import PortNannyCore
import Cocoa
import SwiftUI
import Combine
import ImageIO
import UniformTypeIdentifiers

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, ObservableObject {

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var historyWindow: NSWindow?
    var settingsWindow: NSWindow?
    let settingsRouter = SettingsView.Router()
    var workbenchWindow: NSWindow?
    var tourWindow: NSWindow?
    /// Only `togglePinnedWindow` and `windowWillClose` (both in
    /// AppDelegate+Windows) ever set this.
    var pinnedPanel: NSPanel?
    @Published var isPinned = false
    private var hotKey: GlobalHotKey?
    private var refusalWatcher: RefusalWatcher?


    @Published var hotkeyDisplay: String = GlobalHotKey.defaultDisplay

    let portManager: PortManager = {
        let defaults = AppDelegate.preferenceDefaults
        let history = defaults === UserDefaults.standard ? HistoryManager.shared : HistoryManager(defaults: defaults)
        return PortManager(defaults: defaults, history: history)
    }()
    var cancellables = Set<AnyCancellable>()

    /// Debug renders honour PORTNANNY_DEFAULTS_SUITE for preferences as well
    /// as history, so a snapshot's density or watch list never lands in the
    /// developer's own settings.
    static var preferenceDefaults: UserDefaults {
        #if DEBUG
        if let suite = Foundation.ProcessInfo.processInfo.environment["PORTNANNY_DEFAULTS_SUITE"], !suite.isEmpty,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        #endif
        return .standard
    }

    static func main() {
        // CLI mode: `PortNanny list`, `PortNanny kill 3000`, …
        let arguments = Array(Foundation.ProcessInfo.processInfo.arguments.dropFirst())
        if let exitCode = PortNannyCLI.run(arguments) {
            exit(exitCode)
        }

        // LaunchServices only stops a second instance of the same bundle
        // path: the copy on a mounted DMG and the one in Applications both
        // run happily, and then every guard kills twice and ⌥⌘P toggles
        // whichever answers first. Hand the person the one already running.
        if anotherInstanceIsRunning {
            ShowSignal.post()
            exit(0)
        }

        // PortKilla's preferences come along on the first run under the new name.
        if preferenceDefaults === UserDefaults.standard { PreferencesMigration.run() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        if let button = statusItem.button {
            button.image = MenuBarGlyph.image(portManager.menuBarIcon, active: false)
            button.imagePosition = .imageLeft
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Redraw the icon after the port list has changed. (A Combine sink on
        // $activePorts fires before the new value lands, so it needed a
        // run-loop hop; a callback from didSet needs none.)
        portManager.onPortsChanged = { [weak self] in self?.updateMenuBar() }

        popover = NSPopover()
        let contentView = PortListView(portManager: portManager)
            .environmentObject(self)
        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = portManager.popoverSize.dimensions
        // Track visibility so PortManager can slow the scan down while hidden.
        popover.delegate = self

        // Redraw the menu bar when its display preference changes
        portManager.onMenuBarPreferenceChanged = { [weak self] in self?.updateMenuBar() }
        portManager.onPopoverSizeChanged = { [weak self] in self?.applyPopoverSize() }

        // Hide dock icon (make it a background agent / menu bar app only)
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.make()

        // Global hotkey from anywhere toggles the popover (permission-free
        // Carbon API); the shortcut is set in Settings > Shortcuts.
        registerStoredHotKey()

        // A refusal the CLI issues to an agent becomes a notification here.
        refusalWatcher = RefusalWatcher(portManager: portManager) { [weak self] in self?.revealPorts() }

        // A second copy someone opened asks this one to show itself.
        DistributedNotificationCenter.default().addObserver(
            forName: ShowSignal.name, object: nil, queue: .main
        ) { [weak self] _ in
            self?.revealPorts()
        }

        // First launch: the tour, then the popover, so the app does not
        // silently vanish into the menu bar. An upgrade skips the tour (it
        // stays in the menu) but still sees the popover once per install.
        let defaults = Self.preferenceDefaults
        let isFirstLaunch = !defaults.bool(forKey: DefaultsKey.hasLaunchedBefore)
        if isFirstLaunch {
            defaults.set(true, forKey: DefaultsKey.hasLaunchedBefore)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showTour()
            }
        } else if defaults.object(forKey: DefaultsKey.didFinishTour) == nil {
            defaults.set(true, forKey: DefaultsKey.didFinishTour)
        }

        if hasPendingShowRequest {
            hasPendingShowRequest = false
            revealPorts()
        }

        // Developer-only rendering hooks (screenshots, README GIF, CI smoke
        // test). Compiled only in debug builds, never in the shipped app.
        #if DEBUG
        installDevHooks()
        #endif
    }

    /// True when another PortNanny process is already up. Debug and scripted
    /// runs have no bundle identifier, so they are never counted.
    private static var anotherInstanceIsRunning: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let mine = NSRunningApplication.current.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != mine }
    }

    /// A `portnanny://show` that arrived while the app was still launching.
    private var hasPendingShowRequest = false

    /// Opening PortNanny again (Spotlight, Finder, Raycast, the Dock) shows
    /// the port list. Without this the app looked dead to anyone whose menu
    /// bar is full, or whose icon hides behind a notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        revealPorts()
        return true
    }


    private var menuBarState: (active: Bool, title: String, icon: PortManager.MenuBarIcon)?

    func updateMenuBar() {
        guard let button = statusItem.button else { return }
        let count = portManager.menuBarBadgeCount
        let active = count > 0
        let title = (active && portManager.showMenuBarCount) ? "\(count)" : ""
        let icon = portManager.menuBarIcon

        // Same state, same drawing: skip the AppKit work.
        if let state = menuBarState, state.active == active, state.title == title, state.icon == icon { return }
        menuBarState = (active, title, icon)
        button.image = MenuBarGlyph.image(icon, active: active)
        button.title = title
    }

    // MARK: - Global hotkey

    private func registerStoredHotKey() {
        let defaults = UserDefaults.standard
        let keyCode = defaults.object(forKey: DefaultsKey.hotkeyKeyCode) as? Int
        let modifiers = defaults.object(forKey: DefaultsKey.hotkeyModifiers) as? Int

        hotkeyDisplay = defaults.string(forKey: DefaultsKey.hotkeyDisplay) ?? GlobalHotKey.defaultDisplay
        hotKey = GlobalHotKey(
            keyCode: keyCode.flatMap(Self.storedKeyCode) ?? GlobalHotKey.defaultKeyCode,
            modifiers: modifiers.flatMap(UInt32.init(exactly:)) ?? GlobalHotKey.defaultModifiers
        ) { [weak self] in
            self?.togglePopover()
        }
    }

    /// Preferences are untrusted: a negative or oversized value would trap in
    /// `UInt32(_:)` and crash every launch with no way to recover in-app.
    private static func storedKeyCode(_ value: Int) -> UInt32? {
        guard let code = UInt32(exactly: value), code <= 0x7F else { return nil }
        return code
    }

    /// Replaces the global hotkey; returns false if registration failed
    /// (e.g. the combination is taken by the system).
    @discardableResult
    func setHotKey(keyCode: UInt32, carbonModifiers: UInt32, display: String) -> Bool {
        hotKey = nil // Unregister the old one first (deinit)

        guard let newHotKey = GlobalHotKey(keyCode: keyCode, modifiers: carbonModifiers, onPress: { [weak self] in
            self?.togglePopover()
        }) else {
            registerStoredHotKey() // Fall back to the previous shortcut
            return false
        }

        hotKey = newHotKey
        hotkeyDisplay = display
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: DefaultsKey.hotkeyKeyCode)
        defaults.set(Int(carbonModifiers), forKey: DefaultsKey.hotkeyModifiers)
        defaults.set(display, forKey: DefaultsKey.hotkeyDisplay)
        return true
    }

    func resetHotKey() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKey.hotkeyKeyCode)
        defaults.removeObject(forKey: DefaultsKey.hotkeyModifiers)
        defaults.removeObject(forKey: DefaultsKey.hotkeyDisplay)
        hotKey = nil
        registerStoredHotKey()
    }

    /// URL scheme: portnanny://kill/3000[?force=1], portnanny://show
    ///
    /// A URL can be opened by any webpage the user visits, so a scheme-initiated
    /// kill is never silent: it always asks for confirmation first. (In-app
    /// kills have their own confirmation flow / explicit modifier keys.)
    func application(_ application: NSApplication, open urls: [URL]) {
        var askedThisDelivery = false
        for url in urls {
            switch URLCommand.parse(url) {
            case .kill(let port, let force):
                // One confirmation per delivery, and a cooldown after it: a page
                // could otherwise stack modal dialogs until one is clicked through.
                guard !askedThisDelivery, urlKillCooldownElapsed else { break }
                askedThisDelivery = true
                lastURLKillAsked = Date()
                confirmAndKillFromURL(port: port, force: force)
            case .show:
                // The URL can arrive before launch has built the popover, and
                // dropping it left `open portnanny://show` doing nothing at all.
                guard popover != nil else {
                    hasPendingShowRequest = true
                    break
                }
                revealPorts()
            case nil:
                break
            }
        }
    }

    private var lastURLKillAsked = Date.distantPast
    private static let urlKillCooldown: TimeInterval = 3

    private var urlKillCooldownElapsed: Bool {
        Date().timeIntervalSince(lastURLKillAsked) > Self.urlKillCooldown
    }

    private func confirmAndKillFromURL(port: Int, force: Bool) {
        // respectProtected: a link must not be able to kill a protected process
        portManager.killPortNumber(port, force: force, respectProtected: true, initiator: .link) { target in
            NSApp.activate(ignoringOtherApps: true)
            var message = "A link asked PortNanny to \(force ? "force-" : "")kill '\(target.processName)' (PID \(target.pid)) on :\(port). Only continue if you initiated this."
            if case .warn(let reason) = KillDecision.forHuman(target: target.agentOwner) {
                message += "\n\n\(reason)"
            }
            return KillConfirm.run(title: "Kill process on :\(port)?", message: message)
        }
    }

}
