import PortNannyCore
import SwiftUI
import AppKit

/// One port: its type tile and number, the process and what is known about
/// it, memory and CPU, and the verbs. Plain values in (not an observed
/// manager), and its own hover state, so a publish on PortManager or a
/// mouse crossing re-evaluates this row and not the list.
struct PortRowView: View {
    static func chipText(_ text: String, cap: Int = 24) -> String {
        text.count > cap ? text.prefix(cap) + "…" : text
    }

    let port: PortInfo
    /// The detail switch, not a view mode: the command line, the chips,
    /// CPU and age, and the process tree.
    let showsDetails: Bool
    /// True in the Agents view, where the section header already names the
    /// session: the same chip on every row of it is noise, and the room goes
    /// to the project instead.
    var hidesAgentChip = false
    let metrics: RowMetrics
    let isProtected: Bool
    let isWatched: Bool
    let isTerminating: Bool
    let isSelected: Bool
    /// Unobserved; the context menu, the star, and the sparkline need it.
    let manager: PortManager
    @Binding var isExpanded: Bool
    let onSelect: () -> Void
    let onKillRequest: (_ force: Bool, _ killTree: Bool) -> Void
    let onKillChild: (PortInfo.ProcessInfo) -> Void

    @State private var isHovered = false
    // Widths follow the text size so Larger Text reflows instead of clipping.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var isAdvanced: Bool { showsDetails }
    private var hasTree: Bool { !(port.children ?? []).isEmpty }
    /// Hover and selection reveal the secondary verbs.
    private var showsExtraVerbs: Bool { isHovered || isSelected }

    /// Compact identifier shown inline when details are off (project, else container).
    private var cleanSubtitle: String? {
        if let project = port.projectName { return project }
        if let container = port.containerName { return container }
        return nil
    }

    /// What VoiceOver reads for the row: the custom stack of Texts has no
    /// label of its own, and arrow-key selection is otherwise silent.
    private var accessibilityLabel: String {
        var parts = ["Port \(port.port)", port.processName, port.memoryUsage]
        if let project = port.projectName { parts.append("project \(project)") }
        if let agent = port.agentOwner { parts.append(agent.sessionEnded ? "started by \(agent.name), session ended" : "owned by \(agent.name)") }
        if port.isExposed { parts.append("exposed on all interfaces") }
        if port.connections > 0 { parts.append("\(port.connections) clients connected") }
        if isTerminating { parts.append("shutting down") }
        return parts.joined(separator: ", ")
    }

