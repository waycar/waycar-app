#!/usr/bin/env python3
"""Executable Zellij contract (Z1–Z16, docs/research/zellij-backend-2026-11.md).

Usage: zellij-contract.py [--zellij PATH | --version X.Y.Z | --latest] [--warn]
       zellij-contract.py --only pane_records,input -v
       zellij-contract.py --list | --print-pin | --fetch DIR

Default: download the pin, verify the extracted binary against both the release's
.sha256sum and the committed per-target hash, then run all scenarios. --latest
and unpinned versions trust the release checksum; --zellij trusts a local binary.
--fetch always fetches the pin for this platform and prints ONLY its path to stdout.

Each scenario owns a short /tmp/zjc-* root, HOME, XDG directories and socket dir.
No user config, environment, session or socket is inherited. Cleanup runs on every
exit (including signals); the next run reaps owned roots older than an hour after
SIGKILL. Only processes carrying an owned scratch path are signalled. Each scenario
has a 60 s wall budget. Assertion failures exit 1 (0 under --warn); setup failures
exit 2 even under --warn. Stdlib only, Python 3.8+, Linux and macOS.
"""
import argparse
import atexit
import base64
import fcntl
import hashlib
import io
import json
import os
import platform
import re
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tarfile
import tempfile
import termios
import threading
import time
import traceback
import urllib.request

PINNED_VERSION = '0.46.0'
# SHA-256 of the EXTRACTED binary, not the tarball. Independently downloaded all
# four assets and cross-checked their zellij-<target>.sha256sum files. Bump together.
PINNED_SHA256 = {
    'x86_64-unknown-linux-musl': 'afb6bfb5f9fdc3d9e9d094ce21866bc99d37073a5fbe75bb612e21fc9b96033d',
    'aarch64-unknown-linux-musl': '09cc9f60eb122987c10221fa559aa00c441333a23ba53d727c807f36c5222147',
    'aarch64-apple-darwin': '27be5b0489377217aa47633253c0e7a162fcebced02351f36e97bf7dff29acdc',
    'x86_64-apple-darwin': '60d2d5ff0c20fd0b0d03c76209cf3b55e224518d01797af62ae8469a1a458da3',
}
RELEASES = 'https://github.com/zellij-org/zellij/releases/'
SCENARIO_BUDGET = 60
STALE_SECONDS = 3600


class Fail(Exception):
    """An observed behavior differs from the contract."""


class SetupError(Exception):
    """Cannot run the contract, never downgraded by --warn."""


def expect(ok, message):
    if not ok:
        raise Fail(message)


def equal(got, want, label):
    expect(got == want, '%s: expected %r, got %r' % (label, want, got))


def wait_until(fn, label, timeout=10):
    end = time.monotonic() + timeout
    while True:
        result = fn()
        if result:
            return result
        if time.monotonic() >= end:
            raise Fail('timed out waiting for %s' % label)
        time.sleep(0.05)


def target_key():
    arch = {'x86_64': 'x86_64', 'amd64': 'x86_64', 'arm64': 'aarch64',
            'aarch64': 'aarch64'}.get(platform.machine().lower())
    suffix = {'Linux': 'unknown-linux-musl', 'Darwin': 'apple-darwin'}.get(platform.system())
    if not arch or not suffix:
        raise SetupError('no Zellij build for %s/%s' % (platform.system(), platform.machine()))
    return '%s-%s' % (arch, suffix)


def fetch(url):
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'waycar-zellij-contract/1'})
        with urllib.request.urlopen(req, timeout=60) as response:
            return response.read()
    except Exception as exc:
        raise SetupError('cannot fetch %s: %s' % (url, exc))


def download(version, latest, dest_dir, log, target=None):
    """target is injectable so all four committed binary hashes can be verified."""
    if latest:
        try:
            meta = json.loads(fetch('https://api.github.com/repos/zellij-org/zellij/releases/latest'))
            tag = meta['tag_name']
            if not isinstance(tag, str):
                raise SetupError('latest release tag is not a string')
            version = tag.lstrip('v')
        except (ValueError, KeyError, TypeError) as exc:
            raise SetupError('unusable latest release: %s' % exc)
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[\w.-]+)?', version):
        raise SetupError('invalid release version %r' % version)
    key = target or target_key()
    base = RELEASES + 'download/v%s/zellij-%s' % (version, key)
    try:
        checksum = fetch(base + '.sha256sum').decode('ascii').split()
    except UnicodeError as exc:
        raise SetupError('invalid checksum from %s: %s' % (base, exc))
    if not checksum or not re.fullmatch('[0-9a-fA-F]{64}', checksum[0]):
        raise SetupError('invalid checksum from %s.sha256sum' % base)
    log('downloading %s.tar.gz' % base)
    blob = fetch(base + '.tar.gz')
    try:
        with tarfile.open(fileobj=io.BytesIO(blob), mode='r:gz') as archive:
            members = archive.getmembers()
            for member in members:
                if member.name.startswith('/') or '..' in member.name.replace('\\', '/').split('/'):
                    raise SetupError('unsafe archive member %r' % member.name)
            candidates = [m for m in members if os.path.normpath(m.name) == 'zellij' and m.isfile()]
            if len(candidates) != 1:
                raise SetupError('archive must contain exactly one top-level zellij binary')
            binary = archive.extractfile(candidates[0]).read()
    except (tarfile.TarError, OSError) as exc:
        raise SetupError('cannot extract %s: %s' % (base, exc))
    got = hashlib.sha256(binary).hexdigest()
    if got != checksum[0].lower():
        raise SetupError('binary sha256 mismatch: release %s, downloaded %s' % (checksum[0], got))
    if version == PINNED_VERSION and got != PINNED_SHA256.get(key):
        raise SetupError('binary sha256 differs from PINNED_SHA256[%s]: %s' % (key, got))
    path = os.path.abspath(os.path.join(dest_dir, 'zellij'))
    with open(path, 'wb') as out:
        out.write(binary)
    os.chmod(path, 0o755)
    log('verified %s binary sha256 %s' % (key, got))
    return path


