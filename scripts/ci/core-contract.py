#!/usr/bin/env python3
"""herdr-core contract check (WAY-472).

Waycar drives herdr-core (`herdr-core`, also `hc`; 0.x, API generation 1) over
`hc connect` pipes, the same bytes an SSH exec channel carries. Core is preview
software, so this script pins what the app assumes about its wire protocol
against a real release. Each scenario below maps to a fact (C1..C19) in
docs/design/herdr-core-backend.md section 1 and to the section that relies on it.

Usage:
  python3 scripts/ci/core-contract.py                    # download PINNED_VERSION, run everything
  python3 scripts/ci/core-contract.py --hc PATH          # use this binary
  python3 scripts/ci/core-contract.py --version 0.1.5    # download that release
  python3 scripts/ci/core-contract.py --latest --warn    # newest release; failures become ::warning::
  python3 scripts/ci/core-contract.py --list             # scenario names
  python3 scripts/ci/core-contract.py --only hello,restart_eof -v
  python3 scripts/ci/core-contract.py --print-pin        # what the workflow reads
  python3 scripts/ci/core-contract.py --fetch DIR        # download and verify PINNED_VERSION into DIR, print the binary's path, run nothing

Isolation: every scenario gets its own scratch session under /tmp/hcc-<random>
(a short path: Unix socket paths hold about 107 bytes) with HOME and every
XDG_* directory, HC_SESSION and the environment set from scratch, never
inherited. Most scenarios start core through `connect`; `explicit_start`
pins the app's side-effect-free probe and user-requested `server status` start.
At the end of each scenario `server stop` runs, leftover processes that carry
the scratch path are killed and the scratch root is deleted, on every exit
path. Nothing is cached between runs; nothing is installed. A run that is killed
(SIGKILL) cannot clean up after itself, so the next run reaps stale scratch: any
/tmp/hcc-* directory older than an hour, and every process whose command line
or environment carries that path.

The scratch core runs with HC_HEARTBEAT_MS=500 so the heartbeat can be asserted
in seconds: core's 15 s default heartbeat interval is NOT pinned here.

Integrity: the manifest and the archive come from the same host, so the manifest's
sha256 only proves the download is not corrupt. For PINNED_VERSION the archive must
also match PINNED_SHA256, which is committed here. `--version X` for any other
version and `--latest` trust the manifest alone. `--hc` trusts the binary you name.

With --warn a setup failure (dead URL, bad checksum, missing binary) is also printed
as a ::warning:: line, but still exits 2.

Stdlib only, Python 3.8 compatible.
"""
import argparse
import atexit
import base64
import hashlib
import io
import json
import os
import platform
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import traceback
import urllib.request

# The one place the pinned core release lives. The workflow reads it with --print-pin.
PINNED_VERSION = '0.1.14'
# sha256 of the PINNED_VERSION archives, copied from
# https://releases.herdr.dev/core/<PINNED_VERSION>/manifest.json. Bump both together.
PINNED_SHA256 = {
    'linux-x86_64': 'e9dbabdead0ce0ce3de51b6f54cc9549efedbb41b2f8448b6932ab0d1442343e',
    'linux-aarch64': '19cef6a2e52f14c22c4b6f3fdaf1a462d2dafc78e8b03fabbfad5b063477a370',
    'macos-aarch64': 'ca524329d2e0630219550055dcc71f42aafd85fba356e0d543d6f51244487970',
    'macos-x86_64': '8e16ec43a17656f80e7d7f98292bf710c60c4aeff52941cca98fb24f37f35028',
}

# The app's minimum core version (design section 1, C16): file.* and status_ms arrived in 0.1.10.
VERSION_FLOOR = (0, 1, 10)

RELEASES = 'https://releases.herdr.dev/core/'
SCENARIO_BUDGET = 60.0
# A scratch directory older than this is stale: its run died without cleaning up.
STALE_SECONDS = 3600

# What the app calls (design section 7).
REQUIRED = [
    'hello', 'server.status', 'terminal.run', 'terminal.list', 'terminal.get', 'terminal.kill',
    'terminal.read', 'terminal.attach', 'terminal.send', 'terminal.keys', 'terminal.interrupt',
    'terminal.label', 'terminal.put', 'machine.exec', 'file.read', 'file.write', 'doc.get',
    'events.subscribe', 'rpc.discover',
]
RECORD_KEYS = ['address', 'labels', 'argv', 'cwd', 'state', 'created_ms', 'screen', 'cols', 'rows']
ADDRESS_RE = re.compile(r'^t[1-9][0-9a-z]*$')
ID_DIGITS = '0123456789bcdfghjkmnpqrstvwxyz'

DATA, CREDIT, CLOSE, RESIZE, FOCUS, FACTS = range(6)
HDR = struct.Struct('<IBI')


class Fail(Exception):
    """A contract assertion failed: the reason is the message."""


class SetupError(Exception):
    """The run could not start (download, checksum, binary): never downgraded by --warn."""


class RpcError(Fail):
    def __init__(self, method, error):
        self.method = method
        self.error = error
        data = error.get('data') if isinstance(error, dict) else None
        kind = data.get('kind') if isinstance(data, dict) else None
        msg = error.get('message') if isinstance(error, dict) else error
        Fail.__init__(self, '%s failed: %s: %s' % (method, kind, msg))


# ---------------------------------------------------------------------------------------------
# Getting the binary
# ---------------------------------------------------------------------------------------------

def target_key():
    system = platform.system()
    machine = platform.machine().lower()
    arch = {'x86_64': 'x86_64', 'amd64': 'x86_64', 'aarch64': 'aarch64', 'arm64': 'aarch64'}.get(machine)
    osname = {'Linux': 'linux', 'Darwin': 'macos'}.get(system)
    if not osname or not arch:
        raise SetupError('no herdr-core build for %s/%s (releases cover linux-x86_64, linux-aarch64, '
                         'macos-aarch64, macos-x86_64)' % (system, platform.machine()))
    return '%s-%s' % (osname, arch)


def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'waycar-core-contract/1'})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.read()
    except Exception as exc:
        raise SetupError('cannot fetch %s: %s' % (url, exc))


def download(version, latest, dest_dir, log):
    """Download, verify and unpack the top-level herdr-core member into dest_dir; returns its path."""
    manifest_url = RELEASES + ('latest.json' if latest else '%s/manifest.json' % version)
    try:
        manifest = json.loads(fetch(manifest_url).decode('utf-8'))
        key = target_key()
        entry = manifest['targets'][key]
        url, want = entry['url'], entry['sha256'].lower()
    except SetupError:
        raise
    except (KeyError, ValueError) as exc:
        raise SetupError('unusable manifest %s (%s: %s)' % (manifest_url, type(exc).__name__, exc))
    if not url.startswith(RELEASES):
        raise SetupError('manifest url %s is outside %s' % (url, RELEASES))
    log('downloading %s' % url)
    blob = fetch(url)
    got = hashlib.sha256(blob).hexdigest()
    if got != want:
        raise SetupError('sha256 mismatch for %s: manifest %s, downloaded %s' % (url, want, got))
    if not latest and version == PINNED_VERSION:
        pinned = PINNED_SHA256.get(key)
        if pinned is None:
            raise SetupError('PINNED_SHA256 has no entry for %s' % key)
        if got != pinned:
            raise SetupError('sha256 of %s does not match PINNED_SHA256: pinned %s, downloaded %s' % (url, pinned, got))
    try:
        tf = tarfile.open(fileobj=io.BytesIO(blob), mode='r:gz')
    except tarfile.TarError as exc:
        raise SetupError('%s is not a tar.gz: %s' % (url, exc))
    member = None
    with tf:
        for m in tf.getmembers():
            for name in (m.name, m.linkname if (m.issym() or m.islnk()) else ''):
                if name.startswith('/') or '..' in name.replace('\\', '/').split('/'):
                    raise SetupError('archive member %r escapes the extraction directory' % name)
            if os.path.normpath(m.name) == 'herdr-core' and m.isfile():
                member = m
        if member is None:
            raise SetupError('archive %s has no top-level herdr-core file' % url)
        path = os.path.join(dest_dir, 'herdr-core')
        src = tf.extractfile(member)
        with open(path, 'wb') as out:
            shutil.copyfileobj(src, out)
    os.chmod(path, 0o755)
    return path


