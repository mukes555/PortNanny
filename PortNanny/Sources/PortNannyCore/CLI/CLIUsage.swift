import Foundation

/// The help text, kept apart from the parser so the two stay readable.
extension CLIArguments {

    /// Per-command help; nil topic (or an unknown one) gives the overview.
    public static func usage(for topic: String?) -> String {
        switch topic {
        case "list": return """
            portnanny list [--json] [--mine | --agent <name> | --unowned | --orphaned]

            Lists listening TCP ports and bound UDP sockets with process, memory,
            owning AI agent, and bind address. --json prints the same as an array
            (stable field names; new fields are only ever added). The header is
            omitted when stdout is not a terminal.
              --mine      ports kill would let you stop without --force
              --agent X   ports owned by that agent (names are case-insensitive)
              --unowned   ports with no known owner
              --orphaned  ports whose owning session has ended
            """
        case "kill", "free": return """
            portnanny kill <port> [--force|-9] [--dry-run] [--json]
            portnanny kill --pid <pid> [...]
            portnanny kill --orphaned [--dry-run] [--json]
            portnanny free <port> [...]

            Stops every process listening on the port (SIGTERM, verified; --force
            sends SIGKILL). Refuses (exit 3) when another AI agent's running
            session owns it, or when the caller is an agent and nobody claims the
            server (Settings > Agents can turn that part off), unless --force.
            --dry-run reports the decision without signalling. free is the same
            command with exit 0 when the port was already free, for
            `portnanny free 3000 && npm run dev`. --orphaned
            stops every server left behind by an agent session that has ended
            (any agent's); exit 0 when there is nothing to clean up.

            A supervised listener is stopped the way its supervisor expects: a
            reloader (nodemon, next dev, uvicorn --reload, a gunicorn master) is
            stopped together with its child; a pm2 app, a launchd job, or a Docker
            container gets its own stop command (pm2 stop, brew services stop or
            launchctl bootout, docker stop), run for you when the tool is on PATH
            and printed with exit 6 when it is not. --force kills the listener
            itself regardless.

            Exit codes: 0 done, 1 nothing listening, 2 usage, 3 refused, 4 kill
            failed, 5 still running after the wait, 6 managed, 70 internal error.
            """
        case "whois": return """
            portnanny whois <port> [--json]
            portnanny whois --pid <pid> [--json]

            Everything PortNanny knows about what listens there: process, command,
            project, connected clients, the AI agent that started it together with
            the evidence (ancestry, environment markers, declaration), and what
            `kill` would do for you and why. Exit 1 when nothing listens.
            """
        case "wait": return """
            portnanny wait <port> [--timeout 30] [--json]

            Blocks until nothing listens on the port. Exit 0 when free, 5 on timeout.
            """
        case "history": return """
            portnanny history [--json] [--port <port>] [--limit 20] [--all]

            Recent kills from the app and the CLI, newest first, with who started
            and who stopped each process. --all adds the guard's refusals (action
            "Refused"; there, killedBy names the agent that was refused).
            """
        case "whoami": return """
            portnanny whoami [--json]

            How the friendly-fire guard identifies the calling process: agent name,
            session, and whether it was detected from the process tree, the
            environment, or declared via PORTNANNY_OWNER (and PORTNANNY_SESSION).
            """
        case "agent-docs": return """
            portnanny agent-docs [--write [--file <path>]] [--claude|--codex|--cursor|--windsurf] [--claude-hook]

            Prints the snippet that tells AI agents to free ports through PortNanny.
            --write appends it to CLAUDE.md (or --file) between markers, once; run
            again to update it. --codex writes AGENTS.md, --cursor writes
            .cursor/rules/portnanny.mdc, --windsurf .windsurf/rules/portnanny.md
            (folders and frontmatter included). --claude-hook prints a Claude Code
            PreToolUse hook for settings.json that turns `kill -9 $(lsof -ti:PORT)`
            into a nudge.
            """
        case "setup": return """
            portnanny setup [--yes] [--project <dir>]

            Walks through setting PortNanny up for the AI tools on this Mac: checks
            `portnanny` on PATH, and for each tool found offers to register the MCP
            server (Claude Code, by running `claude mcp add`), write its rule file
            into the project (CLAUDE.md, AGENTS.md, .cursor/rules, .windsurf/rules),
            and shows the rest (Cursor's mcp.json, Codex's config.toml, shell
            completions). Asks before every change; --yes applies all of them.
            Without a terminal it prints the plan and changes nothing.
            """
        case "mcp": return """
            portnanny mcp
            portnanny mcp --setup [claude|cursor|codex]

            Runs a Model Context Protocol server over stdin/stdout with the tools
            list_ports, whois_port, kill_port (dry-run by default), free_port,
            reserve_port, release_port, whoami, and wait_for_port_free. It is not
            a background service: each agent starts
            its own copy when it needs one and stops it afterwards, so register it
            once and forget it. `--setup` prints the registration (the exact
            `claude mcp add` command, Cursor's mcp.json, Codex's config.toml).
            Run by hand it waits silently for requests; Ctrl-C stops it.
            """
        case "free-port": return """
            portnanny free-port [--prefer 3000] [--range A-B] [--json]

            Prints the first port in the range that nothing listens on and that can
            be bound right now, starting at --prefer (default 3000; default range is
            the preferred port plus 999). Stateless: no reservation is made. Exit 1
            when the whole range is taken.
            """
        case "schema": return """
            portnanny schema [list|kill|whois|whoami|wait|history|version|doctor|agents|free-port|reserve|release|reservations|drift]

            Prints the JSON contract for a command's --json output: every field and
            its meaning (`agents` is `doctor --agents`). Fields are only ever added,
            never renamed or removed, within a schema version.
            """
        case "reserve", "release", "reservations": return """
            portnanny reserve <port> [--for 10m] [--reason "..."] [--json]
            portnanny release <port> [--force] [--json]
            portnanny reservations [--json]

            A lease on a free port: free-port and exec skip it for everyone else,
            and kill refuses other agents on it, until it expires (default 10
            minutes, at most a day) or you release it. Reserving a port you already
            hold renews the lease. Exit 1 when the port is in use, 3 when someone
            else holds the lease. release needs --force for another holder's lease.
            """
        case "exec": return """
            portnanny exec [--port N | --free-port [--prefer 3000] [--range A-B]] [--no-reserve]
                           [--owner NAME] [--session KEY] -- <command> [args...]

            Runs the command with PORT set to a free port (--port must be free;
            --free-port, the default, takes the first free one nobody else has
            leased, starting at --prefer), leases the port for the run, and exports
            PORTNANNY_OWNER and PORTNANNY_SESSION (yours, unless given) so the
            server is attributed to you even when your tool leaves no marker.
            Signals are forwarded; the exit code is the command's.
            """
        case "drift": return """
            portnanny drift [--json]

            Servers that run somewhere other than where their project says: PORT in
            .env files, --port or PORT= in package.json scripts, port: in
            vite.config. Each line says which port was meant, and who holds it now.
            """
        case "doctor": return """
            portnanny doctor [--json] [--agents]

            Version, macOS, architecture, install source, quarantine state, which
            scanner is in use and how long a scan takes, PATH resolution, and login
            item status. Paste it into bug reports.

            --agents prints the agent compatibility matrix against this machine:
            which tools are running or installed, how each is recognised, how
            precisely its sessions are told apart, and where each fact came from.
            """
        default: return usage
        }
    }

