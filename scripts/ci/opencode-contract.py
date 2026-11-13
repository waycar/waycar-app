#!/usr/bin/env python3
"""Real OpenCode 2 shared-service contract; Python stdlib + Node 26, no credentials.

--list; --only detection,events -v; --latest --warn; --print-pin;
--fetch DIR downloads the checksum-pinned platform npm package and prints its
executable path. Only npm registry artifacts are fetched; latest trusts npm
integrity. The version and artifact hashes live only in this script.

Every scenario has fresh HOME/XDG directories in /tmp/occ-*, a configured free
loopback port (never the default 49374), and a local model stand-in. No real
account, configuration, service or model is used. Cleanup stops through the
scratch environment, then signals ONLY processes carrying that scratch path.
Stale runs (>1h) are reaped. Normal exits, SIGINT and SIGTERM clean up; SIGKILL
cannot. --fetch output is caller-owned and retained. --warn annotates observed
drift and exits 0; preparation errors still exit 2. Scenarios never skip.
"""
import argparse
import base64
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import platform
import pty
import queue
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
import threading
import time
import traceback
import urllib.request

PINNED_VERSION = '2.2.7'
PINNED_SHA256 = {
    'linux-x64': 'd65935464f93f07913633f977cb99723af64eeff6ae7a822722ce89bedabdd45',
    'linux-arm64': '7e74ceb64fe5704ff2fdef3dee45866efcb580d71f182a6cae29606cad1f8b52',
    'darwin-arm64': '8d4f90c5b23faa724ba1c877d8358072bbb6565c33b8d8b5dca7c7644c4de0bf',
    'darwin-x64': 'a2f1bd02c36e180d43999a70126212511ef67686345d600724dd93ea74de7601',
}
REGISTRY = 'https://registry.npmjs.org/'
BUDGET = 40
REPO = Path(__file__).resolve().parents[2]
VERBOSE = False


class Fail(Exception):
    """Observed contract drift."""


class SetupError(Exception):
    """Unable to prepare the application; never downgraded to success."""


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


