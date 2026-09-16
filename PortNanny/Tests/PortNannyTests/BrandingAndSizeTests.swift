import XCTest
@testable import PortNannyCore
@testable import PortNanny

/// UI-3: the quokka branding, the popover sizes, and the richer rows.
final class BrandingAndSizeTests: XCTestCase {

    // MARK: - Preferences

    func testPopoverSizeAndMenuBarIconPersistAndReset() {
        let manager = PortManager.forTesting()
        defer { manager.discardTestDefaults() }
        XCTAssertEqual(manager.popoverSize, .regular, "bigger by default")
        XCTAssertEqual(manager.menuBarIcon, .mono, "the traced quokka by default")

        var sizeChanges = 0
        manager.onPopoverSizeChanged = { sizeChanges += 1 }
        var menuBarChanges = 0
        manager.onMenuBarPreferenceChanged = { menuBarChanges += 1 }
        manager.popoverSize = .large
        manager.menuBarIcon = .color
        XCTAssertEqual(sizeChanges, 1, "the open popover resizes at once")
        XCTAssertEqual(menuBarChanges, 1, "the status item redraws at once")
        XCTAssertEqual(manager.defaults.string(forKey: DefaultsKey.popoverSize), "large")
        XCTAssertEqual(manager.defaults.string(forKey: DefaultsKey.menuBarIcon), "quokka")

        let restored = PortManager(defaults: manager.defaults, history: HistoryManager(defaults: manager.defaults), autoStart: false)
        XCTAssertEqual(restored.popoverSize, .large)
        XCTAssertEqual(restored.menuBarIcon, .color)

        manager.resetAllSettings()
        XCTAssertEqual(manager.popoverSize, .regular)
        XCTAssertEqual(manager.menuBarIcon, .mono)
    }

    func testUnknownStoredChoicesFallBackToTheDefaults() {
        let suite = "PortNannyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.discardSuite(named: suite, defaults: defaults) }
        defaults.set("gigantic", forKey: DefaultsKey.popoverSize)
        defaults.set("bolt", forKey: DefaultsKey.menuBarIcon)
        let manager = PortManager(defaults: defaults, history: HistoryManager(defaults: defaults), autoStart: false)
        XCTAssertEqual(manager.popoverSize, .regular)
        XCTAssertEqual(manager.menuBarIcon, .mono, "the bolt is gone; a stored choice for it means the default")
    }

    func testSizesGrowAndCompactIsTheOldPopover() {
        XCTAssertEqual(PortManager.PopoverSize.compact.dimensions, NSSize(width: 500, height: 600))
        let sizes = PortManager.PopoverSize.allCases.map(\.dimensions)
        for (smaller, larger) in zip(sizes, sizes.dropFirst()) {
            XCTAssertLessThan(smaller.width, larger.width)
            XCTAssertLessThan(smaller.height, larger.height)
        }
        XCTAssertEqual(PortManager.PopoverSize.allCases.map(\.label), ["Compact", "Regular", "Large"])
    }

    func testDebugRendersKeepPreferencesInTheirOwnSuite() {
        setenv("PORTNANNY_DEFAULTS_SUITE", "PortNannyTests.renders.\(UUID().uuidString)", 1)
        XCTAssertFalse(AppDelegate.preferenceDefaults === UserDefaults.standard, "a snapshot's density never lands in real settings")
        unsetenv("PORTNANNY_DEFAULTS_SUITE")
        XCTAssertTrue(AppDelegate.preferenceDefaults === UserDefaults.standard)
    }

    // MARK: - Brand

    func testMenuBarIconsComeFromTheArtwork() throws {
        pointAtTheArtwork()
        defer { unsetenv("PORTNANNY_MASCOT_DIR") }
        let color = MenuBarGlyph.colorIcon(active: true)
        XCTAssertFalse(color.isTemplate, "the app icon keeps its colours")
        XCTAssertEqual(color.size, NSSize(width: 18, height: 18))
        XCTAssertGreaterThan(try coverage(of: color), try coverage(of: MenuBarGlyph.colorIcon(active: false)), "idle is dimmed")

        let mono = MenuBarGlyph.monoIcon(active: true)
        XCTAssertTrue(mono.isTemplate, "mono follows the menu bar's look")
        let monoCoverage = try coverage(of: mono)
        XCTAssertGreaterThan(monoCoverage, 0.25, "the head fills the glyph")
        XCTAssertLessThan(monoCoverage, 0.9, "the shades and the mouth are holes")
        XCTAssertGreaterThan(monoCoverage, try coverage(of: MenuBarGlyph.monoIcon(active: false)), "idle is lighter")
        XCTAssertTrue(MenuBarGlyph.image(.mono, active: false) === MenuBarGlyph.image(.mono, active: false), "drawn once, then cached")
    }

