# Contributing to PortNanny

Thanks for your interest! PortNanny is a small, dependency-free, native macOS
menu-bar app (with a built-in CLI). This guide gets you from clone to running in
about a minute, and explains how the project is organized.

> New to the codebase? Read [ARCHITECTURE.md](ARCHITECTURE.md) first: it maps
> the module layout and the scan pipeline.

## Prerequisites

- **macOS 13 (Ventura) or newer.** This is a macOS-only AppKit/SwiftUI app; it
  will not build or run on Linux or Windows.
- A Swift toolchain. CI builds with **Swift 6.0.2**; `Package.swift` declares a
  `5.9` minimum. Anything in that range should work.
- **No third-party dependencies.** There are zero external Swift packages, just
  the standard library, AppKit/SwiftUI, and a thin C shim (`CLibProc`) over
  Darwin's `libproc`.

## The one gotcha: the package lives in a nested directory

The Git repo is named `PortNanny` and the Swift package sits in a `PortNanny/`
subdirectory of it. After cloning you have to step in twice:

```bash
git clone https://github.com/mukes555/PortNanny.git
cd PortNanny/PortNanny        # repo root → Swift package root
```

Every `swift` command below is run from that package root.

## Run it (clone → running GUI in ~60s)

```bash
swift build
swift run PortNanny            # launches the menu-bar app (look for the quokka)
```

The package also builds the standalone CLI, and the app binary answers the
same subcommands:

```bash
swift run portnanny-cli list          # table of listening ports
swift run portnanny-cli list --json   # JSON, for scripting
swift run portnanny-cli kill 3000     # graceful kill; add --force for SIGKILL
swift run PortNanny list          # the app binary in CLI mode
```

## Test

```bash
swift build && swift test --disable-sandbox
```

`swift build` first: the scenario tests spawn the debug `portnanny-cli`
executable next to the test bundle, and `swift test` alone does not build
it. `--disable-sandbox` is required: several tests exercise the native
scanner, which makes raw `libproc` syscalls the SwiftPM sandbox blocks.

If the link step ever complains that `_portnanny_cli_main` is undefined,
the incremental state is stale: `rm -rf .build/arm64-apple-macosx/debug`
and build again.

## Build a distributable app

```bash
./scripts/build.sh            # → dist/PortNanny.app (ad-hoc signed)
./scripts/build.sh --dmg      # also produces dist/PortNanny-<version>.dmg
./scripts/build.sh --bundle-id=com.you.PortNanny   # override the bundle id
```

The app is **ad-hoc signed** (no Apple Developer account), so Gatekeeper will
warn on first open: right-click → Open, or
`xattr -dr com.apple.quarantine dist/PortNanny.app`.

## Developer hooks (env vars)

The app renders its own UI offscreen for screenshots and the README GIF, no
screen-recording permission needed. CI uses the first one as a smoke test.

| Env var | Effect |
|---|---|
| `PORTNANNY_SNAPSHOT=/path.png` | Render a view offscreen to PNG, then quit |
| `PORTNANNY_SNAPSHOT_VIEW=main\|bulkkill\|protected\|detail\|settings\|workbench\|workbench-live\|tour\|avatar\|menubar\|menubar-strip` | Which view to render (default `main`); `workbench-live` opens the real window for a moment so the sidebar material draws; `menubar-strip` is a made-up menu bar around the glyph |
| `PORTNANNY_SNAPSHOT_DATA=demo` | Render the scripted demo ports instead of this Mac's. Every README image uses it: a live scan shows your projects, paths, and user name |
| `PORTNANNY_SNAPSHOT_SEARCH="kill 3000"` | Seed the popover's search field, so the palette bar renders |
| `PORTNANNY_SNAPSHOT_SECTION=ports\|projects\|agents\|watchlist\|history` | Which Workbench view to render |
| `PORTNANNY_SNAPSHOT_SELECT=3000` | Select that port in the Workbench, so the inspector renders |
| `PORTNANNY_SNAPSHOT_TOUR_PAGE=1` | Which page of the welcome tour to render |
| `PORTNANNY_MASCOT_DIR=assets/mascot` | Where a bare binary finds the quokka art (an app bundle carries it) |
| `PORTNANNY_DEFAULTS_SUITE=<suite>` | Preferences and history go to that defaults domain, so renders and scenario runs never touch your own settings |
| `PORTNANNY_SNAPSHOT_PANE=general\|display\|agents\|shortcuts\|protected\|about` | Which Settings pane to render |
| `PORTNANNY_SNAPSHOT_TEXTSIZE=large` | Render at an accessibility text size to check that rows reflow |
| `PORTNANNY_SNAPSHOT_MODE=agents\|ports` | Which view to render |
| `PORTNANNY_SNAPSHOT_DETAILS=1` | Turn row details on |
| `PORTNANNY_SNAPSHOT_WATCH=3000,9999` | Seed watched ports |
| `PORTNANNY_SNAPSHOT_APPEARANCE=light\|dark` | Force appearance |
| `PORTNANNY_SHOW_ON_LAUNCH=1` | Auto-open the popover on launch |
| `PORTNANNY_DEMO_GIF=/path.gif` | Render the scripted demo reel (fabricated data) to an animated GIF, then quit |

