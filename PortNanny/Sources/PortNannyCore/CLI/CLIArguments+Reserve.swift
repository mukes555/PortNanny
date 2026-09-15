import Foundation

// MARK: - reserve, release, exec
extension CLIArguments {

    static func parseReserve(_ args: [String]) -> Result<CLICommand, ParseError> {
        var port: Int?
        var ttl = Policy.defaultLeaseTTL
        var reason: String?
        var json = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--json" {
                json = true
            } else if arg == "--for" || arg == "--reason" {
                guard index + 1 < args.count else { return .failure(.missingValue(arg)) }
                index += 1
                if arg == "--for" {
                    guard let seconds = Reservation.parseTTL(args[index]) else { return .failure(.invalidNumber(args[index], option: "--for")) }
                    ttl = seconds
                } else {
                    reason = args[index]
                }
            } else if let value = valueOf(option: "--for", in: arg) {
                guard let seconds = Reservation.parseTTL(value) else { return .failure(.invalidNumber(value, option: "--for")) }
                ttl = seconds
            } else if let value = valueOf(option: "--reason", in: arg) {
                reason = value
            } else if arg.hasPrefix("-") {
                return .failure(.unknownOption(arg, command: "reserve"))
            } else if let number = Int(arg), PortManager.isValidPortNumber(number) {
                guard port == nil else { return .failure(.tooManyTargets) }
                port = number
            } else {
                return .failure(.invalidNumber(arg, option: "port"))
            }
            index += 1
        }
        guard let port else { return .failure(.missingTarget) }
        var options = CLICommand.ReserveOptions(port: port)
        options.ttl = ttl
        options.reason = reason
        options.json = json
        return .success(.reserve(options))
    }

    static func parseRelease(_ args: [String]) -> Result<CLICommand, ParseError> {
        var port: Int?
        var force = false
        var json = false
        for arg in args {
            switch arg {
            case "--json": json = true
            case "--force": force = true
            default:
                guard !arg.hasPrefix("-") else { return .failure(.unknownOption(arg, command: "release")) }
                guard let number = Int(arg), PortManager.isValidPortNumber(number) else { return .failure(.invalidNumber(arg, option: "port")) }
                guard port == nil else { return .failure(.tooManyTargets) }
                port = number
            }
        }
        guard let port else { return .failure(.missingTarget) }
        return .success(.release(port: port, force: force, json: json))
    }

    /// Options up to `--` (or the first bare word), then the command.
    static func parseExec(_ args: [String]) -> Result<CLICommand, ParseError> {
        var options = CLICommand.ExecOptions()
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                options.command = Array(args[(index + 1)...])
                break
            }
            if !arg.hasPrefix("-") {
                options.command = Array(args[index...])
                break
            }
            switch arg {
            case "--free-port": options.port = nil
            case "--no-reserve": options.reserve = false
            case "--port", "--prefer", "--range", "--owner", "--session":
                guard index + 1 < args.count else { return .failure(.missingValue(arg)) }
                index += 1
                if let failure = applyExecValue(arg, args[index], to: &options) { return .failure(failure) }
            default:
                guard let equals = arg.firstIndex(of: "=") else { return .failure(.unknownOption(arg, command: "exec")) }
                let option = String(arg[..<equals])
                guard ["--port", "--prefer", "--range", "--owner", "--session"].contains(option) else { return .failure(.unknownOption(arg, command: "exec")) }
                if let failure = applyExecValue(option, String(arg[arg.index(after: equals)...]), to: &options) { return .failure(failure) }
            }
            index += 1
        }
        guard !options.command.isEmpty else { return .failure(.missingValue("exec [--port N | --free-port] -- <command>")) }
        guard options.range.contains(options.prefer) else { return .failure(.invalidNumber("\(options.prefer)", option: "--prefer (outside --range)")) }
        return .success(.exec(options))
    }

    static func applyExecValue(_ option: String, _ value: String, to options: inout CLICommand.ExecOptions) -> ParseError? {
        switch option {
        case "--port":
            guard let port = Int(value), PortManager.isValidPortNumber(port) else { return .invalidNumber(value, option: option) }
            options.port = port
        case "--prefer":
            guard let port = Int(value), PortManager.isValidPortNumber(port) else { return .invalidNumber(value, option: option) }
            options.prefer = port
            options.preferWasGiven = true
            // --prefer shifts the default window; an explicit --range wins,
            // even when the caller typed the default.
            if !options.rangeWasGiven { options.range = port...min(port + 999, 65535) }
        case "--range":
            guard let range = parseRange(value) else { return .invalidNumber(value, option: option) }
            options.range = range
            options.rangeWasGiven = true
            // A range on its own moves the preferred port into it; the
            // default of 3000 used to reject `--range 5000-5999` outright.
            if !options.preferWasGiven { options.prefer = range.lowerBound }
        case "--owner":
            options.owner = value
        case "--session":
            options.session = value
        default:
            return .unknownOption(option, command: "exec")
        }
        return nil
    }
}
