#!/usr/bin/env python3
"""Pin Ultimate's HTTP contract (U1-U9/U12-U14, docs/design/ultimate-backend.md).

  python3 scripts/ci/ultimate-contract.py                 # pinned upstream commit
  python3 scripts/ci/ultimate-contract.py --latest --warn # upstream HEAD, advisory
  python3 scripts/ci/ultimate-contract.py --list
  python3 scripts/ci/ultimate-contract.py --print-pin
  python3 scripts/ci/ultimate-contract.py --only admission,errors

Requires git, Node >=26 and pnpm (the version in upstream's packageManager).
Clones HazAT/ultimate into a temporary directory, verifies the commit, installs
its frozen lockfile, and starts the real supervisor on an ephemeral loopback
port. HOME, XDG directories, Pi config and project are all scratch; no inherited
credentials or user extensions. A local OpenAI-compatible stand-in supplies
replies without an account, network model calls or tokens. Nothing is installed
in the caller's project. Server process groups, the stand-in and scratch files
are removed on success, failure, SIGINT and SIGTERM (not SIGKILL).

--warn downgrades contract failures to annotations and exit 0; setup errors
still exit 2. CI's latest job is additionally continue-on-error. Python stdlib
only; no app/simulator required. U8 is a source/documentation check: upstream
exposes no API version to negotiate. This does not test SSH, the web UI, default
port selection, or exhaustively assert optional ConversationSummary fields.
"""
import argparse
import base64
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time

PINNED_COMMIT = 'd0a2e17b99fa119c37b442b234a9590a433b1880'
UPSTREAM = 'https://github.com/HazAT/ultimate.git'
BUDGET = 30


class Fail(Exception):
    """An observed wire behavior changed."""


class SetupError(Exception):
    """The upstream server could not be prepared."""


def require(condition, message):
    if not condition:
        raise Fail(message)


def until(check, description, seconds=BUDGET):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise Fail('timed out: ' + description)


def clean_env(root):
    # In particular do not forward API keys, proxy identities, NODE_OPTIONS,
    # ULTIMATE_*, PI_* or the real HOME into upstream or its install scripts.
    env = {'PATH': os.environ.get('PATH', ''), 'HOME': str(root / 'home'),
           'LANG': 'C.UTF-8', 'CI': '1', 'ULTIMATE_NO_OPEN': '1',
           'MIMALLOC_ALLOW_THP': '0', 'MIMALLOC_PURGE_DELAY': '0',
           'PI_CODING_AGENT_DIR': str(root / 'pi'), 'TMPDIR': str(root / 'tmp')}
    for name in ('CONFIG', 'CACHE', 'DATA', 'STATE'):
        env['XDG_' + name + '_HOME'] = str(root / name.lower())
    for name in ('HOME', 'PI_CODING_AGENT_DIR', 'TMPDIR', 'XDG_CONFIG_HOME',
                 'XDG_CACHE_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME'):
        Path(env[name]).mkdir(parents=True, exist_ok=True)
    return env


def stop_group(child):
    # Every command is its own session. Never find/kill by a shared port or name.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            break
        try:
            child.wait(timeout=10 if sig == signal.SIGTERM else 5)
        except subprocess.TimeoutExpired:
            continue
        if sig == signal.SIGTERM:
            # The leader can exit before its children; remove that group too.
            continue
    child.wait(timeout=5)