def check_binary(path):
    try:
        result = subprocess.run([path, '--version'], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError) as exc:
        raise SetupError('%s --version: %s' % (path, exc))
    if result.returncode or not re.fullmatch(r'zellij \d+\.\d+\.\d+(?:[^\n]*)', result.stdout.strip()):
        raise SetupError('unexpected --version: exit %s, %r' % (result.returncode, result.stdout + result.stderr))
    return result.stdout.strip()


def find_procs(root):
    """Only processes with our scratch path in argv or environment; never name-match."""
    found = []
    if os.path.isdir('/proc/self'):
        for name in os.listdir('/proc'):
            if not name.isdigit() or int(name) == os.getpid():
                continue
            for part in ('cmdline', 'environ'):
                try:
                    with open('/proc/%s/%s' % (name, part), 'rb') as src:
                        if root.encode() in src.read():
                            found.append(int(name))
                            break
                except OSError:
                    pass
    else:
        # macOS ps e includes HOME for daemonized servers and pane programs.
        out = subprocess.run(['ps', 'axeww', '-o', 'pid=,command='], capture_output=True,
                             text=True, timeout=10).stdout
        for line in out.splitlines():
            pid, _, command = line.strip().partition(' ')
            if pid.isdigit() and int(pid) != os.getpid() and root in command:
                found.append(int(pid))
    return found


def kill_owned(root):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in find_procs(root):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        end = time.monotonic() + 1
        while find_procs(root) and time.monotonic() < end:
            time.sleep(0.05)
    expect(not find_procs(root), 'owned processes survived cleanup: %s' % find_procs(root))


def reap_stale(log):
    for name in os.listdir('/tmp'):
        root = os.path.join('/tmp', name)
        if not name.startswith('zjc-') or os.path.islink(root) or not os.path.isdir(root):
            continue
        st = os.stat(root)
        if st.st_uid == os.getuid() and time.time() - st.st_mtime > STALE_SECONDS:
            kill_owned(root)
            shutil.rmtree(root)
            log('reaped stale %s' % root)


class PtyClient:
    """A real controlling PTY, continuously drained so renders cannot block Zellij."""
    def __init__(self, scratch, columns, rows, default_mode=None, preset=None):
        self.master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))

        def terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        argv = [scratch.zellij, 'attach', scratch.session]
        if default_mode:
            argv += ['options', '--default-mode', default_mode]
        if preset:
            argv += ['--keybinds-preset', preset]
        self.proc = subprocess.Popen(argv, stdin=slave, stdout=slave,
                                     stderr=slave, env=scratch.env, cwd=scratch.root,
                                     preexec_fn=terminal)
        os.close(slave)
        self.output = bytearray()
        self.last_output = time.monotonic()
        self.stopped = threading.Event()
        self.reader = threading.Thread(target=self._drain, daemon=True)
        self.reader.start()
        scratch.clients.append(self)

    def _drain(self):
        while not self.stopped.is_set():
            if not select.select([self.master], [], [], 0.1)[0]:
                continue
            try:
                data = os.read(self.master, 65536)
            except OSError:
                return
            if not data:
                return
            self.output.extend(data)
            self.last_output = time.monotonic()

    def send(self, data):
        expect(self.proc.poll() is None, 'PTY client exited: %r' % bytes(self.output[-500:]))
        os.write(self.master, data)

    def resize(self, columns, rows):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
        os.kill(self.proc.pid, signal.SIGWINCH)

    def close(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGHUP)
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.stopped.set()
        self.reader.join(timeout=1)
        os.close(self.master)


_live = []


