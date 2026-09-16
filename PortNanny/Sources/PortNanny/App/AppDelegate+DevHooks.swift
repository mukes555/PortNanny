import PortNannyCore
import Cocoa
import SwiftUI

// MARK: - Developer render hooks
// Offscreen renders driven by PORTNANNY_* environment variables: README
// screenshots, the demo GIF, and CI's UI smoke test. Debug builds only.
extension AppDelegate {
    #if DEBUG
    /// Offscreen render hooks, driven by PORTNANNY_* env vars. See CONTRIBUTING.md.
    func installDevHooks() {
        let env = Foundation.ProcessInfo.processInfo.environment

        if env["PORTNANNY_SHOW_ON_LAUNCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.togglePopover()
            }
        }

        if let snapshotPath = env["PORTNANNY_SNAPSHOT"] {
            let viewName = env["PORTNANNY_SNAPSHOT_VIEW"] ?? "main"
            if portManager.usesDemoData {
                // PORTNANNY_SNAPSHOT_DATA=demo: the scripted ports instead of
                // this Mac's, so a README image never shows a real project.
                portManager.hasCompletedFirstScan = true
                portManager.currentUser = DemoData.user
                portManager.activeTests = [DemoData.test]
                portManager.activePorts = DemoData.ports(includePort3000: true)
                portManager.clock.lastUpdated = Date()
                // The guard's work, made visible: one agent told no about
                // another's port. Written to the snapshot's own defaults.
                portManager.history.addRefusal(port: 3000, processName: "node", owner: "Claude Code", refused: "Codex CLI")
                // And an agent that has claimed a port before starting on it.
                AgentTools.shared.showForDemo(DemoData.tools)
                let claim = DemoData.claim
                _ = ReservationStore.shared.release(port: claim.port, by: nil, force: true)
                try? ReservationStore.shared.reserve(claim, by: claim.holder)
            } else {
                // Render what an open popover shows: full scans, not the light
                // hidden-state ones.
                portManager.setUIVisible(true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.writeSnapshot(of: viewName, to: snapshotPath)
                // The live capture quits on its own once it has drawn.
                if viewName != "workbench-live" { NSApp.terminate(nil) }
            }
        }

        if let gifPath = env["PORTNANNY_DEMO_GIF"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.renderDemoReel(to: gifPath)
                NSApp.terminate(nil)
            }
        }
    }

    /// By window id first; by screen region (the window's frame, flipped to
    /// screencapture's top-left origin) when the window server declines.
    private func captureWorkbench(to path: String) {
        guard let window = workbenchWindow, let screen = window.screen ?? NSScreen.main else {
            try? FileHandle.standardError.write(contentsOf: Data("no workbench window to capture\n".utf8))
            return
        }
        if (try? CommandRunner.run("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(window.windowNumber)", path], timeout: 10)) != nil {
            return
        }
        let frame = window.frame
        let top = screen.frame.maxY - frame.maxY
        let region = "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
        do {
            _ = try CommandRunner.run("/usr/sbin/screencapture", ["-x", "-R", region, path], timeout: 10)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("screencapture failed by window and by region \(region): \(error)\n".utf8))
        }
    }

    func writeSnapshot(of viewName: String, to path: String) {
        // Seed watched ports so the watched section can be rendered in snapshots
        if let watchList = Foundation.ProcessInfo.processInfo.environment["PORTNANNY_SNAPSHOT_WATCH"] {
            portManager.watchedPorts = Set(watchList.split(separator: ",").compactMap { Int($0) })
        }
        // agents, simple or advanced (the stored "clean" works too).
        if let mode = Foundation.ProcessInfo.processInfo.environment["PORTNANNY_SNAPSHOT_MODE"]?.lowercased(),
           let value = PortManager.ViewMode(rawValue: mode) ?? PortManager.ViewMode.allCases.first(where: { $0.label.lowercased() == mode }) {
            portManager.viewMode = value
        }

        let view: NSView
        switch viewName {
        case "bulkkill":
            view = NSHostingView(rootView: BulkKillView(portManager: portManager))
        case "protected":
            view = NSHostingView(rootView: ProtectedProcessListView(portManager: portManager))
        case "settings":
            // PORTNANNY_SNAPSHOT_PANE=general|display|agents|shortcuts|protected|about picks the pane.
            let router = SettingsView.Router()
            if let pane = Foundation.ProcessInfo.processInfo.environment["PORTNANNY_SNAPSHOT_PANE"].flatMap({ SettingsView.Pane(rawValue: $0.capitalized) }) {
                router.pane = pane
            }
            view = NSHostingView(rootView: SettingsView(portManager: portManager, router: router).environmentObject(self))
        case "workbench":
            // PORTNANNY_SNAPSHOT_SECTION=ports|projects|agents|watchlist|history and
            // PORTNANNY_SNAPSHOT_SELECT=<port> pick what the Workbench shows.
            let env = Foundation.ProcessInfo.processInfo.environment
            let section = env["PORTNANNY_SNAPSHOT_SECTION"].flatMap { WorkbenchView.Section(rawValue: $0.capitalized) } ?? .ports
            let selected = env["PORTNANNY_SNAPSHOT_SELECT"].flatMap(Int.init).flatMap { number in portManager.activePorts.first { $0.port == number }?.id }
            view = NSHostingView(rootView: WorkbenchView(portManager: portManager, initialSection: section, initialSelection: selected)
                .environmentObject(self).frame(width: 1380, height: 740))
        case "tour":
            // PORTNANNY_SNAPSHOT_TOUR_PAGE=0|1|2 picks the page.
            let page = Int(Foundation.ProcessInfo.processInfo.environment["PORTNANNY_SNAPSHOT_TOUR_PAGE"] ?? "0") ?? 0
            view = NSHostingView(rootView: TourView(portManager: portManager, initialPage: page, onFinish: {}).environmentObject(self))
        case "workbench-live":
            // Sidebar material is composited by the window server, so an
            // offscreen render shows it blank: open the real window and let
            // screencapture photograph it (needs Screen Recording permission).
            let env = Foundation.ProcessInfo.processInfo.environment
            let section = env["PORTNANNY_SNAPSHOT_SECTION"].flatMap { WorkbenchView.Section(rawValue: $0.capitalized) } ?? .ports
            let selected = env["PORTNANNY_SNAPSHOT_SELECT"].flatMap(Int.init).flatMap { number in portManager.activePorts.first { $0.port == number }?.id }
            openWorkbench(section: section, selection: selected)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.captureWorkbench(to: path)
                NSApp.terminate(nil)
            }
            return
        case "avatar":
            view = NSHostingView(rootView: AvatarSheet())
        case "menubar-strip":
            view = NSHostingView(rootView: MenuBarStrip())
        case "menubar":
            // Both menu bar glyphs, active and idle, on a light and a dark
            // bar, at 4x and at their real size.
            view = NSHostingView(rootView: MenuBarGlyphSheet())
        case "detail":
            let port = portManager.activePorts.first ?? PortInfo(
                port: 3000, pid: 1234, processName: "node",
                command: "/usr/local/bin/node server.js", user: NSUserName(),
                memoryUsage: "45MB", memorySizeKB: 46080, type: .nodejs,
                projectName: "my-app", bindAddress: "*"
            )
            view = NSHostingView(rootView: PortDetailView(port: port))
        default:
            // PORTNANNY_SNAPSHOT_TEXTSIZE=large renders at an accessibility
            // text size to check that the rows reflow instead of clipping.
            let textSize: DynamicTypeSize = Foundation.ProcessInfo.processInfo.environment["PORTNANNY_SNAPSHOT_TEXTSIZE"] == "large" ? .accessibility1 : .medium
            // PORTNANNY_SNAPSHOT_SEARCH seeds the search field, so the palette
            // bar ("kill 3000", "> ...") can be rendered.
            let search = Foundation.ProcessInfo.processInfo.environment["PORTNANNY_SNAPSHOT_SEARCH"] ?? ""
            view = NSHostingView(rootView: PortListView(portManager: portManager, initialSearchText: search).environmentObject(self).dynamicTypeSize(textSize))
        }

        let size = view.fittingSize == .zero ? NSSize(width: 500, height: 600) : view.fittingSize

        // Host in an offscreen window so the view gets a real appearance chain
        // (otherwise dark-mode colors resolve against a transparent void).
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        switch Foundation.ProcessInfo.processInfo.environment["PORTNANNY_SNAPSHOT_APPEARANCE"] {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        default: window.appearance = NSApp.effectiveAppearance
        }
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif
}

