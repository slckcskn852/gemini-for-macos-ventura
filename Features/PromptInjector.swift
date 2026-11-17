//
//  PromptInjector.swift
//  GeminiDesktop
//
//  Helpers that put text / images into Gemini's prompt box, start voice input
//  and submit — used by screen sharing, the "Ask Gemini" macOS Service and the
//  geminidesktop:// URL scheme.
//

import AppKit
import WebKit

enum PromptInjector {

    // MARK: - Scripts

    /// Focuses the prompt editor and places the caret at the end. Returns true on success.
    static let focusInputScript = """
    (function() {
        const editor = document.querySelector('rich-textarea .ql-editor') ||
                       document.querySelector('rich-textarea [contenteditable="true"]') ||
                       document.querySelector('[contenteditable="true"][role="textbox"]') ||
                       document.querySelector('[contenteditable="true"]') ||
                       document.querySelector('textarea');
        if (!editor) { return false; }
        editor.focus();
        try {
            if (editor.isContentEditable) {
                const range = document.createRange();
                range.selectNodeContents(editor);
                range.collapse(false);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
            }
        } catch (e) {}
        return true;
    })();
    """

    private static let clickSendScript = """
    (function() {
        const btn = document.querySelector('button[aria-label="Send message"]') ||
                    document.querySelector('button.send-button') ||
                    document.querySelector('button[aria-label*="Send" i]');
        if (btn && !btn.disabled && btn.getAttribute('aria-disabled') !== 'true') { btn.click(); return true; }
        return false;
    })();
    """

    private static let clickMicScript = """
    (function() {
        const btn = document.querySelector('speech-dictation-mic-button button') ||
                    document.querySelector('button[aria-label^="Dictate"]') ||
                    document.querySelector('button[aria-label*="microphone" i]') ||
                    document.querySelector('button[aria-label*="Microphone"]') ||
                    document.querySelector('button[aria-label*="voice" i]');
        if (btn) { btn.click(); return true; }
        return false;
    })();
    """

    private static let newChatScript = """
    (function() {
        const event = new KeyboardEvent('keydown', {
            key: 'O', code: 'KeyO', keyCode: 79, which: 79,
            shiftKey: true, metaKey: true, bubbles: true, cancelable: true, composed: true
        });
        (document.activeElement || document.body).dispatchEvent(event);
        document.dispatchEvent(event);
    })();
    """

    static func newChat(in webView: WKWebView, completion: (() -> Void)? = nil) {
        webView.evaluateJavaScript(newChatScript) { _, _ in completion?() }
    }

    // MARK: - Public API

    /// Inserts `text` into the prompt (appending to anything already there).
    static func insertText(_ text: String, into webView: WKWebView, submit: Bool = false) {
        whenEditorReady(in: webView) { ready in
            guard ready else { return }
            let literal = jsStringLiteral(text)
            let script = "document.execCommand('insertText', false, \(literal));"
            webView.evaluateJavaScript(script) { result, _ in
                // Fall back to a native paste if execCommand was refused.
                if (result as? Bool) == false {
                    paste(into: webView) { $0.setString(text, forType: .string) }
                }
                if submit {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        webView.evaluateJavaScript(clickSendScript, completionHandler: nil)
                    }
                }
            }
        }
    }

    /// Attaches a PNG image to the prompt via a real (trusted) paste so Gemini
    /// treats it exactly like a screenshot pasted by the user.
    static func attachImage(_ png: Data, into webView: WKWebView, prompt: String? = nil) {
        whenEditorReady(in: webView) { ready in
            guard ready else { return }
            paste(into: webView) { pasteboard in
                pasteboard.setData(png, forType: .png)
                if let tiff = NSImage(data: png)?.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                }
            }
            if let prompt = prompt, !prompt.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    insertText(prompt, into: webView)
                }
            }
        }
    }

    /// Clicks Gemini's microphone button to start voice input.
    static func startVoiceInput(in webView: WKWebView) {
        whenEditorReady(in: webView) { _ in
            webView.evaluateJavaScript(clickMicScript, completionHandler: nil)
        }
    }

    // MARK: - Internals

    /// Waits until the page has a prompt editor (e.g. right after launch or a
    /// window switch), focuses it, and makes the web view first responder.
    static func whenEditorReady(in webView: WKWebView, attempt: Int = 0, completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript(focusInputScript) { result, _ in
            if (result as? Bool) == true, webView.window != nil {
                webView.window?.makeFirstResponder(webView)
                completion(true)
            } else if attempt < 40 { // ~10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    whenEditorReady(in: webView, attempt: attempt + 1, completion: completion)
                }
            } else {
                completion(false)
            }
        }
    }

    /// Temporarily places content on the general pasteboard, sends `paste:` to the
    /// web view and then restores the user's clipboard.
    private static func paste(into webView: WKWebView, write: (NSPasteboard) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        write(pasteboard)
        let ourChangeCount = pasteboard.changeCount

        webView.window?.makeFirstResponder(webView)
        let pasteSelector = #selector(NSText.paste(_:))
        if !NSApp.sendAction(pasteSelector, to: nil, from: nil), webView.responds(to: pasteSelector) {
            webView.perform(pasteSelector, with: nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Only restore if nothing else touched the clipboard meanwhile.
            guard pasteboard.changeCount == ourChangeCount else { return }
            restore(saved, to: pasteboard)
        }
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Encodes a Swift string as a safe JavaScript string literal.
    static func jsStringLiteral(_ string: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [string]),
           let json = String(data: data, encoding: .utf8) {
            // json is `["..."]` — strip the array brackets.
            return String(json.dropFirst().dropLast())
        }
        return "''"
    }
}
