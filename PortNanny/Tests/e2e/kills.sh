#!/bin/zsh
# What `kill` and `free` report, against real listeners.
#
# The unit tests build their targets; these bugs were all about what the CLI
# says after signalling something real: a port taken again by a supervisor
# within milliseconds, a process that had already exited, a port held by a
# user this scan cannot see.
#
# Safety: see Tests/e2e/README.md. Only pids recorded here are ever signalled.
set -u
cd "${0:A:h}"
source ./lib.sh

print -r -- "== 1. free reports a port that is taken again the instant it frees"
PORT=45013
if portBusy $PORT; then
  bad "port $PORT was already in use"
else
  if serve $PORT; then
    SERVER=$LAST_PID
    # A stand-in for a supervisor with no restart delay: it binds the moment
    # the server above lets go. `free` used to answer "Killed …", exit 0,
    # with the port already busy again.
    python3 -c "
import socket, time
sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
while True:
    try:
        sock.bind(('127.0.0.1', $PORT)); break
    except OSError:
        time.sleep(0.001)
sock.listen(1)
time.sleep(120)
" &
    GRABBER=$!
    STARTED+=($GRABBER)

    "$PN" free $PORT > "$S_OUT/free.txt" 2>&1
    check "free on a port taken again is not success" 5 $?
    if grep -q "in use again" "$S_OUT/free.txt"; then
      ok "and it says the port was taken again"
    else
      bad "it did not say the port was taken again: $(cat "$S_OUT/free.txt")"
    fi
    kill -9 $GRABBER 2>/dev/null
  fi
fi

print -r -- ""
print -r -- "== 2. free says so when a port is held by a process it cannot see"
# 88 is root's on a stock macOS install (httpd). Nothing is killed here: the
# scan cannot see it, and the point is that PortNanny admits that.
if "$PN" list --json | grep -q '"port" : 88,'; then
  print -r -- "  skip  :88 is visible to this user on this machine"
else
  "$PN" free 88 > "$S_OUT/eighty.txt" 2>&1
  check "free on a root-held port is a failure, not success" 4 $?
  if grep -q "cannot see" "$S_OUT/eighty.txt"; then
    ok "and it explains who to ask"
  else
    bad "no explanation: $(cat "$S_OUT/eighty.txt")"
  fi
fi

print -r -- ""
print -r -- "== 3. a free port is still free, and free still succeeds"
PORT=45014
if serve $PORT; then
  "$PN" free $PORT >/dev/null 2>&1
  check "free kills a plain server" 0 $?
  if portBusy $PORT; then bad "the server is still listening"; else ok "the port is free"; fi
fi
"$PN" free 45015 >/dev/null 2>&1
check "free on an already free port is success" 0 $?

print -r -- ""
print -r -- "== 4. exec picks a port, leases it, and gives it back"
PORT=45016
if portBusy $PORT; then
  bad "port $PORT was already in use"
else
  env PORTNANNY_OWNER="E2E" PORTNANNY_SESSION="kills" "$PN" exec --port $PORT -- \
    zsh -c 'test -n "$PORT" && echo "PORT=$PORT"' > "$S_OUT/exec.txt" 2>&1
  check "exec runs the command" 0 $?
  if grep -q "PORT=$PORT" "$S_OUT/exec.txt"; then ok "and exports the port"; else bad "no PORT in the environment"; fi
  if "$PN" reservations | grep -q ":$PORT"; then
    bad "the lease outlived the command"
  else
    ok "the lease is released when the command ends"
  fi
  env PORTNANNY_OWNER="E2E" "$PN" exec --range 45016-45019 -- zsh -c 'echo "PORT=$PORT"' > "$S_OUT/range.txt" 2>&1
  check "a range with no preferred port is accepted" 0 $?
fi

print -r -- ""
print -r -- "== 5. a command exec cannot find"
"$PN" exec --port 45017 -- definitely-not-a-command-45017 >/dev/null 2>&1
check "exec answers like a shell for a missing command" 127 $?

print -r -- ""
print -r -- "== $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
