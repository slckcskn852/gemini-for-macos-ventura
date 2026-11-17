//
//  ChatBarContent.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import WebKit

/// An invisible drag region that initiates window dragging on mouseDown
struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

class WindowDragNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
    }
}

struct ChatBarView: View {
    let webView: WKWebView
    let coordinator: AppCoordinator
    let onExpandToMain: () -> Void

    /// Calculate button offset based on screen height
    /// MacBook Air 13" (~900pt): (-6, -2), 1080p (1080pt): (-4, 0)
    private var buttonOffset: CGSize {
        let screenHeight = NSScreen.main?.frame.height ?? 900
        // Interpolate: 900pt -> (-6, -2), 1080pt -> (-4, 0)
        let t = (screenHeight - 900) / 180  // 0 at 900pt, 1 at 1080pt
        let xOffset = -6.0 + t * 2.0
        let yOffset = -2.0 + t * 2.0
        return CGSize(width: xOffset, height: yOffset)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeminiWebView(webView: webView)

            // Expand button
            Button(action: onExpandToMain) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .offset(buttonOffset)

            // Invisible drag region in the top bar (between Gemini text and PRO badge)
            VStack {
                HStack {
                    Spacer()
                        .frame(width: Constants.dragRegionLeading)
                    WindowDragView()
                        .frame(maxWidth: .infinity, maxHeight: Constants.dragRegionHeight)
                    ContextMenuButton(coordinator: coordinator)
                        .frame(height: Constants.dragRegionHeight)
                    Spacer()
                        .frame(width: Constants.dragRegionTrailing)
                }
                .padding(.top, Constants.dragRegionTopPadding)
                Spacer()
            }
        }
    }

    fileprivate enum Constants {
        static let dragRegionLeading: CGFloat = 160  // skip past expand button + "Gemini" text
        static let dragRegionTrailing: CGFloat = 120  // skip past PRO badge + avatar
        static let dragRegionHeight: CGFloat = 38
        static let dragRegionTopPadding: CGFloat = 16
    }
}

/// "Share screen / talk" button shown in the chat bar's top bar, mirroring the
/// context-sharing controls of Google's official Mac app.
struct ContextMenuButton: View {
    let coordinator: AppCoordinator

    var body: some View {
        Menu {
            Button {
                coordinator.shareContext(.window(pid: coordinator.lastExternalApp?.processIdentifier))
            } label: {
                Label(windowTitle, systemImage: "macwindow.on.rectangle")
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
                .font(.system(size: 14, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .help("Share your screen or talk to Gemini")
    }

    private var windowTitle: String {
        if let name = coordinator.lastExternalApp?.localizedName {
            return "Share \(name) Window"
        }
        return "Share Active Window"
    }
}
