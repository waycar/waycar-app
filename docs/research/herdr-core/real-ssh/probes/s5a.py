"""5a: SIGSTOP the ssh client of an attached session for 60 s, then SIGKILL it. Core view sampled every 5 s."""
import sys, time, subprocess, signal, os, re
sys.path.insert(0, ".")
from ptyssh import *
def hc(*a): return subprocess.run([HC] + list(a), capture_output=True, text=True)
def sh(c): return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()
def conns(): return len(re.findall(r"/default\.sock \d+", sh("ss -xpn 2>/dev/null | grep herdr-core")))
def attach_procs(): return sh("pgrep -f '[h]erdr-core attach' | wc -l")
def tcp(): return sh("ss -tn state established '( sport = :22 )' | tail -n +2 | wc -l")
W = os.path.expanduser("~/work/s4"); os.makedirs(W, exist_ok=True)
hc("kill", "ghost"); time.sleep(.2); hc("rm", "ghost")
hc("run", "--bg", "--no-parent", "--name", "ghost", "--cwd", W, "--", "sh", "-c", "while :; do sleep 1; done")
A = PtySSH(SSH + [attach_line("ghost")], 80, 24); time.sleep(1.0)
print("t=0 attached A 80x24: size=%s core client conns=%s remote 'herdr-core attach' procs=%s sshd established=%s" % (get("ghost"), conns(), attach_procs(), tcp()))
T0 = time.monotonic(); os.kill(A.p.pid, signal.SIGSTOP); print("SIGSTOP ssh client pid %d" % A.p.pid, flush=True)
B = None
while time.monotonic() - T0 < 60:
    t = time.monotonic() - T0
    if B is None and t >= 30:
        B = PtySSH(SSH + [attach_line("ghost")], 60, 30); time.sleep(0.6); print("t=%2.0f B attaches 60x30 (newest viewer): size=%s" % (time.monotonic() - T0, get("ghost")), flush=True)
    if B is not None and not B.closed and t >= 40:
        B.close_master(); B.wait_exit(3); time.sleep(0.3); print("t=%2.0f B detaches: size=%s  <- ghost A (stopped) pins it" % (time.monotonic() - T0, get("ghost")), flush=True)
    print("t=%2.0f size=%s core client conns=%s attach procs=%s sshd established=%s" % (t, get("ghost"), conns(), attach_procs(), tcp()), flush=True)
    time.sleep(5)
t = time.monotonic(); A.kill(signal.SIGKILL); rc = A.wait_exit(5)
dt = wait_size("ghost", (200, 120), timeout=10)
print("SIGKILL ssh client: rc=%s; core size back to 200x120 after %s s; conns=%s attach procs=%s; size=%s" % (rc, None if dt is None else round(dt, 3), conns(), attach_procs(), get("ghost")))
hc("kill", "ghost")
