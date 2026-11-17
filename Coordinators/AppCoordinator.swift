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
    private var notificationObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var visibilityUpdatePending = false
    private var pendingMainRevealWork: DispatchWorkItem?
    private var isHidingChatBar = false
    private var chatBarFadeGeneration: UInt = 0

    private init() {
        // Re-publish web view state changes so SwiftUI views observing the coordinator update.
        webViewModel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        webViewModel.onPageLoaded = { [weak self] in
            self?.scheduleVisibilityUpdate()
        }

        // Observe notifications for window opening
        let openObserver = NotificationCenter.default.addObserver(forName: .openMainWindow, object: nil, queue: .main) { [weak self] _ in
            self?.openMainWindow()
        }
        notificationObservers.append((.default, openObserver))

        // Pause WebKit CSS animations whenever no Gemini window is visible/unoccluded.
        let visibilityNotifications: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        for name in visibilityNotifications {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self = self else { return }
                if name == NSApplication.didHideNotification {
                    self.pendingMainRevealWork?.cancel()
                    self.pendingMainRevealWork = nil
                } else if name == NSWindow.willCloseNotification,
                          let window = note.object as? NSWindow,
                          self.isMainWindow(window) {
                    self.pendingMainRevealWork?.cancel()
                    self.pendingMainRevealWork = nil
                }
                self.scheduleVisibilityUpdate()
            }
            notificationObservers.append((.default, observer))
        }

        // Track the front-most app that isn't us.
        lastExternalApp = Self.frontmostExternalApp()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let appObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.lastExternalApp = app
        }
        notificationObservers.append((workspaceCenter, appObserver))

        ResponseNotifier.shared.isGeminiVisibleToUser = { [weak self] in
            self?.isGeminiVisibleToUser ?? false
        }
        ResponseNotifier.shared.onNotificationClicked = { [weak self] in
            self?.openMainWindow()
        }
    }

    deinit {
        pendingMainRevealWork?.cancel()
        for (center, observer) in notificationObservers {
            center.removeObserver(observer)
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

    /// Coalesces rapid occlusion/window notifications onto the next main runloop turn.
    private func scheduleVisibilityUpdate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleVisibilityUpdate()
            }
            return
        }
        guard !visibilityUpdatePending else { return }
        visibilityUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.visibilityUpdatePending = false
            self.updateWebViewVisibility()
        }
    }

    private func updateWebViewVisibility() {
        let chatVisible = chatBar?.isVisible == true
        let mainWindow = findMainWindow()
        let mainVisible = (mainWindow.map { $0.isVisible && $0.occlusionState.contains(.visible) }) ?? false
        if mainVisible {
            pendingMainRevealWork?.cancel()
            pendingMainRevealWork = nil
        }
        let isVisible = chatVisible || mainVisible || (pendingMainRevealWork != nil && mainWindow?.isVisible != false)
        webViewModel.setPageBackgrounded(!isVisible)
    }

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
        webViewModel.setPageBackgrounded(false)

        let alreadyInChatBar = chatBar?.contentView.map { webViewModel.wkWebView.isDescendant(of: $0) } ?? false
        if !alreadyInChatBar {
            webViewModel.wkWebView.evaluateJavaScript(
                WebViewContainer.freezeLayoutScript + ChatBarPanel.enterQuickChatScript,
                completionHandler: nil
            )
        }

        // Hide main window when showing chat bar
        closeMainWindow()

        let position = PanelPosition.current

        if let bar = chatBar {
            let wasHiding = isHidingChatBar
            // Reposition unless "Remember last position" is selected
            if position != .rememberLast {
                positionChatBar(bar, position: position)
            }
            NSApp.activate(ignoringOtherApps: true)
            if bar.isVisible && !wasHiding {
                bar.makeKeyAndOrderFront(nil)
            } else {
                animateIn(bar, offset: 10, duration: 0.22)
            }
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
        chatBar = bar
        animateIn(bar, offset: 10, duration: 0.22)
        DispatchQueue.main.async { bar.checkAndAdjustSize() }
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
        chatBarFadeGeneration &+= 1
        isHidingChatBar = false
        chatBar?.orderOut(nil)
        chatBar?.alphaValue = 1
        scheduleVisibilityUpdate()
    }

    /// Fades out Quick Chat (used for the toggle shortcut).
    func hideChatBarAnimated() {
        guard let bar = chatBar, bar.isVisible, !isHidingChatBar else { return }
        isHidingChatBar = true
        chatBarFadeGeneration &+= 1
        let generation = chatBarFadeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.chatBarFadeGeneration == generation else { return }
            self.isHidingChatBar = false
            bar.orderOut(nil)
            bar.alphaValue = 1
            self.scheduleVisibilityUpdate()
        })
    }

    /// Spotlight-style entrance: fade in while dropping a few points into place.
    private func animateIn(_ window: NSWindow, offset: CGFloat = 10, duration: TimeInterval = 0.22) {
        if window === chatBar {
            chatBarFadeGeneration &+= 1
            isHidingChatBar = false
        }
        let target = window.frame
        window.alphaValue = 0
        if offset != 0 {
            window.setFrame(target.offsetBy(dx: 0, dy: offset), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            window.animator().alphaValue = 1
            if offset != 0 {
                window.animator().setFrame(target, display: true)
            }
        }
    }

    func closeMainWindow() {
        pendingMainRevealWork?.cancel()
        pendingMainRevealWork = nil
        // Find and hide the main window
        for window in NSApp.windows where isMainWindow(window) {
            window.orderOut(nil)
        }
        scheduleVisibilityUpdate()
    }

    func toggleChatBar() {
        if let bar = chatBar, bar.isVisible, !isHidingChatBar {
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
        webViewModel.setPageBackgrounded(false)

        // Find existing main window (may be hidden/suppressed)
        let mainWindow = findMainWindow()
        let alreadyInMain = mainWindow?.contentView.map { webViewModel.wkWebView.isDescendant(of: $0) } ?? false
        if !alreadyInMain {
            webViewModel.wkWebView.evaluateJavaScript(
                WebViewContainer.freezeLayoutScript + ChatBarPanel.exitQuickChatScript,
                completionHandler: nil
            )
        }

        // Hide chat bar first - WebView can only be in one view hierarchy
        hideChatBar()

        let hideDockIcon = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hideDockIcon.rawValue)
        if !hideDockIcon {
            NSApp.setActivationPolicy(.regular)
        }

        // Guard against the brief ~20ms WindowServer lag before occlusionState flips to .visible.
        if !(mainWindow?.isVisible == true && mainWindow?.occlusionState.contains(.visible) == true) {
            pendingMainRevealWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.pendingMainRevealWork = nil
                self?.scheduleVisibilityUpdate()
            }
            pendingMainRevealWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        if let window = mainWindow {
            // Window exists - show it (works for suppressed windows too)
            if let screen = targetScreen {
                centerWindow(window, on: screen)
            }
            if window.isVisible {
                window.makeKeyAndOrderFront(nil)
            } else {
                animateIn(window, offset: 0, duration: 0.22)
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

    private func isMainWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) &&
        (window.identifier?.rawValue == Constants.mainWindowIdentifier || window.title == Constants.mainWindowTitle)
    }

    /// Finds the main window by identifier or title
    private func findMainWindow() -> NSWindow? {
        NSApp.windows.first(where: isMainWindow)
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
