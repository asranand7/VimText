import AppKit
import Carbon.HIToolbox

/// Registers the system-wide Quick Capture hotkey via Carbon's
/// `RegisterEventHotKey` — the one global-shortcut API that needs no
/// accessibility permission, fires while the app is backgrounded, and fails
/// loudly (so the recorder sheet can tell the user) when another app already
/// owns the combo.
///
/// The shortcut is stored in UserDefaults as a virtual key code plus a Carbon
/// modifier mask, so any combination of ⌃⌥⇧⌘ — including all four at once —
/// round-trips unchanged.
public final class QuickCaptureHotKey {
    public static let shared = QuickCaptureHotKey()

    static let keyCodeDefaultsKey = "quickCaptureKeyCode"
    static let modifiersDefaultsKey = "quickCaptureModifiers"

    /// ⌃⌥Space: ⌘Space is Spotlight, ⌥Space is usually Raycast/Alfred, and
    /// ⌃⌘Space is the system emoji picker — this combo is reliably free.
    public static let defaultKeyCode = UInt32(kVK_Space)
    public static let defaultModifiers = UInt32(controlKey | optionKey)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    /// True when the last registration attempt was rejected — i.e. another
    /// app owns the combo system-wide.
    public private(set) var lastRegistrationFailed = false

    public var keyCode: UInt32 {
        let stored = UserDefaults.standard.object(forKey: Self.keyCodeDefaultsKey) as? Int
        return stored.map(UInt32.init) ?? Self.defaultKeyCode
    }

    public var carbonModifiers: UInt32 {
        let stored = UserDefaults.standard.object(forKey: Self.modifiersDefaultsKey) as? Int
        return stored.map(UInt32.init) ?? Self.defaultModifiers
    }

    public var shortcutDescription: String {
        Self.description(keyCode: keyCode, carbonModifiers: carbonModifiers)
    }

    /// Installs the Carbon press handler and registers the stored shortcut.
    /// Call once at launch; safe to call again.
    public func start() {
        installHandlerIfNeeded()
        register()
    }

    /// Persists and registers a new shortcut. If the system rejects it
    /// (another app holds it), the previous shortcut is restored and this
    /// returns false.
    @discardableResult
    public func apply(keyCode newKeyCode: UInt32, carbonModifiers newModifiers: UInt32) -> Bool {
        let previousKeyCode = keyCode
        let previousModifiers = carbonModifiers
        persist(keyCode: newKeyCode, carbonModifiers: newModifiers)
        register()
        if lastRegistrationFailed {
            persist(keyCode: previousKeyCode, carbonModifiers: previousModifiers)
            register()
            return false
        }
        return true
    }

    @discardableResult
    public func resetToDefault() -> Bool {
        apply(keyCode: Self.defaultKeyCode, carbonModifiers: Self.defaultModifiers)
    }

    private func persist(keyCode: UInt32, carbonModifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode), forKey: Self.keyCodeDefaultsKey)
        UserDefaults.standard.set(Int(carbonModifiers), forKey: Self.modifiersDefaultsKey)
    }

    private func register() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5654_5143) /* 'VTQC' */, id: 1)
        let status = RegisterEventHotKey(
            keyCode, carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref
        )
        lastRegistrationFailed = status != noErr || ref == nil
        hotKeyRef = ref
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // C callback — must not capture context, so it reaches the panel
        // through the shared singletons.
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            Task { @MainActor in
                QuickCapturePanelController.shared.toggle()
            }
            return noErr
        }, 1, &eventType, nil, nil)
        handlerInstalled = status == noErr
    }

    // MARK: - Display / conversion helpers

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

    /// "⌃⌥⇧⌘" prefix in the standard macOS display order, then the key name.
    public static func description(keyCode: UInt32, carbonModifiers modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName(forKeyCode: keyCode)
    }

    /// F-keys work as a global shortcut without any modifier; everything else
    /// needs ⌃, ⌥, or ⌘ so a bare letter can't shadow normal typing.
    public static func isValidShortcut(keyCode: UInt32, carbonModifiers modifiers: UInt32) -> Bool {
        if modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 { return true }
        return functionKeyNames[Int(keyCode)] != nil
    }

    public static func keyName(forKeyCode keyCode: UInt32) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeyNames: [Int: String] = functionKeyNames.merging([
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_ANSI_KeypadEnter: "⌤",
        kVK_Tab: "⇥",
        kVK_Escape: "⎋",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
    ]) { _, new in new }
}
