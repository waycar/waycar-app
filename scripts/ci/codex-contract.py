#!/usr/bin/env python3
"""Real Codex shared-daemon contract; Python stdlib + Node 26, no credentials.

--list; --only detection,websocket -v; --latest --warn; --print-pin;
--fetch DIR downloads the complete pinned npm package (not a bare executable)
and prints its executable wrapper path. Only npm registry artifacts are fetched.
Pinned artifacts require the committed SHA256 below; latest trusts npm integrity.

All application state and environments are scratch /tmp/ccc-* directories.
Exception imposed by Codex: physical sockets are /tmp/codex-daemon-<uid>/<hash>.
The hash covers the canonical scratch CODEX_HOME rendezvous path. We verify it
and remove ONLY that exact endpoint, never the shared directory or other sockets.
Lifecycle locks are inside CODEX_HOME; a physical startup lock is beside the
hashed socket. Stale runs (>1h) are reaped.
Cleanup covers normal exits, SIGINT and SIGTERM, not SIGKILL. --fetch output is
caller-owned and retained. --warn annotates observed drift and exits 0; preparation
errors still exit 2. Every scenario is independent, real and skip-free.
"""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import pty
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import traceback
import urllib.request

PINNED_VERSION = '0.167.1'
PINNED_SHA256 = {
    'cli': 'a5b60ca409e06544c15ce03aca7c2f7e4082e220383a2e57700e42a0c6830b03',
    'linux-x64': '944cbabe58a2c599a30141bc0220c31963205c33e69b43b414dd5da6adaf957f',
    'darwin-arm64': '402f0e6678eef2842ce669da71f54c44ed4743f659527beb18185ef17306b154',
}
REGISTRY = 'https://registry.npmjs.org/'
BUDGET = 40
REPO = Path(__file__).resolve().parents[2]
VERBOSE = False


class Fail(Exception):
    """Observed contract drift."""


class SetupError(Exception):
    """Unable to prepare the pinned application; never downgraded to success."""


def require(value, message):
    if not value:
        raise Fail(message)


def until(check, description, seconds=BUDGET):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise Fail('timed out: ' + description)


def fetch(url):
    if not url.startswith(REGISTRY):
        raise SetupError('download outside npm registry: ' + url)
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(url, timeout=90) as response:
            return response.read()
    except Exception as exc:
        raise SetupError('fetch %s: %s' % (url, exc)) from exc


