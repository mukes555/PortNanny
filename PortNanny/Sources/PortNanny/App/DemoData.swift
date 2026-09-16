import PortNannyCore
import Foundation

/// The ports every README image and the demo GIF show. Fabricated on
/// purpose: a live scan would put this Mac's projects, paths, and user name
/// into the repository. A user named "dev" under /Users/dev/code.
#if DEBUG
enum DemoData {
    static let user = "dev"

    static let test = TestProcessInfo(
        pid: 4101, processName: "node", command: "node node_modules/.bin/vitest --watch",
        memoryUsage: "312MB", memorySizeKB: 319_488, cpuPercent: 46, type: .vitest
    )

    private static let claudeLive = AgentOwner(name: "Claude Code", sessionPid: 4001, source: .processTree)
    private static let claudeEnded = AgentOwner(name: "Claude Code", sessionPid: 3950, source: .processTree, sessionEnded: true)
    private static let cursorLive = AgentOwner(name: "Cursor", sessionPid: 4002, source: .environment)

    /// A port an agent has taken and not started on yet: the Agents view is
    /// the only place this can be shown, since there is no process to list.
    /// No session pid on purpose: a lease pinned to a process that has
    /// exited is over, however long its clock says, and a made-up pid would
    /// vanish before the snapshot was taken.
    static let claim = Reservation(port: 3100, owner: "Codex CLI", sessionKey: "s-42",
                                   reason: "building the checkout page", ttl: 20 * 60)

    /// The AI tools the Agents view lists at the bottom.
    static let tools: [DoctorAgents.Status] = [
        DoctorAgents.Status(name: "Claude Code", kind: "CLI", recognisedBy: [], session: "one per window", provenance: "",
                            tip: nil, running: 2, installedAt: "/usr/local/bin/claude"),
        DoctorAgents.Status(name: "Codex CLI", kind: "CLI", recognisedBy: [], session: "one per run", provenance: "",
                            tip: nil, running: 1, installedAt: "/usr/local/bin/codex"),
        DoctorAgents.Status(name: "Cursor", kind: "editor", recognisedBy: [], session: "one per window", provenance: "",
                            tip: nil, running: 1, installedAt: nil),
        DoctorAgents.Status(name: "Gemini CLI", kind: "CLI", recognisedBy: [], session: "one per run", provenance: "",
                            tip: nil, running: 0, installedAt: "/usr/local/bin/gemini"),
    ]

    /// The reel kills :3000 halfway through, so it can be left out.
    static func ports(includePort3000: Bool) -> [PortInfo] {
        var ports: [PortInfo] = [
            PortInfo(
                port: 5173, pid: 2002, processName: "node",
                command: "node /Users/dev/code/my-app/node_modules/.bin/vite",
                user: user, memoryUsage: "84MB", memorySizeKB: 86_016, type: .nodejs,
                projectName: "my-app", projectPath: "/Users/dev/code/my-app",
                bindAddress: "127.0.0.1", cpuPercent: 1.2, age: "2h 14m", agentOwner: claudeEnded, connections: 1
            ),
            PortInfo(
                port: 4400, pid: 2004, processName: "node",
                command: "node --enable-source-maps /Users/dev/code/api/dist/server.js",
                user: user, memoryUsage: "96MB", memorySizeKB: 98_304, type: .nodejs,
                projectName: "api", projectPath: "/Users/dev/code/api",
                bindAddress: "*", cpuPercent: 0.6, age: "1h 8m", agentOwner: claudeEnded,
                managedBy: ManagedRuntime(kind: .reloader, name: "watch mode", supervisorPid: 2040, supervisorName: "nodemon")
            ),
            PortInfo(
                port: 8080, pid: 2003, processName: "api-server",
                command: "/Users/dev/code/api/bin/api-server --dev",
                user: user, memoryUsage: "24MB", memorySizeKB: 24_576, type: .go,
                projectName: "api", projectPath: "/Users/dev/code/api",
                bindAddress: "*", cpuPercent: 0.4, age: "3h 2m", agentOwner: cursorLive, connections: 2
            ),
            PortInfo(
                port: 4500, pid: 2006, processName: "Python",
                command: "/opt/homebrew/bin/python3 -m uvicorn app:api --reload --port 4500",
                user: user, memoryUsage: "41MB", memorySizeKB: 41_984, type: .python,
                projectName: "checkout", projectPath: "/Users/dev/code/checkout",
                bindAddress: "127.0.0.1", cpuPercent: 0.3, age: "52m"
            ),
            PortInfo(
                port: 5432, pid: 903, processName: "postgres",
                command: "/opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16",
                user: user, memoryUsage: "6MB", memorySizeKB: 6_144, type: .database,
                bindAddress: "127.0.0.1", cpuPercent: 0.0, age: "2d 5h",
                managedBy: ManagedRuntime(kind: .launchd, name: "homebrew.mxcl.postgresql@16")
            ),
            PortInfo(
                port: 6379, pid: 2005, processName: "com.docker.backend",
                command: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
                user: user, memoryUsage: "120MB", memorySizeKB: 122_880, type: .docker,
                containerName: "redis-dev", bindAddress: "127.0.0.1", cpuPercent: 0.8, age: "1d 3h", connections: 3,
                managedBy: ManagedRuntime(kind: .docker, name: "redis-dev")
            ),
        ]
        if includePort3000 {
            ports.insert(PortInfo(
                port: 3000, pid: 2001, processName: "node",
                command: "node /Users/dev/code/my-app/node_modules/.bin/next dev",
                user: user, memoryUsage: "512MB", memorySizeKB: 524_288, type: .nodejs,
                projectName: "my-app", projectPath: "/Users/dev/code/my-app",
                children: [PortInfo.ProcessInfo(pid: 2010, name: "node", command: "next-render-worker")],
                bindAddress: "*", cpuPercent: 12.5, age: "4h 32m", agentOwner: claudeLive, connections: 1
            ), at: 0)
        }
        return ports
    }
}
#endif
