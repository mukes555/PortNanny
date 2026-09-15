# End-to-end checks

`swift test` builds its own fixtures, which is why it did not catch
`portnanny kill` being unable to stop a Docker container: those tests
construct a `ManagedRuntime` directly and never run the scan that feeds one.
These scripts drive the built binary against real listeners instead.

They are manual. They need a machine with real processes on it, and one of
them needs Docker, so CI does not run them. Run them after a change to
scanning, attribution, the guard, the supervisors, or the MCP server.

```bash
cd PortNanny
swift build
PN=$PWD/.build/debug/portnanny zsh Tests/e2e/guard.sh
PN=$PWD/.build/debug/portnanny zsh Tests/e2e/kills.sh
PN=$PWD/.build/debug/portnanny python3 Tests/e2e/mcp.py
```

`PN` can be any build: `.build/debug/portnanny`, the one inside
`dist/PortNanny.app/Contents/Helpers/`, or the installed `portnanny`.

## Safety

These scripts start real servers and kill real processes, so they follow two
rules, both learned by breaking them:

- **Only ever signal a pid recorded at spawn time.** Never a pattern. A
  `pkill -f "http.server 450"` once matched a person's own `http.server 4500`
  and took down work that could not be restored.
- **Never start a test server on a port that is not already free.** A leaked
  server from an earlier run makes the next spawn fail silently while the
  port still looks busy, and every assertion after that is measuring the
  wrong process.

Everything binds `127.0.0.1` on ports 45001-45019. Nothing runs a bulk kill.

## What each one covers

**`guard.sh`** is the friendly-fire guard against real listeners: attribution
from the environment a server was started with, another agent refused while
the server survives, dry runs deciding without signalling, the owning session
allowed, `--force` overriding, a second session of the same agent refused,
and the `--mine` and `--agent` filters.

**`mcp.py`** speaks JSON-RPC to `portnanny mcp` the way an agent does:
the handshake, all eight tools advertised, `kill_port` defaulting to a dry
run and refusing another agent's server, leases made over MCP showing up in
the CLI, and malformed input getting an error without taking the server down.

**`kills.sh`** is what `kill` and `free` report after signalling something
real: a port taken again the instant it frees (a supervisor with no restart
delay), a port held by a user this scan cannot see, `exec` taking and giving
back a lease, and a command `exec` cannot find.

**`detach.py`** is the piece that makes two cases testable at all. Anything
started from a shell inside an agent session inherits that session's process
tree, so it is never truly unowned and the caller is never truly a person.
This double-forks and calls `setsid`, so the child reparents to launchd with
no agent above it:

```bash
# a server nobody claims
python3 Tests/e2e/detach.py /tmp/pid.txt python3 -m http.server 45011 --bind 127.0.0.1

# a caller the guard sees as a person, with its exit code in the file
python3 Tests/e2e/detach.py /tmp/out.txt --wait portnanny kill 45011
```

## Not covered here

Docker and the other supervisors still need doing by hand, because they need
software the scripts cannot assume. The Docker one that found the bug was:

```bash
docker run -d --name portnanny-e2e -p 127.0.0.1:45016:80 nginx:alpine
portnanny whois 45016      # should name the container and its stop command
portnanny kill 45016       # should run that command, not refuse
docker rm -f portnanny-e2e
```

The guard's own auto-kill, the watch notifications, and every window are
also untested here; they need the menu bar app and a person looking at it.
