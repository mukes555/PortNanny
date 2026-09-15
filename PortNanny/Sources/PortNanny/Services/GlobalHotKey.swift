import PortNannyCore
import Foundation
import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut that works without Accessibility permission.
///
/// Uses Carbon's RegisterEventHotKey, the one macOS API that delivers global
/// hotkeys to background apps permission-free (NSEvent global monitors would
/// require the user to grant Accessibility access).
final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onPress: () -> Void

    /// The app's default shortcut: ⌥⌘P ("P" for ports).
    static let defaultKeyCode = UInt32(kVK_ANSI_P)
    static let defaultModifiers = UInt32(cmdKey | optionKey)
    static let defaultDisplay = "⌥⌘P"

    /// Converts AppKit modifier flags to the Carbon flags RegisterEventHotKey expects.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Whether macOS has already claimed this combination (Spotlight,
    /// Mission Control, input switching). Registering one of those succeeds
    /// and then never fires, so it has to be refused here instead.
    static func isTakenBySystem(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        return entries.contains { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return false }
            return code == keyCode && modifiers == carbonModifiers
        }
    }

    static func displayString(for flags: NSEvent.ModifierFlags, key: String) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }

    init?(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void) {
        self.onPress = onPress

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                // Carbon delivers hotkey events on the main run loop, so call
                // synchronously: a deferred main.async could fire onPress()
                // after the object was replaced (Change Hotkey) and freed.
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                hotKey.onPress()
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x504B_4C41) /* "PKLA" */, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr else {
            RemoveEventHandler(eventHandler)
            eventHandler = nil // deinit must not remove it a second time
            return nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}
