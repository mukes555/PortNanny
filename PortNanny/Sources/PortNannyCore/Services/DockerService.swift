import Foundation

/// Maps published container ports to container names and can stop containers.
///
/// All state is lock-guarded: lookups run on the refresh queue while
/// `stopContainer` runs on ad-hoc kill queues.
public final class DockerService {
    public static let shared = DockerService()

    private let lock = NSLock()
    private var portContainerMap: [Int: String] = [:]
    private var lastUpdate: Date = .distantPast
    private var cachedDockerPath: String?
    private var lastPathProbe: Date = .distantPast

    /// Container port mappings change rarely; don't shell out more often than this.
    private let cacheValidity: TimeInterval = 5.0
    /// When docker isn't found, re-probe occasionally: it may get installed
    /// or started later (the old code latched "not installed" forever).
    private let pathProbeInterval: TimeInterval = 60.0

    private static let candidatePaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker", // Homebrew on Apple Silicon
        "/usr/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker"
    ]

    private let refreshQueue = DispatchQueue(label: "com.portnanny.docker", qos: .utility)
    private var refreshInFlight = false
    /// Grows on every failed `docker ps` (daemon down, CLI hung) so a stopped
    /// Docker Desktop costs one probe a minute, not one per refresh.
    private var backoff: TimeInterval = 0
    private var nextAttempt: Date = .distantPast

    public static let minimumBackoff: TimeInterval = 5
    public static let maximumBackoff: TimeInterval = 60

    public static func nextBackoff(after current: TimeInterval) -> TimeInterval {
        min(max(current * 2, minimumBackoff), maximumBackoff)
    }

    /// Cache read only; never blocks the scan on a subprocess.
    /// True when the last `docker ps` did not answer. Without it a kill on a
    /// Docker port said "a container `docker ps` can name" and exited 6, when
    /// the real problem was that `docker ps` had just timed out.
    public var lastLookupFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return didFail
    }
    private var didFail = false

    public func getContainerName(forPort port: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return portContainerMap[port]
    }

    /// Refreshes the port map on a background queue when it is stale and a
    /// Docker process is actually listening; the names appear one refresh
    /// later. With no Docker listener the map is simply cleared.
    public func refreshInBackground(dockerPresent: Bool) {
        lock.lock()
        guard dockerPresent else {
            portContainerMap = [:]
            lastUpdate = .distantPast // so Docker coming back refreshes at once
            lock.unlock()
            return
        }
        let isFresh = Date().timeIntervalSince(lastUpdate) < cacheValidity
        let inBackoff = Date() < nextAttempt
        guard !isFresh, !inBackoff, !refreshInFlight else {
            lock.unlock()
            return
        }
        refreshInFlight = true
        lock.unlock()

        refreshQueue.async { [self] in
            fetchPortMap()
            lock.lock(); refreshInFlight = false; lock.unlock()
        }
    }

    /// Synchronous refresh for one-shot callers (the CLI) that have no later
    /// refresh to pick the names up on.
    public func refreshNow(dockerPresent: Bool) {
        guard dockerPresent else { return }
        fetchPortMap()
    }

    private func fetchPortMap() {
        lock.lock(); lastUpdate = Date(); lock.unlock()
        guard let docker = dockerPath() else { return }

        // Output per container: "0.0.0.0:5432->5432/tcp::my-postgres"
        guard let output = try? CommandRunner.run(
            docker, ["ps", "--format", "{{.Ports}}::{{.Names}}"], timeout: 3.0
        ) else {
            // Daemon down or hung: clear stale names so the UI doesn't lie,
            // and wait longer before the next attempt.
            lock.lock()
            portContainerMap = [:]
            didFail = true
            backoff = Self.nextBackoff(after: backoff)
            nextAttempt = Date().addingTimeInterval(backoff)
            lock.unlock()
            return
        }

        let map = Self.parsePortMap(output)
        lock.lock()
        portContainerMap = map
        didFail = false
        backoff = 0
        nextAttempt = .distantPast
        lock.unlock()
    }

    private func dockerPath() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedDockerPath { return cached }
        if Date().timeIntervalSince(lastPathProbe) < pathProbeInterval { return nil }

        lastPathProbe = Date()
        cachedDockerPath = Self.candidatePaths.first { FileManager.default.fileExists(atPath: $0) }
        return cachedDockerPath
    }

    public static func parsePortMap(_ output: String) -> [Int: String] {
        var map: [Int: String] = [:]

        for line in output.components(separatedBy: "\n") {
            // IPv6 bindings contain "::" themselves (":::8080->8080/tcp::api"),
            // so the container name is the LAST component, ports are the rest.
            let parts = line.components(separatedBy: "::")
            guard parts.count >= 2, let containerName = parts.last, !containerName.isEmpty else { continue }

            let portsStr = parts.dropLast().joined(separator: "::")

            // Ports string: "0.0.0.0:5432->5432/tcp" or several comma-separated mappings
            for mapping in portsStr.components(separatedBy: ",") {
                guard let rangeArrow = mapping.range(of: "->") else { continue }
                let publicPart = mapping[..<rangeArrow.lowerBound] // "0.0.0.0:5432" or ":::5432"

                guard let lastColon = publicPart.lastIndex(of: ":") else { continue }
                for port in publishedPorts(String(publicPart[publicPart.index(after: lastColon)...])) {
                    map[port] = containerName
                }
            }
        }

        return map
    }

    /// The ports one published mapping names. Compose publishes ranges
    /// ("0.0.0.0:3000-3005->3000-3005/tcp"), and reading only a single number
    /// dropped the whole container: no name in `whois`, no `docker stop` offer
    /// from `kill`. Capped, so a container publishing thousands of ports
    /// cannot fill the map.
    static func publishedPorts(_ text: String) -> [Int] {
        if let port = Int(text) { return PortManager.isValidPortNumber(port) ? [port] : [] }
        let ends = text.split(separator: "-", maxSplits: 1).map(String.init)
        guard ends.count == 2, let first = Int(ends[0]), let last = Int(ends[1]), first <= last,
              PortManager.isValidPortNumber(first), PortManager.isValidPortNumber(last) else { return [] }
        return Array(first...min(last, first + 255))
    }

    public func stopContainer(name: String) throws {
        guard let docker = dockerPath() else {
            throw NSError(domain: "DockerService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Docker CLI not found"
            ])
        }

        // `docker stop` waits up to 10s for a graceful shutdown; allow that plus slack.
        // "--" ends option parsing so a name can never be read as a flag.
        _ = try CommandRunner.run(docker, ["stop", "--", name], timeout: 15.0)

        // Invalidate cache so the UI updates quickly
        lock.lock(); lastUpdate = .distantPast; lock.unlock()
    }
}
