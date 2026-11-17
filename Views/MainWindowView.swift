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
                    .background(Self.loadingSurfaceColor)
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

                ToolbarItem(placement: .navigation) {
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

                ToolbarItem(placement: .navigation) {
                    Button {
                        coordinator.openNewChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New Chat (⌘N)")
                }

                ToolbarItem(placement: .navigation) {
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

    private static let loadingSurfaceColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 19.0 / 255.0, green: 19.0 / 255.0, blue: 20.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 248.0 / 255.0, green: 250.0 / 255.0, blue: 253.0 / 255.0, alpha: 1.0)
    })

    private func minimizeToPrompt() {
        coordinator.showChatBar()
    }
}
