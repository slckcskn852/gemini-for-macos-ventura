//
//  MenuBarContentView.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var hotKeys = HotKeyManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button {
                coordinator.openMainWindow()
            } label: {
                Label(title("Open Gemini Desktop", .openMainWindow), systemImage: "macwindow")
            }

            Button {
                coordinator.toggleChatBar()
            } label: {
                Label(title("Quick Chat", .toggleChatBar), systemImage: "rectangle.bottomthird.inset.filled")
            }

            Divider()

            Button {
                coordinator.shareContext(.window(pid: coordinator.lastExternalApp?.processIdentifier))
            } label: {
                Label(title(windowTitle, .shareWindow), systemImage: "macwindow.on.rectangle")
            }

            Button {
                coordinator.shareContext(.area)
            } label: {
                Label(title("Ask About Screen Area…", .shareArea), systemImage: "rectangle.dashed")
            }

            Button {
                coordinator.startVoiceInput()
            } label: {
                Label(title("Talk to Gemini", .voiceInput), systemImage: "mic")
            }

            Divider()

            Button {
                coordinator.openSettings()
            } label: {
                Label("Settings...", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .onAppear {
            coordinator.openWindowAction = { id in
                openWindow(id: id)
            }
        }
    }

    private var windowTitle: String {
        if let name = coordinator.lastExternalApp?.localizedName {
            return "Ask About \(name) Window"
        }
        return "Ask About Active Window"
    }

    /// Appends the global shortcut (if any) so users can discover it.
    private func title(_ base: String, _ action: HotKeyAction) -> String {
        guard let combo = hotKeys.combo(for: action) else { return base }
        return "\(base)    \(combo.displayString)"
    }
}
