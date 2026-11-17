//
//  UserDefaultsKeys.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import Foundation
import AppKit

enum UserDefaultsKeys: String {
    case panelWidth
    case panelHeight
    case pageZoom
    case hideWindowAtLaunch
    case hideDockIcon
    case appTheme
    case userAgentOption
    case customUserAgent
    case panelPosition
    case panelX
    case panelY
    case alwaysOnTop
    case notifyOnResponse
    case hotKeyPrefix = "hotKey."
}

enum AppTheme: String, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    func apply() {
        switch self {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppTheme {
        let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.appTheme.rawValue) ?? "system"
        return AppTheme(rawValue: raw) ?? .system
    }
}

enum UserAgentOption: String, CaseIterable {
    case safari
    case chrome
    case custom

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .custom: return "Custom"
        }
    }

    /// Version of the Safari/WebKit actually installed on this Mac (e.g. "18.6").
    /// Advertising the real engine version keeps Google from serving features
    /// the embedded WebKit can't handle (important on older macOS releases).
    static let installedSafariVersion: String = {
        let plist = "/Applications/Safari.app/Contents/Info.plist"
        if let dict = NSDictionary(contentsOfFile: plist),
           let version = dict["CFBundleShortVersionString"] as? String {
            let parts = version.split(separator: ".").prefix(2)
            if !parts.isEmpty { return parts.joined(separator: ".") }
        }
        return "18.0"
    }()

    /// A Chrome major version that tracks Chrome's 4-week release cadence so
    /// the string never goes stale (Chrome 132 shipped 2025-01-14).
    static let estimatedChromeMajor: Int = {
        var components = DateComponents()
        components.year = 2025; components.month = 1; components.day = 14
        guard let anchor = Calendar(identifier: .gregorian).date(from: components) else { return 140 }
        let days = Date().timeIntervalSince(anchor) / 86_400
        // Stay one release behind stable to be conservative.
        return max(132, 132 + Int(days / 28) - 1)
    }()

    // Real Safari always reports "Intel Mac OS X 10_15_7", even on Apple Silicon.
    static var safariUA: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(installedSafariVersion) Safari/605.1.15"
    }
    static var chromeUA: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(estimatedChromeMajor).0.0.0 Safari/537.36"
    }

    func userAgentString(custom: String = "") -> String {
        switch self {
        case .safari: return Self.safariUA
        case .chrome: return Self.chromeUA
        case .custom: return custom.isEmpty ? Self.safariUA : custom
        }
    }

    func settingsDescription(custom: String = "") -> String {
        switch self {
        case .safari: return "Identifies as Safari \(Self.installedSafariVersion) (the WebKit version installed on this Mac). Recommended."
        case .chrome: return "Identifies as Chrome \(Self.estimatedChromeMajor) on macOS. May unlock web features WebKit can't run."
        case .custom: return custom.isEmpty ? "No custom user agent set — falls back to Safari" : "Using custom user agent string"
        }
    }

    static var current: UserAgentOption {
        let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.userAgentOption.rawValue) ?? "safari"
        return UserAgentOption(rawValue: raw) ?? .safari
    }

    static var currentUserAgentString: String {
        let option = current
        let custom = UserDefaults.standard.string(forKey: UserDefaultsKeys.customUserAgent.rawValue) ?? ""
        return option.userAgentString(custom: custom)
    }
}

enum PanelPosition: String, CaseIterable {
    case topCenter
    case bottomLeft
    case bottomCenter
    case bottomRight
    case rememberLast

    var displayName: String {
        switch self {
        case .topCenter: return "Top Center (Spotlight-style)"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        case .rememberLast: return "Remember Last Position"
        }
    }

    static var current: PanelPosition {
        let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.panelPosition.rawValue) ?? "topCenter"
        return PanelPosition(rawValue: raw) ?? .topCenter
    }
}
