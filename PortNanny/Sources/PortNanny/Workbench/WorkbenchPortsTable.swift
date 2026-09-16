import AppKit
import PortNannyCore
import SwiftUI

/// Every visible port as a sortable table. Selecting a row fills the
/// inspector; the context menu is the popover's.
struct WorkbenchPortsTable: View {
    @ObservedObject var portManager: PortManager
    @Binding var selection: String?
    @Binding var searchText: String
    @State private var sortOrder = [KeyPathComparator(\PortInfo.port)]

    private var rows: [PortInfo] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = needle.isEmpty ? portManager.visiblePorts : portManager.visiblePorts.filter { PortSearch.matches($0, needle) }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        // Filtered and sorted once per render, shared by the toolbar and the table.
        let rows = self.rows
        VStack(spacing: 0) {
            toolbar(rows: rows)
            Divider()
            if !portManager.hasCompletedFirstScan {
                WorkbenchEmpty(icon: "magnifyingglass", text: "Scanning ports…")
            } else if rows.isEmpty {
                let searched = searchText.trimmingCharacters(in: .whitespaces)
                WorkbenchEmpty(icon: searched.isEmpty ? "powersleep" : "magnifyingglass",
                               text: searched.isEmpty ? "Nothing is listening" : "No ports match \"\(searched)\"",
                               mood: searched.isEmpty ? .sleepy : .searching)
            } else {
                table(rows: rows)
            }
        }
    }

    private func toolbar(rows: [PortInfo]) -> some View {
        let selectedPort = rows.first { $0.id == selection }
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Filter ports, processes, projects, agents", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .frame(maxWidth: 360)

            Text("\(rows.count) of \(portManager.visiblePorts.count) · \(portManager.totalPortsMemory)")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if let port = selectedPort {
                Button {
                    KillFlow(portManager: portManager).requestKill(port, force: false, killTree: false)
                } label: {
                    Label("Kill :\(String(port.port))", systemImage: "xmark.circle")
                }
                .controlSize(.small)
            }
            Button {
                portManager.refresh(showToast: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
        .padding(10)
    }

    private func table(rows: [PortInfo]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Port", value: \.port) { port in
                HStack(spacing: 6) {
                    IconTile(type: port.type, size: 20)
                    Text(":\(String(port.port))")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                }
            }
            .width(min: 86, ideal: 94)

            TableColumn("Process", value: \.processName) { port in
                HStack(spacing: 6) {
                    Text(port.processName).fontWeight(.medium)
                    if portManager.isProtectedProcessName(port.processName) {
                        Image(systemName: "lock.fill").font(.caption2).foregroundColor(.orange)
                            .help("Protected: skipped by bulk kill actions")
                    }
                    if portManager.isGuarded(port.port) {
                        Image(systemName: "shield.fill").font(.caption2).foregroundColor(.orange)
                            .help("Guarded: anything that takes this port is stopped")
                    }
                    if port.isExposed {
                        Chip(icon: "wifi.exclamationmark", text: "exposed", tint: .chipOrange)
                    }
                    if port.connections > 0 {
                        Chip(icon: "person.2", text: "\(port.connections)", tint: .chipBlue)
                    }
                }
            }
            .width(min: 130, ideal: 140)

            TableColumn("Project", value: \.projectLabel)
                .width(min: 84, ideal: 90)

            TableColumn("Agent", value: \.agentLabel) { port in
                if let agent = port.agentOwner {
                    AgentChip(agent: agent)
                }
            }
            .width(min: 96, ideal: 104)

            TableColumn("Managed", value: \.managedLabel) { port in
                if let managed = port.managedBy {
                    Chip(icon: managed.kind == .docker ? "shippingbox" : "arrow.triangle.2.circlepath",
                         text: managed.short, tint: managed.kind == .docker ? .chipBlue : .chipOrange)
                        .help("\(managed.label): \(managed.consequence)")
                }
            }
            .width(min: 80, ideal: 88)

            TableColumn("Memory", value: \.memorySizeKB) { port in
                Text(port.memoryUsage).monospacedDigit()
            }
            .width(min: 62, ideal: 64)

            TableColumn("CPU", value: \.cpuPercent) { port in
                Text(String(format: "%.1f%%", port.cpuPercent)).monospacedDigit()
            }
            .width(min: 48, ideal: 50)

            TableColumn("Trend") { port in
                SparklineView(metrics: portManager.metrics, pid: port.pid, series: .cpu, tint: .chipTeal)
                    .frame(height: 14)
                    .help("CPU over the last \(MetricsHistory.capacity) scans")
            }
            .width(min: 56, ideal: 70)

            TableColumn("Age", value: \.ageLabel)
                .width(min: 52, ideal: 56)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let port = rows.first(where: { $0.id == id }) {
                PortRowContextMenu(port: port, manager: portManager, onSelect: { selection = port.id }) { force, tree in
                    KillFlow(portManager: portManager).requestKill(port, force: force, killTree: tree)
                }
            }
        } primaryAction: { ids in
            selection = ids.first
        }
    }
}