class Scratch:
    def __init__(self, zellij, verbose):
        self.root = tempfile.mkdtemp(prefix='zjc-', dir='/tmp')
        self.zellij, self.verbose = zellij, verbose
        self.session = 'contract'
        self.clients = []
        self.processes = []
        self.env = {'PATH': '/usr/bin:/bin', 'SHELL': '/bin/sh', 'TERM': 'xterm-256color',
                    'LANG': 'C.UTF-8', 'HOME': self.root + '/home', 'TMPDIR': self.root + '/tmp',
                    'XDG_CONFIG_HOME': self.root + '/home/.config',
                    'XDG_CACHE_HOME': self.root + '/home/.cache',
                    'XDG_DATA_HOME': self.root + '/home/.local/share',
                    'XDG_STATE_HOME': self.root + '/home/.local/state',
                    'XDG_RUNTIME_DIR': self.root + '/run', 'ZELLIJ_SOCKET_DIR': self.root + '/sock'}
        for key, value in self.env.items():
            if key in ('HOME', 'TMPDIR', 'ZELLIJ_SOCKET_DIR') or key.startswith('XDG_'):
                os.makedirs(value, mode=0o700, exist_ok=True)
        os.makedirs(self.env['XDG_CONFIG_HOME'] + '/zellij')
        with open(self.env['XDG_CONFIG_HOME'] + '/zellij/config.kdl', 'w') as out:
            out.write('serialization_interval 1\nshow_startup_tips false\nshow_release_notes false\n')
        _live.append(self)

    def note(self, message):
        if self.verbose:
            print('  ' + message, flush=True)

    def cli(self, *args, **kw):
        result = subprocess.run([self.zellij] + list(map(str, args)), env=self.env, cwd=self.root,
                                capture_output=True, text=True, timeout=kw.get('timeout', 10))
        if kw.get('ok', True):
            equal(result.returncode, 0, '%s (stdout=%r stderr=%r)' % (args, result.stdout, result.stderr))
        return result

    def action(self, *args, **kw):
        return self.cli('-s', self.session, 'action', *args, **kw)

    def panes(self):
        return json.loads(self.action('list-panes', '-j').stdout)

    def tabs(self):
        return json.loads(self.action('list-tabs', '-j').stdout)

    def clients_table(self):
        lines = self.action('list-clients').stdout.splitlines()
        equal(lines[0].split(), ['CLIENT_ID', 'ZELLIJ_PANE_ID', 'RUNNING_COMMAND'], 'client table header')
        return {int(parts[0]): parts[1] for parts in (line.split() for line in lines[1:]) if parts}

    def start(self, command=None):
        started = time.monotonic()
        self.cli('attach', '-b', self.session, '--', *(command or ['/bin/sh', '-c', 'sleep 60']))
        empty_successes = 0

        def initialized():
            nonlocal empty_successes
            result = self.action('list-panes', '-j', timeout=max(0.1, 5 - (time.monotonic() - started)))
            # 0.46.0 can answer an early inventory call with exit 0, exactly
            # empty stdout. This is pending initialization, not an empty inventory.
            if result.stdout == '':
                empty_successes += 1
                return None
            return [p for p in json.loads(result.stdout) if not p['is_plugin']]

        records = wait_until(initialized, 'initial terminal within 5s', timeout=max(0, 5 - (time.monotonic() - started)))
        elapsed = time.monotonic() - started
        expect(elapsed <= 5, 'background inventory took %.3fs (expected <=5s)' % elapsed)
        self.note('attach -b: %s empty-success replies; records after %.3fs' % (empty_successes, elapsed))
        return records[0]

    def attach(self, columns=200, rows=50, default_mode=None, preset=None):
        before = len(self.clients_table())
        client = PtyClient(self, columns, rows, default_mode, preset)
        wait_until(lambda: len(self.clients_table()) == before + 1 and b'\x1b[?25' in client.output
                   and time.monotonic() - client.last_output >= 0.2, 'PTY rendered and quiet', timeout=5)
        return client

    def pane(self, pane_id):
        return next(p for p in self.panes() if not p['is_plugin'] and p['id'] == pane_id)

    def new_tab(self, name, command=None):
        result = self.action('new-tab', '--no-focus', '--name', name, '--cwd', self.root,
                             '--', *(command or ['/bin/sh', '-c', 'sleep 60']))
        expect(re.fullmatch(r'\d+\s*', result.stdout) is not None, 'new-tab id: %r' % result.stdout)
        return int(result.stdout)

    def new_pane(self, tab, command):
        result = self.action('new-pane', '--tab-id', tab, '--name', 'contract-pane', '--no-focus',
                             '--cwd', self.root, '--', *command)
        expect(re.fullmatch(r'terminal_\d+\s*', result.stdout) is not None, 'new-pane id: %r' % result.stdout)
        return int(result.stdout.strip().split('_')[1])

    def file(self, name, content):
        path = self.root + '/' + name
        with open(path, 'w') as out:
            out.write(content)
        return path

    def cleanup(self):
        try:
            for client in self.clients:
                client.close()
            for proc in self.processes:
                if proc.stdin and not proc.stdin.closed:
                    proc.stdin.close()
            # All CLI invocations carry this scratch's HOME and socket directory.
            listed = self.cli('ls', '-s', ok=False)
            for name in listed.stdout.splitlines():
                self.cli('kill-session', name, ok=False, timeout=3)
            kill_owned(self.root)
            for proc in self.processes:
                proc.wait(timeout=2)
                if proc.stdout:
                    proc.stdout.close()
                if proc.stderr:
                    proc.stderr.close()
        finally:
            shutil.rmtree(self.root, ignore_errors=True)
            _live.remove(self)


def cleanup_all():
    for scratch in list(_live):
        scratch.cleanup()


SCENARIOS = []


def scenario(name):
    def register(fn):
        SCENARIOS.append((name, fn))
        return fn
    return register


@scenario('cli_surface')
def cli_surface(s):
    """Z1/Z18: every subcommand and flag used by Waycar is available."""
    expect(re.fullmatch(r'zellij \d+\.\d+\.\d+', s.cli('--version').stdout.strip()), 'version format')
    config = s.cli('setup', '--dump-config').stdout
    for option in ('serialization_interval', 'show_startup_tips', 'show_release_notes'):
        expect(option in config, 'config missing %s' % option)
    surface = {
        'list-panes': ['-j'], 'list-tabs': ['-j'], 'list-clients': [],
        'dump-screen': ['--pane-id', '--full'], 'paste': ['--pane-id'],
        'write-chars': ['--pane-id'], 'send-keys': ['--pane-id'], 'close-pane': ['--pane-id'],
        'close-tab': ['--tab-id'], 'rename-pane': ['--pane-id'], 'rename-tab-by-id': ['<ID>', '<NAME>'],
        'new-tab': ['--no-focus', '--name', '--cwd', '<INITIAL_COMMAND>'],
        'new-pane': ['--tab-id', '--name', '--no-focus', '--cwd', '<COMMAND>'],
        'go-to-tab-by-id': ['<ID>'], 'focus-pane-id': ['<PANE_ID>'],
        'set-resurrect-command': ['--pane-id', '<COMMAND>'],
    }
    for name, flags in surface.items():
        help_text = s.cli('action', name, '--help').stdout
        for flag in flags:
            expect(flag in help_text, '%s help missing %s' % (name, flag))
    for name in ('kill-session', 'delete-session'):
        expect('SESSION' in s.cli(name, '--help').stdout, '%s session argument' % name)
    attach = s.cli('attach', '--help').stdout
    for token in ('-b', '[SESSION_NAME]', '[-- <INITIAL_COMMAND>...]'):
        expect(token in attach, 'attach help missing %s' % token)
    expect('--default-mode' in s.cli('attach', 'options', '--help').stdout, 'attach mode option')


def no_server(s):
    pids = find_procs(s.root)
    expect(not pids, 'read started owned processes: %s' % pids)


