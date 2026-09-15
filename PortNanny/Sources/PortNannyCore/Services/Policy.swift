import Foundation

/// Preferences that change what the guard and the lease store do, honoured
/// by the app and by every CLI process alike: read from the shared domain
/// when a process starts, set by the app when the person changes them.
public enum Policy {
    /// An identified agent is refused a server nobody claims (most such
    /// servers are a person's). Off, the agent may stop it like a person.
    public static var refusesUnclaimedServers = true

    /// `portnanny reserve` without `--for`, and what Settings shows.
    public static var defaultLeaseTTL: TimeInterval = Reservation.defaultTTL

    public static func load(from defaults: UserDefaults) {
        if let stored = defaults.object(forKey: DefaultsKey.guardRefusesUnclaimed) as? Bool {
            refusesUnclaimedServers = stored
        }
        if let stored = defaults.object(forKey: DefaultsKey.leaseDefaultTTL) as? Double, Self.isValidLeaseTTL(stored) {
            defaultLeaseTTL = stored
        }
    }

    /// The store where the app keeps its preferences, which the CLI reads.
    public static func loadFromSharedDomain() {
        load(from: HistoryManager.appDefaults())
    }

    public static func isValidLeaseTTL(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds >= 60 && seconds <= Reservation.maxTTL
    }
}
