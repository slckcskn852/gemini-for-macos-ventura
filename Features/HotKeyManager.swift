//
//  HotKeyManager.swift
//  GeminiDesktop
//
//  Dependency-free global keyboard shortcuts built on the Carbon hot-key API.
//  Replaces the KeyboardShortcuts package (which requires Swift 6.1 / Xcode 16
//  and therefore can't be built on macOS 13 with the Command Line Tools).
//

import AppKit
import Carbon.HIToolbox
import Combine

/// Global actions that can be bound to a system-wide shortcut.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case toggleChatBar
    case openMainWindow
    case shareWindow
    case shareArea
    case voiceInput

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggleChatBar: return "Toggle Quick Chat"
        case .openMainWindow: return "Open Main Window"
        case .shareWindow: return "Ask About Active Window"
        case .shareArea: return "Ask About Screen Area"
        case .voiceInput: return "Talk to Gemini"
        }
    }

    var systemImage: String {
        switch self {
        case .toggleChatBar: return "rectangle.bottomthird.inset.filled"
        case .openMainWindow: return "macwindow"
        case .shareWindow: return "macwindow.on.rectangle"
        case .shareArea: return "rectangle.dashed"
        case .voiceInput: return "mic"
        }
    }

    /// Same default as Google's official Mac app: Option + Space.
    var defaultCombo: KeyCombo? {
        switch self {
        case .toggleChatBar:
            return KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), keyLabel: "Space")
        default:
            return nil
        }
    }

    fileprivate var carbonID: UInt32 {
        UInt32(Self.allCases.firstIndex(of: self)! + 1)
    }

    fileprivate var defaultsKey: String {
        UserDefaultsKeys.hotKeyPrefix.rawValue + rawValue
    }
}

/// A key + modifier combination expressed in Carbon terms.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    /// Builds a combo from a key event captured by the recorder.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }

        let code = UInt32(event.keyCode)
        let isFunctionKey = Self.functionKeyNames[code] != nil
        // Require a "real" modifier unless it's a function key, otherwise the
        // shortcut would swallow normal typing system-wide.
        let hasRealModifier = mods & UInt32(cmdKey | optionKey | controlKey) != 0
        guard hasRealModifier || isFunctionKey else { return nil }

        self.keyCode = code
        self.modifiers = mods
        self.keyLabel = Self.label(for: code, event: event)
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    private static let functionKeyNames: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19",
    ]

    private static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓", UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
    ]

    private static func label(for code: UInt32, event: NSEvent) -> String {
        if let name = functionKeyNames[code] ?? specialKeyNames[code] { return name }
        if let chars = event.characters(byApplyingModifiers: []), !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return chars.uppercased()
        }
        return "Key \(code)"
    }
}

/// Registers system-wide hot keys and dispatches them to `onTrigger`.
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    /// 'GMDK' – identifies our hot keys inside the Carbon event stream.
    fileprivate static let signature: OSType = 0x474D_444B

    @Published private(set) var combos: [HotKeyAction: KeyCombo] = [:]
    /// Actions whose shortcut couldn't be registered (taken by macOS or another app).
    @Published private(set) var failed: Set<HotKeyAction> = []

    var onTrigger: ((HotKeyAction) -> Void)?

    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var isSuspended = false

    private init() {
        loadCombos()
    }

    func start() {
        installHandlerIfNeeded()
        registerAll()
    }

    func combo(for action: HotKeyAction) -> KeyCombo? {
        combos[action]
    }

    func setCombo(_ combo: KeyCombo?, for action: HotKeyAction) {
        // Unbind the same combo from any other action to avoid double triggers.
        if let combo = combo {
            for (other, existing) in combos where other != action && existing == combo {
                combos[other] = nil
                persist(nil, for: other)
            }
        }
        combos[action] = combo
        persist(combo, for: action)
        registerAll()
    }

    func resetToDefaults() {
        for action in HotKeyAction.allCases {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
        loadCombos()
        registerAll()
    }

    /// Temporarily releases all hot keys (used while recording a new shortcut).
    func suspend() {
        isSuspended = true
        unregisterAll()
    }

    func resume() {
        isSuspended = false
        registerAll()
    }

    // MARK: - Persistence

    private func loadCombos() {
        var result: [HotKeyAction: KeyCombo] = [:]
        let defaults = UserDefaults.standard
        for action in HotKeyAction.allCases {
            if let data = defaults.data(forKey: action.defaultsKey) {
                if let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
                    result[action] = combo
                }
                // Undecodable / empty data == explicitly cleared by the user.
            } else if let def = action.defaultCombo {
                result[action] = def
            }
        }
        combos = result
    }

    private func persist(_ combo: KeyCombo?, for action: HotKeyAction) {
        let data = combo.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: action.defaultsKey)
    }

    // MARK: - Carbon registration

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event = event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotKeyManager.signature,
                  let action = HotKeyAction.allCases.first(where: { $0.carbonID == hotKeyID.id }) else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async {
                HotKeyManager.shared.onTrigger?(action)
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    private func registerAll() {
        unregisterAll()
        guard !isSuspended, handlerRef != nil else { return }

        var newFailed: Set<HotKeyAction> = []
        for (action, combo) in combos {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.carbonID)
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref = ref {
                refs[action] = ref
            } else {
                newFailed.insert(action)
            }
        }
        failed = newFailed
    }

    private func unregisterAll() {
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
    }
}
