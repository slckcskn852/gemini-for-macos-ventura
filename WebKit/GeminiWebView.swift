//
//  GeminiWebView.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import WebKit

struct GeminiWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer(webView: webView, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: WebViewContainer, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        private var downloadDestination: URL?

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if isExternalURL(url) {
                    NSWorkspace.shared.open(url)
                } else {
                    webView.load(URLRequest(url: url))
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // <a download> links (e.g. "Download image" on generated images)
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
            // mailto:, tel:, facetime: etc. go to the system handler
            if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
               !["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            // Cmd-click opens links in the default browser
            if navigationAction.modifierFlags.contains(.command),
               navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// Recover automatically if the web content process crashes (e.g. memory pressure).
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.canShowMIMEType {
                decisionHandler(.allow)
            } else {
                decisionHandler(.download)
            }
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            var destination = downloadsURL.appendingPathComponent(suggestedFilename)

            // Handle duplicate filenames
            var counter = 1
            let fileManager = FileManager.default
            let nameWithoutExtension = destination.deletingPathExtension().lastPathComponent
            let fileExtension = destination.pathExtension

            while fileManager.fileExists(atPath: destination.path) {
                let newName = fileExtension.isEmpty
                    ? "\(nameWithoutExtension) (\(counter))"
                    : "\(nameWithoutExtension) (\(counter)).\(fileExtension)"
                destination = downloadsURL.appendingPathComponent(newName)
                counter += 1
            }

            downloadDestination = destination
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let destination = downloadDestination else { return }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            let alert = NSAlert()
            alert.messageText = "Download Failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: GeminiWebView.Constants.textFieldWidth, height: GeminiWebView.Constants.textFieldHeight))
            textField.stringValue = defaultText ?? ""
            alert.accessoryView = textField

            completionHandler(alert.runModal() == .alertFirstButtonReturn ? textField.stringValue : nil)
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(origin.host.contains(GeminiWebView.Constants.trustedHost) ? .grant : .prompt)
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            // Activate the app so the file dialog receives focus,
            // especially when triggered from the non-activating floating panel
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }

        private func isExternalURL(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            // Only Gemini-related domains stay in the app
            let internalHosts = ["gemini.google.com", "accounts.google.com", "accounts.youtube.com"]
            let internalSuffixes = [".googleapis.com", ".gstatic.com"]

            if internalHosts.contains(host) { return false }
            for suffix in internalSuffixes {
                if host.hasSuffix(suffix) { return false }
            }
            return true
        }
    }
}

class WebViewContainer: NSView {
    let webView: WKWebView
    let coordinator: GeminiWebView.Coordinator
    private var windowObserver: NSObjectProtocol?
    private var revealGeneration = 0
    private var revealedGeneration = 0
    private var revealFallbackWorkItem: DispatchWorkItem?

    private static let darkBackgroundColor = NSColor(srgbRed: 19.0 / 255.0, green: 19.0 / 255.0, blue: 20.0 / 255.0, alpha: 1.0)
    private static let lightBackgroundColor = NSColor(srgbRed: 248.0 / 255.0, green: 250.0 / 255.0, blue: 253.0 / 255.0, alpha: 1.0)

    init(webView: WKWebView, coordinator: GeminiWebView.Coordinator) {
        self.webView = webView
        self.coordinator = coordinator
        super.init(frame: .zero)
        autoresizesSubviews = true
        wantsLayer = true
        updateBackgroundColor()
        setupWindowObserver()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        revealFallbackWorkItem?.cancel()
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updateBackgroundColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (isDark ? Self.darkBackgroundColor : Self.lightBackgroundColor).cgColor
    }

