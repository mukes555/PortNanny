import Foundation

// MARK: - Per-command options
// Plain values the parser fills in and the commands read.
extension CLICommand {

    public struct AgentDocsOptions: Equatable {
        /// Append the snippet to `file` (default CLAUDE.md) instead of printing it.
        var write = false
        var file = "CLAUDE.md"
        /// Print a Claude Code PreToolUse hook that redirects lsof-based kills.
        var claudeHook = false
    }

    /// Where each tool reads its rules from, relative to the project.
    public enum RuleTarget: String, CaseIterable {
        case claude, codex, cursor, windsurf

        public var path: String {
            switch self {
            case .claude: return "CLAUDE.md"
            case .codex: return "AGENTS.md"
            case .cursor: return ".cursor/rules/portnanny.mdc"
            case .windsurf: return ".windsurf/rules/portnanny.md"
            }
        }

        public var toolName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex CLI"
            case .cursor: return "Cursor"
            case .windsurf: return "Windsurf"
            }
        }
    }

    public struct SetupOptions: Equatable {
        /// Apply every step without asking (including `claude mcp add`).
        var yes = false
        /// The project directory rule files go into; default the current one.
        var project: String?
    }

    public struct ReserveOptions: Equatable {
        var port: Int
        var ttl: TimeInterval = Reservation.defaultTTL
        var reason: String?
        var json = false
    }

    public struct ExecOptions: Equatable {
        var port: Int?
        var prefer = 3000
        var range: ClosedRange<Int> = 3000...3999
        /// True once --range was typed, so --prefer stops moving it.
        var rangeWasGiven = false
        /// And the other way round: a range alone moves the preferred port.
        var preferWasGiven = false
        var reserve = true
        var owner: String?
        var session: String?
        var command: [String] = []
    }

    public struct WhoisOptions: Equatable {
        var port: Int?
        var pid: Int?
        var json = false
    }

    public struct HistoryOptions: Equatable {
        var json = false
        var port: Int?
        var limit = 20
        /// Refusals too; kills only by default, so `killedBy` keeps meaning who killed.
        var all = false
    }

    public struct ListOptions: Equatable {
        var json = false
        var mine = false
        var unowned = false
        var orphaned = false
        var agent: String?
    }

    public struct KillOptions: Equatable {
        var port: Int?
        var pid: Int?
        var force = false
        var dryRun = false
        var json = false
        /// `free`: an already-free port is success, so `portnanny free 3000
        /// && npm run dev` works under `set -e`.
        var freeIsSuccess = false
        /// Every server whose agent session has ended, instead of a port.
        var orphaned = false
    }
}