    private var rowTooltip: String {
        var lines = ["PID: \(port.pid)"]
        if let age = port.age {
            lines.append("Running for: \(age)")
        }
        lines.append(String(format: "CPU: %.1f%%", port.cpuPercent))
        lines.append("Command: \(port.command)")
        return lines.joined(separator: "\n")
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.15) }
        if isHovered { return Color.accentColor.opacity(0.06) }
        return .clear
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: RowMetrics.spacing) {
                gutter
                HStack(spacing: RowMetrics.spacing) {
                    portColumn
                    processColumn
                    metricsColumn
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // Advanced: tap toggles the tree if there is one. Simple:
                    // tap always opens details (no tree, no info button).
                    if isAdvanced, hasTree {
                        isExpanded.toggle()
                    } else {
                        onSelect()
                    }
                }
                actionColumn
            }
            .opacity(isTerminating ? 0.5 : 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            // The hover-only verbs, reachable without a mouse.
            .accessibilityAction(named: isWatched ? "Stop watching" : "Watch") { manager.toggleWatch(port.port) }
            .accessibilityAction(named: "Open in browser") { Browser.openLocalhost(port: port.port) }
            .contextMenu {
                PortRowContextMenu(port: port, manager: manager, onSelect: onSelect, onKillRequest: onKillRequest)
            }

            if isExpanded, let children = port.children, !children.isEmpty {
                childRows(children)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(background)
        .onHover { isHovered = $0 }
    }

    // MARK: - Columns

    private var gutter: some View {
        Group {
            if isAdvanced, hasTree {
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundColor(.secondary)
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse process tree" : "Expand process tree")
            } else {
                Color.clear
            }
        }
        .frame(width: metrics.gutter * scale)
    }

    private var portColumn: some View {
        HStack(spacing: 8) {
            IconTile(type: port.type, size: metrics.tile * scale)
            Text(":\(String(port.port))")
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .frame(width: metrics.port * scale, alignment: .leading)
    }

    private var processColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(port.processName)
                    .font(.title3.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Natural width, capped: fixedSize keeps the frame from
                    // filling (which starved the chips) while the cap still
                    // truncates long names.
                    .frame(maxWidth: metrics.nameCap * scale, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)

                badges

                // Simple mode: the project or container inline, since the
                // detail line is hidden.
                if !isAdvanced, let label = cleanSubtitle {
                    Text(label)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if isAdvanced {
                detailLine
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(rowTooltip)
    }

    /// Protected, watched, exposed, clients, agent: what a kill decision
    /// needs, on the first line in every density.
    @ViewBuilder
    private var badges: some View {
        if isProtected {
            Image(systemName: "shield.fill")
                .font(.caption2)
                .foregroundColor(.orange)
                .help("Protected: skipped by bulk kill actions")
        }
        if isWatched {
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundColor(.yellow)
                .help("Watched: you'll be notified when this port frees up or gets taken")
        }
        if port.isExposed {
            Chip(icon: "wifi.exclamationmark", text: "exposed", tint: .chipOrange)
                .help("Listening on all interfaces (\(port.bindAddress ?? "*")): reachable from your local network")
        }
        // Clients talking to it right now: the strongest hint that killing
        // this would break something.
        if port.connections > 0 {
            Chip(icon: "person.2", text: "\(port.connections)", tint: .chipBlue)
                .help("\(port.connections) client\(port.connections == 1 ? "" : "s") connected right now")
        }
        // Which AI agent spawned this: the friendly-fire signal.
        if let agent = port.agentOwner, !hidesAgentChip {
            AgentChip(agent: agent)
        }
    }

    /// Advanced only: project, container, lease, supervisor, then the command.
    private var detailLine: some View {
        HStack(spacing: 4) {
            if port.proto == "udp" {
                Chip(text: "UDP", tint: .chipPurple)
                    .fixedSize()
            }
            // Chips truncate at the string level and render at fixed size:
            // layout-level truncation kept stealing width from their siblings.
            if let project = port.projectName {
                Chip(icon: "folder", text: Self.chipText(project), tint: .secondary)
                    .fixedSize()
                    .help(port.projectPath ?? project)
            }
            if let container = port.containerName {
                Chip(icon: "shippingbox", text: Self.chipText(container), tint: .chipBlue)
                    .fixedSize()
                    .help(container)
            }
            if let expected = port.expectedPort {
                Chip(icon: "arrow.uturn.backward", text: "expected :\(expected.port)", tint: .chipOrange)
                    .fixedSize()
                    .help("\(expected.source) says :\(expected.port); this server ended up on :\(port.port)")
                    .accessibilityLabel("expected on port \(expected.port)")
            }
            if let lease = port.reservation {
                Chip(icon: "lock", text: "reserved", tint: .chipPurple)
                    .fixedSize()
                    .help("Reserved by \(lease.describedHolder) \(lease.expiryDescription())" + (lease.reason.map { ", for \($0)" } ?? ""))
                    .accessibilityLabel("reserved by \(lease.describedHolder)")
            }
            // A supervisor that would undo a plain kill; Docker already
            // shows as its container.
            if let managed = port.managedBy, managed.kind != .docker {
                Chip(icon: "arrow.triangle.2.circlepath", text: Self.chipText(managed.short), tint: .chipOrange)
                    .fixedSize()
                    .help("Managed by \(managed.label): \(managed.consequence)")
                    .accessibilityLabel("managed by \(managed.label)")
            }
            Text(port.command)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption.monospaced())
        .foregroundColor(.secondary)
    }

    /// Memory in every density; CPU and its trend in Advanced.
    private var metricsColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(port.memoryUsage)
                .font(.body.monospaced())
                .foregroundColor(.secondary)
            if isAdvanced {
                HStack(spacing: 4) {
                    SparklineView(metrics: manager.metrics, pid: port.pid, series: .cpu, tint: .chipTeal)
                        .frame(width: 34, height: 10)
                    Text(String(format: "%.1f%%", port.cpuPercent))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .help("CPU now, and over the last \(MetricsHistory.capacity) scans")
            }
        }
        .frame(width: metrics.memory * scale, alignment: .trailing)
    }

    /// Kill is always there; the browser and the star fade in on hover or
    /// selection so an idle list stays calm (VoiceOver reaches them as row
    /// actions), and Details stays put in Advanced.
    private var actionColumn: some View {
        HStack(spacing: 6) {
            Group {
                if port.type.category == .web {
                    Button(action: { Browser.openLocalhost(port: port.port) }) {
                        Image(systemName: "safari")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open localhost:\(port.port) in the browser")
                    .help("Open in browser (⌘O)")
                }
                Button(action: { manager.toggleWatch(port.port) }) {
                    Image(systemName: isWatched ? "star.fill" : "star")
                        .foregroundColor(isWatched ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isWatched ? "Stop watching port \(port.port)" : "Watch port \(port.port)")
                .help(isWatched ? "Stop watching" : "Watch: be told when it frees up or gets taken")
            }
            .opacity(showsExtraVerbs ? 1 : 0)
            .allowsHitTesting(showsExtraVerbs)
            .accessibilityHidden(true)

            if isAdvanced {
                Button(action: onSelect) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show details for \(port.processName) on port \(port.port)")
                .help("Show Details")
            }

            if isTerminating {
                ProgressView()
                    .controlSize(.small)
                    .help("Shutting down…")
            } else {
                Button(action: {
                    // Option = force kill (SIGKILL), Shift = kill process tree
                    let force = NSEvent.modifierFlags.contains(.option)
                    let killTree = NSEvent.modifierFlags.contains(.shift)
                    onKillRequest(force, killTree)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Kill \(port.processName) on port \(port.port)")
                .help("Click to kill. Option-click to force kill. Shift-click to kill the process tree.")
            }
        }
        .font(.system(size: 13))
        .frame(width: metrics.action * scale, alignment: .trailing)
    }

    private func childRows(_ children: [PortInfo.ProcessInfo]) -> some View {
        ForEach(children) { child in
            HStack(spacing: 8) {
                Spacer().frame(width: (metrics.gutter + metrics.tile) * scale + 8)

                Image(systemName: "arrow.turn.down.right")
                    .foregroundColor(.secondary.opacity(0.5))
                    .font(.caption)

                VStack(alignment: .leading, spacing: 1) {
                    Text(child.name)
                        .font(.subheadline)
                    Text("PID \(String(child.pid))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { onKillChild(child) }) {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Kill child process \(child.name)")
                .help("Kill \(child.name)")
                .padding(.trailing, 12)
            }
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.05))
        }
    }
}
