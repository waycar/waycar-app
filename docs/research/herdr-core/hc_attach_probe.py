#!/usr/bin/env python3
"""hc_attach_probe.py - decode herdr-core's framed attach/event wire, stdlib only.

What it does (exactly what an SSH *exec* channel with NO pty gives you):
  1. spawn `hc connect --session NAME`  (stdin/stdout are plain pipes)
  2. plain mode: write one JSON line  hello {framed:true}, read one JSON line reply
  3. from the next byte on the connection is FRAMED:
         [channel u32 LE][kind u8][len u32 LE][payload]       (9-byte header)
     channel 0 = JSON-RPC (kind DATA), channels >=1 = attach / event streams
  4. terminal.attach on channel 0 -> result.channel = N ; then decode every frame.

Which binary: pass `--hc /path/to/herdr-core` or set the env var HC_BIN (default: `hc` on PATH).
Which core: `--session NAME` (or env HC_SESSION); XDG_RUNTIME_DIR / HOME decide where the socket is.
NOTE: `hc connect` AUTO-STARTS a core for that session when none listens.

Frame kinds: 0 DATA  1 CREDIT(u32 LE)  2 CLOSE  3 RESIZE(u16 LE cols,u16 LE rows)
             4 FOCUS(1/0)  5 FACTS(JSON Display)

Usage examples (all steps after --attach/--subscribe are `--do` actions, run in order):
  hc_attach_probe.py --hc hc --session s1 --attach t1 --cols 52 --rows 28 \
        --do sleep:1 --do 'type:echo hi\\r' --do sleep:1 --do close --do sleep:0.3
  hc_attach_probe.py --session s1 --subscribe --do sleep:20
  hc_attach_probe.py --session s1 --attach t1 --no-credit --do sleep:3

Actions (--do NAME[:ARG]):
  sleep:SECS                 wait (frames keep being decoded/printed meanwhile)
  call:METHOD[:JSON]         JSON-RPC call on channel 0 (params default {})
  attach:TERMINAL[:JSON]     terminal.attach (extra params merged); becomes the "current" channel
  subscribe[:JSON]           events.subscribe; its channel carries JSON lines
  type:TEXT                  DATA on current attach channel; TEXT uses python escapes (\\r \\x1b \\x03)
  hex:HEXBYTES               DATA with raw bytes given as hex
  resize:COLSxROWS           RESIZE frame on current channel
  focus:0|1                  FOCUS frame
  facts:JSON                 FACTS frame (Display: fg,bg,cursor as #rrggbb, cell [w,h])
  credit:N                   CREDIT frame (bytes)
  close                      CLOSE frame (viewer detach) on current channel
  use:N                      make channel N the current one
  eof                        close our stdin (what a dropped SSH session looks like to hc connect)

Options: --no-credit (never auto-send CREDIT), --capture PREFIX (writes PREFIX.bin = byte-exact
core->client stream after the hello reply, PREFIX.json = decoded frames), --width N (preview bytes).
"""
import argparse, base64, codecs, json, os, struct, subprocess, sys, threading, time, queue

DATA, CREDIT, CLOSE, RESIZE, FOCUS, FACTS = range(6)
KIND = {0: "DATA", 1: "CREDIT", 2: "CLOSE", 3: "RESIZE", 4: "FOCUS", 5: "FACTS"}
HDR = struct.Struct("<IBI")  # channel u32 LE, kind u8, len u32 LE  (9 bytes, no padding with '<')
MAX_PAYLOAD = 16 << 20


def encode(channel, kind, payload=b""):
    return HDR.pack(channel, kind, len(payload)) + payload


def esc(b, width):
    s = b.decode("utf-8", "backslashreplace")
    s = s.encode("unicode_escape").decode("ascii")
    return s if len(s) <= width else s[:width] + "...(+%d chars)" % (len(s) - width)