    func testEveryMoodHasItsOwnArtwork() throws {
        pointAtTheArtwork()
        defer { unsetenv("PORTNANNY_MASCOT_DIR") }
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["PORTNANNY_MASCOT_DIR"])
        var seen: [Data: MascotView.Mood] = [:]
        for mood in [MascotView.Mood.happy, .sleepy, .onGuard, .searching] {
            XCTAssertNotNil(MascotView.artwork(for: mood), "no artwork loads for \(mood.rawValue)")
            let file = URL(fileURLWithPath: directory).appendingPathComponent("quokka-\(mood.rawValue).png")
            let bytes = try Data(contentsOf: file)
            // Three moods shipped as one file until this artwork landed, so
            // the sleepy empty state and the guard badge both waved at you.
            XCTAssertNil(seen[bytes], "\(mood.rawValue) is the same file as \(seen[bytes]?.rawValue ?? "")")
            seen[bytes] = mood
        }
    }

    func testTheVectorFaceStandsInWithoutArtwork() throws {
        let filled = MenuBarGlyph.quokka(filled: true)
        let outline = MenuBarGlyph.quokka(filled: false)
        XCTAssertTrue(filled.isTemplate)
        XCTAssertTrue(outline.isTemplate)
        let filledCoverage = try coverage(of: filled)
        let outlineCoverage = try coverage(of: outline)
        XCTAssertGreaterThan(filledCoverage, outlineCoverage, "active is the filled face")
        XCTAssertGreaterThan(outlineCoverage, 0.05, "idle is drawn")
        XCTAssertLessThan(filledCoverage, 0.9, "the shades and the smile are cut out")
    }

    /// The repo's artwork stands in for the bundle's.
    private func pointAtTheArtwork() {
        let mascots = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/mascot").path
        setenv("PORTNANNY_MASCOT_DIR", mascots, 1)
    }

    /// Fraction of pixels the glyph covers, from a 72 px render.
    private func coverage(of image: NSImage) throws -> Double {
        let size = 72
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        var covered = 0
        for y in 0..<size {
            for x in 0..<size where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                covered += 1
            }
        }
        return Double(covered) / Double(size * size)
    }

    func testHeaderSummaryReadsLikeASentence() {
        XCTAssertEqual(BrandHeader.summary(portCount: 0, memory: "0B", liveSessions: 0, scanned: false), "Scanning ports…")
        XCTAssertEqual(BrandHeader.summary(portCount: 0, memory: "0B", liveSessions: 0, scanned: true), "Nothing is listening")
        XCTAssertEqual(BrandHeader.summary(portCount: 1, memory: "45MB", liveSessions: 0, scanned: true), "1 port · 45MB")
        XCTAssertEqual(BrandHeader.summary(portCount: 19, memory: "3.1GB", liveSessions: 2, scanned: true), "19 ports · 3.1GB · 2 agent sessions")
    }

    func testLiveSessionsCountOnlyRunningAgents() {
        let live = AgentOwner(name: "Claude Code", sessionPid: 10, source: .processTree)
        let sameSession = AgentOwner(name: "Claude Code", sessionPid: 10, source: .processTree)
        let other = AgentOwner(name: "Codex CLI", sessionPid: 20, source: .processTree)
        let ended = AgentOwner(name: "Cursor", source: .environment, sessionEnded: true)
        let terminal = AgentOwner(name: "VS Code", source: .environment, confidence: .editorTerminal)
        let ports = [live, sameSession, other, ended, terminal].enumerated().map { index, owner in
            PortInfo(port: 3000 + index, pid: 100 + index, processName: "node", command: "node", user: "me",
                     memoryUsage: "1MB", memorySizeKB: 1, type: .nodejs, agentOwner: owner)
        }
        XCTAssertEqual(AgentSessions.liveSessionCount(of: ports), 2, "one Claude session on two ports and one Codex; ended and terminal do not count")
    }

    func testTheAvatarIsTheHeadCutFromTheArtwork() throws {
        pointAtTheArtwork()
        defer { unsetenv("PORTNANNY_MASCOT_DIR") }
        let happy = try XCTUnwrap(MascotView.artwork(for: .happy), "artwork under assets/mascot")
        let face = try XCTUnwrap(MascotView.face(for: .happy))
        XCTAssertLessThan(face.size.height, happy.size.height * 0.5, "the head, not the whole figure")
        XCTAssertEqual(face.size.height, face.size.width * MascotView.headAspect, accuracy: 1, "a fifth taller than wide: the chin is in")
        let square = try XCTUnwrap(MascotView.face(for: .happy, aspect: 1))
        XCTAssertEqual(square.size.width, square.size.height, accuracy: 1, "the menu bar's square box")
        XCTAssertTrue(MascotView.face(for: .happy) === face, "cut once, then cached")

        // The box starts at the very first opaque row, so the ear tips are in.
        let full = try XCTUnwrap(happy.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let box = try XCTUnwrap(MascotView.headBox(in: full))
        XCTAssertLessThanOrEqual(box.minY, CGFloat(full.height) * 0.2, "the ears begin about 16% down this artwork; the box starts just above them")
        XCTAssertGreaterThan(box.width, CGFloat(full.width) * 0.35, "ear to ear (the laptop and the hand make the figure wide)")
        XCTAssertLessThan(box.maxY, CGFloat(full.height) * 0.6, "stops at the collar, above the mug and the hand")
    }
}
