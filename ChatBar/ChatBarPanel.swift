//
//  ChatBar.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit
import WebKit

class ChatBarPanel: NSPanel, NSWindowDelegate {

    private var positionSaveWork: DispatchWorkItem?
    private var sizeSaveWork: DispatchWorkItem?
    private var clickOutsideMonitor: Any?
    private weak var webView: WKWebView?

    init(contentView: NSView) {
        let width = UserDefaults.standard.double(forKey: UserDefaultsKeys.panelWidth.rawValue)
        let height = UserDefaults.standard.double(forKey: UserDefaultsKeys.panelHeight.rawValue)
        let initWidth = width >= Constants.minWidth ? width : Constants.defaultWidth
        let initHeight = height >= Constants.minHeight ? height : Constants.defaultHeight

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: initWidth, height: initHeight),
            styleMask: [
                .nonactivatingPanel,
                .resizable,
                .borderless
            ],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView
        self.delegate = self

        configureWindow()
        configureAppearance()
    }

    private func resolvedWebView() -> WKWebView? {
        if let webView = webView {
            return webView
        }
        guard let contentView = contentView,
              let found = findWebView(in: contentView) else {
            return nil
        }
        webView = found
        return found
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let wk = view as? WKWebView {
            return wk
        }
        for subview in view.subviews {
            if let wk = findWebView(in: subview) {
                return wk
            }
        }
        return nil
    }

    private func configureWindow() {
        isFloatingPanel = true
        level = .floating
        isMovable = true
        isMovableByWindowBackground = false

        collectionBehavior.insert(.fullScreenAuxiliary)
        collectionBehavior.insert(.canJoinAllSpaces)

        minSize = NSSize(width: Constants.minWidth, height: Constants.minHeight)
        maxSize = NSSize(width: Constants.maxWidth, height: Constants.maxHeight)
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, self.isVisible else { return }
            self.orderOut(nil)
        }
    }

    private func removeClickOutsideMonitor() {
        guard let monitor = clickOutsideMonitor else { return }
        NSEvent.removeMonitor(monitor)
        clickOutsideMonitor = nil
    }

    private func configureAppearance() {
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false

        if let contentView = contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = Constants.cornerRadius
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
            // The adaptive hairline is drawn in SwiftUI (ChatBarView) so it follows appearance.
        }
    }

    /// Called when panel is shown - focuses the prompt input
    func checkAndAdjustSize() {
        focusInput()
    }

    /// Focus the input field in the WebView
    func focusInput() {
        guard let webView = resolvedWebView() else { return }
        // Close Gemini's overlay sidebar (it opens over the chat in narrow windows), then focus the prompt.
        webView.evaluateJavaScript(ChatBarPanel.enterQuickChatScript, completionHandler: nil)
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript(PromptInjector.focusInputScript, completionHandler: nil)
    }

    deinit {
        positionSaveWork?.cancel()
        sizeSaveWork?.cancel()
        removeClickOutsideMonitor()
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        let size = frame.size
        scheduleSave(&sizeSaveWork, delay: Constants.sizeSaveDebounce) {
            UserDefaults.standard.set(size.width, forKey: UserDefaultsKeys.panelWidth.rawValue)
            UserDefaults.standard.set(size.height, forKey: UserDefaultsKeys.panelHeight.rawValue)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard PanelPosition.current == .rememberLast else { return }
        let origin = frame.origin
        scheduleSave(&positionSaveWork, delay: Constants.positionSaveDebounce) {
            UserDefaults.standard.set(origin.x, forKey: UserDefaultsKeys.panelX.rawValue)
            UserDefaults.standard.set(origin.y, forKey: UserDefaultsKeys.panelY.rawValue)
        }
    }

    private func scheduleSave(_ workSlot: inout DispatchWorkItem?, delay: TimeInterval, save: @escaping () -> Void) {
        workSlot?.cancel()
        let work = DispatchWorkItem(block: save)
        workSlot = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Keyboard Handling

    /// Handle ESC key to hide the chat bar
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    /// Handle CMD+N to open a new Gemini chat
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) &&
           !event.modifierFlags.contains(.shift) &&
           !event.modifierFlags.contains(.option) &&
           event.charactersIgnoringModifiers == "n" {
            openNewChat()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Triggers a new chat by emulating Shift+Cmd+O (Google's shortcut)
    private func openNewChat() {
        guard let webView = resolvedWebView() else { return }
        PromptInjector.newChat(in: webView) { [weak self] in
            self?.focusInput()
        }
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        installClickOutsideMonitor()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
    }

    override func orderOut(_ sender: Any?) {
        removeClickOutsideMonitor()
        super.orderOut(sender)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
    }

    static let exitQuickChatScript = #"document.documentElement.classList.remove('gd-quickchat', 'gd-qc-usernav');"#

    /// Adds a compact-layout class (narrow reading column, no sidebar) and
    /// force-closes Gemini's sidebar when open, retrying up to 6 times while open.
    static let enterQuickChatScript = #"""
    (function() {
        var root = document.documentElement;
        root.classList.add('gd-quickchat');
        if (!document.getElementById('gd-quickchat-style')) {
            var st = document.createElement('style');
            st.id = 'gd-quickchat-style';
            st.textContent = `
              html.gd-quickchat .conversation-container,
              html.gd-quickchat user-query,
              html.gd-quickchat model-response {
                  max-width: 660px !important;
                  margin-left: auto !important;
                  margin-right: auto !important;
                  box-sizing: border-box !important;
              }
              html.gd-quickchat message-content,
              html.gd-quickchat .markdown {
                  line-height: 1.55 !important;
                  overflow-wrap: anywhere;
              }
              html.gd-quickchat infinite-scroller { padding-left: 20px !important; padding-right: 20px !important; }
              html.gd-quickchat .cdk-overlay-backdrop.mat-drawer-backdrop,
              html.gd-quickchat .mat-drawer-backdrop.mat-drawer-shown { display: none !important; }`;
            (document.head || document.documentElement).appendChild(st);
        }
        // In Quick Chat, Gemini's overlay drawer is never shown unless the user opens it:
        // Gemini re-opens it on its own a beat after the resize (it remembers the main
        // window's pinned sidebar), so it is kept invisible and un-animated and closed
        // behind the scenes. A user click on the menu button reveals it normally.
        if (!document.getElementById('gd-qc-nav-style')) {
            var hs = document.createElement('style');
            hs.id = 'gd-qc-nav-style';
            hs.textContent = 'html.gd-quickchat:not(.gd-qc-usernav) mat-sidenav, html.gd-quickchat:not(.gd-qc-usernav) .mat-drawer,' +
              'html.gd-quickchat:not(.gd-qc-usernav) bard-sidenav, html.gd-quickchat:not(.gd-qc-usernav) .mat-drawer-backdrop' +
              '{ visibility: hidden !important; transition: none !important; animation: none !important; }';
            (document.head || document.documentElement).appendChild(hs);
        }
        if (!window.__gdQCNavClickHooked) {
            window.__gdQCNavClickHooked = true;
            document.addEventListener('click', function(e) {
                if (!root.classList.contains('gd-quickchat') || !e.isTrusted) { return; }
                var t = e.target && e.target.closest ? e.target : null;
                if (!t) { return; }
                if (t.closest('button[aria-label="Main menu"], button[aria-label="Open sidebar"]')) {
                    root.classList.add('gd-qc-usernav');
                } else if (t.closest('button[aria-label="Close sidebar"], .mat-drawer-backdrop')) {
                    root.classList.remove('gd-qc-usernav');
                }
            }, true);
        }
        root.classList.remove('gd-qc-usernav');
        // Closes an auto-opened drawer while it is hidden. Called right away and from
        // every transition settle poll (page timers are throttled during the fade-in).
        window.__gdQCNavStep = function() {
            if (!root.classList.contains('gd-quickchat') || root.classList.contains('gd-qc-usernav')) { return true; }
            if (window.innerWidth >= 960) { return true; }
            var opened = document.querySelector('mat-sidenav.mat-drawer-opened, .mat-drawer.mat-drawer-opened');
            if (!opened) { return true; }
            var btn = opened.querySelector('button[aria-label="Close sidebar"]');
            if (!btn) {
                var all = document.querySelectorAll('button[aria-label="Close sidebar"]');
                for (var bi = 0; bi < all.length; bi++) {
                    if (all[bi].getBoundingClientRect().width > 0) { btn = all[bi]; break; }
                }
            }
            if (btn) { btn.click(); }
            if (opened.classList.contains('mat-drawer-opened')) {
                var bd = document.querySelector('.mat-drawer-backdrop');
                if (bd) { bd.click(); }
            }
            return !opened.classList.contains('mat-drawer-opened');
        };
        var tries = 0;
        (function loop() {
            window.__gdQCNavStep();
            if (++tries < 40) { setTimeout(loop, 75); }
        })();
    })();
    """#

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}


extension ChatBarPanel {

    struct Constants {
        static let defaultWidth: CGFloat = 760
        static let defaultHeight: CGFloat = 620
        static let minWidth: CGFloat = 560
        static let minHeight: CGFloat = 420
        static let maxWidth: CGFloat = 1400
        static let maxHeight: CGFloat = 1400
        static let cornerRadius: CGFloat = 22
        static let borderWidth: CGFloat = 0.5
        static let positionSaveDebounce: TimeInterval = 0.3
        static let sizeSaveDebounce: TimeInterval = 0.3
    }
}
