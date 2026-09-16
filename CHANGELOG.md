# Changelog

All notable changes are documented here. The GitHub Release notes for each
version are generated automatically from the matching section below, so keep
entries user-facing and concise.

Format: one `## <version> (<date>)` heading per release, with changes grouped
under **Added**, **Changed**, **Fixed**, **Security**, or **Distribution**.
Accumulate work-in-progress notes under **[Unreleased]** as you land PRs; on
release, rename it to the version and date.

## [Unreleased]

### Added
- **An Agents view, and it is where PortNanny now opens.** What is listening
  is grouped by the session that started it: each agent with its servers and
  how much memory they hold, the ports an agent has reserved and not started
  on yet, the sessions that have ended (with one button to clean up after
  them), and everything nobody claims. When another agent has just been
  refused one of a session's ports, the section says so.
- The old Clean/Advanced density became two things: the view above (Agents
  or Ports, the plain list by kind), and a "Show details in rows" switch
  that works in either. An upgrade from Advanced keeps its detail.
- **`portnanny agents`** answers the same question in a terminal, and in
  `--json` for the agents themselves: every session here, the servers it is
  running, the ports it has claimed, and which one is you. The rules file
  PortNanny installs into projects now points agents at it.
- The Workbench opens on Agents, and its session cards show claims too.

<!-- next -->

## 2.3.0 (2026-09-16)

A bug-hunting round: fuzzing, concurrent agents, corrupted stores, hostile
tools and the app's own lifecycle. Everything below was reproduced first.

### Fixed
- **Guarding a busy port killed the server on it.** Watching or guarding a
  port recorded its occupant in a different format from the one scans
  write, so the next scan read the server already there as a newcomer: a
  watch announced it, and a guard killed the very thing it was set to
  protect.
- **One long argument froze every scan.** The patterns that find a secret
  in a command line backtracked over every way of splitting a run of word
  characters: 800 characters took 2.6 seconds and a few kilobytes took
  minutes, on every listener, on every scan. 500 KB now takes 0.15s.
- **Killing a port inside tmux killed the whole session.** A tmux server
  keeps the argv of the command that opened it, so `tmux new -s build tsc
  --watch` looked like a reloader and the kill went to tmux and everything
  under it: every pane, the editor, other servers.
- **A port held by another user read as free.** The listener table cannot
  see root's or `_postgres`'s sockets, so `free 5432` exited 0 and the
  next server still could not bind. Kill, free, wait, reserve and exec now
  ask the kernel before answering.
- **Kills reported more than they did.** A partial kill exited 0 as
  "killed"; a tree kill swallowed every child it could not stop (and its
  pgrep fallback killed none at all); a process that had already exited
  was recorded in History as killed; `free` checked that the pid died
  rather than that the port was free.
- **An agent installed through npm or pip looked like an ended session**,
  because it runs as `node …/bin/gemini` or `python3 …/bin/aider`. That
  let `kill --orphaned` reap a live agent's server and allowed a rival
  agent's kill that should have been refused.
- **Agent kills trimmed History to 50 entries** however long you had set
  it, and changing the length in Settings dropped everything an agent had
  recorded since the window last read it.
- **One damaged entry hid every lease and every history row**, and the
  next write saved that empty list over the good ones. Entries are now
  salvaged one at a time.
- **Four crashes**: a non-finite JSON-RPC id, an oversized `CLAUDE_PID`, a
  closed stderr, and a stored lease naming an impossible pid.
- **The popover's shortcuts stayed live after it closed**, so Return in
  the Workbench started a kill from a list nobody could see, and Escape
  stopped working everywhere. A confirmation opened from the popover fed
  its own Return back and stacked a second dialog.
- **Cut, Copy, Paste, Select All, Undo and Close did nothing** in every
  PortNanny text field and window: a menu bar app still needs a main menu
  for those keys to route.
- The refresh timer stopped while any dialog or menu was open, blinding
  the guard exactly then; the guard announced "Auto-killing" before
  signalling anything and said nothing when a kill failed; refusal
  banners never asked for notification permission, so macOS dropped them;
  clicking a watch or guard banner did nothing; `portnanny://show` during
  launch was dropped, closing the welcome tour left nothing on screen, and
  a second copy of PortNanny guarded every port twice.
- Smaller ones: `free-port --range` alone was rejected, a lease reason
  kept `--token=…` unredacted and quoted it back to other agents, a
  process name with a carriage return could write its own row into
  `portnanny list`, Docker containers publishing a port range went
  unnamed, a test worker under a path with a space could not be killed,
  `portnanny://kill/9999/3000` acted on :3000, `agent-docs` replaced a
  symlinked CLAUDE.md with a private copy, and a scan lost to a stalled
  network mount stopped every later one.

### Changed
- Exit codes: a partial kill is 4, a lease or history write that fails is
  73, and `exec` answers 126 and 127 like a shell.
- MCP results say `isError` truthfully: a `wait_for_port_free` that timed
  out is an error, an unknown `list_ports` filter is refused rather than
  silently listing everything, `kill_port` validates its port and pid, and
  `list_ports` with filter `mine` and no identity says so.
- The shortcut recorder refuses ⌘W, ⌘Q and combinations macOS owns, which
  it used to accept and then never fire.
- Toasts and errors now appear in the Workbench and Settings; both were
  drawn only by the popover.

## 2.2.1 (2026-09-08)

Two bugs that end-to-end testing found and the unit suite could not: a
kill that could never stop a Docker container, and a force kill that only
worked from the list. The README now describes the app that exists.

### Fixed
- **`portnanny kill` could not stop a Docker container.** It scanned
  without asking for container names, so it never had one, and every
  Docker-published port answered "a container `docker ps` can name" and
  stopped nothing, while `portnanny whois` on the same port printed the
  exact `docker stop` command it would not run. The MCP `kill_port` had it
  too. A kill now fetches the name when a target is a container it cannot
  name yet, and pays the `docker ps` only then.
- **Command-Return force killed a selected row but not a typed one.** With
  `kill 3000` in the search field it sent a plain SIGTERM, contradicting
  the keyboard help and the code's own comment.