@scenario('detection_starts_nothing')
def detection_starts_nothing(s):
    """Z6: reads and failed actions do not start servers or sessions."""
    commands = [('ls',), ('ls', '-n'), ('ls', '-s'), ('action', 'list-panes', '-j'),
                ('-s', 'missing', 'action', 'list-panes', '-j'),
                ('-s', 'missing', 'subscribe', '-p', '1'), ('-s', 'missing', 'run', '--', 'true')]
    for args in commands:
        result = s.cli(*args, ok=False)
        equal(result.returncode, 1, 'missing session %s' % (args,))
        text = result.stdout + result.stderr
        expect('No active zellij sessions found.' in text or 'There is no active session!' in text
               or "Session 'missing' not found" in text, 'missing-session diagnostic: %r' % text)
        s.note('%s -> exit %s, %r' % (' '.join(args), result.returncode, text.strip()))
        no_server(s)
        equal(s.cli('ls', '-s', ok=False).stdout.strip(), '', 'no session created')


@scenario('pane_records')
def pane_records(s):
    """Z2/Z3: terminal/plugin JSON shape, tab shape and session/client tables."""
    s.start()
    s.attach()

    def with_plugins():
        records = s.panes()
        return records if any(p['is_plugin'] for p in records) else None

    records = wait_until(with_plugins, 'plugin and terminal panes')
    fields = {'id': int, 'is_plugin': bool, 'is_suppressed': bool, 'tab_id': int,
              'tab_position': int, 'tab_name': str, 'title': str,
              'terminal_command': (str, type(None)), 'exited': bool,
              'program_status': (list, type(None)), 'cursor_coordinates_in_pane': (list, type(None))}
    for p in records:
        for key, types in fields.items():
            expect(key in p and isinstance(p[key], types), '%s type in %r' % (key, p))
        # 0.46.0 plugins omit these fields; they are optional for plugins only.
        for key in ('pane_command', 'pane_cwd'):
            if p['is_plugin'] and key not in p:
                continue
            expect(key in p and isinstance(p[key], (str, type(None))), 'pane %s type' % key)
        expect(isinstance(p.get('attention'), dict) and isinstance(p['attention'].get('status'), str),
               'attention.status in %r' % p)
        if p['cursor_coordinates_in_pane'] is not None:
            expect(len(p['cursor_coordinates_in_pane']) == 2 and
                   all(type(v) is int for v in p['cursor_coordinates_in_pane']), 'cursor coordinate pair')
    for tab in s.tabs():
        for key, types in {'tab_id': int, 'position': int, 'name': str, 'viewport_columns': int,
                           'other_focused_clients': list}.items():
            expect(key in tab and isinstance(tab[key], types), 'tab %s type: %r' % (key, tab))
    expect(s.clients_table(), 'attached client missing')
    line = s.cli('ls', '-n').stdout.strip()
    expect(re.fullmatch(re.escape(s.session) + r' \[Created .+ ago\]', line), 'ls -n shape: %r' % line)
    s.note('terminal=%s; plugin=%s; ls=%r' %
           (next(p for p in records if not p['is_plugin']), next(p for p in records if p['is_plugin']), line))


@scenario('pane_env')
def pane_env(s):
    """Z11: pane programs inherit ZELLIJ=0, pane number and session name."""
    path = s.root + '/env'
    p = s.start(['/bin/sh', '-c', 'env > %s; sleep 60' % shlex.quote(path)])
    wait_until(lambda: os.path.exists(path) and os.path.getsize(path), 'pane environment')
    with open(path) as src:
        env = dict(line.rstrip('\n').split('=', 1) for line in src if '=' in line)
    for key, value in {'ZELLIJ': '0', 'ZELLIJ_PANE_ID': str(p['id']), 'ZELLIJ_SESSION_NAME': s.session}.items():
        equal(env.get(key), value, key)


@scenario('program_status')
def program_status(s):
    """Z9/Z10: OSC 7501 root/nested status; attention is not agent status."""
    fifo = s.root + '/status.fifo'
    os.mkfifo(fifo)
    program = s.file('status.py', 'import os, sys\nf = open(sys.argv[1])\nfor line in f:\n'
                     '    os.write(1, b"\\x1b]7501;" + line.strip().encode() + b"\\x1b\\\\")\n')
    p = s.start([sys.executable, program, fifo])
    writer = os.open(fifo, os.O_RDWR)
    try:
        def emit(text):
            os.write(writer, (text + '\n').encode())

        def root(state):
            return next((r for r in s.pane(p['id'])['program_status'] or []
                         if r['id'] is None and r['state'] == state), None)

        emit('state=working:app=fake')
        r = wait_until(lambda: root('Working'), 'root Working')
        for key in ('id', 'state', 'kind', 'progress', 'app', 'title', 'msg', 'updated_ms'):
            expect(key in r, 'program_status missing %s' % key)
        equal(r['app'], 'fake', 'status app')
        emit('state=done')
        wait_until(lambda: root('Done'), 'root Done')
        s.attach()
        wait_until(lambda: s.pane(p['id'])['attention']['status'] == 'Idle', 'viewed Done attention becomes Idle')
        expect(root('Done'), 'viewing cleared program_status Done')
        msg = base64.b64encode(b'approve fake').decode()
        emit('state=blocked:kind=permission:msg=' + msg)
        r = wait_until(lambda: root('Blocked'), 'root Blocked')
        equal(r['kind'], 'Permission', 'blocked kind')
        equal(r['msg'], 'approve fake', 'decoded message')
        emit('id=x:state=working:app=child')
        wait_until(lambda: any(r['id'] == 'x' and r['state'] == 'Working'
                              for r in s.pane(p['id'])['program_status']), 'nested record x')
        expect(root('Blocked'), 'nested record replaced root')
        emit('state=clear')
        wait_until(lambda: not any(r['id'] is None for r in s.pane(p['id'])['program_status'] or []), 'root clear')
    finally:
        os.close(writer)