    private func setupWindowObserver() {
        // Observe when ANY window becomes key - then check if we should have the webView
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let keyWindow = notification.object as? NSWindow,
                  self.window === keyWindow else { return }
            // Our window became key, attach webView
            self.attachWebView()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && window?.isKeyWindow == true {
            attachWebView()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    override func layout() {
        super.layout()
        updateBackgroundColor()
        if webView.superview === self {
            webView.frame = bounds
        }
    }

    private func attachWebView() {
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        // Moving the shared web view between windows forces a relayout (and Quick Chat
        // closes the sidebar / narrows the column). Hide it and freeze Gemini's own
        // layout transitions so the user sees one clean fade instead of the jumps.
        webView.wantsLayer = true
        webView.alphaValue = 0
        webView.evaluateJavaScript(Self.freezeLayoutScript, completionHandler: nil)
        addSubview(webView)

        revealFallbackWorkItem?.cancel()
        revealGeneration += 1
        let generation = revealGeneration

        let fallback = DispatchWorkItem { [weak self] in
            self?.revealIfNeeded(generation: generation)
        }
        revealFallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: fallback)

        DispatchQueue.main.async { [weak self] in
            self?.revealWhenLayoutSettles(generation: generation)
        }
    }

    /// Runs an in-page `requestAnimationFrame` settle loop inside WebContent via a single
    /// `callAsyncJavaScript` invocation, eliminating per-frame XPC polling churn while waiting
    /// for two consecutive matching layout signatures (or at most 12 frames / ~200ms).
    private func revealWhenLayoutSettles(generation: Int) {
        guard generation == revealGeneration, webView.superview === self else { return }
        webView.callAsyncJavaScript(Self.settleLayoutScript, in: nil, in: .page) { [weak self] _ in
            self?.revealIfNeeded(generation: generation)
        }
    }

    private func revealIfNeeded(generation: Int) {
        guard generation == revealGeneration,
              revealedGeneration != generation,
              webView.superview === self else { return }
        revealedGeneration = generation
        revealFallbackWorkItem?.cancel()
        revealFallbackWorkItem = nil
        fadeInWebView(generation: generation)
    }

    private func fadeInWebView(generation: Int) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            webView.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self,
                  generation == self.revealGeneration,
                  self.webView.superview === self else { return }
            self.webView.evaluateJavaScript(#"document.documentElement.classList.remove('gd-noanim');"#, completionHandler: nil)
        }
    }

    static let settleLayoutScript = #"""
    var sel = ['input-container', 'rich-textarea', 'chat-window', '.conversation-container', 'bard-sidenav', 'side-navigation-v2', 'mat-sidenav', '.zero-state-container'];
    function layoutSignature() {
        var out = [window.innerWidth, window.innerHeight];
        for (var i = 0; i < sel.length; i++) {
            var el = document.querySelector(sel[i]);
            if (el) {
                var r = el.getBoundingClientRect();
                out.push(Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height));
            }
        }
        return out.join(',');
    }
    return new Promise(function(resolve) {
        if (typeof requestAnimationFrame !== 'function') {
            resolve(true);
            return;
        }
        var last = null;
        var frames = 0;
        function tick() {
            frames++;
            var cur = layoutSignature();
            if (cur === last || frames >= 12) {
                resolve(true);
                return;
            }
            last = cur;
            requestAnimationFrame(tick);
        }
        requestAnimationFrame(tick);
    });
    """#


    static let freezeLayoutScript = #"""
    (function() {
        if (!document.getElementById('gd-noanim-style')) {
            var st = document.createElement('style');
            st.id = 'gd-noanim-style';
            st.textContent = 'html.gd-noanim .mat-drawer, html.gd-noanim .mat-drawer-content, html.gd-noanim .mat-drawer-backdrop,' +
              'html.gd-noanim bard-sidenav, html.gd-noanim bard-sidenav *, html.gd-noanim side-navigation-v2, html.gd-noanim side-navigation-v2 *,' +
              'html.gd-noanim chat-window, html.gd-noanim .conversation-container, html.gd-noanim input-container,' +
              'html.gd-noanim user-query, html.gd-noanim model-response { transition: none !important; animation: none !important; }';
            (document.head || document.documentElement).appendChild(st);
        }
        document.documentElement.classList.add('gd-noanim');
    })();
    """#
}


extension GeminiWebView {

    struct Constants {
        static let textFieldWidth: CGFloat = 200
        static let textFieldHeight: CGFloat = 24
        static let trustedHost = "google.com"
    }

}
