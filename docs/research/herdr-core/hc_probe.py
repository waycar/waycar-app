#!/usr/bin/env python3
"""hc_probe.py - talk to herdr-core the way a mobile client would: JSON-RPC 2.0,
one JSON object per line, over the stdin/stdout of `hc connect` (no pty).

Stdlib only. Read this file top to bottom to see the exact wire exchanges:
every request is printed as `-> {json}` and every reply/notification line as
`<- {json}`, byte for byte (that is what a Swift client reads/writes).

USAGE
  hc_probe.py [options] call METHOD [PARAMS_JSON]      one request, print the reply
  hc_probe.py [options] script FILE.jsonl              send each line of FILE ({"method":..,"params":..}), print replies
  hc_probe.py [options] events [PARAMS_JSON]           events.subscribe, then print notifications for 20 s
  hc_probe.py [options] features                       hello + which methods this core lacks (and since which release)
  hc_probe.py [options] demo                           full lifecycle against a fake agent (see demo())

OPTIONS
  --hc PATH         binary to spawn (default: $HC_BIN, else `herdr-core`, else `hc` from PATH)
  --session NAME    passes `connect --session NAME` (else HC_SESSION env / "default")
  --ssh 'CMD'       run herdr-core's own remote line (REMOTE_LINE) behind CMD, e.g. --ssh 'ssh -T box'
  --env-clear       spawn with a minimal env (HOME, PATH=/usr/bin:/bin) like a bare ssh exec channel
  --capture FILE    also append every exchange to FILE as JSON lines {"dir":"->"|"<-","line":...}
  --timeout S       per-request reply timeout (default 20)
  -q                do not echo the wire

ISOLATION: set HOME / XDG_RUNTIME_DIR / XDG_STATE_HOME / XDG_CONFIG_HOME / HC_SESSION to a scratch
dir first, or you will talk to (and auto-start) your REAL core.
RUNNING (repo layout, no other files needed):
  HC_BIN=/path/to/herdr-core python3 docs/research/herdr-core/hc_probe.py features
  python3 docs/research/herdr-core/hc_probe.py --hc /path/to/herdr-core call hello
  Without --hc/HC_BIN it looks for `herdr-core`, then `hc`, on PATH. Fixtures it mirrors: fixtures/ beside this file.


WIRE FACTS this file relies on (all observed, see rpc-facts.md beside this file):
  * plain mode is strictly serial: one reply per request, in order; a slow call (terminal.wait, machine.exec,
    send wait=true) blocks every later request on that connection. Notifications (no "id") never get a reply.
  * after events.subscribe the connection only emits notifications and ignores everything you send.
  * stdout carries only JSON lines; errors of `hc connect` itself go to stderr as {"error":{..}} + exit code.
"""
import argparse
import base64
import json
import os
import queue
import shlex
import shutil
import subprocess
import sys
import threading
import time


# What herdr-core itself runs over ssh to reach a remote core (herdr-core/crates/herdr-core/src/machines.rs, fn pipe).
# Looks on PATH first, then ~/.local/bin (the install dir of distribution/install.sh, usually NOT on a non-login
# ssh PATH). Not installed -> exit 127 and "herdr-core is not installed here" on stderr.
REMOTE_LINE = ("sh -c 'p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core; "
               "[ -x \"$p\" ] || { echo \"herdr-core is not installed here\" >&2; exit 127; }; "
               "@SESSION@exec \"$p\" connect'")


class HcError(Exception):
    """A JSON-RPC error reply: .code, .kind (error.data.kind), .message, .hint."""

    def __init__(self, err):
        self.err = err
        self.code = err.get("code")
        self.kind = (err.get("data") or {}).get("kind")
        self.hint = (err.get("data") or {}).get("hint")
        self.message = err.get("message")
        super().__init__(f"{self.kind}: {self.message} (hint: {self.hint})")


