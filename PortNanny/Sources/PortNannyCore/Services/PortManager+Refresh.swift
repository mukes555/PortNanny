import Foundation

// MARK: - Refresh scheduling and the scan pipeline
// The timer cadence follows what is on screen; each refresh runs one native
// snapshot on a background queue and publishes only what actually changed.
extension PortManager {

    /// Called by the app delegate when the popover opens/closes so the timer
    /// can switch between the foreground and background cadence.
    public func setUIVisible(_ visible: Bool) {
        isUIVisible = visible
        // Opening wants fresh, full data now; closing only changes cadence,
        // so it must not spend a scan nobody will see.
        restartTimer(refreshNow: visible)

        let isManualMode = refreshInterval <= 0
        if visible && isManualMode {
            refresh()
        }
    }

    private var effectiveRefreshInterval: TimeInterval {
        let interval = Self.sanitizedRefreshInterval(refreshInterval)
        if interval <= 0 { return 0 } // manual only
        if isUIVisible { return interval }
        return max(interval, Self.backgroundRefreshInterval)
    }

    /// 0 means manual refresh; anything else is clamped to 1...300 seconds.
    /// Preferences are untrusted input: 0.01 would scan a hundred times a
    /// second, and NaN slips past a `<= 0` check and throws inside Timer.
    public static func sanitizedRefreshInterval(_ value: Double) -> Double {
        guard value.isFinite else { return 2.0 }
        if value <= 0 { return 0 }
        return min(max(value, 1.0), 300)
    }

    public static func isValidPortNumber(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }

