import AppKit

/// A menu nobody sees: PortNanny is an accessory app, so the menu bar never
/// shows it. It exists because AppKit routes ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z and ⌘W
/// through the main menu. Without one, paste did nothing in the search field
/// or any other PortNanny text field, and ⌘W closed no window.
enum MainMenu {

    static func make() -> NSMenu {
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]

        let menu = NSMenu()
        menu.addItem(submenu("PortNanny", [
            NSMenuItem(title: "Quit PortNanny", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]))
        menu.addItem(submenu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            redo,
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]))
        menu.addItem(submenu("Window", [
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ]))
        return menu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}
