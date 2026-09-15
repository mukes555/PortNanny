import Foundation
import Combine

/// "Updated 2s ago" ticks on its own object so the footer alone re-renders
/// when a scan lands; publishing it from PortManager re-evaluated every row.
public final class RefreshClock: ObservableObject {
    @Published public var lastUpdated = Date()
}

// MARK: - PortManager
public class PortManager: ObservableObject {
    @Published public var activePorts: [PortInfo] = [] {
        didSet {
            activeSignature = Self.stableSignature(activePorts)
            recomputeVisiblePorts()
            onPortsChanged?()
        }
    }
    @Published public var activeTests: [TestProcessInfo] = []
    @Published public var lastErrorMessage: String?
    @Published public var toastMessage: String?
    public let clock = RefreshClock()

    /// Published once, so the list can show "scanning" instead of a
    /// premature "no ports" before any data exists.
    @Published public var hasCompletedFirstScan = false
    /// The slow lsof path is in use (libproc unavailable); shown in the footer.
    @Published public var isCompatibilityScan = false
    /// Processes a kill has been sent to and that have not exited yet; rows
    /// dim while they shut down.
    @Published public var terminatingPids: Set<Int> = []
    public var lastUpdated: Date { clock.lastUpdated }

    /// Not published: no view reads it, and publishing it forced two
    /// whole-tree re-renders per refresh even when nothing changed.
    public var isRefreshing = false
    /// Full-depth signature of `activePorts`, kept so a refresh compares one
    /// side instead of rebuilding both.
    public var activeSignature: [String] = []
    public var lastTestsPublish = Date.distantPast

    /// The ports the list shows, honoring the hide-system setting. Cached:
    /// it was recomputed on every access, thousands of times a minute.
    public internal(set) var visiblePorts: [PortInfo] = []
    /// Menu-bar badge: only dev-relevant ports. Counting every system daemon
    /// made the badge permanently ~30 and therefore meaningless.
    public internal(set) var menuBarBadgeCount = 0
    /// Set by the app delegate; fires after `activePorts` has changed.
    public var onPortsChanged: (() -> Void)?

    /// Preferences restored in init must not write themselves back or
    /// trigger side effects (a notification-permission prompt on launch).
    private var isRestoringPreferences = true

    /// Injected so tests run against a throwaway suite: every preference
    /// didSet below persists, and a test that touched the real defaults once
    /// switched off "hide system processes" on the developer's own machine.
    public let defaults: UserDefaults
    public let history: HistoryManager
    /// Per-process CPU and memory over the last scans, for sparklines.
    public let metrics = MetricsHistory()
    public let scanner = PortScanner()
    public let processScanner = ProcessScanner()
    public let killer = ProcessKiller()
    public var refreshTimer: Timer?
    /// Set by the debug render hooks: the ports come from scripted data and
    /// a refresh must not replace them with real ones.
    public private(set) var usesDemoData = false
    /// Whose processes count as "mine" (the rest hide as system ones); the
    /// demo hooks point it at their made-up user.
    public var currentUser = NSUserName()
    private var toastWorkItem: DispatchWorkItem?
    public var shouldRestartTimerOnIntervalChange = false

    /// While the popover is closed only the menu-bar count consumes the data,
    /// so the scan slows down to save CPU and battery.
    public static let backgroundRefreshInterval: TimeInterval = 30.0
    public var isUIVisible = false


    public static let defaultProtectedProcessSubstrings = KnownEditors.substrings

    @Published public var protectedProcessSubstrings: [String] = [] {
        didSet {
            let normalized = Self.normalizeProtectedProcessSubstrings(protectedProcessSubstrings)
            if normalized != protectedProcessSubstrings {
                protectedProcessSubstrings = normalized
                return
            }
            defaults.set(normalized, forKey: DefaultsKey.protectedProcessSubstrings)
        }
    }

    @Published public var refreshInterval: TimeInterval = 2.0 {
        didSet {
            guard !isRestoringPreferences else { return }
            defaults.set(refreshInterval, forKey: DefaultsKey.refreshIntervalSeconds)
            if shouldRestartTimerOnIntervalChange {
                restartTimer()
            }
        }
    }

    /// Default on: system daemons (rapportd, AirPlay, …) drown out the handful
    /// of dev servers the user actually cares about.
    @Published public var hideSystemProcesses: Bool = true {
        didSet {
            recomputeVisiblePorts()
            guard !isRestoringPreferences else { return }
            defaults.set(hideSystemProcesses, forKey: DefaultsKey.hideSystemProcesses)
        }
    }

    @Published public var confirmBeforeKill: Bool = true {
        didSet {
            guard !isRestoringPreferences else { return }
            defaults.set(confirmBeforeKill, forKey: DefaultsKey.confirmBeforeKill)
        }
    }

