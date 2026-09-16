import Foundation

/// Every UserDefaults key the app writes, in one place, so "reset all
/// settings" and the docs can see the whole surface.
public enum DefaultsKey {
    public static let refreshIntervalSeconds = "PortNanny.refreshIntervalSeconds"
    public static let protectedProcessSubstrings = "PortNanny.protectedProcessSubstrings"
    public static let hideSystemProcesses = "PortNanny.hideSystemProcesses"
    public static let confirmBeforeKill = "PortNanny.confirmBeforeKill"
    /// The Simple/Advanced setting the view tabs replaced. No longer read:
    /// kept so the migration from PortKilla still knows the key.
    public static let viewDensity = "PortNanny.viewDensity"
    /// Agents, Simple ("clean") or Advanced.
    public static let viewMode = "PortNanny.viewMode"
    public static let showMenuBarCount = "PortNanny.showMenuBarCount"
    public static let menuBarIcon = "PortNanny.menuBarIcon"
    public static let popoverSize = "PortNanny.popoverSize"
    public static let notifyPortFreed = "PortNanny.notifyPortFreed"
    public static let notifyPortTaken = "PortNanny.notifyPortTaken"
    public static let notifyGuardKills = "PortNanny.notifyGuardKills"
    public static let notifyRefusals = "PortNanny.notifyRefusals"
    public static let showUDP = "PortNanny.showUDP"
    public static let hideEphemeralPorts = "PortNanny.hideEphemeralPorts"
    public static let autoUpdateCheck = "PortNanny.autoUpdateCheck"
    public static let includePrereleases = "PortNanny.includePrereleases"
    /// Read by the CLI too: the guard's rule for unclaimed servers, and the
    /// lease length `reserve` uses without --for.
    public static let guardRefusesUnclaimed = "PortNanny.guardRefusesUnclaimed"
    public static let leaseDefaultTTL = "PortNanny.leaseDefaultTTL"
    /// The folder Settings > Agents writes rule files into.
    public static let setupProject = "PortNanny.setupProject"
    public static let notificationsEnabled = "PortNanny.notificationsEnabled"
    public static let notificationSound = "PortNanny.notificationSound"
    public static let historyLimit = "PortNanny.historyLimit"
    public static let watchedPorts = "PortNanny.watchedPorts"
    public static let guardedPorts = "PortNanny.guardedPorts"
    public static let hotkeyKeyCode = "PortNanny.hotkeyKeyCode"
    public static let hotkeyModifiers = "PortNanny.hotkeyModifiers"
    public static let hotkeyDisplay = "PortNanny.hotkeyDisplay"
    public static let hasLaunchedBefore = "PortNanny.hasLaunchedBefore"
    public static let didDismissHotkeyTip = "PortNanny.didDismissHotkeyTip"
    public static let didFinishTour = "PortNanny.didFinishTour"
    public static let probeLocalServers = "PortNanny.probeLocalServers"
    public static let lastUpdateCheck = "PortNanny.lastUpdateCheck"
    /// Unprefixed for compatibility with history saved by 1.0.
    public static let history = "portHistory"
    /// Refusals live apart from kills so an older app reading `history`
    /// never meets an action it cannot decode.
    public static let refusals = "PortNanny.refusals"
    /// Port leases, shared by the CLI and the app.
    public static let reservations = "PortNanny.reservations"
}