@scenario('tab_sizes_and_attach_recipe')
def tab_sizes_and_attach_recipe(s):
    """Z7/Z8: production Normal+Ctrl-g recipe; desk unchanged and cat receives exact input."""
    a_bytes, b_bytes = s.root + '/a.bytes', s.root + '/b.bytes'

    def cat_command(path):
        # Raw, no echo: tee captures the exact bytes cat receives, and cat -v
        # makes any leaked control byte visible in dump-screen as well.
        return ['/bin/sh', '-c', 'stty raw -echo; tee %s | cat -v' % shlex.quote(path)]

    a = s.start(cat_command(a_bytes))
    desk = s.attach(200, 50)
    desk_id = max(s.clients_table())
    b = s.new_tab('B', cat_command(b_bytes))
    pane_b = wait_until(lambda: next((p for p in s.panes() if not p['is_plugin'] and p['tab_id'] == b), None), 'tab B pane')
    wait_until(lambda: os.path.exists(a_bytes) and os.path.exists(b_bytes), 'raw cat panes ready')
    a_id = a['tab_id']

    def received(path):
        with open(path, 'rb') as src:
            return src.read()

    def columns(tab):
        return next(t['viewport_columns'] for t in s.tabs() if t['tab_id'] == tab)

    def cat_screen():
        return s.action('dump-screen', '--pane-id', 'terminal_%s' % pane_b['id']).stdout.rstrip('\n')

    wait_until(lambda: columns(a_id) == 200, 'desk tab at 200 cols')
    for index, preset in enumerate(('default', 'unlock-first')):
        label = 'normal/%s + Ctrl g' % preset
        started = time.monotonic()
        phone = s.attach(600, 200, default_mode='normal', preset=preset)
        attach_seconds = time.monotonic() - started
        phone_id = max(s.clients_table())
        equal(columns(a_id), 200, label + ': oversized phone preserves desk size')
        # Negative control: phone has sent NO key, desk is last active.
        before_a = received(a_bytes)
        marker = ('desk-%s' % index).encode()
        desk.send(marker)
        wait_until(lambda: received(a_bytes) == before_a + marker, 'desk key processed')
        s.action('go-to-tab-by-id', b)
        wait_until(lambda: s.clients_table().get(desk_id) == 'terminal_%s' % pane_b['id'], 'negative control moves desk')
        equal(s.clients_table()[phone_id], 'terminal_%s' % a['id'], 'negative control leaves phone')
        s.action('go-to-tab-by-id', a_id)
        wait_until(lambda: s.clients_table().get(desk_id) == 'terminal_%s' % a['id'], 'desk restored')
        wait_until(lambda: time.monotonic() - phone.last_output >= 0.2, 'restore render quiet')
        output_before = len(phone.output)
        before_a, before_b = received(a_bytes), received(b_bytes)
        started = time.monotonic()
        phone.send(b'\x07')

        # Locked has just the lock hint, not Normal's SESSION/RESIZE hints.
        def locked_redraw():
            output = bytes(phone.output[output_before:])
            return b' LOCK ' in output and b' SESSION ' not in output

        wait_until(locked_redraw, label + ': Locked redraw', timeout=5)
        redraw_seconds = time.monotonic() - started
        wait_until(lambda: time.monotonic() - phone.last_output >= 0.2, 'Locked redraw + 200ms quiet')
        claim_seconds = time.monotonic() - started
        equal(received(a_bytes), before_a, label + ': claim byte did not reach pane A')
        equal(received(b_bytes), before_b, label + ': claim byte did not reach pane B')
        before = s.clients_table()
        s.action('go-to-tab-by-id', b)
        focus = s.action('focus-pane-id', 'terminal_%s' % pane_b['id'], ok=False)
        equal((focus.returncode, focus.stderr.strip()),
              (2, 'Pane Terminal(%s) is already focused' % pane_b['id']), 'already-focused diagnostic')
        wait_until(lambda: s.clients_table().get(phone_id) == 'terminal_%s' % pane_b['id'], 'phone on target pane')
        equal(s.clients_table()[desk_id], before[desk_id], label + ': desk focus unchanged')
        # Exercise normal typing before AND after the final phone-sized resize.
        expected = before_b + b'x\r'
        phone.send(b'x\r')
        wait_until(lambda: received(b_bytes) == expected, label + ': cat receives x CR exactly')
        wait_until(lambda: cat_screen() == expected.replace(b'\r', b'^M').decode(), 'cat renders x CR exactly')
        phone.resize(80, 30)
        wait_until(lambda: columns(b) == 80, 'phone tab at 80 cols')
        equal(columns(a_id), 200, label + ': desk tab remains at 200 cols')
        expected += b'x\r'
        phone.send(b'x\r')
        wait_until(lambda: received(b_bytes) == expected, label + ': post-resize x CR delivered exactly')
        wait_until(lambda: cat_screen() == expected.replace(b'\r', b'^M').decode(), 'post-resize cat output exact')
        equal(received(a_bytes), before_a, label + ': desk received no phone input')
        equal(s.clients_table()[desk_id], before[desk_id], label + ': desk still untouched')
        s.note('%s: attach-ready %.3fs; redraw %.3fs; claim + quiet %.3fs; no leakage; exact typing before/after resize' %
               (label, attach_seconds, redraw_seconds, claim_seconds))
        phone.close()
        s.clients.remove(phone)
        wait_until(lambda: phone_id not in s.clients_table(), 'phone detached')


@scenario('claim_mode_input')
def claim_mode_input(s):
    """Z8 finding: Session+Esc / Locked+Ctrl-g claim, but ensuing Normal mode swallows typing."""
    data = s.root + '/claim.bytes'
    reader = s.file('claim-reader.py', 'import os, sys, tty\ntty.setraw(0)\n'
                    'with open(sys.argv[1], "ab", buffering=0) as f:\n'
                    '    while True:\n        f.write(os.read(0, 4096))\n')
    s.start([sys.executable, reader, data])
    wait_until(lambda: os.path.exists(data), 'claim reader ready')
    for mode, key, preset in [('session', b'\x1b', 'default'), ('locked', b'\x07', 'default'),
                              ('locked', b'\x07', 'unlock-first')]:
        phone = s.attach(600, 200, default_mode=mode, preset=preset)
        output_before = len(phone.output)
        started = time.monotonic()
        phone.send(key)
        # No follow-up key while the bare Esc is pending: it needs about 1s
        # on this PTY (no host-query responses), unlike Ctrl-g's ~50ms redraw.
        wait_until(lambda: b' SESSION ' in bytes(phone.output[output_before:]), 'legacy claim Normal redraw', timeout=5)
        seconds = time.monotonic() - started
        expect(0.8 <= seconds < 2 if mode == 'session' else seconds < 0.75, 'legacy claim timing changed: %.3fs' % seconds)
        equal(os.path.getsize(data), 0, 'legacy claim byte leaked into pane')
        phone.send(b'x')
        end = time.monotonic() + 0.3
        while time.monotonic() < end:
            equal(os.path.getsize(data), 0, 'legacy Normal input-drop bug changed; revisit recipe')
            time.sleep(0.02)
        s.note('%s/%s: claim %.3fs; no claim leakage; subsequent x swallowed' % (mode, preset, seconds))
        phone.close()
        s.clients.remove(phone)


