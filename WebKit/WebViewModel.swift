//
//  WebViewModel.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-15.
//

import WebKit
import Combine

/// Handles console.log messages from JavaScript
class ConsoleLogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String {
            print("[WebView] \(body)")
        }
    }
}

/// Observable wrapper around WKWebView with Gemini-specific functionality
final class WebViewModel: ObservableObject {

    // MARK: - Constants

    static let geminiURL = URL(string: "https://gemini.google.com/app")!
    static let defaultPageZoom: Double = 1.0

    private static let geminiHost = "gemini.google.com"
    private static let geminiAppPath = "/app"
    private static var userAgent: String { UserAgentOption.currentUserAgentString }
    private static let minZoom: Double = 0.6
    private static let maxZoom: Double = 1.4

    // MARK: - Public Properties

    let wkWebView: WKWebView
    var onPageLoaded: (() -> Void)?
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    @Published private(set) var isAtHome: Bool = true
    @Published private(set) var isLoading: Bool = true

    // MARK: - Private Properties

    private var backObserver: NSKeyValueObservation?
    private var forwardObserver: NSKeyValueObservation?
    private var urlObserver: NSKeyValueObservation?
    private var loadingObserver: NSKeyValueObservation?
    private var lastBackgroundedState: Bool?
    private let consoleLogHandler = ConsoleLogHandler()

    // MARK: - Initialization

    init() {
        self.wkWebView = Self.createWebView(consoleLogHandler: consoleLogHandler)
        setupObservers()
        loadHome()
    }

    // MARK: - Navigation

    func loadHome() {
        if !isAtHome { isAtHome = true }
        if canGoBack { canGoBack = false }
        wkWebView.load(URLRequest(url: Self.geminiURL))
    }

    func goBack() {
        if isAtHome { isAtHome = false }
        wkWebView.goBack()
    }

    func goForward() {
        wkWebView.goForward()
    }

    func reload() {
        wkWebView.reload()
    }

    func openNewChat() {
        PromptInjector.newChat(in: wkWebView)
    }

    // MARK: - Zoom

    func zoomIn() {
        let newZoom = min((wkWebView.pageZoom * 100 + 5).rounded() / 100, Self.maxZoom)
        setZoom(newZoom)
    }

    func zoomOut() {
        let newZoom = max((wkWebView.pageZoom * 100 - 5).rounded() / 100, Self.minZoom)
        setZoom(newZoom)
    }

    func resetZoom() {
        setZoom(Self.defaultPageZoom)
    }

    private func setZoom(_ zoom: Double) {
        wkWebView.pageZoom = zoom
        UserDefaults.standard.set(zoom, forKey: UserDefaultsKeys.pageZoom.rawValue)
    }

    func applyUserAgent() {
        let newUA = Self.userAgent
        guard wkWebView.customUserAgent != newUA else { return }
        wkWebView.customUserAgent = newUA
        wkWebView.reload()
    }

    // MARK: - Lifecycle Power Management

    private static let pauseAnimationsScript = """
        (function() {
            if (!document.getElementById('gd-bg-pause')) {
                var root = document.head || document.documentElement;
                if (!root) return;
                var st = document.createElement('style');
                st.id = 'gd-bg-pause';
                st.textContent = '*, *::before, *::after { animation-play-state: paused !important; transition: none !important; }';
                root.appendChild(st);
            }
        })();
        """

    private static let resumeAnimationsScript = """
        (function() {
            var el = document.getElementById('gd-bg-pause');
            if (el) el.remove();
        })();
        """

    /// Pauses all CSS animations/transitions while no Gemini window is visible or unoccluded,
    /// without blocking background network streaming or `ResponseNotifier`.
    func setPageBackgrounded(_ backgrounded: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setPageBackgrounded(backgrounded)
            }
            return
        }
        guard lastBackgroundedState != backgrounded else { return }
        lastBackgroundedState = backgrounded
        wkWebView.evaluateJavaScript(
            backgrounded ? Self.pauseAnimationsScript : Self.resumeAnimationsScript,
            completionHandler: nil
        )
    }

    // MARK: - Private Setup

    private static func createWebView(consoleLogHandler: ConsoleLogHandler) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Add user scripts
        for script in UserScripts.createAllScripts() {
            configuration.userContentController.addUserScript(script)
        }

        // Bridge for "response finished" notifications
        configuration.userContentController.add(ResponseNotifier.shared, name: ResponseNotifier.messageHandlerName)

        // Register console log message handler (debug only)
        #if DEBUG
        configuration.userContentController.add(consoleLogHandler, name: UserScripts.consoleLogHandler)
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.allowsMagnification = true
        webView.customUserAgent = userAgent

        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        let savedZoom = UserDefaults.standard.double(forKey: UserDefaultsKeys.pageZoom.rawValue)
        webView.pageZoom = savedZoom > 0 ? savedZoom : defaultPageZoom

        return webView
    }

    private func setupObservers() {
        backObserver = wkWebView.observe(\.canGoBack, options: [.new, .initial]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let newCanGoBack = !self.isAtHome && webView.canGoBack
                if self.canGoBack != newCanGoBack {
                    self.canGoBack = newCanGoBack
                }
            }
        }

        forwardObserver = wkWebView.observe(\.canGoForward, options: [.new, .initial]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let newCanGoForward = webView.canGoForward
                if self.canGoForward != newCanGoForward {
                    self.canGoForward = newCanGoForward
                }
            }
        }

        loadingObserver = wkWebView.observe(\.isLoading, options: [.new, .initial]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let newIsLoading = webView.isLoading
                if self.isLoading != newIsLoading {
                    self.isLoading = newIsLoading
                    if !newIsLoading {
                        self.lastBackgroundedState = nil
                        self.onPageLoaded?()
                    }
                }
            }
        }

        urlObserver = wkWebView.observe(\.url, options: .new) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let currentURL = webView.url else { return }

                let isGeminiApp = currentURL.host == Self.geminiHost &&
                                  currentURL.path.hasPrefix(Self.geminiAppPath)

                if self.isAtHome != isGeminiApp {
                    self.isAtHome = isGeminiApp
                }
                let newCanGoBack = isGeminiApp ? false : webView.canGoBack
                if self.canGoBack != newCanGoBack {
                    self.canGoBack = newCanGoBack
                }
            }
        }
    }
}