class Hc:
    """One `hc connect` child process = one plain-mode JSON-RPC connection."""

    def __init__(self, hc=None, session=None, prefix=None, env=None, echo=True, capture=None, timeout=20.0):
        hc = hc or os.environ.get("HC_BIN") or shutil.which("herdr-core") or shutil.which("hc") or "herdr-core"
        if prefix:
            # Remote: run herdr-core's own line (machines.rs `pipe`) through ssh. `hc` is NOT used: another
            # program may own that name. Not installed => exit 127 + stderr "herdr-core is not installed here".
            cmd = prefix + [REMOTE_LINE.replace("@SESSION@", "HC_SESSION=%s " % shlex.quote(session) if session else "")]
        else:
            cmd = [hc, "connect"] + (["--session", session] if session else [])
        self.cmd, self.echo, self.timeout = cmd, echo, timeout
        self.capture = open(capture, "a") if capture else None
        self.next_id = 1
        self.started = time.monotonic()
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.lines = queue.Queue()  # every stdout line, in order
        self.notifications = []  # lines without "id" (events / heartbeat / missed)
        self.stderr_text = b""
        threading.Thread(target=self._pump_out, daemon=True).start()
        threading.Thread(target=self._pump_err, daemon=True).start()

    # -- plumbing ---------------------------------------------------------
    def _pump_out(self):
        for line in self.p.stdout:
            self.lines.put(line)
        self.lines.put(None)  # EOF

    def _pump_err(self):
        self.stderr_text = self.p.stderr.read()

    def _log(self, arrow, line):
        if self.echo:
            print(f"{arrow} {line}", flush=True)
        if self.capture:
            self.capture.write(json.dumps({"dir": arrow, "line": line}) + "\n")
            self.capture.flush()

    def send_raw(self, line):
        self._log("->", line)
        self.p.stdin.write(line.encode() + b"\n")
        self.p.stdin.flush()

    def read_line(self, timeout=None):
        """Next stdout line (str), None on EOF, raises queue.Empty on timeout."""
        raw = self.lines.get(timeout=timeout if timeout is not None else self.timeout)
        if raw is None:
            return None
        line = raw.decode().rstrip("\n")
        self._log("<-", line)
        return line

    # -- API ---------------------------------------------------------------
    def request(self, method, params=None, timeout=None, **kw):
        """Send one request and return the FULL reply object (result or error).
        Lines without an "id" that arrive meanwhile are kept in self.notifications."""
        rid = self.next_id
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        self.send_raw(json.dumps(msg, separators=(",", ":")))
        deadline = time.monotonic() + (timeout or self.timeout)
        while True:
            line = self.read_line(max(0.01, deadline - time.monotonic()))
            if line is None:
                raise EOFError("hc connect closed stdout; stderr=" + self.stderr_text.decode(errors="replace"))
            reply = json.loads(line)
            if reply.get("id") == rid:
                return reply
            self.notifications.append(reply)

    def call(self, method, params=None, **kw):
        """Like request() but returns .result and raises HcError on a JSON-RPC error."""
        reply = self.request(method, params, **kw)
        if "error" in reply:
            raise HcError(reply["error"])
        return reply["result"]

    def notification(self, timeout):
        """Next notification (event/heartbeat/missed) as dict, or None on timeout."""
        if self.notifications:
            return self.notifications.pop(0)
        try:
            line = self.read_line(timeout)
        except queue.Empty:
            return None
        return json.loads(line) if line else None

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        try:
            self.p.wait(5)
        except subprocess.TimeoutExpired:
            self.p.kill()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


# -- helpers a client needs ----------------------------------------------------

def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def unb64(s: str) -> bytes:
    return base64.b64decode(s)


def osc7501(**fields) -> str:
    """The shell `printf` a fake agent runs to report status (OSC 7501, ST-terminated).
    title= and msg= are base64 on the wire. Example: osc7501(state="blocked", kind="permission", msg="Apply?")."""
    out = []
    for k, v in fields.items():
        if k in ("title", "msg"):
            v = b64(v.encode())
        out.append(f"{k}={v}")
    return "printf '\\033]7501;%s\\033\\\\' " + shlex.quote(":".join(out))


