//
//  UserScripts.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-15.
//

import WebKit

/// Collection of user scripts injected into WKWebView
enum UserScripts {

    /// Message handler name for console log bridging
    static let consoleLogHandler = "consoleLog"

    /// Creates all user scripts to be injected into the WebView
    static func createAllScripts() -> [WKUserScript] {
        var scripts: [WKUserScript] = [
            createIMEFixScript(),
            WKUserScript(source: readingWidthSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true),
            WKUserScript(source: hideGetAppSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true),
            WKUserScript(source: responseWatcherSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        ]

        #if DEBUG
        scripts.insert(createConsoleLogBridgeScript(), at: 0)
        #endif

        return scripts
    }

    /// Creates a script that bridges console.log to native Swift
    private static func createConsoleLogBridgeScript() -> WKUserScript {
        WKUserScript(
            source: consoleLogBridgeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Creates the IME fix script that resolves the double-enter issue
    /// when using input method editors (e.g., Chinese, Japanese, Korean input)
    private static func createIMEFixScript() -> WKUserScript {
        WKUserScript(
            source: imeFixSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    // MARK: - Script Sources

    /// Keeps the conversation in a centered, readable column (like gemini.google.com
    /// in a desktop browser) instead of stretching across wide windows.
    private static let readingWidthSource = #"""
    (function() {
        if (document.getElementById('gd-reading-width')) { return; }
        var st = document.createElement('style');
        st.id = 'gd-reading-width';
        st.textContent = `
          .conversation-container,
          user-query,
          model-response,
          .input-area-container,
          input-container,
          .zero-state-container,
          infinite-scroller > * {
              max-width: 760px !important;
              margin-left: auto !important;
              margin-right: auto !important;
              box-sizing: border-box !important;
          }
          infinite-scroller { padding-left: 24px !important; padding-right: 24px !important; }`;
        (document.head || document.documentElement).appendChild(st);
    })();
    """#

    /// Hides Gemini's "Get App" promo buttons — we already are the app.
    private static let hideGetAppSource = """
    (function() {
        'use strict';
        function hide() {
            document.querySelectorAll('a, button, [role="button"], [role="menuitem"]').forEach(function(el) {
                if (el.dataset.gdHidden) { return; }
                const text = (el.innerText || el.textContent || '').trim().toLowerCase();
                const label = (el.getAttribute('aria-label') || '').trim().toLowerCase();
                const href = (el.getAttribute('href') || '').toLowerCase();
                if (text === 'get app' || text === 'get the app' || label === 'get app' ||
                    label === 'get the app' || href.indexOf('gemini.google/mac') !== -1 ||
                    href.indexOf('/download') !== -1 && text.indexOf('app') !== -1) {
                    el.dataset.gdHidden = '1';
                    el.style.setProperty('display', 'none', 'important');
                }
            });
        }
        hide();
        let pending = false;
        new MutationObserver(function() {
            if (pending) { return; }
            pending = true;
            requestAnimationFrame(function() { pending = false; hide(); });
        }).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

    /// Watches for Gemini finishing a response (the "Stop response" button
    /// disappearing) and tells the native side so it can post a notification.
    private static let responseWatcherSource = """
    (function() {
        'use strict';
        if (window.__geminiDesktopWatcher) { return; }
        window.__geminiDesktopWatcher = true;

        let generating = false;
        function isGenerating() {
            return !!document.querySelector(
                'button[aria-label="Stop response"], button[aria-label*="Stop generating" i], ' +
                'button.send-button.stop, mat-icon[fonticon="stop"], .stop-icon'
            );
        }
        function latestResponsePreview() {
            const nodes = document.querySelectorAll('message-content, model-response');
            if (!nodes.length) { return ''; }
            const text = (nodes[nodes.length - 1].innerText || '').replace(/\\s+/g, ' ').trim();
            return text.length > 180 ? text.slice(0, 177) + '…' : text;
        }
        setInterval(function() {
            const now = isGenerating();
            if (generating && !now) {
                try {
                    window.webkit.messageHandlers.\(ResponseNotifier.messageHandlerName).postMessage({
                        type: 'responseFinished',
                        preview: latestResponsePreview()
                    });
                } catch (e) {}
            }
            generating = now;
        }, 1000);
    })();
    """

    /// JavaScript to bridge console.log to native Swift via WKScriptMessageHandler
    private static let consoleLogBridgeSource = """
    (function() {
        const originalLog = console.log;
        console.log = function(...args) {
            originalLog.apply(console, args);
            try {
                const message = args.map(arg => {
                    if (typeof arg === 'object') {
                        return JSON.stringify(arg, null, 2);
                    }
                    return String(arg);
                }).join(' ');
                window.webkit.messageHandlers.\(consoleLogHandler).postMessage(message);
            } catch (e) {}
        };
    })();
    """

    /// JavaScript to fix IME Enter issue on Gemini
    /// When using IME (e.g., Chinese/Japanese input), pressing Enter to confirm
    /// the IME composition should NOT send the message. This script intercepts
    /// Enter keydown events during and immediately after IME composition,
    /// preventing them from reaching Gemini's send handler.
    private static let imeFixSource = """
    (function() {
        'use strict';

        let imeActive = false;
        let imeEverUsed = false;
        let compositionEndTime = 0;
        const BUFFER_TIME = 300;

        function isInIMEWindow() {
            return imeActive || (Date.now() - compositionEndTime < BUFFER_TIME);
        }

        document.addEventListener('compositionstart', function() {
            imeActive = true;
            imeEverUsed = true;
        }, true);

        document.addEventListener('compositionend', function() {
            imeActive = false;
            compositionEndTime = Date.now();
        }, true);

        document.addEventListener('keydown', function(e) {
            if (!imeEverUsed) return;
            if (e.key !== 'Enter' || e.shiftKey || e.ctrlKey || e.altKey) return;

            if (isInIMEWindow() || e.isComposing || e.keyCode === 229) {
                e.stopImmediatePropagation();
                e.preventDefault();
            }
        }, true);

        document.addEventListener('beforeinput', function(e) {
            if (!imeEverUsed) return;
            if (e.inputType !== 'insertParagraph' && e.inputType !== 'insertLineBreak') return;

            if (isInIMEWindow()) {
                e.stopImmediatePropagation();
                e.preventDefault();
            }
        }, true);
    })();
    """
}