### Changed
- The README was checked line by line against the code and rewritten
  around what it found: eighteen claims were wrong or misleading, among
  them Command-K killing "the current filter" (on All it kills dev
  servers), "hide UDP sockets" (the switch shows them, and is on),
  "the only network request" (the inspector's peek is a local one), and
  a scan taking "about 20 ms with no subprocesses" (kernel calls in a few
  milliseconds, with lsof and ps as fallbacks). It also documents the
  right-click menu and that the Tests filter lists test processes rather
  than ports, neither of which it mentioned before.
- `Tests/e2e/` holds the harness that caught the Docker bug: the guard and
  the MCP server driven against real listeners. Manual, not in CI, since
  it needs real processes and Docker.

## 2.2.0 (2026-09-08)

A face for every state, and an audit behind it. The quokka was one image
wearing three names; she now has four, and a search that finds nothing
says so in her own voice. Behind that, six passes over the code found
thirty things worth fixing, including a guard that could miss a
supervisor's respawn and secrets reaching agents through a listener's
child processes.

### Changed
- **New artwork, and three moods that are actually different.** The mascot
  shipped as one file under three names, so "All quiet: nothing is
  listening" and the guard badge both showed the waving quokka. There is
  now a sleeping one for the empty state, a bust bold enough to read at
  badge size for the guard, and a new one for a search that matches
  nothing. The app icon, the README banner, and every screenshot are
  redrawn to match.
- `scripts/make_artwork.swift` keeps an alpha channel the source already
  has. It used to recompute one from whiteness whatever it was given,
  which turned a transparent background opaque black and the white
  pinafore see-through.
- The banner is a drawn asset rather than one composed by a script, so
  `scripts/make_logo.swift` and the two generated logo files are gone.
- The README opens with the problem it solves and carries a nav row;
  `docs/ARTWORK.md` holds the prompts that draw the character.
- **Destructive buttons ask first.** Clear History, both Release buttons,
  and Reset Defaults went straight through while every kill confirms.
- **Empty states tell the truth.** A filtered list said "nothing is
  listening" while the header counted every port; the Workbench table had
  no empty or scanning state at all.
- **The detail sheets close properly**: a real button with a name for
  VoiceOver, on Escape, instead of a fake traffic light. Ten icon-only
  buttons gained accessibility labels.
- One vocabulary (Stop watching, Remove guard, Option-click), ":3000" in
  notification titles, and "free" readable in light mode.
- Fewer wakeups: a successful scan no longer republishes to every view,
  the hidden scan runs at a background priority, and Settings stopped
  asking launchd for its login-item status on every redraw.

### Fixed
- **The guard could miss a supervisor's respawn.** Watched occupancy
  remembered a process name, so a server restarted under the same name
  looked like nothing had happened and the guard never fired.
- **`wait --timeout 0` always said "still in use"**, because it never
  looked at the port before checking the clock.
- **Attribution walked the wrong chain.** With a session pid to follow,
  the CLI stopped before reaching its own parents, so `whoami` named the
  wrong source and a lease taken by one agent could be refused to that
  same agent. A caller whose agent has no session id of its own now
  borrows its pid, the value `exec` stamps on what it starts, so a
  detached server and its own session match.
- **Claude Code installed through npm** runs as node, matched no
  signature, and its live sessions read as ended, which let anyone stop
  its servers. Servers under a path containing a space (fnm's default)
  were classified Other rather than Node.js, and pm2 under fnm was not
  found.
- A project name that arrived with the first full scan after a background
  one was not treated as a change, so rows kept a missing project. A CPU
  sample taken milliseconds after another showed a process at 50%.
- A lease warning meant for people was collected and dropped.
- **A rule file with one PortNanny marker and not its pair** was appended
  to, duplicating the block; the next run then deleted the person's own
  text between the two markers. `list --mine --orphaned` quietly applied
  one of the two. `exec --range` was dropped when it equalled the default.

### Security
- Command lines of a listener's **children** went into `--json` and MCP
  output unredacted, so a worker started with `--token=...` leaked. The
  redaction also missed digit-bearing names (`S3_SECRET_KEY`), JSON
  secrets, and header secrets.
- A lease reason is capped and stripped of control characters, and so are
  process names and command lines: a process could name itself with escape
  sequences that rewrite the terminal reading `portnanny list`.
- **A tree kill could signal a recycled pid.** Each child was checked
  against a name read at kill time, which compares the new process with
  itself and can never fail; the walk now carries the name it saw.
- Output carries the short session key rather than the full one, so an
  agent cannot copy what it read and pass as another agent's session.
- Every GitHub Action is pinned to a commit, the release token is scoped
  to the job that publishes, and the Homebrew cask is pinned to the
  checksum the build wrote rather than to a fresh download that could
  hash an error page.

## 2.1.1 (2026-09-07)

The polish after the rename: a bigger, whole quokka in the header and the
Workbench, README images that never came from anyone's real Mac, and a
cask that current Homebrew installs without a word.

### Changed
- **A bigger quokka.** The avatar grows to 40 pt in the popover header and
  36 pt in the Workbench sidebar, and the head crop now runs from the cap
  to the chin with room on both sides, so the face is whole and centred
  instead of ending at the mouth. The menu bar keeps its round glyph.
- The Raycast extension scaffold under `extensions/raycast` is gone (the
  extension was dropped), and so is the unpinned pre-2.0 cask file; the
  release workflow and the tap render the pinned template only.

### Fixed
- **README images are scripted.** The popover screenshots, the palette
  shot, the Workbench capture, and the menu bar strip were rendered from
  the live scan of the Mac that built them, which put its project folders,
  paths, and user name on the page. Every image now comes from the same
  fabricated ports as the demo GIF (`PORTNANNY_SNAPSHOT_DATA=demo`), a
  refresh in that mode is a no-op, and a test keeps the fixtures free of
  anything from the rendering machine. The old images were also removed
  from the repository's history.

### Distribution
- The cask uses the stanzas current Homebrew asks for (`postflight_steps`
  and `depends_on macos: :ventura`), so `brew upgrade` no longer prints
  deprecation warnings. docs/FIRST-RUN.md notes the one-time
  `brew trust mukes555/tap` that Homebrew may ask for after the rename.

## 2.1.0 (2026-09-07)

PortKilla is now PortNanny. The old name said "killer" for an app that
spends most of its time keeping servers alive and attributed, and it sat
one letter from a much larger project. Nothing written for the old name
stops working.

### Changed
- **Renamed to PortNanny.** New app name and bundle id
  (`com.mukes555.PortNanny`), `portnanny` command, `PORTNANNY_OWNER` and
  `PORTNANNY_SESSION`, `portnanny://` links, repository
  (github.com/mukes555/PortNanny; the old URL redirects), Homebrew cask
  `portnanny`, and Claude Code plugin `portnanny@portnanny`.
- **The maid quokka.** New artwork for the icon, the menu bar, the header,
  the tour, and the banner: a quokka with a cap, a mug, and a laptop.
- The README and the app's update banner say `brew upgrade` rather than
  `brew reinstall`, since the cask has been pinned per release since 2.0.

### Added
- **The old name keeps working**, for at least a year: the `portkilla`
  command (Homebrew links it next to `portnanny`), `PORTKILLA_OWNER` and
  `PORTKILLA_SESSION` (read wherever the new names are; `exec` exports
  both), and `portkilla://kill/3000`.
- **Preferences move over.** The first launch copies settings, watched
  ports, guards, history, refusals, and leases from the PortKilla domain
  into the new one, once, and never over a value the new app has already
  written. The CLI does the same for the domain it shares with the app.

### Distribution
- `brew upgrade --cask portnanny` follows the rename (the tap carries
  `cask_renames.json`): PortKilla.app goes, PortNanny.app comes, and macOS
  asks again for notifications and Launch at login because it keys both to
  the bundle id. Every step is in docs/FIRST-RUN.md.

## 2.0.0 (2026-09-07)

The quokka release: a new look, a Workbench window, port leases, a setup
wizard for AI tools, and a guard that knows whose server it is. Everything
since 1.16, reviewed twice.

### Added
- **Settings > Agents.** The AI tools this Mac has and how each is
  recognised, the guard's one switch ("Refuse agents a server nobody
  claims", followed by the CLI and the MCP server too), a project setup
  with a click per step (what `portkilla setup` does: rule files, the MCP
  registration for Claude Code), and leases: the default length
  `portkilla reserve` uses and a Release button for each active lease.
- **Notifications per event.** A watched port freeing up, something taking
  one, a guard acting, and an agent being refused each have a switch under
  the master.
- **What the list shows.** Settings > Display can hide UDP sockets and
  ephemeral ports (49152 and up).
- **Updates.** The daily check is a switch, and "Include beta releases"
  offers prereleases, which rank below the release they precede.
- **`portkilla setup`** walks through setting up the AI tools on this Mac:
  checks `portkilla` on PATH, and for each tool found offers to register
  the MCP server with Claude Code (`claude mcp add`), write its rule file
  into the project, and shows the rest (Cursor's mcp.json, Codex's
  config.toml, shell completions). Asks before every change; `--yes`
  applies all; without a terminal it prints the plan.
- **Rule files for every tool.** `portkilla agent-docs --cursor` writes
  `.cursor/rules/portkilla.mdc` (with frontmatter), `--windsurf` writes
  `.windsurf/rules/portkilla.md`, `--codex` writes AGENTS.md, `--claude`
  CLAUDE.md; folders are created, existing files keep their content.
- **A Claude Code plugin** in `plugins/portkilla`: the MCP server, the lsof
  hook, a `portkilla` skill, and `/portkilla:ports` and `/portkilla:free`
  commands. Install with `claude plugin marketplace add mukes555/PortKilla`
  then `claude plugin install portkilla@portkilla`.
- **Leases on free ports.** `portkilla reserve <port> [--for 10m]
  [--reason ...]` takes a lease that `free-port` and `exec` skip for
  everyone else and that makes `kill` refuse other agents on the port
  (people are warned) until it expires (a day at most) or `portkilla
  release <port>` gives it back. `portkilla reservations` lists them; the
  Workbench watchlist shows them with a Release button, and a listener on
  a leased port wears a "reserved" chip. MCP: `reserve_port`,
  `release_port`, and a `free_port` tool.
- **Drift.** PortKilla reads the port a project meant to use (PORT in
  `.env` files, `--port`/`PORT=` in package.json scripts, `port:` in
  vite.config) and marks a web server that ended up elsewhere with an
  "expected :3000" chip; the inspector and `whois` say who holds the port
  it wanted. `portkilla drift` lists every such server.
- **`portkilla exec`.** `portkilla exec --free-port --prefer 3000 -- npm
  run dev` picks a free port nobody has leased, exports `PORT`, leases the
  port for the run, exports `PORTKILLA_OWNER` and `PORTKILLA_SESSION`
  (yours unless given) so the server is attributed even when the tool
  leaves no marker, forwards signals, and exits with the command's status.
  `--port N` insists on one port and explains who has it when it is busy.
- **The Workbench.** A full-size window (overflow menu, or type `> workbench`)
  with a sidebar of views: a sortable table of every port; ports grouped by
  project with Reveal, Open in editor, and Kill all; ports grouped by agent
  session (live, ended, editor terminals, unclaimed) with Stop all and a
  one-click clean-up of ended sessions; the watchlist with guard and watch
  toggles and a field to add a port; and History. An inspector on the right
  shows the selected port's overview, the evidence behind its owner (the
  ancestry walked, the markers found), and its history, with Kill, Force,
  Tree, Open, Watch, and Guard at hand.
- **A command palette in the search field.** Type `kill 3000`, `open 5173`,
  `watch 8080`, `guard 8080`, or `free port` and Return does it; the strip
  under the field says what will happen, including who owns the target and
  whether a supervisor is involved. `>` lists app commands (Refresh, Bulk
  Kill, Pin, Workbench, History, Find a Free Port, Settings, Quit).
- Rows slide in and fade out as ports come and go.
- **Sparklines.** The Workbench keeps the last sixty scans of CPU and
  memory per process: a trend column in the table, and CPU and memory
  charts in the inspector.
- **Who is connected.** The inspector's Connections tab lists the remote
  end of every established connection, marked local, from the local
  network, or from elsewhere; `portkilla whois` prints the same.
- **Peek at a web server.** A Peek button in the inspector sends one GET to
  the local server and shows its status, content type, and page title. A
  Settings toggle (off by default) does it automatically for web ports.
- **A welcome tour** on first launch: what the app shows, how agents are
  kept from killing each other, and how to set the agents up (with the
  commands to copy). Later from the menu or `> tour`.
- **The quokka.** A new app icon, and the mascot in the welcome tour (waving
  on the first page, on guard on the second) and in the empty state (asleep
  on the tablet). `scripts/make_artwork.swift` turns the artwork into the
  icon and the cut-outs.
- **Supervisors understood.** PortKilla recognises what would undo a plain
  kill: pm2 apps, launchd jobs (Homebrew services and your own
  LaunchAgents), Docker containers, and reloaders (nodemon, `next dev`,
  `uvicorn --reload`, `--watch` modes, Flask's and Django's reloaders,
  gunicorn, puma, and nginx masters). Rows show an orange chip and the
  detail view says why. `portkilla kill` stops a reloader together with its
  child and runs `pm2 stop`, `brew services stop`, `launchctl bootout`, or
  `docker stop` for the rest; when the tool is not on PATH it prints the
  command and exits 6. `--force` kills the listener itself, except for
  Docker, where it means `docker kill`. The app asks "Stop via pm2" or
  "Kill anyway". Docker's backend is never killed through a port.
- **Refusals reach you.** When the guard refuses an agent, the running app
  shows a notification with "Stop it anyway" and "Show in PortKilla", the
  History window lists the refusal in orange with who was refused, and
  `portkilla history` includes it.
- `portkilla whois` shows the supervisor and its stop command; `list --json`
  carries `managedBy`.
- **`portkilla whois <port>`** (or `--pid`): everything PortKilla knows about
  a listener, including the evidence behind its owner (the ancestry walked,
  the markers found, what was declared) and what `kill` would do for the
  caller and why. Also an MCP tool, `whois_port`.
- **`portkilla kill --orphaned`** stops every server left behind by an
  agent session that has ended, for any agent; exit 0 when there is
  nothing to clean up.
- **`portkilla doctor --agents`** prints the agent compatibility matrix
  checked against this machine: which tools run or are installed, how each
  is recognised, how precisely its sessions are told apart, and where each
  fact came from. The same matrix is in docs/AGENTS.md, kept in step by a
  test.
- **`PORTKILLA_SESSION`**: tools that export no session id (Codex, Gemini,
  custom bots) can export any unique string next to `PORTKILLA_OWNER`, and
  their servers stay tied to that session after reparenting.
- A refusal now says when the server runs in the caller's working
  directory: a hint that it may be the caller's own unclaimed server, or
  the user's.
- `portkilla schema whois` and `schema agents` document the new outputs.
- **Connected clients.** Each listener shows how many established
  connections it has (a chip in the row, a Clients line in the detail
  view, `connections` in `list --json`), and killing a server with live
  clients always confirms first.
- **`portkilla free-port [--prefer N] [--range A-B] [--json]`** prints the
  first port that is neither listening nor bound (a real bind probe),
  starting from the preferred one. Exit 1 when the range is full.
- **`portkilla schema <command>`** documents every field of that command's
  `--json` output, so scripts and agents do not have to guess.
- **Agents no longer kill what nobody claims.** An identified agent that
  asks to stop a server PortKilla cannot attribute is refused (exit 3,
  `guardVerdict: "refused"`, reason "not attributed"); it should start its
  own servers with `PORTKILLA_OWNER` set or ask the person. People at a
  plain terminal and the GUI are unaffected; `--force` still overrides.
  Commands from an editor terminal count as a person's, except against
  another agent's running server, where they need `--force`.
- Scenario tests spawn real servers (`portkilla __serve <port>`, debug
  builds only) and drive the guard through the CLI as a separate process:
  attribution by declaration and by environment after reparenting,
  refusals, overrides, real kills, `free-port`, `whoami`.
- `portkilla mcp` announces itself on stderr when run from a terminal
  (it used to wait in silence), and `portkilla mcp --setup [claude|cursor|
  codex]` prints the registration for each agent. There is no background
  mode by design: each agent starts its own copy over stdin/stdout when it
  needs one and stops it afterwards.

### Changed
- **The quokka is the brand.** The menu bar shows the quokka traced in
  black and white from the artwork (lighter while nothing is listening)
  or, from Settings > Display, the app icon in colour; the bolt is gone.
  The popover header carries the artwork's head with a live summary line,
  About shows the app icon, and the Workbench sidebar and empty inspector
  wear it too.
- **A bigger popover.** Regular is now 580 by 720 points; Settings >
  Display offers Compact (the old 500 by 600) and Large (660 by 840). The
  pinned window follows.
- **Richer rows.** Type tiles, section headers with counts and accents,
  port and process names a size up, memory with CPU and its trend in
  Advanced, and the browser and watch verbs on hover so the list stays
  calm. Guard buttons use a shield.
- Debug snapshot renders keep their density and watch list in the
  throwaway suite instead of the developer's own preferences.
- **The core is a library.** `PortKillaCore` (models, scanners, guard, CLI,
  MCP; Foundation only) sits under three targets: the menu-bar app, the new
  standalone `portkilla` executable, and the tests. The CLI no longer
  links AppKit, so it starts faster and uses less memory; the app binary
  still answers the same subcommands.
- A declared `PORTKILLA_OWNER` now wins over process ancestry for both the
  caller and the target, so a bot started from inside another agent's
  session keeps its own name.
- `portkilla kill --dry-run` mentions connected clients, and `agent-docs`
  explains the new refusal and points at `free-port`.
- Row text uses relative text styles (`body`, `subheadline`, `caption`)
  instead of fixed point sizes, and the column widths are `ScaledMetric`,
  so the list follows whatever text scaling the system applies rather than
  clipping. macOS applies little of it to SwiftUI text today; the snapshot
  hook's `PORTKILLA_SNAPSHOT_TEXTSIZE=large` exists for when it does.
- Rows no longer observe the whole `PortManager`: the section hands each
  row plain values (density, protected, watched, terminating), so a
  publish re-evaluates only the rows whose inputs changed.
- The demo-GIF hook renders against a throwaway preference suite instead
  of the real one.

### Fixed
- **The watchlist no longer disarms guards by looking at them.** Rendering
  the Workbench's watchlist counted as a guard strike, so a guard stood
  down on its next intrusion after a few seconds on screen.
- **Bulk kills leave supervised servers alone.** Kill All and the bulk
  sheet used to send a plain kill to pm2, launchd, and reloader servers,
  which came straight back; they are skipped with a note, and each row's
  own stop verb applies.
- **Every kill dialog carries the owner, client, and lease warnings**,
  including the supervised ones, which showed none.
- **A reloader kill names what goes with it.** Stopping nodemon (or another
  reloader) takes every server under it; those are now judged by the
  guard, listed in the dry run, and recorded in History.
- **Leases survive two agents at once.** The lease store takes an advisory
  lock around every read-modify-write, so two `exec --free-port` calls at
  the same instant cannot both win a port.
- **Client counts refresh the row.** A change in connected clients
  republishes the row and its warnings.
- Smaller: `--help` after `--` belongs to the command `exec` runs;
  `history` shows kills by default and refusals with `--all`, so its first
  entry always names the killer; the docs installer refuses garbled
  markers; the MCP kill tool flags every outcome that leaves the port
  busy; the inspector's peek reports a redirect without following it and
  stops at 64 KB; debug snapshot renders keep their density and watch
  list out of real preferences.

### Security
- **A name alone claims nothing.** A declared `PORTKILLA_OWNER` without a
  session could stop another agent's server, or release its lease, by
  matching the name. A known session now has to be shown, with
  `PORTKILLA_SESSION` or by running from the agent's own shell.
- **Refusal notifications are believed only when the CLI recorded them.**
  Any local process could post one, and its "Stop it anyway" killed the
  port with no confirmation. Labels are cleaned and the kill goes through
  the usual confirmation.
- **Leases are held by a session, not a name.**
- **pm2 app names are validated** before they become arguments; `pm2 stop
  all` was reachable from a process name.
- Command lines are redacted before they are shown, exported, written to
  History, or handed to an agent: `--token=...`, `--api-key ...`,
  `DATABASE_PASSWORD=...`, passwords inside URLs, and bearer tokens become
  `[redacted]`. Classification and project detection still see the original.

### Distribution
- `scripts/build.sh` bundles the standalone CLI as
  `PortKilla.app/Contents/Helpers/portkilla`, and the cask's `binary` stanza
  links that instead of the app binary. CI builds before testing so the
  scenario tests find the debug `portkilla`.
- The release workflow can pin the Homebrew cask to each release with its
  SHA-256 (`packaging/homebrew/portkilla.rb.tmpl`, `livecheck`,
  `brew upgrade` support). It runs only when a `HOMEBREW_TAP_TOKEN` secret
  exists; see RELEASING.md.
- README leads with a current screenshot and shows the Workbench; the demo
  GIF is regenerated.
## 1.16.0 — 2026-09-06

### The agent tools batch

### Added
- **`portkilla mcp`**: a Model Context Protocol server over stdin/stdout,
  no dependencies. Tools: `list_ports`, `kill_port` (dry-run by default,
  refusals come back as tool errors the model reads), `whoami`,
  `wait_for_port_free`. The agent spawns and reaps it, so nothing is
  resident or registered: the guard becomes a tool instead of a habit.
  Register with `{"mcpServers":{"portkilla":{"command":"portkilla","args":["mcp"]}}}`
  (Claude Code, Cursor) or `[mcp_servers.portkilla]` in Codex's config.
- **`portkilla agent-docs --write [--file CLAUDE.md]`** appends the agent
  snippet between markers, once, and updates it in place on later runs.
  Opt-in only; no other command writes into your repository.
- **`portkilla agent-docs --claude-hook`** prints a Claude Code PreToolUse
  hook that turns `kill -9 $(lsof -ti:PORT)` into a nudge toward
  `portkilla free`, at the point of the habit.

## 1.15.0 — 2026-09-06

### The distribution batch

### Added
- `portkilla doctor` (and Settings → About → **Copy debug info**): version,
  macOS, architecture, install source, quarantine state, scanner path and
  timing, PATH resolution, login item status. Paste it into bug reports.
- `portkilla <command> --help` and `portkilla help <command>`;
  `portkilla completions zsh|bash|fish`; `version --json`.
- Structured logging into the unified log (`log stream --predicate
  'subsystem == "com.mukes555.PortKilla"'`) for the scan path, kills, guard
  events, and update checks. Process names are marked private.
- VoiceOver reads each port row as one labelled element ("Port 3000, node,
  45 MB, owned by Claude Code, exposed on all interfaces") and announces
  the keyboard selection.
- `docs/FIRST-RUN.md`: the one page for Gatekeeper on macOS 13/14 versus
  15+, Homebrew, login-item re-approval, and uninstall. README badges and
  an FAQ.

### Changed
- **Updates know where you installed from.** A Homebrew install is offered
  the `brew reinstall` command instead of a DMG that would overwrite the
  cask's bundle. A GitHub rate limit is explained as such. Development
  builds no longer show a dead Check for Updates button. Pre-release tags
  are never offered as updates.
- Settings shows when macOS is waiting for you to re-approve the login item
  (common after an update) with a button to Login Items.
- `list` and `history` omit their header when piped; a JSON encoding
  failure exits 70 instead of 0 with no output.

### Distribution
- The release workflow refuses to run unless the tag, `build.sh`, and the
  newest CHANGELOG section agree; CI checks the same on every PR.
- The release verifies the binary is universal and signed and that
  Info.plist carries the tag's version, publishes `SHA256SUMS`, and marks
  `-rc`/`-beta`/`-alpha` tags as pre-releases.
- CI caches the SwiftPM build and runs the suite once through Rosetta, so
  the x86_64 slice has executed at least once (advisory).
- The Homebrew cask quits the running app and drops its login item before
  replacing the bundle, and `zap` removes saved state, caches, and HTTP
  storage as well as preferences.
- `CFBundleVersion` follows the release version (it was always 1); the
  bundle declares the Developer Tools category.

## 1.14.0 — 2026-09-06

### The guard batch

Closes the holes a fresh audit found in the friendly-fire guard.

### Changed
- **Session identity uses `CLAUDE_CODE_SESSION_ID`** where Claude Code
  provides it: a UUID is never recycled the way a pid is and survives a
  restart in place. Pids remain the fallback.
- A session pid reused by a *different* agent is no longer trusted.
- **Markerless sessions expire.** Owners detected from a marker with no
  session (Cursor, Gemini, Codex, older Claude Code) used to block other
  agents forever. If no process of that agent is running at all, the
  session is reported as ended.
- **tmux, screen, zellij, and ssh are attribution barriers.** Markers seen
  through a multiplexer belong to whoever started it, not the pane, so the
  name is kept and the session dropped; the tree walk stops there.
- `list --mine` means exactly what `kill` would allow without `--force`,
  and says so on stderr (exit 1) when the caller isn't identified.
- The `kill` report gains `guardVerdict` ("refused", "allowed",
  "overridden", "not-evaluated: caller unknown", "not-evaluated: target
  unknown"), and an unidentified caller killing an agent's live server is
  told on stderr that the guard could not apply.
- Refusals suggest the next step (ask the user, or use a free port).

### Added
- **`portkilla free <port>`**: kill for scripts; exit 0 when the port was
  already free, so `portkilla free 3000 && npm run dev` works under `set -e`.
- **`portkilla wait <port> [--timeout 30]`** blocks until the port is free.
- **`portkilla open <port>`** opens localhost in the browser.
- **`portkilla history [--port N] [--json]`**: the CLI now records its kills
  in the same store as the app, so the History window shows agent kills and
  an agent can find out who stopped its server.
- `agent-docs` covers `--dry-run`, `--pid`, stderr, same-tool sessions,
  `free`, `wait`, `history`, and `PORTKILLA_OWNER` for tools without markers.

## 1.13.1 — 2026-09-06

### Fixed
- **Running the test suite changed the developer's real preferences** (it
  once switched off "Hide system processes" and rewrote the watched ports).
  `PortManager` now takes an injected `UserDefaults` and `HistoryManager`,
  and every test uses a throwaway suite.
- Opening the popover while a hidden-state scan was running could show rows
  without chips, containers, or trees for one cycle. The full scan the
  popover asked for now runs instead of being dropped.
- The port guard looked up agent ownership by port number, so a port shared
  by a TCP listener and a UDP binder could be judged by the wrong process.
- An editor-terminal ancestor used to hide a stronger `CLAUDECODE` marker in
  the server's own environment, silently losing protection.
- The per-process facts cache survived `exec` without `fork` (`sh -c 'exec
  node …'`), so a row could keep showing `sh`. The kernel's short name is
  now part of the cache key, and an empty marker read is retried.
- Subprocess output: the pipe could be closed under a read in flight, and
  truncated `lsof` output was parsed as complete. Reads and the close now
  share one lock, and end-of-file is required.
- The CLI reported an unreaped zombie as "still running" after the full
  wait; `--force` erased the refusal reasons from the JSON report (now kept
  as `overriddenRefusals`); ports outside 1 to 65535 and `port` plus `--pid`
  together are usage errors.
- Pinned window shortcuts stopped working whenever no window was key.
- The Guard switch in Settings ran a modal dialog inside SwiftUI's update.
- Hardening: `PORTKILLA_OWNER` control characters are stripped, chip label
  colours are computed once per tint, the socket size re-probe keeps what it
  already read, a Docker restart is picked up immediately, the working
  directory lock is no longer held across the `lsof` subprocess, and
  concurrent scans no longer zero each other's CPU deltas.

### Security
- SECURITY.md now states the threat model: the friendly-fire guard is a
  cooperation protocol between well-behaved agents, not a security boundary.

## 1.13.0 — 2026-09-06

### The engineering batch

No user-visible feature changes; this release is for the people who read the
code. The one behaviour change: the CSV export gains Owner and Killed By
columns, and Reset All Settings also brings the tips banner back.

### Changed
- `PortManager` (762 lines) is split into its core, `PortManager+WatchGuard`
  (watchlist and guards) and `PortManager+Refresh` (scheduling and the scan
  pipeline); the row view's context menu and child row are their own files.
- One `KnownEditors` list drives both "IDE & Tools" classification and the
  default protected list, with a test that they agree. They had drifted.
- Every UserDefaults key lives in `DefaultsKey`; the `portkilla://` scheme is
  parsed by `URLCommand`; key codes are named (`KeyCode.escape`) instead of
  numbered.
- Port classification is a table of rules in priority order instead of a
  ten-branch if-ladder.
- The scanner's working-directory cache is lock-guarded, so link-initiated
  kills reuse the shared scanner instead of allocating a cold one.
- `HistoryManager` is observable (the History window updates while open) and
  takes an injectable `UserDefaults`, so tests never touch real history.
- Removed dead code: two unused view bindings, an unreachable history state,
  `killAllPorts(ofType:)`, and comments that restated their signatures.
- Docs: ARCHITECTURE lists the real CLI commands; README no longer says "TCP
  only", describes Kill All Dev's true scope, and points Check for Updates at
  Settings → About.

### Tests
- The exit wait (killed, surviving, already dead, deadline), the guard's
  four refusal rules, URL scheme parsing, editor/protected agreement,
  classification order, history cap and persistence, the CSV document, and
  several pure helpers. 139 tests.

## 1.12.0 — 2026-09-06

### The UI batch

### Added
- **States the app had no words for:** a "Scanning ports…" state before the
  first scan (it used to claim "No active ports" with a green check before
  any data existed), a "compatibility scan" note in the footer when the slow
  lsof path is in use, a "Notifications are blocked" row in Settings with a
  button to System Settings, rows that dim with a spinner while a process
  shuts down, and a "Refreshing…" toast when you press refresh mid-scan.
- **Guards are reachable:** "Guard :port" in every row's context menu, and a
  Watched ports section in Settings with guard switches and unwatch buttons.
  Previously the only guard toggle lived in a section that disappeared on
  any search or filter.
- Shortcuts pane documents Option-click, Shift-click, right-click, and ⌘C,
  and can bring the tips banner back.
- Settings: notification sound toggle and history retention (50 to 500).

### Changed
- **Watched rows** now use the same columns, padding, chips, and context
  menu as the rest of the list instead of a second, narrower layout.
- **Pinned window:** keyboard shortcuts work in it (each copy of the list
  answers only while its own window is key), it is resizable, and it
  remembers its position and display.
- **⌘K and the footer button honour the active filter:** "Kill All
  Databases" on the Databases tab, "Kill All Docker" on Docker. The All tab
  keeps the classic "Kill All Dev".
- Killing the selected row keeps the keyboard position on its neighbour
  instead of jumping to the top.
- One confirmation dialog style everywhere, with a properly destructive Kill
  button (five different idioms before).
- Chips share one component, use system colours that adapt to the
  appearance, and darken their label in light mode where the old ones
  failed contrast.
- The density toggle respects Reduce Motion.

### Removed (internal)
- Two unreachable sheet cases and the protected list's never-shown
  standalone mode.

## 1.11.0 — 2026-09-06

### The performance batch

Same features, a fraction of the work. Measured on a machine with ~600
processes and ~60 listeners, a refresh went from roughly 5,100 syscalls and
30,000 short-lived strings to about 1,400 syscalls and a few hundred strings.

### Changed
- **One native pass.** The process table and the listening sockets are
  gathered in a single walk over the pid list (two before), with a reusable
  descriptor buffer instead of a size probe per process.
- **Facts that can't change aren't re-read.** Executable path, argv, and the
  environment markers are cached per (pid, start time), so a refresh only
  pays for processes it hasn't seen. A recycled pid gets a fresh entry.
- **No render storm.** An unread published flag and an always-changing
  timestamp forced three whole-tree re-renders per refresh even when nothing
  changed. The flag is plain, the timestamp lives on its own object that
  only the footer observes, the visible-port filter is cached instead of
  recomputed thousands of times a minute, and the Tests list republishes on
  structural change (or every 10s for the CPU column).
- **Docker off the hot path.** `docker ps` runs on a background queue, only
  when a Docker process is listening, and backs off (5s to 60s) when the
  daemon is down, instead of blocking every refresh for up to three seconds.
- **Hidden means light.** With nothing on screen a refresh gathers the six
  fields the badge and watchlist need; working directories, Docker names,
  children, and agent attribution wait for the popover. Closing the popover
  no longer triggers a scan nobody sees.
- **Quiet launch.** No notification-permission prompt just for launching
  (it is asked when you turn notifications on or arm a watch), no
  preferences written back to disk on read, and the update check is
  deferred ten seconds.
- The menu-bar icon is drawn from two cached images and only when its state
  changes; `lsof` is no longer asked for working directories of other
  users' processes (it can't read them either).
- `portkilla whoami` walks its own ancestor chain instead of snapshotting
  every process; `kill` skips the Docker lookup it doesn't print.

## 1.10.0 — 2026-09-06

### The agent batch

### Changed
- **One kill decision for every path.** The friendly-fire guard used to live
  only in the CLI. Now the GUI warns before you kill a port owned by another
  agent's running session (even with confirmations off), bulk dialogs say how
  many targets belong to running agents, link-initiated kills show the owner
  before asking, and port guards never auto-kill one.
- **Agent versus editor terminal.** `TERM_PROGRAM=vscode` fires for every VS
  Code fork and for humans typing in an editor terminal, and Windsurf or Trae
  collapsed into "VS Code". Editor signals now mean "started inside the
  editor" and are never a reason to refuse; the fork is resolved from the
  editor's own environment; `CURSOR_AGENT`, `GEMINI_CLI`, and Codex's sandbox
  markers identify real agents.
- **Session ended** is a first-class state: a grey "(ended)" chip, no longer
  blocking anyone, and `list --orphaned` to find abandoned servers. Ports
  fronted by Docker never get an agent owner.
- The tree walk starts at the parent, so an editor's own helper resolves to
  the editor instead of a "session" of one; the caller's identity gets the
  same session-liveness check as targets.
- `PORTKILLA_OWNER` is canonicalised (`claude-code` is "Claude Code") and,
  when exported before starting servers, labels them.
- Kill history records who started the process and who stopped it (you, the
  port guard, or a link).

### Added
- `portkilla kill --dry-run`, `--json`, `--pid <pid>`; `kill` stops every
  process on the port; documented exit codes (0 done, 1 nothing listening,
  2 usage, 3 refused, 4 failed, 5 still running); errors on stderr.
- `portkilla list --mine`, `--agent <name>`, `--unowned`, `--orphaned`;
  `whoami --json`; `portkilla agent-docs` prints a CLAUDE.md / AGENTS.md
  snippet.
- Strict argument parsing: an unknown flag is an error. (`kill 3000
  --dry-run` on 1.9 killed for real because the flag was ignored.) A mistyped
  subcommand no longer launches the GUI.
- The GUI search matches agent names; the detail sheet shows session and
  source; the chip tooltip explains how PortKilla knows.

## 1.9.0 — 2026-09-06

### The safety batch

Every item here came out of a full audit; none removes a feature.

### Fixed
- **Subprocess timeouts leaked** a file descriptor and a blocked thread each
  time `lsof` or `docker` hung; after enough of them, refreshes and kills
  silently stopped. Pipe output is now collected without a blocking read.
- **Crash on launch** from a corrupt hotkey preference, and a CPU-pegging or
  throwing timer from an out-of-range refresh interval. Every stored
  preference is validated (hotkey, interval, watched and guarded ports).
- `portkilla://show` during a cold launch could dereference the popover
  before it existed. Scheme-initiated kills are now one confirmation per
  delivery with a short cooldown, so a page can't stack dialogs.
- **Tree kill** re-enumerated the whole process table at every node with no
  cycle guard. It now walks one snapshot with a visited set and depth limit.
- **Port guards** killed and notified every scan, forever, when a supervised
  process (pm2, nodemon, launchd KeepAlive) kept rebinding. After three kills
  in a minute the guard stands down with a single notification.
- **Update check** reported "up to date" on any HTTP error or when offline,
  then suppressed retries for a day. Failures are now reported as failures
  and retried on the next launch; the URL cache is bypassed.
- **Kill verdicts were too hasty:** a one-second wait marked healthy Node or
  Postgres shutdowns as failures. SIGTERM now gets three seconds, SIGKILL
  one, and the message says "still shutting down" instead of "failed".
- A machine with zero listeners fell through to the slow `lsof` path on every
  refresh. An empty native result is now a real answer.
- Context-menu **Kill Process Tree** and **Force Kill**, and Test Radar
  kills, bypassed the confirm-before-kill setting. All kills now share one
  confirmation flow.
- An undecodable bind address made the "exposed" badge disappear; it now
  fails closed and shows the port as wildcard-bound.
- **Reset all settings** promised to reset the hotkey and didn't.
- The exit-wait had a narrow race where a late kernel event could change a
  result after it was decided.

### Security
- The agent-attribution environment read now enforces its allowlist at the
  byte level: no process environment is ever decoded into strings beyond the
  five marker keys, and the buffer is zeroed after use.
- CSV export escapes every column and treats tab and carriage return as
  formula lead-ins. `docker stop` passes `--` before the container name.

## 1.8.3 — 2026-09-06

### Fixed
- A restarted agent could not kill its own older dev server without `--force`:
  the server's `CLAUDE_PID` marker pointed at the previous session. When that
  session process no longer exists, the owner keeps the agent name but no
  longer pins a session, so the same tool is allowed through.

## 1.8.2 — 2026-09-06

### Fixed
- `portkilla version` still printed `dev` when invoked by bare name through
  PATH (argv[0] carries no path). The CLI now asks the kernel for its real
  executable path before locating the app bundle.

## 1.8.1 — 2026-09-06

### Fixed
- `portkilla version` printed `dev` when run through a symlink (as installed
  by Homebrew); it now resolves the link to the app bundle.

### Distribution
- The Homebrew cask links `portkilla` onto your PATH, so the CLI (`list`,
  `kill`, `whoami`) works right after `brew install --cask portkilla`.

## 1.8.0 — 2026-09-06

### Changed
- **Agent attribution now survives detached servers.** Besides the process
  tree, PortKilla reads the environment markers agents leave on their
  children (`CLAUDECODE`, `CURSOR_TRACE_ID`, `TERM_PROGRAM=vscode`,
  `GEMINI_CLI`). A server backgrounded by an agent's shell, or started via
  nohup/pm2, is reparented to launchd and lost the tree link in 1.7.0; it is
  now attributed correctly. Only that allowlist of keys is ever read.
- Session identity is recovered from `CLAUDE_PID`, which matches the pid the
  tree walk finds, so the two signals agree.

### Added
- `portkilla whoami` prints how the friendly-fire guard identifies the caller
  (name, session, and whether it was detected or declared).
- Codex CLI, Gemini CLI, Copilot CLI, and OpenCode are recognised.
- The `kill` refusal now names both sides and points at `whoami`.


## 1.7.0 — 2026-09-06

### Added
- **Agent attribution & friendly-fire protection** — so AI coding agents don't
  kill each other's dev servers. PortKilla attributes each listening process to
  the agent that spawned it (Claude Code, Cursor, VS Code, Windsurf, Zed, Trae,
  Aider) by walking the process ancestry — no launcher or opt-in required.
  - A ✨ agent chip on rows and an **Agent** field in the detail sheet.
  - `portkilla list` shows an **AGENT** column.
  - **`portkilla kill` refuses** to stop a port owned by a different agent
    session unless `--force` (exit code 3). Set `PORTKILLA_OWNER` to declare the
    caller's identity, or it's detected from the process tree.
  - GUI kill confirmations note the owning agent.
  - Best-effort: a detached server (double-fork / nohup / pm2) loses the
    ancestry link and reports no owner rather than guessing.

## 1.6.0 — 2026-08-08

### Hardening, UI polish, and contributor-readiness

**Distribution**
- The release is now a **universal binary** (arm64 + x86_64) — runs natively on
  both Apple Silicon and Intel Macs. Minimum macOS 13 (Ventura).

**UI**
- **Simple / Advanced row density** with a modern segmented header toggle. Simple
  shows one clean line per port; Advanced adds command, chips, CPU, and the tree.
- **Settings redesigned** as a native macOS System Settings-style **sidebar**
  window (⚙︎ / ⌘,), replacing the overloaded gear menu. New: Notifications
  master toggle, menu-bar count toggle, in-app shortcut reference, Reset all.
- Header split into three clear controls: density toggle · **⋯ actions** ·
  **⚙︎ settings**.
- **Pin as Floating Window** now closes the popover instead of showing two copies.

**Security & correctness** (from a multi-agent audit)
- URL-scheme kills require confirmation and refuse protected processes.
- Fixed a data race in `waitForExit`; tree-kill children run the identity check;
  bounded reads on fixed kernel arrays; CPU% no longer wraps on PID reuse; guard
  fires on occupant swaps; docker-proxy classified as Docker; CSV quotes `\r`.

**Engineering & docs**
- Dev-only snapshot/demo hooks gated behind `#if DEBUG` (out of the shipped app).
- Deduplicated: one `KillConfirm` dialog, one `isWildcardHost` check.
- Fixed the test-runner self-exclusion string; removed unreachable `TestType` cases.
- Added **CONTRIBUTING.md**, **ARCHITECTURE.md**, **SECURITY.md**, issue/PR
  templates; fixed the README build path.
- 60 tests (+ regression coverage), universal build verified.

## 1.5.0 — 2026-08-07

### The native scanner release

- **Raw-syscall scanning (libproc)**: process + socket enumeration now uses
  kernel interfaces directly — a full scan (≈480 processes, ≈60 listeners) takes
  ~19ms with **zero subprocesses** (previously two lsof runs + ps per refresh).
  lsof/ps remain only as an automatic fallback. CPU% is now a true
  between-scans delta, and process names are no longer truncated at 9 chars.
- **Pin as Floating Window** (gear menu): keep the port list on top while you
  work; refresh stays at full cadence while pinned.
- **Port guards** (bolt-shield in the Watched section): opt-in per port —
  anything unprotected of yours that grabs a guarded port is auto-killed, with
  a notification. Explicit confirmation required to enable.
- **Raycast extension scaffold** under `extensions/raycast/` (experimental),
  built on the CLI's `list --json` / `kill`.
- CLI `list` now shows a PROTO column.
- Internals: kill verification is event-driven (DispatchSourceProcess), the
  two largest files were split per-responsibility, CI actions bumped and a UI
  render smoke test added to every CI run.

## 1.4.0 — 2026-08-07

The "big batch" release.

### Added
- **Watched section**: starred ports pinned to the top of the list with live status — including "free ✓", the answer you usually came for.
- **Kill & notify**: when a kill doesn't finish (slow shutdown, trapped SIGTERM), PortKilla notifies you the moment the port actually frees.
- **UDP ports**: bound UDP sockets now appear with a purple UDP tag (ephemeral/outgoing sockets are filtered out).
- **Process age & CPU%**: shown in row tooltips and the detail sheet; Test Radar rows show live CPU to expose runaway watchers.
- **Open Project in Editor**: detects VS Code, Cursor, Zed, Sublime Text, and Trae; opens the process's real working directory.
- **Free-port answer**: searching a port number that's free shows ":8080 is free ✓ — Watch it" instead of a dead-end empty state; if it's occupied but hidden by a filter, it says so.
- **Configurable global hotkey**: gear menu → Change Hotkey (default ⌥⌘P).
- Keyboard navigation (↑↓ ⏎) now also works on the Tests filter.
- Accessibility labels on all icon-only buttons.

## 1.3.0 — 2026-08-07

- Port watchlist with "freed"/"taken" notifications.
- Real project detection from process working directories, with Reveal in Finder / Open in Terminal.
- CLI mode: `portkilla list [--json]`, `portkilla kill <port> [--force]`.
- URL scheme: `portkilla://kill/3000`, `portkilla://show`.
- Update check against GitHub Releases (gear menu).
- First-run popover + hotkey tip; generated app icon; History gained "Kill again".
- Homebrew cask template under `packaging/homebrew/`.

## 1.2.0 — 2026-08-07

- Keyboard-first flow: ⌥⌘P global hotkey, search-focused popover, ↑↓ selection, ⏎ kill, ⌘⏎ force, ⌘O open in browser.
- Filter chips (All/Dev/Databases/Docker/Tests) replace tabs; settings moved to a gear menu.
- Hide System Processes filter (default on) and dev-only menu-bar count.
- "Exposed" badge for ports bound to all interfaces (0.0.0.0/::).
- Safety: PID-identity re-check before kills, `pid > 0` guard, no silent SIGTERM→SIGKILL escalation.
- Performance: one `ps` snapshot per refresh instead of 3 subprocesses per port; hard timeouts on all subprocess calls; background refresh slows to 30s while the popover is closed.
- Fixes: Docker on Apple Silicon Homebrew paths, IPv6 container port parsing, CSV injection escaping, locale-formatted port numbers, false "Refresh failed" with zero ports.

## 1.1.0

- Process tree with Smart Kill (kill tree), Docker container names, Test Radar (beta).

## 1.0.x

- Initial releases: port list, one-click kill, history + CSV export, protected processes, bulk kill.
