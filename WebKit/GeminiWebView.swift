//
//  GeminiWebView.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import WebKit
import CoreImage

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
    private let coverView = NSView()
    private var windowObserver: NSObjectProtocol?
    private var revealGeneration = 0
    private var revealedGeneration = 0
    private var revealFallbackWorkItem: DispatchWorkItem?
    private var lastBoundsSize: NSSize = .zero
    private var pendingAttachSourceSize: NSSize?
    private var unfreezeWorkItem: DispatchWorkItem?
    private var stableSinceUptime: TimeInterval?

    private static let quickChatDarkBackgroundColor = NSColor(srgbRed: 13.0 / 255.0, green: 13.0 / 255.0, blue: 16.0 / 255.0, alpha: 1.0)
    private static let darkBackgroundColor = NSColor(srgbRed: 19.0 / 255.0, green: 19.0 / 255.0, blue: 20.0 / 255.0, alpha: 1.0)
    private static let lightBackgroundColor = NSColor(srgbRed: 248.0 / 255.0, green: 250.0 / 255.0, blue: 253.0 / 255.0, alpha: 1.0)

    init(webView: WKWebView, coordinator: GeminiWebView.Coordinator) {
        self.webView = webView
        self.coordinator = coordinator
        super.init(frame: .zero)
        autoresizesSubviews = true
        wantsLayer = true
        coverView.wantsLayer = true
        coverView.autoresizingMask = [.width, .height]
        coverView.isHidden = true
        coverView.alphaValue = 0
        updateBackgroundColor()
        setupWindowObserver()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        revealFallbackWorkItem?.cancel()
        unfreezeWorkItem?.cancel()
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updateBackgroundColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor
        if isDark {
            color = (window is NSPanel) ? Self.quickChatDarkBackgroundColor : Self.darkBackgroundColor
        } else {
            color = Self.lightBackgroundColor
        }
        let cgColor = color.cgColor
        layer?.backgroundColor = cgColor
        coverView.layer?.backgroundColor = cgColor
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
        updateBackgroundColor()
        if window != nil && window?.isKeyWindow == true {
            attachWebView()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        unfreezeWorkItem?.cancel()
        unfreezeWorkItem = nil
        if webView.superview === self {
            webView.evaluateJavaScript(Self.freezeLayoutScript, completionHandler: nil)
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        lastBoundsSize = bounds.size
        scheduleUnfreeze(after: 0.18)
    }

    override func layout() {
        super.layout()
        updateBackgroundColor()
        if webView.superview === self {
            webView.frame = bounds
        }
        if coverView.superview === self {
            coverView.frame = bounds
            if !coverView.isHidden {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layoutSnapshotLayer()
                CATransaction.commit()
            }
        }
        if webView.superview === self {
            if inLiveResize {
                lastBoundsSize = bounds.size
            } else if bounds.width > 10, bounds.height > 10 {
                let oldSize = lastBoundsSize
                let jumped = oldSize != .zero &&
                    (abs(bounds.width - oldSize.width) > 80 || abs(bounds.height - oldSize.height) > 80)
                let becameNonZero = oldSize == .zero
                lastBoundsSize = bounds.size
                if (jumped || becameNonZero), (window?.isVisible == true || !coverView.isHidden) {
                    let sourceSize = jumped ? oldSize : pendingAttachSourceSize
                    pendingAttachSourceSize = nil
                    hideForRelayoutAndSettle(targetSize: bounds.size, sourceSize: sourceSize)
                }
            }
        }
    }

    /// Blurred snapshot of the outgoing layout, aspect-filled under a soft tint.
    private lazy var snapshotLayer: CALayer = {
        let l = CALayer()
        l.contentsGravity = .resizeAspectFill
        l.masksToBounds = true
        l.isHidden = true
        let tint = CALayer()
        tint.name = "tint"
        l.addSublayer(tint)
        coverView.layer?.addSublayer(l)
        return l
    }()

    private func applySnapshot(_ image: CGImage?) {
        let l = snapshotLayer
        guard let image = image else {
            l.contents = nil
            l.isHidden = true
            return
        }
        l.frame = coverView.bounds
        l.contents = image
        if let tint = l.sublayers?.first(where: { $0.name == "tint" }) {
            tint.frame = l.bounds
            tint.backgroundColor = coverView.layer?.backgroundColor?.copy(alpha: 0.35)
        }
        l.isHidden = false
    }

    private func showCoverImmediately() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateBackgroundColor()
        coverView.layer?.removeAllAnimations()
        let freshCover = coverView.isHidden || coverView.alphaValue < 1.0
        coverView.frame = bounds
        if freshCover {
            // Fresh cover: use the hand-off snapshot if one was just captured.
            applySnapshot(TransitionSnapshot.consume())
        } else {
            layoutSnapshotLayer()
        }
        coverView.alphaValue = 1.0
        coverView.isHidden = false
        CATransaction.commit()
    }

    private func layoutSnapshotLayer() {
        guard !snapshotLayer.isHidden else { return }
        snapshotLayer.frame = coverView.bounds
        snapshotLayer.sublayers?.forEach { $0.frame = snapshotLayer.bounds }
    }

    private func scheduleUnfreeze(after delay: TimeInterval) {
        unfreezeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.webView.superview === self,
                  !self.inLiveResize else { return }
            self.webView.evaluateJavaScript(Self.unfreezeLayoutScript, completionHandler: nil)
        }
        unfreezeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func attachWebView() {
        guard webView.superview !== self else { return }

        revealFallbackWorkItem?.cancel()
        revealFallbackWorkItem = nil
        unfreezeWorkItem?.cancel()
        unfreezeWorkItem = nil
        revealGeneration += 1

        let previousSize = webView.frame.size
        let sourceSize = (previousSize.width > 10 && previousSize.height > 10) ? previousSize : nil
        pendingAttachSourceSize = sourceSize

        showCoverImmediately()

        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.wantsLayer = true
        webView.alphaValue = 1.0
        addSubview(webView)

        coverView.removeFromSuperview()
        addSubview(coverView, positioned: .above, relativeTo: webView)

        lastBoundsSize = bounds.size
        if bounds.width > 10 && bounds.height > 10 {
            pendingAttachSourceSize = nil
            hideForRelayoutAndSettle(targetSize: bounds.size, sourceSize: sourceSize)
        }
    }

    private func hideForRelayoutAndSettle(targetSize: NSSize, sourceSize: NSSize?) {
        revealFallbackWorkItem?.cancel()
        revealFallbackWorkItem = nil
        unfreezeWorkItem?.cancel()
        unfreezeWorkItem = nil
        revealGeneration += 1
        let generation = revealGeneration
        stableSinceUptime = nil

        showCoverImmediately()
        if coverView.superview !== self && webView.superview === self {
            addSubview(coverView, positioned: .above, relativeTo: webView)
        }
        if webView.alphaValue != 1.0 {
            webView.alphaValue = 1.0
        }
        webView.evaluateJavaScript(Self.freezeLayoutScript, completionHandler: nil)

        let fallback = DispatchWorkItem { [weak self] in
            self?.revealIfNeeded(generation: generation)
        }
        revealFallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: fallback)

        let startUptime = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.pollUntilSettled(
                generation: generation,
                targetSize: targetSize,
                sourceSize: sourceSize,
                startUptime: startUptime,
                attempt: 0,
                lastSignature: nil,
                stableCount: 0
            )
        }
    }

    /// Polls layout signature across bounded IPC round-trips so WebKit flushes layout and paints
    /// new-size `TiledCoreAnimationDrawingArea` tiles underneath the opaque `coverView` while
    /// `webView.alphaValue == 1.0`. Detects Gemini's `960px` responsive breakpoint directly via
    /// `contentLeft` and finishes finite Web Animations in place, leaving zero idle timers.
    private func pollUntilSettled(
        generation: Int,
        targetSize: NSSize,
        sourceSize: NSSize?,
        startUptime: TimeInterval,
        attempt: Int,
        lastSignature: String?,
        stableCount: Int
    ) {
        guard generation == revealGeneration,
              revealedGeneration != generation,
              webView.superview === self else { return }

        let zoom = webView.pageZoom > 0 ? webView.pageZoom : 1.0
        let expectedW = Int((targetSize.width / zoom).rounded())
        let expectedH = Int((targetSize.height / zoom).rounded())
        let crossesBreakpoint: Bool = {
            guard let src = sourceSize, src.width > 10 else { return false }
            let srcW = Int((src.width / zoom).rounded())
            return (srcW >= 960 && expectedW < 960) || (srcW < 960 && expectedW >= 960)
        }()

        // Synchronous measurements (getBoundingClientRect forces layout at the new viewport
        // size) polled back-to-back; the breakpoint/sidebar/order checks catch Gemini's
        // JS-driven responsive component swaps. In-page timers/rAF are throttled while the
        // window is fading in, so waiting inside the page would only add latency.
        webView.evaluateJavaScript(Self.layoutSignatureScript) { [weak self] result, error in
            guard let self = self,
                  generation == self.revealGeneration,
                  self.revealedGeneration != generation,
                  self.webView.superview === self else { return }

            let nowElapsed = ProcessInfo.processInfo.systemUptime - startUptime
            let nextSignature: String?
            let stable: Int

            if error == nil, let signature = result as? String {
                let parts = signature.split(separator: ",").prefix(6).compactMap {
                    Double($0).map { Int($0.rounded()) }
                }
                let w = parts.count > 0 ? parts[0] : 0
                let h = parts.count > 1 ? parts[1] : 0
                let sidenavOpen = parts.count > 2 ? parts[2] : 0
                let contentLeft = parts.count > 3 ? parts[3] : -1

                let sizeMatched = parts.count >= 4 && abs(w - expectedW) <= 12 && abs(h - expectedH) <= 12
                let orderOK = parts.count > 4 ? parts[4] == 1 : true
                let pageVisible = parts.count > 5 ? parts[5] == 1 : true
                let sidebarReady = !(self.window is NSPanel) || sidenavOpen == 0 || nowElapsed >= 1.0
                let breakpointReady: Bool = {
                    guard crossesBreakpoint else { return true }
                    if expectedW < 960 {
                        return (contentLeft >= 0 && contentLeft <= 12 && sidenavOpen == 0) || nowElapsed >= 1.0
                    } else {
                        return (contentLeft >= 36) || nowElapsed >= 1.0
                    }
                }()

                if sizeMatched && sidebarReady && breakpointReady && (orderOK || nowElapsed >= 1.0) && pageVisible && signature == lastSignature {
                    // Identical measurements held for a short wall-clock window once the
                    // page reports visible: catches the late header/placeholder updates
                    // Gemini applies a beat after the main swap (its timers are throttled
                    // until the page becomes visible again).
                    let now = ProcessInfo.processInfo.systemUptime
                    if self.stableSinceUptime == nil { self.stableSinceUptime = now }
                    stable = (now - (self.stableSinceUptime ?? now)) >= 0.12 ? 2 : 1
                } else {
                    self.stableSinceUptime = nil
                    stable = 0
                }
                nextSignature = signature
            } else {
                stable = 0
                nextSignature = nil
            }

            // Under heavy system load layout can lag; only force a reveal well past the
            // normal settle so an intermediate layout is never exposed.
            if stable >= 2 || nowElapsed >= 1.4 || attempt >= 80 {
                self.revealIfNeeded(generation: generation)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.pollUntilSettled(
                    generation: generation,
                    targetSize: targetSize,
                    sourceSize: sourceSize,
                    startUptime: startUptime,
                    attempt: attempt + 1,
                    lastSignature: nextSignature,
                    stableCount: stable
                )
            }
        }
    }

    private func revealIfNeeded(generation: Int) {
        guard generation == revealGeneration,
              revealedGeneration != generation,
              webView.superview === self else { return }
        revealedGeneration = generation
        revealFallbackWorkItem?.cancel()
        revealFallbackWorkItem = nil
        webView.evaluateJavaScript(Self.unfreezeLayoutScript, completionHandler: nil)
        fadeInWebView(generation: generation)
    }

    private func fadeInWebView(generation: Int) {
        NSAnimationContext.runAnimationGroup({ ctx in
            // Slightly longer dissolve when cross-fading from the blurred snapshot so it
            // reads as a focus pull; flat covers keep the quick 0.14s fade.
            ctx.duration = snapshotLayer.isHidden ? 0.14 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            coverView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, generation == self.revealGeneration else { return }
            self.coverView.isHidden = true
            self.applySnapshot(nil)   // release the bitmap
        })
    }

    static let layoutSignatureScript = #"""
    (function() {
        if (document.getAnimations) {
            var anims = document.getAnimations();
            for (var aIdx = 0; aIdx < anims.length; aIdx++) {
                var anim = anims[aIdx];
                if (anim.effect && anim.effect.getComputedTiming && anim.effect.getComputedTiming().iterations === Infinity) continue;
                try { anim.finish(); } catch (e) {}
            }
        }
        var narrow = window.innerWidth < 960;
        // Only count a drawer that actually covers part of the viewport.
        var navEls = document.querySelectorAll(
            narrow
                ? 'mat-sidenav.mat-drawer-opened, .mat-drawer.mat-drawer-opened, bard-sidenav[expanded], side-navigation-v2 .expanded'
                : 'mat-sidenav.mat-drawer-over.mat-drawer-opened, .mat-drawer-over.mat-drawer-opened'
        );
        var sidenavOpen = 0;
        for (var n = 0; n < navEls.length; n++) {
            var nr = navEls[n].getBoundingClientRect();
            if (nr.width > 40 && nr.right > 40 && nr.left < window.innerWidth - 40) { sidenavOpen = 1; break; }
        }
        var contentEl = document.querySelector('bard-sidenav-content') || document.querySelector('chat-window') || document.querySelector('input-container');
        var contentLeft = contentEl ? Math.round(contentEl.getBoundingClientRect().left) : -1;
        var sel = ['input-container', '.input-area-container', 'rich-textarea', 'bard-mode-switcher', 'chat-window', '.conversation-container', 'bard-sidenav', 'side-navigation-v2', '.zero-state-container', 'h1', '.suggestion-block-container'];
        // Gemini briefly renders the prompt box above the hero while it swaps
        // responsive components; treat that as not settled.
        var inp = document.querySelector('input-container');
        // The zero-state greeting is the tallest visible heading.
        var hero = null, heroH = 0;
        var heads = document.querySelectorAll('h1, h2');
        for (var hi = 0; hi < heads.length; hi++) {
            var hh = heads[hi].getBoundingClientRect().height;
            if (hh > heroH && hh >= 28) { heroH = hh; hero = heads[hi]; }
        }
        var orderOK = 1;
        if (inp && hero) {
            var ir = inp.getBoundingClientRect(), hr = hero.getBoundingClientRect();
            if (ir.height > 0 && hr.height > 0 && ir.top < hr.top) orderOK = 0;
        }
        var out = [window.innerWidth, window.innerHeight, sidenavOpen, contentLeft, orderOK, document.hidden ? 0 : 1];
        for (var i = 0; i < sel.length; i++) {
            var el = document.querySelector(sel[i]);
            if (el) {
                var r = el.getBoundingClientRect();
                out.push(Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height));
            } else {
                out.push(-1);
            }
        }
        return out.join(',');
    })();
    """#


    private static let unfreezeLayoutScript = #"""
    (function() {
        document.documentElement.classList.remove('gd-noanim');
        var st = document.getElementById('gd-noanim-style');
        if (st) st.remove();
        if (document.getAnimations) {
            var anims = document.getAnimations();
            for (var i = 0; i < anims.length; i++) {
                var a = anims[i];
                if (a.effect && a.effect.getComputedTiming && a.effect.getComputedTiming().iterations === Infinity) continue;
                try { a.finish(); } catch (e) {}
            }
        }
    })();
    """#

    static let freezeLayoutScript = #"""
    (function() {
        if (!document.getElementById('gd-noanim-style')) {
            var st = document.createElement('style');
            st.id = 'gd-noanim-style';
            st.textContent = 'html.gd-noanim chat-window, html.gd-noanim chat-window-content, html.gd-noanim .conversation-container,' +
              'html.gd-noanim input-container, html.gd-noanim .input-area-container, html.gd-noanim input-area-v2, html.gd-noanim rich-textarea,' +
              'html.gd-noanim bard-mode-switcher, html.gd-noanim bard-mode-switcher *,' +
              'html.gd-noanim .zero-state-container, html.gd-noanim .zero-state-container *, html.gd-noanim modular-zero-state, html.gd-noanim zero-state,' +
              'html.gd-noanim zero-state-suggestions, html.gd-noanim zero-state-suggestions *, html.gd-noanim .static-sparkle-container,' +
              'html.gd-noanim .lm-fade-in-up-animation, html.gd-noanim .fade-in-animation, html.gd-noanim h1,' +
              'html.gd-noanim user-query, html.gd-noanim model-response,' +
              'html.gd-noanim .mat-drawer, html.gd-noanim .mat-drawer-content, html.gd-noanim .mat-drawer-backdrop,' +
              'html.gd-noanim bard-sidenav, html.gd-noanim bard-sidenav *, html.gd-noanim side-navigation-v2, html.gd-noanim side-navigation-v2 * ' +
              '{ transition-duration: 0s !important; transition-delay: 0s !important; animation-duration: 1ms !important; animation-delay: 0s !important; }';
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

// MARK: - Transition snapshot
//  One-shot, blurred snapshot of the web content taken right before the web view
//  moves between Quick Chat and the main window. The receiving container shows it
//  under its opaque cover so the hand-off reads as a soft "focus pull" (blurred old
//  content dissolving into the sharp, fully laid-out page) instead of a blank flash.
//  The page's responsive relayout always happens underneath and is never visible.
//
//  Cost: a single nominal-resolution capture of our own window plus a GPU blur at
//  1/4 scale (~a few ms), only at transition time. Nothing runs while idle.
//


enum TransitionSnapshot {
    private static var pending: (image: CGImage, time: TimeInterval)?
    private static let maxAge: TimeInterval = 1.5
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Captures `webView`'s on-screen pixels from its current window (ours, so no
    /// Screen Recording permission is involved) and stores a blurred copy.
    static func capture(webView: WKWebView) {
        guard let window = webView.window,
              window.isVisible,
              window.occlusionState.contains(.visible),
              window.windowNumber > 0,
              webView.bounds.width > 10, webView.bounds.height > 10 else { return }

        guard let raw = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .nominalResolution]
        ) else { return }

        // Window-relative rect of the web view (bottom-left origin == Core Image space).
        let scale = CGFloat(raw.width) / max(window.frame.width, 1)
        let r = webView.convert(webView.bounds, to: nil)
        let crop = CGRect(x: r.minX * scale, y: r.minY * scale,
                          width: r.width * scale, height: r.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
        guard !crop.isEmpty else { return }

        let downscale: CGFloat = 0.25
        let image = CIImage(cgImage: raw)
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: downscale, y: downscale))
        let extent = image.extent
        let blurred = image
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 9)
            .cropped(to: extent)
        guard let out = context.createCGImage(blurred, from: extent) else { return }
        pending = (out, ProcessInfo.processInfo.systemUptime)
    }

    /// Returns the pending snapshot (if still fresh) and clears it.
    static func consume() -> CGImage? {
        defer { pending = nil }
        guard let p = pending,
              ProcessInfo.processInfo.systemUptime - p.time <= maxAge else { return nil }
        return p.image
    }
}
