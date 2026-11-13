"""6: `herdr-core server restart` (sent over its own ssh exec, as the app would) while a framed subscribed connection and an
attach PTY are open. What do the two ssh sessions see? Then: time to reconnect + re-snapshot."""
import sys, time, subprocess, signal, os, json
sys.path.insert(0, ".")
from ptyssh import *
def sh(c, **k): return subprocess.run(c, shell=True, capture_output=True, text=True, **k)
def hc(*a): return subprocess.run([HC] + list(a), capture_output=True, text=True)
W = os.path.expanduser("~/work/s4"); os.makedirs(W, exist_ok=True)
hc("kill", "tick"); time.sleep(.2); hc("rm", "tick")
hc("run", "--bg", "--no-parent", "--name", "tick", "--cwd", W, "--", "sh", "-c", "i=0; while :; do i=$((i+1)); echo tick $i; sleep 0.5; done")
before = json.loads(hc("server", "status").stdout)
print("core before: pid=%s uptime_ms=%s live=%s" % (before["pid"], before["uptime_ms"], before["live"]))
P_T0 = time.monotonic()
P = subprocess.Popen(["python3", "hc_attach_probe_ssh.py", "--ssh", "ssh -T -o BatchMode=yes 127.0.0.1", "--subscribe", "--do", "sleep:14", "--drain", "0.2", "--width", "200", "--capture", "/tmp/cap/s6sub"],
                     stdout=open("/tmp/out/s6-probe.log", "w"), stderr=subprocess.STDOUT)
A = PtySSH(SSH + [attach_line("tick")], 80, 24)
time.sleep(2.0)
print("attach bytes before restart:", sum(len(c) for _, c in A.chunks), "; viewers: core size", get("tick"))
T = time.monotonic()
r = subprocess.run(["ssh", "-T", "-o", "BatchMode=yes", "127.0.0.1", "~/.local/bin/herdr-core server restart"], capture_output=True, text=True)
t_restart = time.monotonic() - T
print("restart command issued at %.3fs after the subscriber process started (its log clock starts ~0.03 s later)" % (T - P_T0))
print("`ssh host 'herdr-core server restart'`: rc=%s in %.3fs stdout=%r stderr=%r" % (r.returncode, t_restart, r.stdout.strip(), r.stderr.strip()))
rc = A.wait_exit(10)
print("attach PTY ssh: rc=%s exited %.3fs after the restart command started; last bytes: %s" % (rc, (A.exit_t or 0) - (T - A.t0), esc(A.data()[-200:], 400)))
# reconnect: new ssh + hello + subscribe, time to the snapshot
t1 = time.monotonic()
Q = subprocess.run(["python3", "hc_attach_probe_ssh.py", "--ssh", "ssh -T -o BatchMode=yes 127.0.0.1", "--subscribe", "--do", "sleep:0.2", "--drain", "0.1", "--width", "120"], capture_output=True, text=True)
print("reconnect (new ssh + framed hello + events.subscribe + 0.3 s hold): total %.3fs" % (time.monotonic() - t1))
for l in Q.stdout.splitlines():
    if "PLAIN" in l or "ch=0 DATA" in l: print("   ", l[:170])
after = json.loads(hc("server", "status").stdout)
print("core after: pid=%s uptime_ms=%s live=%s (same core.id: %s)" % (after["pid"], after["uptime_ms"], after["live"], after["core"]["id"] == before["core"]["id"]))
# re-attach
B = PtySSH(SSH + [attach_line("tick")], 80, 24); time.sleep(1.0)
print("re-attach after restart: first paint @%s s, bytes=%d, core size=%s; text '#tick' seen: %s" % (B.first(b"\x1b[!p"), len(B.data()), get("tick"), b"tick" in B.data()))
B.close_master(); B.wait_exit(3)
P.wait(timeout=30)
print("--- subscriber probe log tail:")
print(sh("grep -E 'EOF|exit code|BAD|STDERR' /tmp/out/s6-probe.log").stdout)
print(sh("tail -n 4 /tmp/out/s6-probe.log | cut -c1-260").stdout)
hc("kill", "tick")