def download(dest, latest=False):
    """Verify before extracting; atomic staging leaves no partial package."""
    system = {'Linux': 'linux', 'Darwin': 'darwin'}.get(platform.system())
    arch = {'x86_64': 'x64', 'amd64': 'x64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine())
    target = '%s-%s' % (system, arch)
    if target not in PINNED_SHA256:
        raise SetupError('no pinned package for ' + target)
    dest = Path(dest).resolve()
    dest.mkdir(parents=True, exist_ok=True)
    package = dest / 'opencode'
    if package.exists() or package.is_symlink():
        raise SetupError('refusing to overwrite ' + str(package))
    try:
        version = json.loads(fetch(REGISTRY + '@opencode/cli/latest'))['version'] if latest else PINNED_VERSION
        metadata = json.loads(fetch(REGISTRY + '@opencode/cli-' + target + '/' + version))
        blob = fetch(metadata['dist']['tarball'])
        digest = hashlib.sha256(blob).hexdigest()
        if not latest and digest != PINNED_SHA256[target]:
            raise SetupError('%s sha256: expected %s, got %s' % (target, PINNED_SHA256[target], digest))
        integrity = 'sha512-' + base64.b64encode(hashlib.sha512(blob).digest()).decode()
        if integrity != metadata['dist']['integrity']:
            raise SetupError(target + ' npm integrity mismatch')
        with tempfile.TemporaryDirectory(prefix='.download-', dir=dest) as stage:
            staged = Path(stage) / 'opencode'
            staged.mkdir()
            with tarfile.open(fileobj=io.BytesIO(blob), mode='r:gz') as archive:
                for member in archive:
                    parts = Path(member.name).parts
                    if not parts or parts[0] != 'package' or '..' in parts or not (member.isfile() or member.isdir()):
                        raise SetupError('unsafe archive member: ' + member.name)
                    path = staged.joinpath(*parts[1:])
                    if member.isdir():
                        path.mkdir(parents=True, exist_ok=True)
                    else:
                        path.parent.mkdir(parents=True, exist_ok=True)
                        with archive.extractfile(member) as source, path.open('wb') as out:
                            shutil.copyfileobj(source, out)
                        path.chmod(0o755 if member.mode & 0o111 else 0o644)
            if not (staged / 'bin/opencode').is_file():
                raise SetupError('package has no bin/opencode')
            staged.rename(package)
        return package / 'bin/opencode', version
    except SetupError:
        raise
    except (OSError, ValueError, KeyError, tarfile.TarError) as exc:
        raise SetupError('invalid npm package: ' + str(exc)) from exc


def processes(root):
    """Only processes carrying this unique scratch path, never a name/port."""
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
        output = subprocess.run(['ps', 'eww', '-axo', 'pid=,command='], capture_output=True,
                                text=True, timeout=15, check=True).stdout
        for line in output.splitlines():
            pid, _, command = line.strip().partition(' ')
            if pid.isdigit() and int(pid) != os.getpid() and str(root) in command:
                found.add(int(pid))
    return found


def scratch_env(root):
    env = {'PATH': str(Path(shutil.which('node') or '/usr/bin/node').parent) + ':/usr/bin:/bin',
           'HOME': str(root / 'h'), 'TMPDIR': str(root / 'tmp'), 'TERM': 'xterm-256color',
           'LANG': 'C.UTF-8', 'SHELL': '/bin/sh', 'MOCK_API_KEY': 'mock',
           'OPENCODE_DISABLE_AUTOUPDATE': '1', 'OPENCODE_DISABLE_MODELS_FETCH': '1'}
    for name in ('CONFIG', 'STATE', 'DATA', 'CACHE'):
        env['XDG_' + name + '_HOME'] = str(root / name.lower())
    return env


def remove_scratch(root, executable=None):
    # The marker is generated by us, not a user-supplied --fetch directory. A
    # stale run can still use its recorded executable before its download dies.
    marker = root / 'executable'
    if executable is None and marker.is_file():
        executable = Path(marker.read_text().strip())
    registration = root / 'state/opencode/service.json'
    try:
        registered_pid = json.loads(registration.read_text())['pid']
    except (OSError, ValueError, KeyError, TypeError):
        registered_pid = None
    # A stale registration's PID may have been reused by an unrelated process.
    if executable and executable.is_file() and registered_pid in processes(root):
        try:
            subprocess.run([str(executable), 'service', 'stop'], env=scratch_env(root), cwd=root,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            pass
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in processes(root):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        time.sleep(0.1)
    require(not processes(root), 'scratch processes survived cleanup: ' + str(root))
    shutil.rmtree(root)


def reap_stale():
    for root in Path('/tmp').glob('occ-*'):
        info = root.lstat()
        if stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and time.time() - info.st_mtime > 3600:
            remove_scratch(root)
            print('reaped stale ' + str(root), file=sys.stderr)


def free_port(exclude=()):
    while True:
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        if port != 49374 and port not in exclude:
            return port


def listening(port):
    with socket.socket() as probe:
        probe.settimeout(0.2)
        return probe.connect_ex(('127.0.0.1', port)) == 0


class Events:
    """SSE reader with bounded waits and raw frames retained for wire assertions."""
    def __init__(self, scratch, types=()):
        self.conn = http.client.HTTPConnection('127.0.0.1', scratch.port, timeout=BUDGET)
        path = '/api/event' + ('?' + '&'.join('types=' + t for t in types) if types else '')
        self.conn.request('GET', path, headers={'Authorization': scratch.authorization(), 'Accept': 'text/event-stream'})
        self.sock = self.conn.sock
        self.response = self.conn.getresponse()
        require(self.response.status == 200 and self.response.getheader('content-type').startswith('text/event-stream'),
                'SSE response not text/event-stream: %d' % self.response.status)
        self.incoming = queue.Queue()
        self.seen = []
        self.frames = []
        self.closed = False
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        scratch.clients.append(self)
        first = self.event('server.connected')
        require(self.seen[0] == first, 'first SSE frame is not server.connected')

    def read(self):
        frame = []
        try:
            while not self.closed:
                line = self.response.readline()
                if not line:
                    break
                line = line.decode().rstrip('\r\n')
                if line:
                    frame.append(line)
                else:
                    self.frames.append(frame)
                    data = '\n'.join(line[5:].lstrip() for line in frame if line.startswith('data:'))
                    if data:
                        self.incoming.put(json.loads(data))
                    frame = []
        except (OSError, ValueError) as exc:
            if not self.closed:
                self.incoming.put(exc)
        finally:
            self.incoming.put(EOFError('SSE closed'))

    def event(self, kind, session=None, seconds=BUDGET):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                value = self.incoming.get(timeout=max(0.001, deadline - time.monotonic()))
            except queue.Empty:
                break
            if isinstance(value, Exception):
                raise Fail(str(value))
            self.seen.append(value)
            if VERBOSE:
                print('    event: ' + json.dumps(value))
            data = value.get('data', {})
            event_session = data.get('form', {}).get('sessionID') if kind == 'form.created' else data.get('sessionID')
            if value.get('type') == kind and (session is None or event_session == session):
                return value
        raise Fail('timed out: event %s session=%s; saw %s' % (kind, session, [v.get('type') for v in self.seen]))

    def close(self):
        if not self.closed:
            self.closed = True
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.reader.join(timeout=2)
            self.response.close()
            self.conn.close()


class TUI:
    """Real TUI on a PTY; answer capability probes and wait for its input box."""
    def __init__(self, scratch, *args):
        import fcntl
        import termios
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        self.child = subprocess.Popen([str(scratch.executable)] + list(args), env=scratch.env, cwd=scratch.project,
                                      stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        scratch.children.append(self.child)
        scratch.clients.append(self)
        os.close(slave)
        self.output = bytearray()
        self.closed = False

    def pump(self):
        if select.select([self.master], [], [], 0.05)[0]:
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                chunk = b''
            self.output.extend(chunk)
            if b'\x1b[6n' in chunk:
                os.write(self.master, b'\x1b[1;1R')
            if b'\x1b[c' in chunk or b'\x1b[>c' in chunk:
                os.write(self.master, b'\x1b[?1;2c')
        require(self.child.poll() is None, 'TUI exited: ' + repr(bytes(self.output[-3000:])))
        return '┃'.encode() in self.output

    def prompt(self, text):
        until(self.pump, 'TUI input box')
        os.write(self.master, text.encode())
        # Delivery is separate from Enter so the TUI processes the text first.
        until(lambda: self.pump() and text.encode() in self.output, 'TUI typed prompt')
        os.write(self.master, b'\r')

    def close(self):
        if not self.closed:
            self.closed = True
            if self.child.poll() is None:
                self.child.terminate()
                try:
                    self.child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.child.kill()
                    self.child.wait(timeout=5)
            os.close(self.master)


class Scratch:
    def __init__(self, executable, version):
        self.root = Path(tempfile.mkdtemp(prefix='occ-', dir='/tmp')).resolve()
        self.executable, self.version = executable, version
        self.env = scratch_env(self.root)
        self.clients, self.children = [], []
        for key, value in self.env.items():
            if key in ('HOME', 'TMPDIR') or key.startswith('XDG_'):
                Path(value).mkdir(mode=0o700)
        self.project = self.root / 'project'
        self.project.mkdir()
        (self.root / 'executable').write_text(str(executable))
        self.port = free_port()
        self.url = 'http://127.0.0.1:%d' % self.port
        self.registration = self.root / 'state/opencode/service.json'
        self.config = self.root / 'config/opencode/service.json'
        self.model = None

    def cli(self, *args, env=None):
        return subprocess.run([str(self.executable)] + list(args), env=env or self.env, cwd=self.project,
                              capture_output=True, text=True, timeout=BUDGET)

    def lifecycle(self, *args):
        result = self.cli('service', *args)
        require(result.returncode == 0, 'service %s exit=%d stdout=%r stderr=%r' %
                (' '.join(args), result.returncode, result.stdout, result.stderr))
        return result.stdout.strip()

    def prepare(self):
        self.lifecycle('set', 'port', str(self.port))
        require(json.loads(self.config.read_text())['port'] == self.port, 'service set port did not persist scratch port')
        self.lifecycle('set', 'hostname', '127.0.0.1')

    def start_model(self):
        if self.model is not None:
            return
        port = free_port((self.port,))
        self.model_port = port
        env = dict(self.env, PORT=str(port), MOCK_FIRST_MS='100', MOCK_DELAY_MS='100')
        with (self.root / 'model.log').open('wb') as log:
            self.model = subprocess.Popen([shutil.which('node'), str(REPO / 'scripts/harness-lab/mock/server.js')],
                                          cwd=self.root, env=env, stdout=log, stderr=log)
        self.children.append(self.model)
        def healthy():
            try:
                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=1)
                conn.request('GET', '/_health')
                response = conn.getresponse()
                response.read()
                return response.status == 200 and self.model.poll() is None
            except OSError:
                return False
            finally:
                conn.close()
        until(healthy, 'local model stand-in')
        (self.root / 'config/opencode/opencode.jsonc').write_text(json.dumps({
            'model': 'mock/mock-model', 'providers': {'mock': {'name': 'Mock', 'env': ['MOCK_API_KEY'],
                'package': '@opencode/ai/providers/openai-compatible',
                'settings': {'baseURL': 'http://127.0.0.1:%d/v1' % port, 'apiKey': 'mock'},
                'models': {'mock-model': {'name': 'Mock'}}}},
            'permissions': [{'action': 'shell', 'resource': '*', 'effect': 'ask'}]}))

    def model_api(self, method, path, body=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.model_port, timeout=BUDGET)
        try:
            conn.request(method, path, body=json.dumps(body) if body is not None else None,
                         headers={'Content-Type': 'application/json'})
            response = conn.getresponse()
            value = json.loads(response.read())
            require(response.status == 200, 'model control: %s %s: %s' % (method, path, value))
            return value
        finally:
            conn.close()

    def held(self, text):
        return until(lambda: next((h['id'] for h in self.model_api('GET', '/_health')['holds']
                                   if h['lastUser'] == text), None), 'model request held: ' + text)

    def release(self, identifier):
        return self.model_api('POST', '/_release', {'id': identifier})['released']

    def start(self):
        self.start_model()
        output = self.lifecycle('start')
        require(self.url in output, 'service start did not print scratch URL: ' + output)
        return self.registered()

    def registered(self):
        return json.loads(self.registration.read_text())

    def authorization(self):
        return 'Basic ' + base64.b64encode(('opencode:' + self.registered()['password']).encode()).decode()

    def request(self, method, path, body=None, status=200, auth=True, raw=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=BUDGET)
        headers = {'Content-Type': 'application/json'}
        if auth:
            headers['Authorization'] = self.authorization() if auth is True else auth
        try:
            conn.request(method, '/api' + path, body=raw if raw is not None else json.dumps(body) if body is not None else None,
                         headers=headers)
            response = conn.getresponse()
            data = response.read()
            value = json.loads(data) if data else None
            require(response.status == status, '%s %s: expected %d, got %d %s' %
                    (method, path, status, response.status, json.dumps(value)))
            return value, dict(response.getheaders())
        finally:
            conn.close()

    def api(self, method, path, body=None, status=200):
        return self.request(method, path, body, status)[0]

    def session(self, **params):
        identifier = 'ses_' + os.urandom(12).hex()
        session = self.api('POST', '/session', dict({'id': identifier, 'title': 'Waycar contract',
                           'location': {'directory': str(self.project)}}, **params))['data']
        require(session['id'] == identifier, 'server replaced client-chosen session id')
        return session

    def prompt(self, identifier, text):
        return self.api('POST', '/session/%s/prompt' % identifier, {'text': text})

    def messages(self, identifier):
        return self.api('GET', '/session/%s/message' % identifier)['data']

    def complete(self, stream, identifier, outcome='succeeded'):
        stream.event('session.execution.' + outcome, identifier)
        def idle():
            messages = self.messages(identifier)
            return messages if messages and messages[0]['type'] == 'idle' else None
        messages = until(idle, 'persisted idle message')
        require(messages[0]['outcome'] == outcome,
                'newest message not idle/%s: %s' % (outcome, json.dumps(messages)))
        return messages

    def cleanup(self):
        for client in self.clients:
            client.close()
        remove_scratch(self.root, self.executable)
        for child in self.children:
            child.wait(timeout=10)


def detection(s):
    """Version and stopped service status start no process and open no port (O1/O2)."""
    version = s.cli('--version')
    require(version.returncode == 0 and version.stdout.strip() == 'opencode v' + s.version, '--version: %r' % version)
    require(s.lifecycle('status') == 'stopped', 'absent status is not stopped')
    require(not processes(s.root) and not listening(s.port) and not s.registration.exists(), 'detection started service')


def server_flag_never_starts(s):
    """Explicit --server refuses a stopped service; plain session list starts it (O2/O3)."""
    result = s.cli('session', 'list', '--format', 'json', '--server', s.url)
    require(result.returncode != 0 and 'Could not reach server' in result.stdout + result.stderr, 'explicit --server: %r' % result)
    require(not processes(s.root) and not listening(s.port) and not s.registration.exists(), '--server started service')
    s.start_model()
    result = s.cli('session', 'list', '--format', 'json')
    require(result.returncode == 0 and json.loads(result.stdout) == [], 'plain session list: %r' % result)
    require(listening(s.port) and s.registered()['url'] == s.url, 'plain session list did not start service')
    s.lifecycle('stop')
    until(lambda: not listening(s.port), 'plain-list service stopped')


def service_start(s):
    """Start/status URL, private registration and serve --service process (O3/O5/O6)."""
    record = s.start()
    for key in ('id', 'version', 'url', 'pid', 'password'):
        require(key in record, 'registration missing ' + key)
    require(isinstance(record['pid'], int), 'registration PID is not an integer')
    require(record['version'] == s.version and record['url'] == s.url and record['password'], 'registration version/URL/password')
    for path in (s.registration, s.config):
        require(stat.S_IMODE(path.stat().st_mode) == 0o600 and path.stat().st_uid == os.getuid(), 'not private/owned: ' + str(path))
    require(s.lifecycle('status') == s.url, 'running status did not print URL')
    output = subprocess.run(['ps', '-p', str(record['pid']), '-o', 'args='], capture_output=True, text=True, check=True).stdout
    require('serve --service' in output and record['pid'] in processes(s.root), 'server command/environment not isolated: ' + output)


def auth_and_info(s):
    """Basic-only authentication and /api/info version/pid/urls (O6/O8)."""
    record = s.start()
    value, headers = s.request('GET', '/info', status=401, auth=False)
    require(value['_tag'] == 'UnauthorizedError' and headers.get('www-authenticate', '').split(' ', 1)[0] == 'Basic', 'unauthenticated envelope/Basic challenge')
    for auth in ('Basic ' + base64.b64encode(b'opencode:wrong').decode(), 'Bearer ' + record['password']):
        value, _ = s.request('GET', '/info', status=401, auth=auth)
        require(value['_tag'] == 'UnauthorizedError', 'wrong password/Bearer accepted')
    info = s.api('GET', '/info')
    require(info['version'] == s.version and info['pid'] == record['pid'] and s.url in info['urls'], 'info version/pid/urls: ' + json.dumps(info))


def session_create(s):
    """Client-chosen id, idempotent create, location/metadata and metadata event (O11)."""
    s.start()
    stream = Events(s)
    metadata = {'waycar': {'launch': 'contract'}}
    session = s.session(metadata=metadata)
    identifier = session['id']
    repeated = s.api('POST', '/session', {'id': identifier, 'title': 'must not replace'})['data']
    require(repeated['id'] == identifier and repeated['title'] == session['title'], 'create not idempotent')
    for value in (s.api('GET', '/session/' + identifier)['data'], next(v for v in s.api('GET', '/session')['data'] if v['id'] == identifier)):
        require(value['metadata'] == metadata and value['location']['directory'] == str(s.project), 'metadata/location round-trip: ' + json.dumps(value))
    changed = {'waycar': {'launch': 'updated'}}
    s.api('PATCH', '/session/' + identifier, {'metadata': changed}, status=204)
    event = stream.event('session.metadata.updated', identifier)
    require(changed == s.api('GET', '/session/' + identifier)['data']['metadata'], 'metadata patch not retained')
    require(event['durable']['aggregateID'] == identifier and isinstance(event['durable']['seq'], int), 'missing durable event identity')


def archived_listing(s):
    """Pin default and explicit archived filters for the unarchived inventory (O10)."""
    s.start()
    identifier = s.session()['id']
    s.api('PATCH', '/session/' + identifier, {'archived': True}, status=204)
    visible = {}
    for query in ('', '?archived=false', '?archived=true'):
        visible[query or 'default'] = identifier in [v['id'] for v in s.api('GET', '/session' + query)['data']]
    print('  archived session visible: ' + json.dumps(visible))
    require(visible == {'default': True, '?archived=false': False, '?archived=true': True}, 'archived filter changed: ' + json.dumps(visible))


def events(s):
    """SSE starts server.connected, has data/no id, and filters types server-side (O14)."""
    s.start()
    stream = Events(s, ('session.metadata.updated',))
    identifier = s.session()['id']
    s.api('PATCH', '/session/' + identifier, {'metadata': {'contract': True}}, status=204)
    stream.event('session.metadata.updated', identifier)
    require([v['type'] for v in stream.seen] == ['server.connected', 'session.metadata.updated'], 'SSE server-side filter leaked events')
    require(all(not any(line.startswith('id:') for line in frame) for frame in stream.frames), 'SSE acquired replay id')
    require(sum(any(line.startswith('data:') for line in frame) for frame in stream.frames) == 2, 'SSE data frames missing')


def prompt_round_trip(s):
    """Steer receipt before model release, running map, ordered events and newest-first history (O10/O13/O15)."""
    s.start()
    stream = Events(s)
    identifier = s.session()['id']
    text = 'WAYCAR_HOLD WAYCAR_ROUND_TRIP'
    receipt = s.prompt(identifier, text)
    require(receipt['data']['id'] and receipt['data']['delivery'] == 'steer',
            'prompt did not acknowledge before model release: ' + json.dumps(receipt))
    stream.event('session.execution.started', identifier)
    held = s.held(text)
    require(s.api('GET', '/session/active')['data'][identifier]['type'] == 'running', 'active map not running')
    require(s.release(held), 'model hold disappeared before release')
    messages = s.complete(stream, identifier)
    require([m['type'] for m in messages] == ['idle', 'assistant', 'user'], 'history not newest-first idle/assistant/user: ' + json.dumps(messages))
    require(messages[-1]['text'] == text and any(
        c['type'] == 'text' and 'WAYCAR_ROUND_TRIP' in c['text'] for c in messages[1]['content']), 'prompt/reply not readable')
    require(identifier not in s.api('GET', '/session/active')['data'], 'idle session still active')


def steer(s):
    """A prompt enqueued during a running turn is delivered (O13)."""
    s.start()
    stream = Events(s)
    identifier = s.session()['id']
    text = 'WAYCAR_HOLD WAYCAR_FIRST'
    s.prompt(identifier, text)
    stream.event('session.execution.started', identifier)
    held = s.held(text)
    receipt = s.prompt(identifier, 'WAYCAR_STEERED')
    require(receipt['data']['delivery'] == 'steer', 'running prompt not steered')
    enqueued = stream.event('session.inbox.enqueued', identifier)
    require(enqueued['data']['inboxID'] == receipt['data']['id'] and not any(
        v['type'] == 'session.execution.succeeded' for v in stream.seen), 'second prompt not enqueued during running turn')
    require(s.api('GET', '/session/active')['data'][identifier]['type'] == 'running', 'steered turn not running before release')
    require(s.release(held), 'model hold disappeared before steer assertions')
    delivered = stream.event('session.inbox.delivered', identifier)
    require(delivered['data']['inboxID'] == receipt['data']['id'], 'wrong inbox item delivered')
    until(lambda: any(m['type'] == 'user' and m['text'] == 'WAYCAR_STEERED' for m in s.messages(identifier)), 'steered prompt delivered')
    until(lambda: any(m['type'] == 'assistant' and 'WAYCAR_STEERED' in json.dumps(m['content']) for m in s.messages(identifier)), 'steered reply')
    until(lambda: identifier not in s.api('GET', '/session/active')['data'], 'steered turn idle')


def interrupt(s):
    """Interrupt running/idle responses, event and interrupted idle item (O16)."""
    s.start()
    stream = Events(s)
    identifier = s.session()['id']
    text = 'WAYCAR_HOLD WAYCAR_INTERRUPT'
    s.prompt(identifier, text)
    stream.event('session.execution.started', identifier)
    held = s.held(text)
    require(s.api('GET', '/session/active')['data'][identifier]['type'] == 'running', 'turn not running before interrupt')
    require(s.api('POST', '/session/%s/interrupt' % identifier) == {'interrupted': True}, 'running interrupt not true')
    s.complete(stream, identifier, 'interrupted')
    # An explicit interrupt writes its result time (Waycar's Done, B-38).
    ended = next(v for v in stream.seen if v['type'] == 'session.execution.interrupted')
    idle = s.api('GET', '/session/' + identifier)['data']['time'].get('idle')
    require(ended['data'].get('reason') == 'user' and idle == ended['created'],
            'interrupt reason/idle: %s idle=%s' % (json.dumps(ended), idle))
    require(s.api('POST', '/session/%s/interrupt' % identifier) == {'interrupted': False}, 'idle interrupt not false')
    s.release(held)  # The interrupt may already have cancelled the model connection.


def asked(s, stream, identifier):
    s.prompt(identifier, 'WAYCAR_TOOL')
    event = stream.event('permission.asked', identifier)['data']
    pending = s.api('GET', '/session/%s/permission' % identifier)['data']
    require(event['id'] in [p['id'] for p in pending] and event['action'] == 'shell'
            and event['resources'] == ['echo waycar-tool-ok'] and event['save'] == ['echo *']
            and event['source']['messageID'] and event['source']['id'], 'permission event/list mismatch: ' + json.dumps(pending))
    require(s.api('GET', '/session/active')['data'][identifier]['type'] == 'running', 'pending permission not running')
    return event['id']


def permission(s):
    """Once/reject, reply event/204, tool completion/error and second-answer 404 (O17)."""
    s.start()
    for decision in ('once', 'reject'):
        stream = Events(s)
        identifier = s.session()['id']
        request = asked(s, stream, identifier)
        path = '/session/%s/permission/%s/reply' % (identifier, request)
        s.api('POST', path, {'decision': decision}, status=204)
        reply = stream.event('permission.replied', identifier)['data']
        require(reply['requestID'] == request and reply['reply'] == decision, 'permission reply identity/decision')
        error = s.api('POST', path, {'decision': decision}, status=404)
        require(error['_tag'] == 'PermissionNotFoundError', 'duplicate permission reply envelope: ' + json.dumps(error))
        if decision == 'once':
            messages = s.complete(stream, identifier)
        else:
            # Rejection interrupts without writing an idle item (unlike /interrupt),
            # with reason shutdown and no time.idle: no result to show (B-38).
            ended = stream.event('session.execution.interrupted', identifier)
            until(lambda: identifier not in s.api('GET', '/session/active')['data'], 'rejected turn stopped')
            messages = s.messages(identifier)
            time_after = s.api('GET', '/session/' + identifier)['data']['time']
            require(ended['data'].get('reason') == 'shutdown' and 'idle' not in time_after,
                    'rejected turn reason/idle: %s time=%s' % (json.dumps(ended), json.dumps(time_after)))
        tools = [c for m in messages if m['type'] == 'assistant' for c in m['content'] if c['type'] == 'tool']
        require(tools and any(t['state']['status'] == ('completed' if decision == 'once' else 'error') for t in tools),
                'tool state after %s: %s' % (decision, json.dumps(tools)))
        stream.close()


def permission_disconnect(s):
    """A pending permission survives SSE disconnect and a new client answers (O17/O19)."""
    s.start()
    stream = Events(s)
    identifier = s.session()['id']
    request = asked(s, stream, identifier)
    stream.close()
    time.sleep(3)  # Deliberate disconnected observation window, not a readiness wait.
    pending = s.api('GET', '/session/%s/permission' % identifier)['data']
    require(request in [p['id'] for p in pending], 'permission cancelled on disconnect')
    replacement = Events(s)
    s.api('POST', '/session/%s/permission/%s/reply' % (identifier, request), {'decision': 'once'}, status=204)
    replacement.event('permission.replied', identifier)
    s.complete(replacement, identifier)


def question_form(s):
    """Question tool creates custom q0 Form/options, GET and reply/204/event (O18)."""
    s.start()
    stream = Events(s)
    identifier = s.session()['id']
    s.prompt(identifier, 'WAYCAR_ASK')
    form = stream.event('form.created', identifier)['data']['form']
    require(form['metadata']['kind'] == 'question', 'question form metadata: ' + json.dumps(form))
    field = form['fields'][0]
    require(field['key'] == 'q0' and field['custom'] is True and [v['value'] for v in field['options']] == ['Red', 'Blue'], 'question field: ' + json.dumps(field))
    require(form['id'] in [f['id'] for f in s.api('GET', '/session/%s/form' % identifier)['data']], 'form not listed')
    s.api('POST', '/session/%s/form/%s/reply' % (identifier, form['id']), {'answer': {'q0': 'Blue'}}, status=204)
    reply = stream.event('form.replied', identifier)['data']
    require(reply['id'] == form['id'] and reply['answer'] == {'q0': 'Blue'}, 'form reply identity/answer: ' + json.dumps(reply))
    s.complete(stream, identifier)


def tui_joins(s):
    """Plain PTY TUI joins one server, no metadata, correct folder; exact --session id (O9/O12/O25)."""
    record = s.start()
    tui = TUI(s)
    tui.prompt('WAYCAR_DESK_TUI')
    def desk_session():
        tui.pump()
        return next((v for v in s.api('GET', '/session')['data'] if 'metadata' not in v and v['location']['directory'] == str(s.project)), None)
    session = until(desk_session, 'plain TUI session')
    until(lambda: tui.pump() and any(m['type'] == 'user' and m['text'] == 'WAYCAR_DESK_TUI' for m in s.messages(session['id'])), 'plain TUI submitted prompt')
    require(s.registered()['pid'] == record['pid'] and processes(s.root) == {record['pid'], s.model.pid, tui.child.pid}, 'TUI spawned another server/process')
    tui.close()
    identifier = 'ses_' + os.urandom(12).hex()
    linked = TUI(s, '--session', identifier, '--prompt', 'WAYCAR_EXACT_ID')
    until(lambda: linked.pump() and any(v['id'] == identifier for v in s.api('GET', '/session')['data']), 'TUI client-chosen session id')
    require(len([v for v in s.api('GET', '/session')['data'] if v['id'] == identifier]) == 1, 'TUI created duplicate session')
    until(lambda: linked.pump() and any(m['type'] == 'user' and m['text'] == 'WAYCAR_EXACT_ID' for m in s.messages(identifier)), 'TUI --prompt submitted')
    linked.close()


def tui_autostarts(s):
    """A plain TUI starts serve --service, which outlives the TUI (O3)."""
    s.start_model()
    require(s.lifecycle('status') == 'stopped', 'service not initially stopped')
    tui = TUI(s)
    until(tui.pump, 'autostart TUI input box')
    until(lambda: s.registration.exists() and listening(s.port), 'TUI autostarted service')
    record = s.registered()
    tui.close()
    require(s.lifecycle('status') == s.url and record['pid'] in processes(s.root), 'TUI exit stopped service')
    output = subprocess.run(['ps', '-p', str(record['pid']), '-o', 'args='], capture_output=True, text=True, check=True).stdout
    require('serve --service' in output, 'TUI did not start service mode: ' + output)


def restart(s):
    """Restart keeps URL/password, resumes a turn with synthetic text, cancels permission (O20)."""
    first = s.start()
    stream = Events(s)
    running, blocked = s.session()['id'], s.session()['id']
    pending = asked(s, stream, blocked)
    text = 'WAYCAR_HOLD WAYCAR_RESTART'
    s.prompt(running, text)
    stream.event('session.execution.started', running)
    held = s.held(text)
    require(s.api('GET', '/session/active')['data'][running]['type'] == 'running', 'turn not running before restart')
    stream.close()
    os.kill(first['pid'], signal.SIGTERM)
    until(lambda: not listening(s.port), 'server SIGTERM')
    second = s.start()
    require(first['url'] == second['url'] and first['password'] == second['password'] and first['pid'] != second['pid'], 'restart URL/password/pid')
    replacement = Events(s)
    until(lambda: any(m['type'] == 'synthetic' and 'server restarted' in m['text'].lower() for m in s.messages(running)), 'restart synthetic message')
    require(not s.api('GET', '/session/%s/permission' % blocked)['data'], 'pending permission survived restart')
    error = s.api('POST', '/session/%s/permission/%s/reply' % (blocked, pending), {'decision': 'once'}, status=404)
    require(error['_tag'] == 'PermissionNotFoundError', 'cancelled permission reply envelope')
    tools = [c for m in s.messages(blocked) if m['type'] == 'assistant' for c in m['content'] if c['type'] == 'tool']
    require(any(t['state']['status'] == 'error' and t['state']['error']['type'] == 'aborted'
                and 'location shut down' in t['state']['error']['message'] for t in tools),
            'cancelled tool lacks shutdown error: ' + json.dumps(tools))
    s.release(held)  # SIGTERM may already have cancelled the original model connection.
    until(lambda: any(m['type'] == 'idle' and m['outcome'] == 'succeeded' for m in s.messages(running)), 'resumed turn completion')
    replacement.close()


def session_export_cli(s):
    """Session export --server/password prints info + oldest-first messages (O22)."""
    s.start()
    stream = Events(s)
    identifier = s.session()['id']
    s.prompt(identifier, 'WAYCAR_EXPORT')
    newest = s.complete(stream, identifier)
    result = s.cli('session', 'export', identifier, '--server', s.url,
                   env=dict(s.env, OPENCODE_PASSWORD=s.registered()['password']))
    require(result.returncode == 0, 'export CLI: %r' % result)
    export = json.loads(result.stdout)
    require(export['info']['id'] == identifier and [m['id'] for m in export['messages']] == [m['id'] for m in reversed(newest)], 'export shape/order: ' + json.dumps(export))


def errors(s):
    """Unknown session 404 SessionNotFoundError; malformed body 400."""
    s.start()
    value = s.api('GET', '/session/ses_waycar_missing', status=404)
    require(value['_tag'] == 'SessionNotFoundError', 'unknown session envelope: ' + json.dumps(value))
    s.request('POST', '/session', raw='{', status=400)


SCENARIOS = [detection, server_flag_never_starts, service_start, auth_and_info, session_create,
             archived_listing, events, prompt_round_trip, steer, interrupt, permission,
             permission_disconnect, question_form, tui_joins, tui_autostarts, restart,
             session_export_cli, errors]


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
            raise SetupError('Node 26 is required for the local model stand-in')
        with tempfile.TemporaryDirectory(prefix='occ-', dir='/tmp') as work:
            executable, version = download(work, args.latest)
            print('OpenCode %s (%s); %d scenarios' % (version, 'latest advisory' if args.latest else 'pinned', len(names)), flush=True)
            failed = 0
            for scenario in SCENARIOS:
                if scenario.__name__ not in names:
                    continue
                scratch = Scratch(executable, version)
                started = time.monotonic()
                try:
                    scratch.prepare()
                    scenario(scratch)
                    print('PASS %-24s %.1fs — %s' % (scenario.__name__, time.monotonic() - started, scenario.__doc__), flush=True)
                except Exception as exc:
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