@scenario('input')
def input_scenario(s):
    """Z12: unbracketed/bracketed paste, key names, unknown keys and leading dash."""
    p = s.start(['/bin/sh', '-c', 'exec cat -v'])
    target = 'terminal_%s' % p['id']
    s.action('paste', '--pane-id', target, 'A\nB')

    def pasted_screen():
        text = s.action('dump-screen', '--pane-id', target).stdout
        return text if 'A' in text and 'B' in text else None

    screen = wait_until(pasted_screen, 'cat paste')
    expect('^[[200~' not in screen and '^[[201~' not in screen, 'cat received paste brackets: %r' % screen)
    s.action('paste', '--pane-id', target, '--', '-dash')
    wait_until(lambda: '-dash' in s.action('dump-screen', '--pane-id', target).stdout, 'leading-dash paste')
    s.action('write-chars', '--pane-id', target, '--', '-write')
    wait_until(lambda: '-write' in s.action('dump-screen', '--pane-id', target).stdout, 'leading-dash write-chars')
    ready, data = s.root + '/ready', s.root + '/bytes'
    reader = s.file('reader.py', 'import os, sys, tty\ntty.setraw(0)\nos.write(1, b"\\x1b[?2004h")\n'
                    'open(sys.argv[1], "w").close()\nwith open(sys.argv[2], "ab", buffering=0) as f:\n'
                    '    while True:\n        f.write(os.read(0, 4096))\n')
    pane_id = s.new_pane(p['tab_id'], [sys.executable, reader, ready, data])
    wait_until(lambda: os.path.exists(ready), 'bracketed reader ready')
    target = 'terminal_%s' % pane_id

    def received():
        if not os.path.exists(data):
            return b''
        with open(data, 'rb') as src:
            return src.read()

    s.action('paste', '--pane-id', target, '--', '-A\nB')
    wait_until(lambda: received() == b'\x1b[200~-A\nB\x1b[201~', 'exact bracketed paste')
    keymap = [('Enter', b'\r'), ('Esc', b'\x1b'), ('Tab', b'\t'), ('Shift Tab', b'\x1b[Z'),
              ('Ctrl c', b'\x03'), ('Alt b', b'\x1bb'), ('F1', b'\x1bOP'), ('+', b'+')]
    expected = received()
    for key, value in keymap:
        s.action('send-keys', '--pane-id', target, key)
        expected += value
        wait_until(lambda: received() == expected, 'key %r bytes %r (got %r)' % (key, value, received()))
    unknown = s.action('send-keys', '--pane-id', target, 'NotAKey', ok=False)
    equal(unknown.returncode, 2, 'unknown key exit status')
    expect('Invalid key at position 1: "NotAKey"' in unknown.stdout + unknown.stderr and
           'Error: unsupported key' in unknown.stdout + unknown.stderr, 'unknown key diagnostic')
    s.note('unknown key -> exit %s, %r' % (unknown.returncode, (unknown.stdout + unknown.stderr).strip()))
    s.note('leading dash syntax: action paste/write-chars --pane-id terminal_N -- -text')


@scenario('new_tab_needs_a_client')
def new_tab_needs_a_client(s):
    """Z13/Z14: headless new-tab lies; tagged client launch and headless new-pane work."""
    initial = s.start()
    tag = 'WAYCAR_LAUNCH=headless-tab'
    tab = s.new_tab('headless', ['env', tag, '/bin/sh', '-c', 'sleep 60'])
    # A following inventory call is ordered after new-tab; observe a short negative window too.
    end = time.monotonic() + 1
    while time.monotonic() < end:
        expect(not any(tag in (p['terminal_command'] or '') for p in s.panes()),
               'headless new-tab now creates its command (Z14 bug fixed; revisit launch path)')
        time.sleep(0.05)
    s.note('headless new-tab -> exit 0, id %s, no tagged pane' % tab)
    p = s.new_pane(initial['tab_id'], ['env', 'WAYCAR_LAUNCH=headless-pane', '/bin/sh', '-c', 'sleep 60'])
    wait_until(lambda: 'WAYCAR_LAUNCH=headless-pane' in (s.pane(p)['terminal_command'] or ''), 'headless new-pane')
    s.attach()
    tab = s.new_tab('attached', ['env', 'WAYCAR_LAUNCH=attached', '/bin/sh', '-c', 'sleep 60'])
    wait_until(lambda: any(not p['is_plugin'] and p['tab_id'] == tab and 'WAYCAR_LAUNCH=attached' in
                          (p['terminal_command'] or '') for p in s.panes()), 'attached tagged pane')


@scenario('background_session_with_command')
def background_session_with_command(s):
    """Z14: attach -b -- cmd starts a background command in under two seconds."""
    marker = s.root + '/ran'
    line = 'printf background-ok > %s; sleep 60' % shlex.quote(marker)
    start = time.monotonic()
    s.start(['/bin/sh', '-c', line])
    wait_until(lambda: os.path.exists(marker), 'background command', timeout=2)
    elapsed = time.monotonic() - start
    expect(elapsed < 2, 'background creation took %.3fs (expected <2s)' % elapsed)
    expect(any(line in (p['terminal_command'] or '') for p in s.panes()), 'terminal_command lost launch line')
    s.note('background creation and command: %.3fs' % elapsed)


