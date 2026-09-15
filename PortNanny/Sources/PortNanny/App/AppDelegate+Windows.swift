import PortNannyCore
import Cocoa
import SwiftUI

// MARK: - Popover, panel and windows
// Every window PortNanny can put on screen lives here: the popover and its
// pinned twin, the tour, the Workbench, Settings and History. Each is built
// once and reused, so a second ⌘-click brings the same window forward.
extension AppDelegate {

    /// The popover takes the chosen size at once; the pinned panel grows to
    /// it when it is smaller and keeps whatever the person stretched it to.
    func applyPopoverSize() {
        let size = portManager.popoverSize.dimensions
        popover.contentSize = size
        guard let panel = pinnedPanel else { return }
        panel.minSize = size
        if panel.frame.width < size.width || panel.frame.height < size.height {
            panel.setContentSize(size)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        portManager.setUIVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        // A pinned window or the Workbench keeps the fast refresh cadence alive
        portManager.setUIVisible(isPinned || workbenchIsVisible)
    }

    private var workbenchIsVisible: Bool {
        workbenchWindow?.isVisible ?? false
    }

    // MARK: - Pinned floating window

    /// A floating panel with the same content, for keeping an eye on ports
    /// while working ("is my build's port free yet?").
    func togglePinnedWindow() {
        if let panel = pinnedPanel {
            panel.close()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: portManager.popoverSize.dimensions),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "PortNanny"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = portManager.popoverSize.dimensions
        panel.contentViewController = NSHostingController(
            rootView: PortListView(portManager: portManager, hostedInPinnedWindow: true)
                .environmentObject(self)
        )
        panel.delegate = self
        // Remember where the user put it (and on which display); centre only
        // the very first time.
        panel.setFrameAutosaveName("PortNannyPinnedWindow")
        if !panel.setFrameUsingName("PortNannyPinnedWindow") {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        pinnedPanel = panel
        isPinned = true
        // The pinned window replaces the popover: close it so there aren't
        // two identical copies on screen.
        popover.performClose(nil)
        portManager.setUIVisible(true)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === workbenchWindow {
            portManager.setUIVisible(popover.isShown || isPinned)
            return
        }
        if closing === tourWindow {
            // Closing the tour any other way used to leave a first-time user
            // with nothing on screen and an app they could not find.
            DispatchQueue.main.async { [weak self] in self?.revealPorts() }
            return
        }
        guard closing === pinnedPanel else { return }
        pinnedPanel = nil
        isPinned = false
        portManager.setUIVisible(popover.isShown || workbenchIsVisible)
    }

    // MARK: - Tour

    func showTour() {
        popover.performClose(nil)
        if tourWindow == nil {
            // Skip, Done and the window's own close button all end the same
            // way: the window closes, and `windowWillClose` reveals the list.
            let view = TourView(portManager: portManager) { [weak self] in
                self?.tourWindow?.close()
            }
            .environmentObject(self)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "Welcome to PortNanny"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: view)
            window.center()
            window.delegate = self
            tourWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        tourWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Workbench

    /// The full-size window: table, projects, agent sessions, watchlist,
    /// history, and an inspector. One instance, remembered position.
    func openWorkbench(section: WorkbenchView.Section = .ports, selection: String? = nil) {
        popover.performClose(nil)
        if workbenchWindow == nil {
            let view = WorkbenchView(portManager: portManager, initialSection: section, initialSelection: selection).environmentObject(self)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1380, height: 740),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "PortNanny Workbench"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: view)
            window.setFrameAutosaveName("PortNannyWorkbench")
            if !window.setFrameUsingName("PortNannyWorkbench") {
                window.center()
            }
            window.delegate = self
            workbenchWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        workbenchWindow?.makeKeyAndOrderFront(nil)
        portManager.setUIVisible(true)
    }

    @objc func togglePopover() {
        // While pinned, there's a floating window already: don't open a second
        // identical popover; just bring the pinned window forward.
        if let panel = pinnedPanel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    /// Brings the port list forward without toggling it away when it is
    /// already showing.
    func revealPorts() {
        if pinnedPanel != nil || !popover.isShown {
            togglePopover()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Opens the dedicated Settings window (gear icon / ⌘,), at a pane when
    /// something points there.
    func openSettings(pane: SettingsView.Pane? = nil) {
        // The transient popover floats at a high window level and would sit on
        // top of a normal window; close it so Settings is actually visible.
        popover.performClose(nil)
        if let pane { settingsRouter.pane = pane }

        if settingsWindow == nil {
            let view = SettingsView(portManager: portManager, router: settingsRouter).environmentObject(self)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "PortNanny Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: view)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    func showHistory() {
        if historyWindow == nil {
            let historyView = HistoryView(portManager: portManager)
            historyWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            historyWindow?.center()
            historyWindow?.title = "PortNanny History"
            historyWindow?.contentViewController = NSHostingController(rootView: historyView)
            historyWindow?.isReleasedWhenClosed = false
        }

        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
