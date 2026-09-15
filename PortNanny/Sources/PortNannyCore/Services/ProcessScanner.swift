import Foundation

public class ProcessScanner {

    private let testKeywords = [
        "jest",
        "vitest",
        "mocha",
        "jasmine",
        "karma",
        "react-scripts test",
        "ava",
        "tape",
        "cypress",
        "playwright",
        "puppeteer",
        "selenium",
        "webdriver",
        "nightwatch",
        "protractor",
        "testcafe"
    ]

    /// Filters test processes out of a shared process snapshot
    /// (no subprocess spawned here).
    public func scanTestProcesses(processes: ProcessTable) -> [TestProcessInfo] {
        processes.allEntries
            .compactMap { entry -> TestProcessInfo? in
                guard let info = makeTestInfo(pid: entry.pid, memoryKb: entry.rssKB, command: entry.command,
                                              cpuPercent: entry.cpuPercent, name: entry.name) else { return nil }
                return info.withOwner(AgentAttribution.owner(ofPid: entry.pid, in: processes))
            }
            .sorted { $0.pid < $1.pid }
    }

    /// Parses raw "PID RSS COMMAND" lines (kept as the testable entry point).
    public func parseProcessOutput(_ output: String) -> [TestProcessInfo] {
        var processes: [TestProcessInfo] = []

        for line in output.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }

            let parts = trimmedLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int(parts[0]),
                  let memoryKb = Int(parts[1]) else { continue }

            if let info = makeTestInfo(pid: pid, memoryKb: memoryKb, command: String(parts[2])) {
                processes.append(info)
            }
        }

        return processes
    }

    /// `name` is the kernel's, whenever the caller has it. Taking it from the
    /// command splits on the first space, so a test worker under
    /// "~/Library/Application Support/fnm/…/node" was called "Application" and
    /// its kill was refused: "PID 42 now belongs to 'node'".
    private func makeTestInfo(pid: Int, memoryKb: Int, command: String, cpuPercent: Double = 0, name: String? = nil) -> TestProcessInfo? {
        guard let type = determineTestType(command: command) else { return nil }

        return TestProcessInfo(
            pid: pid,
            processName: name ?? extractProcessName(from: command),
            command: CommandRedaction.redact(command),
            memoryUsage: MemoryFormat.string(kilobytes: memoryKb),
            memorySizeKB: memoryKb,
            cpuPercent: cpuPercent,
            type: type
        )
    }

    private func determineTestType(command: String) -> TestProcessInfo.TestType? {
        let lowerCommand = command.lowercased()

        // Filter out PortNanny itself and common system tools to avoid false
        // positives. Match both the product name and the (double-a) dev folder.
        if lowerCommand.contains("portnanny") || lowerCommand.contains("portkilaa") || lowerCommand.contains("grep") {
            return nil
        }

        // Exclude common dev servers that might trigger false positives (e.g. if they have 'test' in path)
        if lowerCommand.contains("next dev") || lowerCommand.contains("next start") || lowerCommand.contains("react-scripts start") {
            return nil
        }

        // Exclude internal drivers/helpers
        if lowerCommand.contains("run-driver") || lowerCommand.contains("ms-playwright-go") {
            return nil
        }

        if lowerCommand.contains("jest") { return .jest }
        if lowerCommand.contains("vitest") { return .vitest }
        if lowerCommand.contains("mocha") { return .mocha }

        for keyword in testKeywords {
            if lowerCommand.contains(keyword) {
                return .other
            }
        }

        return nil
    }

    private func extractProcessName(from command: String) -> String {
        // Last path component of the executable, e.g. "/usr/local/bin/node ..." -> "node"
        let components = command.components(separatedBy: " ")
        if let first = components.first {
            let pathComponents = first.components(separatedBy: "/")
            if let last = pathComponents.last {
                return last
            }
        }
        return "Unknown"
    }
}
