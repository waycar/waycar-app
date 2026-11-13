import sys, time, subprocess, signal
sys.path.insert(0, ".")
from ptyssh import *

def hdr(s): print("\n### " + s, flush=True)

hdr("baseline: ssh -tt host 'printf hi' (connect+auth+pty+exec+exit)")
for i in range(3):
    s = PtySSH(SSH + ["printf hi"]); rc = s.wait_exit(10)
    print("  run %d: first byte %.3fs exit at %.3fs rc=%s out=%r" % (i, s.chunks[0][0] if s.chunks else -1, s.exit_t, rc, s.data()))

for da1 in (True, False):
    hdr("attach t1 (alpha), 80x24 pty, DA1 reply from outer terminal: %s" % da1)
    for rep in range(3):
        s = PtySSH(SSH + [attach_line("alpha")], 80, 24, da1=da1)
        time.sleep(1.3)
        print("  rep %d: marker@%s first-paint(ESC[!p)@%s  total bytes=%d  core size=%s" % (rep, s.first(b"@@WAYCAR-ATTACH@@"), s.first(b"\x1b[!p"), len(s.data()), get("alpha")))
        if rep == 0 and da1:
            print("  first chunks:", [(round(t,3), esc(c, 200)) for t, c in s.chunks[:4]])
        s.close_master(); rc = s.wait_exit(5)
        print("         detach: rc=%s" % rc)
        time.sleep(0.3)

hdr("resize through the local pty (TIOCSWINSZ on master -> SIGWINCH -> ssh window-change -> hc RESIZE)")
s = PtySSH(SSH + [attach_line("alpha")], 80, 24)
time.sleep(1.0); print("  attached: core size", get("alpha"))
for (c, r) in [(100, 30), (52, 28), (120, 40), (80, 24)]:
    t = time.monotonic(); s.setsize(c, r)
    dt = wait_size("alpha", (c, r))
    print("  setsize %dx%d -> core saw it after %s s" % (c, r, None if dt is None else round(dt, 3)))
    time.sleep(0.3)
t = time.monotonic(); s.close_master(); rc = s.wait_exit(5); tex = time.monotonic() - t
dt = wait_size("alpha", (200, 120))
print("  close master: ssh exit rc=%s after %.3fs; core back at 200x120 after %.3fs (from close); size=%s" % (rc, tex, (time.monotonic() - t) if dt is not None else -1, get("alpha")))
