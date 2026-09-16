import PortNannyCore
import SwiftUI
import AppKit

/// The dedicated Settings window (⌘,), styled like macOS System Settings:
/// a sidebar of categories on the left, the selected pane on the right.
/// Everything here is a preference, never an action.
struct SettingsView: View {
    @ObservedObject var portManager: PortManager
    @EnvironmentObject var appDelegate: AppDelegate

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case display = "Display"
        case agents = "Agents"
        case shortcuts = "Shortcuts"
        case protected = "Protected"
        case about = "About"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .display: return "list.bullet.rectangle.fill"
            case .agents: return "sparkles"
            case .shortcuts: return "keyboard.fill"
            case .protected: return "shield.lefthalf.filled"
            case .about: return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: return .gray
            case .display: return .blue
            case .agents: return .teal
            case .shortcuts: return .purple
            case .protected: return .orange
            case .about: return .green
            }
        }
    }

    /// The pane to show, so "Settings > Agents" can be opened from the tour
    /// or a menu while the window already exists.
    final class Router: ObservableObject {
        @Published var pane: Pane = .general
    }

    @ObservedObject var router: Router

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $router.pane) { pane in
                NavigationLink(value: pane) {
                    Label {
                        Text(pane.rawValue)
                    } icon: {
                        Image(systemName: pane.icon)
                            .foregroundStyle(.white)
                            .font(.system(size: 11))
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(pane.tint))
                    }
                }
            }
            .navigationSplitViewColumnWidth(180)
            .listStyle(.sidebar)
        } detail: {
            detail(for: router.pane)
                .navigationTitle(router.pane.rawValue)
        }
        .frame(width: 640, height: 480)
        .showsFeedback(from: portManager)
    }

    @ViewBuilder
    private func detail(for pane: Pane) -> some View {
        switch pane {
        case .general:   GeneralSettings(portManager: portManager)
        case .display:   DisplaySettings(portManager: portManager)
        case .agents:    AgentsSettings(portManager: portManager)
        case .shortcuts: ShortcutsSettings()
        case .protected: ProtectedProcessListView(portManager: portManager)
        case .about:     AboutSettings(portManager: portManager)
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var portManager: PortManager
    // Read in onAppear, not here: a @State default runs on every rebuild,
    // and each read is a synchronous XPC call to launchd.
    @State private var launchAtLogin = false
    @State private var loginNeedsApproval = false
    @State private var notificationsBlocked = false

    private let historyLimits = [50, 100, 200, 500]

    private let intervals: [(TimeInterval, String)] = [
        (0, "Manual only"), (2, "Every 2 seconds"), (5, "Every 5 seconds"),
        (10, "Every 10 seconds"), (30, "Every 30 seconds")
    ]

    var body: some View {
        Form {
            Section("Startup & Scanning") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        if LoginItem.setEnabled(newValue) { launchAtLogin = newValue }
                        else { portManager.showToast("Needs the installed .app bundle") }
                        loginNeedsApproval = LoginItem.requiresApproval
                    }
                ))
                if loginNeedsApproval {
                    HStack {
                        Label("macOS is waiting for you to allow PortNanny in Login Items (this happens after an update).", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Spacer()
                        Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                    }
                }
                Picker("Auto refresh", selection: $portManager.refreshInterval) {
                    ForEach(intervals, id: \.0) { Text($0.1).tag($0.0) }
                }
            }

            Section("Killing") {
                Toggle("Confirm before killing a process", isOn: $portManager.confirmBeforeKill)
                Text("When off, the kill button acts immediately (Option-click always force-kills).")
                    .settingsCaption()
            }

            Section("Notifications") {
                Toggle("Send notifications", isOn: $portManager.notificationsEnabled)
                Group {
                    Toggle("A watched port frees up", isOn: $portManager.notifyPortFreed)
                    Toggle("Something takes a watched port", isOn: $portManager.notifyPortTaken)
                    Toggle("A guard acts", isOn: $portManager.notifyGuardKills)
                    Toggle("An agent is refused a port", isOn: $portManager.notifyRefusals)
                    Toggle("Play a sound", isOn: $portManager.notificationSound)
                }
                .disabled(!portManager.notificationsEnabled)
                if notificationsBlocked {
                    HStack {
                        Label("Notifications are blocked for PortNanny in System Settings.", systemImage: "bell.slash")
                            .foregroundColor(.orange)
                        Spacer()
                        Button("Open System Settings") { openNotificationSettings() }
                    }
                }
                Text("A refusal is the guard saying no to an agent from the CLI or MCP; the notification lets you stop the server yourself.")
                    .settingsCaption()
            }

            Section("Watched ports") {
                if portManager.watchedPorts.isEmpty {
                    Text("Right-click any port in the list and choose Watch. Guards are opt-in per watched port.")
                        .settingsCaption()
                } else {
                    ForEach(portManager.watchedPorts.sorted(), id: \.self) { port in
                        HStack {
                            Text(":\(String(port))")
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Toggle("Guard", isOn: Binding(
                                get: { portManager.isGuarded(port) },
                                // A modal alert must not run inside SwiftUI's
                                // update transaction; hop off it first.
                                set: { _ in DispatchQueue.main.async { GuardConfirm.toggle(port, in: portManager) } }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            Button("Stop Watching") { portManager.toggleWatch(port) }
                                .controlSize(.small)
                        }
                    }
                    Text("A guard auto-kills any unprotected process of yours that takes the port, except servers of a running AI agent session.")
                        .settingsCaption()
                }
            }

            Section("History") {
                Picker("Keep the last", selection: $portManager.historyLimit) {
                    ForEach(historyLimits, id: \.self) { Text("\($0) kills").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            checkNotificationStatus()
            launchAtLogin = LoginItem.isEnabled
            loginNeedsApproval = LoginItem.requiresApproval
        }
        .onChange(of: portManager.notificationsEnabled) { _ in checkNotificationStatus() }
    }

    private func checkNotificationStatus() {
        Notifier.authorizationStatus { status in
            notificationsBlocked = status == .denied
        }
    }

    private func openNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Display

private struct DisplaySettings: View {
    @ObservedObject var portManager: PortManager

    var body: some View {
        Form {
            Section("Popover") {
                Picker("Size", selection: $portManager.popoverSize) {
                    ForEach(PortManager.PopoverSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Regular is 580 by 720 points. The pinned window can always be resized by hand.")
                    .settingsCaption()
            }

            Section("View") {
                Picker("Open in", selection: $portManager.viewMode) {
                    ForEach(PortManager.ViewMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Agents groups what is listening by the session that started it, with the ports each agent has claimed and the AI tools on this Mac. Simple lists every port by kind, one line each. Advanced adds the command, project and container chips, CPU with its trend, and the process tree. The same three tabs sit at the top of the list.")
                    .settingsCaption()
            }

            Section("List") {
                Toggle("Hide system processes", isOn: $portManager.hideSystemProcesses)
                Toggle("Show UDP sockets", isOn: $portManager.showUDP)
                Toggle("Hide ephemeral ports (49152 and up)", isOn: $portManager.hideEphemeralPorts)
                Text("System daemons stay out of the list; a footer hint shows how many are hidden. Ephemeral ports are mostly the outgoing side of something, or a server that picked a random port.")
                    .settingsCaption()
            }

            Section("Inspector") {
                Toggle("Peek at local web servers automatically", isOn: $portManager.probeLocalServers)
                Text("Sends one GET to http://127.0.0.1:<port>/ when a web server is selected in the Workbench, to show its status and page title. Off, the Peek button does it on request.")
                    .settingsCaption()
            }

            Section("Menu bar") {
                Picker("Icon", selection: $portManager.menuBarIcon) {
                    Text("Mono").tag(PortManager.MenuBarIcon.mono)
                    Text("Color").tag(PortManager.MenuBarIcon.color)
                }
                .pickerStyle(.segmented)
                Toggle("Show active port count", isOn: $portManager.showMenuBarCount)
                Text("Mono is the quokka traced in black and white, following the menu bar. Color is the app icon, dimmed while nothing is listening. The count is the number of dev ports.")
                    .settingsCaption()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettings: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var recording = false

    var body: some View {
        Form {
            Section("Global hotkey") {
                HStack {
                    Text("Open PortNanny from anywhere")
                    Spacer()
                    Text(appDelegate.hotkeyDisplay)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                    Button("Change…") { recording = true }
                    Button("Reset") { appDelegate.resetHotKey() }
                }
                Text("Works from any app, no Accessibility permission required.")
                    .settingsCaption()
            }

            Section("In-app shortcuts") {
                shortcutRow("Refresh", "⌘R")
                shortcutRow("Kill all (current filter)", "⌘K")
                shortcutRow("Kill selected", "⏎")
                shortcutRow("Force kill selected", "⌘⏎")
                shortcutRow("Open selected in browser", "⌘O")
                shortcutRow("Copy selected port", "⌘C")
                shortcutRow("Settings", "⌘,")
            }

            Section("Mouse") {
                shortcutRow("Force kill (SIGKILL)", "⌥ click ✕")
                shortcutRow("Kill the whole process tree", "⇧ click ✕")
                shortcutRow("Watch, guard, open project, copy…", "right-click a row")
                Button("Show the tips banner again") {
                    UserDefaults.standard.set(false, forKey: DefaultsKey.didDismissHotkeyTip)
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $recording) { HotKeyRecorderView() }
    }

    private func shortcutRow(_ title: String, _ key: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    @ObservedObject var portManager: PortManager
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var showResetConfirm = false

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "v\($0)" } ?? "dev"
    }

    var body: some View {
        VStack(spacing: 10) {
            AppIconView(size: 72)
            Text("PortNanny").font(.title2).bold()
            Text(version).foregroundColor(.secondary)

            if let newer = portManager.updateAvailableVersion {
                UpdateButton(version: newer, portManager: portManager)
            } else if UpdateChecker.currentVersion != nil {
                Button("Check for Updates…") { portManager.checkForUpdates(manual: true) }
            } else {
                Text("Development build: no update check.")
                    .settingsCaption()
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Check for updates once a day", isOn: $portManager.autoUpdateCheck)
                Toggle("Include beta releases", isOn: $portManager.includePrereleases)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Button("Copy debug info") {
                Pasteboard.copy(Diagnostics.text())
                portManager.showToast("Debug info copied")
            }
            .help("Version, macOS, install source, scanner path, and more, for bug reports")

            Divider().padding(.vertical, 6)

            Button("Reset all settings to defaults") { showResetConfirm = true }
                .foregroundColor(.red)

            Text("The macOS menu bar port manager · global hotkey opens it from anywhere.")
                .settingsCaption()
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .alert("Reset all settings?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                portManager.resetAllSettings()
                appDelegate.resetHotKey()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores refresh interval, density, popover size, menu bar icon, protected list, hotkey, and toggles to their defaults. Watched/guarded ports are cleared.")
        }
    }
}

private extension View {
    func settingsCaption() -> some View {
        self.font(.caption).foregroundColor(.secondary)
    }
}

/// "Download vX" for a DMG install; for a Homebrew install the download
/// would overwrite the cask's managed bundle, so it offers the brew command.
struct UpdateButton: View {
    let version: String
    @ObservedObject var portManager: PortManager

    var body: some View {
        if InstallSource.detect() == .homebrew {
            Button("Update to v\(version) with Homebrew") {
                Pasteboard.copy("brew upgrade --cask portnanny")
                portManager.showToast("Copied: brew upgrade --cask portnanny")
            }
            .buttonStyle(.borderedProminent)
            .help("Copies the Homebrew command; the cask replaces the app and quits the running copy")
        } else {
            Button("Download v\(version)…") { NSWorkspace.shared.open(UpdateChecker.releasePage(for: version)) }
                .buttonStyle(.borderedProminent)
        }
    }
}