def command(args, env, cwd, timeout=180):
    with tempfile.TemporaryFile(mode='w+') as output:
        child = subprocess.Popen(args, cwd=cwd, env=env, stdout=output,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            child.wait(timeout=timeout)
            if child.returncode:
                output.seek(0)
                raise SetupError('%s failed (%s):\n%s' %
                                 (' '.join(args), child.returncode, output.read()[-6000:]))
        except subprocess.TimeoutExpired:
            raise SetupError('%s timed out' % ' '.join(args))
        finally:
            stop_group(child)


class Model(http.server.ThreadingHTTPServer):
    """An ordinary Pi custom provider, matching upstream's scripted-model fixture."""
    daemon_threads = True

    def __init__(self):
        self.started = threading.Event()
        self.release = threading.Event()
        self.release.set()
        self.tools = {}
        super().__init__(('127.0.0.1', 0), ModelHandler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.release.set()
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=5)


class ModelHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        last = body['messages'][-1]['content']
        text = last if isinstance(last, str) else ''.join(p.get('text', '') for p in last)
        self.server.started.set()
        if not self.server.release.wait(BUDGET):
            self.send_error(504)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        def chunk(delta, finish=None):
            return 'data: ' + json.dumps({
                'id': 'waycar-contract', 'object': 'chat.completion.chunk', 'created': 0,
                'model': 'contract-1', 'choices': [
                    {'index': 0, 'delta': delta, 'finish_reason': finish}]}) + '\n\n'
        # Notes can follow a submitted input in the model context. Find the
        # exact scripted input, once, rather than assuming it is the last message.
        # Ultimate executes its ordinary tools: we never supply document state.
        token = next((m['content'] for m in reversed(body['messages'])
                      if m['role'] == 'user' and isinstance(m['content'], str)
                      and m['content'] in self.server.tools), None)
        tool = self.server.tools.pop(token) if token else None
        if tool:
            name, args = tool
            delta = {'role': 'assistant', 'tool_calls': [{
                'index': 0, 'id': token, 'type': 'function',
                'function': {'name': name, 'arguments': json.dumps(args)}}]}
            finish = 'tool_calls'
        else:
            delta, finish = {'role': 'assistant', 'content': 'Reply: ' + text}, 'stop'
        try:
            self.wfile.write((chunk(delta) + chunk({}, finish) + 'data: [DONE]\n\n').encode())
        except (BrokenPipeError, ConnectionResetError):
            pass  # An /abort deliberately disconnects an in-flight model call.


class Events:
    """Read the real HTTP SSE stream, including chunked transfer framing."""
    def __init__(self, server):
        self.conn = server.connection()
        self.conn.request('GET', '/api/events', headers={'Accept': 'text/event-stream'})
        self.response = self.conn.getresponse()
        require(self.response.status == 200, 'SSE status is not 200')
        require(self.response.getheader('Content-Type') == 'text/event-stream', 'SSE MIME changed')
        self.items = queue.Queue()
        self.pending = []
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        try:
            name, data = '', []
            while True:
                line = self.response.readline().decode().rstrip('\r\n')
                if not line:
                    if data:
                        if name in ('view', 'ops', 'doc', 'docOps'):
                            require(len(data) == 2 and data[0].isdigit(),
                                    'subscription event lost its numeric first data line: %r' % data)
                            value = {'subscription': int(data[0]), 'data': json.loads(data[1])}
                        else:
                            value = json.loads('\n'.join(data))
                        self.items.put((name, value))
                    name, data = '', []
                    if self.response.isclosed():
                        break
                elif line.startswith('event: '):
                    name = line[7:]
                elif line.startswith('data: '):
                    data.append(line[6:])
        except Exception as exc:
            self.items.put(('reader-error', str(exc)))

    def event(self, name, predicate=lambda value: True):
        for index, (kind, value) in enumerate(self.pending):
            if kind == name and predicate(value):
                self.pending.pop(index)
                return value
        deadline = time.monotonic() + BUDGET
        while time.monotonic() < deadline:
            try:
                kind, value = self.items.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty:
                break
            require(kind != 'reader-error', 'SSE read failed: ' + str(value))
            if kind == name and predicate(value):
                return value
            # Preserve interleaved document deltas, not old busy/idle summaries:
            # replaying an earlier idle would falsely settle a later submit.
            if kind in ('doc', 'docOps', 'ui', 'uiOps'):
                self.pending.append((kind, value))
        raise Fail('timed out waiting for SSE ' + name)

    def close(self):
        # shutdown unblocks the reader before closing its buffered response.
        if self.conn.sock:
            import socket
            self.conn.sock.shutdown(socket.SHUT_RDWR)
        self.thread.join(timeout=5)
        self.response.close()
        self.conn.close()
        require(not self.thread.is_alive(), 'SSE reader did not stop')


class Server:
    def __init__(self, root, source, env, model):
        self.root, self.source, self.env, self.model = root, source, env, model
        self.project = root / 'project'
        self.project.mkdir()
        digest = hashlib.sha256(str(self.project).encode()).hexdigest()[:8]
        self.home = Path(env['HOME']) / '.ultimate/projects' / ('project-' + digest)
        self.log_path = root / 'server.log'
        self.log = self.log_path.open('w')
        self.child = subprocess.Popen(
            ['node', str(source / 'bin/ultimate.ts'), str(self.project), '--no-open', '--port', '0'],
            cwd=self.project, env=env, stdout=self.log, stderr=subprocess.STDOUT,
            start_new_session=True)
        self.port = None

    def start(self):
        def ready():
            if self.child.poll() is not None:
                raise SetupError('supervisor exited: ' + self.log_path.read_text()[-6000:])
            lock = self.home / 'ultimate.lock'
            if not lock.exists():
                return False
            try:
                record = json.loads(lock.read_text())
                self.port = record['port']
                return self.port and self.request('GET', '/api/models')[0] == 200
            except (OSError, ValueError, http.client.HTTPException):
                return False
        until(ready, 'Ultimate startup', seconds=90)

    def connection(self):
        return http.client.HTTPConnection('127.0.0.1', self.port, timeout=BUDGET)

    def request(self, method, path, data=None, headers=None, raw=None):
        conn = self.connection()
        try:
            payload = raw if raw is not None else (json.dumps(data) if data is not None else None)
            conn.request(method, path, body=payload,
                         headers={'Content-Type': 'application/json', 'Connection': 'close',
                                  **(headers or {})})
            resp = conn.getresponse()
            body = resp.read().decode()
            return resp.status, (json.loads(body) if resp.getheader('Content-Type') ==
                                 'application/json' else body)
        finally:
            conn.close()

    def expect(self, method, path, status=200, **kwargs):
        actual, body = self.request(method, path, **kwargs)
        require(actual == status, '%s %s: wanted %d, got %d: %r' %
                (method, path, status, actual, body))
        return body

    def conversation(self):
        body = self.expect('POST', '/api/conversations', 201,
                           data={'title': 'Waycar contract', 'cwd': str(self.project)})
        require(type(body.get('id')) is int and body['id'] > 0, 'conversation id changed')
        return body['id']

    def history(self, cid, query='before=9007199254740991'):
        return self.expect('GET', '/api/conversations/%d/history?%s' % (cid, query))

    def action(self, extension, name, args):
        # Fixture driver only: the app does not use browser-gated actions (U4).
        return self.expect('POST', '/api/extensions/%s/actions/%s' % (extension, name),
                           data={'args': args}, headers={
                               'Origin': 'http://127.0.0.1:%d' % self.port})['result']

    def tool(self, cid, name, args):
        token = 'waycar-contract-tool-%d' % time.monotonic_ns()
        self.model.tools[token] = (name, args)
        self.expect('POST', '/api/conversations/%d/submit' % cid, 202, data={'text': token})
        def completed():
            for entry in self.history(cid)['entries']:
                for message in entry.get('model', []):
                    if message.get('role') == 'toolResult' and message.get('toolCallId') == token:
                        require(not message.get('isError'), '%s failed: %r' % (name, message))
                        return message
        return until(completed, name + ' tool result')

    def close(self):
        stop_group(self.child)
        self.log.close()
        require(not (self.home / 'ultimate.lock').exists(), 'supervisor left its lock behind')


def apply_ops(value, ops):
    """Materialize the Chord operations the native UI/board replicas consume."""
    require(isinstance(ops, list), 'document ops are not an array')
    for op in ops:
        require(isinstance(op, list) and op, 'invalid document op: %r' % op)
        if op[0] == 'r' and len(op) == 2:
            value = op[1]
            continue
        require(len(op) >= 2 and isinstance(op[1], list), 'invalid op path: %r' % op)
        path = op[1]
        try:
            target = value
            for key in path[:-1]:
                target = target[key]
            if op[0] in ('s', 'd', 'a', 't') and path:
                key = path[-1]
                if op[0] == 's' and len(op) == 3:
                    if isinstance(target, list) and key == len(target):
                        target.append(op[2])
                    else:
                        target[key] = op[2]
                elif op[0] == 'd' and len(op) == 2:
                    del target[key]
                elif op[0] in ('a', 't') and len(op) == 3:
                    require(isinstance(target[key], str), 'string op targets a non-string: %r' % op)
                    if op[0] == 'a':
                        require(isinstance(op[2], str), 'append is not text: %r' % op)
                        target[key] += op[2]
                    else:
                        text = target[key].encode('utf-16-le', errors='surrogatepass')
                        require(type(op[2]) is int and 0 <= op[2] <= len(text) // 2,
                                'invalid UTF-16 front truncate: %r' % op)
                        target[key] = text[op[2] * 2:].decode('utf-16-le', errors='surrogatepass')
                else:
                    raise Fail('invalid property op: %r' % op)
            else:
                target = target[path[-1]] if path else value
                require(isinstance(target, list), 'array op targets a non-array: %r' % op)
                if op[0] == 'p' and len(op) == 5:
                    index, remove, inserted = op[2:]
                    require(type(index) is int and type(remove) is int and
                            0 <= index <= len(target) and 0 <= remove <= len(target) - index and
                            isinstance(inserted, list), 'invalid splice: %r' % op)
                    target[index:index + remove] = inserted
                elif op[0] == 'm' and len(op) == 3:
                    require(sorted(op[2]) == list(range(len(target))), 'invalid move: %r' % op)
                    target[:] = [target[index] for index in op[2]]
                else:
                    raise Fail('unsupported document op: %r' % op)
        except (KeyError, IndexError, TypeError) as exc:
            raise Fail('document op cannot apply: %r (%s)' % (op, exc))
    return value


class Document:
    """One real subscription's snapshot and subsequent ops, never a polling GET."""
    def __init__(self, events, subscription, kind):
        self.events, self.subscription, self.kind = events, subscription, kind
        self.value = self.event('doc')['value']

    def event(self, name):
        return self.events.event(name, lambda item: item.get('subscription') == self.subscription
                                 and item.get('data', {}).get('kind') == self.kind)['data']

    def wait(self, check):
        deadline = time.monotonic() + BUDGET
        while not check(self.value):
            require(time.monotonic() < deadline, 'timed out applying ' + self.kind + ' ops')
            self.value = apply_ops(self.value, self.event('docOps')['ops'])
        return self.value


def create_branch(s, events, lead, title):
    s.tool(lead, 'branch', {'prompt': 'Reply briefly.', 'title': title,
                          'root': 1, 'isolated': False})
    rows = events.event('conversations', lambda rows: any(
        row.get('title') == title and row.get('branchOf') for row in rows))
    return next(row['id'] for row in rows if row.get('title') == title and row.get('branchOf'))


def loopback(s):
    # The real supervisor chooses the port and publishes it in its lock (U1).
    require(type(s.port) is int and 0 < s.port < 65536, 'invalid ephemeral port')
    s.expect('GET', '/api/models')
    # Linux exposes the actual bind address, not just whether loopback connects.
    # On macOS (no /proc), check the supervisor's loopback-only bind in source.
    if sys.platform.startswith('linux'):
        port = '%04X' % s.port
        entries = Path('/proc/net/tcp').read_text().splitlines()[1:]
        listeners = [line.split()[1] for line in entries
                     if line.split()[3] == '0A' and line.split()[1].endswith(':' + port)]
        require(listeners == ['0100007F:' + port], 'supervisor is not loopback-only: %r' % listeners)
    else:
        # Bind authority is also asserted directly in the pinned server source.
        require("proxy.listen(port, '127.0.0.1'" in (s.source / 'bin/ultimate.ts').read_text(),
                'supervisor loopback binding changed')


def discovery(s):
    record = json.loads((s.home / 'ultimate.lock').read_text())
    require(record == {'pid': s.child.pid, 'port': s.port, 'project': str(s.project)},
            'lock {pid, port, project} contract changed: %r' % record)
    project = json.loads((s.home / 'project.json').read_text())
    require(project.get('root') == str(s.project), 'project.json root changed: %r' % project)


def admission(s):
    s.expect('GET', '/api/models', headers={'Origin': 'http://127.0.0.1:%d' % s.port})
    for headers in ({'Host': 'foreign.example'}, {'Origin': 'https://foreign.example'},
                    {'Host': '127.0.0.1:1'}, {'X-Forwarded-For': '127.0.0.1'},
                    {'Forwarded': 'for=127.0.0.1'}):
        s.expect('GET', '/api/models', 403, headers=headers)


def extension_gate(s):
    path = '/api/extensions/waycar-contract-missing/actions/missing'
    body = s.expect('POST', path, 403, data={})
    require('browser request' in body.get('error', ''), 'extension browser gate changed')
    s.expect('POST', path, 404, data={}, headers={'Origin': 'http://127.0.0.1:%d' % s.port})


def identity(s):
    events = Events(s)
    try:
        require(events.items.get(timeout=BUDGET)[0] == 'stream', 'first event is not stream')
        kind, system = events.items.get(timeout=BUDGET)
        require(kind == 'system', 'second event is not system')
        require(system.get('project', {}).get('root') == str(s.project),
                'system.project.root differs from the lock project')
        path = system.get('persistence', {}).get('path')
        require(isinstance(path, str) and s.home in Path(path).parents,
                'system.persistence.path is not inside the instance home')
        require(events.items.get(timeout=BUDGET)[0] == 'conversations',
                'conversations no longer follows system')
    finally:
        events.close()


def summaries(s):
    events = Events(s)
    try:
        stream = events.event('stream')
        require(isinstance(stream.get('id'), str) and stream['id'], 'missing stream id')
        values = events.event('conversations')
        require(isinstance(values, list) and values, 'no initial ConversationSummary[]')
        for value in values:
            require(type(value.get('id')) is int and type(value.get('busy')) is bool,
                    'summary id/busy shape changed: %r' % value)
        cid = s.conversation()
        updated = events.event('conversations', lambda rows: any(r['id'] == cid for r in rows))
        row = next(r for r in updated if r['id'] == cid)
        require(row.get('title') == 'Waycar contract' and row.get('cwd') == str(s.project),
                'summary title/cwd changed')
        path = '/api/events/%s/1' % stream['id']
        s.expect('POST', path, data={'conversation': cid, 'docs': [], 'view': False})
        s.expect('DELETE', path)
    finally:
        events.close()


def branch_summaries(s):
    events = Events(s)
    try:
        events.event('conversations')
        # Both are real standing conversations opened through the browser action.
        lead = s.action('subagents', 'standing', {'name': 'ultimate'})
        s.action('subagents', 'saveDefinition', {
            'name': 'contract-scout', 'scope': 'user', 'create': True,
            'frontmatter': {'description': 'Scratch contract standing agent', 'resident': True},
            'instructions': 'Reply briefly.'})
        standing = s.action('subagents', 'standing', {'name': 'contract-scout'})
        rows = events.event('conversations', lambda rows: {lead, standing} <= {r['id'] for r in rows})
        for cid, title in ((lead, '@ultimate'), (standing, '@contract-scout')):
            row = next(r for r in rows if r['id'] == cid)
            require(row.get('label') == 'agent' and row.get('title') == title,
                    'standing identity changed: %r' % row)
            require(all(key not in row for key in ('parentConversationId', 'ownerTaskId', 'branchOf')),
                    'standing agent is not ownerless/unforked: %r' % row)
        branch = create_branch(s, events, lead, 'Contract branch metadata')
        rows = events.event('conversations', lambda rows: any(
            r['id'] == branch and not r['busy'] and 'answerAt' in r for r in rows))
        row = next(r for r in rows if r['id'] == branch)
        source = row.get('branchOf', {})
        require(source.get('conversationId') == 1 and type(source.get('at')) is int and source['at'] > 0,
                'branchOf is not {conversationId, at}: %r' % row)
        require('parentConversationId' not in row and 'ownerTaskId' not in row,
                'ownerless branch acquired ownership: %r' % row)
        answers = [e['model'][0]['timestamp'] for e in s.history(branch)['entries']
                   if e['kind'] == 'pi.assistant']
        # A routed follow-up may already have answered after this SSE snapshot.
        require(type(row.get('inputAt')) in (int, float) and
                type(row.get('answerAt')) in (int, float) and row['inputAt'] > 1e12 and
                row['answerAt'] in answers and row['answerAt'] >= row['inputAt'],
                'answerAt is not the assistant Unix-millisecond timestamp: %r' % row)
        # A task-owned child has different metadata, even when it does not fork.
        s.tool(branch, 'subagent', {'action': 'start', 'agent': 'scout',
                                   'task': 'Reply briefly.', 'isolate': 'none'})
        rows = events.event('conversations', lambda rows: any(
            r.get('parentConversationId') == branch for r in rows))
        child = next(r for r in rows if r.get('parentConversationId') == branch)
        require(type(child.get('ownerTaskId')) is int and child['ownerTaskId'] > 0
                and 'branchOf' not in child, 'owned child shape changed: %r' % child)
    finally:
        events.close()


def ui_concluded(s):
    events = Events(s)
    key = 'ext.conversations.concluded'
    try:
        initial = events.event('ui')
        require(isinstance(initial.get('value'), dict), 'automatic ui snapshot lost {value}')
        value = initial['value']
        cid = s.conversation()
        result = s.action('conversations', 'conclude', {'ids': [cid]})
        require(cid in result.get('concluded', []), 'conclude did not accept the conversation')
        value = apply_ops(value, events.event('uiOps')['ops'])
        require(cid in value.get(key, []), 'automatic uiOps lost the concluded id')
        # Reconnect while concluded, not after returning to the initial empty set.
        fresh = Events(s)
        try:
            require(fresh.event('ui')['value'] == value, 'reconnect UI snapshot is stale')
        finally:
            fresh.close()
        s.action('conversations', 'resume', {'ids': [cid]})
        value = apply_ops(value, events.event('uiOps')['ops'])
        require(cid not in value.get(key, []), 'resume did not remove the automatic concluded id')
    finally:
        events.close()


def board_questions(s):
    events = Events(s)
    path = None
    try:
        stream = events.event('stream')['id']
        path = '/api/events/%s/0' % stream
        s.expect('POST', path, data={'conversation': 1, 'docs': ['board'], 'view': False})
        doc = Document(events, 0, 'board')
        require(isinstance(doc.value.get('messages'), list) and type(doc.value.get('next')) is int,
                'root board is not {messages, next}')
        lead = s.action('subagents', 'standing', {'name': 'ultimate'})
        branch = create_branch(s, events, lead, 'Contract question branch')
        questions = [{'kind': 'confirm', 'text': 'Proceed with the contract check?'}]
        for action, state in (('answer', 'answered'), ('dismiss', 'dismissed')):
            text = 'Contract question to ' + action
            s.tool(branch, 'message', {'to': 'user', 'text': text, 'reply': True,
                                       'questions': questions})
            value = doc.wait(lambda value: any(m.get('text') == text for m in value['messages']))
            original = next(m for m in value['messages'] if m.get('text') == text)
            mid = original['id']
            require(type(mid) is int and original.get('from') == branch
                    and original.get('to') == 'user' and original.get('reply') is True
                    and original.get('questions') == questions and original.get('state') == 'delivered',
                    'open question shape changed: %r' % original)
            args = {'messageId': mid}
            if action == 'answer':
                args['answers'] = [{'question': questions[0]['text'], 'answer': 'Yes'}]
            reply = s.action('questions', action, args)['id']
            value = doc.wait(lambda value: any(m['id'] == mid and m['state'] == state
                                               for m in value['messages']) and
                             any(m['id'] == reply for m in value['messages']))
            response = next(m for m in value['messages'] if m['id'] == reply)
            require(response.get('from') == 'user' and response.get('to') == branch
                    and response.get('re') == mid, 'answer/dismissal lost sender/re link: %r' % response)
            if action == 'answer':
                require(response.get('text') == questions[0]['text'] + ': Yes',
                        'structured answer text changed: %r' % response)
            else:
                require(response.get('reply') is False, 'dismissal is no longer a one-way note')
        # These terminal variants cannot all be forced through a user question:
        # failed/stopped belong to inter-agent delivery, not the user-card actions.
        refs = (s.source / 'extensions/messages/refs.ts').read_text()
        require("state: 'sent' | 'delivered' | 'answered' | 'dismissed' | 'failed' | 'stopped'" in refs,
                'board Message state variants changed; review native attention filtering')
    finally:
        try:
            if path:
                s.expect('DELETE', path)
        finally:
            events.close()


def submit(s):
    cid = s.conversation()
    path = '/api/conversations/%d' % cid
    events = Events(s)
    s.model.started.clear()
    s.model.release.clear()
    try:
        result = s.expect('POST', path + '/submit', 202,
                          data={'text': 'contract prompt', 'whenBusy': 'steer'})
        require(type(result.get('submissionId')) is int, 'missing submissionId')
        require(s.model.started.wait(BUDGET), 'submit never reached the local model')
        def status(busy):
            return lambda rows: any(r['id'] == cid and r['busy'] is busy for r in rows)
        events.event('conversations', status(True))
        queued = s.expect('POST', path + '/submit', 202,
                          data={'text': 'must be cancelled', 'whenBusy': 'followUp'})
        s.expect('POST', path + '/inbox/%d/cancel' % queued['submissionId'], data={})
        s.model.release.set()
        events.event('conversations', status(False))
        entries = s.history(cid)['entries']
        require(any(e['kind'] == 'pi.user' and 'contract prompt' in json.dumps(e.get('model'))
                    for e in entries), 'submitted pi.user missing from history')
        require(any(e['kind'] == 'pi.assistant' and 'Reply: contract prompt' in json.dumps(e.get('model'))
                    for e in entries), 'model reply missing from history')
        require(not any('must be cancelled' in json.dumps(e.get('model')) for e in entries),
                'cancelled input entered history')
        # Abort an actual in-flight turn, not just an already idle conversation.
        s.model.started.clear()
        s.model.release.clear()
        s.expect('POST', path + '/submit', 202, data={'text': 'abort this turn'})
        require(s.model.started.wait(BUDGET), 'abort fixture never reached the model')
        events.event('conversations', status(True))
        s.expect('POST', path + '/abort', data={})
        events.event('conversations', status(False))
    finally:
        s.model.release.set()
        events.close()


def history(s):
    cid = s.conversation()
    for n in range(36):
        prompt = 'page-%d' % n
        s.expect('POST', '/api/conversations/%d/submit' % cid, 202, data={'text': prompt})
        def replied():
            page = s.history(cid)
            if any(e['kind'] == 'pi.assistant' and 'Reply: ' + prompt + '"' in
                   json.dumps(e.get('model')) for e in page['entries']):
                return page
        page = until(replied, 'reply in history')
        if page.get('before'):
            break
    require(len(page['entries']) == 64 and page.get('before'), 'history did not paginate at 64')
    ids = [e['id'] for e in page['entries']]
    require(ids == sorted(set(ids), reverse=True), 'history is not newest-first')
    require(page['before'] == ids[-1], 'before is not the oldest returned entry')
    older = s.history(cid, 'before=%d' % ids[-1])['entries']
    require(older and all(e['id'] < ids[-1] for e in older), 'before is not exclusive')
    bounded = s.history(cid, 'before=%d&after=%d' % (ids[0], ids[-1]))['entries']
    require(bounded and all(ids[-1] <= e['id'] < ids[0] for e in bounded), 'after bounds changed')
    for entry in page['entries']:
        require(type(entry.get('id')) is int and isinstance(entry.get('kind'), str)
                and entry.get('conversationId') == cid, 'EntryRecord identity changed')


def history_cards(s):
    events = Events(s)
    try:
        events.event('conversations')
        lead = s.action('subagents', 'standing', {'name': 'ultimate'})
        branch = create_branch(s, events, lead, 'Contract history cards')
        markers = [e for e in s.history(1)['entries']
                   if e['kind'] == 'lineage.branched' and e.get('data', {}).get('branch') == branch]
        require(markers, 'lineage.branched history marker missing')
        marker = markers[0]['data']
        require(type(marker.get('at')) is int and marker['at'] > 0
                and isinstance(marker.get('intent'), str),
                'branch pointer data lost branch/at/intent: %r' % marker)
        questions = [{'ref': '1', 'kind': 'choice', 'text': 'Which approach?', 'options': [
            {'key': 'a', 'label': 'Small change', 'recommended': True},
            {'key': 'b', 'label': 'Larger change'}]}]
        s.tool(branch, 'message', {'to': 'user', 'text': 'Contract history question',
                                   'reply': True, 'questions': questions})
        calls = [block for entry in s.history(branch)['entries']
                 if entry['kind'] == 'pi.assistant'
                 for message in entry.get('model', [])
                 for block in message.get('content', []) if isinstance(block, dict)
                 and block.get('type') == 'toolCall' and block.get('name') == 'message']
        require(any(isinstance(call.get('id'), str)
                    and call.get('arguments', {}).get('to') == 'user'
                    and call['arguments'].get('questions') == questions for call in calls),
                'question card is no longer a message toolCall with structured arguments')
        # Inducing a provider outage is not a deterministic fixture. Pin the
        # producer's submit entry explicitly; do not mistake a fake HTTP entry
        # for an observed watchdog report.
        watchdog = (s.source / 'extensions/watchdog/server.ts').read_text()
        require('const data: Failure = {' in watchdog
                and 'conversation,\n          title,\n          error,\n          step,\n          retried,' in watchdog
                and '...(hint ? { hint } : {})' in watchdog
                and "entry: { kind: 'watchdog.failure', data }" in watchdog,
                'watchdog failure submit data changed; review the native failure card')
    finally:
        events.close()


def unstable_api(s):
    require('without migration paths' in (s.source / 'README.md').read_text(),
            'upstream API stability disclaimer changed; review versioning policy')


def errors(s):
    cid = s.conversation()
    path = '/api/conversations/%d/submit' % cid
    image = {'mimeType': 'image/png', 'data': base64.b64encode(b'png').decode()}
    cases = [('POST', path, 400, {'raw': '{'}),
             ('POST', path, 400, {'data': {'text': ' '}}),
             ('POST', path, 400, {'data': {'text': 'x', 'whenBusy': 'invalid'}}),
             ('POST', path, 413, {'data': {'text': 'x', 'images': [image] * 5}}),
             ('GET', '/api/conversations/%d/history' % cid, 400, {}),
             ('GET', '/api/conversations/9007199254740990/history?before=1', 404, {}),
             ('GET', '/api/waycar-contract-missing', 404, {})]
    for method, url, status, kwargs in cases:
        body = s.expect(method, url, status, **kwargs)
        require(isinstance(body, dict) and isinstance(body.get('error'), str),
                'error is not {error: string}: %r' % body)


SCENARIOS = [
    ('loopback', 'U1: real supervisor listens only on loopback', loopback),
    ('discovery', 'U2: hashed project home, lock and project record', discovery),
    ('admission', 'U3: credential-free local access; foreign/proxy headers refused', admission),
    ('extension_gate', 'U4: non-browser extension actions refused', extension_gate),
    ('identity', 'U12: SSE system project root and persistence home identify the instance', identity),
    ('summaries', 'U5: initial/live SSE summaries and stream subscriptions', summaries),
    ('branch_summaries', 'U5/U13: lead, standing, branch, owned child and answerAt metadata', branch_summaries),
    ('ui_concluded', 'U5: automatic UI snapshots, conclude/resume ops and reconnect', ui_concluded),
    ('board_questions', 'U14: root board doc framing, questions, answer/dismiss ops; state union (source)', board_questions),
    ('submit', 'U5/U6: submit, busy/idle push, queued cancellation, reply, abort', submit),
    ('history', 'U7: EntryRecord shape, 64-entry pagination, before/after cursors', history),
    ('history_cards', 'U7: question toolCall and branch pointer history; watchdog submit (source)', history_cards),
    ('unstable_api', 'U8: upstream still disclaims API compatibility', unstable_api),
    ('errors', 'U6/U9: validation, status codes and JSON API errors', errors),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--latest', action='store_true')
    parser.add_argument('--warn', action='store_true')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--print-pin', action='store_true')
    parser.add_argument('--only', help='comma-separated scenario names')
    args = parser.parse_args()
    if args.print_pin:
        print(PINNED_COMMIT)
        return 0
    if args.list:
        for name, description, _ in SCENARIOS:
            print('%-16s %s' % (name, description))
        return 0
    names = set(args.only.split(',')) if args.only else {name for name, _, _ in SCENARIOS}
    unknown = names - {name for name, _, _ in SCENARIOS}
    if unknown:
        parser.error('unknown scenarios: ' + ', '.join(sorted(unknown)))
    failures = 0
    with tempfile.TemporaryDirectory(prefix='waycar-ultimate-contract-') as temp:
        root = Path(temp).resolve()
        env = clean_env(root)
        source = root / 'source'
        print('Scratch: ' + str(root), flush=True)
        command(['git', 'clone', '--quiet', '--no-checkout', '--depth', '1', UPSTREAM, str(source)], env, root)
        if not args.latest:
            command(['git', 'fetch', '--quiet', '--depth', '1', 'origin', PINNED_COMMIT], env, source)
            command(['git', 'checkout', '--quiet', '--detach', 'FETCH_HEAD'], env, source)
        else:
            command(['git', 'checkout', '--quiet', '--detach', 'HEAD'], env, source)
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, env=env, text=True).strip()
        if not args.latest and commit != PINNED_COMMIT:
            raise SetupError('checkout does not match pinned commit: ' + commit)
        print('Ultimate: ' + commit, flush=True)
        command(['pnpm', 'install', '--frozen-lockfile', '--store-dir', str(root / 'pnpm-store')],
                env, source, timeout=300)
        model = Model()
        server = None
        try:
            pi = Path(env['PI_CODING_AGENT_DIR'])
            (pi / 'models.json').write_text(json.dumps({'providers': {'waycar-contract': {
                'baseUrl': 'http://127.0.0.1:%d/v1' % model.server_port,
                'api': 'openai-completions', 'apiKey': 'not-a-secret',
                'models': [{'id': 'contract-1'}]}}}))
            (pi / 'settings.json').write_text(json.dumps({
                'defaultProvider': 'waycar-contract', 'defaultModel': 'contract-1'}))
            server = Server(root, source, env, model)
            server.start()
            for name, _, scenario in SCENARIOS:
                if name not in names:
                    continue
                try:
                    scenario(server)
                    print('PASS ' + name, flush=True)
                except (Fail, OSError, ValueError, http.client.HTTPException) as exc:
                    failures += 1
                    print(('::warning::' if args.warn else 'FAIL ') + name + ': ' + str(exc), flush=True)
        finally:
            try:
                if server:
                    server.close()
            finally:
                model.close()
        print('%d scenarios, %d failures; scratch servers stopped' % (len(names), failures), flush=True)
    print('Scratch removed: ' + str(root), flush=True)
    return 0 if args.warn or not failures else 1


def interrupted(signum, frame):
    raise SystemExit(128 + signum)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        sys.exit(main())
    except (SetupError, Fail, OSError, subprocess.SubprocessError) as exc:
        print('::error::setup/cleanup failed: ' + str(exc), file=sys.stderr)
        sys.exit(2)
