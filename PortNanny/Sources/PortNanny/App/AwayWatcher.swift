import AppKit
import Foundation

/// Whether the person is at the Mac.
///
/// macOS holds every banner posted while the screen is locked or the display
/// is asleep, then delivers the whole queue at unlock, each with its own
/// sound. An agent restarting a watched server for an hour turned into a wall
/// of banners and an alarm. PortNanny stops posting while away and keeps a
/// count instead; one summary follows when the screen comes back.
final class AwayWatcher {
    private let onChange: (Bool) -> Void
    private var isLocked = false
    private var screensAreAsleep = false
    private var lockTokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []

    var isAway: Bool { isLocked || screensAreAsleep }

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange

        // The lock screen is a distributed notification; display sleep is a
        // workspace one. Either means the banners would be queued, not seen.
        let distributed = DistributedNotificationCenter.default()
        lockTokens.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.set { $0.isLocked = true }
        })
        lockTokens.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.set { $0.isLocked = false }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.set { $0.screensAreAsleep = true }
        })
        workspaceTokens.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.set { $0.screensAreAsleep = false }
        })
    }

    deinit {
        lockTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// Reports only when the answer changes: a lock during display sleep must
    /// not read as a return.
    private func set(_ change: (AwayWatcher) -> Void) {
        let was = isAway
        change(self)
        if isAway != was { onChange(isAway) }
    }
}