    /// Off by default: the inspector only sends a GET to a local web server
    /// when asked, or always once the person opts in.
    @Published public var probeLocalServers: Bool = false {
        didSet {
            guard !isRestoringPreferences else { return }
            defaults.set(probeLocalServers, forKey: DefaultsKey.probeLocalServers)
        }
    }

    /// Clean = one glanceable line per port; Advanced = command path, chips,
    /// CPU/age, tree expansion.
    /// Raw values are what older versions stored; the case names match the UI.
    public enum ViewDensity: String {
        case simple = "clean"
        case advanced
    }
    @Published public var viewDensity: ViewDensity = .simple {
        didSet {
            guard !isRestoringPreferences else { return }
            defaults.set(viewDensity.rawValue, forKey: DefaultsKey.viewDensity)
        }
    }

    /// Show the dev-port count next to the menu bar icon.
    @Published public var showMenuBarCount: Bool = true {
        didSet {
            guard !isRestoringPreferences else { return }
            defaults.set(showMenuBarCount, forKey: DefaultsKey.showMenuBarCount)
            onMenuBarPreferenceChanged?()
        }
    }

    /// What the status item draws: a monochrome quokka that follows the menu
    /// bar's look, or the app icon in colour.
    public enum MenuBarIcon: String, CaseIterable {
        case mono
        case color = "quokka"
    }
    @Published public var menuBarIcon: MenuBarIcon = .mono {
        didSet {
            guard !isRestoringPreferences else { return }
            defaults.set(menuBarIcon.rawValue, forKey: DefaultsKey.menuBarIcon)
            onMenuBarPreferenceChanged?()
        }
    }

    /// How much room the popover takes; the app maps a size to points.
    public enum PopoverSize: String, CaseIterable {
        case compact
        case regular
        case large
    }
    @Published public var popoverSize: PopoverSize = .regular {
        didSet {
            guard !isRestoringPreferences else { return }
            defaults.set(popoverSize.rawValue, forKey: DefaultsKey.popoverSize)
            onPopoverSizeChanged?()
        }
    }
    /// Set by the app delegate so a size change resizes the open popover.
    public var onPopoverSizeChanged: (() -> Void)?

    /// Master switch for watch/guard notifications. Permission is requested
    /// when the user turns it on or arms a watch, never just for launching.
    @Published public var notificationsEnabled: Bool = true {
        didSet {
            guard !isRestoringPreferences else { return }
            defaults.set(notificationsEnabled, forKey: DefaultsKey.notificationsEnabled)
            if notificationsEnabled { Notifier.requestPermission() }
        }
    }

    @Published public var notificationSound: Bool = true {
        didSet {
            guard !isRestoringPreferences else { return }
            defaults.set(notificationSound, forKey: DefaultsKey.notificationSound)
        }
    }

    // Which events notify, under the master switch.
    @Published public var notifyPortFreed = true { didSet { persist(notifyPortFreed, DefaultsKey.notifyPortFreed) } }
    @Published public var notifyPortTaken = true { didSet { persist(notifyPortTaken, DefaultsKey.notifyPortTaken) } }
    @Published public var notifyGuardKills = true { didSet { persist(notifyGuardKills, DefaultsKey.notifyGuardKills) } }
    @Published public var notifyRefusals = true { didSet { persist(notifyRefusals, DefaultsKey.notifyRefusals) } }

    public enum NotificationKind {
        case portFreed, portTaken, guardKill, refusal
    }

    public func notifies(_ kind: NotificationKind) -> Bool {
        guard notificationsEnabled else { return false }
        switch kind {
        case .portFreed: return notifyPortFreed
        case .portTaken: return notifyPortTaken
        case .guardKill: return notifyGuardKills
        case .refusal: return notifyRefusals
        }
    }

    // What the list shows besides system processes.
    @Published public var showUDP = true {
        didSet {
            recomputeVisiblePorts()
            persist(showUDP, DefaultsKey.showUDP)
        }
    }
    /// Ports from 49152 up are mostly ephemeral: something's outgoing side,
    /// or a server that picked a random port and does not mind which.
    @Published public var hideEphemeralPorts = false {
        didSet {
            recomputeVisiblePorts()
            persist(hideEphemeralPorts, DefaultsKey.hideEphemeralPorts)
        }
    }

    @Published public var autoUpdateCheck = true { didSet { persist(autoUpdateCheck, DefaultsKey.autoUpdateCheck) } }
    @Published public var includePrereleases = false { didSet { persist(includePrereleases, DefaultsKey.includePrereleases) } }

