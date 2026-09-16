#!/bin/zsh
set -uo pipefail
source "${0:A:h}/lib.sh"

print -r -- "== binary $("$PN" version) at $PN"

print "\n== 1. attribution follows the environment the server was started with"
serve 45001 PORTNANNY_OWNER="Claude Code" PORTNANNY_SESSION=sess-alpha || exit 1
PID_A=$LAST_PID
WHOIS=$("$PN" whois 45001 --json 2>/dev/null)
print -r -- "$WHOIS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
t = (d.get('targets') or [{}])[0]
o = t.get('agentOwner') or {}
print('  owner', o.get('name'), '| session', o.get('sessionKey'), '| source', o.get('source'))
print('  caller', (d.get('caller') or {}).get('name'))
" 2>/dev/null || print "  (could not parse whois --json)"
print -r -- "$WHOIS" | grep -q 'Claude Code' && ok "whois names Claude Code" || bad "whois did not name Claude Code"
print -r -- "$WHOIS" | grep -q 'sess-alpha' && ok "whois carries the declared session" || bad "whois lost the session"

print "\n== 2. another agent is refused and the server survives"
asAgent Cursor sess-beta kill 45001 >$S_OUT/refuse.txt 2>&1
check "Cursor killing Claude Code's server is refused" 3 $?
grep -qi "owned by" $S_OUT/refuse.txt && ok "the refusal names the owner" || bad "no owner in the refusal"
grep -q -- "--force" $S_OUT/refuse.txt && ok "the refusal mentions --force" || bad "no --force hint"
alive $PID_A && ok "the server is still running" || bad "the server died despite the refusal"

print "\n== 3. dry runs decide without signalling"
asAgent Cursor sess-beta kill 45001 --dry-run >/dev/null 2>&1
check "dry run from another agent refuses" 3 $?
asAgent "Claude Code" sess-alpha kill 45001 --dry-run >/dev/null 2>&1
check "dry run from the owner is allowed" 0 $?
alive $PID_A && ok "no dry run signalled anything" || bad "a dry run killed it"

print "\n== 4. the owning session may stop its own server"
asAgent "Claude Code" sess-alpha kill 45001 >/dev/null 2>&1
check "the owner kills its own server" 0 $?
sleep 0.6
alive $PID_A && bad "still alive after its owner killed it" || ok "the server is gone"

print "\n== 5. --force overrides"
serve 45002 PORTNANNY_OWNER="Claude Code" PORTNANNY_SESSION=sess-alpha || exit 1
PID_B=$LAST_PID
asAgent Cursor sess-beta kill 45002 --force >/dev/null 2>&1
check "another agent with --force succeeds" 0 $?
sleep 0.6
alive $PID_B && bad "--force did not kill it" || ok "--force killed it"

print "\n== 6. same agent, different session"
serve 45003 PORTNANNY_OWNER="Claude Code" PORTNANNY_SESSION=sess-alpha || exit 1
PID_C=$LAST_PID
asAgent "Claude Code" sess-gamma kill 45003 >/dev/null 2>&1
check "a different session of the same agent is refused" 3 $?
alive $PID_C && ok "the server survived" || bad "the server died"
asAgent "Claude Code" sess-alpha kill 45003 >/dev/null 2>&1
check "its own session may stop it" 0 $?

print "\n== 7. a server nobody claims"
# env -i is not enough: attribution also walks the process tree, and anything
# started from this shell has an agent above it. detach.py reparents to
# launchd so there genuinely is none.
HERE="${0:A:h}"
if portBusy 45011; then bad "45011 was already busy"; else
  rm -f "$S_OUT/srv.txt"
  python3 "$HERE/detach.py" "$S_OUT/srv.txt" python3 -m http.server 45011 --bind 127.0.0.1
  for i in {1..40}; do [ -s "$S_OUT/srv.txt" ] && break; sleep 0.3; done
  PID_U=$(cat "$S_OUT/srv.txt" 2>/dev/null)
  STARTED+=($PID_U)
  for i in {1..40}; do portBusy 45011 && break; sleep 0.25; done
  "$PN" whois 45011 2>&1 | grep -q "no agent above it" \
    && ok "whois says no agent is above it" || bad "whois still sees an agent"
  asAgent Cursor sess-beta kill 45011 >$S_OUT/unclaimed.txt 2>&1
  check "an agent is refused an unclaimed server" 3 $?
  grep -qi "not attributed" $S_OUT/unclaimed.txt \
    && ok "the refusal explains it is unattributed" || bad "no explanation: $(head -1 $S_OUT/unclaimed.txt)"
  alive $PID_U && ok "the unclaimed server survived" || bad "it was killed anyway"

  print "\n== 8. the switch that governs that rule"
  # The run's own domain, never the real one: this suite used to flip the
  # switch in the preferences of whoever happened to be using the Mac.
  defaults write "$E2E_SUITE" PortNanny.guardRefusesUnclaimed -bool false
  asAgent Cursor sess-beta kill 45011 --dry-run >/dev/null 2>&1
  check "with the switch off the same agent is allowed" 0 $?
  defaults write "$E2E_SUITE" PortNanny.guardRefusesUnclaimed -bool true
  asAgent Cursor sess-beta kill 45011 --dry-run >/dev/null 2>&1
  check "with it back on the refusal returns" 3 $?

  print "\n== 9. a person is warned, not refused"
  rm -f "$S_OUT/person.txt"
  python3 "$HERE/detach.py" "$S_OUT/person.txt" --wait "$PN" kill 45011 --dry-run
  for i in {1..40}; do [ -s "$S_OUT/person.txt" ] && break; sleep 0.3; done
  head -1 "$S_OUT/person.txt" | grep -q "exit 0" \
    && ok "a caller with no agent above it is allowed" || bad "a person was refused: $(head -1 "$S_OUT/person.txt")"
  kill -9 $PID_U 2>/dev/null
fi

summary
