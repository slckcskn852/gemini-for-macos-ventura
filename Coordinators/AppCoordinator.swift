//
//  AppCoordinator.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit
import WebKit
import Combine

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    private var chatBar: ChatBarPanel?
    let webViewModel = WebViewModel()

    var openWindowAction: ((String) -> Void)?
    @Published var alwaysOnTop: Bool = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTop.rawValue)

    var canGoBack: Bool { webViewModel.canGoBack }
    var canGoForward: Bool { webViewModel.canGoForward }

    /// The last app the user worked in before switching to Gemini — used for
    /// "Ask About Active Window".
    private(set) var lastExternalApp: NSRunningApplication?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Re-publish web view state changes so SwiftUI views observing the coordinator update.
        webViewModel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Observe notifications for window opening
        NotificationCenter.default.addObserver(forName: .openMainWindow, object: nil, queue: .main) { [weak self] _ in
            self?.openMainWindow()
        }

        // Track the front-most app that isn't us.
        lastExternalApp = Self.frontmostExternalApp()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.lastExternalApp = app
        }

        ResponseNotifier.shared.isGeminiVisibleToUser = { [weak self] in
            self?.isGeminiVisibleToUser ?? false
        }
        ResponseNotifier.shared.onNotificationClicked = { [weak self] in
            self?.openMainWindow()
        }
    }

    private static func frontmostExternalApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    // MARK: - Global shortcuts

    func handle(_ action: HotKeyAction) {
        switch action {
        case .toggleChatBar: toggleChatBar()
        case .openMainWindow: openMainWindow()
        case .shareWindow: shareContext(.window(pid: lastExternalApp?.processIdentifier))
        case .shareArea: shareContext(.area)
        case .voiceInput: startVoiceInput()
        }
    }

    // MARK: - Navigation

    func goBack() { webViewModel.goBack() }
    func goForward() { webViewModel.goForward() }
    func goHome() { webViewModel.loadHome() }
    func reload() { webViewModel.reload() }
    func openNewChat() { webViewModel.openNewChat() }

    // MARK: - Zoom

    func zoomIn() { webViewModel.zoomIn() }
    func zoomOut() { webViewModel.zoomOut() }
    func resetZoom() { webViewModel.resetZoom() }

    // MARK: - Always on Top

    func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        UserDefaults.standard.set(alwaysOnTop, forKey: UserDefaultsKeys.alwaysOnTop.rawValue)
        applyAlwaysOnTop()
    }

    func applyAlwaysOnTop() {
        let level: NSWindow.Level = alwaysOnTop ? .floating : .normal

        // Apply to main window
        if let mainWindow = findMainWindow() {
            mainWindow.level = level
        }

        // Chat bar panel is always floating by design
    }

    // MARK: - Visibility

    var isChatBarVisible: Bool { chatBar?.isVisible == true }

    var isMainWindowVisible: Bool { findMainWindow()?.isVisible == true }

    /// True when the user can currently see a Gemini surface.
    var isGeminiVisibleToUser: Bool {
        if isChatBarVisible { return true }
        if let main = findMainWindow(), main.isVisible, NSApp.isActive,
           main.occlusionState.contains(.visible) {
            return true
        }
        return false
    }

    /// Makes sure a Gemini surface is visible (keeps the main window if it's
    /// already up, otherwise shows the quick chat bar), then runs `then`.
    func revealGemini(preferMain: Bool = false, then: (() -> Void)? = nil) {
        if preferMain || isMainWindowVisible {
            openMainWindow()
        } else {
            showChatBar()
        }
        // Give the shared WKWebView a moment to re-attach to the new window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { then?() }
    }

    // MARK: - Screen context, voice & prompts

    /// Captures screen context and attaches it to the prompt.
    func shareContext(_ mode: ScreenCapture.Mode) {
        guard ScreenCapture.ensurePermission() else { return }

        let preferMain = isMainWindowVisible && NSApp.isActive
        // Keep our own UI out of the screenshot.
        hideChatBar()
        if case .window = mode {} else if preferMain {
            findMainWindow()?.orderOut(nil)
        }

        // Small delay so the hidden windows are gone before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            ScreenCapture.capture(mode) { [weak self] png in
                guard let self = self else { return }
                guard let png = png else {
                    self.revealGemini(preferMain: preferMain)
                    return
                }
                self.revealGemini(preferMain: preferMain) {
                    PromptInjector.attachImage(png, into: self.webViewModel.wkWebView)
                }
            }
        }
    }

    /// Opens Gemini and starts voice input.
    func startVoiceInput() {
        revealGemini {
            PromptInjector.startVoiceInput(in: self.webViewModel.wkWebView)
        }
    }

    /// Puts text in the prompt box (optionally in a fresh chat) and optionally sends it.
    func ask(_ text: String, submit: Bool = false, newChat: Bool = false) {
        revealGemini {
            let webView = self.webViewModel.wkWebView
            let insert = { PromptInjector.insertText(text, into: webView, submit: submit) }
            if newChat {
                PromptInjector.newChat(in: webView) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: insert)
                }
            } else {
                insert()
            }
        }
    }

    // MARK: - Chat Bar

    func showChatBar() {
        // Hide main window when showing chat bar
        closeMainWindow()

        let position = PanelPosition.current

        if let bar = chatBar {
            // Reposition unless "Remember last position" is selected
            if position != .rememberLast {
                positionChatBar(bar, position: position)
            }
            NSApp.activate(ignoringOtherApps: true)
            animateIn(bar)
            bar.checkAndAdjustSize()
            return
        }

        let contentView = ChatBarView(
            webView: webViewModel.wkWebView,
            coordinator: self,
            onExpandToMain: { [weak self] in
                self?.expandToMainWindow()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        let bar = ChatBarPanel(contentView: hostingView)

        // Position based on setting
        positionChatBar(bar, position: position)

        NSApp.activate(ignoringOtherApps: true)
        animateIn(bar)
        chatBar = bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { bar.checkAndAdjustSize() }
    }

    /// Positions the chat bar based on the given position setting
    private func positionChatBar(_ bar: ChatBarPanel, position: PanelPosition) {
        guard let screen = NSScreen.screenAtMouseLocation() ?? NSScreen.main else { return }

        if position == .rememberLast {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: UserDefaultsKeys.panelX.rawValue) != nil,
               defaults.object(forKey: UserDefaultsKeys.panelY.rawValue) != nil {
                let saved = NSPoint(x: defaults.double(forKey: UserDefaultsKeys.panelX.rawValue),
                                    y: defaults.double(forKey: UserDefaultsKeys.panelY.rawValue))
                let center = NSPoint(x: saved.x + bar.frame.width / 2, y: saved.y + bar.frame.height / 2)
                if NSScreen.screenStrictly(containing: center) != nil {
                    bar.setFrameOrigin(saved)
                    return
                }
            }
        }

        let origin = screen.point(for: bar.frame.size, position: position, dockOffset: Constants.dockOffset)
        bar.setFrameOrigin(origin)
    }

    /// Repositions the chat bar to its configured position
    func resetChatBarPosition() {
        guard let bar = chatBar else { return }
        positionChatBar(bar, position: PanelPosition.current)
    }

    func hideChatBar() {
        chatBar?.orderOut(nil)
    }

    /// Fades out Quick Chat (used for the toggle shortcut).
    func hideChatBarAnimated() {
        guard let bar = chatBar, bar.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            bar.animator().alphaValue = 0
        }, completionHandler: {
            bar.orderOut(nil)
            bar.alphaValue = 1
        })
    }

    /// Spotlight-style entrance: fade in while dropping a few points into place.
    private func animateIn(_ window: NSWindow, offset: CGFloat = 10) {
        let target = window.frame
        window.alphaValue = 0
        window.setFrame(target.offsetBy(dx: 0, dy: offset), display: false)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            window.animator().alphaValue = 1
            window.animator().setFrame(target, display: true)
        }
    }

    func closeMainWindow() {
        // Find and hide the main window
        for window in NSApp.windows {
            if window.identifier?.rawValue == Constants.mainWindowIdentifier || window.title == Constants.mainWindowTitle {
                if !(window is NSPanel) {
                    window.orderOut(nil)
                }
            }
        }
    }

    func toggleChatBar() {
        if let bar = chatBar, bar.isVisible {
            hideChatBarAnimated()
        } else {
            showChatBar()
        }
    }

    func expandToMainWindow() {
        // Capture the screen where the chat bar is located before hiding it
        let targetScreen = chatBar.flatMap { bar -> NSScreen? in
            let center = NSPoint(x: bar.frame.midX, y: bar.frame.midY)
            return NSScreen.screen(containing: center)
        } ?? NSScreen.main

        hideChatBar()
        openMainWindow(on: targetScreen)
    }

    func openMainWindow(on targetScreen: NSScreen? = nil) {
        // Hide chat bar first - WebView can only be in one view hierarchy
        hideChatBar()

        let hideDockIcon = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hideDockIcon.rawValue)
        if !hideDockIcon {
            NSApp.setActivationPolicy(.regular)
        }

        // Find existing main window (may be hidden/suppressed)
        let mainWindow = findMainWindow()

        if let window = mainWindow {
            // Window exists - show it (works for suppressed windows too)
            if let screen = targetScreen {
                centerWindow(window, on: screen)
            }
            if window.isVisible {
                window.makeKeyAndOrderFront(nil)
            } else {
                animateIn(window, offset: 0)
            }
        } else if let openWindowAction = openWindowAction {
            // Window doesn't exist yet - use SwiftUI openWindow to create it
            openWindowAction("main")
            // Position newly created window with retry mechanism
            if let screen = targetScreen {
                centerNewlyCreatedWindow(on: screen)
            }
        }

        applyAlwaysOnTop()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the Settings window on every supported macOS version.
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // Prefer the app menu's own "Settings…" item; works on macOS 13 and later.
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
            appMenu.performActionForItem(at: index)
            return
        }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Finds the main window by identifier or title
    private func findMainWindow() -> NSWindow? {
        NSApp.windows.first {
            !($0 is NSPanel) &&
            ($0.identifier?.rawValue == Constants.mainWindowIdentifier || $0.title == Constants.mainWindowTitle)
        }
    }

    /// Centers a window on the specified screen
    private func centerWindow(_ window: NSWindow, on screen: NSScreen) {
        let origin = screen.centerPoint(for: window.frame.size)
        window.setFrameOrigin(origin)
    }

    /// Centers a newly created window on the target screen with retry mechanism
    private func centerNewlyCreatedWindow(on screen: NSScreen, attempt: Int = 1) {
        let maxAttempts = 5
        let retryDelay = 0.05 // 50ms between attempts

        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self = self else { return }

            if let window = self.findMainWindow() {
                self.centerWindow(window, on: screen)
                self.applyAlwaysOnTop()
            } else if attempt < maxAttempts {
                // Window not found yet, retry
                self.centerNewlyCreatedWindow(on: screen, attempt: attempt + 1)
            }
        }
    }
}


extension AppCoordinator {

    struct Constants {
        static let dockOffset: CGFloat = 50
        static let mainWindowIdentifier = "main"
        static let mainWindowTitle = "Gemini Desktop"
    }

}
