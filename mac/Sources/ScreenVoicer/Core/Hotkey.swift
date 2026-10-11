import AppKit
import Carbon.HIToolbox

/// A global shortcut such as "Alt+Shift+S" (⌥⇧S). Stored as text like on Windows; Alt = ⌥ Option, Cmd = ⌘.
struct HotkeyGesture: Equatable {
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let shift = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }

    var modifiers: Modifiers
    var keyCode: UInt32

    private static let keyNames: [(UInt32, String)] = {
        var list: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
            (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"), (kVK_F6, "F6"),
            (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
            (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"), (kVK_F16, "F16"), (kVK_F17, "F17"),
            (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20"),
            (kVK_Space, "Space"), (kVK_Home, "Home"), (kVK_End, "End"), (kVK_PageUp, "PageUp"),
            (kVK_PageDown, "PageDown"), (kVK_ForwardDelete, "Delete"),
            // a PC keyboard's Insert arrives as Help on macOS (MacBooks have neither)
            (kVK_Help, "Insert"),
            (kVK_ANSI_Grave, "`"), (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"),
            (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/")
        ]
        list.append((kVK_ISO_Section, "§"))
        return list.map { (UInt32($0.0), $0.1) }
    }()

    /// Keys that are fine without a modifier (nobody types them), as on Windows.
    private static let standaloneKeys: Set<UInt32> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ].map { UInt32($0) })

    /// Shortcuts macOS or every app needs (Windows has its own list).
    private static let reserved: Set<String> = [
        "Shift+Cmd+3", "Shift+Cmd+4", "Shift+Cmd+5", "Shift+Cmd+6", "Ctrl+Shift+Cmd+3", "Ctrl+Shift+Cmd+4",
        "Cmd+Space", "Ctrl+Space", "Alt+Cmd+Space", "Cmd+Q", "Cmd+W", "Cmd+H", "Cmd+M", "Cmd+C", "Cmd+V",
        "Cmd+X", "Cmd+Z", "Cmd+A", "Cmd+S", "Cmd+F", "Cmd+N", "Cmd+T", "Cmd+P", "Cmd+O", "Cmd+`", "Shift+Cmd+Z"
    ]

    static func keyName(_ code: UInt32) -> String? { keyNames.first { $0.0 == code }?.1 }

    static func isModifierKey(_ code: UInt16) -> Bool {
        [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
         kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function].contains(Int(code))
    }

    var isValid: Bool {
        Self.keyName(keyCode) != nil && (!modifiers.isEmpty || Self.standaloneKeys.contains(keyCode))
    }

    var isReserved: Bool { Self.reserved.contains(storageText) }

    /// "Alt+Shift+S" — the settings format, same order as Windows (Ctrl, Alt, Shift, Win/Cmd).
    var storageText: String {
        (Self.modifierNames(modifiers) + [Self.keyName(keyCode) ?? "?"]).joined(separator: "+")
    }

    /// "⌥⇧S" — how macOS writes shortcuts.
    var displayText: String {
        Self.modifierSymbols(modifiers).joined() + (Self.keyName(keyCode) ?? "?")
    }

    static func modifierNames(_ m: Modifiers) -> [String] {
        var names: [String] = []
        if m.contains(.control) { names.append("Ctrl") }
        if m.contains(.option) { names.append("Alt") }
        if m.contains(.shift) { names.append("Shift") }
        if m.contains(.command) { names.append("Cmd") }
        return names
    }

    /// Apple order: ⌃ ⌥ ⇧ ⌘.
    static func modifierSymbols(_ m: Modifiers) -> [String] {
        var symbols: [String] = []
        if m.contains(.control) { symbols.append("⌃") }
        if m.contains(.option) { symbols.append("⌥") }
        if m.contains(.shift) { symbols.append("⇧") }
        if m.contains(.command) { symbols.append("⌘") }
        return symbols
    }

    /// Keycaps for the hotkey window: "⌥ Option", "⇧ Shift", "S".
    static func keycaps(_ m: Modifiers) -> [String] {
        var caps: [String] = []
        if m.contains(.control) { caps.append("⌃ Control") }
        if m.contains(.option) { caps.append("⌥ Option") }
        if m.contains(.shift) { caps.append("⇧ Shift") }
        if m.contains(.command) { caps.append("⌘ Command") }
        return caps
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> Modifiers {
        var m: Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    static func parse(_ text: String?) -> HotkeyGesture? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var m: Modifiers = []
        var key: UInt32?
        for raw in text.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            switch raw.lowercased() {
            case "ctrl", "control": m.insert(.control); continue
            case "alt", "option", "opt": m.insert(.option); continue
            case "shift": m.insert(.shift); continue
            case "cmd", "command", "win": m.insert(.command); continue
            default: break
            }
            if key != nil { return nil } // two non-modifier keys
            guard let code = keyNames.first(where: { $0.1.caseInsensitiveCompare(raw) == .orderedSame })?.0 else { return nil }
            key = code
        }
        guard let key else { return nil }
        let gesture = HotkeyGesture(modifiers: m, keyCode: key)
        return gesture.isValid ? gesture : nil
    }

    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        return UInt32(flags)
    }
}

/// Registers the capture shortcut with Carbon's RegisterEventHotKey: global, and no Accessibility permission needed.
final class HotkeyService {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onPressed: (() -> Void)?

    var isRegistered: Bool { hotKeyRef != nil }

    func register(_ gesture: HotkeyGesture) -> Bool {
        unregister()
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x5356_4F43), id: 1) // 'SVOC'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(gesture.keyCode, gesture.carbonModifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            Log.warn("[Hotkey] \(gesture.storageText) could not be registered (\(status)).")
            return false
        }
        hotKeyRef = ref
        Log.info("[Hotkey] \(gesture.storageText) registered.")
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installHandler() {
        if handlerRef != nil { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { service.onPressed?() }
            return noErr
        }, 1, &spec, me, &handlerRef)
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
