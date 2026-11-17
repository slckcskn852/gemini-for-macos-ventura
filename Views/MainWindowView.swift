//
//  MainWindowContent.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit

struct MainWindowView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            GeminiWebView(webView: coordinator.webViewModel.wkWebView)

            if coordinator.webViewModel.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            }
        }
            .onAppear {
                coordinator.openWindowAction = { id in
                    openWindow(id: id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        coordinator.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Back")
                    .opacity(coordinator.canGoBack ? 1 : 0)
                    .disabled(!coordinator.canGoBack)
                }

                ToolbarItem(placement: .principal) {
                    Spacer()
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            coordinator.shareContext(.window(pid: coordinator.lastExternalApp?.processIdentifier))
                        } label: {
                            Label(shareWindowTitle, systemImage: "macwindow.on.rectangle")
                        }
                        Button {
                            coordinator.shareContext(.area)
                        } label: {
                            Label("Share Screen Area…", systemImage: "rectangle.dashed")
                        }
                        Button {
                            coordinator.shareContext(.screen)
                        } label: {
                            Label("Share Entire Screen", systemImage: "display")
                        }
                        Divider()
                        Button {
                            coordinator.startVoiceInput()
                        } label: {
                            Label("Talk to Gemini", systemImage: "mic")
                        }
                    } label: {
                        Image(systemName: "plus.viewfinder")
                    }
                    .help("Share your screen or talk to Gemini")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        coordinator.openNewChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New Chat (⌘N)")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        minimizeToPrompt()
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                    .help("Minimize to Quick Chat")
                }
            }
    }

    private var shareWindowTitle: String {
        if let name = coordinator.lastExternalApp?.localizedName {
            return "Share \(name) Window"
        }
        return "Share Active Window"
    }

    private func minimizeToPrompt() {
        // Close main window and show chat bar
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == AppCoordinator.Constants.mainWindowIdentifier || $0.title == AppCoordinator.Constants.mainWindowTitle }) {
            if !(window is NSPanel) {
                window.orderOut(nil)
            }
        }
        coordinator.showChatBar()
    }
}
