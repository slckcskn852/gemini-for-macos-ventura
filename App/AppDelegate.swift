//
//  AppDelegate.swift
//  GeminiDesktop
//

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = ServicesProvider()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // geminidesktop:// URL scheme (works with Shortcuts, Raycast, Alfred, scripts…)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator.shared

        // System-wide keyboard shortcuts (default: ⌥Space toggles Quick Chat)
        HotKeyManager.shared.onTrigger = { action in
            coordinator.handle(action)
        }
        HotKeyManager.shared.start()

        // "Ask Gemini" in every app's Services / right-click menu
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()

        ResponseNotifier.shared.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Always open main window when dock icon is clicked
        // This handles the case where only the chat bar panel is visible
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep running in the menu bar
    }

    // MARK: - URL scheme

    /// Supported forms:
    ///   geminidesktop://open                 – show the main window
    ///   geminidesktop://chat                 – toggle the quick chat bar
    ///   geminidesktop://new                  – start a new chat
    ///   geminidesktop://ask?q=TEXT[&send=1]  – put TEXT in a new chat (and send it)
    ///   geminidesktop://share?mode=window|area|screen
    ///   geminidesktop://voice                – start voice input
    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let components = URLComponents(string: string) else { return }

        let coordinator = AppCoordinator.shared
        let action = (components.host ?? components.path).lowercased()
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        let flag: (String) -> Bool = { ["1", "true", "yes"].contains(value($0)?.lowercased() ?? "") }

        switch action {
        case "open", "":
            coordinator.openMainWindow()
        case "chat":
            coordinator.toggleChatBar()
        case "new":
            coordinator.revealGemini { coordinator.openNewChat() }
        case "ask":
            let text = value("q") ?? value("text") ?? ""
            if text.isEmpty {
                coordinator.revealGemini()
            } else {
                coordinator.ask(text, submit: flag("send"), newChat: value("new").map { _ in flag("new") } ?? true)
            }
        case "share":
            switch value("mode")?.lowercased() {
            case "area": coordinator.shareContext(.area)
            case "screen": coordinator.shareContext(.screen)
            default: coordinator.shareContext(.window(pid: coordinator.lastExternalApp?.processIdentifier))
            }
        case "voice":
            coordinator.startVoiceInput()
        default:
            coordinator.openMainWindow()
        }
    }
}

/// Implements the "Ask Gemini" macOS Service declared in Info.plist (NSServices).
/// Select text in any app → right-click → Services → Ask Gemini.
final class ServicesProvider: NSObject {
    @objc func askGemini(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }
        DispatchQueue.main.async {
            AppCoordinator.shared.ask("\"\(text)\"\n\n", newChat: true)
        }
    }
}
