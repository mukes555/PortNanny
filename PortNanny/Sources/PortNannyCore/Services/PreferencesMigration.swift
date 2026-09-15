import Foundation

/// PortNanny was PortKilla until 2.1. The new bundle id means a new
/// preference domain, so the first run copies what the old app kept
/// (preferences, watched ports, history, refusals, leases) into the new
/// domain with the new key prefix. Once, silently, and never over a value
/// the new app has already written.
public enum PreferencesMigration {
    public static let legacySuite = "com.mukes555.PortKilla"
    public static let legacyPrefix = "PortKilla."
    public static let prefix = "PortNanny."
    /// Set in the target once the copy has run, whatever it found.
    public static let marker = "PortNanny.migratedFromPortKilla"
    /// Keys the old app wrote without the prefix.
    static let unprefixedKeys: Set<String> = ["portHistory"]

    @discardableResult
    public static func run(into target: UserDefaults = .standard,
                           from legacy: UserDefaults? = UserDefaults(suiteName: legacySuite)) -> Int {
        guard target.object(forKey: marker) == nil else { return 0 }
        var copied = 0
        for (key, value) in legacy?.dictionaryRepresentation() ?? [:] {
            guard let newKey = migratedKey(key), target.object(forKey: newKey) == nil else { continue }
            target.set(value, forKey: newKey)
            copied += 1
        }
        target.set(true, forKey: marker)
        return copied
    }

    /// The CLI's copy of the migration: into the domain the app shares with
    /// it, unless a debug run pointed that domain elsewhere (scenario tests
    /// must not inherit a real PortKilla's preferences).
    public static func runIntoSharedDomain() {
        let suite = HistoryManager.appSuiteName
        guard suite == "com.mukes555.PortNanny" else { return }
        run(into: HistoryManager.appDefaults())
    }

    /// The new name for an old key, or nil for anything that is not ours.
    static func migratedKey(_ key: String) -> String? {
        if key.hasPrefix(legacyPrefix) { return prefix + key.dropFirst(legacyPrefix.count) }
        if unprefixedKeys.contains(key) { return key }
        return nil
    }
}
