import PortNannyCore
import SwiftUI

/// The scrolling list: one section per category, rows inside.
struct PortListContent: View {
    let groupedPorts: [(key: PortInfo.PortCategory, value: [PortInfo])]
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
                    ForEach(groupedPorts, id: \.key) { category, ports in
                        PortSectionView(
                            category: category,
                            ports: ports,
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

struct PortSectionView: View {
    let category: PortInfo.PortCategory
    let ports: [PortInfo]
    let metrics: RowMetrics
    @ObservedObject var portManager: PortManager
    @Binding var selectedId: String?
    @Binding var expandedIds: Set<String>
    let onSelectPort: (PortInfo) -> Void
    let onKillRequest: (PortInfo, _ force: Bool, _ killTree: Bool) -> Void
    let onKillChild: (PortInfo.ProcessInfo) -> Void

    var body: some View {
        Section(header: SectionHeader(title: category.rawValue, count: ports.count, tint: Color(nsColor: category.color))) {
            ForEach(ports) { port in
                PortRowView(
                    port: port,
                    showsDetails: portManager.showsDetails,
                    metrics: metrics,
                    isProtected: portManager.isProtectedProcessName(port.processName),
                    isWatched: portManager.isWatched(port.port),
                    isGuarded: portManager.isGuarded(port.port),
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
        }
        .animation(.easeInOut(duration: 0.18), value: ports.map(\.id))
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