/// The dev hook's contact sheet for the menu bar glyphs.
struct MenuBarGlyphSheet: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 28) {
                    ForEach(PortManager.MenuBarIcon.allCases, id: \.self) { icon in
                        ForEach([true, false], id: \.self) { active in
                            HStack(spacing: 10) {
                                glyph(icon, active: active, dark: dark, scale: 4)
                                glyph(icon, active: active, dark: dark, scale: 1)
                            }
                        }
                    }
                }
                .padding(20)
                .background(dark ? Color(white: 0.12) : Color(white: 0.93))
            }
        }
    }

    private func glyph(_ icon: PortManager.MenuBarIcon, active: Bool, dark: Bool, scale: CGFloat) -> some View {
        let image = MenuBarGlyph.image(icon, active: active)
        return Image(nsImage: image)
            .renderingMode(image.isTemplate ? .template : .original)
            .resizable()
            .interpolation(.high)
            .foregroundColor(dark ? .white : .black)
            .frame(width: MenuBarGlyph.pointSize * scale, height: MenuBarGlyph.pointSize * scale)
    }
}



/// PORTNANNY_SNAPSHOT_VIEW=avatar: the head crop large, with its box drawn,
/// and at the sizes the header and the Workbench use.
struct AvatarSheet: View {
    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            BrandAvatar(size: 320)
                .border(Color.red.opacity(0.6))
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) { BrandAvatar(size: 40); Text("PortNanny").font(.system(size: 15, weight: .bold)) }
                HStack(spacing: 10) { BrandAvatar(size: 36); Text("PortNanny").font(.system(size: 14, weight: .bold)) }
                MascotView(mood: .happy, size: 200)
            }
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// PORTNANNY_SNAPSHOT_VIEW=menubar-strip: a made-up menu bar around the glyph
/// and its count, for the README. A photograph of the real bar would show
/// whatever else is running on this Mac.
struct MenuBarStrip: View {
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Image(nsImage: MenuBarGlyph.image(.mono, active: true))
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: MenuBarGlyph.pointSize, height: MenuBarGlyph.pointSize)
                Text("22").font(.system(size: 13, weight: .medium))
            }
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Mon 9:41").font(.system(size: 13))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .frame(width: 210, height: 28)
        .background(LinearGradient(colors: [Color(red: 0.56, green: 0.33, blue: 0.64), Color(red: 0.44, green: 0.24, blue: 0.53)],
                                   startPoint: .leading, endPoint: .trailing))
    }
}
