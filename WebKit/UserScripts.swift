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
            WKUserScript(source: coreStyleSource, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            createIMEFixScript(),
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

    /// Injects core layout, GPU/CPU animation suppression, and static promo hiding
    /// at document start so WebKit never allocates oversized offscreen backing textures.
    private static let coreStyleSource = #"""
    (function() {
        'use strict';
        if (document.getElementById('gd-core-style')) { return; }
        var css = `
          .conversation-container,
          user-query,
          model-response {
              max-width: 760px !important;
              margin-left: auto !important;
              margin-right: auto !important;
              box-sizing: border-box !important;
          }
          infinite-scroller { padding-left: 24px !important; padding-right: 24px !important; }
          chat-loading-animation, .nl-canvas, .nl-blob, .gradient-strip { display: none !important; animation: none !important; filter: none !important; }
          .mdc-circular-progress--closed .mdc-circular-progress__indeterminate-container, .mdc-circular-progress--closed .mdc-circular-progress__spinner-layer, .mdc-circular-progress--closed svg { animation: none !important; }
          a[href*="gemini.google/mac"], a[aria-label="Get App" i], a[aria-label="Get the app" i], button[aria-label="Get App" i], button[aria-label="Get the app" i], [role="button"][aria-label="Get App" i], [role="menuitem"][aria-label="Get App" i] { display: none !important; }`;
        function inject() {
            if (document.getElementById('gd-core-style')) { return true; }
            var target = document.head || document.documentElement;
            if (!target) { return false; }
            var st = document.createElement('style');
            st.id = 'gd-core-style';
            st.textContent = css;
            target.appendChild(st);
            return true;
        }
        if (!inject()) {
            document.addEventListener('DOMContentLoaded', inject, { once: true });
        }
    })();
    """#

    /// Hides Gemini's "Get App" promo buttons — we already are the app.
    private static let hideGetAppSource = #"""
    (function() {
        'use strict';
        const CANDIDATE_SELECTOR = 'a, button, [role="button"], [role="menuitem"]';
        const SKIP_TEXT_SELECTOR = 'mat-icon, svg, style, script, [aria-hidden="true"]';
        const STREAMING_SKIP_SELECTOR = 'message-content, model-response, user-query';

        function cleanText(el) {
            const walker = document.createTreeWalker(
                el,
                NodeFilter.SHOW_TEXT,
                {
                    acceptNode: function(node) {
                        const parent = node.parentElement;
                        if (parent && parent.closest && parent.closest(SKIP_TEXT_SELECTOR)) {
                            return NodeFilter.FILTER_REJECT;
                        }
                        return NodeFilter.FILTER_ACCEPT;
                    }
                }
            );
            let out = '';
            let node;
            while ((node = walker.nextNode())) {
                out += ' ' + node.nodeValue;
            }
            return out.replace(/\s+/g, ' ').trim().toLowerCase();
        }

        function checkCandidate(el) {
            if (!el || !el.dataset || el.dataset.gdHidden) { return; }
            const label = (el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim().toLowerCase();
            const href = (el.getAttribute('href') || '').toLowerCase();
            if (label === 'get app' || label === 'get the app' ||
                href.indexOf('gemini.google/mac') !== -1) {
                el.dataset.gdHidden = '1';
                el.style.setProperty('display', 'none', 'important');
                return;
            }
            const text = cleanText(el);
            if (text === 'get app' || text === 'get the app' ||
                (href.indexOf('/download') !== -1 && text.indexOf('app') !== -1)) {
                el.dataset.gdHidden = '1';
                el.style.setProperty('display', 'none', 'important');
            }
        }

        document.querySelectorAll(CANDIDATE_SELECTOR).forEach(checkCandidate);

        const pending = new Set();
        let flushTimer = null;

        function flushPending() {
            flushTimer = null;
            pending.forEach(checkCandidate);
            pending.clear();
        }

        function scheduleFlush() {
            if (flushTimer !== null) {
                clearTimeout(flushTimer);
            }
            flushTimer = setTimeout(flushPending, 150);
        }

        function collectNode(node) {
            if (node.nodeType === 1) {
                let found = false;
                if (node.matches(CANDIDATE_SELECTOR)) {
                    pending.add(node);
                    found = true;
                }
                const nested = node.querySelectorAll(CANDIDATE_SELECTOR);
                for (let i = 0; i < nested.length; i++) {
                    pending.add(nested[i]);
                    found = true;
                }
                return found;
            }
            if (node.nodeType === 3) {
                const parent = node.parentElement;
                const candidate = parent && parent.closest(CANDIDATE_SELECTOR);
                if (candidate) {
                    pending.add(candidate);
                    return true;
                }
            }
            return false;
        }

        const root = document.documentElement;
        if (!root) { return; }
        new MutationObserver(function(mutations) {
            let touched = false;
            for (let i = 0; i < mutations.length; i++) {
                const m = mutations[i];
                const target = m.target;
                const targetEl = target.nodeType === 1 ? target : target.parentElement;
                if (targetEl && targetEl.closest && targetEl.closest(STREAMING_SKIP_SELECTOR)) {
                    continue;
                }
                const added = m.addedNodes;
                for (let j = 0; j < added.length; j++) {
                    if (collectNode(added[j])) {
                        touched = true;
                    }
                }
            }
            if (touched) {
                scheduleFlush();
            }
        }).observe(root, { childList: true, subtree: true });
    })();
    """#

    /// Watches for Gemini finishing a response (the "Stop response" button
    /// disappearing) and tells the native side so it can post a notification.
    /// Runs zero timers when idle; only polls while a response is actively streaming.
    private static let responseWatcherSource = #"""
    (function() {
        'use strict';
        if (window.__geminiDesktopWatcher) { return; }
        window.__geminiDesktopWatcher = true;

        let generating = false;
        let pollTimer = null;
        let throttleTimer = null;

        function isGenerating() {
            return !!document.querySelector(
                'button[aria-label="Stop response"], button[aria-label*="Stop generating" i], ' +
                'button.send-button.stop, mat-icon[fonticon="stop"], .stop-icon'
            );
        }

        function latestResponsePreview() {
            const nodes = document.querySelectorAll('message-content, model-response');
            if (!nodes.length) { return ''; }
            const text = (nodes[nodes.length - 1].textContent || '').replace(/\s+/g, ' ').trim();
            return text.length > 180 ? text.slice(0, 177) + '…' : text;
        }

        function checkState() {
            const now = isGenerating();
            if (now && !generating) {
                generating = true;
                if (pollTimer === null) {
                    pollTimer = setInterval(checkState, 800);
                }
            } else if (!now && generating) {
                generating = false;
                if (pollTimer !== null) {
                    clearInterval(pollTimer);
                    pollTimer = null;
                }
                try {
                    window.webkit.messageHandlers.\#(ResponseNotifier.messageHandlerName).postMessage({
                        type: 'responseFinished',
                        preview: latestResponsePreview()
                    });
                } catch (e) {}
            }
        }

        function scheduleCheck() {
            if (generating || throttleTimer !== null) { return; }
            throttleTimer = setTimeout(function() {
                throttleTimer = null;
                checkState();
            }, 400);
        }

        document.addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && !e.shiftKey) {
                scheduleCheck();
            }
        }, true);

        document.addEventListener('click', function() {
            scheduleCheck();
        }, true);

        const root = document.body || document.documentElement;
        if (root) {
            new MutationObserver(scheduleCheck).observe(root, { childList: true, subtree: true });
        }

        checkState();
    })();
    """#

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
