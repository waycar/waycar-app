#!/usr/bin/env python3
"""ptyssh.py - drive `ssh -tt ... 'herdr-core attach T'` on a real local PTY (stdlib only), like the app's attach does.
Lab helper: import it from scenario scripts. Everything is timestamped relative to spawn."""
import fcntl, json, os, pty, signal, struct, subprocess, termios, threading, time

HC = os.path.expanduser("~/.local/bin/herdr-core")
SSH = ["ssh", "-tt", "-o", "BatchMode=yes", "127.0.0.1"]
PATHLINE = "PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
DA1 = b"\x1b[?62;22c"


def attach_line(addr, extra=""):
    # design section 8 shape: /bin/sh -c '<PATH>; <marker>; exec "$p" attach "$1"' attach '<address>'
    return ("/bin/sh -c '%s; p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core; "
            "[ -x \"$p\" ] || { echo \"herdr-core is not installed here\" >&2; exit 127; }; "
            "printf \"@@WAYCAR-ATTACH@@\\n\"; exec \"$p\" attach %s \"$1\"' attach '%s'") % (PATHLINE, extra, addr)


def get(addr):
    """(cols, rows) of a terminal as the core sees it, via a local herdr-core call (not through ssh)."""
    out = subprocess.run([HC, "get", addr, "--json"], capture_output=True, text=True).stdout
    try:
        r = json.loads(out)
        return r["cols"], r["rows"]
    except Exception:
        return None


def esc(b, n=300):
    s = b.decode("utf-8", "backslashreplace").encode("unicode_escape").decode()
    return s if len(s) <= n else s[:n] + "...(+%d)" % (len(s) - n)


class PtySSH:
    def __init__(self, cmd, cols=80, rows=24, da1=True, term="xterm-256color", env_extra=None):
        self.t0 = time.monotonic()
        self.cmd, self.da1 = cmd, da1
        self.master, slave = pty.openpty()
        self.setsize(cols, rows)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        env = dict(os.environ, TERM=term)
        env.update(env_extra or {})
        self.p = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True,
                                  preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        os.close(slave)
        self.chunks = []          # (t, bytes)
        self.answered = False
        self.closed = False
        self.exit_t = None
        self.th = threading.Thread(target=self._read, daemon=True)
        self.th.start()

    def now(self):
        return time.monotonic() - self.t0

    def setsize(self, cols, rows):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def _read(self):
        import select
        while not self.closed:
            try:
                if not select.select([self.master], [], [], 0.02)[0]:
                    continue
                b = os.read(self.master, 65536)
            except (OSError, ValueError):
                break
            if not b:
                break
            self.chunks.append((self.now(), b))
            if self.da1 and b"\x1b[c" in b and not self.answered:
                self.answered = True
                try:
                    os.write(self.master, DA1)
                except OSError:
                    pass

    def write(self, b):
        os.write(self.master, b)

    def data(self):
        return b"".join(c for _, c in self.chunks)

    def first(self, needle):
        """time of the first chunk containing needle (None if never)"""
        acc = b""
        for t, c in self.chunks:
            acc += c
            if needle in acc:
                return t
        return None

    def wait_exit(self, timeout):
        try:
            rc = self.p.wait(timeout)
            self.exit_t = self.exit_t or self.now()
            return rc
        except subprocess.TimeoutExpired:
            return None

    def close_master(self):
        """what an app dropping the PTY does: master closed -> ssh sees EIO/SIGHUP"""
        self.closed = True          # reader polls with select, so it never pins the master open
        self.th.join()
        os.close(self.master)

    def kill(self, sig=signal.SIGKILL):
        os.kill(self.p.pid, sig)


def wait_size(addr, want, timeout=3.0, step=0.005):
    t = time.monotonic()
    while time.monotonic() - t < timeout:
        if get(addr) == want:
            return time.monotonic() - t
        time.sleep(step)
    return None
