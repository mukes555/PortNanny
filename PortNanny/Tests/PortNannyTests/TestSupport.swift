import Foundation
@testable import PortNannyCore
@testable import PortNanny

/// Test doubles that keep the suite away from the developer's real
/// preferences and history: every PortManager preference persists on set,
/// and a test once switched off "hide system processes" on a real machine.
extension PortManager {
    private static var suiteNames: [ObjectIdentifier: String] = [:]

    static func forTesting() -> PortManager {
        let suite = "PortNannyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let manager = PortManager(defaults: defaults, history: HistoryManager(defaults: defaults), autoStart: false)
        suiteNames[ObjectIdentifier(manager)] = suite
        return manager
    }

    /// Call from `defer`: stops any timer and deletes the throwaway suite.
    func discardTestDefaults() {
        stopAutoRefresh()
        updateTimer?.invalidate()
        if let suite = Self.suiteNames.removeValue(forKey: ObjectIdentifier(self)) {
            UserDefaults.discardSuite(named: suite, defaults: defaults)
        }
    }
}

extension UserDefaults {
    /// removePersistentDomain empties the suite but leaves its plist in
    /// ~/Library/Preferences; delete the file too so runs don't litter.
    static func discardSuite(named suite: String, defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suite)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}
