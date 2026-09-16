import PortNannyCore
import SwiftUI

/// Which AI tools this Mac has, and how many of each are running.
///
/// This used to be a table in Settings, which is the wrong place for what is
/// happening on the machine: it belongs beside the sessions it explains.
/// Finding the tools walks the process table and PATH, so it runs off the
/// main thread and at most once a minute, however often the list redraws.
final class AgentTools: ObservableObject {
    static let shared = AgentTools()

    @Published private(set) var tools: [DoctorAgents.Status] = []
    /// Until the first look finishes, "none found" would be a lie.
    @Published private(set) var hasLoaded = false
    private var loadedAt = Date.distantPast
    private var isLoading = false
    static let freshFor: TimeInterval = 60

    /// The tools worth showing: running now, or installed and ready. A tool
    /// that is not on this Mac at all is Settings' business (it has setup).
    var present: [DoctorAgents.Status] {
        Self.present(in: tools)
    }

    static func present(in tools: [DoctorAgents.Status]) -> [DoctorAgents.Status] {
        tools.filter { $0.running > 0 || $0.installedAt != nil }
            .sorted { a, b in
                if (a.running > 0) != (b.running > 0) { return a.running > 0 }
                return a.name < b.name
            }
    }

    func refreshIfStale(now: Date = Date()) {
        let isFresh = now.timeIntervalSince(loadedAt) < Self.freshFor
        guard !isLoading, !isFresh else { return }
        isLoading = true
        DispatchQueue.global(qos: .utility).async {
            let found = DoctorAgents.report().agents
            DispatchQueue.main.async {
                self.tools = found
                self.hasLoaded = true
                self.loadedAt = Date()
                self.isLoading = false
            }
        }
    }

    #if DEBUG
    /// Scripted tools for README images, which must never show this Mac's.
    func showForDemo(_ scripted: [DoctorAgents.Status]) {
        tools = scripted
        hasLoaded = true
        loadedAt = .distantFuture
    }
    #endif
}

/// The tools as a strip of chips: teal with a count while running, grey when
/// installed and idle.
struct AgentToolChips: View {
    let tools: [DoctorAgents.Status]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tools, id: \.name) { tool in
                    if tool.running > 0 {
                        Chip(icon: "sparkles", text: "\(tool.name) · \(tool.running)", tint: .chipTeal)
                            .help("\(tool.running) \(tool.name) process\(tool.running == 1 ? "" : "es") running. \(tool.session)")
                    } else {
                        Chip(icon: "checkmark", text: tool.name, tint: .secondary)
                            .help("Installed\(tool.installedAt.map { " at \($0)" } ?? ""), not running. \(tool.session)")
                    }
                }
            }
        }
    }
}

/// The last section of the Agents view: the tools the sessions above come
/// from, and the way into setting one up.
struct AgentToolsSection: View {
    @ObservedObject var tools: AgentTools
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Capsule()
                    .fill(Color.secondary)
                    .frame(width: 3, height: 12)
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Text("AI tools on this Mac")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.primary)
                Spacer()
                Button("Set up…") { appDelegate.openSettings(pane: .agents) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .help("Rule files and MCP registration for each tool, in Settings")
            }
            if !tools.hasLoaded {
                Text("Looking…")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.leading, 11)
            } else if tools.present.isEmpty {
                Text("None found. Claude Code, Codex, Cursor, Gemini, Copilot and the rest show up here once installed.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.leading, 11)
            } else {
                AgentToolChips(tools: tools.present)
                    .padding(.leading, 11)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { tools.refreshIfStale() }
    }
}
