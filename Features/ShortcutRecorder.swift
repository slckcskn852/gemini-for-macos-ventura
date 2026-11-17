//
//  ShortcutRecorder.swift
//  GeminiDesktop
//
//  A small SwiftUI shortcut recorder (click, then press the key combination).
//

import SwiftUI
import AppKit

struct ShortcutRecorder: View {
    let action: HotKeyAction
    @ObservedObject private var manager = HotKeyManager.shared
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if manager.failed.contains(action) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help("This shortcut is already used by macOS or another app. Choose a different one.")
            }

            Button(action: toggleRecording) {
                Text(title)
                    .frame(minWidth: 110)
                    .foregroundColor(isRecording ? .accentColor : .primary)
            }
            .help(isRecording ? "Press a key combination · Esc to cancel · Delete to clear" : "Click to record a shortcut")

            if manager.combo(for: action) != nil && !isRecording {
                Button {
                    manager.setCombo(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var title: String {
        if isRecording { return "Type shortcut…" }
        return manager.combo(for: action)?.displayString ?? "Record Shortcut"
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        manager.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case 53 where flags.isEmpty: // Esc
                stopRecording()
                return nil
            case 51 where flags.isEmpty, 117 where flags.isEmpty: // Delete / Forward delete
                manager.setCombo(nil, for: action)
                stopRecording()
                return nil
            default:
                break
            }
            if let combo = KeyCombo(event: event) {
                manager.setCombo(combo, for: action)
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if isRecording {
            isRecording = false
            manager.resume()
        }
    }
}
