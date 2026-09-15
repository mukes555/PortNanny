import Foundation

public struct PortHistoryItem: Identifiable, Codable {
    public let id: UUID
    public let port: Int
    public let processName: String
    public let timestamp: Date
    public let action: HistoryAction
    /// Agent that had started the process, and who stopped it ("you", "port
    /// guard", "link"). Optional so entries from older versions still decode.
    public let owner: String?
    public let killedBy: String?

    public enum HistoryAction: String, Codable {
        case detected = "Detected"
        case killed = "Killed"
        /// The guard refused an agent; `killedBy` names the agent it refused.
        case refused = "Refused"
    }

    public init(port: Int, processName: String, action: HistoryAction, owner: String? = nil, killedBy: String? = nil) {
        self.id = UUID()
        self.port = port
        self.processName = processName
        self.timestamp = Date()
        self.action = action
        self.owner = owner
        self.killedBy = killedBy
    }
}

public enum CSV {
    /// The History export, one row per entry. Every column goes through
    /// `field` so a future column can't silently bypass the defence.
    public static func historyDocument(_ items: [PortHistoryItem], formatter: DateFormatter) -> String {
        var csv = "Timestamp,Port,Process,Action,Owner,Killed By\n"
        for item in items {
            let fields = [
                formatter.string(from: item.timestamp),
                "\(item.port)",
                item.processName,
                item.action.rawValue,
                item.owner ?? "",
                item.killedBy ?? ""
            ].map(field)
            csv.append(fields.joined(separator: ",") + "\n")
        }
        return csv
    }

    /// Escapes a value for a CSV cell, defusing spreadsheet formula injection
    /// (process names are attacker-influenced: a name like "=cmd|..." would
    /// otherwise execute when the export is opened in Excel).
    public static func field(_ raw: String) -> String {
        var value = raw
        // Tab and carriage return are formula lead-ins for Excel as well.
        if let first = value.first, "=+-@\t\r".contains(first) {
            value = "'" + value
        }

        let needsQuoting = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        if needsQuoting {
            value = "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

/// Kill history, newest first, capped by the History preference. Observable
/// so the History window updates while it is open; `defaults` is injectable
/// so tests never touch the user's real history.
public final class HistoryManager: ObservableObject {
    public static let shared = HistoryManager()

    @Published public private(set) var history: [PortHistoryItem] = []
    /// Refusals the guard issued to agents, newest first, capped at twenty.
    @Published public private(set) var refusals: [PortHistoryItem] = []
    private let defaults: UserDefaults
    /// The app and every CLI and MCP process append to this store; without a
    /// shared lock, fifteen agents refused at once kept only twelve refusals.
    private let lock: SharedStore.Lock
    private static let maxRefusals = 20

    /// Kills and refusals together, newest first.
    public var events: [PortHistoryItem] {
        (history + refusals).sorted { $0.timestamp > $1.timestamp }
    }

    public static let defaultLimit = 50
    /// The lengths a stored History preference may have; anything else is ignored.
    public static let limitRange = 10...1000

    /// Set from the History preference; trimming applies immediately.
    public var maxHistoryItems = HistoryManager.defaultLimit {
        // Re-read first: this copy may be older than kills an agent has
        // recorded since, and saving it as it was would drop them.
        didSet {
            guard maxHistoryItems != oldValue else { return }
            lock.withLock { loadHistory(); trimAndSave() }
        }
    }

    /// `lockName` defaults to the shared domain, so the app's `.shared` store
    /// and the CLI's `appStore()`, which reach the same plist by different
    /// routes, take the same lock.
    public init(defaults: UserDefaults = .standard, lockName: String = HistoryManager.appSuiteName) {
        self.defaults = defaults
        self.lock = SharedStore.Lock(name: "\(lockName)-history")
        // Every CLI and MCP process trims on write too. Assuming the default
        // there cut a History of 500 down to 50 on the first agent kill.
        maxHistoryItems = Self.storedLimit(in: defaults)
        loadHistory()
    }

    /// The History preference as Settings saved it, or the default when it is
    /// missing or not a length Settings could have saved.
    public static func storedLimit(in defaults: UserDefaults) -> Int {
        guard let stored = defaults.object(forKey: DefaultsKey.historyLimit) as? Int, limitRange.contains(stored) else {
            return defaultLimit
        }
        return stored
    }

    public func addEntry(port: Int, processName: String, action: PortHistoryItem.HistoryAction,
                  owner: String? = nil, killedBy: String? = nil) {
        // The CLI and the app share this store. Re-reading before writing only
        // helps if nobody else writes between the read and the write, which
        // is what the lock is for.
        lock.withLock {
            loadHistory()
            let item = PortHistoryItem(port: port, processName: processName, action: action, owner: owner, killedBy: killedBy)
            history.insert(item, at: 0)
            trimAndSave()
        }
    }

    public func addRefusal(port: Int, processName: String, owner: String?, refused caller: String) {
        lock.withLock {
            loadHistory()
            let item = PortHistoryItem(port: port, processName: processName, action: .refused, owner: owner, killedBy: caller)
            refusals.insert(item, at: 0)
            refusals = Array(refusals.prefix(Self.maxRefusals))
            if let data = try? JSONEncoder().encode(refusals) {
                defaults.set(data, forKey: DefaultsKey.refusals)
            }
        }
    }

    public func reload() {
        loadHistory()
    }

    /// The store the app itself uses. From the CLI, `UserDefaults.standard`
    /// would not resolve to the app's domain (the binary is reached through
    /// a symlink), so the domain is named explicitly.
    public static func appStore() -> HistoryManager {
        HistoryManager(defaults: appDefaults())
    }

    /// The app's preference domain, from wherever this code is running.
    /// Inside the app that domain *is* `.standard`, and asking for it by name
    /// returns nil and logs "using your own bundle identifier as a suite name
    /// does not make sense"; from the CLI it has to be named.
    public static func appDefaults() -> UserDefaults {
        let suite = appSuiteName
        if suite == Bundle.main.bundleIdentifier { return .standard }
        return UserDefaults(suiteName: suite) ?? .standard
    }

    /// The shared preference domain. Debug builds honour PORTNANNY_DEFAULTS_SUITE
    /// so the scenario tests write to a throwaway domain instead of the user's.
    public static var appSuiteName: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["PORTNANNY_DEFAULTS_SUITE"], !override.isEmpty {
            return override
        }
        #endif
        return "com.mukes555.PortNanny"
    }

    private func trimAndSave() {
        if history.count > maxHistoryItems {
            history = Array(history.prefix(maxHistoryItems))
        }
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: DefaultsKey.history)
        }
    }

    private func loadHistory() {
        // Entries that no longer decode are dropped one by one rather than
        // taking the whole list with them, which the next save would then
        // have written over every good entry.
        if let data = defaults.data(forKey: DefaultsKey.history),
           let items = SharedStore.decodeArray(PortHistoryItem.self, from: data) {
            history = items
        }
        if let data = defaults.data(forKey: DefaultsKey.refusals),
           let items = SharedStore.decodeArray(PortHistoryItem.self, from: data) {
            refusals = items
        }
    }

    public func clearHistory() {
        lock.withLock {
            history.removeAll()
            refusals.removeAll()
            defaults.removeObject(forKey: DefaultsKey.history)
            defaults.removeObject(forKey: DefaultsKey.refusals)
        }
    }
}
