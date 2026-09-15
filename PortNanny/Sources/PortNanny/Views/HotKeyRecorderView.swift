import PortNannyCore
import SwiftUI
import AppKit

/// Captures a new global shortcut: press the combination, done.
struct HotKeyRecorderView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @Environment(\.dismiss) private var dismiss
    @State private var monitor: Any?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 14) {
            DetailTitleBar(onClose: { dismiss() })

            Image(systemName: "keyboard")
                .font(.system(size: 28))
                .foregroundColor(.secondary)

            Text("Press the new shortcut")
                .font(.headline)
            Text("Must include ⌘, ⌥, or ⌃ · current: \(appDelegate.hotkeyDisplay) · Esc to cancel")
                .font(.caption)
                .foregroundColor(.secondary)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button("Reset to ⌥⌘P") {
                appDelegate.resetHotKey()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(width: 320, height: 240)
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor() }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == KeyCode.escape {
            dismiss()
            return true
        }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let key = event.charactersIgnoringModifiers, !key.isEmpty else {
            errorText = "Include at least ⌘, ⌥, or ⌃"
            return true
        }
        // The other two ways people close a sheet: they cancel, rather than
        // being recorded as the shortcut that then stops closing anything.
        if flags == [.command], ["w", "."].contains(key.lowercased()) {
            dismiss()
            return true
        }
        // A global hotkey outranks every app, so a plain ⌘ combination is a
        // trap: ⌘W was accepted and from then on closed no tab anywhere.
        let hasControl = flags.contains(.control)
        let hasOptionWithCommand = flags.contains(.option) && flags.contains(.command)
        guard hasControl || hasOptionWithCommand else {
            errorText = "Use ⌃, or ⌥ with ⌘: a plain ⌘ shortcut would stop working in every other app"
            return true
        }

        let display = GlobalHotKey.displayString(for: flags, key: key)
        let carbonModifiers = GlobalHotKey.carbonModifiers(from: flags)
        guard !GlobalHotKey.isTakenBySystem(keyCode: UInt32(event.keyCode), carbonModifiers: carbonModifiers) else {
            errorText = "\(display) belongs to macOS; it would be recorded and never fire"
            return true
        }

        let registered = appDelegate.setHotKey(keyCode: UInt32(event.keyCode), carbonModifiers: carbonModifiers, display: display)
        if registered {
            dismiss()
        } else {
            errorText = "\(display) couldn't be registered, likely taken by another app"
        }
        return true
    }
}
