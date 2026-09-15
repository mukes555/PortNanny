import Foundation

/// `portnanny mcp`: a Model Context Protocol server over stdin/stdout, so an
/// agent gets the guard as a tool instead of a habit. Newline-delimited
/// JSON-RPC 2.0, no dependencies. The agent spawns and reaps this process;
/// nothing is resident, registered, or wrapped, which keeps it inside the
/// project's passive charter. Only responses go to stdout; everything else
/// goes to stderr or the unified log.
public final class MCPServer {
    /// Refused, failed, still running, or blocked by a supervisor: the port
    /// is not free, so the tool result is an error the agent must read.
    static let killNotDone: Set<Int32> = [CLIExit.refused, CLIExit.killFailed, CLIExit.stillRunning, CLIExit.managed]

    public static let protocolVersion = "2024-11-05"

    public func serve() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        // A person who runs this by hand sees a silent prompt otherwise. Goes
        // to stderr, and only on a terminal, so an agent's log stays clean.
        if isatty(2) != 0 {
            PortNannyCLI.printError("PortNanny MCP server \(UpdateChecker.currentVersion ?? "dev") ready: reading JSON-RPC on stdin, answering on stdout.")
            PortNannyCLI.printError("Meant to be launched by an agent, not by hand; `portnanny mcp --setup` shows how to register it. Ctrl-C to stop.")
        }
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = handle(line: line) {
                print(reply)
                fflush(stdout)
            }
        }
        return CLIExit.ok
    }

    /// One request in, one response out (nil for notifications). Exposed
    /// for tests, which drive the protocol without a process.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
        let id = request["id"]
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]

        if method.hasPrefix("notifications/") { return nil }
        guard let id else { return nil }
        // JSON-RPC ids are strings, numbers, or null. Echoing anything else
        // back, such as the -Infinity that `-1e999` parses to, raised an
        // exception Swift cannot catch and took the whole server down.
        guard Self.isValidRequestID(id) else {
            return fail(NSNull(), code: -32600, message: "invalid request: id must be a string, a finite number, or null")
        }

        switch method {
        case "initialize":
            return respond(id, [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "portnanny", "version": UpdateChecker.currentVersion ?? "dev"],
            ])
        case "ping":
            return respond(id, [:])
        case "tools/list":
            return respond(id, ["tools": Self.tools])
        case "tools/call":
            // This process lives as long as the agent's session; the person
            // may have changed the guard or the lease length since it began.
            Policy.loadFromSharedDomain()
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let result = call(tool: name, arguments: arguments) else {
                return fail(id, code: -32602, message: "unknown tool '\(name)'")
            }
            return respond(id, result)
        default:
            return fail(id, code: -32601, message: "method not found: \(method)")
        }
    }

    // MARK: - Tools

    public static let tools: [[String: Any]] = [
        [
            "name": "list_ports",
            "description": "Listening TCP ports and bound UDP sockets with process, memory, bind address, and the AI agent that started each. filter: all | mine | unowned | orphaned; agent: name to filter by.",
            "inputSchema": ["type": "object", "properties": [
                "filter": ["type": "string", "enum": ["all", "mine", "unowned", "orphaned"]],
                "agent": ["type": "string"],
            ]],
        ],
        [
            "name": "kill_port",
            "description": "Stop every process listening on a port (SIGTERM, verified). dry_run is true by default: call again with dry_run=false to act. Refuses (isError) when another agent's running session owns the port, when a server nobody claims is asked for by an agent (Settings > Agents can turn that part off), or when the port is leased by someone else; do not set force unless the user said so.",
            "inputSchema": ["type": "object", "properties": [
                "port": ["type": "integer"],
                "pid": ["type": "integer"],
                "dry_run": ["type": "boolean", "default": true],
                "force": ["type": "boolean", "default": false],
            ]],
        ],
        [
            "name": "whois_port",
            "description": "Everything PortNanny knows about what listens on a port (or a pid): process, project, connected clients, the AI agent that started it with the evidence for that, and what kill_port would do for you and why.",
            "inputSchema": ["type": "object", "properties": [
                "port": ["type": "integer"],
                "pid": ["type": "integer"],
            ]],
        ],
        [
            "name": "free_port",
            "description": "The first port that nothing listens on, nobody else has leased, and that can be bound right now, starting at prefer (default 3000).",
            "inputSchema": ["type": "object", "properties": [
                "prefer": ["type": "integer", "default": 3000],
                "range_end": ["type": "integer"],
            ]],
        ],
        [
            "name": "reserve_port",
            "description": "Lease a free port for a while (default from Settings, 10 minutes unless changed) so free_port does not hand it to another agent and kill_port refuses others. Renews your own lease; fails when someone else holds it.",
            "inputSchema": ["type": "object", "properties": [
                "port": ["type": "integer"],
                "minutes": ["type": "number", "default": 10],
                "reason": ["type": "string"],
            ], "required": ["port"]],
        ],
        [
            "name": "release_port",
            "description": "Give back a lease you took with reserve_port.",
            "inputSchema": ["type": "object", "properties": ["port": ["type": "integer"]], "required": ["port"]],
        ],
        [
            "name": "whoami",
            "description": "How PortNanny identifies the calling agent for the friendly-fire guard.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "wait_for_port_free",
            "description": "Block until nothing listens on the port, up to timeout_seconds (max 30).",
            "inputSchema": ["type": "object", "properties": [
                "port": ["type": "integer"],
                "timeout_seconds": ["type": "number", "default": 10],
            ], "required": ["port"]],
        ],
    ]

    private func call(tool: String, arguments: [String: Any]) -> [String: Any]? {
        switch tool {
        case "list_ports":
            var options = CLICommand.ListOptions()
            switch arguments["filter"] as? String {
            case "mine": options.mine = true
            case "unowned": options.unowned = true
            case "orphaned": options.orphaned = true
            case .none, "all", "": break
            case .some(let unknown):
                // A misspelt filter used to answer with every port, which an
                // agent reads as "none of these are mine".
                return toolResult(text: "list_ports does not know the filter '\(unknown)'; use all, mine, unowned or orphaned",
                                  structured: nil as String?, isError: true)
            }
            options.agent = arguments["agent"] as? String
            let scan = PortNannyCLI.scan(refreshDocker: true)
            // "mine" with nobody to compare against is not an empty answer,
            // it is an unanswerable question.
            if options.mine, scan.caller == nil {
                return toolResult(text: "PortNanny cannot tell who you are, so it cannot say which ports are yours. Export PORTNANNY_OWNER=<name> (and PORTNANNY_SESSION=<unique>) for the process that starts your servers, then call whoami.",
                                  structured: nil as String?, isError: true)
            }
            let ports = PortNannyCLI.filtered(scan.ports, by: options, caller: scan.caller)
            let summary = ports.isEmpty ? "No listening ports match." : ports.map { ":\($0.port) \($0.processName) (pid \($0.pid))\($0.agentOwner.map { " owned by \($0.label)" } ?? "")" }.joined(separator: "\n")
            return toolResult(text: summary, structured: ports, isError: false)

        case "kill_port":
            var options = CLICommand.KillOptions()
            options.port = arguments["port"] as? Int
            options.pid = arguments["pid"] as? Int
            options.dryRun = arguments["dry_run"] as? Bool ?? true
            options.force = arguments["force"] as? Bool ?? false
            guard options.port != nil || options.pid != nil else {
                return toolResult(text: "kill_port needs a port or a pid", structured: nil as String?, isError: true)
            }
            // Checked here rather than left to read as "nothing is listening":
            // an agent that sent :99999 has a bug, and should be told so.
            if let port = options.port, !PortManager.isValidPortNumber(port) {
                return toolResult(text: "kill_port: :\(port) is not a port number (1-65535)", structured: nil as String?, isError: true)
            }
            if let pid = options.pid, pid <= 0 {
                return toolResult(text: "kill_port: \(pid) is not a pid", structured: nil as String?, isError: true)
            }
            let outcome = CLIKill.perform(options)
            return toolResult(text: outcome.text, structured: outcome.report, isError: Self.killNotDone.contains(outcome.report.exitCode))

        case "free_port":
            let prefer = arguments["prefer"] as? Int ?? 3000
            let end = arguments["range_end"] as? Int ?? min(prefer + 999, 65535)
            guard PortManager.isValidPortNumber(prefer), PortManager.isValidPortNumber(end), end >= prefer else {
                return toolResult(text: "free_port needs a valid prefer and range_end", structured: nil as String?, isError: true)
            }
            let listening = Set((NativeScanner.allListeners() ?? []).map(\.port))
            let reserved = ReservationStore.appStore().portsReservedByOthers(for: PortNannyCLI.callerIdentity())
            let port = PortNannyCLI.firstFreePort(prefer: prefer, range: prefer...end, listening: listening.union(reserved))
            let report = PortNannyCLI.FreePortReport(port: port, preferred: prefer, range: "\(prefer)-\(end)", exitCode: port == nil ? CLIExit.notFound : CLIExit.ok)
            return toolResult(text: port.map { "\($0)" } ?? "no free port in \(prefer)-\(end)", structured: report, isError: port == nil)

        case "reserve_port":
            guard let port = arguments["port"] as? Int, PortManager.isValidPortNumber(port) else {
                return toolResult(text: "reserve_port needs a port", structured: nil as String?, isError: true)
            }
            var options = CLICommand.ReserveOptions(port: port)
            options.ttl = (arguments["minutes"] as? Double).map { $0 * 60 } ?? Policy.defaultLeaseTTL
            options.reason = arguments["reason"] as? String
            let report = CLIReserve.performReserve(options)
            let text = report.reservation.map { "\(report.action) :\(port) as \($0.describedHolder), \($0.expiryDescription())" } ?? report.reasons.joined(separator: "\n")
            return toolResult(text: text, structured: report, isError: report.exitCode != CLIExit.ok)

        case "release_port":
            guard let port = arguments["port"] as? Int, PortManager.isValidPortNumber(port) else {
                return toolResult(text: "release_port needs a port", structured: nil as String?, isError: true)
            }
            let report = CLIReserve.performRelease(port: port, force: false)
            return toolResult(text: "\(report.action) :\(port)", structured: report, isError: report.exitCode == CLIExit.refused)

        case "whois_port":
            var options = CLICommand.WhoisOptions()
            options.port = arguments["port"] as? Int
            options.pid = arguments["pid"] as? Int
            guard options.port != nil || options.pid != nil else {
                return toolResult(text: "whois_port needs a port or a pid", structured: nil as String?, isError: true)
            }
            let report = CLIWhois.perform(options)
            return toolResult(text: CLIWhois.text(for: report), structured: report, isError: false)

        case "whoami":
            let me = PortNannyCLI.callerIdentity()
            let text = me.map { "\($0.described), detected from \($0.source.rawValue)" } ?? "Not identified as an AI agent. Export PORTNANNY_OWNER=<name>."
            return toolResult(text: text, structured: PortNannyCLI.WhoAmI(detected: me != nil, owner: me), isError: false)

        case "wait_for_port_free":
            guard let port = arguments["port"] as? Int else {
                return toolResult(text: "wait_for_port_free needs a port", structured: nil as String?, isError: true)
            }
            guard PortManager.isValidPortNumber(port) else {
                return toolResult(text: "wait_for_port_free: :\(port) is not a port number (1-65535)", structured: nil as String?, isError: true)
            }
            // Capped: this blocks the whole server loop.
            let timeout = min(arguments["timeout_seconds"] as? Double ?? 10, 30)
            let report = PortNannyCLI.waitUntilFree(port: port, timeout: timeout)
            // A wait that ran out did not do what was asked, and said so in
            // words while reporting success in the field agents check.
            return toolResult(text: report.free ? ":\(port) is free." : ":\(port) is still in use after \(Int(timeout))s.",
                              structured: report, isError: !report.free)

        default:
            return nil
        }
    }

    // MARK: - Encoding

    private func toolResult<T: Encodable>(text: String, structured: T?, isError: Bool) -> [String: Any] {
        var result: [String: Any] = ["content": [["type": "text", "text": text]], "isError": isError]
        if let structured, let data = try? JSONEncoder().encode(structured),
           let object = try? JSONSerialization.jsonObject(with: data) {
            result["structuredContent"] = object
        }
        return result
    }

    private func respond(_ id: Any, _ result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func fail(_ id: Any, code: Int, message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// `JSONSerialization.data(withJSONObject:)` raises an Objective-C
    /// exception, which `try?` does not catch, for a non-finite number anywhere
    /// in the object. Checking first keeps a NaN in a tool result, or an
    /// infinite id, from crashing the server an agent depends on.
    private func encode(_ object: [String: Any]) -> String {
        let fallback = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"could not encode response"}}"#
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return text
    }

    static func isValidRequestID(_ id: Any) -> Bool {
        if id is NSNull || id is String { return true }
        guard let number = id as? NSNumber else { return false }
        // NSNumber wraps booleans too, and `true` is not a request id.
        let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
        return !isBoolean && number.doubleValue.isFinite
    }
}
