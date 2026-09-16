import PortNannyCore
import SwiftUI

/// Ports grouped by the agent session that started them: live sessions,
/// ended ones (safe to clean up), editor terminals, and the unclaimed.
struct WorkbenchAgents: View {
    @ObservedObject var portManager: PortManager
    @Binding var selection: String?

    private var sessions: [AgentSessions.Group] {
        AgentSessions.groups(from: portManager.visiblePorts, leases: ReservationStore.shared.recent())
    }

    private var orphaned: [PortInfo] {
        AgentSessions.orphaned(portManager.visiblePorts)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !orphaned.isEmpty {
                HStack {
                    Image(systemName: "moon.zzz").foregroundColor(.secondary)
                    Text("\(orphaned.count) server\(orphaned.count == 1 ? "" : "s") left behind by ended sessions")
                        .font(.caption)
                    Spacer()
                    Button("Clean up") {
                        KillFlow(portManager: portManager).requestKillAll(orphaned, label: "Clean up ended sessions")
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()
            }
            if sessions.isEmpty {
                WorkbenchEmpty(icon: "sparkles", text: "No listening ports")
            } else {
                List(sessions) { session in
                    card(for: session)
                        .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }
            Divider()
            AgentToolsSection(tools: AgentTools.shared)
        }
    }

    private func card(for session: AgentSessions.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: session.kind.icon)
                    .foregroundColor(tint(for: session.kind))
                Text(session.title).font(.headline)
                if session.kind == .live {
                    Chip(text: "running", tint: .chipTeal)
                } else if session.kind == .ended {
                    Chip(text: "ended", tint: .secondary)
                }
                Spacer()
                Text(session.ports.isEmpty
                     ? "\(session.claims.count) claimed"
                     : "\(session.ports.count) port\(session.ports.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(session.subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
            if !session.ports.isEmpty {
                PortChipRow(ports: session.ports, selection: $selection)
            }
            // A session can hold a port before it starts anything on it.
            ForEach(session.claims) { claim in
                HStack(spacing: 6) {
                    Image(systemName: "bookmark").font(.caption2).foregroundColor(.secondary)
                    Text(":" + String(claim.port)).font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text(claim.reason ?? "reserved, nothing listening yet").font(.caption).foregroundColor(.secondary).lineLimit(1)
                    Text(claim.expiryDescription()).font(.caption2).foregroundColor(.secondary)
                }
            }
            if !session.ports.isEmpty, session.kind.hasBulkVerb {
                HStack(spacing: 8) {
                    Button(session.kind == .ended ? "Clean up (\(session.ports.count))" : "Stop all (\(session.ports.count))") {
                        KillFlow(portManager: portManager).requestKillAll(session.ports, label: "Stop \(session.title)",
                                                                         confirmTitle: session.kind == .ended ? "Clean Up" : "Stop All")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func tint(for kind: AgentSessions.Group.Kind) -> Color {
        switch kind {
        case .live: return .chipTeal
        default: return .secondary
        }
    }
}