class Probe:
    def __init__(self, a):
        self.a = a
        self.t0 = time.time()
        self.q = queue.Queue()
        self.log = []           # decoded frames (for --capture .json)
        self.raw = bytearray()  # exact core->client bytes after hello reply (for --capture .bin)
        self.sent = bytearray()  # exact client->core bytes incl. the plain hello line (--capture .out.bin)
        self.next_id = 1
        self.replies = {}
        self.channels = {}      # channel -> role ("attach"/"events")
        self.cur = None
        self.rx_bytes = {}      # per-channel DATA bytes received
        self.ev_buf = {}        # events channel -> partial line
        self.methods = {}       # request id -> method name
        cmd = [a.hc, "connect"] + (["--session", a.session] if a.session else [])
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        threading.Thread(target=self._stderr, daemon=True).start()

    def now(self):
        return time.time() - self.t0

    def say(self, *x):
        print("[%7.3f]" % self.now(), *x, flush=True)

    def wr(self, b):
        """The only place bytes go to `hc connect`'s stdin (an SSH exec channel's stdin, in the app)."""
        self.sent += b
        self.p.stdin.write(b)
        self.p.stdin.flush()

    def _stderr(self):
        for line in self.p.stderr:
            self.say("STDERR", line.decode(errors="replace").rstrip())

    # ---- plain mode -------------------------------------------------------------------
    def hello(self):
        req = {"jsonrpc": "2.0", "id": 0, "method": "hello", "params": {"framed": True}}
        self.wr((json.dumps(req) + "\n").encode())
        line = self.p.stdout.readline()          # the LAST plain-mode line; frames follow it
        self.say("PLAIN <-", line.decode().rstrip()[:300])
        self.hello_reply = json.loads(line)
        threading.Thread(target=self._reader, daemon=True).start()

    # ---- framed mode ------------------------------------------------------------------
    def _read_exact(self, n):
        buf = b""
        while len(buf) < n:
            c = self.p.stdout.read1(n - len(buf)) if hasattr(self.p.stdout, "read1") else self.p.stdout.read(n - len(buf))
            if not c:
                return None
            buf += c
        return buf

    def _reader(self):
        while True:
            h = self._read_exact(HDR.size)
            if h is None:
                self.q.put(("eof",))
                return
            ch, kind, ln = HDR.unpack(h)
            if ln > MAX_PAYLOAD:
                self.q.put(("bad", h))
                return
            payload = self._read_exact(ln) if ln else b""
            if payload is None:
                self.q.put(("eof",))
                return
            self.raw += h + payload
            self.q.put(("frame", self.now(), ch, kind, payload))

    def send(self, ch, kind, payload=b""):
        self.wr(encode(ch, kind, payload))
        self.say("-> ch=%d %s len=%d %s" % (ch, KIND[kind], len(payload), esc(payload, self.a.width)))
        self.log.append({"t": round(self.now(), 3), "dir": "out", "ch": ch, "kind": KIND[kind], "len": len(payload),
                         "payload_b64": base64.b64encode(payload).decode()})

    def handle(self, item):
        if item[0] == "eof":
            self.say("EOF on hc stdout (connection closed)")
            self.log.append({"t": round(self.now(), 3), "dir": "in", "eof": True})
            return False
        if item[0] == "bad":
            self.say("BAD HEADER", item[1].hex())
            return False
        _, t, ch, kind, payload = item
        rec = {"t": round(t, 3), "dir": "in", "ch": ch, "kind": KIND.get(kind, kind), "len": len(payload),
               "payload_b64": base64.b64encode(payload).decode()}
        role = self.channels.get(ch)
        if ch == 0 and kind == DATA:
            msg = json.loads(payload)
            rec["json"] = msg
            self.say("<- ch=0 DATA", json.dumps(msg)[: self.a.width * 3])
            if "id" in msg and msg.get("id") is not None:
                self.replies[msg["id"]] = msg
                # Tag the new channel the moment the reply is decoded: the first paint / events follow it
                # on the wire immediately (the reply on ch 0 always comes first).
                role = {"terminal.attach": "attach", "events.subscribe": "events"}.get(self.methods.get(msg["id"]))
                chn = (msg.get("result") or {}).get("channel")
                if role and chn:
                    self.channels[chn] = role
        elif kind == DATA and role == "events":
            # Event stream = JSON lines; a line may be split across DATA frames (16 KiB chunks),
            # so buffer per channel and split on "\n". Events need CREDIT like any stream.
            buf = self.ev_buf.get(ch, b"") + payload
            *whole, rest = buf.split(b"\n")
            self.ev_buf[ch] = rest
            rec["lines"] = [json.loads(l) for l in whole if l.strip()]
            for l in rec["lines"]:
                self.say("<- ch=%d EVENT %s" % (ch, json.dumps(l)[: self.a.width * 3]))
            if not self.a.no_credit:
                self.wr(encode(ch, CREDIT, struct.pack("<I", len(payload))))
        elif kind == DATA:
            self.rx_bytes[ch] = self.rx_bytes.get(ch, 0) + len(payload)
            self.say("<- ch=%d DATA len=%d %s" % (ch, len(payload), esc(payload, self.a.width)))
            if not self.a.no_credit:
                # CREDIT = "I consumed this many bytes"; without it the core stops after 256 KiB.
                self.wr(encode(ch, CREDIT, struct.pack("<I", len(payload))))
        elif kind == CLOSE:
            reason = None
            if payload:
                try:
                    reason = json.loads(payload)
                except ValueError:
                    reason = payload.decode("utf-8", "replace")
            rec["reason"] = reason
            self.say("<- ch=%d CLOSE reason=%s" % (ch, json.dumps(reason)))
        else:
            self.say("<- ch=%d %s len=%d %s" % (ch, KIND.get(kind, kind), len(payload), payload.hex()))
        self.log.append(rec)
        return True

    def pump(self, seconds):
        end = time.time() + seconds
        while True:
            left = end - time.time()
            if left <= 0:
                return True
            try:
                item = self.q.get(timeout=left)
            except queue.Empty:
                return True
            if not self.handle(item):
                return False

    def call(self, method, params=None, wait=10.0):
        rid = self.next_id
        self.next_id += 1
        self.methods[rid] = method
        req = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}
        self.send(0, DATA, json.dumps(req).encode())
        end = time.time() + wait
        while rid not in self.replies and time.time() < end:
            self.pump(0.05)
        return self.replies.get(rid)

    # ---- actions ----------------------------------------------------------------------
    def attach(self, terminal, extra=None):
        a = self.a
        params = {"terminal": terminal, "cols": a.cols, "rows": a.rows, "observe": a.observe, "history": a.history}
        params.update(extra or {})
        r = self.call("terminal.attach", params)
        if r and "result" in r:
            ch = r["result"]["channel"]
            self.channels[ch] = "attach"
            self.cur = ch
        return r

    def subscribe(self, extra=None):
        r = self.call("events.subscribe", extra or {})
        if r and "result" in r and r["result"].get("channel"):
            self.channels[r["result"]["channel"]] = "events"
            if self.cur is None:
                self.cur = r["result"]["channel"]   # so credit:/close actions work on a subscribe-only run
        return r

    def action(self, spec):
        name, _, arg = spec.partition(":")
        if name == "sleep":
            return self.pump(float(arg))
        if name == "call":
            m, _, js = arg.partition(":")
            self.call(m, json.loads(js) if js else {})
        elif name == "attach":
            t, _, js = arg.partition(":")
            self.attach(t, json.loads(js) if js else None)
        elif name == "subscribe":
            self.subscribe(json.loads(arg) if arg else None)
        elif name == "type":
            self.send(self.cur, DATA, codecs.decode(arg, "unicode_escape").encode("latin-1"))
        elif name == "hex":
            self.send(self.cur, DATA, bytes.fromhex(arg))
        elif name == "resize":
            c, r = arg.split("x")
            self.send(self.cur, RESIZE, struct.pack("<HH", int(c), int(r)))
        elif name == "focus":
            self.send(self.cur, FOCUS, bytes([int(arg)]))
        elif name == "facts":
            self.send(self.cur, FACTS, arg.encode())
        elif name == "credit":
            self.send(self.cur, CREDIT, struct.pack("<I", int(arg)))
        elif name == "close":
            self.send(self.cur, CLOSE, b"")
        elif name == "use":
            self.cur = int(arg)
        elif name == "eof":
            self.p.stdin.close()
            self.say("closed our stdin")
        else:
            raise SystemExit("unknown action " + spec)
        return True

    def run(self):
        a = self.a
        self.hello()
        if a.attach:
            self.attach(a.attach)
        if a.subscribe:
            self.subscribe()
        alive = True
        for spec in a.do:
            if not alive:
                break
            alive = self.action(spec) is not False
        # drain a little so late frames are shown
        self.pump(a.drain)
        self.say("RX bytes per channel:", self.rx_bytes)
        if a.capture:
            open(a.capture + ".bin", "wb").write(bytes(self.raw))
            open(a.capture + ".out.bin", "wb").write(bytes(self.sent))
            json.dump({"frames": self.log, "hello_reply": self.hello_reply}, open(a.capture + ".json", "w"), indent=1)
        try:
            self.p.stdin.close()
        except Exception:
            pass
        try:
            self.p.wait(timeout=3)
        except Exception:
            self.p.kill()
        self.say("hc connect exit code", self.p.returncode)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hc", default=os.environ.get("HC_BIN", "hc"), help="hc / herdr-core binary (default: $HC_BIN, else `hc` on PATH)")
    ap.add_argument("--session", default=os.environ.get("HC_SESSION"))
    ap.add_argument("--attach", help="terminal to attach first (t1, name, ...)")
    ap.add_argument("--subscribe", action="store_true", help="events.subscribe first")
    ap.add_argument("--observe", action="store_true")
    ap.add_argument("--history", type=int, default=0)
    ap.add_argument("--cols", type=int, default=80)
    ap.add_argument("--rows", type=int, default=24)
    ap.add_argument("--no-credit", action="store_true")
    ap.add_argument("--capture")
    ap.add_argument("--width", type=int, default=160)
    ap.add_argument("--drain", type=float, default=0.5)
    ap.add_argument("--do", action="append", default=[])
    Probe(ap.parse_args()).run()


if __name__ == "__main__":
    main()
