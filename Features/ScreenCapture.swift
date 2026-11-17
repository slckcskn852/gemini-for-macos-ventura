//
//  ScreenCapture.swift
//  GeminiDesktop
//
//  Captures screen context (active window, a selected area, or the whole
//  screen) so it can be attached to a Gemini prompt — mirroring the
//  "share your screen/window" feature of Google's official Mac app.
//  Uses /usr/sbin/screencapture, which works on every macOS version.
//

import AppKit
import CoreGraphics

enum ScreenCapture {

    enum Mode {
        /// Front-most window of the given app (the app you were using before Gemini).
        case window(pid: pid_t?)
        /// Interactive crosshair selection (press Space to pick a window).
        case area
        /// The display under the mouse pointer.
        case screen
    }

    // MARK: - Permission

    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Returns true if capture is allowed. Otherwise triggers the system prompt
    /// (first time only) and explains how to grant access.
    @discardableResult
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // Shows the macOS prompt the first time and registers the app in the list.
        _ = CGRequestScreenCaptureAccess()

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = """
        To let Gemini see your screen, enable "Gemini Desktop" in System Settings → Privacy & Security → Screen Recording, then quit and reopen the app.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openPrivacySettings()
        }
        return false
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Capture

    /// Captures according to `mode` and calls back on the main queue with PNG data
    /// (or nil if the user cancelled / capture failed).
    static func capture(_ mode: Mode, completion: @escaping (Data?) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-context-\(UUID().uuidString).png")

        var args = ["-x", "-t", "png"] // no sound, PNG
        switch mode {
        case .window(let pid):
            if let windowID = frontWindowID(for: pid) {
                args += ["-o", "-l", String(windowID)] // no shadow, specific window
            } else {
                args += ["-i", "-o"] // fall back to interactive selection
            }
        case .area:
            args += ["-i", "-o"]
        case .screen:
            if let index = displayIndexUnderMouse() {
                args += ["-D", String(index)]
            } else {
                args += ["-m"]
            }
        }
        args.append(url.path)

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = args
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let data = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { completion(data) }
        }
    }

    /// Finds the front-most normal window owned by `pid` (window list is front-to-back).
    private static func frontWindowID(for pid: pid_t?) -> CGWindowID? {
        guard let pid = pid,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in info {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
               (bounds["Width"] ?? 0) < 80 || (bounds["Height"] ?? 0) < 80 {
                continue
            }
            return number
        }
        return nil
    }

    /// 1-based display index (as used by `screencapture -D`) of the screen under the mouse.
    private static func displayIndexUnderMouse() -> Int? {
        let mouse = NSEvent.mouseLocation
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let index = displays.firstIndex(of: CGDirectDisplayID(number.uint32Value)) else { return nil }
        return index + 1
    }
}