@scenario('closed_sessions')
def closed_sessions(s):
    """Z6/Z15: serialization, resurrect override, kill/list/delete never auto-resurrect."""
    p = s.start()
    s.action('set-resurrect-command', '--pane-id', 'terminal_%s' % p['id'], '--', '/bin/sh', '-c', 'echo resurrect-tag')

    def saved():
        for root, _, files in os.walk(s.env['XDG_CACHE_HOME']):
            for name in files:
                if name.endswith('.kdl'):
                    with open(os.path.join(root, name)) as src:
                        text = src.read()
                    if 'resurrect-tag' in text:
                        return text
        return None

    layout = wait_until(saved, 'serialized resurrect command', timeout=15)
    expect('start_suspended true' in layout, 'saved layout does not suspend command')
    s.cli('kill-session', s.session)
    wait_until(lambda: not find_procs(s.root), 'server stopped')
    line = s.cli('ls', '-n').stdout.strip()
    expect(re.fullmatch(re.escape(s.session) + r' \[Created .+ ago\] \(EXITED - attach to resurrect\)', line),
           'closed session shape: %r' % line)
    for args in [('ls',), ('ls', '-s'), ('-s', s.session, 'action', 'list-panes', '-j'),
                 ('-s', s.session, 'subscribe', '-p', '1'), ('-s', s.session, 'run', '--', 'true')]:
        result = s.cli(*args, ok=False)
        equal(result.returncode, 0 if args[0] == 'ls' else 1, 'closed read %r' % (args,))
        s.note('closed %s -> exit %s, %r' % (' '.join(args), result.returncode,
                                           (result.stdout + result.stderr).strip()))
        no_server(s)
    s.cli('delete-session', s.session)
    equal(s.cli('ls', '-n', ok=False).returncode, 1, 'no sessions after delete')
    expect(not saved(), 'delete-session retained saved resurrect layout')
    no_server(s)


# Reference POSIX loop: a verbatim copy of the body of
# Sources/Waycar/Transport/Zellij/ZellijWatchCommand.swift (design section 4),
# with Z and D taken from the arguments. Keep it in sync when that file changes.
# 0.46.0 prints -j pretty (multi-line), so each session's output is folded first;
# ages become a fixed ` [Created]` placeholder; stdin EOF ends the whole process
# group with `kill 0`, an in-flight zellij call included.
WATCH_LOOP = r'''
Z=$1; D=$2; LC_ALL=C; export LC_ALL
(
  tick=
  trap '[ -z "$tick" ] || { kill "$tick" 2>/dev/null; wait "$tick" 2>/dev/null; }; exit 0' TERM INT
  prev=
  while :; do
    ls=$("$Z" ls -n 2>/dev/null | grep -v '[[:cntrl:]]' | grep -v '^-' | sed -n \
      -e 's/^\(.*\) \[Created [^]][^]]* ago\] (current) *$/\1 [Created] (current)/p' \
      -e 's/^\(.*\) \[Created [^]][^]]* ago\] (EXITED - attach to resurrect) *$/\1 [Created] (EXITED - attach to resurrect)/p' \
      -e 's/^\(.*\) \[Created [^]][^]]* ago\] *$/\1 [Created]/p')
    live=$(printf '%s\n' "$ls" | grep -v ' \[Created\] (EXITED - attach to resurrect) *$' | sed 's/ \[Created\]\( (current)\)\{0,1\} *$//' | grep -v '^$')
    count=$(printf '%s\n' "$live" | grep -c .)
    out=$(printf '%s\n' "$ls"; printf '\036P\n'
      printf '%s\n' "$live" | while IFS= read -r s; do
        [ -n "$s" ] || continue
        printf '\036S%s\n' "$s"
        "$Z" -s "$s" action list-panes -j 2>/dev/null | tr -d '\012\015' | sed \
          -e 's/,[[:space:]]*"cursor_coordinates_in_pane":[[:space:]]*null//g' \
          -e 's/,[[:space:]]*"cursor_coordinates_in_pane":[[:space:]]*\[[[:space:]]*[0-9]*,[[:space:]]*[0-9]*[[:space:]]*\]//g' \
          -e 's/"cursor_coordinates_in_pane":[[:space:]]*null,[[:space:]]*//g' \
          -e 's/"cursor_coordinates_in_pane":[[:space:]]*\[[[:space:]]*[0-9]*,[[:space:]]*[0-9]*[[:space:]]*\],[[:space:]]*//g'
        printf '\n'
      done
      printf '\036H\n'
      for f in "$D"/*.json; do [ ! -f "$f" ] || { cat "$f"; printf '\n'; }; done)
    if [ "$out" != "$prev" ]; then
      printf '\036B\n%s\n\036E\n' "$out"; prev=$out
    else
      printf '\n'
    fi
    delay=1; [ "$count" -le 4 ] || delay=2
    sleep "$delay" </dev/null >/dev/null 2>&1 & tick=$!
    wait "$tick"; tick=
  done
) </dev/null &
cat >/dev/null
kill 0
'''


class Lines:
    def __init__(self, proc):
        self.proc, self.buf = proc, b''

    def line(self, timeout=5):
        end = time.monotonic() + timeout
        while b'\n' not in self.buf:
            remaining = end - time.monotonic()
            expect(remaining > 0 and select.select([self.proc.stdout], [], [], max(0, remaining))[0], 'watch output timeout')
            data = os.read(self.proc.stdout.fileno(), 65536)
            expect(data, 'watch EOF before expected output')
            self.buf += data
        line, _, self.buf = self.buf.partition(b'\n')
        return line

    def frame(self):
        wait_until(lambda: self.line() == b'\x1eB', 'watch frame start')
        result = []
        while True:
            line = self.line()
            if line == b'\x1eE':
                return b'\n'.join(result)
            result.append(line)