    // Policy the CLI follows too; see `Policy`.
    @Published public var guardRefusesUnclaimed = true {
        didSet {
            Policy.refusesUnclaimedServers = guardRefusesUnclaimed
            persist(guardRefusesUnclaimed, DefaultsKey.guardRefusesUnclaimed)
        }
    }
    @Published public var leaseDefaultTTL: TimeInterval = Reservation.defaultTTL {
        didSet {
            Policy.defaultLeaseTTL = leaseDefaultTTL
            persist(leaseDefaultTTL, DefaultsKey.leaseDefaultTTL)
        }
    }

    private func persist(_ value: Any, _ key: String) {
        guard !isRestoringPreferences else { return }
        defaults.set(value, forKey: key)
    }

    /// How many kills the History window keeps.
    @Published public var historyLimit: Int = HistoryManager.defaultLimit {
        didSet {
            history.maxHistoryItems = historyLimit
            guard !isRestoringPreferences else { return }
            defaults.set(historyLimit, forKey: DefaultsKey.historyLimit)
        }
    }

    /// Set by the app delegate so a menu-bar preference change redraws it.
    public var onMenuBarPreferenceChanged: (() -> Void)?

    /// Ports the user starred: a system notification fires when one frees up
    /// or when something new binds it.
    @Published public var watchedPorts: Set<Int> = [] {
        didSet {
            guard !isRestoringPreferences else { return }
            defaults.set(Array(watchedPorts).sorted(), forKey: DefaultsKey.watchedPorts)
        }
    }
    /// Guarded ports auto-kill any new (unprotected, user-owned) occupant.
    /// Strictly opt-in per port; a guarded port is always also watched.
    @Published public var guardedPorts: Set<Int> = [] {
        didSet {
            guard !isRestoringPreferences else { return }
            defaults.set(Array(guardedPorts).sorted(), forKey: DefaultsKey.guardedPorts)
        }
    }

    /// Occupancy of watched ports at the previous scan, as `occupancy(of:in:)` writes it.
    public var watchedOccupancy: [Int: String] = [:]

    /// One-shot "tell me when this frees up" armed when a kill didn't finish
    /// in time (slow shutdown, trapped SIGTERM).
    public var pendingFreeNotifications: Set<Int> = []

    /// Recent guard kills per port; see `guardHasStruckOut`.
    public var guardStrikes: [Int: [Date]] = [:]

    /// Set when GitHub has a newer release; drives the "Download vX.Y.Z" menu item.
    @Published public var updateAvailableVersion: String?

