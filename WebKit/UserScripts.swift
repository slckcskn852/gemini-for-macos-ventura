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
            WKUserScript(source: submenuFixSource, injectionTime: .atDocumentStart, forMainFrameOnly: true),
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
          user-query,
          model-response {
              content-visibility: auto;
              contain-intrinsic-size: auto 120px;
          }
          infinite-scroller { padding-left: 24px !important; padding-right: 24px !important; }
          *, *::before, *::after {
              backdrop-filter: none !important;
              -webkit-backdrop-filter: none !important;
          }
          .mat-ripple, .mat-ripple-element, .mat-mdc-button-ripple, .mdc-button__ripple, .mdc-icon-button__ripple {
              display: none !important;
          }
          .lm-fade-in-up-animation, .fade-in-animation, .fade-in,
          message-content, model-response, user-query,
          bard-sidenav, side-navigation-v2, .conversation-items-container,
          .mat-mdc-menu-panel, gem-menu, gem-menu-item,
          .cdk-overlay-pane, .cdk-overlay-backdrop {
              animation-duration: 0.001ms !important;
              animation-delay: 0s !important;
              transition-duration: 0.001ms !important;
              transition-delay: 0s !important;
          }
          chat-loading-animation, .nl-canvas, .nl-blob, .gradient-strip { display: none !important; animation: none !important; filter: none !important; }
          .mdc-circular-progress--closed .mdc-circular-progress__indeterminate-container, .mdc-circular-progress--closed .mdc-circular-progress__spinner-layer, .mdc-circular-progress--closed svg { animation: none !important; }
          desktop-get-app-button, a[href*="gemini.google/mac"], a[aria-label="Get App" i], a[aria-label="Get the app" i], button[aria-label="Get App" i], button[aria-label="Get the app" i], [role="button"][aria-label="Get App" i], [role="menuitem"][aria-label="Get App" i] { display: none !important; }`;
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

    /// Fixes nested submenus (e.g. "Thinking level") across WebKit versions with zero
    /// MutationObservers and zero idle timers:
    /// - Modern WebKit (macOS 26 / Safari 27+): when `showPopover` is supported, WebKit
    ///   can leave `.cdk-overlay-popover.cdk-overlay-connected-position-bounding-box` laid
    ///   out at full viewport `(0, 0)` after inline positioning updates. A bounded `350ms`
    ///   `requestAnimationFrame` watch on `gem-menu-item` interaction checks a
    ///   self-healing width guard and forces a one-shot `display` reflow only when
    ///   mismatched (covering `ngMenu`'s 100ms hover open delay with zero idle cost).
    /// - Legacy WebKit (macOS Ventura 18615 / Safari 16.6): when `showPopover` is missing,
    ///   Angular CDK falls back to rendering submenus as sibling overlays in
    ///   `.cdk-overlay-container` instead of inline descendants of `<gem-menu>`, causing
    ///   `ngMenu` focusout and `clickOutside` containment checks to prematurely close
    ///   the entire dropdown.
    private static let submenuFixSource = #"""
    (function() {
        'use strict';
        if (typeof HTMLElement === 'undefined') { return; }

        if ('showPopover' in HTMLElement.prototype) {
            var rafId = null;
            var watchUntil = 0;
            function fixPopoverSubmenus(now) {
                rafId = null;
                var scs = document.querySelectorAll('.submenu-container');
                for (var i = 0; i < scs.length; i++) {
                    var sc = scs[i];
                    if (sc.style.display === 'none') { continue; }
                    var box = sc.closest('.cdk-overlay-popover.cdk-overlay-connected-position-bounding-box');
                    if (!box || !box.matches(':popover-open')) { continue; }
                    var expectedWidth = parseFloat(box.style.width);
                    if (!(expectedWidth > 0) || expectedWidth >= window.innerWidth - 2) { continue; }
                    if (box.getBoundingClientRect().width >= window.innerWidth - 2) {
                        var prevDisplay = box.style.display;
                        box.style.display = 'none';
                        void box.offsetHeight;
                        box.style.display = prevDisplay;
                    }
                }
                if (now < watchUntil) {
                    rafId = requestAnimationFrame(fixPopoverSubmenus);
                }
            }
            function startWatch() {
                watchUntil = performance.now() + 350;
                if (rafId === null) {
                    rafId = requestAnimationFrame(fixPopoverSubmenus);
                }
            }
            function onMenuInteraction(e) {
                var t = e.target;
                if (!(t instanceof Element) || !t.closest('gem-menu-item')) { return; }
                startWatch();
            }
            document.addEventListener('mouseover', onMenuInteraction, true);
            document.addEventListener('click', onMenuInteraction, true);
            document.addEventListener('keydown', onMenuInteraction, true);
            window.addEventListener('resize', function() {
                if (document.querySelector('.submenu-container:not([style*="display: none"])')) {
                    startWatch();
                }
            }, { passive: true });
            return;
        }

        function injectLegacyOverlayStyle() {
            if (document.getElementById('gd-legacy-overlay-style')) { return true; }
            var target = document.head || document.documentElement;
            if (!target) { return false; }
            var st = document.createElement('style');
            st.id = 'gd-legacy-overlay-style';
            st.textContent =
                '.cdk-overlay-connected-position-bounding-box { pointer-events: none; }' +
                '.cdk-overlay-connected-position-bounding-box:has(.submenu-container) { z-index: 1002 !important; }' +
                '.cdk-overlay-pane { pointer-events: auto; }' +
                '.popover-click-shield { pointer-events: none !important; }';
            target.appendChild(st);
            return true;
        }
        if (!injectLegacyOverlayStyle()) {
            document.addEventListener('DOMContentLoaded', injectLegacyOverlayStyle, { once: true });
        }

        var origContains = Node.prototype.contains;
        Node.prototype.contains = function(other) {
            if (origContains.call(this, other)) { return true; }
            if (!other || other.nodeType !== 1 || this.nodeType !== 1) { return false; }
            var sub = other.closest && other.closest('.cdk-overlay-container .submenu-container');
            if (!sub || sub.style.display === 'none' || origContains.call(sub, this)) { return false; }
            if (this.closest && this.closest('.cdk-overlay-pane') &&
                this.querySelector && this.querySelector('gem-menu-item[aria-expanded="true"]')) {
                return true;
            }
            return false;
        };

        var lastOutsidePointerDown = 0;
        document.addEventListener('pointerdown', function(e) {
            var t = e.target;
            if (t instanceof Element && !t.closest('.cdk-overlay-pane, [data-gem-menu-trigger-id], [aria-haspopup="true"]')) {
                lastOutsidePointerDown = Date.now();
            }
        }, true);

        document.addEventListener('focusout', function(e) {
            if (e.relatedTarget !== null) { return; }
            if (Date.now() - lastOutsidePointerDown < 250) { return; }
            var t = e.target;
            if (!(t instanceof Element)) { return; }
            var inMenuOrTrigger = t.closest('gem-menu, [data-gem-menu-trigger-id], .input-area-switch');
            if (!inMenuOrTrigger) { return; }
            if (document.querySelector('gem-menu-item[aria-expanded="true"], .cdk-overlay-container .submenu-container:not([style*="display: none"])')) {
                e.stopImmediatePropagation();
            }
        }, true);
    })();
    """#

    /// Hides Gemini's "Get App" promo buttons — we already are the app.
    /// Uses targeted scans after hydration and navigation/menu clicks instead of a
    /// full-document MutationObserver so streaming tokens trigger zero JS work.
    private static let hideGetAppSource = #"""
    (function() {
        'use strict';
        const CANDIDATE_SELECTOR = 'a, button, [role="button"], [role="menuitem"]';
        const SKIP_TEXT_SELECTOR = 'mat-icon, svg, style, script, [aria-hidden="true"]';
        const PROMO_CONTAINERS = 'bard-sidenav, side-navigation-v2, mat-sidenav, .cdk-overlay-container, header, top-bar-actions, desktop-get-app-button';

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

        function scan(scope) {
            const root = scope || document;
            root.querySelectorAll(CANDIDATE_SELECTOR).forEach(checkCandidate);
        }

        function scanPromoContainers() {
            document.querySelectorAll(PROMO_CONTAINERS).forEach(scan);
        }

        scan(document);
        setTimeout(function() { scan(document); }, 1500);
        setTimeout(function() { scan(document); }, 4000);

        let clickTimer = null;
        document.addEventListener('click', function(e) {
            const t = e.target;
            if (!(t instanceof Element)) { return; }
            if (!t.closest('bard-sidenav, side-navigation-v2, button[aria-label*="menu" i], button[aria-label*="sidebar" i], button[aria-label*="settings" i]')) {
                return;
            }
            if (clickTimer !== null) { clearTimeout(clickTimer); }
            clickTimer = setTimeout(function() {
                clickTimer = null;
                scanPromoContainers();
            }, 250);
        }, true);
    })();
    """#

    /// Watches for Gemini finishing a response (the "Stop response" button
    /// disappearing) and tells the native side so it can post a notification.
    /// Zero MutationObservers and zero idle timers; only probes briefly after
    /// Enter/click and polls while a response is actively streaming.
    private static let responseWatcherSource = #"""
    (function() {
        'use strict';
        if (window.__geminiDesktopWatcher) { return; }
        window.__geminiDesktopWatcher = true;

        let generating = false;
        let pollTimer = null;
        let probeTimers = [];

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

        function clearProbes() {
            for (let i = 0; i < probeTimers.length; i++) {
                clearTimeout(probeTimers[i]);
            }
            probeTimers = [];
        }

        function checkState() {
            const now = isGenerating();
            if (now && !generating) {
                generating = true;
                clearProbes();
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
            if (generating) { return; }
            clearProbes();
            probeTimers.push(setTimeout(checkState, 400));
            probeTimers.push(setTimeout(checkState, 1200));
        }

        document.addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && !e.shiftKey) {
                scheduleCheck();
            }
        }, true);

        document.addEventListener('click', function() {
            scheduleCheck();
        }, true);

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
