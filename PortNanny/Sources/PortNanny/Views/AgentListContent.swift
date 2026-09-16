import PortNannyCore
import SwiftUI

/// The Agents view: one section per session, the ports it is running, and
/// the ports it has claimed and not started on yet. Rows are the same rows
/// the Ports view shows, so everything (verbs, tree, chips) behaves alike.
struct AgentListContent: View {
    let groups: [AgentSessions.Group]
    let metrics: RowMetrics
    @ObservedObject var portManager: PortManager
    @Binding var selectedId: String?
    @Binding var expandedIds: Set<String>
    let onSelectPort: (PortInfo) -> Void
    let onKillRequest: (PortInfo, _ force: Bool, _ killTree: Bool) -> Void
    let onKillChild: (PortInfo.ProcessInfo) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        AgentSectionView(
                            group: group,
                            metrics: metrics,
                            portManager: portManager,
                            selectedId: $selectedId,
                            expandedIds: $expandedIds,
                            onSelectPort: onSelectPort,
                            onKillRequest: onKillRequest,
                            onKillChild: onKillChild
                        )
                    }
                }
            }
            .onChange(of: selectedId) { newValue in
                if let newValue {
                    proxy.scrollTo(newValue)
                }
            }
        }
    }
}

struct AgentSectionView: View {
    let group: AgentSessions.Group
    let metrics: RowMetrics
    @ObservedObject var portManager: PortManager
    @Binding var selectedId: String?
    @Binding var expandedIds: Set<String>
    let onSelectPort: (PortInfo) -> Void
    let onKillRequest: (PortInfo, _ force: Bool, _ killTree: Bool) -> Void
    let onKillChild: (PortInfo.ProcessInfo) -> Void

    var body: some View {
        Section(header: AgentSectionHeader(group: group, portManager: portManager)) {
            ForEach(group.ports) { port in
                PortRowView(
                    port: port,
                    showsDetails: portManager.showsDetails,
                    hidesAgentChip: true,
                    metrics: metrics,
                    isProtected: portManager.isProtectedProcessName(port.processName),
                    isWatched: portManager.isWatched(port.port),
                    isTerminating: portManager.terminatingPids.contains(port.pid),
                    isSelected: selectedId == port.id,
                    manager: portManager,
                    isExpanded: expansionBinding(for: port.id),
                    onSelect: { onSelectPort(port) },
                    onKillRequest: { force, killTree in onKillRequest(port, force, killTree) },
                    onKillChild: onKillChild
                )
                    .id(port.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
                Divider()
            }
            ForEach(group.claims) { claim in
                ClaimRow(claim: claim, metrics: metrics, isAgents: group.kind == .live, portManager: portManager)
                Divider()
            }
        }
        .animation(.easeInOut(duration: 0.18), value: group.ports.map(\.id))
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedIds.contains(id) },
            set: { expanded in
                if expanded {
                    expandedIds.insert(id)
                } else {
                    expandedIds.remove(id)
                }
            }
        )
    }
}

/// Who the section is, how much it is running, and the one verb that applies
/// to all of it: stop what a session is running, or clean up after one that
/// has ended.
struct AgentSectionHeader: View {
    let group: AgentSessions.Group
    @ObservedObject var portManager: PortManager

    /// The last time another agent was told no about one of these ports.
    /// The guard's whole job, and until now it happened out of sight.
    private var refusal: PortHistoryItem? {
        let ours = Set(group.ports.map(\.port))
        return portManager.history.refusals.first {
            ours.contains($0.port) && Date().timeIntervalSince($0.timestamp) < 30 * 60
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 12)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(tint)
                Text(group.title)
                    .font(.caption.weight(.bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if group.kind == .live {
                    Chip(text: "running", tint: .chipTeal)
                } else if group.kind == .ended {
                    Chip(text: "ended", tint: .secondary)
                }
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                // Not for "No agent": that group is a leftovers bin, not a
                // session, and stopping all of it would take the database
                // and Docker with it.
                if !group.ports.isEmpty, group.kind != .unattributed {
                    Button(group.kind == .ended ? "Clean up" : "Stop all") {
                        KillFlow(portManager: portManager).requestKillAll(
                            group.ports,
                            label: group.kind == .ended ? "Clean up \(group.title)" : "Stop \(group.title)",
                            confirmTitle: group.kind == .ended ? "Clean Up" : "Stop All"
                        )
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .help(group.kind == .ended
                          ? "Stop the servers this ended session left behind."
                          : "Stop every server this session is running.")
                }
            }
            if let refusal, let caller = refusal.killedBy {
                HStack(spacing: 4) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 9))
                    Text("\(caller) was refused :" + String(refusal.port) + " " + PortListView.timeAgo(from: refusal.timestamp))
                        .lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundColor(.chipTeal)
                .padding(.leading, 11)
                .help("PortNanny refused another agent's kill on this session's port. History has them all.")
            } else {
                Text(group.subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 11)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var summary: String {
        var parts: [String] = []
        if !group.ports.isEmpty {
            parts.append("\(group.ports.count) port\(group.ports.count == 1 ? "" : "s")")
            parts.append(MemoryFormat.string(kilobytes: group.memoryKB))
        }
        if !group.claims.isEmpty {
            parts.append("\(group.claims.count) claimed")
        }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        switch group.kind {
        case .live: return "sparkles"
        case .ended: return "moon.zzz"
        case .editor: return "terminal"
        case .unattributed: return "person"
        }
    }

    private var tint: Color {
        group.kind == .live ? .chipTeal : .secondary
    }
}

/// A port a session has leased with nothing listening on it yet: the agent
/// said "I am about to start something here". Only this view can show it,
/// because there is no process to put in a list.
struct ClaimRow: View {
    let claim: Reservation
    let metrics: RowMetrics
    let isAgents: Bool
    @ObservedObject var portManager: PortManager
    @State private var isHovered = false
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: RowMetrics.spacing) {
            // The port sits under the ports above it: a claim is a row about
            // the same column, without a process to put in it.
            Image(systemName: "bookmark")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: metrics.tile * scale)
            // String(), not the number itself: SwiftUI formats an interpolated
            // Int for the locale, and :3100 came out as ":3,100".
            Text(":" + String(claim.port))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            Text(claim.reason ?? "reserved, nothing listening yet")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(claim.expiryDescription())
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Button("Release") { release() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.accentColor)
                .opacity(isHovered ? 1 : 0.35)
        }
        .padding(.leading, 12 + metrics.gutter * scale)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help("Reserved by \(claim.describedHolder). Nothing is listening on :\(claim.port) yet.")
    }

    private func release() {
        // Another session's claim is the person's to drop, but not by
        // accident: the agent holding it is about to use that port.
        if isAgents {
            let confirmed = KillConfirm.run(
                title: "Release :\(claim.port)?",
                message: "\(claim.describedHolder) reserved it \(claim.expiryDescription()). Releasing it lets anything else take the port, including that agent's own next attempt.",
                confirmTitle: "Release"
            )
            guard confirmed else { return }
        }
        _ = ReservationStore.shared.release(port: claim.port, by: nil, force: true)
        portManager.showToast("Released :\(claim.port)")
        portManager.refresh()
    }
}
