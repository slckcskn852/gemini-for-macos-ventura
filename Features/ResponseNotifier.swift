//
//  ResponseNotifier.swift
//  GeminiDesktop
//
//  Posts a macOS notification when Gemini finishes a response while you're
//  working in another app (WKWebView can't show web notifications itself).
//

import AppKit
import UserNotifications
import WebKit

final class ResponseNotifier: NSObject, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    static let shared = ResponseNotifier()
    static let messageHandlerName = "geminiDesktop"

    /// Decides whether the user is currently looking at Gemini (set by the coordinator).
    var isGeminiVisibleToUser: () -> Bool = { NSApp.isActive }
    var onNotificationClicked: (() -> Void)?

    private var didRequestAuthorization = false

    /// UNUserNotificationCenter crashes when the binary isn't inside an .app bundle
    /// (e.g. `swift run`), so only use it when we have a proper bundle.
    private var canUseNotifications: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: UserDefaultsKeys.notifyOnResponse.rawValue) as? Bool ?? true
    }

    func activate() {
        guard canUseNotifications else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard canUseNotifications, !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              type == "responseFinished" else { return }
        let preview = (body["preview"] as? String) ?? ""
        DispatchQueue.main.async {
            self.handleResponseFinished(preview: preview)
        }
    }

    private func handleResponseFinished(preview: String) {
        guard Self.isEnabled, canUseNotifications, !isGeminiVisibleToUser() else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = "Gemini responded"
        content.body = preview.isEmpty ? "Your response is ready." : preview
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.onNotificationClicked?() }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
