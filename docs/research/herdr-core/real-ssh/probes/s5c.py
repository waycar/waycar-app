"""5c: how long does a ghost viewer persist when the network vanishes / the client freezes?
 C1  sshd :22 (stock: ClientAliveInterval 0), client ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4, link frozen by cutproxy (no FIN/RST)
 C2  sshd :2222 (ClientAliveInterval 15, ClientAliveCountMax 4), plain client (no ServerAlive), link frozen by cutproxy
 C3  sshd :2222 (ClientAlive 15x4), client SIGSTOPped (kernel still ACKs; ssh process silent)
 C4  sshd :22 stock, client SIGSTOPped (= 5a, for comparison)
Observation window OBS seconds after the cut/stop. Prints when each client dies and when the core drops the viewer (size leaves the ghost's)."""
import sys, time, subprocess, signal, os
sys.path.insert(0, ".")
from ptyssh import *
OBS = int(sys.argv[1]) if len(sys.argv) > 1 else 150
def hc(*a): return subprocess.run([HC] + list(a), capture_output=True, text=True)
W = os.path.expanduser("~/work/s4"); os.makedirs(W, exist_ok=True)
proxies = [subprocess.Popen(["python3", "cutproxy.py", "2223", "22"], stdout=subprocess.PIPE, text=True),
           subprocess.Popen(["python3", "cutproxy.py", "2224", "2222"], stdout=subprocess.PIPE, text=True)]
time.sleep(0.5)
opts = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=/tmp/kh5c"]
def ssh(port, extra=()):
    return ["ssh", "-tt", "-p", str(port)] + opts + list(extra) + ["127.0.0.1"]
cases = {
  "C1": dict(port=2223, extra=["-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"], how="cut", proxy=0, size=(80, 24)),
  "C2": dict(port=2224, extra=[], how="cut", proxy=1, size=(81, 25)),
  "C3": dict(port=2222, extra=[], how="stop", size=(82, 26)),
  "C4": dict(port=22, extra=[], how="stop", size=(83, 27)),
}
S = {}
for k, c in cases.items():
    name = "g" + k.lower()
    hc("kill", name); time.sleep(.2); hc("rm", name)
    hc("run", "--bg", "--no-parent", "--name", name, "--cwd", W, "--", "sh", "-c", "while :; do sleep 1; done")
    cmd = ssh(c["port"], c["extra"])
    S[k] = PtySSH(cmd + [attach_line(name)], *c["size"])
time.sleep(1.5)
for k, c in cases.items():
    print("%s attached: size=%s (want %s)" % (k, get("g" + k.lower()), c["size"]), flush=True)
T0 = time.monotonic()
for k, c in cases.items():
    if c["how"] == "cut": os.kill(proxies[c["proxy"]].pid, signal.SIGUSR1)
    else: os.kill(S[k].p.pid, signal.SIGSTOP)
print("cut/stop at t=0", flush=True)
client_dead, core_freed = {}, {}
while time.monotonic() - T0 < OBS:
    t = time.monotonic() - T0
    for k, c in cases.items():
        if k not in client_dead and S[k].p.poll() is not None:
            client_dead[k] = t; print("t=%6.1f %s: ssh client exited rc=%s tail=%s" % (t, k, S[k].p.returncode, esc(S[k].data()[-120:], 200)), flush=True)
        if k not in core_freed and get("g" + k.lower()) == (200, 120):
            core_freed[k] = t; print("t=%6.1f %s: core dropped the viewer (200x120)" % (t, k), flush=True)
    time.sleep(0.5)
print("--- after %ds: client_dead=%s core_freed=%s" % (OBS, {k: round(v, 1) for k, v in client_dead.items()}, {k: round(v, 1) for k, v in core_freed.items()}))
for k, c in cases.items():
    print("%s final core size %s (ghost wanted %s)" % (k, get("g" + k.lower()), c["size"]))
# cleanup
for k in S:
    try: S[k].kill(signal.SIGCONT)
    except Exception: pass
    try: S[k].kill(signal.SIGKILL)
    except Exception: pass
for p in proxies: p.kill()
for k in cases: hc("kill", "g" + k.lower())