@scenario('watch_loop')
def watch_loop(s):
    """Design §4: first/changed frames, blank heartbeat and EOF kills entire loop tree."""
    s.start()
    s.attach()
    path = s.file('watch.sh', WATCH_LOOP)
    state_dir = os.path.join(s.env['HOME'], '.local', 'state', 'waycar', 'zellij')
    proc = subprocess.Popen(['/bin/sh', path, s.zellij, state_dir], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=s.env, cwd=s.root, bufsize=0, start_new_session=True)
    s.processes.append(proc)
    lines = Lines(proc)
    first = lines.frame()
    expect(b'\x1eP\n' in first and b'\x1eScontract\n' in first and b'\x1eH' in first, 'watch frame sections')
    expect(b'cursor_coordinates_in_pane' not in first, 'watch retained cursor')
    wait_until(lambda: lines.line() == b'', 'unchanged newline heartbeat', timeout=15)
    s.new_tab('watch-change')
    changed = lines.frame()
    expect(changed != first and b'watch-change' in changed, 'tab change did not produce new frame')
    # Record only this loop's process group: the separately started session stays live.
    group = proc.pid
    start = time.monotonic()
    proc.stdin.close()
    proc.wait(timeout=1.5)

    def group_gone():
        try:
            os.killpg(group, 0)
            return False
        except ProcessLookupError:
            return True

    wait_until(group_gone, 'watch process group gone (including zellij/sleep)', timeout=max(0, 1.5 - (time.monotonic() - start)))
    expect(time.monotonic() - start < 1.5, 'watch EOF cleanup exceeded 1.5 seconds')
    # `kill 0` ends the shell itself by SIGTERM; sshd reports that as the exec's end.
    expect(proc.returncode in (0, -signal.SIGTERM), 'watch exit %r' % proc.returncode)


def run_scenario(name, fn, zellij, args):
    scratch = Scratch(zellij, args.verbose)
    start = time.monotonic()
    outcome = {}

    def budget(signum, frame):
        raise Fail('timed out after %ss' % SCENARIO_BUDGET)

    previous = signal.signal(signal.SIGALRM, budget)
    signal.alarm(SCENARIO_BUDGET)
    try:
        fn(scratch)
        outcome['ok'] = True
    except Exception as exc:
        outcome['reason'] = '%s: %s' % (type(exc).__name__, exc)
        if args.verbose:
            outcome['trace'] = traceback.format_exc()
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        try:
            scratch.cleanup()
        except Exception as exc:
            outcome = {'reason': 'cleanup failed: %s' % exc}
    return outcome, time.monotonic() - start


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = ap.add_mutually_exclusive_group()
    source.add_argument('--zellij', metavar='PATH', help='trust this local binary')
    source.add_argument('--version', metavar='X.Y.Z', help='download release (default: %s)' % PINNED_VERSION)
    source.add_argument('--latest', action='store_true', help='download the newest GitHub release')
    ap.add_argument('--warn', action='store_true', help='annotate scenario failures, exit 0 (setup still exits 2)')
    ap.add_argument('--only', metavar='NAME[,NAME]')
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--print-pin', action='store_true')
    ap.add_argument('--fetch', metavar='DIR', help='download/verify the pin, print binary path only')
    ap.add_argument('-v', '--verbose', action='store_true')
    args = ap.parse_args()
    if args.print_pin:
        print(PINNED_VERSION)
        return 0
    if args.list:
        for name, fn in SCENARIOS:
            print('%-32s %s' % (name, fn.__doc__))
        return 0
    selected = SCENARIOS
    if args.only:
        wanted = [name.strip() for name in args.only.split(',') if name.strip()]
        unknown = set(wanted) - {name for name, _ in SCENARIOS}
        if unknown or not wanted:
            print('unknown/empty scenario selection: %s (try --list)' % ', '.join(sorted(unknown)), file=sys.stderr)
            return 2
        selected = [(name, fn) for name, fn in SCENARIOS if name in wanted]
    if args.fetch:
        try:
            os.makedirs(args.fetch, exist_ok=True)
            path = download(PINNED_VERSION, False, args.fetch, lambda msg: print(msg, file=sys.stderr, flush=True))
            print('Zellij fetched: %s' % check_binary(path), file=sys.stderr)
            print(path)
            return 0
        except (SetupError, OSError) as exc:
            print('Zellij fetch failed: %s' % exc, file=sys.stderr)
            return 2
    reap_stale(lambda msg: print(msg, flush=True))
    atexit.register(cleanup_all)

    def on_signal(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    with tempfile.TemporaryDirectory(prefix='zjc-', dir='/tmp') as work:
        try:
            path = os.path.abspath(args.zellij) if args.zellij else download(
                args.version or PINNED_VERSION, args.latest, work, lambda msg: print(msg, flush=True))
            version = check_binary(path)
        except (SetupError, OSError) as exc:
            print('setup failed: %s' % exc, file=sys.stderr)
            if args.warn:
                print('::warning::Zellij contract setup failed: %s' % str(exc).replace('\n', '%0A'))
            return 2
        print('Zellij under test: %s (%s)' % (version, path), flush=True)
        results = []
        try:
            for name, fn in selected:
                outcome, secs = run_scenario(name, fn, path, args)
                result = 'PASS' if outcome.get('ok') else 'FAIL'
                reason = outcome.get('reason', '')
                print('%s %s%s' % (result, name, ': ' + reason if reason else ''), flush=True)
                if outcome.get('trace'):
                    print(outcome['trace'], flush=True)
                if reason and args.warn:
                    print('::warning::Zellij contract %s: %s' % (name, reason.replace('\n', '%0A')), flush=True)
                results.append((name, result, secs))
        finally:
            cleanup_all()
        print('\n%-34s %-6s %s' % ('scenario', 'result', 'secs'))
        for name, result, secs in results:
            print('%-34s %-6s %.1fs' % (name, result, secs))
        failed = sum(result == 'FAIL' for _, result, _ in results)
        print('%s passed, %s failed (%s)' % (len(results) - failed, failed, version))
        return 1 if failed and not args.warn else 0


if __name__ == '__main__':
    sys.exit(main())