`portnanny __serve <port>` (debug builds only) listens on 127.0.0.1 and
sleeps forever; the scenario tests use it as a stand-in for an agent's dev
server, with whatever environment the scenario needs.

Regenerate the README assets. Always with `PORTNANNY_SNAPSHOT_DATA=demo`
(the scripted ports in DemoData.swift): a live scan would put your project
folders, paths, and user name into the repository, and the images are public.

```bash
# main-view screenshot
PORTNANNY_SNAPSHOT_DATA=demo PORTNANNY_DEFAULTS_SUITE=com.mukes555.PortNanny.readme PORTNANNY_MASCOT_DIR=assets/mascot PORTNANNY_SNAPSHOT=../assets/screenshot-dark.png PORTNANNY_SNAPSHOT_APPEARANCE=dark PORTNANNY_SNAPSHOT_MODE=ports PORTNANNY_SNAPSHOT_DETAILS=1 PORTNANNY_SNAPSHOT_WATCH=3000 .build/debug/PortNanny
# (the same with APPEARANCE=light for screenshot-light.png; PORTNANNY_SNAPSHOT_SEARCH="kill 4400" for palette.png)
# the Workbench: a real window, photographed (needs Screen Recording permission
# for the debug binary; the offscreen render leaves the sidebar column blank)
PORTNANNY_SNAPSHOT_DATA=demo PORTNANNY_DEFAULTS_SUITE=com.mukes555.PortNanny.readme PORTNANNY_MASCOT_DIR=assets/mascot PORTNANNY_SNAPSHOT=../assets/workbench.png PORTNANNY_SNAPSHOT_VIEW=workbench-live PORTNANNY_SNAPSHOT_SELECT=3000 .build/debug/PortNanny
# the menu bar strip (made up, so no other app's icon ends up in the README)
PORTNANNY_SNAPSHOT_DATA=demo PORTNANNY_DEFAULTS_SUITE=com.mukes555.PortNanny.readme PORTNANNY_MASCOT_DIR=assets/mascot PORTNANNY_SNAPSHOT=../assets/menubar.png PORTNANNY_SNAPSHOT_VIEW=menubar-strip .build/debug/PortNanny
# animated demo
PORTNANNY_DEFAULTS_SUITE=com.mukes555.PortNanny.readme PORTNANNY_MASCOT_DIR=assets/mascot PORTNANNY_DEMO_GIF=../assets/demo.gif .build/debug/PortNanny
```

## The Claude Code plugin

`plugins/portnanny` is a Claude Code plugin (manifest in `.claude-plugin/`,
MCP registration in `.mcp.json`, the lsof hook in `hooks/`, the skill in
`skills/portnanny/SKILL.md`, slash commands in `commands/`), listed by the
marketplace file at the repository root. A test keeps the skill's command
list in step with `portnanny agent-docs`. Try a working copy with
`claude --plugin-dir plugins/portnanny`.

## Artwork

The app icon and the mascot come from the quokka artwork through one script:

```bash
swift scripts/make_artwork.swift icon path/to/quokka-1024.png assets/AppIcon.icns          # rounded-square mask, all sizes
swift scripts/make_artwork.swift mascot path/to/waving.png assets/mascot/quokka-happy.png  # white background lifted, 512 px tall
```

Moods are `happy`, `sleepy`, and `guard`; `build.sh` copies them into the
bundle and `MascotView` falls back to a symbol when one is missing.

`quokka-happy.png` is load-bearing: the header avatar is cut from it and
the menu bar glyph is traced from that crop, so its framing has rules.
The prompts that draw the character, the rules, and how to check the
result are in [docs/ARTWORK.md](docs/ARTWORK.md).

## End-to-end checks

`swift test` builds its own fixtures, so some things it cannot see: it
missed `portnanny kill` being unable to stop a Docker container, because
those tests construct a `ManagedRuntime` directly and never run the scan
that feeds one. `Tests/e2e/` drives the built binary against real
listeners instead. Manual, not in CI, worth running after a change to
scanning, attribution, the guard, the supervisors, or the MCP server.
See [Tests/e2e/README.md](PortNanny/Tests/e2e/README.md).

## Coding style

The project favors code written **for human brains**: early returns over nested
`if`s, complex conditions extracted into named booleans, deep modules with
simple interfaces, and files small enough to hold in your head (aim ~300 lines, split at ~500,
split by responsibility well before 1000). Comments explain **why**, not what.
Match the surrounding style.

## Submitting a pull request

1. Branch from `main`. **Never push directly to `main`/`master`** (CI gates it).
2. Keep the change focused; one concern per PR.
3. `swift build && swift test --disable-sandbox` must pass, and the build must stay green.
4. Add an entry to [CHANGELOG.md](CHANGELOG.md) under an "Unreleased" heading.
5. Open the PR; CI runs `scripts/build.sh`, the test suite, and a UI-render
   smoke test on `macos-14`.

## Releases (maintainers)

Tag a version (`git tag v1.6.0 && git push --tags`) and
`.github/workflows/release.yml` builds the universal DMG + zip and publishes a
GitHub release whose notes come from `CHANGELOG.md`. Full process and the
"What's new" standard: **[RELEASING.md](RELEASING.md)**.

## Reporting bugs & security issues

Use the issue templates for bugs and features. For anything security-sensitive
(this app kills processes and shells out to system tools), see
[SECURITY.md](SECURITY.md).