def _download(dest, latest=False):
    system = {'Linux': 'linux', 'Darwin': 'darwin'}.get(platform.system())
    arch = {'x86_64': 'x64', 'amd64': 'x64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine())
    target = '%s-%s' % (system, arch)
    if target not in PINNED_SHA256:
        raise SetupError('no pinned package for ' + target)
    version = json.loads(fetch(REGISTRY + '@openai/codex/latest'))['version'] if latest else PINNED_VERSION
    dest = Path(dest).resolve()
    dest.mkdir(parents=True, exist_ok=True)
    package = dest / 'codex'
    if package.exists():
        raise SetupError('refusing to overwrite ' + str(package))
    package.mkdir()
    for kind in ('cli', target):
        release = version + ('-' + kind if kind != 'cli' else '')
        metadata = json.loads(fetch(REGISTRY + '@openai/codex/' + release))
        blob = fetch(metadata['dist']['tarball'])
        digest = hashlib.sha256(blob).hexdigest()
        if not latest and digest != PINNED_SHA256[kind]:
            raise SetupError('%s sha256: expected %s, got %s' % (kind, PINNED_SHA256[kind], digest))
        integrity = 'sha512-' + base64.b64encode(hashlib.sha512(blob).digest()).decode()
        if integrity != metadata['dist']['integrity']:
            raise SetupError(kind + ' npm integrity mismatch')
        # Assemble npm's supported local vendor layout without npm install scripts.
        # Only regular files/directories: no archive links or path traversal.
        with tarfile.open(fileobj=io.BytesIO(blob), mode='r:gz') as archive:
            for member in archive:
                parts = Path(member.name).parts
                if not parts or parts[0] != 'package' or '..' in parts or not (member.isfile() or member.isdir()):
                    raise SetupError('unsafe archive member: ' + member.name)
                relative = Path(*parts[1:])
                if kind != 'cli' and (not relative.parts or relative.parts[0] != 'vendor'):
                    continue
                path = package / relative
                if member.isdir():
                    path.mkdir(parents=True, exist_ok=True)
                else:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as source, path.open('wb') as out:
                        shutil.copyfileobj(source, out)
                    path.chmod(0o755 if member.mode & 0o111 else 0o644)
    return package / 'bin/codex.js', version


def download(dest, latest=False):
    """Stage atomically: checksum/setup failures leave no partial package."""
    dest = Path(dest).resolve()
    dest.mkdir(parents=True, exist_ok=True)
    package = dest / 'codex'
    if package.exists() or package.is_symlink():
        raise SetupError('refusing to overwrite ' + str(package))
    with tempfile.TemporaryDirectory(prefix='.download-', dir=dest) as stage:
        try:
            _, version = _download(stage, latest)
        except SetupError:
            raise
        except (OSError, ValueError, KeyError, tarfile.TarError) as exc:
            raise SetupError('invalid npm package: ' + str(exc)) from exc
        (Path(stage) / 'codex').rename(package)
    return package / 'bin/codex.js', version


def processes(root):
    """Only processes carrying this unique scratch directory, never a name/port."""
    found = set()
    if Path('/proc/self').exists():
        for proc in Path('/proc').iterdir():
            if proc.name.isdigit() and int(proc.name) != os.getpid():
                for part in ('cmdline', 'environ'):
                    try:
                        if os.fsencode(root) in (proc / part).read_bytes():
                            found.add(int(proc.name))
                    except OSError:
                        pass
    else:
        # macOS ps e includes the environment, needed for detached descendants.
        output = subprocess.run(['ps', 'eww', '-axo', 'pid=,command='], capture_output=True,
                                text=True, timeout=15, check=True).stdout
        for line in output.splitlines():
            pid, _, command = line.strip().partition(' ')
            if pid.isdigit() and int(pid) != os.getpid() and str(root) in command:
                found.add(int(pid))
    return found


def physical_socket(root):
    alias = (root / 'c/app-server-control').resolve() / 'app-server-control.sock'
    digest = hashlib.sha256(os.fsencode(alias)).hexdigest()
    return Path('/tmp').resolve() / ('codex-daemon-%d' % os.geteuid()) / digest


def remove_scratch(root):
    # Includes orphaned managed daemon, TUI and model children, but no caller
    # process: the root is randomly generated internally, never a CLI argument.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in processes(root):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        time.sleep(0.1)
    target = physical_socket(root)
    for path in (target, target.with_suffix('.lock')):
        if path.exists() or path.is_symlink():
            path.unlink()
    shutil.rmtree(root)


def reap_stale():
    for root in Path('/tmp').glob('ccc-*'):
        info = root.lstat()
        if stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and time.time() - info.st_mtime > 3600:
            remove_scratch(root)
            print('reaped stale ' + str(root), file=sys.stderr)


class WebSocket:
    """Minimal RFC 6455 client on AF_UNIX, including interleaved control frames."""
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(BUDGET)
        self.sock.connect(str(path))
        self.buffer = b''
        self.fragment = bytearray()
        self.fragmenting = False
        self.pending = []
        self.serial = 0
        self.seen = []
        self.pongs = []
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                           'Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n'
                           'Sec-WebSocket-Version: 13\r\n\r\n' % key).encode())
        while b'\r\n\r\n' not in self.buffer:
            block = self.sock.recv(4096)
            require(block, 'WebSocket EOF during upgrade')
            self.buffer += block
            require(len(self.buffer) < 65536, 'oversized WebSocket handshake')
        header, self.buffer = self.buffer.split(b'\r\n\r\n', 1)
        lines = header.decode().split('\r\n')
        self.headers = {name.lower(): value.strip() for name, value in (line.split(':', 1) for line in lines[1:])}
        require(lines[0] == 'HTTP/1.1 101 Switching Protocols', 'upgrade: ' + lines[0])
        want = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        require(self.headers.get('sec-websocket-accept') == want, 'Sec-WebSocket-Accept mismatch')
        require('sec-websocket-extensions' not in self.headers, 'unsolicited WebSocket extension')

    def frame(self, opcode, payload, final=True):
        mask = os.urandom(4)
        length = len(payload)
        size = bytes([length | 128]) if length < 126 else (b'\xfe' + struct.pack('!H', length) if length < 65536 else b'\xff' + struct.pack('!Q', length))
        self.sock.sendall(bytes([(128 if final else 0) | opcode]) + size + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def send(self, value):
        self.frame(1, json.dumps(value).encode())

    def exact(self, count):
        while len(self.buffer) < count:
            block = self.sock.recv(max(4096, count - len(self.buffer)))
            if not block:
                raise Fail('WebSocket EOF')
            self.buffer += block
        value, self.buffer = self.buffer[:count], self.buffer[count:]
        return value

    def receive(self, seconds=BUDGET):
        deadline = time.monotonic() + seconds
        while True:
            self.sock.settimeout(max(0.001, deadline - time.monotonic()))
            a, b = self.exact(2)
            opcode, final = a & 15, bool(a & 128)
            require(not a & 112 and not b & 128, 'server frames must be unmasked, no RSV bits')
            count = b & 127
            if count == 126:
                count = struct.unpack('!H', self.exact(2))[0]
            elif count == 127:
                count = struct.unpack('!Q', self.exact(8))[0]
            require(count <= 32 * 1024 * 1024, 'oversized frame')
            payload = self.exact(count)
            if opcode >= 8:
                require(final and count <= 125, 'invalid control frame')
                if opcode == 9:
                    self.frame(10, payload)
                elif opcode == 10:
                    self.pongs.append(payload)
                elif opcode == 8:
                    self.frame(8, payload)
                    raise Fail('WebSocket close: %r' % payload)
                else:
                    raise Fail('unknown control opcode %d' % opcode)
                continue
            if opcode == 1:
                require(not self.fragmenting, 'new text frame during fragmentation')
                self.fragment = bytearray(payload)
                self.fragmenting = not final
            elif opcode == 0:
                require(self.fragmenting, 'unexpected continuation')
                self.fragment.extend(payload)
                self.fragmenting = not final
            else:
                raise Fail('expected text frame, got opcode %d' % opcode)
            if final:
                value = json.loads(self.fragment.decode())
                require(isinstance(value, dict) and 'jsonrpc' not in value, 'wire envelope changed: %r' % value)
                self.seen.append(value)
                if VERBOSE:
                    print('    ' + json.dumps(value)[:3000])
                return value

    def wait(self, predicate, description, seconds=BUDGET):
        for index, value in enumerate(self.pending):
            if predicate(value):
                return self.pending.pop(index)
        deadline = time.monotonic() + seconds
        try:
            while time.monotonic() < deadline:
                value = self.receive(deadline - time.monotonic())
                if predicate(value):
                    return value
                self.pending.append(value)
        except socket.timeout:
            pass
        raise Fail('timed out: ' + description + '; pending=' + json.dumps(self.pending)[-4000:])

    def request(self, method, params=None, **extra):
        self.serial += 1
        identifier = 'ccc-%d' % self.serial
        self.send(dict({'id': identifier, 'method': method, 'params': params or {}}, **extra))
        return self.wait(lambda msg: msg.get('id') == identifier and 'method' not in msg, method)

    def call(self, method, params=None, **extra):
        response = self.request(method, params, **extra)
        require('error' not in response, '%s: %s' % (method, json.dumps(response)))
        return response['result']

    def event(self, method, thread=None, seconds=BUDGET):
        return self.wait(lambda msg: msg.get('method') == method and (thread is None or
                         msg.get('params', {}).get('threadId') == thread or
                         msg.get('params', {}).get('thread', {}).get('id') == thread), method, seconds)

    def quiet(self, forbidden, seconds=0.4):
        deadline = time.monotonic() + seconds
        try:
            while time.monotonic() < deadline:
                self.pending.append(self.receive(deadline - time.monotonic()))
        except socket.timeout:
            pass
        bad = [msg for msg in self.pending if forbidden(msg)]
        require(not bad, 'unexpected messages: ' + json.dumps(bad))

    def close(self):
        if self.sock.fileno() >= 0:
            try:
                self.frame(8, struct.pack('!H', 1000))
            except OSError:
                pass
            self.sock.close()


class Scratch:
    def __init__(self, executable, version):
        self.root = Path(tempfile.mkdtemp(prefix='ccc-', dir='/tmp')).resolve()
        self.executable, self.version = executable, version
        self.clients = []
        self.children = []
        self.env = {'PATH': str(Path(shutil.which('node')).parent) + ':/usr/bin:/bin',
                    'HOME': str(self.root / 'h'), 'CODEX_HOME': str(self.root / 'c'),
                    'TMPDIR': str(self.root / 'tmp'), 'TERM': 'xterm-256color',
                    'LANG': 'C.UTF-8', 'SHELL': '/bin/sh', 'RUST_LOG': 'error'}
        for name in ('CONFIG', 'DATA', 'STATE', 'CACHE'):
            self.env['XDG_' + name + '_HOME'] = str(self.root / name.lower())
        self.env['XDG_RUNTIME_DIR'] = str(self.root / 'run')
        for key, value in self.env.items():
            if key in ('HOME', 'CODEX_HOME', 'TMPDIR') or key.startswith('XDG_'):
                Path(value).mkdir(mode=0o700)
        self.project = self.root / 'project'
        self.project.mkdir()
        self.alias = self.root / 'c/app-server-control/app-server-control.sock'
        self.target = physical_socket(self.root)
        self.model = None

    def cli(self, *args):
        return subprocess.run([str(self.executable)] + list(args), env=self.env, cwd=self.project,
                              capture_output=True, text=True, timeout=BUDGET)

    def lifecycle(self, method):
        result = self.cli('app-server', 'daemon', method)
        require(result.returncode == 0, '%s exit=%d stdout=%r stderr=%r' % (method, result.returncode, result.stdout, result.stderr))
        try:
            value = json.loads(result.stdout)
        except ValueError as exc:
            raise Fail('%s stdout is not one JSON object: %r' % (method, result.stdout)) from exc
        require(isinstance(value, dict), method + ' must return one object')
        if VERBOSE:
            print('    daemon ' + method + ': ' + json.dumps(value))
        return value

    def start(self):
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        env = dict(self.env, PORT=str(port), MOCK_FIRST_MS='100', MOCK_DELAY_MS='100')
        log = (self.root / 'model.log').open('wb')
        self.model = subprocess.Popen([shutil.which('node'), str(REPO / 'scripts/harness-lab/mock/server.js')],
                                      cwd=self.root, env=env, stdout=log, stderr=log)
        self.children.append(self.model)
        log.close()
        def healthy():
            try:
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                with opener.open('http://127.0.0.1:%d/_health' % port, timeout=1) as response:
                    return response.status == 200 and self.model.poll() is None
            except OSError:
                return False
        until(healthy, 'local model stand-in')
        (self.root / 'c/config.toml').write_text('''model = "mock-model"
model_provider = "contract"
check_for_update_on_startup = false
approval_policy = "on-request"
approvals_reviewer = "user"
sandbox_mode = "read-only"
thread_unload_delay_secs = 2
[model_providers.contract]
name = "Contract loopback model"
base_url = "http://127.0.0.1:%d/v1"
wire_api = "responses"
requires_openai_auth = false
[analytics]
enabled = false
[feedback]
enabled = false
[projects.%s]
trust_level = "trusted"
''' % (port, json.dumps(str(self.project))))
        settings = self.root / 'c/app-server-daemon/settings.json'
        settings.parent.mkdir()
        settings.write_text(json.dumps({'updater': {'autoUpdateEnabled': False}, 'shutdownGraceSeconds': 5}))
        result = self.lifecycle('start')
        require(self.alias.is_symlink() and self.alias.readlink() == self.target, 'physical socket not isolated by scratch canonical path: %s -> %s' % (self.alias, self.alias.resolve()))
        require(self.target.is_socket() and self.target.with_suffix('.lock').is_file(), 'no physical socket/startup lock')
        return result

    def connect(self, initialized=True):
        client = WebSocket(self.alias)
        self.clients.append(client)
        if initialized:
            client.call('initialize', {'clientInfo': {'name': 'waycar_contract', 'version': '1'},
                                      'capabilities': {'experimentalApi': True}})
            client.send({'method': 'initialized', 'params': {}})
        return client

    def thread(self, client, **params):
        return client.call('thread/start', dict({'cwd': str(self.project)}, **params))['thread']['id']

    def turn(self, client, thread, text):
        return client.call('turn/start', {'threadId': thread, 'input': [{'type': 'text', 'text': text}]})['turn']['id']

    def complete(self, client, thread):
        result = client.event('turn/completed', thread)['params']['turn']
        require(result['status'] == 'completed' and result.get('error') is None, 'turn failed: ' + json.dumps(result))
        return result

    def cleanup(self):
        for client in self.clients:
            client.close()
        # Do NOT stop on an unstarted scratch: detection must not create locks.
        if self.alias.exists():
            try:
                self.cli('app-server', 'daemon', 'stop')
            except Exception:
                pass
        remove_scratch(self.root)
        for child in self.children:
            child.wait(timeout=10)


def detection(s):
    """Version/detection starts no process or socket, including global socket dir."""
    directory = s.target.parent
    before = {p.name: (p.lstat().st_ino, p.lstat().st_mtime_ns) for p in directory.iterdir()} if directory.exists() else None
    root_before = sorted(str(p.relative_to(s.root)) for p in s.root.rglob('*'))
    version = s.cli('--version')
    require(version.returncode == 0 and version.stdout.strip() == 'codex-cli ' + s.version, '--version: %r' % version.stdout)
    result = s.cli('app-server', 'daemon', 'version')
    require(result.returncode != 0 and not result.stdout.strip(), 'absent daemon version: %r' % result)
    require(not processes(s.root), 'detection started scratch process(es)')
    added = sorted(set(str(p.relative_to(s.root)) for p in s.root.rglob('*')) - set(root_before))
    require(not any(p.is_socket() for p in s.root.rglob('*')), 'detection created a scratch socket')
    if added:
        print('  detection-created files (not sockets/processes): ' + json.dumps(added))
    after = {p.name: (p.lstat().st_ino, p.lstat().st_mtime_ns) for p in directory.iterdir()} if directory.exists() else None
    require(before == after and not s.target.exists() and not s.alias.exists(), 'detection changed physical socket directory')
    print('  absent daemon: exit=%d stdout=%r stderr=%r' % (result.returncode, result.stdout.strip(), result.stderr.strip()))


def daemon_start(s):
    """One-object lifecycle output, detached daemon, version and idempotent start."""
    first = s.start()
    for key in ('status', 'backend', 'pid', 'socketPath', 'cliVersion', 'appServerVersion', 'managedCodexPath', 'managedCodexVersion'):
        require(key in first, 'start missing ' + key + ': ' + json.dumps(first))
    require(first['appServerVersion'] == first['cliVersion'] == first['managedCodexVersion'] == s.version
            and first['backend'] == 'pid' and isinstance(first['pid'], int)
            and Path(first['managedCodexPath']).is_relative_to(s.root / 'c/packages')
            and first['socketPath'] == str(s.alias), 'start version/socket/package mismatch')
    os.kill(first['pid'], 0)
    second = s.lifecycle('start')
    running = s.lifecycle('version')
    os.kill(first['pid'], 0)
    require(first['status'] == 'started' and second['status'] == 'alreadyRunning' and running['status'] == 'running'
            and 'pid' not in second and 'pid' not in running
            and second['socketPath'] == running['socketPath'] == first['socketPath']
            and running['appServerVersion'] == s.version,
            'start not idempotent/version changed: %r %r' % (second, running))
    print('  lifecycle: ' + json.dumps(first))


def websocket(s):
    """Tokenless RFC6455 upgrade, masking, ping/pong, fragmented client JSON."""
    s.start()
    c = s.connect(False)
    c.frame(9, b'ccc-ping')
    value = json.dumps({'id': 'fragment', 'method': 'initialize', 'params': {
        'clientInfo': {'name': 'waycar_contract', 'version': '1'}}}).encode()
    c.frame(1, value[:17], False)
    c.frame(0, value[17:])
    c.wait(lambda msg: msg.get('id') == 'fragment' and 'result' in msg, 'fragmented initialize')
    require(b'ccc-ping' in c.pongs, 'ping did not get matching pong')
    require('jsonrpc' not in c.seen[-1], 'unexpected jsonrpc field')
    # Explicit JSON-RPC version is accepted, though responses omit it.
    c.call('thread/loaded/list', jsonrpc='2.0')


def initialize(s):
    """Pre-initialize refusal and initialization response; notification optional."""
    s.start()
    c = s.connect(False)
    response = c.request('thread/loaded/list')
    require(response.get('error', {}).get('code') == -32600 and 'not initialized' in response['error']['message'].lower(), 'pre-initialize: ' + json.dumps(response))
    result = c.call('initialize', {'clientInfo': {'name': 'waycar_contract', 'version': '1'}, 'capabilities': {'experimentalApi': True}})
    require(isinstance(result.get('userAgent'), str) and result.get('codexHome') == str(s.root / 'c')
            and result.get('platformFamily') == 'unix', 'initialize: ' + json.dumps(result))
    c.call('thread/loaded/list')  # initialized notification is not a gate.
    c.send({'method': 'initialized', 'params': {}})
    c.call('thread/loaded/list')
    print('  pre-initialize: ' + json.dumps(response))


def thread_start(s):
    """cwd/id and thread/started broadcast to initialized non-subscribers."""
    s.start()
    c, observer = s.connect(), s.connect()
    thread = s.thread(c)
    started = observer.event('thread/started', thread)['params']['thread']
    require(started['id'] == thread and started['cwd'] == str(s.project), 'thread/started: ' + json.dumps(started))


def thread_source(s):
    """Waycar's explicit origin survives read, idle unload and reload."""
    s.start()
    c, observer = s.connect(), s.connect()
    thread = s.thread(c, threadSource='waycar')
    def record(expected_status):
        value = observer.call('thread/read', {'threadId': thread})['thread']
        require(value.get('threadSource') == 'waycar' and value['source'] == 'vscode'
                and value['status']['type'] == expected_status, 'Waycar origin: ' + json.dumps(value))
        return value
    record('idle')
    s.turn(c, thread, 'WAYCAR_ORIGIN')
    s.complete(c, thread)
    c.close()
    observer.event('thread/closed', thread)
    record('notLoaded')
    observer.call('thread/resume', {'threadId': thread})
    record('idle')
    print('  Waycar origin: source=vscode threadSource=waycar (read, unload, reload)')


METADATA = ('id', 'cwd', 'name', 'preview', 'status', 'source', 'parentThreadId', 'ephemeral', 'createdAt', 'updatedAt')


def loaded_read(s):
    """Loaded inventory and durable metadata keys/types."""
    s.start()
    c = s.connect()
    thread = s.thread(c)
    require(thread in c.call('thread/loaded/list')['data'], 'thread absent from loaded/list')
    record = c.call('thread/read', {'threadId': thread})['thread']
    require(all(key in record for key in METADATA), 'metadata missing: ' + json.dumps(record))
    require(record['id'] == thread and record['cwd'] == str(s.project) and record['status']['type'] == 'idle'
            and isinstance(record['createdAt'], int) and isinstance(record['updatedAt'], int)
            and isinstance(record['preview'], str) and record['name'] is None
            and record['source'] == 'vscode' and record['parentThreadId'] is None
            and record['ephemeral'] is False, 'metadata: ' + json.dumps(record))


def turn_round_trip(s):
    """Subscriber turn/items, broadcast status, paginated typed history."""
    s.start()
    c, observer = s.connect(), s.connect()
    thread = s.thread(c)
    turn = s.turn(c, thread, 'WAYCAR_ROUND_TRIP')
    require(c.event('turn/started', thread)['params']['turn']['id'] == turn, 'turn id mismatch')
    require(observer.event('thread/status/changed', thread)['params']['status']['type'] == 'active', 'missing active status')
    s.complete(c, thread)
    require(observer.event('thread/status/changed', thread)['params']['status']['type'] == 'idle', 'missing idle status')
    for method in ('item/started', 'item/completed'):
        items = [msg['params']['item'] for msg in c.seen if msg.get('method') == method]
        require({'userMessage', 'agentMessage'} <= {item['type'] for item in items}, 'missing ' + method + ': ' + json.dumps(items))
    second_turn = s.turn(c, thread, 'WAYCAR_PAGE_2')
    s.complete(c, thread)
    history = c.call('thread/turns/list', {'threadId': thread, 'limit': 1, 'sortDirection': 'asc'})
    require({'nextCursor', 'backwardsCursor'} <= history.keys() and len(history['data']) == 1
            and history['data'][0]['id'] == turn and history['data'][0]['itemsView'] == 'summary'
            and isinstance(history['nextCursor'], str) and isinstance(history['backwardsCursor'], str),
            'pagination: ' + json.dumps(history))
    page = c.call('thread/turns/list', {'threadId': thread, 'limit': 1, 'sortDirection': 'asc', 'cursor': history['nextCursor']})
    require(len(page['data']) == 1 and page['data'][0]['id'] == second_turn and page['nextCursor'] is None,
            'next page: ' + json.dumps(page))
    items = history['data'][0]['items']
    user = next(item for item in items if item['type'] == 'userMessage')
    agent = next(item for item in items if item['type'] == 'agentMessage')
    require(user['content'][0]['text'] == 'WAYCAR_ROUND_TRIP' and 'WAYCAR_ROUND_TRIP' in agent['text']
            and all(isinstance(item['id'], str) for item in (user, agent)), 'history item shape: ' + json.dumps(items))
    observer.quiet(lambda msg: msg.get('method', '').startswith(('turn/', 'item/')))


def steer(s):
    """Expected active turn id gates steering; steered text is persisted."""
    s.start()
    c = s.connect()
    thread = s.thread(c)
    turn = s.turn(c, thread, 'WAYCAR_SLOW')
    c.event('turn/started', thread)
    result = c.call('turn/steer', {'threadId': thread, 'expectedTurnId': turn, 'input': [{'type': 'text', 'text': 'WAYCAR_STEER'}]})
    require(result['turnId'] == turn, 'steer: ' + json.dumps(result))
    s.complete(c, thread)
    history = c.call('thread/turns/list', {'threadId': thread})
    require('WAYCAR_STEER' in json.dumps(history), 'steered input missing in history')


def interrupt(s):
    """Interrupt by thread/turn id ends the turn as interrupted."""
    s.start()
    c = s.connect()
    thread = s.thread(c)
    turn = s.turn(c, thread, 'WAYCAR_SLOW')
    c.event('turn/started', thread)
    c.call('turn/interrupt', {'threadId': thread, 'turnId': turn})
    result = c.event('turn/completed', thread)['params']['turn']
    require(result['id'] == turn and result['status'] == 'interrupted', 'interrupt: ' + json.dumps(result))


def disconnect_mid_turn(s):
    """A detached turn finishes and remains readable/resumable."""
    s.start()
    c, observer = s.connect(), s.connect()
    thread = s.thread(c)
    turn = s.turn(c, thread, 'WAYCAR_SLOW')
    c.event('turn/started', thread)
    c.close()
    observer.event('thread/status/changed', thread)
    observer.wait(lambda msg: msg.get('method') == 'thread/status/changed' and msg['params'].get('threadId') == thread
                  and msg['params']['status']['type'] == 'idle', 'disconnected turn completed')
    new = s.connect()
    new.call('thread/resume', {'threadId': thread})
    history = new.call('thread/turns/list', {'threadId': thread})['data']
    require(history[0]['id'] == turn and history[0]['status'] == 'completed'
            and any(item['type'] == 'agentMessage' for item in history[0]['items']), 'detached history: ' + json.dumps(history))


def pending_approval(s):
    c, observer = s.connect(), s.connect()
    thread = s.thread(c)
    s.turn(c, thread, 'WAYCAR_TOOL')
    request = c.event('item/commandExecution/requestApproval', thread)
    params = request['params']
    require(isinstance(request['id'], (str, int)) and params['threadId'] == thread
            and all(isinstance(params.get(key), str) for key in ('turnId', 'itemId', 'command', 'cwd'))
            and params['cwd'] == str(s.project) and params['command'] == "/bin/bash -lc 'echo waycar-tool-ok'"
            and {'accept', 'cancel'} <= {v for v in params['availableDecisions'] if isinstance(v, str)}
            and any(isinstance(v, dict) and 'acceptWithExecpolicyAmendment' in v for v in params['availableDecisions']),
            'approval params: ' + json.dumps(request))
    observer.wait(lambda msg: msg.get('method') == 'thread/status/changed' and msg['params'].get('threadId') == thread
                  and 'waitingOnApproval' in msg['params']['status'].get('activeFlags', []), 'approval flag broadcast')
    observer.quiet(lambda msg: msg.get('method') == 'item/commandExecution/requestApproval')
    return c, observer, thread, request


def approval(s):
    """Approval status broadcasts; disconnect/resume replays once and can accept."""
    s.start()
    c, observer, thread, original = pending_approval(s)
    c.close()
    new = s.connect()
    new.call('thread/resume', {'threadId': thread})
    replay = new.event('item/commandExecution/requestApproval', thread)
    require(replay == original, 'approval replay changed: ' + json.dumps(replay))
    new.quiet(lambda msg: msg.get('method') == replay['method'])
    new.send({'id': replay['id'], 'result': {'decision': 'accept'}})
    new.event('serverRequest/resolved', thread)
    s.complete(new, thread)


def approval_race(s):
    """Two subscribers: first decision wins; resolved and late reply are safe."""
    s.start()
    c, observer, thread, original = pending_approval(s)
    second = s.connect()
    second.call('thread/resume', {'threadId': thread})
    replay = second.event('item/commandExecution/requestApproval', thread)
    require(replay['id'] == original['id'], 'approval request id changed across subscribers')
    c.send({'id': original['id'], 'result': {'decision': 'accept'}})
    resolved = second.event('serverRequest/resolved', thread)['params']
    require(resolved['requestId'] == original['id'], 'resolved id mismatch')
    second.send({'id': replay['id'], 'result': {'decision': 'cancel'}})
    s.complete(c, thread)
    require(second.call('thread/loaded/list')['data'], 'late response broke connection')
    commands = [msg['params']['item'] for msg in c.seen if msg.get('method') == 'item/completed'
                and msg['params']['item']['type'] == 'commandExecution']
    require(len(commands) == 1 and commands[0]['exitCode'] == 0 and 'waycar-tool-ok' in commands[0]['aggregatedOutput'], 'first answer did not win: ' + json.dumps(commands))


def thread_name(s):
    """Name broadcast/list recency; empty named launches are absent from thread/list."""
    s.start()
    c, observer = s.connect(), s.connect()
    first = s.thread(c)
    c.call('thread/name/set', {'threadId': first, 'name': 'waycar-contract-launch'})
    event = observer.event('thread/name/updated', first)['params']
    require(event['threadName'] == 'waycar-contract-launch', 'name event: ' + json.dumps(event))
    empty = c.call('thread/list', {'sortKey': 'updated_at'})
    require(empty['data'] == [], 'empty launches now appear in thread/list: ' + json.dumps(empty))
    require(c.call('thread/read', {'threadId': first})['thread']['name'] == 'waycar-contract-launch', 'empty launch lost name')
    print('  named launch before first turn: ' + json.dumps(empty))
    s.turn(c, first, 'WAYCAR_FIRST')
    s.complete(c, first)
    first_updated = c.call('thread/read', {'threadId': first})['thread']['updatedAt']
    until(lambda: time.time() >= first_updated + 1, 'distinct thread recency timestamps')
    second = s.thread(c)
    s.turn(c, second, 'WAYCAR_SECOND')
    s.complete(c, second)
    listing = c.call('thread/list', {'sortKey': 'updated_at', 'limit': 10})
    named = next(row for row in listing['data'] if row['id'] == first)
    require(named['name'] == 'waycar-contract-launch', 'lost list name')
    times = [row['updatedAt'] for row in listing['data']]
    require(times == sorted(times, reverse=True) and times[0] > times[1]
            and [row['id'] for row in listing['data']] == [second, first]
            and 'nextCursor' in listing, 'list recency/pagination changed')


def unload(s):
    """Idle last unsubscribe unloads; read notLoaded, resume reloads and turns work."""
    s.start()
    c, observer = s.connect(), s.connect()
    thread = s.thread(c)
    s.turn(c, thread, 'WAYCAR_UNLOAD')
    s.complete(c, thread)
    c.close()
    observer.event('thread/closed', thread)
    require(thread not in observer.call('thread/loaded/list')['data'], 'unloaded thread still loaded')
    record = observer.call('thread/read', {'threadId': thread})['thread']
    require(record['status']['type'] == 'notLoaded', 'unloaded read: ' + json.dumps(record))
    observer.call('thread/resume', {'threadId': thread})
    require(thread in observer.call('thread/loaded/list')['data'], 'resume failed to load')
    s.turn(observer, thread, 'WAYCAR_RELOADED')
    s.complete(observer, thread)


def tui_joins(s):
    """PTY TUI joins shared daemon; --no-daemon uses an embedded server instead."""
    s.start()
    observer = s.connect()
    thread = None
    for mode in ('new', 'shared', 'embedded'):
        embedded = mode == 'embedded'
        c = s.connect() if thread else None
        if c:
            c.call('thread/resume', {'threadId': thread})
        master, slave = pty.openpty()
        # Enough space for the real ratatui TUI. Answer terminal capability probes
        # rather than inventing a UI session or simulating its subscription.
        import fcntl
        import termios
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        args = [str(s.executable)] + (['--no-daemon'] if embedded else []) + ['--no-alt-screen']
        args += ['resume', thread] if thread else ['WAYCAR_TUI']
        child = subprocess.Popen(args, env=s.env, cwd=s.project, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        s.children.append(child)
        os.close(slave)
        output = bytearray()
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    output.extend(chunk)
                    if b'\x1b[6n' in chunk:
                        os.write(master, b'\x1b[1;1R')
                    if b'\x1b[c' in chunk or b'\x1b[>c' in chunk:
                        os.write(master, b'\x1b[?1;2c')
                if b'waycar-mock-reply: WAYCAR_TUI' in output:
                    break
                require(child.poll() is None, 'headless TUI exited: ' + repr(bytes(output[-4000:])))
            require(b'waycar-mock-reply: WAYCAR_TUI' in output,
                    'TUI could not render its reply/history under pty: ' + repr(bytes(output[-4000:])))
            if thread is None:
                loaded = []
                def created():
                    loaded[:] = observer.call('thread/loaded/list')['data']
                    return bool(loaded)
                until(created, 'plain TUI thread/start')
                records = [observer.call('thread/read', {'threadId': item})['thread'] for item in loaded]
                users = [item for item in records if item.get('threadSource') == 'user'
                         and item.get('parentThreadId') is None and item.get('ephemeral') is False]
                require(len(users) == 1, 'unexpected TUI origins: ' + json.dumps(records))
                record = users[0]
                thread = record['id']
                require(record.get('threadSource') == 'user', 'TUI origin: ' + json.dumps(record))
                print('  TUI origin: source=%s threadSource=%s' % (record['source'], record['threadSource']))
                until(lambda: observer.call('thread/read', {'threadId': thread})['thread']['status']['type'] == 'idle',
                      'plain TUI first turn')
                history = observer.request('thread/turns/list', {'threadId': thread, 'limit': 50})
                route = 'thread/turns/list'
                if 'error' in history:
                    route = 'thread/read(includeTurns)'
                    turns = observer.call('thread/read', {'threadId': thread, 'includeTurns': True})['thread']['turns']
                else:
                    turns = history['result']['data']
                items = [item for turn in turns for item in turn['items']]
                prompts = [part.get('text', '') for item in items if item['type'] == 'userMessage'
                           for part in item.get('content', [])]
                replies = [item.get('text', '') for item in items if item['type'] == 'agentMessage']
                require('WAYCAR_TUI' in prompts and any('waycar-mock-reply: WAYCAR_TUI' in text for text in replies),
                        'TUI history missing prompt/reply: ' + json.dumps(turns))
                require(any((s.root / 'c').glob('state_*.sqlite')), 'normal TUI fixture has no state DB')
                print('  TUI history: %s, normal state DB present, prompt and reply readable' % route)
            if c:
                c.close()
            if embedded:
                observer.event('thread/closed', thread, seconds=10)
            else:
                time.sleep(4)  # two times the configured idle unload deadline
                require(thread in observer.call('thread/loaded/list')['data'], 'TUI did not keep shared thread loaded')
            require(child.poll() is None, 'TUI exited during observation')
        finally:
            child.terminate()
            child.wait(timeout=10)
            os.close(master)
        if not embedded:
            observer.event('thread/closed', thread, seconds=10)


def daemon_stop(s):
    """Stop JSON, both socket paths removed and non-starting absent version."""
    s.start()
    result = s.lifecycle('stop')
    require(result['status'] == 'stopped', 'stop: ' + json.dumps(result))
    until(lambda: not s.alias.exists() and not s.target.exists(), 'socket removal')
    version = s.cli('app-server', 'daemon', 'version')
    require(version.returncode != 0 and not version.stdout.strip(), 'version after stop: %r' % version)


def errors(s):
    """Unknown method, invalid params and unknown-thread failure envelopes."""
    s.start()
    c = s.connect()
    for method, params, code in (('waycar/no-such-method', {}, -32600),
                                 ('turn/start', {'threadId': 7}, -32600),
                                 ('turn/start', {'threadId': '00000000-0000-0000-0000-000000000000', 'input': [{'type': 'text', 'text': 'never sent'}]}, -32600)):
        response = c.request(method, params)
        error = response.get('error', {})
        require(error.get('code') == code and isinstance(error.get('message'), str), 'error envelope: ' + json.dumps(response))
        print('  %s: code=%s message=%r%s' % (method, error['code'], error['message'][:110], '…' if len(error['message']) > 110 else ''))


SCENARIOS = [detection, daemon_start, websocket, initialize, thread_start, thread_source, loaded_read,
             turn_round_trip, steer, interrupt, disconnect_mid_turn, approval,
             approval_race, thread_name, unload, tui_joins, daemon_stop, errors]


def main():
    global VERBOSE
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--only')
    parser.add_argument('-v', '--verbose', action='store_true')
    parser.add_argument('--latest', action='store_true')
    parser.add_argument('--warn', action='store_true')
    parser.add_argument('--print-pin', action='store_true')
    parser.add_argument('--fetch', metavar='DIR')
    args = parser.parse_args()
    VERBOSE = args.verbose
    if args.print_pin:
        print(PINNED_VERSION)
        return 0
    if args.list:
        for scenario in SCENARIOS:
            print('%-24s %s' % (scenario.__name__, scenario.__doc__))
        return 0
    names = list(dict.fromkeys(args.only.split(','))) if args.only else [s.__name__ for s in SCENARIOS]
    unknown = set(names) - {s.__name__ for s in SCENARIOS}
    if unknown:
        parser.error('unknown scenarios: ' + ', '.join(sorted(unknown)))
    if args.fetch and (args.latest or args.only):
        parser.error('--fetch always downloads the pin and runs no scenarios')
    def interrupted(signum, frame):
        raise KeyboardInterrupt('signal %d' % signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        reap_stale()
        if args.fetch:
            executable, _ = download(args.fetch)
            print(executable)
            return 0
        if not shutil.which('node'):
            raise SetupError('Node 26 is required for the npm wrapper and local model stand-in')
        with tempfile.TemporaryDirectory(prefix='ccc-', dir='/tmp') as work:
            executable, version = download(work, args.latest)
            print('Codex %s (%s); %d scenarios' % (version, 'latest advisory' if args.latest else 'pinned', len(names)), flush=True)
            failed = 0
            for scenario in SCENARIOS:
                if scenario.__name__ not in names:
                    continue
                scratch = Scratch(executable, version)
                started = time.monotonic()
                try:
                    scenario(scratch)
                    print('PASS %-24s %.1fs — %s' % (scenario.__name__, time.monotonic() - started, scenario.__doc__), flush=True)
                except Exception as exc:
                    # A changed JSON type/shape is drift too, not an uncaught
                    # TypeError that bypasses --warn and the remaining scenarios.
                    failed += 1
                    print('%s%s: %s' % ('::warning::' if args.warn else 'FAIL ', scenario.__name__, exc), flush=True)
                    if VERBOSE:
                        traceback.print_exc()
                finally:
                    scratch.cleanup()
            print('%d passed, %d failed, 0 skipped' % (len(names) - failed, failed), flush=True)
            return 0 if args.warn or not failed else 1
    except SetupError as exc:
        print(('::warning::' if args.warn else '') + 'SETUP: ' + str(exc), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print('interrupted; scratch cleaned', file=sys.stderr)
        return 130


if __name__ == '__main__':
    sys.exit(main())
