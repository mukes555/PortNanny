import PortNannyCore
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Renders the README demo GIF: a scripted search → kill → "port is free"
/// sequence over fabricated data, drawn offscreen (no screen recording needed).
#if DEBUG
extension AppDelegate {

    private static let demoSize = PortManager.PopoverSize.regular.dimensions

    func renderDemoReel(to path: String) {
        // A throwaway suite: the demo must not touch the real preferences
        // (it sets the watchlist, the view, and the tips flag).
        let demoDefaults = UserDefaults(suiteName: "com.mukes555.PortNanny.demo") ?? .standard
        demoDefaults.set(true, forKey: DefaultsKey.didDismissHotkeyTip)
        let manager = PortManager(defaults: demoDefaults, history: HistoryManager(defaults: demoDefaults), autoStart: false)
        manager.hasCompletedFirstScan = true // no live scan: skip the loading state
        manager.currentUser = DemoData.user
        manager.hideSystemProcesses = true
        manager.activeTests = [DemoData.test]
        manager.watchedPorts = [3000]
        manager.activePorts = DemoData.ports(includePort3000: true)
        manager.clock.lastUpdated = Date()

        let selectedNodeId = manager.activePorts.first { $0.port == 3000 }!.id

        var frames: [(image: NSImage, delay: Double)] = []
        func addFrame(search: String = "", selected: String? = nil, delay: Double) {
            let view = PortListView(portManager: manager, initialSearchText: search, initialSelectedId: selected)
                .environmentObject(self)
            if let image = renderFrame(AnyView(view)) {
                frames.append((image, delay))
            }
        }

        // 1. The full picture
        addFrame(delay: 2.0)

        // 2 to 4. Typing ":3000" into search
        addFrame(search: "3", delay: 0.45)
        addFrame(search: "300", delay: 0.4)
        addFrame(search: "3000", selected: selectedNodeId, delay: 1.6)

        // 5. Kill: port gone, toast up, search shows the "free" answer state
        manager.activePorts = DemoData.ports(includePort3000: false)
        manager.toastMessage = "Killed :3000"
        addFrame(search: "3000", delay: 2.0)

        // 6. Back to the list: the watched section confirms :3000 is free
        manager.toastMessage = nil
        addFrame(delay: 2.4)

        writeGIF(frames: frames, to: URL(fileURLWithPath: path))
    }

    private func renderFrame(_ view: AnyView) -> NSImage? {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: Self.demoSize)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        let image = NSImage(size: Self.demoSize)
        image.addRepresentation(rep)
        return image
    }

    private func writeGIF(frames: [(image: NSImage, delay: Double)], to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
        ) else { return }

        let gifProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0] // loop forever
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, gifProperties)

        for frame in frames {
            guard let cgImage = frame.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let frameProperties = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame.delay]
            ] as CFDictionary
            CGImageDestinationAddImage(destination, cgImage, frameProperties)
        }
        CGImageDestinationFinalize(destination)
    }
}
#endif
