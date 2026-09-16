import PortNannyCore
import SwiftUI

/// The big window: everything the popover knows, with room to work. A
/// sidebar of views (ports, projects, agent sessions, watchlist, history),
/// the selected view in the middle, and an inspector for the chosen port.
struct WorkbenchView: View {
    enum Section: String, CaseIterable, Identifiable {
        case ports = "Ports"
        case projects = "Projects"
        case agents = "Agents"
        case watchlist = "Watchlist"
        case history = "History"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .ports: return "network"
            case .projects: return "folder"
            case .agents: return "sparkles"
            case .watchlist: return "star"
            case .history: return "clock"
            }
        }
    }

    @ObservedObject var portManager: PortManager
    @ObservedObject private var history = HistoryManager.shared
    @EnvironmentObject var appDelegate: AppDelegate
    @State var section: Section = .ports
    @State var selectedPortId: String?
    @State var searchText = ""

    init(portManager: PortManager, initialSection: Section = .ports, initialSelection: String? = nil) {
        _portManager = ObservedObject(wrappedValue: portManager)
        _section = State(initialValue: initialSection)
        _selectedPortId = State(initialValue: initialSelection)
    }

    var selectedPort: PortInfo? {
        guard let selectedPortId else { return nil }
        return portManager.activePorts.first { $0.id == selectedPortId }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 700, ideal: 820)
        } detail: {
            if let port = selectedPort {
                // Keyed by the port: selecting another one builds a fresh
                // inspector, so a slow peek or ancestry walk for the previous
                // port cannot land in the new one's panel.
                WorkbenchInspector(port: port, portManager: portManager)
                    .id(port.id)
            } else {
                inspectorPlaceholder
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1220, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .showsFeedback(from: portManager)
    }

    /// Note for screenshots: this column is composited by the window server
    /// and draws blank in offscreen renders; `workbench-live` captures it.
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandAvatar(size: 36)
                Text("PortNanny")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            List(Section.allCases, selection: $section) { item in
                NavigationLink(value: item) {
                    Label(item.rawValue, systemImage: item.icon)
                        .badge(badge(for: item))
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .ports:
            WorkbenchPortsTable(portManager: portManager, selection: $selectedPortId, searchText: $searchText)
        case .projects:
            WorkbenchProjects(portManager: portManager, selection: $selectedPortId)
        case .agents:
            WorkbenchAgents(portManager: portManager, selection: $selectedPortId)
        case .watchlist:
            WorkbenchWatchlist(portManager: portManager, selection: $selectedPortId)
        case .history:
            HistoryView(portManager: portManager, embedded: true)
        }
    }

    private var inspectorPlaceholder: some View {
        VStack(spacing: 10) {
            MascotView(mood: .sleepy, size: 88)
            Text("Select a port to inspect it")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Counts only: the groupings themselves are built by the pane that shows them.
    private func badge(for item: Section) -> Int {
        switch item {
        case .ports: return portManager.visiblePorts.count
        case .projects: return WorkbenchModel.projectCount(of: portManager.visiblePorts)
        case .agents: return AgentSessions.sessionCount(of: portManager.visiblePorts)
        case .watchlist: return portManager.watchedPorts.union(portManager.guardedPorts).count + ReservationStore.shared.recent().count
        case .history: return history.history.count + history.refusals.count
        }
    }
}
