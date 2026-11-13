"""5b: SIGSTOP the ssh client of a framed events subscription for 60 s (events keep flowing: bravo loops), then SIGKILL."""
import sys, time, subprocess, signal, os, re
sys.path.insert(0, ".")
def sh(c): return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()
def conns(): return len(re.findall(r"/default\.sock \d+", sh("ss -xpn 2>/dev/null | grep herdr-core")))
def qs():  # Recv-Q/Send-Q of core-side client sockets
    return re.findall(r"ESTAB\s+(\d+)\s+(\d+)\s+\S*default\.sock", sh("ss -xpn 2>/dev/null | grep herdr-core"))
p = subprocess.Popen(["python3", "hc_attach_probe_ssh.py", "--ssh", "ssh -T -o BatchMode=yes 127.0.0.1", "--subscribe", "--do", "sleep:95", "--drain", "0.1", "--capture", "/tmp/cap/s5b"],
                     stdout=open("/tmp/out/s5b-probe.log", "w"), stderr=subprocess.STDOUT)
time.sleep(1.5)
ssh_pid = int(sh("pgrep -P %d -x ssh" % p.pid))
print("subscribed; ssh client pid %d; core client conns=%s" % (ssh_pid, conns()))
T0 = time.monotonic(); os.kill(ssh_pid, signal.SIGSTOP); print("SIGSTOP ssh")
for i in range(13):
    print("t=%2.0f core client conns=%s queues(Recv,Send)=%s remote 'herdr-core connect' procs=%s" % (time.monotonic() - T0, conns(), qs(), sh("pgrep -f '[h]erdr-core connect' | wc -l")), flush=True)
    time.sleep(5)
t = time.monotonic(); os.kill(ssh_pid, signal.SIGKILL)
for i in range(100):
    if conns() == 0 or True:
        c = conns()
        if c == 0: break
    time.sleep(0.01)
print("SIGKILL ssh: core client conns=%s after %.3fs; remote connect procs=%s" % (conns(), time.monotonic() - t, sh("pgrep -f '[h]erdr-core connect' | wc -l")))
time.sleep(1); p.terminate()