def check_binary(path):
    try:
        out = subprocess.run([path, '--version'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             timeout=15, universal_newlines=True)
    except (OSError, subprocess.SubprocessError) as exc:
        raise SetupError('%s --version failed: %s' % (path, exc))
    text = out.stdout.strip()
    if out.returncode != 0 or not re.match(r'^hc \d+\.\d+\.\d+', text):
        raise SetupError('%s --version printed %r (exit %d), expected "hc X.Y.Z"' % (path, text, out.returncode))
    return text


# ---------------------------------------------------------------------------------------------
# Scratch sessions
# ---------------------------------------------------------------------------------------------

_live_scratches = []
_live_lock = threading.Lock()


def find_procs(root):
    """Pids (other than ours) whose command line or environment mentions the scratch root."""
    me = os.getpid()
    found = []
    needle = root.encode()
    if os.path.isdir('/proc/self'):
        for name in os.listdir('/proc'):
            if not name.isdigit() or int(name) == me:
                continue
            for part in ('cmdline', 'environ'):
                try:
                    with open('/proc/%s/%s' % (name, part), 'rb') as f:
                        if needle in f.read():
                            found.append(int(name))
                            break
                except OSError:
                    pass
        return found
    try:
        out = subprocess.run(['ps', '-axo', 'pid=,command='], stdout=subprocess.PIPE,
                             universal_newlines=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return found
    for line in out.splitlines():
        pid, _, cmd = line.strip().partition(' ')
        if pid.isdigit() and int(pid) != me and root in cmd:
            found.append(int(pid))
    return found


class Scratch(object):
    """One throwaway core: its own HOME, XDG_* dirs and session, under a short /tmp path."""

    def __init__(self, work_root, name, hc, env_overrides=None):
        self.hc = hc
        self.root = os.path.join(work_root, name)
        self.home = os.path.join(self.root, 'h')
        self.run = os.path.join(self.root, 'r')
        self.state = os.path.join(self.root, 's')
        self.config = os.path.join(self.root, 'c')
        self.proj = os.path.join(self.root, 'proj')
        for d in (self.home, self.run, self.state, self.config, self.proj):
            os.makedirs(d)
        os.chmod(self.run, 0o700)
        self.session = 'hcc'
        self.env = {
            'HOME': self.home,
            'PATH': '/usr/bin:/bin',
            'SHELL': '/bin/sh',
            'LANG': 'C.UTF-8',
            'XDG_RUNTIME_DIR': self.run,
            'XDG_STATE_HOME': self.state,
            'XDG_CONFIG_HOME': self.config,
            'HC_SESSION': self.session,
            'HC_HEARTBEAT_MS': '500',
        }
        if env_overrides:
            self.env.update(env_overrides)
        self.clients = []
        self._logs = 0
        with _live_lock:
            _live_scratches.append(self)

    def spawn_connect(self, env_overrides=None):
        env = dict(self.env)
        if env_overrides:
            env.update(env_overrides)
        self._logs += 1
        errlog = open(os.path.join(self.root, 'connect-%d.err' % self._logs), 'wb')
        proc = subprocess.Popen([self.hc, 'connect'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=errlog, env=env, cwd=self.home, bufsize=0)
        proc.errlog_path = errlog.name
        errlog.close()
        return proc

    def cli(self, *args, **kw):
        env = dict(self.env)
        env.update(kw.get('env') or {})
        return subprocess.run([self.hc] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env=env, cwd=self.home, timeout=kw.get('timeout', 20), universal_newlines=True)

    def track(self, client):
        self.clients.append(client)
        return client

    def cleanup(self):
        for c in self.clients:
            try:
                c.close()
            except Exception:
                pass
        try:
            self.cli('server', 'stop', timeout=15)
        except Exception:
            pass
        for _ in range(3):
            pids = find_procs(self.root)
            if not pids:
                break
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
            time.sleep(0.2)
        shutil.rmtree(self.root, ignore_errors=True)
        with _live_lock:
            if self in _live_scratches:
                _live_scratches.remove(self)


def cleanup_all():
    with _live_lock:
        items = list(_live_scratches)
    for s in items:
        s.cleanup()


def reap_stale(log):
    """Remove what a killed run left behind: /tmp/hcc-* dirs older than STALE_SECONDS, and their processes."""
    now = time.time()
    try:
        names = os.listdir('/tmp')
    except OSError:
        return
    for name in names:
        path = os.path.join('/tmp', name)
        if not name.startswith('hcc-') or os.path.islink(path):
            continue
        try:
            st = os.stat(path)
        except OSError:
            continue
        if not os.path.isdir(path) or st.st_uid != os.getuid() or now - st.st_mtime < STALE_SECONDS:
            continue
        pids = find_procs(path)
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        shutil.rmtree(path, ignore_errors=True)
        log('reaped stale %s (%d process(es))' % (path, len(pids)))


# ---------------------------------------------------------------------------------------------
# Clients
# ---------------------------------------------------------------------------------------------

class ClientBase(object):
    def request(self, method, params=None, timeout=10.0):
        raise NotImplementedError

    def call(self, method, params=None, timeout=10.0):
        msg = self.request(method, params, timeout)
        if 'error' in msg:
            raise RpcError(method, msg['error'])
        return msg.get('result')

    def fail_call(self, method, params=None, kind=None, timeout=10.0):
        """Call something that must fail; returns the error object after checking its shape."""
        msg = self.request(method, params, timeout)
        if 'error' not in msg:
            raise Fail('%s succeeded, expected an error%s' % (method, ' (%s)' % kind if kind else ''))
        err = msg['error']
        check_error_shape(method, err)
        if kind is not None and err['data']['kind'] != kind:
            raise Fail('%s failed with kind %r, expected %r (%s)' % (method, err['data']['kind'], kind, err.get('message')))
        return err

    def stderr_tail(self):
        try:
            with open(self.proc.errlog_path, 'rb') as f:
                return f.read()[-300:].decode('utf-8', 'replace').strip()
        except (OSError, AttributeError):
            return ''

    def close(self):
        proc = self.proc
        try:
            proc.stdin.close()
        except Exception:
            pass
        deadline = time.time() + 3
        while proc.poll() is None and time.time() < deadline:
            time.sleep(0.05)
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        try:
            proc.stdout.close()
        except Exception:
            pass


def check_error_shape(method, err):
    if not isinstance(err, dict) or not isinstance(err.get('code'), int) or not isinstance(err.get('message'), str) \
            or not isinstance(err.get('data'), dict) or not isinstance(err['data'].get('kind'), str):
        raise Fail('%s error object lacks code/message/data.kind: %r' % (method, err))


class Plain(ClientBase):
    """Plain mode over `hc connect` pipes: one JSON line per message, strictly serial."""

    def __init__(self, scratch, env_overrides=None):
        self.proc = scratch.spawn_connect(env_overrides)
        self.fd = self.proc.stdout.fileno()
        self.buf = b''
        self.next_id = 1
        self.notes = []

    def send_line(self, obj):
        self.proc.stdin.write((json.dumps(obj) + '\n').encode())

    def read_message(self, timeout):
        """One decoded line, or None when nothing arrives within timeout."""
        end = time.time() + timeout
        while b'\n' not in self.buf:
            left = end - time.time()
            if left <= 0:
                return None
            ready, _, _ = select.select([self.fd], [], [], left)
            if not ready:
                return None
            chunk = os.read(self.fd, 65536)
            if not chunk:
                raise Fail('connection closed by core (hc connect stderr: %r)' % self.stderr_tail())
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b'\n')
        try:
            return json.loads(line.decode('utf-8'))
        except ValueError:
            raise Fail('stdout line is not JSON: %r' % line[:200])

    def start(self, method, params=None):
        rid = self.next_id
        self.next_id += 1
        self.send_line({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params if params is not None else {}})
        return rid

    def wait_reply(self, rid, method, timeout):
        end = time.time() + timeout
        while True:
            msg = self.read_message(max(0.0, end - time.time()))
            if msg is None:
                raise Fail('no reply to %s within %gs' % (method, timeout))
            if msg.get('id') == rid:
                return msg
            self.notes.append(msg)

    def request(self, method, params=None, timeout=10.0):
        return self.wait_reply(self.start(method, params), method, timeout)


class Framed(ClientBase):
    """Framed mode: plain hello line, then [channel u32 LE][kind u8][len u32 LE][payload] frames."""

    def __init__(self, scratch, auto_credit=True, env_overrides=None):
        self.proc = scratch.spawn_connect(env_overrides)
        self.fd = self.proc.stdout.fileno()
        self.auto_credit = auto_credit
        self.cond = threading.Condition()
        self.wlock = threading.Lock()
        self.log = []            # arrival order: (ch, kind, payload)
        self.replies = {}        # id -> message
        self.reply_pos = {}      # id -> index in self.log
        self.notifications = []  # ch0 messages without an id
        self.data = {}           # ch -> bytearray of DATA payloads
        self.frames = {}         # ch -> number of DATA frames
        self.first_pos = {}      # ch -> log index of the first frame
        self.closes = {}         # ch -> [CLOSE payload, ...]
        self.credit_sent = {}
        self.eof = False
        self.next_id = 1
        buf = self._hello()
        self.reader = threading.Thread(target=self._read_loop, args=(buf,))
        self.reader.daemon = True
        self.reader.start()

    def _hello(self):
        req = {'jsonrpc': '2.0', 'id': 0, 'method': 'hello', 'params': {'framed': True, 'generation': 1}}
        self.proc.stdin.write((json.dumps(req) + '\n').encode())
        buf = b''
        end = time.time() + 10
        while b'\n' not in buf:
            left = end - time.time()
            ready = select.select([self.fd], [], [], max(0.0, left))[0] if left > 0 else []
            if not ready:
                raise Fail('no hello reply within 10s (hc connect stderr: %r)' % self.stderr_tail())
            chunk = os.read(self.fd, 65536)
            if not chunk:
                raise Fail('connection closed before the hello reply (hc connect stderr: %r)' % self.stderr_tail())
            buf += chunk
        line, _, rest = buf.partition(b'\n')
        msg = json.loads(line.decode('utf-8'))
        if 'error' in msg:
            raise RpcError('hello', msg['error'])
        if msg['result'].get('framed') is not True:
            raise Fail('hello {framed:true} answered framed=%r' % msg['result'].get('framed'))
        self.hello_result = msg['result']
        return rest

    def _read_loop(self, buf):
        try:
            while True:
                while len(buf) < HDR.size:
                    chunk = os.read(self.fd, 65536)
                    if not chunk:
                        raise EOFError
                    buf += chunk
                ch, kind, ln = HDR.unpack(buf[:HDR.size])
                while len(buf) < HDR.size + ln:
                    chunk = os.read(self.fd, 65536)
                    if not chunk:
                        raise EOFError
                    buf += chunk
                payload = buf[HDR.size:HDR.size + ln]
                buf = buf[HDR.size + ln:]
                self._frame(ch, kind, payload)
        except (EOFError, OSError, ValueError):
            pass
        with self.cond:
            self.eof = True
            self.cond.notify_all()

    def _frame(self, ch, kind, payload):
        credit = 0
        with self.cond:
            pos = len(self.log)
            self.log.append((ch, kind, payload))
            self.first_pos.setdefault(ch, pos)
            if ch == 0 and kind == DATA:
                msg = json.loads(payload.decode('utf-8'))
                if msg.get('id') is not None:
                    self.replies[msg['id']] = msg
                    self.reply_pos[msg['id']] = pos
                else:
                    self.notifications.append(msg)
            elif kind == DATA:
                self.data.setdefault(ch, bytearray()).extend(payload)
                self.frames[ch] = self.frames.get(ch, 0) + 1
                if self.auto_credit:
                    credit = len(payload)
            elif kind == CLOSE:
                self.closes.setdefault(ch, []).append(bytes(payload))
            self.cond.notify_all()
        if credit:
            self.credit(ch, credit)

    def send_frame(self, ch, kind, payload=b''):
        with self.wlock:
            self.proc.stdin.write(HDR.pack(ch, kind, len(payload)) + payload)

    def credit(self, ch, nbytes):
        with self.cond:
            self.credit_sent[ch] = self.credit_sent.get(ch, 0) + nbytes
            self.cond.notify_all()
        self.send_frame(ch, CREDIT, struct.pack('<I', nbytes))

    def type(self, ch, data):
        self.send_frame(ch, DATA, data)

    def resize(self, ch, cols, rows):
        self.send_frame(ch, RESIZE, struct.pack('<HH', cols, rows))

    def close_channel(self, ch):
        self.send_frame(ch, CLOSE, b'')

    def wait_for(self, pred, timeout, what):
        end = time.time() + timeout
        with self.cond:
            while True:
                value = pred()
                if value:
                    return value
                left = end - time.time()
                if self.eof:
                    raise Fail('connection hit EOF while waiting for %s' % what)
                if left <= 0:
                    raise Fail('timed out after %gs waiting for %s' % (timeout, what))
                self.cond.wait(min(left, 0.2))

    def start(self, method, params=None):
        rid = self.next_id
        self.next_id += 1
        self.send_frame(0, DATA, json.dumps({'jsonrpc': '2.0', 'id': rid, 'method': method,
                                             'params': params if params is not None else {}}).encode())
        return rid

    def request(self, method, params=None, timeout=10.0):
        rid = self.start(method, params)
        return self.wait_for(lambda: self.replies.get(rid), timeout, 'the reply to %s' % method)

    def attach(self, terminal, cols, rows, observe=False, history=0, **extra):
        params = {'terminal': terminal, 'cols': cols, 'rows': rows, 'observe': observe, 'history': history}
        params.update(extra)
        rid = self.start('terminal.attach', params)
        msg = self.wait_for(lambda: self.replies.get(rid), 10, 'the reply to terminal.attach')
        if 'error' in msg:
            raise RpcError('terminal.attach', msg['error'])
        res = msg['result']
        ch = res.get('channel')
        if not isinstance(ch, int) or ch < 1:
            raise Fail('terminal.attach channel is %r, expected an int >= 1' % (ch,))
        return ch, rid

    def total(self, ch):
        with self.cond:
            return len(self.data.get(ch, b''))

    def stream(self, ch):
        with self.cond:
            return bytes(self.data.get(ch, b''))

    def lines(self, ch):
        """Complete JSON lines received on a channel (lines may span DATA frames)."""
        raw = self.stream(ch)
        out = []
        for line in raw.split(b'\n')[:-1]:
            if line.strip():
                try:
                    out.append(json.loads(line.decode('utf-8')))
                except ValueError:
                    raise Fail('channel %d line is not JSON: %r' % (ch, line[:120]))
        return out

    def close_payload(self, ch):
        got = self.closes.get(ch) or []
        return got[0] if got else None


# ---------------------------------------------------------------------------------------------
# Scenario plumbing
# ---------------------------------------------------------------------------------------------

SCENARIOS = []


def scenario(name):
    def deco(fn):
        SCENARIOS.append((name, fn))
        return fn
    return deco


class Ctx(object):
    def __init__(self, hc, scratch, verbose, warn):
        self.hc = hc
        self.scratch = scratch
        self.verbose = verbose
        self.warn = warn
        self.proj = scratch.proj

    def log(self, msg):
        if self.verbose:
            print('    . %s' % msg, flush=True)

    def plain(self, env_overrides=None):
        return self.scratch.track(Plain(self.scratch, env_overrides))

    def framed(self, auto_credit=True, env_overrides=None):
        return self.scratch.track(Framed(self.scratch, auto_credit, env_overrides))

    def expect(self, cond, msg):
        if not cond:
            raise Fail(msg)

    def expect_eq(self, actual, expected, what):
        if actual != expected:
            raise Fail('%s: got %r, expected %r' % (what, actual, expected))

    def wait_until(self, fn, timeout, what, interval=0.1):
        end = time.time() + timeout
        while True:
            value = fn()
            if value:
                return value
            if time.time() >= end:
                raise Fail('timed out after %gs waiting for %s' % (timeout, what))
            time.sleep(interval)

    def run(self, cl, argv=None, **params):
        p = {'cwd': self.proj}
        if argv is not None:
            p['argv'] = argv
        p.update(params)
        return cl.call('terminal.run', p)

    def write_script(self, name, text):
        path = os.path.join(self.scratch.root, name)
        with open(path, 'w') as f:
            f.write(text)
        os.chmod(path, 0o755)
        return path

    def agent(self):
        return self.write_script('agent.sh', AGENT_SH)

    def reader_script(self):
        return self.write_script('reader.sh', READER_SH)

    def run_agent(self, cl, **params):
        return self.run(cl, ['sh', self.agent()], **params)

    def run_reader(self, cl, bracketed=False, **params):
        if bracketed:
            env = dict(params.pop('env', None) or {})
            env['HCC_2004'] = '1'
            params['env'] = env
        rec = self.run(cl, ['sh', self.reader_script()], **params)
        addr = rec['address']
        self.wait_until(lambda: 'READY' in cl.call('terminal.read', {'terminal': addr})['text'], 8,
                        'the reader terminal to print READY')
        return addr

    def type_line(self, cl, term, word):
        """Type a lowercase word and Enter with terminal.keys (never waits, never refused)."""
        cl.call('terminal.keys', {'terminal': term, 'keys': list(word) + ['enter']})

    def get(self, cl, term):
        return cl.call('terminal.get', {'terminal': term})

    def kill(self, cl, term):
        return cl.call('terminal.kill', {'terminal': term})

    def rec_check(self, rec, where):
        missing = [k for k in RECORD_KEYS if k not in rec]
        if missing:
            raise Fail('%s lacks record keys %s' % (where, missing))
        if 'id' in rec:
            raise Fail('%s has an `id` key; the record id is `address`' % where)
        if not ADDRESS_RE.match(str(rec['address'])):
            raise Fail('%s address %r does not match %s' % (where, rec['address'], ADDRESS_RE.pattern))


class ByteReader(object):
    """Bytes a raw reader terminal saw, as hex strings, from its `B:xx` screen lines."""

    def __init__(self, ctx, cl, term):
        self.ctx, self.cl, self.term = ctx, cl, term

    def all(self):
        text = self.cl.call('terminal.read', {'terminal': self.term})['text']
        return re.findall(r'(?m)^B:([0-9a-f]{2})\s*$', text)

    def expect_new(self, before, expected, what, timeout=5.0):
        """The reader sees exactly `expected` (hex strings) after the `before` snapshot."""
        want = len(before) + len(expected)
        got = []
        end = time.time() + timeout
        while time.time() < end:
            got = self.all()
            if len(got) >= want:
                break
            time.sleep(0.1)
        time.sleep(0.15)
        got = self.all()
        new = got[len(before):]
        if got[:len(before)] != before or new != expected:
            raise Fail('%s: reader saw %s, expected %s' % (what, ' '.join(new) or '(nothing)', ' '.join(expected)))
        return got


def b64(text):
    return base64.b64encode(text.encode()).decode()


AGENT_MSGS = {
    'TITLE': 'Refactoring', 'M1': 'step 1', 'M2': 'step 2', 'MD': 'All done',
    'MA': 'Allow rm -rf /tmp/x?', 'MF': 'It broke',
}

# A fake agent: reports through OSC 7501 like a real one and obeys one word per line.
AGENT_SH = r"""#!/bin/sh
osc() { printf '\033]7501;%s\033\\' "$1"; }
osc 'state=idle:app=fake'
while IFS= read -r line; do
  case "$line" in
    work)  osc 'state=working:app=fake:progress=40:title=@TITLE@:msg=@M1@' ;;
    work2) osc 'state=working:app=fake:progress=40:title=@TITLE@:msg=@M2@' ;;
    done)  osc 'state=done:app=fake:msg=@MD@' ;;
    idle)  osc 'state=idle:app=fake' ;;
    ask)   osc 'state=blocked:app=fake:kind=permission:msg=@MA@' ;;
    fail)  osc 'state=error:app=fake:msg=@MF@' ;;
    turn)  osc 'state=working:app=fake:progress=40:title=@TITLE@:msg=@M1@'; sleep 0.3
           osc 'state=done:app=fake:msg=@MD@'; sleep 0.3; osc 'state=idle:app=fake' ;;
    title) printf '\033]0;mytitle\033\\' ;;
    *)     printf 'GOT:%s\n' "$line" ;;
  esac
done
"""
for _k, _v in AGENT_MSGS.items():
    AGENT_SH = AGENT_SH.replace('@%s@' % _k, b64(_v))

# A raw byte reader: prints every byte it receives as `B:xx`. HCC_2004 turns bracketed paste on first.
READER_SH = r"""#!/bin/sh
stty raw -echo opost onlcr 2>/dev/null
[ -n "$HCC_2004" ] && printf '\033[?2004h'
printf 'READY\n'
while :; do
  b=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' ')
  [ -z "$b" ] && exit 0
  printf 'B:%s\n' "$b"
done
"""


def parse_version(text):
    m = re.match(r'^(\d+)\.(\d+)\.(\d+)$', text or '')
    return tuple(int(x) for x in m.groups()) if m else None


def address_number(addr):
    """Address -> counter (t1..t9, t10..): base 30 over ID_DIGITS. Only used to see that ids are burned."""
    n = 0
    for ch in addr[1:]:
        n = n * 30 + ID_DIGITS.index(ch)
    return n


def hello_result(cl):
    return cl.call('hello', {})


# ---------------------------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------------------------

# design: section 5, fact C16
@scenario('hello')
def sc_hello(ctx):
    """hello shape, generation gate, error objects."""
    cl = ctx.plain()
    res = hello_result(cl)
    core = res.get('core')
    ctx.expect(isinstance(core, dict) and 'id' in core and 'name' in core, 'hello.core lacks id/name: %r' % (core,))
    feats = res.get('features')
    ctx.expect(isinstance(feats, list), 'hello.features is not a list: %r' % (feats,))
    for f in ('framed', 'attach', 'events', 'status'):
        ctx.expect(f in feats, 'hello.features lacks %r: %r' % (f, feats))
    ctx.expect_eq(res.get('generation'), 1, 'hello.generation')
    ctx.expect_eq(res.get('framed'), False, 'hello.framed on a plain hello')
    methods = res.get('methods')
    ctx.expect(isinstance(methods, list), 'hello.methods is not a list: %r' % (methods,))
    missing = [m for m in REQUIRED if m not in methods]
    ctx.expect(not missing, 'hello.methods lacks %s' % ', '.join(missing))
    # A 1.0 core is meant to fail this strict job (the regex below) until the design is revisited.
    ctx.expect(re.match(r'^0\.\d+\.\d+$', str(res.get('version'))), 'hello.version %r is not 0.x.y' % (res.get('version'),))
    cl.fail_call('hello', {'generation': 2}, kind='unsupported_generation')
    cl2 = ctx.plain()
    err2 = cl2.fail_call('nope.method', {}, kind='unknown_method')
    ctx.expect_eq(err2['code'], -32601, 'unknown method error code')
    cl2.fail_call('terminal.get', {}, kind='invalid_params')
    cl2.fail_call('terminal.get', {'terminal': 'nosuch'}, kind='not_found')


# design: section 1, fact C16
@scenario('version_floor')
def sc_version_floor(ctx):
    """core version is at least the app's floor (0.1.10)."""
    cl = ctx.plain()
    ver = hello_result(cl).get('version')
    parsed = parse_version(ver)
    ctx.expect(parsed is not None, 'hello.version %r is not X.Y.Z' % (ver,))
    ctx.expect(parsed >= VERSION_FLOOR, 'core %s is below the app floor %s' % (ver, '.'.join(map(str, VERSION_FLOOR))))


# design: section 1, fact C1 (and C19 for hidden_finished)
@scenario('terminal_record')
def sc_terminal_record(ctx):
    """record shape, address, list/get, foreground, kill, finished visibility."""
    cl = ctx.plain()
    labels = {'herdr.space': 'sp1', 'herdr.tab': 'tb1', 'waycar': '1'}
    rec = ctx.run(cl, ['sh', '-c', 'sleep 60'], labels=labels)
    ctx.rec_check(rec, 'terminal.run result')
    addr = rec['address']
    ctx.expect_eq(rec['state'], 'live', 'run result state')
    ctx.expect(rec.get('status') is None, 'run result status is %r, expected null' % (rec.get('status'),))
    ctx.expect_eq(rec.get('reported'), False, 'run result reported')
    ctx.expect_eq(rec['labels'], labels, 'labels round trip')
    ctx.expect_eq(rec['cwd'], ctx.proj, 'run result cwd')
    ctx.expect_eq(rec['argv'], ['sh', '-c', 'sleep 60'], 'run result argv')
    listing = cl.call('terminal.list', {})
    ctx.expect(isinstance(listing.get('hidden_finished'), int), 'terminal.list lacks hidden_finished: %r' % sorted(listing))
    entry = [t for t in listing['terminals'] if t.get('address') == addr]
    ctx.expect(len(entry) == 1, 'terminal.list does not contain %s' % addr)
    ctx.rec_check(entry[0], 'terminal.list entry')
    got = ctx.get(cl, addr)
    ctx.rec_check(got, 'terminal.get result')
    for k in ('address', 'name', 'labels', 'argv', 'cwd', 'state', 'created_ms', 'screen', 'cols', 'rows'):
        ctx.expect_eq(got.get(k), entry[0].get(k), 'terminal.get vs terminal.list on %s' % k)

    def fg():
        f = ctx.get(cl, addr).get('foreground')
        return f if isinstance(f, dict) else None
    f = ctx.wait_until(fg, 3, 'a foreground object on %s' % addr)
    missing = [k for k in ('pid', 'name', 'argv', 'cwd') if k not in f]
    ctx.expect(not missing, 'foreground lacks %s: %r' % (missing, f))
    killed = ctx.kill(cl, addr)
    ctx.expect_eq(killed.get('state'), 'finished', 'terminal.kill state')
    ctx.expect_eq(killed.get('reason'), 'killed', 'terminal.kill reason')
    live = cl.call('terminal.list', {})
    ctx.expect(addr not in [t['address'] for t in live['terminals']], 'finished %s is still in terminal.list {}' % addr)
    ctx.expect(live.get('hidden_finished', 0) >= 1, 'hidden_finished is %r after a finish' % (live.get('hidden_finished'),))
    full = cl.call('terminal.list', {'all': True})
    ctx.expect(addr in [t['address'] for t in full['terminals']], 'finished %s missing from terminal.list {all:true}' % addr)


# design: section 1, fact C6
@scenario('spawn_failed')
def sc_spawn_failed(ctx):
    """spawn failures, no ~ expansion, burned addresses, machine.exec exit codes."""
    cl = ctx.plain()
    first = ctx.run(cl, ['sh', '-c', 'sleep 60'])['address']
    cl.fail_call('terminal.run', {'argv': ['definitely-not-a-program-hcc'], 'cwd': ctx.proj}, kind='spawn_failed')
    cl.fail_call('terminal.run', {'argv': ['sh', '-c', 'true'], 'cwd': os.path.join(ctx.proj, 'nonexistent')}, kind='spawn_failed')
    cl.fail_call('terminal.run', {'argv': ['sh', '-c', 'true'], 'cwd': '~'}, kind='spawn_failed')
    second = ctx.run(cl, ['sh', '-c', 'sleep 60'])['address']
    gap = address_number(second) - address_number(first)
    ctx.expect(gap >= 2, 'failed spawns did not burn an address: %s then %s' % (first, second))
    ok = cl.call('machine.exec', {'argv': ['test', '-d', ctx.proj]})
    ctx.expect_eq(ok.get('code'), 0, 'machine.exec test -d on a directory: code')
    bad = cl.call('machine.exec', {'argv': ['test', '-d', os.path.join(ctx.proj, 'missing')]})
    ctx.expect_eq(bad.get('code'), 1, 'machine.exec test -d on a missing path: code')
    for res in (ok, bad):
        for k in ('stdout', 'stderr'):
            v = res.get(k)
            ctx.expect(isinstance(v, str), 'machine.exec %s is %r, expected a base64 string' % (k, v))
            try:
                base64.b64decode(v.encode(), validate=True)
            except ValueError:
                raise Fail('machine.exec %s %r is not base64' % (k, v))


# design: section 1, fact C5
@scenario('env_frozen')
def sc_env_frozen(ctx):
    """the core's env is frozen at its first start; a per-run env.PATH overrides and resolves argv[0]."""
    first = ctx.plain()  # the scratch env is an `env -i` PATH=/usr/bin:/bin start, like a bare ssh exec
    rec = first.call('terminal.run', {'line': 'echo PATH=$PATH', 'cwd': ctx.proj, 'wait': True})
    out = rec.get('output', '')
    ctx.expect('PATH=/usr/bin:/bin' in [l.strip() for l in out.splitlines()],
               'frozen PATH is not exactly /usr/bin:/bin; output was %r' % out[-200:])
    second = ctx.plain({'PATH': '/opt/rich:/usr/local/bin:/usr/bin:/bin', 'HCC_MARKER': 'second'})
    rec = second.call('terminal.run', {'line': 'echo PATH=$PATH MARK=$HCC_MARKER', 'cwd': ctx.proj, 'wait': True})
    lines = [l.strip() for l in rec.get('output', '').splitlines()]
    ctx.expect('PATH=/usr/bin:/bin MARK=' in lines, 'a later client changed the core env; output was %r' % rec.get('output', '')[-200:])
    rec = first.call('terminal.run', {'argv': ['sh', '-c', 'echo $PATH'], 'cwd': ctx.proj,
                                      'env': {'PATH': '/custom:/usr/bin:/bin'}, 'wait': True})
    ctx.expect('/custom:/usr/bin:/bin' in [l.strip() for l in rec.get('output', '').splitlines()],
               'env.PATH override not seen; output was %r' % rec.get('output', '')[-200:])
    bindir = os.path.join(ctx.scratch.root, 'bin')
    os.makedirs(bindir)
    ctx.write_script('bin/definitely-not-here', '#!/bin/sh\necho ran-from-override\n')
    first.fail_call('terminal.run', {'argv': ['definitely-not-here'], 'cwd': ctx.proj}, kind='spawn_failed')
    rec = first.call('terminal.run', {'argv': ['definitely-not-here'], 'cwd': ctx.proj,
                                      'env': {'PATH': bindir + ':/usr/bin:/bin'}, 'wait': True})
    ctx.expect('ran-from-override' in rec.get('output', ''),
               'argv[0] was not resolved through the env.PATH override; output was %r' % rec.get('output', '')[-200:])


# design: section 6, fact C9
@scenario('status_semantics')
def sc_status_semantics(ctx):
    """OSC 7501 -> status/reported/turn/status_ms, decoded msg."""
    cl = ctx.plain()
    quiet = ctx.run(cl, ['sh', '-c', 'sleep 60'])['address']
    time.sleep(0.5)
    q = ctx.get(cl, quiet)
    ctx.expect_eq(q.get('reported'), False, 'never-reporting terminal reported')
    ctx.expect(q.get('status') is None, 'never-reporting terminal status is %r' % (q.get('status'),))
    term = ctx.run_agent(cl)['address']
    st = ctx.wait_until(lambda: ctx.get(cl, term) if ctx.get(cl, term).get('reported') else None, 5,
                        'the fake agent to report')
    ctx.expect_eq(st['status'].get('state'), 'idle', 'first status state')
    ctx.expect_eq(st['status'].get('app'), 'fake', 'status.app')
    ctx.expect_eq(st.get('turn'), 0, 'turn before any work')

    def until(state, what):
        return ctx.wait_until(lambda: (lambda r: r if (r.get('status') or {}).get('state') == state else None)(ctx.get(cl, term)),
                              5, what)
    ctx.type_line(cl, term, 'work')
    w1 = until('working', 'state=working')
    s = w1['status']
    ctx.expect_eq(s.get('msg'), AGENT_MSGS['M1'], 'status.msg (decoded, not base64)')
    ctx.expect_eq(s.get('title'), AGENT_MSGS['TITLE'], 'status.title (decoded)')
    ctx.expect_eq(s.get('progress'), 40, 'status.progress')
    ctx.expect_eq(s.get('app'), 'fake', 'status.app while working')
    ctx.expect_eq(w1.get('turn'), 0, 'turn while working')
    ms1 = w1.get('status_ms')
    ctx.expect(isinstance(ms1, int), 'status_ms is %r after a state change' % (ms1,))
    # The app's Watch reads it as a clock (design section 6): milliseconds since the epoch.
    now_ms = int(time.time() * 1000)
    ctx.expect(abs(ms1 - now_ms) < 120000, 'status_ms %r is not milliseconds since the epoch (now %r)' % (ms1, now_ms))
    time.sleep(0.05)
    ctx.type_line(cl, term, 'work2')
    w2 = ctx.wait_until(lambda: (lambda r: r if (r.get('status') or {}).get('msg') == AGENT_MSGS['M2'] else None)(ctx.get(cl, term)),
                        5, 'the second working message')
    ctx.expect_eq(w2.get('status_ms'), ms1, 'status_ms after working -> working (must not move)')
    ctx.type_line(cl, term, 'done')
    d = until('done', 'state=done')
    ctx.expect_eq(d['status'].get('msg'), AGENT_MSGS['MD'], 'done msg')
    ctx.expect_eq(d.get('turn'), 1, 'turn after leaving working')
    ctx.expect(d.get('status_ms') != ms1, 'status_ms did not move on working -> done')
    ctx.type_line(cl, term, 'work')
    until('working', 'working again')
    ctx.type_line(cl, term, 'ask')
    b = until('blocked', 'state=blocked')
    ctx.expect_eq(b['status'].get('kind'), 'permission', 'blocked kind')
    ctx.expect_eq(b['status'].get('msg'), AGENT_MSGS['MA'], 'blocked msg')
    ctx.expect_eq(b.get('turn'), 2, 'turn after working -> blocked')
    ctx.type_line(cl, term, 'fail')
    e = until('error', 'state=error')
    ctx.expect_eq(e['status'].get('msg'), AGENT_MSGS['MF'], 'error msg')
    ctx.expect_eq(e.get('turn'), 2, 'turn after blocked -> error')
    ctx.type_line(cl, term, 'idle')
    until('idle', 'state=idle')


# design: section 7, fact C7 and C8
@scenario('send_and_keys')
def sc_send_and_keys(ctx):
    """terminal.send paste rules, terminal.keys encodings and validation, blocked refusal."""
    cl = ctx.plain()
    plain_t = ctx.run_reader(cl)
    rd = ByteReader(ctx, cl, plain_t)
    seen = rd.all()
    cl.call('terminal.send', {'terminal': plain_t, 'text': 'hello'}, timeout=15)
    seen = rd.expect_new(seen, ['68', '65', '6c', '6c', '6f', '0d'], 'send without bracketed paste')
    paste_t = ctx.run_reader(cl, bracketed=True)
    pr = ByteReader(ctx, cl, paste_t)
    pseen = pr.all()
    cl.call('terminal.send', {'terminal': paste_t, 'text': 'hello'}, timeout=15)
    pr.expect_new(pseen, '1b 5b 32 30 30 7e 68 65 6c 6c 6f 1b 5b 32 30 31 7e 0d'.split(), 'send with ESC[?2004h')
    keymap = [
        ('enter', ['0d']), ('esc', ['1b']), ('up', ['1b', '5b', '41']), ('ctrl+c', ['03']),
        ('home', ['1b', '5b', '48']), ('pagedown', ['1b', '5b', '36', '7e']),
        ('f5', ['1b', '5b', '31', '35', '7e']),
        ('-', ['2d']), (',', ['2c']), ('.', ['2e']), ('/', ['2f']), ("'", ['27']), (';', ['3b']), ('`', ['60']),
        ('\\', ['5c']), ('backslash', ['5c']), ('space', ['20']),
    ]
    for key, want in keymap:
        cl.call('terminal.keys', {'terminal': plain_t, 'keys': [key]})
        seen = rd.expect_new(seen, want, 'terminal.keys %r' % key)
    err = cl.fail_call('terminal.keys', {'terminal': plain_t, 'keys': ['x', 'minus', 'y']}, kind='invalid_params')
    time.sleep(0.4)
    cl.call('terminal.keys', {'terminal': plain_t, 'keys': ['q']})
    seen = rd.expect_new(seen, ['71'], 'after a rejected key list nothing may be typed (only the marker q)')
    for key in ('+', '"', ':', '%', '&'):
        cl.fail_call('terminal.keys', {'terminal': plain_t, 'keys': [key]}, kind='invalid_params')
    time.sleep(0.4)
    rd.expect_new(seen, [], 'rejected keys +"%:& typed something')
    agent = ctx.run_agent(cl)['address']
    ctx.wait_until(lambda: ctx.get(cl, agent).get('reported'), 5, 'the fake agent to report')
    ctx.type_line(cl, agent, 'ask')
    ctx.wait_until(lambda: (ctx.get(cl, agent).get('status') or {}).get('state') == 'blocked', 5, 'agent blocked')
    cl.fail_call('terminal.send', {'terminal': agent, 'text': 'hi'}, kind='blocked', timeout=15)
    cl.call('terminal.send', {'terminal': agent, 'text': 'hi', 'force': True}, timeout=15)
    ctx.wait_until(lambda: 'GOT:hi' in cl.call('terminal.read', {'terminal': agent})['text'], 5,
                   'force:true text to reach the blocked agent')


# design: section 5, fact C10 and C4
@scenario('framed_events')
def sc_framed_events(ctx):
    """framed events: subscribe reply order, event shapes, order, credit, heartbeat, split lines."""
    cl = ctx.framed()
    rid = cl.start('events.subscribe', {})
    sub = cl.wait_for(lambda: cl.replies.get(rid), 10, 'the reply to events.subscribe')
    ctx.expect('result' in sub, 'events.subscribe failed: %r' % sub.get('error'))
    res = sub['result']
    ch = res.get('channel')
    ctx.expect(isinstance(ch, int) and ch >= 1, 'events.subscribe channel is %r' % (ch,))
    ctx.expect(isinstance(res.get('seq'), int), 'events.subscribe seq is %r' % (res.get('seq'),))
    ctx.expect(isinstance(res.get('terminals'), list), 'events.subscribe terminals is %r' % (res.get('terminals'),))
    term = ctx.run_agent(cl, labels={'a': 'b'})['address']
    ctx.wait_until(lambda: any(e['params'].get('type') == 'status' and e['params'].get('terminal') == term
                               for e in cl.lines(ch) if e.get('method') == 'event'), 5, 'the first status event')
    ctx.type_line(cl, term, 'turn')
    ctx.type_line(cl, term, 'title')
    big = 'x' * 40000
    cl.call('terminal.label', {'terminal': term, 'labels': {'big': big}})
    cl.call('terminal.label', {'terminal': term, 'labels': {'big': ''}})
    time.sleep(1.2)
    cl.call('terminal.kill', {'terminal': term})

    def events():
        return [e for e in cl.lines(ch) if e.get('method') == 'event']
    ctx.wait_until(lambda: any(e['params'].get('type') == 'finished' and e['params'].get('terminal') == term
                               for e in events()), 5, 'the finished event')
    evs = events()
    pos = cl.first_pos.get(ch)
    ctx.expect(pos is not None and cl.reply_pos[rid] < pos, 'a frame on the event channel arrived before the ch0 reply')
    last = -1
    for e in evs:
        ctx.expect(e.get('jsonrpc') == '2.0' and set(e) >= {'jsonrpc', 'method', 'params'},
                   'event envelope is not {jsonrpc,method,params}: %r' % sorted(e))
        p = e['params']
        miss = [k for k in ('seq', 'type', 'terminal', 'data') if k not in p]
        ctx.expect(not miss, 'event params lack %s: %r' % (miss, p))
        ctx.expect(p['seq'] > last, 'event seq is not strictly increasing: %r after %r' % (p['seq'], last))
        last = p['seq']
    mine = [e['params']['type'] for e in evs if e['params'].get('terminal') == term]
    for t in ('created', 'status', 'finished', 'title', 'labels'):
        ctx.expect(t in mine, 'no %r event for %s; saw %s' % (t, term, mine))
    first_status = mine.index('status')
    ctx.expect(mine.index('created') < first_status < len(mine) - 1 - mine[::-1].index('finished'),
               'event order is not created < status < finished: %s' % mine)
    labels_ev = [e for e in evs if e['params'].get('type') == 'labels' and e['params'].get('terminal') == term]
    ctx.expect(any(big in json.dumps(e) for e in labels_ev), 'the 40 KB labels event did not arrive intact across DATA frames')
    cl.wait_for(lambda: sum(cl.credit_sent.values()) > 0 and cl.credit_sent.get(ch) == cl.total(ch), 3,
                'client credit to match consumed bytes (credit %r, consumed %d)' % (cl.credit_sent.get(ch), cl.total(ch)))
    seen = len(heartbeats(cl, ch))
    ctx.wait_until(lambda: len(heartbeats(cl, ch)) > seen, 5, 'a heartbeat within 5s of silence')
    beat = heartbeats(cl, ch)[-1]
    ctx.expect(isinstance(beat.get('params', {}).get('seq'), int), 'heartbeat params.seq is %r' % (beat.get('params'),))


def heartbeats(cl, ch):
    return [m for m in cl.lines(ch) if m.get('method') == 'heartbeat']


# design: section 8, fact C4
@scenario('credit_stall')
def sc_credit_stall(ctx):
    """without CREDIT an attach stream stops at exactly 262144 bytes; CREDIT resumes it."""
    cl = ctx.framed(auto_credit=False)
    rec = ctx.run(cl, ['sh', '-c', 'sleep 1; yes | head -c 2000000; sleep 60'])
    term = rec['address']
    cl.fail_call('terminal.attach', {'terminal': term}, kind='invalid_params')
    ch, rid = cl.attach(term, 52, 28)
    cl.wait_for(lambda: cl.total(ch) >= 262144, 12, 'the stream to fill its 256 KiB of credit')
    time.sleep(0.5)
    ctx.expect_eq(cl.total(ch), 262144, 'DATA bytes without CREDIT')
    time.sleep(1.5)
    ctx.expect_eq(cl.total(ch), 262144, 'DATA bytes after 1.5s of silence')
    ctx.expect(cl.reply_pos[rid] < cl.first_pos[ch], 'the first paint arrived before the ch0 attach reply')
    first = [p for (c, k, p) in cl.log if c == ch and k == DATA][0]
    ctx.expect(first.startswith(b'\x1b[!p'), 'first paint starts with %r, expected ESC[!p' % first[:8])
    cl.credit(ch, 65536)
    cl.wait_for(lambda: cl.total(ch) > 262144, 5, 'more data after CREDIT 65536')
    ctx.kill(cl, term)
    cl.fail_call('terminal.attach', {'terminal': term, 'cols': 52, 'rows': 28, 'observe': False, 'history': 0}, kind='finished')


# design: section 8, fact C13
@scenario('attach_size_rules')
def sc_attach_size_rules(ctx):
    """newest typing viewer sets the pty size; last detach snaps to 200x120; observers never lead or type."""
    a = ctx.framed()
    b = ctx.framed()
    term = ctx.run_reader(a)
    rd = ByteReader(ctx, a, term)

    def size():
        r = ctx.get(a, term)
        return (r['cols'], r['rows'])

    def settle(want, what):
        ctx.wait_until(lambda: size() == want, 5, '%s: size %s (now %s)' % (what, want, size()))

    cha, _ = a.attach(term, 120, 40)
    settle((120, 40), 'A attached')
    chb, _ = b.attach(term, 52, 28)
    b.type(chb, b'x')
    settle((52, 28), 'B attached and typed')
    a.type(cha, b'y')
    settle((120, 40), 'A typed')
    b.close_channel(chb)
    b.wait_for(lambda: chb in b.closes, 5, "the core's CLOSE answer to B")
    time.sleep(0.5)
    ctx.expect_eq(size(), (120, 40), 'size after B closed')
    a.close_channel(cha)
    a.wait_for(lambda: cha in a.closes, 5, "the core's CLOSE answer to A")
    settle((200, 120), 'A closed (headless)')
    before = rd.all()
    o = ctx.framed()
    cho, _ = o.attach(term, 30, 10, observe=True)
    time.sleep(0.5)
    ctx.expect_eq(size(), (200, 120), 'size after an observer attached')
    o.type(cho, b'Z')
    o.resize(cho, 30, 10)
    time.sleep(0.7)
    ctx.expect_eq(size(), (200, 120), 'size after an observer RESIZE')
    ctx.expect_eq(rd.all(), before, 'bytes the program saw after observer DATA (must be none)')
    cha2, _ = a.attach(term, 80, 24)
    a.type(cha2, b'Q')
    rd.expect_new(before, ['51'], 'a non-observer viewer typing Q')
    settle((80, 24), 'A re-attached')


# design: section 8, fact C13 (attach lifecycle)
@scenario('close_and_exit_reasons')
def sc_close_and_exit_reasons(ctx):
    """CLOSE payloads for exit and kill; viewer CLOSE is answered with an empty CLOSE."""
    cl = ctx.framed()
    go = os.path.join(ctx.scratch.root, 'go')
    t1 = ctx.run(cl, ['sh', '-c', 'while [ ! -e %s ]; do sleep 0.1; done; exit 3' % go])['address']
    ch1, _ = cl.attach(t1, 80, 24)
    open(go, 'w').close()
    cl.wait_for(lambda: ch1 in cl.closes, 8, 'CLOSE after the program exited')
    pl = json.loads(cl.close_payload(ch1).decode('utf-8'))
    ctx.expect_eq(pl.get('reason'), 'exited', 'CLOSE reason on exit')
    ctx.expect_eq(pl.get('exit_code'), 3, 'CLOSE exit_code')
    t2 = ctx.run(cl, ['sh', '-c', 'sleep 60'])['address']
    ch2, _ = cl.attach(t2, 80, 24)
    ctx.kill(cl, t2)
    cl.wait_for(lambda: ch2 in cl.closes, 8, 'CLOSE after terminal.kill')
    pl = json.loads(cl.close_payload(ch2).decode('utf-8'))
    ctx.expect_eq(pl.get('reason'), 'killed', 'CLOSE reason on kill')
    t3 = ctx.run(cl, ['sh', '-c', 'sleep 60'])['address']
    ch3, _ = cl.attach(t3, 80, 24)
    cl.close_channel(ch3)
    cl.wait_for(lambda: ch3 in cl.closes, 5, "the core's answer to a viewer CLOSE")
    ctx.expect_eq(cl.close_payload(ch3), b'', 'payload of the core answer to a viewer CLOSE')


# design: section 7, fact C6 (readPane, readAgent and the screen checks before a prompt)
@scenario('read_screen_and_history')
def sc_read_screen_and_history(ctx):
    """terminal.read: lines 0 is the visible screen, lines N adds scrollback above it, a finished terminal stays readable."""
    cl = ctx.plain()
    cmd = 'i=1; while [ $i -le 300 ]; do echo "line $i"; i=$((i+1)); done; sleep 60'
    term = ctx.run(cl, ['sh', '-c', cmd])['address']
    ctx.wait_until(lambda: 'line 300' in cl.call('terminal.read', {'terminal': term})['text'], 8, 'line 300 on the screen')
    screen = cl.call('terminal.read', {'terminal': term, 'lines': 0})
    rows = screen['text'].split('\n')
    ctx.expect(rows[-1] == 'line 300', 'the screen ends with %r, expected line 300' % rows[-1])
    ctx.expect(rows[0] != 'line 1' and len(rows) <= 121, 'lines 0 returned %d rows starting at %r' % (len(rows), rows[0]))
    ctx.expect_eq(screen.get('how'), 'screen', 'how for lines 0')
    more = cl.call('terminal.read', {'terminal': term, 'lines': 5})['text'].split('\n')
    ctx.expect(len(more) == len(rows) + 5, 'lines 5 returned %d rows, expected %d' % (len(more), len(rows) + 5))
    full = cl.call('terminal.read', {'terminal': term, 'lines': 1000})
    frows = full['text'].split('\n')
    ctx.expect(frows[0] == 'line 1' and frows[-1] == 'line 300', 'lines 1000 spans %r .. %r' % (frows[0], frows[-1]))
    ctx.expect_eq(full.get('complete'), True, 'complete when the whole history was asked for')
    ctx.kill(cl, term)
    ctx.wait_until(lambda: ctx.get(cl, term).get('state') == 'finished', 5, '%s to finish' % term)
    after = cl.call('terminal.read', {'terminal': term, 'lines': 1000})['text'].split('\n')
    ctx.expect(after[-1] == 'line 300', 'a finished terminal reads %r last, expected line 300' % after[-1])


# design: section 8, fact C12 (Attach is `hc attach` on a pty)
@scenario('pty_attach')
def sc_pty_attach(ctx):
    """`hc attach` on a pty: first paint, typed bytes, resize, the viewer leaves when the pty closes, exit 0 when the program ends."""
    import fcntl
    import pty
    import termios
    cl = ctx.framed()
    term = ctx.run_reader(cl)
    rd = ByteReader(ctx, cl, term)

    def size(address):
        r = ctx.get(cl, address)
        return (r['cols'], r['rows'])

    def open_attach(address, cols, rows):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
        env = dict(ctx.scratch.env)
        env['TERM'] = 'xterm-256color'
        proc = subprocess.Popen([ctx.hc, 'attach', address], stdin=slave, stdout=slave, stderr=slave,
                                env=env, cwd=ctx.scratch.home, start_new_session=True, close_fds=True)
        os.close(slave)
        return master, proc

    def drain(master, seconds):
        out = b''
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
        return out

    master, proc = open_attach(term, 52, 28)
    try:
        painted = drain(master, 1.5)
        ctx.expect(b'READY' in painted, 'the first paint lacks the screen: %r' % painted[:200])
        ctx.wait_until(lambda: size(term) == (52, 28), 5, 'the pty size 52x28 (now %s)' % (size(term),))
        before = rd.all()
        os.write(master, b'q')
        rd.expect_new(before, ['71'], 'a byte typed on the attach pty')
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
        ctx.wait_until(lambda: size(term) == (100, 30), 5, 'a resize to 100x30 (now %s)' % (size(term),))
        os.close(master)
        master = None
        ctx.wait_until(lambda: proc.poll() is not None, 5, 'hc attach to exit once its pty closed')
        ctx.wait_until(lambda: size(term) == (200, 120), 5, 'the headless size once the viewer left (now %s)' % (size(term),))
    finally:
        if master is not None:
            os.close(master)
        if proc.poll() is None:
            proc.kill()
        proc.wait()
    short = ctx.run(cl, ['sh', '-c', 'sleep 1; exit 3'])['address']
    master, proc = open_attach(short, 80, 24)
    try:
        tail = drain(master, 4.0)
        ctx.wait_until(lambda: proc.poll() is not None, 8, 'hc attach to exit when its program exited')
        ctx.expect_eq(proc.returncode, 0, 'hc attach exit status after the program exited')
        ctx.expect(b'finished' in tail, 'the end line does not say the terminal finished: %r' % tail[-200:])
    finally:
        os.close(master)
        if proc.poll() is None:
            proc.kill()
        proc.wait()


def pid_alive(pid):
    try:
        with open('/proc/%d/stat' % pid) as f:
            return f.read().rsplit(')', 1)[1].split()[0] != 'Z'
    except (OSError, IndexError):
        pass
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


# design: section 5, fact C11
@scenario('restart_eof')
def sc_restart_eof(ctx):
    """server.restart ends every connection with EOF and no CLOSE; terminals survive."""
    cl = ctx.framed()
    term = ctx.run(cl, ['sh', '-c', 'sleep 120'])['address']
    pid = ctx.wait_until(lambda: ctx.get(cl, term).get('pid'), 5, 'a pid on %s' % term)
    cha, _ = cl.attach(term, 80, 24)
    cl.call('events.subscribe', {})
    core_pid = cl.call('server.status', {}).get('pid')
    ctx.expect(isinstance(core_pid, int), 'server.status pid is %r' % (core_pid,))
    cl.start('server.restart', {})
    cl.wait_for(lambda: cl.eof, 20, 'EOF after server.restart')
    ctx.expect(not cl.closes, 'CLOSE frames arrived before the restart EOF: %r' % cl.closes)
    end = time.time() + 5
    while cl.proc.poll() is None and time.time() < end:
        time.sleep(0.05)
    ctx.expect_eq(cl.proc.poll(), 0, 'hc connect exit code after the core closed it')
    ctx.wait_until(lambda: not pid_alive(core_pid), 15, 'the old core (pid %d) to exit' % core_pid)
    fresh = ctx.framed()
    new_pid = fresh.call('server.status', {}).get('pid')
    ctx.expect(new_pid != core_pid, 'server.status pid is still %r after restart' % (new_pid,))
    ctx.expect_eq(ctx.get(fresh, term).get('pid'), pid, 'terminal pid after restart')
    rid = fresh.start('events.subscribe', {})
    snap = fresh.wait_for(lambda: fresh.replies.get(rid), 10, 'the post-restart snapshot')['result']
    listed = sorted(t['address'] for t in fresh.call('terminal.list', {'all': True})['terminals'])
    snapped = sorted(t['address'] for t in snap['terminals'])
    ctx.expect_eq(snapped, listed, 'subscribe snapshot vs terminal.list all')
    ctx.expect(term in snapped, 'snapshot lacks %s' % term)


# design: section 4, fact C2 and C14
def app_core_script(name):
    """Read the exact fixed shell text from CoreConnectCommand, not a second probe."""
    source = os.path.join(os.path.dirname(__file__), '..', '..', 'Sources', 'Waycar',
                          'Transport', 'Core', 'CoreConnectCommand.swift')
    with open(source) as f:
        text = f.read()
    block = text.split('static let %s =' % name, 1)[1].split('\n\n', 1)[0]
    literals = re.findall(r'"(?:\\.|[^"\\])*"', block)
    return ''.join(json.loads(literal) for literal in literals)


@scenario('explicit_start')
def explicit_start(c):
    """C2/C5, #389: only an explicit start may create a core; probe starts nothing."""
    s = c.scratch
    script = app_core_script('socketScript') + app_core_script('runningProbeScript')
    # Same refusal wrapper as CoreConnectCommand.connect (125 is Waycar's
    # reserved exit; core itself never uses it). Keep path visible for checks.
    probe = (script + '; r=$?; printf "%s" "$HC_SOCKET"; '
             '[ "$r" = 0 ] || { echo "herdr-core is not running here" >&2; exit 125; }')
    cases = [
        ({}, os.path.join(s.run, 'herdr-core', s.session + '.sock')),
        ({'HC_SOCKET': os.path.join(s.root, 'custom.sock')}, os.path.join(s.root, 'custom.sock')),
        ({'XDG_RUNTIME_DIR': '', 'HC_SESSION': '  named  '},
         os.path.join(s.state, 'herdr-core', 'named', 'named.sock')),
    ]
    for overrides, expected in cases:
        env = dict(s.env)
        env.update(overrides)
        c.expect(not os.path.exists(expected), 'socket exists before probe: ' + expected)
        before = find_procs(s.root)
        stopped = subprocess.run(['/bin/sh', '-c', probe], env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, universal_newlines=True, timeout=10)
        c.expect_eq(stopped.returncode, 125, 'stopped probe status')
        c.expect_eq(stopped.stderr, 'herdr-core is not running here\n', 'stopped probe refusal')
        c.expect_eq(stopped.stdout, expected, 'probed socket')
        c.expect(not os.path.exists(expected), 'probe created a socket')
        c.expect_eq(find_procs(s.root), before, 'probe left no core process')
        # The app uses this same socket derivation and pins HC_SOCKET before
        # server status, including in its login-session job's environment.
        start = app_core_script('socketScript') + 'exec "$1" server status >/dev/null'
        result = subprocess.run(['/bin/sh', '-c', start, 'core', s.hc], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                universal_newlines=True, timeout=15)
        c.expect_eq(result.returncode, 0, 'server status start: ' + result.stderr)
        running = subprocess.run(['/bin/sh', '-c', probe], env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, universal_newlines=True, timeout=10)
        c.expect_eq(running.returncode, 0, 'probe after start exited')
        c.expect_eq(running.stdout, expected, 'running socket')
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            peer.connect(expected)
        c.log('probe stopped (no socket/process); server status exited 0; still listening: ' + expected)
        s.cli('server', 'stop', env=dict(overrides, HC_SOCKET=expected))
        c.wait_until(lambda: not os.path.exists(expected), 5, 'socket removal after stop')


@scenario('detect_no_core')
def sc_detect_no_core(ctx):
    """--version and server stop start nothing; a foreign hc fails the ^hc \\d+ check."""
    s = ctx.scratch
    out = s.cli('--version')
    ctx.expect(out.returncode == 0 and re.match(r'^hc \d+\.\d+\.\d+', out.stdout), '--version printed %r' % out.stdout)

    def quiet(what):
        leftovers = [os.path.join(dp, f) for d in (s.run, s.state, s.config) for dp, dn, fn in os.walk(d) for f in dn + fn]
        ctx.expect(not leftovers, '%s created %s' % (what, leftovers))
        pids = find_procs(s.root)
        ctx.expect(not pids, '%s left processes running: %s' % (what, pids))
    quiet('--version')
    out = s.cli('server', 'stop')
    try:
        stopped = json.loads(out.stdout.strip().splitlines()[-1]).get('stopped')
    except (ValueError, IndexError):
        raise Fail('server stop printed %r (exit %d), expected JSON' % (out.stdout, out.returncode))
    ctx.expect_eq(stopped, False, 'server stop on a session with no core: stopped')
    quiet('server stop')
    shim = os.path.join(s.root, 'shim')
    os.makedirs(shim)
    ctx.write_script('shim/hc', '#!/bin/sh\necho "hc: herbstclient 0.9"\n')
    shim_out = subprocess.run([os.path.join(shim, 'hc'), '--version'], stdout=subprocess.PIPE,
                              universal_newlines=True).stdout.strip()
    ctx.expect(not re.match(r'^hc \d+', shim_out), 'a foreign hc (%r) passes the ^hc \\d+ check' % shim_out)


# design: section 5, fact C3
@scenario('plain_mode_traps')
def sc_plain_mode_traps(ctx):
    """plain mode is serial; after events.subscribe it never answers again."""
    cl = ctx.plain()
    term = ctx.run(cl, ['sh', '-c', 'sleep 60'])['address']
    t0 = time.time()
    wid = cl.start('terminal.wait', {'terminal': term, 'timeout': 3})
    sid = cl.start('server.status', {})
    cl.wait_reply(sid, 'server.status', 15)
    elapsed = time.time() - t0
    ctx.expect(2.5 <= elapsed <= 8, 'server.status behind a 3s terminal.wait answered after %.1fs, expected about 3s' % elapsed)
    ctx.expect(any(n.get('id') == wid for n in cl.notes), 'terminal.wait reply did not precede the later request reply')
    sub = ctx.plain()
    sub.call('events.subscribe', {})
    rid = sub.start('terminal.list', {})
    end = time.time() + 2
    while time.time() < end:
        msg = sub.read_message(max(0.0, end - time.time()))
        ctx.expect(msg is None or msg.get('id') != rid, 'a subscribed plain connection answered a later request: %r' % (msg,))


# design: section 7, fact C6 and C16
@scenario('files_and_exec')
def sc_files_and_exec(ctx):
    """file.write/read/edit, machine.exec base64, terminal.put location and silence."""
    cl = ctx.plain()
    path = os.path.join(ctx.proj, 'new', 'deep', 'x.txt')
    cl.call('file.write', {'path': path, 'data': b64('hello\nhello\nworld\n')})
    ctx.expect(os.path.isfile(path), 'file.write did not create %s (parent dirs)' % path)
    ctx.expect_eq(cl.call('file.read', {'path': path}).get('text'), 'hello\nhello\nworld\n', 'file.read text')
    cl.fail_call('file.edit', {'path': path, 'edits': [{'old': 'hello', 'new': 'bye'}]}, kind='edit_failed')
    cl.call('file.edit', {'path': path, 'edits': [{'old': 'world', 'new': 'earth'}]})
    ctx.expect_eq(cl.call('file.read', {'path': path}).get('text'), 'hello\nhello\nearth\n', 'file.read after a unique edit')
    res = cl.call('machine.exec', {'argv': ['printf', '%s', 'hi']})
    ctx.expect_eq(res.get('stdout'), b64('hi'), 'machine.exec stdout base64')
    term = ctx.run_reader(cl)
    rd = ByteReader(ctx, cl, term)
    before = rd.all()
    put = cl.call('terminal.put', {'terminal': term, 'name': 'shot.png', 'data': b64('abc')})
    p = put.get('path')
    ctx.expect(isinstance(p, str), 'terminal.put result has no path: %r' % (put,))
    ctx.expect(os.path.realpath(p).startswith(os.path.realpath(ctx.scratch.state) + os.sep),
               'terminal.put path %s is not under the state dir %s' % (p, ctx.scratch.state))
    ctx.expect(os.path.isfile(p) and open(p, 'rb').read() == b'abc', 'terminal.put did not store the bytes at %s' % p)
    time.sleep(0.7)
    ctx.expect_eq(rd.all(), before, 'bytes typed into the terminal by terminal.put (must be none)')


# design: section 6, fact C13 (headless size)
@scenario('initial_size')
def sc_initial_size(ctx):
    """a terminal nobody attached is 200x120 right after terminal.run."""
    cl = ctx.plain()
    rec = ctx.run(cl, ['sh', '-c', 'sleep 60'])
    addr = rec['address']
    ctx.expect_eq((rec.get('cols'), rec.get('rows')), (200, 120), 'terminal.run result size')
    got = ctx.get(cl, addr)
    ctx.expect_eq((got.get('cols'), got.get('rows')), (200, 120), 'terminal.get size')
    entry = [t for t in cl.call('terminal.list', {})['terminals'] if t.get('address') == addr][0]
    ctx.expect_eq((entry.get('cols'), entry.get('rows')), (200, 120), 'terminal.list size')


# design: section 5, fact C10
@scenario('subscribe_snapshot_and_turn')
def sc_subscribe_snapshot_and_turn(ctx):
    """the subscribe snapshot includes finished terminals; a status cycle emits a turn event."""
    cl = ctx.framed()
    done = ctx.run(cl, ['sh', '-c', 'exit 0'])['address']
    ctx.wait_until(lambda: ctx.get(cl, done).get('state') == 'finished', 5, '%s to finish' % done)
    rid = cl.start('events.subscribe', {})
    res = cl.wait_for(lambda: cl.replies.get(rid), 10, 'the reply to events.subscribe')
    ctx.expect('result' in res, 'events.subscribe failed: %r' % res.get('error'))
    snap = [t for t in res['result']['terminals'] if t.get('address') == done]
    ctx.expect(len(snap) == 1, 'the snapshot does not include the finished terminal %s' % done)
    ctx.expect_eq(snap[0].get('state'), 'finished', 'finished record state in the snapshot')
    ch = res['result']['channel']
    agent = ctx.run_agent(cl)['address']
    ctx.wait_until(lambda: ctx.get(cl, agent).get('reported'), 5, 'the fake agent to report')
    ctx.type_line(cl, agent, 'turn')

    def turn_events():
        return [e['params'] for e in cl.lines(ch) if e.get('method') == 'event'
                and e['params'].get('type') == 'turn' and e['params'].get('terminal') == agent]
    evs = ctx.wait_until(turn_events, 8, 'a turn event for %s' % agent)
    data = evs[0].get('data') or {}
    ctx.expect(isinstance(data.get('turn'), int), 'turn event data.turn is %r' % (data.get('turn'),))
    ctx.expect(isinstance(data.get('state'), str), 'turn event data.state is %r' % (data.get('state'),))


# design: section 1, fact C18
@scenario('terminal_env')
def sc_terminal_env(ctx):
    """a terminal gets HC_TERMINAL_ID, HC_TERMINAL_SOCKET, HC_SESSION and no HERDR_* variable."""
    cl = ctx.plain()
    rec = cl.call('terminal.run', {'line': 'env', 'cwd': ctx.proj, 'wait': True})
    lines = [l.strip() for l in rec.get('output', '').splitlines()]
    ctx.expect('HC_TERMINAL_ID=%s' % rec['address'] in lines,
               'no HC_TERMINAL_ID=%s line in the terminal env' % rec['address'])
    ctx.expect(any(l.startswith('HC_TERMINAL_SOCKET=') and len(l) > len('HC_TERMINAL_SOCKET=') for l in lines),
               'no HC_TERMINAL_SOCKET= line in the terminal env')
    ctx.expect('HC_SESSION=%s' % ctx.scratch.session in lines, 'no HC_SESSION=%s line in the terminal env' % ctx.scratch.session)
    herdr = [l for l in lines if l.startswith('HERDR_')]
    ctx.expect(not herdr, 'the terminal env carries HERDR_* variables: %s' % herdr)


# design: section 7, fact C8
@scenario('key_names')
def sc_key_names(ctx):
    """more terminal.keys names and the bytes they type (rpc-facts section 5)."""
    cl = ctx.plain()
    term = ctx.run_reader(cl)
    rd = ByteReader(ctx, cl, term)
    seen = rd.all()
    keymap = [
        ('tab', ['09']), ('backspace', ['7f']), ('delete', ['1b', '5b', '33', '7e']),
        ('insert', ['1b', '5b', '32', '7e']), ('end', ['1b', '5b', '46']),
        ('pageup', ['1b', '5b', '35', '7e']), ('f1', ['1b', '4f', '50']),
        ('f12', ['1b', '5b', '32', '34', '7e']), ('alt+x', ['1b', '78']),
        ('shift+tab', ['1b', '5b', '5a']), ('[', ['5b']), (']', ['5d']), ('=', ['3d']),
    ]
    for key, want in keymap:
        cl.call('terminal.keys', {'terminal': term, 'keys': [key]})
        seen = rd.expect_new(seen, want, 'terminal.keys %r' % key)


# design: section 6, fact C16 (run options and documents)
@scenario('run_options')
def sc_run_options(ctx):
    """terminal.run outlive_parent and keep echo; doc.set/doc.get version rules."""
    cl = ctx.plain()
    parent = ctx.run(cl, ['sh', '-c', 'sleep 60'])['address']
    bound = ctx.run(cl, ['sh', '-c', 'sleep 60'], parent=parent)
    ctx.expect_eq(bound.get('die_with_parent'), True, 'die_with_parent of a child with a parent')
    free = ctx.run(cl, ['sh', '-c', 'sleep 60'], parent=parent, outlive_parent=True)
    ctx.expect_eq(free.get('die_with_parent'), False, 'die_with_parent with outlive_parent')
    kept = ctx.run(cl, ['sh', '-c', 'sleep 60'], keep=True)
    ctx.expect_eq(kept.get('keep'), True, 'keep in the terminal.run result')
    ctx.expect_eq(ctx.get(cl, kept['address']).get('keep'), True, 'keep in terminal.get')
    fresh = cl.call('doc.get', {'name': 'hccdoc'})
    ctx.expect_eq((fresh.get('value'), fresh.get('version')), (None, 0), 'doc.get of a new document')
    ctx.expect_eq(cl.call('doc.set', {'name': 'hccdoc', 'value': {'a': 1}, 'version': 0}).get('version'), 1,
                  'doc.set version on a new document')
    got = cl.call('doc.get', {'name': 'hccdoc'})
    ctx.expect_eq((got.get('value'), got.get('version')), ({'a': 1}, 1), 'doc.get after doc.set')
    cl.fail_call('doc.set', {'name': 'hccdoc', 'value': {'a': 2}, 'version': 0}, kind='conflict')
    ctx.expect_eq(cl.call('doc.set', {'name': 'hccdoc', 'value': {'a': 2}, 'version': 1}).get('version'), 2,
                  'doc.set with the current version')


# design: section 1, fact C15 (empty label means absent)
@scenario('label_removal')
def sc_label_removal(ctx):
    """terminal.label with an empty value removes the key from the record."""
    cl = ctx.plain()
    addr = ctx.run(cl, ['sh', '-c', 'sleep 60'], labels={'k': 'v', 'other': '1'})['address']
    rec = cl.call('terminal.label', {'terminal': addr, 'labels': {'k': ''}})
    ctx.expect_eq(rec.get('labels'), {'other': '1'}, 'labels in the terminal.label result')
    ctx.expect_eq(ctx.get(cl, addr).get('labels'), {'other': '1'}, 'labels in terminal.get')
    matching = cl.call('terminal.list', {'labels': {'k': 'v'}})['terminals']
    ctx.expect(addr not in [t['address'] for t in matching], 'terminal.list still matches the removed label')


# ---------------------------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------------------------

def run_scenario(name, fn, hc, work_root, index, args):
    scratch = Scratch(work_root, 's%02d' % index, hc)
    ctx = Ctx(hc, scratch, args.verbose, args.warn)
    outcome = {}

    def target():
        try:
            fn(ctx)
            outcome['ok'] = True
        except Fail as exc:
            outcome['reason'] = str(exc)
        except Exception as exc:
            outcome['reason'] = '%s: %s' % (type(exc).__name__, exc)
            if args.verbose:
                outcome['trace'] = traceback.format_exc()

    started = time.time()
    t = threading.Thread(target=target)
    t.daemon = True
    t.start()
    t.join(SCENARIO_BUDGET)
    if t.is_alive():
        outcome = {'reason': 'timed out after %gs' % SCENARIO_BUDGET}
    scratch.cleanup()
    return outcome, time.time() - started


def main():
    ap = argparse.ArgumentParser(description='herdr-core contract check (WAY-472)')
    src = ap.add_mutually_exclusive_group()
    src.add_argument('--hc', metavar='PATH', help='use this herdr-core binary')
    src.add_argument('--version', metavar='X.Y.Z', help='download this release (default: the pin, %s)' % PINNED_VERSION)
    src.add_argument('--latest', action='store_true', help="download latest.json's version")
    ap.add_argument('--warn', action='store_true', help='report assertion failures as ::warning:: and exit 0')
    ap.add_argument('--only', metavar='NAME[,NAME]', help='run only these scenarios')
    ap.add_argument('--list', action='store_true', help='list scenario names')
    ap.add_argument('--print-pin', action='store_true', help='print the pinned core version')
    ap.add_argument('--fetch', metavar='DIR', help='download and verify PINNED_VERSION, unpack herdr-core into DIR, print its path and exit')
    ap.add_argument('-v', '--verbose', action='store_true')
    args = ap.parse_args()

    if args.print_pin:
        print(PINNED_VERSION)
        return 0
    if args.fetch:
        # The iOS lane's herdr-core E2E (scripts/run-ci-ios-tests.sh) takes its binary from here, so the pin
        # and its checksums stay in this file. Any failure is exit 2 with the reason on stderr: never a skip.
        try:
            os.makedirs(args.fetch, exist_ok=True)
            hc = download(PINNED_VERSION, False, args.fetch, lambda m: print(m, file=sys.stderr, flush=True))
            print('herdr-core fetched: %s' % check_binary(hc), file=sys.stderr, flush=True)
        except (SetupError, OSError) as exc:
            print('herdr-core fetch failed: %s' % exc, file=sys.stderr)
            return 2
        print(hc)
        return 0
    names = [n for n, _ in SCENARIOS]
    if args.list:
        for n, fn in SCENARIOS:
            print('%-24s %s' % (n, (fn.__doc__ or '').strip()))
        return 0
    chosen = SCENARIOS
    if args.only:
        want = [x.strip() for x in args.only.split(',') if x.strip()]
        unknown = [x for x in want if x not in names]
        if unknown:
            print('unknown scenario(s): %s (try --list)' % ', '.join(unknown), file=sys.stderr)
            return 2
        chosen = [(n, f) for n, f in SCENARIOS if n in want]

    reap_stale(lambda m: print(m, flush=True))
    work_root = tempfile.mkdtemp(prefix='hcc-', dir='/tmp')
    atexit.register(shutil.rmtree, work_root, True)

    def on_signal(signum, frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    try:
        try:
            if args.hc:
                hc = os.path.abspath(args.hc)
            else:
                bindir = os.path.join(work_root, 'dl')
                os.makedirs(bindir)
                hc = download(args.version or PINNED_VERSION, args.latest, bindir,
                              lambda m: print(m, flush=True))
            version = check_binary(hc)
        except SetupError as exc:
            print('setup failed: %s' % exc, file=sys.stderr)
            if args.warn:
                print('::warning::herdr-core contract setup failed: %s' % str(exc).replace('\n', '%0A'), flush=True)
            return 2
        print('herdr-core under test: %s (%s)' % (version, hc), flush=True)
        results = []
        for i, (name, fn) in enumerate(chosen, 1):
            outcome, secs = run_scenario(name, fn, hc, work_root, i, args)
            if outcome.get('ok'):
                print('PASS %s' % name, flush=True)
                results.append((name, 'PASS', secs, ''))
            else:
                reason = outcome.get('reason', 'unknown failure')
                print('FAIL %s: %s' % (name, reason), flush=True)
                if outcome.get('trace'):
                    print(outcome['trace'], flush=True)
                if args.warn:
                    print('::warning::herdr-core contract %s: %s' % (name, reason.replace('\n', '%0A')), flush=True)
                results.append((name, 'FAIL', secs, reason))
        print()
        print('%-28s %-5s %6s' % ('scenario', 'result', 'secs'))
        for name, res, secs, _ in results:
            print('%-28s %-6s %5.1fs' % (name, res, secs))
        failed = [r for r in results if r[1] == 'FAIL']
        print('%d passed, %d failed (core %s)' % (len(results) - len(failed), len(failed), version))
        if failed and not args.warn:
            return 1
        return 0
    finally:
        cleanup_all()
        shutil.rmtree(work_root, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
