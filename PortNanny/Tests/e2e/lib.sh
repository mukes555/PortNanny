# Shared harness for the PortNanny end-to-end suites.
#
# Safety rules, learned the hard way:
#   - only ever signal PIDs recorded here at spawn time, never a pattern
#   - refuse to start a server on a port that is not already free
#   - every listener binds 127.0.0.1 in 45001-45019
setopt NO_HUP NO_CHECK_JOBS
PN="${PN:?set PN to the portnanny binary under test}"

# These suites provoke refusals on purpose, and a refusal the CLI records is
# broadcast to the running app, which turns it into a banner with a sound.
# Run against the person's real preference domain, they get one alert per
# refusal, for every run: a day of testing arrived as a pile of notifications
# at the next unlock. So each run gets its own throwaway domain, and a build
# that ignores the override (a release build, where it is debug-only) stops
# here rather than writing into the real store.
E2E_SUITE="${PORTNANNY_DEFAULTS_SUITE:-PortNannyE2E.$$}"
export PORTNANNY_DEFAULTS_SUITE="$E2E_SUITE"
E2E_DOMAIN="$("$PN" version --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("defaultsDomain",""))' 2>/dev/null)"
if [ "$E2E_DOMAIN" != "$E2E_SUITE" ] && [ "${PORTNANNY_E2E_ALLOW_REAL_STORE:-0}" != "1" ]; then
  print -r -- "This build writes to ${E2E_DOMAIN:-the real preference domain}, not the throwaway one these suites asked for."
  print -r -- "Leases, history and refusal banners would land on the person using this Mac."
  print -r -- "Run them against .build/debug/portnanny, or set PORTNANNY_E2E_ALLOW_REAL_STORE=1 to accept that."
  exit 2
fi

# Where the scripts park command output they need to grep.
S_OUT="${S_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/portnanny-e2e.XXXXXX")}"
PASS=0; FAIL=0
STARTED=()
LAST_PID=""

ok()  { PASS=$((PASS+1)); print -r -- "  ok    $1" }
bad() { FAIL=$((FAIL+1)); print -r -- "  FAIL  $1" }
check() { if [ "$2" = "$3" ]; then ok "$1 (exit $3)"; else bad "$1 (expected exit $2, got $3)"; fi }
alive() { kill -0 "$1" 2>/dev/null }

cleanup() {
  local pid
  for pid in $STARTED; do kill -9 "$pid" 2>/dev/null; done
  STARTED=()
  # The throwaway domain goes with the run that made it.
  if [ "$E2E_DOMAIN" = "$E2E_SUITE" ]; then
    defaults delete "$E2E_SUITE" 2>/dev/null
    rm -f "$HOME/Library/Preferences/$E2E_SUITE.plist"
  fi
}
trap cleanup EXIT INT TERM

portBusy() { "$PN" list --json 2>/dev/null | grep -q "\"port\" : $1," }

# serve <port> [env assignments...]; sets LAST_PID, returns non-zero on failure.
# Runs in the calling shell: a command substitution would take the server down
# with its subshell.
serve() {
  local port=$1; shift
  if portBusy "$port"; then
    bad "port $port was already in use, refusing to start a test server on it"
    return 1
  fi
  if [ "$#" -gt 0 ]; then
    env "$@" python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
  else
    python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
  fi
  LAST_PID=$!
  STARTED+=($LAST_PID)
  local i
  for i in {1..40}; do
    if ! alive $LAST_PID; then bad "the server for $port exited immediately"; return 1; fi
    portBusy "$port" && return 0
    sleep 0.25
  done
  bad "port $port never appeared in list"
  return 1
}

# Runs the CLI as a named agent session.
asAgent() {
  local owner=$1 session=$2; shift 2
  env PORTNANNY_OWNER="$owner" PORTNANNY_SESSION="$session" "$PN" "$@"
}

summary() {
  print -r -- ""
  print -r -- "== $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