    public static let usage = """
    PortNanny, the macOS port manager

    Usage:
      portnanny list [--json] [--mine | --agent <name> | --unowned | --orphaned]
      portnanny kill <port> [--force|-9] [--dry-run] [--json]
      portnanny kill --pid <pid> [--force|-9] [--dry-run] [--json]
      portnanny kill --orphaned [--dry-run] [--json]   servers whose agent session ended
      portnanny free <port> [...]        like kill, but exit 0 if already free
      portnanny whois <port> [--json]    who started it, and why PortNanny thinks so
      portnanny reserve <port> [--for 10m] [--reason "..."] [--json]
      portnanny release <port> [--force]  |  portnanny reservations [--json]
      portnanny exec [--port N | --free-port] [--] <command...>   PORT set, leased, attributed
      portnanny drift [--json]           servers not on the port their project configured
      portnanny wait <port> [--timeout 30] [--json]
      portnanny open <port>
      portnanny history [--json] [--port <port>] [--limit 20] [--all]
      portnanny whoami [--json]
      portnanny free-port [--prefer 3000] [--range 3000-3999] [--json]
      portnanny schema [command]         JSON output contracts
      portnanny doctor [--json] [--agents]
      portnanny setup [--yes] [--project <dir>]   set the AI tools on this Mac up
      portnanny agent-docs [--write [--file CLAUDE.md]] [--claude|--codex|--cursor|--windsurf] [--claude-hook]
      portnanny mcp                      MCP server over stdio (for agents)
      portnanny mcp --setup [claude|cursor|codex]   how to register it
      portnanny completions <zsh|bash|fish>
      portnanny version [--json]
      portnanny help [command]

    kill stops every process listening on the port (use --pid for one of
    them). --dry-run reports what would happen without signalling anything.
    free is kill for scripts: `portnanny free 3000 && npm run dev`. wait
    blocks until the port is free (exit 5 on timeout). history lists recent
    kills from the app and the CLI, with who started and who stopped each.

    Friendly-fire guard: kill refuses to stop a port owned by a different AI
    agent session, or one nobody claims when the caller is an agent (the app's
    Settings > Agents can turn that part off), unless --force. Owners are
    detected from the process tree and from the environment agents leave on
    their children; export PORTNANNY_OWNER=<name> to declare who you are (and
    to label what you start), and
    PORTNANNY_SESSION=<unique> to tell your sessions apart. The PortKilla
    names, PORTKILLA_OWNER and PORTKILLA_SESSION, are read too.

    Exit codes: 0 done, 1 nothing listening, 2 usage, 3 refused (another
    agent's live session owns it, or nobody claims it), 4 kill failed (or
    only some of several ports), 5 still running after the wait, 6 managed
    (a supervisor would undo the kill; the stop command is printed),
    70 internal error, 73 a lease or history entry could not be written,
    126 exec could not start the command, 127 exec could not find it.
    --dry-run exits 0 when it would kill and 3 when it would refuse.
    `portnanny help <command>` or `<command> --help` for more.

    The GUI launches when run with no arguments.
    """
}