    public func startAutoRefresh(refreshNow: Bool = true) {
        stopAutoRefresh()

        let interval = effectiveRefreshInterval
        if interval <= 0 {
            return
        }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Let macOS coalesce wakeups for power efficiency.
        timer.tolerance = interval * 0.1
        // Common modes, not the default one: a kill confirmation or an open
        // menu runs its own run loop mode, and the default-mode timer stopped
        // there. Scanning stopped with it, so a guard watched nothing for as
        // long as a dialog stood open.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        if refreshNow {
            refresh()
        }
    }

    public func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    public func restartTimer(refreshNow: Bool = true) {
        stopAutoRefresh()
        startAutoRefresh(refreshNow: refreshNow)
    }

    public var totalPortsMemory: String {
        MemoryFormat.string(kilobytes: activePorts.reduce(0) { $0 + $1.memorySizeKB })
    }

    public var totalTestsMemory: String {
        MemoryFormat.string(kilobytes: activeTests.reduce(0) { $0 + $1.memorySizeKB })
    }

    private func publishTests(_ tests: [TestProcessInfo]) {
        let changed = Self.testsSignature(tests) != Self.testsSignature(activeTests)
        let stale = Date().timeIntervalSince(lastTestsPublish) > 10
        guard changed || (stale && tests != activeTests) else { return }
        activeTests = tests
        lastTestsPublish = Date()
    }

    // MARK: - Refresh

    public func refresh(showToast: Bool = false) {
        if usesDemoData { return }
        if isRefreshing {
            // A press during a slow scan must not look like nothing happened.
            if showToast { self.showToast("Refreshing…") }
            return
        }
        isRefreshing = true
        // Nothing on screen: the badge and the watchlist need six fields, not
        // working directories, Docker names, or agent attribution.
        let depth: PortScanner.ScanDepth = isUIVisible ? .full : .light
        let guarded = guardedPorts

        // Nobody is waiting on a hidden scan, so it can be scheduled with
        // other background work rather than on a performance core.
        DispatchQueue.global(qos: depth == .full ? .userInitiated : .utility).async { [weak self] in
            guard let self = self else { return }

            // One native snapshot shared by both scanners.
            let processTable = ProcessTable.capture()
            let tests = self.processScanner.scanTestProcesses(processes: processTable)
            let portsResult = Result { try self.scanner.scanActivePorts(processes: processTable, depth: depth) }
            // A light scan skips attribution, but the guard decides on it and
            // runs precisely while nothing is on screen: attribute just the
            // occupants of guarded ports.
            let guardOwners = Self.ownersOfGuardedOccupants(guarded, in: (try? portsResult.get()) ?? [], processes: processTable)

            DispatchQueue.main.async {
                self.publishTests(tests)
                self.isRefreshing = false

                switch portsResult {
                case .success(let ports):
                    // The popover opened while this hidden-state scan ran (its
                    // own refresh request was dropped as re-entrant). Stripped
                    // rows must not reach the screen: run the full scan now.
                    if depth == .light && self.isUIVisible {
                        self.refresh()
                        return
                    }
                    // Gate on a stable projection: cpuPercent/age change nearly
                    // every scan, so full-model `!=` would republish (and force a
                    // whole-list SwiftUI re-diff) every 2s even when nothing
                    // structural changed.
                    let current = depth == .full ? self.activeSignature : Self.stableSignature(self.activePorts, depth: .light)
                    if Self.stableSignature(ports, depth: depth) != current {
                        self.activePorts = ports
                    }
                    // Every scan feeds the sparklines, published or not.
                    self.metrics.record(ports)
                    self.processWatchedPorts(with: ports, guardOwners: guardOwners)
                    self.firePendingFreeNotifications(with: ports)
                    if !self.hasCompletedFirstScan { self.hasCompletedFirstScan = true }
                    let usedFallback = self.scanner.lastScanUsedFallback
                    if usedFallback != self.isCompatibilityScan { self.isCompatibilityScan = usedFallback }
                    self.clock.lastUpdated = Date()
                    // Assigning nil to nil still publishes, which would
                    // re-render every observer on every scan.
                    if self.lastErrorMessage != nil { self.lastErrorMessage = nil }
                    if showToast {
                        self.showToast("Refreshed")
                    }
                case .failure(let error):
                    self.lastErrorMessage = self.formatError(error, context: "Refresh failed")
                    if showToast {
                        self.showToast(self.lastErrorMessage ?? "Refresh failed")
                    }
                }
            }
        }
    }


    /// Identity of the list ignoring volatile per-scan metrics (CPU%, age).
    /// Two scans with the same signature render identically. A light scan
    /// carries no enrichment, so its signature leaves those fields out; the
    /// next full scan differs and republishes them.
    public static func stableSignature(_ ports: [PortInfo], depth: PortScanner.ScanDepth = .full) -> [String] {
        ports.map { port in
            var fields: [String] = [
                String(port.port),
                String(port.pid),
                port.proto,
                port.processName,
                String(port.memorySizeKB),
                port.type.rawValue,
                port.bindAddress ?? "",
                String(port.connections),
            ]
            if depth == .full {
                fields.append(port.containerName ?? "")
                fields.append(String(port.children?.count ?? 0))
                // Attribution can change on its own (a session ending);
                // the chip must follow.
                let owner = port.agentOwner.map { "\($0.sessionId)|\($0.confidence.rawValue)|\($0.sessionEnded)" } ?? ""
                fields.append(owner)
                fields.append(port.managedBy?.label ?? "")
                fields.append(port.reservation?.owner ?? "")
                fields.append(port.expectedPort.map { String($0.port) } ?? "")
                // A light scan leaves this empty; the first full scan after
                // one must republish so the row gets its project back.
                fields.append(port.projectPath ?? "")
            }
            return fields.joined(separator: "|")
        }
    }

    /// Test rows republish on structural change, or at most every 10s so
    /// the Tests tab's CPU column keeps moving without a re-render per scan.
    public static func testsSignature(_ tests: [TestProcessInfo]) -> [String] {
        tests.map { "\($0.pid)|\($0.processName)|\($0.type.rawValue)|\($0.agentOwner?.sessionId ?? "")" }
    }

}
