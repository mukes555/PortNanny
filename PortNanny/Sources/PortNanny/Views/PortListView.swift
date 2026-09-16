import PortNannyCore
import SwiftUI
import Foundation
import AppKit

struct PortListView: View {
    enum ListFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case dev = "Dev"
        case database = "Databases"
        case docker = "Docker"
        case tests = "Tests"

        var id: String { rawValue }

        /// What ⌘K and the footer button kill on this filter. "All" keeps
        /// the classic "Kill All Dev" behaviour.
        var bulkKillLabel: String {
            switch self {
            case .all, .dev: return "Kill All Dev"
            case .database: return "Kill All Databases"
            case .docker: return "Kill All Docker"
            case .tests: return "Kill All Tests"
            }
        }

        func includesInBulkKill(_ port: PortInfo) -> Bool {
            switch self {
            case .all, .dev: return port.type.category == .web
            case .database: return port.type.category == .database
            case .docker: return port.type == .docker || port.containerName != nil
            case .tests: return false
            }
        }
    }

    enum ActiveSheet: Identifiable {
        case portDetail(PortInfo)
        case bulkKill

        var id: String {
            switch self {
            case .portDetail(let port):
                return "portDetail-\(port.id)"
            case .bulkKill:
                return "bulkKill"
            }
        }
    }

    @ObservedObject var portManager: PortManager
    @EnvironmentObject var appDelegate: AppDelegate
    @State var searchText = ""
    @State var filter: ListFilter = .all
    @State var eventMonitor: Any?
    @State var activeSheet: ActiveSheet?
    @State var selectedId: String?
    @State var expandedIds: Set<String> = []
    @State var isOnScreen = false
    @ScaledMetric(relativeTo: .body) var textScale: CGFloat = 1
    @AppStorage(DefaultsKey.didDismissHotkeyTip) var didDismissHotkeyTip = false
    @FocusState var isSearchFocused: Bool

    /// The pinned panel hosts a second copy of this view; each copy handles
    /// keys only while its own window is key.
    let hostedInPinnedWindow: Bool

    init(portManager: PortManager, initialSearchText: String = "", initialSelectedId: String? = nil, hostedInPinnedWindow: Bool = false) {
        _portManager = ObservedObject(wrappedValue: portManager)
        _searchText = State(initialValue: initialSearchText)
        _selectedId = State(initialValue: initialSelectedId)
        self.hostedInPinnedWindow = hostedInPinnedWindow
    }

    var filteredPorts: [PortInfo] {
        var ports = portManager.visiblePorts

        switch filter {
        case .all, .tests:
            break
        case .dev:
            ports = ports.filter { $0.type.category == .web }
        case .database:
            ports = ports.filter { $0.type.category == .database }
        case .docker:
            ports = ports.filter { $0.type == .docker || $0.containerName != nil }
        }

        // "kill 3000" filters to :3000; the verb is the palette's business.
        let needle = paletteQuery.rowFilter
        if needle.isEmpty {
            return ports
        }
        return ports.filter { PortSearch.matches($0, needle) }
    }

    // Web first, then IDE, then DB, then Other
    private static let categoryRank: [PortInfo.PortCategory: Int] = [.web: 0, .ide: 1, .database: 2, .other: 3]

    var groupedPorts: [(key: PortInfo.PortCategory, value: [PortInfo])] {
        Dictionary(grouping: filteredPorts) { $0.type.category }
            .sorted { (Self.categoryRank[$0.key] ?? 999) < (Self.categoryRank[$1.key] ?? 999) }
    }

    /// The same ports, grouped by the session that started them. Claims (a
    /// lease with nothing listening yet) only make sense unfiltered: a search
    /// or a category filter is about processes, and a claim has none.
    var agentGroups: [AgentSessions.Group] {
        let claims = filter == .all && paletteQuery.rowFilter.isEmpty ? ReservationStore.shared.recent() : []
        return AgentSessions.groups(from: filteredPorts, leases: claims)
    }

    var filteredTests: [TestProcessInfo] {
        let needle = paletteQuery.rowFilter
        if needle.isEmpty {
            return portManager.activeTests
        }
        return portManager.activeTests.filter { test in
            test.processName.localizedCaseInsensitiveContains(needle) ||
            test.command.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Row order as displayed, used for arrow-key navigation. It has to
    /// follow whichever grouping is on screen, or the arrows jump about.
    var visibleIdsInOrder: [String] {
        if filter == .tests {
            return filteredTests.map(\.id)
        }
        if portManager.viewMode == .agents {
            return agentGroups.flatMap { $0.ports.map(\.id) }
        }
        return groupedPorts.flatMap { $0.value.map(\.id) }
    }

    var selectedPort: PortInfo? {
        guard let selectedId else { return nil }
        return filteredPorts.first { $0.id == selectedId }
    }

    var selectedTest: TestProcessInfo? {
        guard let selectedId else { return nil }
        return filteredTests.first { $0.id == selectedId }
    }

    /// The popover is pinned to the chosen size (NSPopover follows the
    /// hosting controller's ideal size, and an unbounded list would grow
    /// with its content); only the pinned panel may be resized.
    private var popoverSize: NSSize { portManager.popoverSize.dimensions }
    var metrics: RowMetrics { RowMetrics.forPopover(portManager.popoverSize, pinned: hostedInPinnedWindow) }
    private var maxWidth: CGFloat { hostedInPinnedWindow ? .infinity : popoverSize.width }
    private var maxHeight: CGFloat { hostedInPinnedWindow ? .infinity : popoverSize.height }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if let errorMessage = portManager.lastErrorMessage {
                    ErrorBannerView(message: errorMessage) {
                        portManager.lastErrorMessage = nil
                    }
                }

                headerView

                Divider()

                if filter == .tests {
                    TestRadarView(
                        portManager: portManager,
                        tests: filteredTests,
                        selectedId: $selectedId,
                        onKillRequest: { test, force in requestKillTest(test, force: force) }
                    )
                } else {
                    portsContentView
                }

                Divider()

                footerView
            }
            .frame(minWidth: popoverSize.width, maxWidth: maxWidth, minHeight: popoverSize.height, maxHeight: maxHeight)

            if let toastMessage = portManager.toastMessage {
                VStack {
                    Spacer()
                    ToastView(message: toastMessage)
                        .padding(.bottom, 12)
                }
                .frame(minWidth: popoverSize.width, maxWidth: maxWidth, minHeight: popoverSize.height, maxHeight: maxHeight)
                .allowsHitTesting(false)
            }
        }
        // Opaque background so list rows never sit on unpredictable popover material
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            isOnScreen = true
            installKeyMonitorIfNeeded()
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onDisappear {
            isOnScreen = false
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .portDetail(let port):
                PortDetailView(port: port)
            case .bulkKill:
                BulkKillView(portManager: portManager)
            }
        }
    }

    var portsContentView: some View {
        VStack(spacing: 0) {
            // Column headers; the widths scale with the rows' text size.
            HStack(spacing: RowMetrics.spacing) {
                Spacer().frame(width: metrics.gutter * textScale)
                Text("Port")
                    .frame(width: metrics.port * textScale, alignment: .leading)
                Text("Process")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Memory")
                    .frame(width: metrics.memory * textScale, alignment: .trailing)
                Text("Action")
                    .frame(width: metrics.action * textScale, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if showWatchedSection {
                WatchedSectionView(
                    portManager: portManager,
                    metrics: metrics,
                    onKillRequest: { port in requestKill(port, force: false, killTree: false) }
                )
            }

            if !portManager.hasCompletedFirstScan {
                loadingStateView
            } else if filteredPorts.isEmpty {
                emptyStateView
            } else if portManager.viewMode == .agents {
                AgentListContent(
                    groups: agentGroups,
                    showsTools: filter == .all && paletteQuery.rowFilter.isEmpty,
                    metrics: metrics,
                    portManager: portManager,
                    selectedId: $selectedId,
                    expandedIds: $expandedIds,
                    onSelectPort: { port in activeSheet = .portDetail(port) },
                    onKillRequest: { port, force, killTree in requestKill(port, force: force, killTree: killTree) },
                    onKillChild: { child in requestKillChild(child) }
                )
            } else {
                PortListContent(
                    groupedPorts: groupedPorts,
                    metrics: metrics,
                    portManager: portManager,
                    selectedId: $selectedId,
                    expandedIds: $expandedIds,
                    onSelectPort: { port in activeSheet = .portDetail(port) },
                    onKillRequest: { port, force, killTree in requestKill(port, force: force, killTree: killTree) },
                    onKillChild: { child in requestKillChild(child) }
                )
            }

            // The Agents view with nothing to group by is a fair question:
            // "is this thing working?". It is; nothing here came from an agent.
            if portManager.viewMode == .agents, showsNoAgentHint {
                Text("Nothing here was started by an AI agent. PortNanny labels servers from Claude Code, Codex, Cursor and friends on its own; for anything else, export PORTNANNY_OWNER=<name>.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            }

            // A filter (system, UDP, ephemeral) must never look like missing data
            if portManager.hiddenPortsCount > 0 {
                Button(action: { portManager.showEverything() }) {
                    Text("Show \(portManager.hiddenPortsCount) hidden port\(portManager.hiddenPortsCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            }
        }
    }

    /// True when the Agents view has nothing but the catch-all group.
    var showsNoAgentHint: Bool {
        portManager.hasCompletedFirstScan && !filteredPorts.isEmpty
            && agentGroups.allSatisfy { $0.kind == .unattributed }
    }

    var showWatchedSection: Bool {
        !portManager.watchedPorts.isEmpty && searchText.isEmpty && filter == .all
    }

    // MARK: - Footer

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func timeAgo(from date: Date) -> String {
        // The formatter says "in 0 seconds" for just-written timestamps
        if Date().timeIntervalSince(date) < 10 {
            return "just now"
        }
        return Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}