def wait_until(hc, terminal, pred, timeout=10.0):
    """Poll terminal.get until pred(record) (a client should use events.subscribe instead)."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        t = hc.call("terminal.get", {"terminal": terminal})
        if pred(t):
            return t
        time.sleep(0.1)
    raise TimeoutError(f"{terminal}: condition not met; last={t}")


# -- scenarios -----------------------------------------------------------------

# Methods a Waycar-style client relies on, and the first hc release that has each (from running every release
# 0.1.0..0.1.13 and sending `hello`; see fixtures/rpc-version-matrix.json).
NEEDED = {
    "hello": "0.1.0", "terminal.run": "0.1.0", "terminal.list": "0.1.0", "terminal.get": "0.1.0",
    "terminal.send": "0.1.0", "terminal.keys": "0.1.0", "terminal.read": "0.1.0", "terminal.kill": "0.1.0",
    "terminal.rm": "0.1.0", "terminal.label": "0.1.0", "terminal.wait": "0.1.0", "terminal.interrupt": "0.1.0",
    "terminal.put": "0.1.0", "events.subscribe": "0.1.0", "rpc.discover": "0.1.0", "templates.list": "0.1.0",
    "machine.exec": "0.1.6", "terminal.keep": "0.1.8", "doc.get": "0.1.8", "doc.set": "0.1.8",
    "file.read": "0.1.10", "file.write": "0.1.10", "file.edit": "0.1.10",
}


def features(hc):
    """Feature-detect the way a client should: hello.methods / hello.features, never the version string."""
    h = hc.call("hello", {"generation": 1})  # generation is optional; a mismatch => error kind unsupported_generation
    have = set(h["methods"])
    print(f"# core {h['core']['name']} ({h['core']['id'][:8]}) hc {h['version']} generation {h['generation']} "
          f"features {h['features']}")
    for m, since in NEEDED.items():
        if m not in have:
            print(f"# MISSING {m} (added in hc {since})")
    return h


def demo(hc):
    """Everything a mobile client does on ONE request connection, against a throwaway fake agent (an sh script
    that prints OSC 7501; no paid agent). Events need a SECOND `hc connect` (see events()): after
    events.subscribe a plain connection carries notifications only and ignores further requests."""
    features(hc)
    for t in hc.call("terminal.list", {"labels": {"probe": "demo"}})["terminals"]:  # leftovers of a previous run
        hc.call("terminal.kill", {"terminal": t["address"]})

    agent = (
        "r(){ printf '\\033]7501;%s\\033\\\\' \"$1\"; }; "
        "r state=idle:app=probe; "
        "while IFS= read -r l; do "
        "  case \"$l\" in *block*) r state=blocked:kind=permission:app=probe:msg=$(printf 'Run rm -rf?' | base64); "
        "     read -r a; echo \"answer: $a\" ;; esac; "
        "  r state=working:app=probe:progress=50:title=$(printf 'Thinking' | base64); sleep 1; "
        "  r state=done:app=probe:msg=$(printf 'finished' | base64); echo \"got: $l\"; r state=idle:app=probe; "
        "done"
    )
    # No template, no login shell: `line` runs `sh -c LINE` with the core's env + `env` below.
    r = hc.call("terminal.run", {"line": agent, "name": "probe-agent", "cwd": "/tmp", "labels": {"probe": "demo"},
                                 "env": {"FOO": "bar"}})
    tid = r["address"]  # the record has NO "id" field; "address" ("t7", "t1b") is the id. Opaque string.
    print("# started", tid, "pid", r["pid"], "status", r["status"], "(null: the first report has not arrived yet)")
    wait_until(hc, tid, lambda t: t["status"] and t["status"]["state"] == "idle")

    print("# send  ->", hc.call("terminal.send", {"terminal": tid, "text": "first prompt"}))
    print("# wait  ->", hc.call("terminal.wait", {"terminal": tid, "timeout": 10}))  # blocks this connection
    print("# send block ->", hc.call("terminal.send", {"terminal": tid, "text": "please block"}))  # started:false
    print("# get   -> status", hc.call("terminal.get", {"terminal": tid})["status"])
    try:
        hc.call("terminal.send", {"terminal": tid, "text": "y"})
    except HcError as e:
        print("# send while blocked ->", e.kind, "-", e.message)
    print("# keys  ->", hc.call("terminal.keys", {"terminal": tid, "keys": ["y", "enter"]}))
    time.sleep(2.5)
    print("# read  ->", repr(hc.call("terminal.read", {"terminal": tid, "lines": 20})["text"]))
    print("# interrupt ->", hc.call("terminal.interrupt", {"terminal": tid, "timeout": 1}))
    print("# exec  ->", exec_text(hc, ["git", "--version"], cwd="/tmp"))
    print("# kill  ->", hc.call("terminal.kill", {"terminal": tid})["state"])
    time.sleep(0.3)
    print("# rm    ->", hc.call("terminal.rm", {"terminal": tid}))


def exec_text(hc, argv, cwd=None, timeout=None):
    """machine.exec helper: stdout/stderr come back base64. Returns (code, stdout, stderr)."""
    p = {"argv": argv}
    if cwd:
        p["cwd"] = cwd  # `~` is NOT expanded anywhere in the API
    if timeout:
        p["timeout"] = timeout  # (0, 600], default 60
    r = hc.call("machine.exec", p)
    return r["code"], unb64(r["stdout"]).decode(errors="replace"), unb64(r["stderr"]).decode(errors="replace")


def events(hc, params, seconds=20):
    """events.subscribe in plain mode: reply = snapshot, then ONLY notifications (events, heartbeat every 15 s,
    missed). This connection is dead for requests afterwards: open another `hc connect` for those."""
    hc.request("events.subscribe", params)
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        hc.notification(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hc")
    ap.add_argument("--session")
    ap.add_argument("--ssh", help="e.g. 'ssh -T box': run herdr-core's remote line through this prefix")
    ap.add_argument("--env-clear", action="store_true")
    ap.add_argument("--capture")
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("-q", action="store_true")
    ap.add_argument("cmd", choices=["call", "script", "events", "demo", "features"])
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()
    env = None
    if a.env_clear:
        env = {"HOME": os.environ.get("HOME", "/"), "PATH": "/usr/bin:/bin"}
        for k in ("XDG_RUNTIME_DIR", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "HC_SESSION"):
            if k in os.environ:
                env[k] = os.environ[k]
    hc = Hc(a.hc, a.session, shlex.split(a.ssh) if a.ssh else None, env, not a.q, a.capture, a.timeout)
    try:
        if a.cmd == "call":
            params = json.loads(a.args[1]) if len(a.args) > 1 else {}
            hc.request(a.args[0], params)
        elif a.cmd == "script":
            for line in open(a.args[0]):
                line = line.strip()
                if line and not line.startswith("#"):
                    obj = json.loads(line)
                    hc.request(obj["method"], obj.get("params"))
        elif a.cmd == "events":
            events(hc, json.loads(a.args[0]) if a.args else {})
        elif a.cmd == "features":
            features(hc)
        elif a.cmd == "demo":
            demo(hc)
    finally:
        hc.close()


if __name__ == "__main__":
    main()
