import PortNannyCore
import SwiftUI
import Foundation
import AppKit

// MARK: - Header, overflow menu, footer, empty state
extension PortListView {

    var headerView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                BrandHeader(summary: headerSummary)

                Spacer()

                viewModeToggle
                overflowMenu
                settingsButton
            }

            searchField

            if let action = paletteAction {
                PaletteBar(action: action, commands: paletteQuery.commandMatches, onRun: { _ = runPaletteAction() },
                           onCommand: { perform($0) })
            }

            filterChips

            if !didDismissHotkeyTip {
                hotkeyTip
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(headerBackground)
    }

    /// A whisper of the accent colour behind the brand, fading into the list.
    private var headerBackground: some View {
        LinearGradient(colors: [Color.accentColor.opacity(0.10), Color.accentColor.opacity(0)], startPoint: .top, endPoint: .bottom)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    var headerSummary: String {
        BrandHeader.summary(
            portCount: portManager.visiblePorts.count,
            memory: portManager.totalPortsMemory,
            liveSessions: AgentSessions.liveSessionCount(of: portManager.visiblePorts),
            scanned: portManager.hasCompletedFirstScan
        )
    }

    /// Modern segmented capsule: Agents or Ports.
    var viewModeToggle: some View {
        ViewModeToggle(mode: $portManager.viewMode)
    }

    /// Overflow menu: actions only (never settings, those live in ⚙︎).
    var overflowMenu: some View {
        Menu {
            Button("Refresh") { portManager.refresh(showToast: true) }
                .keyboardShortcut("r")
            Button("Bulk Kill…") { activeSheet = .bulkKill }
            Button(appDelegate.isPinned ? "Unpin Floating Window" : "Pin as Floating Window") {
                appDelegate.togglePinnedWindow()
            }
            Button("History…") { appDelegate.showHistory() }
            Button("Open Workbench") { appDelegate.openWorkbench() }
            Button("Welcome Tour…") { appDelegate.showTour() }

            Divider()

            if let newer = portManager.updateAvailableVersion {
                if InstallSource.detect() == .homebrew {
                    Button("Update to v\(newer) (copy brew command)") {
                        Pasteboard.copy("brew upgrade --cask portnanny")
                        portManager.showToast("Copied: brew upgrade --cask portnanny")
                    }
                } else {
                    Button("Download v\(newer)…") { NSWorkspace.shared.open(UpdateChecker.releasePage(for: newer)) }
                }
            }
            Button("Quit PortNanny") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
        .help("Actions")
    }

    /// Gear opens the dedicated Settings window: settings only, no actions.
    var settingsButton: some View {
        Button {
            appDelegate.openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",", modifiers: .command)
        .accessibilityLabel("Settings")
        .help("Settings")
    }

    var hotkeyTip: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .font(.system(size: 10))
            Text("Tip: \(appDelegate.hotkeyDisplay) opens PortNanny anywhere · ↑↓ select · ⏎ kill · ⌘O browser")
                .font(.system(size: 10))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer()
            Button(action: { didDismissHotkeyTip = true }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss tip")
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(5)
    }

    var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search, or type kill 3000, open 5173, > commands", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(ListFilter.allCases) { chip in
                Button(action: { filter = chip }) {
                    Text(chipLabel(chip))
                        .font(.system(size: 11, weight: filter == chip ? .semibold : .regular))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(filter == chip ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                        .foregroundColor(filter == chip ? .accentColor : .primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    func chipLabel(_ chip: ListFilter) -> String {
        if chip == .tests && !portManager.activeTests.isEmpty {
            return "Tests (\(portManager.activeTests.count))"
        }
        return chip.rawValue
    }

    /// Before the first scan lands nothing is known yet; "no ports" would
    /// be a claim made without data.
    var loadingStateView: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Scanning ports…")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Searching a free port number gets a positive answer instead of a
    /// dead-end "no results".
    var emptyStateView: some View {
        let searchedPort = Int(searchText.trimmingCharacters(in: .whitespaces))
        let isValidPort = searchedPort.map { (1...65535).contains($0) } ?? false
        let hiddenMatch = searchedPort.flatMap { number in
            portManager.activePorts.first { $0.port == number }
        }

        return VStack {
            Spacer()
            if isValidPort, let searchedPort {
                if let hiddenMatch {
                    // Occupied, but filtered out of the current view
                    Image(systemName: "eye.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 8)
                    Text(":\(String(searchedPort)) is in use by \(hiddenMatch.processName)")
                        .foregroundColor(.primary)
                    Text("It's hidden by the current filter.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Show All") {
                        portManager.showEverything()
                        filter = .all
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 6)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.green)
                        .padding(.bottom, 8)
                    Text(":\(String(searchedPort)) is free")
                        .font(.headline)
                    Button(portManager.isWatched(searchedPort) ? "Watching" : "Watch :\(String(searchedPort))") {
                        portManager.toggleWatch(searchedPort)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 6)
                }
            } else if searchText.isEmpty, filter != .all {
                // The header still counts every port, so "nothing is
                // listening" here would contradict the line above it.
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
                Text("No \(filter.rawValue.lowercased()) ports right now")
                    .font(.headline)
                Button("Show All") { filter = .all }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 6)
            } else if searchText.isEmpty {
                MascotView(mood: .sleepy, size: 96)
                    .padding(.bottom, 8)
                Text("All quiet: nothing is listening")
                    .font(.headline)
                Text("Start a dev server and it shows up here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                MascotView(mood: .searching, size: 96)
                    .padding(.bottom, 8)
                Text("No results found")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    private var statusLine: String {
        var parts: [String] = []
        let shown = filteredPorts.count
        if filter == .tests {
            parts.append("\(portManager.activeTests.count) tests running · \(portManager.totalTestsMemory)")
        } else if shown != portManager.visiblePorts.count {
            parts.append("\(shown) of \(portManager.visiblePorts.count) ports shown")
        }
        if portManager.isCompatibilityScan {
            parts.append("compatibility scan")
        }
        return parts.joined(separator: " · ")
    }

    var footerView: some View {
        VStack(spacing: 0) {
            // The header carries the totals; this line only says when the
            // list is narrower than the scan, and how it was scanned.
            HStack {
                Text(statusLine)
                    .help(portManager.isCompatibilityScan ? "The native scanner is unavailable here, so PortNanny is reading ports through lsof. It works, but each refresh is slower." : "")
                Spacer()
                UpdatedLabel(clock: portManager.clock, isOnScreen: isOnScreen)
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            HStack(spacing: 12) {
                Button(action: { killAllForCurrentFilter() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("\(filter.bulkKillLabel) ⌘K")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("\(filter.bulkKillLabel): unprotected processes on this filter (⌘K)")

                Spacer()

                Button(action: {
                    portManager.refresh(showToast: true)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh ⌘R")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh (⌘R)")
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

/// The footer's "Updated 2s ago". Observes the refresh clock on its own so a
/// scan landing re-renders this label and nothing else, and only ticks while
/// the list is on screen (the hosting view outlives the popover).
struct UpdatedLabel: View {
    @ObservedObject var clock: RefreshClock
    let isOnScreen: Bool

    var body: some View {
        if isOnScreen {
            // Re-render periodically so "2s ago" can't freeze at 2s forever
            TimelineView(.periodic(from: .now, by: 10)) { _ in
                Text("Updated \(PortListView.timeAgo(from: clock.lastUpdated))")
            }
        } else {
            Text("Updated \(PortListView.timeAgo(from: clock.lastUpdated))")
        }
    }
}
