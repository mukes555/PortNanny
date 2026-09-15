import Foundation

// MARK: - Updates
// Once a day (when allowed), and on request from About.
extension PortManager {

    /// "Check once a day" was checked once per launch: a Mac that sleeps
    /// instead of shutting down never saw a new version, and a check that
    /// failed at login (Wi-Fi not up yet) was never retried for that whole
    /// session. This timer asks hourly and `shouldAutoCheck` decides.
    static let updateCheckInterval: TimeInterval = 60 * 60

    public func startUpdateChecks() {
        updateTimer?.invalidate()
        guard autoUpdateCheck else { return }
        let timer = Timer(timeInterval: Self.updateCheckInterval, repeats: true) { [weak self] _ in
            guard let self, self.autoUpdateCheck, UpdateChecker.shouldAutoCheck() else { return }
            self.checkForUpdates(manual: false)
        }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    public func checkForUpdates(manual: Bool) {
        UpdateChecker.fetchNewerVersion(includePrereleases: includePrereleases) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .newer(let version):
                UpdateChecker.markChecked()
                self.updateAvailableVersion = version
                if manual { self.showToast("v\(version) available") }
            case .upToDate:
                UpdateChecker.markChecked()
                self.updateAvailableVersion = nil
                if manual { self.showToast("You're up to date") }
            case .failed(let reason):
                // Not marked as checked, so the next launch tries again.
                Log.update.error("update check failed: \(reason, privacy: .public)")
                if manual { self.showToast("Couldn't check for updates: \(reason)") }
            }
        }
    }
}