    public init(defaults: UserDefaults = .standard, history: HistoryManager = .shared, autoStart: Bool = true) {
        self.defaults = defaults
        self.history = history
        if let storedProtected = defaults.array(forKey: DefaultsKey.protectedProcessSubstrings) as? [String] {
            protectedProcessSubstrings = Self.normalizeProtectedProcessSubstrings(storedProtected)
        } else {
            protectedProcessSubstrings = Self.normalizeProtectedProcessSubstrings(Self.defaultProtectedProcessSubstrings)
        }

        if let stored = defaults.object(forKey: DefaultsKey.refreshIntervalSeconds) as? Double {
            refreshInterval = Self.sanitizedRefreshInterval(stored)
        }
        if let stored = defaults.object(forKey: DefaultsKey.hideSystemProcesses) as? Bool {
            hideSystemProcesses = stored
        }
        if let stored = defaults.object(forKey: DefaultsKey.confirmBeforeKill) as? Bool {
            confirmBeforeKill = stored
        }
        if let stored = defaults.object(forKey: DefaultsKey.probeLocalServers) as? Bool {
            probeLocalServers = stored
        }
        if let stored = defaults.string(forKey: DefaultsKey.viewDensity),
           let density = ViewDensity(rawValue: stored) {
            viewDensity = density
        }
        if let stored = defaults.object(forKey: DefaultsKey.showMenuBarCount) as? Bool {
            showMenuBarCount = stored
        }
        if let stored = defaults.string(forKey: DefaultsKey.menuBarIcon), let icon = MenuBarIcon(rawValue: stored) {
            menuBarIcon = icon
        }
        if let stored = defaults.string(forKey: DefaultsKey.popoverSize), let size = PopoverSize(rawValue: stored) {
            popoverSize = size
        }
        if let stored = defaults.object(forKey: DefaultsKey.notificationsEnabled) as? Bool {
            notificationsEnabled = stored
        }
        if let stored = defaults.array(forKey: DefaultsKey.watchedPorts) as? [Int] {
            watchedPorts = Set(stored.filter(Self.isValidPortNumber))
        }
        if let stored = defaults.object(forKey: DefaultsKey.notificationSound) as? Bool {
            notificationSound = stored
        }
        notifyPortFreed = defaults.object(forKey: DefaultsKey.notifyPortFreed) as? Bool ?? true
        notifyPortTaken = defaults.object(forKey: DefaultsKey.notifyPortTaken) as? Bool ?? true
        notifyGuardKills = defaults.object(forKey: DefaultsKey.notifyGuardKills) as? Bool ?? true
        notifyRefusals = defaults.object(forKey: DefaultsKey.notifyRefusals) as? Bool ?? true
        showUDP = defaults.object(forKey: DefaultsKey.showUDP) as? Bool ?? true
        hideEphemeralPorts = defaults.object(forKey: DefaultsKey.hideEphemeralPorts) as? Bool ?? false
        autoUpdateCheck = defaults.object(forKey: DefaultsKey.autoUpdateCheck) as? Bool ?? true
        includePrereleases = defaults.object(forKey: DefaultsKey.includePrereleases) as? Bool ?? false
        guardRefusesUnclaimed = defaults.object(forKey: DefaultsKey.guardRefusesUnclaimed) as? Bool ?? true
        if let stored = defaults.object(forKey: DefaultsKey.leaseDefaultTTL) as? Double, Policy.isValidLeaseTTL(stored) {
            leaseDefaultTTL = stored
        }
        Policy.refusesUnclaimedServers = guardRefusesUnclaimed
        Policy.defaultLeaseTTL = leaseDefaultTTL
        historyLimit = HistoryManager.storedLimit(in: defaults)
        if let stored = defaults.array(forKey: DefaultsKey.guardedPorts) as? [Int] {
            // A guard only makes sense on a watched port; the invariant is
            // enforced on writes, so re-establish it for whatever was stored.
            guardedPorts = Set(stored).intersection(watchedPorts)
        }
        shouldRestartTimerOnIntervalChange = true
        isRestoringPreferences = false

        // In debug, the demo hooks drive state by hand: no live scan, so a
        // README image never shows this Mac's ports.
        #if DEBUG
        let environment = Foundation.ProcessInfo.processInfo.environment
        usesDemoData = environment["PORTNANNY_DEMO_GIF"] != nil || environment["PORTNANNY_SNAPSHOT_DATA"] == "demo"
        #endif
        if !usesDemoData && autoStart {
            startAutoRefresh()

            // Once a day, quietly see if a newer release exists. Deferred so
            // launch never waits on the network.
            if autoUpdateCheck && UpdateChecker.shouldAutoCheck() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    self?.checkForUpdates(manual: false)
                }
            }
        }
    }

    public func isProtectedProcessName(_ processName: String) -> Bool {
        let lower = processName.lowercased()
        return protectedProcessSubstrings.contains { lower.contains($0) }
    }

    public func resetProtectedProcessSubstrings() {
        protectedProcessSubstrings = Self.defaultProtectedProcessSubstrings
    }

    /// Restores every preference to its default and clears watch/guard state.
    public func resetAllSettings() {
        refreshInterval = 2.0
        hideSystemProcesses = true
        confirmBeforeKill = true
        viewDensity = .simple
        showMenuBarCount = true
        menuBarIcon = .mono
        popoverSize = .regular
        notificationsEnabled = true
        notificationSound = true
        notifyPortFreed = true
        notifyPortTaken = true
        notifyGuardKills = true
        notifyRefusals = true
        showUDP = true
        hideEphemeralPorts = false
        autoUpdateCheck = true
        includePrereleases = false
        guardRefusesUnclaimed = true
        leaseDefaultTTL = Reservation.defaultTTL
        historyLimit = HistoryManager.defaultLimit
        protectedProcessSubstrings = Self.defaultProtectedProcessSubstrings
        watchedPorts = []
        guardedPorts = []
        defaults.set(false, forKey: DefaultsKey.didDismissHotkeyTip)
        showToast("Settings reset to defaults")
    }

    private static func normalizeProtectedProcessSubstrings(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty { continue }
            if result.contains(normalized) { continue }
            result.append(normalized)
        }
        return result
    }

    deinit {
        stopAutoRefresh()
    }

    public func showToast(_ message: String) {
        toastWorkItem?.cancel()
        toastMessage = message

        let workItem = DispatchWorkItem { [weak self] in
            self?.toastMessage = nil
        }
        toastWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    public func formatError(_ error: Error, context: String) -> String {
        if let scanError = error as? PortScanner.ScanError {
            switch scanError {
            case .invalidOutput:
                return "\(context): invalid command output"
            case .commandFailed(let code):
                return "\(context): lsof failed (exit \(code))"
            }
        }
        return "\(context): \(error.localizedDescription)"
    }

    public func scheduleRefresh(after delay: TimeInterval = 2.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.refresh()
        }
    }

}
