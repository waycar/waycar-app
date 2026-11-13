#!/usr/bin/env python3

import argparse
import json
import os
import re
import signal
import socket
import threading
import time
from typing import Optional

# One scripted run, spelled `fixture:<behavior>:<unique>`. Tests plant it in a
# request parameter the Transport carries to herdr — `tab.create`'s cwd,
# `worktree.create`'s branch, `workspace.create`'s cwd, `worktree.list`'s
# workspace id — and the fixture derives every id it answers with from it, so
# each later request in the same launch carries the token onward. That both
# steers the scripted failures and keeps one test's recorded requests from
# being confused with another's.
SCRIPT_TOKEN_PATTERN = re.compile(r"fixture:[a-z0-9]+:[0-9a-f-]+")

# `pane.read` on this pane id answers with the requests recorded under the
# token that follows it, rather than pane output.
RECORD_QUERY_PREFIX = "record:"

AGENT_PANE_BUSY = {
    "code": "agent_pane_busy",
    "message": "pane is not an available shell",
}
# Any API error that is not `agent_pane_busy`, which is the whole contract the
# compensating close and remove hang off. The code is the fixture's own on
# purpose: herdr 0.7.5's refusal of an unsupported kind is recorded only by its
# message, so inventing a plausible code here would read as a verified fact.
NON_RETRYABLE_START_FAILURE = {
    "code": "fixture_agent_start_refused",
    "message": "scripted non-retryable agent.start failure",
}
# herdr 0.9.1's launch reconcile race (#17), scaled down. A launch stays
# `launch_pending` until an `agent.get` reconciles it at or after the settle;
# one at or after the deadline clears the managed name instead.
LAUNCH_SETTLE_SECONDS = 1.5
LAUNCH_DEADLINE_SECONDS = 4.0
# What `agent.prompt` answers while a launch is pending, as 0.9.1 words it.
AGENT_NOT_READY_CODE = "agent_not_ready"
# Recorded under the token when a late `agent.get` clears the managed name.
LAUNCH_NAME_CLEARED = "fixture.launch_name_cleared"
# Worktree launch scripts (`_worktree_launch_state`). Each keeps its token's
# worktree and Agents in every `worktree.list`, `agent.list` and
# `session.snapshot` from the token's first request until its recorded
# requests are read, which ends the test's launch.
#   createhangs: `worktree.create` makes the worktree, then never answers.
#   hungrefuse: createhangs, and `agent.start` is refused.
#   hungnothing: `worktree.create` never answers and makes nothing.
#   slowcreate: `worktree.create` answers after SLOW_CREATE_SECONDS.
#   lostcreate: the worktree exists before the launch (a lost try made it).
#   rootagent: lostcreate, with an Agent running in its root pane.
#   envagent: lostcreate, with an Agent running in a second tab
#   (`env-tab:<token>`, pane `env-pane:<token>`), as an env-carrying launch
#   starts it.
#   envorphan: lostcreate, with that second tab open but no Agent in it.
#   existingagent / existingidle / existingrefuse / existingshell /
#   existingkinds: the worktree was already open before the launch; with a
#   codex Agent, with none, with none and a refused `agent.start`, for a
#   shell launch, and with a claude then a codex Agent.
WORKTREE_LAUNCH_BEHAVIORS = frozenset(
    {
        "createhangs",
        "hungrefuse",
        "hungnothing",
        "slowcreate",
        "lostcreate",
        "rootagent",
        "pendingagent",
        "envagent",
        "envorphan",
        "existingagent",
        "existingidle",
        "existingrefuse",
        "existingshell",
        "existingkinds",
    }
)
# The worktree launch scripts whose `agent.start` herdr refuses.
REFUSED_WORKTREE_AGENT_STARTS = frozenset({"hungrefuse", "existingrefuse"})
# Past the app's request budget in the slow-create test, inside its
# `worktreeCreateTimeout`.
SLOW_CREATE_SECONDS = 4
# A hung `worktree.create` waits for the client to close its channel; this
# only bounds a thread whose client never does.
HUNG_CREATE_CAP_SECONDS = 120
# Launches whose pane shows its TUI's screen (`AgentScreen`), as
# (first `pane.read`, every later one): `opencodebox` is blank while the TUI
# starts, then shows opencode's (or kilo's) input box; `opencodeblank` never
# draws it; `clinerow` draws cline's composer second; `signin` shows
# cursor-agent's sign-in screen first and a plain one after; `groktrust`
# shows grok's folder-trust dialog first and a plain one after.
OPENCODE_INPUT_BOX = "\n".join(
    [
        "",
        "  ┃",
        "  ┃  Ask anything...",
        "  ┃",
        "  ╹" + "▀" * 40,
        "   /tmp/fixture                         tab agents  ctrl+p commands",
    ]
)
CLINE_COMPOSER = "\n".join(
    [
        "                     What can I do for you?",
        "  " + "─" * 40,
        "  ❯ What can I do for you?",
        "  " + "─" * 40,
        "   mock-model (0) $0.00          ○ Plan ● Act (Tab)",
        "   ▶▶ Auto-approve all enabled (Shift+Tab)",
    ]
)
CURSOR_SIGN_IN = "\n".join(
    ["", "       Cursor Agent", "       v2026.10.01-e373342", "       Press any key to log in..."]
)
GROK_TRUST = "\n".join(
    [
        "            Do you trust the contents of this directory?",
        "             /home/waycar/work/demo",
        "",
        "      Grok Build may run or modify contents in this directory,",
        "                       posing security risks.",
        "",
        "                   Yes, proceed                 y",
        "                   No, quit                     n",
        "",
        "                                                  Grok Build  1.0.50",
    ]
)
# A user's close of a main checkout's last tab or pane, which herdr 0.9.x
# refuses because it would take the linked worktree Workspaces too.
WORKTREE_GROUP_BEHAVIORS = frozenset({"worktreegroup", "worktreegroupraced"})
SCREEN_BEHAVIORS = {
    "opencodebox": ("", OPENCODE_INPUT_BOX),
    "opencodeblank": ("", ""),
    "clinerow": ("", CLINE_COMPOSER),
    "signin": (CURSOR_SIGN_IN, ""),
    "groktrust": (GROK_TRUST, ""),
}


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--stale-socket", action="append", required=True)
    parser.add_argument("--count-file", required=True)
    return parser.parse_args()


class _OneShotBarrier:
    def __init__(self, condition: threading.Condition) -> None:
        self.condition = condition
        self.tokens: set[str] = set()

    def record(self, token: object) -> None:
        if not isinstance(token, str):
            return
        with self.condition:
            self.tokens.add(token)
            self.condition.notify_all()

    def wait(self, token: object) -> bool:
        if not isinstance(token, str):
            return False
        with self.condition:
            observed = self.condition.wait_for(
                lambda: token in self.tokens,
                timeout=20,
            )
            if observed:
                self.tokens.discard(token)
            return observed


class Server:
    def __init__(self, socket_path: str, stale_socket_paths: list[str], count_file: str) -> None:
        self.socket_path = socket_path
        self.stale_socket_paths = stale_socket_paths
        self.count_file = count_file
        self.count = 0
        self.count_lock = threading.Lock()
        self.hang_condition = threading.Condition()
        self.hang_requests = _OneShotBarrier(self.hang_condition)
        self.pane_hangs = _OneShotBarrier(self.hang_condition)
        self.pane_delays = _OneShotBarrier(self.hang_condition)
        self.script_lock = threading.Lock()
        self.recorded_requests: dict[str, list[str]] = {}
        self.agent_start_attempts: dict[str, int] = {}
        # Live worktree launch scripts by token (`_worktree_launch_state`).
        self.worktree_launches: dict[str, dict] = {}
        self.finished_worktree_launches: set[str] = set()
        self.launches: dict[str, dict] = {}
        self.screen_reads: dict[str, int] = {}
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    def start(self) -> None:
        self._unlink_paths()
        for stale_socket_path in self.stale_socket_paths:
            stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            stale.bind(stale_socket_path)
            stale.close()
            os.chmod(stale_socket_path, 0o777)

        self.listener.bind(self.socket_path)
        os.chmod(self.socket_path, 0o777)
        self.listener.listen()
        self._write_count()

        while True:
            connection, _ = self.listener.accept()
            threading.Thread(
                target=self._serve,
                args=(connection,),
                daemon=True,
            ).start()

    def close(self) -> None:
        self.listener.close()
        self._unlink_paths()

    def _serve(self, connection: socket.socket) -> None:
        with connection:
            self._increment_count()
            request = bytearray()
            while not request.endswith(b"\n"):
                chunk = connection.recv(1024)
                if not chunk:
                    return
                request.extend(chunk)

            envelope = json.loads(request)
            method = envelope.get("method")
            if method == "events.subscribe":
                self._serve_events(connection, envelope)
                return
            if method == "eof":
                return
            if method == "hang":
                self.hang_requests.record(envelope.get("id"))
                time.sleep(30)
                return
            params = envelope.get("params", {})
            if method == "pane.read" and params.get("pane_id") == "hang":
                time.sleep(30)
                return
            pane_id = params.get("pane_id") if isinstance(params, dict) else None
            pane_hang_token = self._fixture_token(pane_id, "fixture:hang:")
            if method == "pane.read" and pane_hang_token is not None:
                self.pane_hangs.record(pane_hang_token)
                time.sleep(30)
                return
            pane_delay_token = self._fixture_token(pane_id, "fixture:delay:")
            pane_await_delay_token = self._fixture_token(
                pane_id,
                "fixture:await-delay:",
            )
            pane_observer_token = self._fixture_token(
                pane_id,
                "fixture:await-hang:",
            )
            record_query = self._fixture_token(pane_id, RECORD_QUERY_PREFIX)
            if method == "pane.read" and pane_delay_token is not None:
                self.pane_delays.record(pane_delay_token)
                # Must outlast the 2s Attach-echo bound in the app's "RPC does
                # not stall Attach" tests with room for the observer's reply,
                # or the delayed read could finish before the echo is checked.
                time.sleep(3)
                response = {
                    "id": envelope.get("id"),
                    "result": self._pane_read_result(pane_id, "delayed"),
                }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7
            elif method == "pane.read" and pane_await_delay_token is not None:
                observed = self.pane_delays.wait(pane_await_delay_token)
                response = {
                    "id": envelope.get("id"),
                    "result": self._pane_read_result(
                        pane_id,
                        "observed" if observed else "not observed",
                    ),
                }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7
            elif method == "pane.read" and record_query is not None:
                # Reading the records ends the test's launch.
                with self.script_lock:
                    self.worktree_launches.pop(record_query, None)
                    self.finished_worktree_launches.add(record_query)
                response = {
                    "id": envelope.get("id"),
                    "result": self._pane_read_result(
                        pane_id,
                        self._recorded(record_query),
                    ),
                }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7
            elif method == "pane.read" and pane_observer_token is not None:
                observed = self.pane_hangs.wait(pane_observer_token)
                response = {
                    "id": envelope.get("id"),
                    "result": self._pane_read_result(
                        pane_id,
                        "observed" if observed else "not observed",
                    ),
                }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7
            elif method == "fixture.await_hang":
                response = {
                    "id": envelope.get("id"),
                    "result": {
                        "observed": self.hang_requests.wait(envelope.get("extra"))
                    },
                }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7
            elif method == "oversized":
                payload = b"x" * (1_048_576 + 1)
                chunk_size = 16 * 1024
            else:
                token = self._scripted_run_token(params)
                if token is not None:
                    self._record(token, method, params)
                    behavior = token.split(":")[1]
                    self._worktree_launch_state(token)
                    if method == "agent.start" and behavior == "startdrop":
                        return
                    if method == "worktree.create" and behavior in (
                        "createhangs",
                        "hungrefuse",
                        "hungnothing",
                    ):
                        # `git worktree add` on a large repository outlives
                        # the create budget; herdr may have made the worktree.
                        state = self._worktree_launch_state(token)
                        if state is not None and behavior != "hungnothing":
                            with self.script_lock:
                                state["made"] = True
                        self._hold_until_closed(connection)
                        return
                    if method == "worktree.create" and behavior == "slowcreate":
                        time.sleep(SLOW_CREATE_SECONDS)
                launch = self._launch_race_response(method, params, token)
                error = None if launch is not None else self._scripted_error(method, token)
                if launch is not None:
                    response = {"id": envelope.get("id"), **launch}
                elif error is not None:
                    response = {"id": envelope.get("id"), "error": error}
                elif method == "agent.rename" and params.get("target") == "api-error":
                    response = {
                        "id": envelope.get("id"),
                        "error": {"code": 500, "message": "scripted failure"},
                    }
                else:
                    response = {
                        "id": envelope.get("id"),
                        "result": self._result(method, params, token),
                    }
                payload = json.dumps(response, separators=(",", ":")).encode() + b"\n"
                chunk_size = 7

            for offset in range(0, len(payload), chunk_size):
                try:
                    connection.sendall(payload[offset : offset + chunk_size])
                except BrokenPipeError:
                    return

    @staticmethod
    def _fixture_token(value: object, prefix: str) -> Optional[str]:
        if not isinstance(value, str) or not value.startswith(prefix):
            return None
        token = value[len(prefix) :]
        return token or None

    @staticmethod
    def _scripted_run_token(params: object) -> Optional[str]:
        if not isinstance(params, dict):
            return None
        match = SCRIPT_TOKEN_PATTERN.search(
            json.dumps(params, separators=(",", ":"), sort_keys=True)
        )
        return match.group(0) if match else None

    def _record(self, token: str, method: str, params: object) -> None:
        entry = "{} {}".format(
            method,
            json.dumps(params, separators=(",", ":"), sort_keys=True),
        )
        with self.script_lock:
            self.recorded_requests.setdefault(token, []).append(entry)

    def _recorded(self, token: str) -> str:
        with self.script_lock:
            return "\n".join(self.recorded_requests.get(token, []))

    def _launch_race_response(
        self, method: str, params: object, token: Optional[str]
    ) -> Optional[dict]:
        """herdr 0.9.1's launch reconcile race, or None for other scripts.

        `launchrace` reports its agent idle at once but keeps it
        `launch_pending` (so `agent.prompt` answers `agent_not_ready`) until
        an `agent.get` lands at or after `LAUNCH_SETTLE_SECONDS`, like a
        lifecycle-hook agent that goes idle before herdr's settle.
        `launchworking` stays `working`, so it never settles. For both, an
        `agent.get` at or after `LAUNCH_DEADLINE_SECONDS` on a still-pending
        launch clears the name and the gate instead, and records
        `LAUNCH_NAME_CLEARED`. `agent.list` and `agent.prompt` never reconcile.
        """
        if token is None or token.split(":")[1] not in ("launchrace", "launchworking"):
            return None
        working = token.split(":")[1] == "launchworking"
        pane_id = "pane:" + token
        request = params if isinstance(params, dict) else {}
        with self.script_lock:
            if method == "agent.start":
                launch = {
                    "started": time.monotonic(),
                    "pending": True,
                    "name": request.get("name"),
                }
                self.launches[token] = launch
                return {
                    "result": {
                        "type": "agent_started",
                        "argv": [request.get("kind", "codex")],
                        "agent": self._launch_agent(pane_id, token, launch, working),
                    }
                }
            launch = self.launches.get(token)
            if launch is None or method not in ("agent.get", "agent.prompt"):
                return None
            if method == "agent.get":
                elapsed = time.monotonic() - launch["started"]
                if launch["pending"] and elapsed >= LAUNCH_DEADLINE_SECONDS:
                    launch["pending"] = False
                    launch["name"] = None
                    self.recorded_requests.setdefault(token, []).append(LAUNCH_NAME_CLEARED)
                elif launch["pending"] and not working and elapsed >= LAUNCH_SETTLE_SECONDS:
                    launch["pending"] = False
                return {
                    "result": {
                        "type": "agent_info",
                        "agent": self._launch_agent(pane_id, token, launch, working),
                    }
                }
            if launch["pending"]:
                return {
                    "error": {
                        "code": AGENT_NOT_READY_CODE,
                        "message": "agent " + pane_id + " is not an active named agent",
                    }
                }
            return {
                "result": {
                    "type": "agent_prompted",
                    "agent": self._launch_agent(pane_id, token, launch, working),
                }
            }

    def _launch_agent(self, pane_id: str, token: str, launch: dict, working: bool) -> object:
        agent = self._agent(
            pane_id,
            "workspace-1",
            status="working" if working else "idle",
            tab_id="tab:" + token,
        )
        agent["launch_pending"] = launch["pending"]
        if launch["name"] is not None:
            agent["name"] = launch["name"]
        return agent

    def _scripted_error(self, method: str, token: Optional[str]) -> Optional[dict]:
        """The failure a token scripts for `agent.start`, or None to succeed.

        `busyN` refuses the first N starts the way herdr 0.7.5 refuses a pane
        whose shell has not reached its prompt, then lets the launch through;
        `busyforever` never lets it through; `startfails` refuses once with a
        code no retry policy may swallow; `startdrop` is handled in `_serve`
        by closing the channel with no reply (an ambiguous transport failure);
        `launchrace` and `launchworking` are answered by
        `_launch_race_response` before this is asked; `ok`,
        `SCREEN_BEHAVIORS` and the `WORKTREE_LAUNCH_BEHAVIORS`
        outside `REFUSED_WORKTREE_AGENT_STARTS` script no `agent.start`
        failure at all.

        A word outside that set is refused rather than treated as `ok`: a
        mistyped behaviour would otherwise leave a test green while proving
        nothing, which is the one way a fixture can lie.

        `worktreegroup` and `worktreegroupraced` refuse `tab.close` and
        `pane.close` the way herdr 0.9.x refuses emptying a main checkout's
        Workspace that has linked worktree Workspaces.
        """
        if (
            token is not None
            and method in ("tab.close", "pane.close")
            and token.split(":")[1] in WORKTREE_GROUP_BEHAVIORS
        ):
            return {
                "code": "confirmation_required",
                "message": "closing this tab would close a worktree group",
            }
        if token is None or method != "agent.start":
            return None
        behavior = token.split(":")[1]
        if behavior in REFUSED_WORKTREE_AGENT_STARTS:
            return dict(NON_RETRYABLE_START_FAILURE)
        if behavior in WORKTREE_LAUNCH_BEHAVIORS:
            return None
        if behavior == "ok":
            return None
        if behavior in SCREEN_BEHAVIORS:
            return None
        if behavior == "startdrop":
            return None
        if behavior == "startfails":
            return dict(NON_RETRYABLE_START_FAILURE)
        if behavior == "busyforever":
            return dict(AGENT_PANE_BUSY)
        if behavior.startswith("busy") and behavior[4:].isdigit():
            with self.script_lock:
                served = self.agent_start_attempts.get(token, 0)
                self.agent_start_attempts[token] = served + 1
            if served < int(behavior[4:]):
                return dict(AGENT_PANE_BUSY)
            return None
        return {
            "code": "fixture_unknown_behavior",
            "message": "no scripted behaviour named " + behavior,
        }

    def _serve_events(self, connection: socket.socket, envelope: object) -> None:
        request_id = envelope.get("id") if isinstance(envelope, dict) else None
        params = envelope.get("params", {}) if isinstance(envelope, dict) else {}
        subscriptions = params.get("subscriptions", []) if isinstance(params, dict) else []
        pane_ids = {
            subscription.get("pane_id")
            for subscription in subscriptions
            if isinstance(subscription, dict) and subscription.get("pane_id") is not None
        }

        if "fixture:reject" in pane_ids:
            self._send_event_line(
                connection,
                {
                    "id": request_id,
                    "error": {
                        "code": "fixture_rejected",
                        "message": "scripted rejection",
                    },
                },
            )
            return

        if "fixture:no-ack" in pane_ids:
            while connection.recv(1024):
                pass
            return

        self._send_event_line(
            connection,
            {
                "id": request_id,
                "result": {"type": "subscription_started"},
            },
        )

        if "fixture:remote-close" in pane_ids:
            self._send_event_line(
                connection,
                {
                    "event": "pane_agent_status_changed",
                    "data": {"pane_id": "fixture:remote-close"},
                },
            )
            return

        if subscriptions != [{"type": "pane.created"}]:
            self._send_event_line(
                connection,
                {"event": "fixture_noncanonical_subscription", "data": subscriptions},
            )
            return

        try:
            connection.sendall(b"this is not json\n")
        except BrokenPipeError:
            return
        lines = [
            {
                "event": "future_herdr_event",
                "data": {"value": "preserved"},
            },
            {
                "event": "pane_created",
                "data": {"pane_id": "fixture:event"},
            },
            {
                "event": "pane_created",
                "data": {"pane_id": "fixture:event"},
            },
        ]
        for line in lines:
            self._send_event_line(connection, line)

        while connection.recv(1024):
            pass

    def _send_event_line(self, connection: socket.socket, line: object) -> None:
        payload = json.dumps(line, separators=(",", ":")).encode() + b"\n"
        for offset in range(0, len(payload), 7):
            try:
                connection.sendall(payload[offset : offset + 7])
            except BrokenPipeError:
                return

    def _result(self, method: str, params: object, token: Optional[str] = None) -> object:
        if token is not None:
            scripted = self._scripted_result(method, token, params)
            if scripted is not None:
                return scripted
        if method == "ping" or method == "partial":
            return {"protocol": 17, "version": "fake"}
        if method == "agent.list":
            agents = []
            for live, state in self._live_worktree_launches():
                self._record(live, method, params)
                agents.extend(state["agents"])
            return {"type": "agent_list", "agents": agents}
        if method == "session.snapshot":
            made = []
            env_tabs = []
            for live, state in self._live_worktree_launches():
                self._record(live, method, params)
                if state["made"]:
                    made.append(live)
                if state.get("env_tab"):
                    env_tabs.append(live)
            return {
                "type": "session_snapshot",
                "snapshot": {
                    "version": "fake",
                    "protocol": 17,
                    "workspaces": [self._workspace("workspace:" + t) for t in made],
                    "tabs": [self._tab("tab:" + t, "workspace:" + t) for t in made]
                    + [self._tab("env-tab:" + t, "workspace:" + t, number=2) for t in env_tabs],
                    "panes": [
                        self._pane("pane:" + t, "tab:" + t, "workspace:" + t)
                        for t in made
                    ]
                    + [
                        self._pane("env-pane:" + t, "env-tab:" + t, "workspace:" + t)
                        for t in env_tabs
                    ],
                    "layouts": [],
                    "agents": [],
                },
            }
        if method == "pane.read":
            request = params if isinstance(params, dict) else {}
            pane_id = request.get("pane_id", "pane-1")
            source = request.get("source", "recent")
            output_format = request.get("format", "text")
            return self._pane_read_result(
                pane_id,
                "fixture output",
                source=source,
                output_format=output_format,
            )
        if method == "agent.read":
            request = params if isinstance(params, dict) else {}
            target = request.get("target", "pane-1")
            source = request.get("source", "recent")
            output_format = request.get("format", "text")
            text = "fixture agent output"
            if output_format == "ansi" and request.get("strip_ansi") is False:
                text = "\x1b[31mfixture agent output\x1b[0m"
            return self._pane_read_result(
                target,
                text,
                source=source,
                output_format=output_format,
            )
        if method == "agent.prompt":
            request = params if isinstance(params, dict) else {}
            is_expected_prompt = (
                request.get("target") == "pane-1"
                and request.get("text") == "fixture prompt"
                and "wait" not in request
            )
            pane_id = "pane-1" if is_expected_prompt else "fixture:invalid-prompt"
            return {
                "type": "agent_prompted",
                "agent": self._agent(pane_id, "workspace-1", status="working"),
            }
        if method == "agent.send_keys":
            # Thin ok-envelope RPC; key-spelling contract is asserted in unit
            # tests against the spellings Monitor ships (enter/esc/ctrl+c/…).
            return {"type": "ok"}
        if method == "pane.close":
            return {"type": "ok"}
        if method == "tab.create":
            return {
                "type": "tab_created",
                "tab": self._tab("tab-new", "workspace-1"),
                "root_pane": self._pane("pane-new", "tab-new", "workspace-1"),
            }
        if method == "worktree.create":
            return {
                "type": "worktree_created",
                "workspace": self._workspace("workspace-worktree"),
                "tab": self._tab("tab-worktree", "workspace-worktree"),
                "root_pane": self._pane(
                    "pane-worktree", "tab-worktree", "workspace-worktree"
                ),
                "worktree": {
                    "path": "/tmp/worktree",
                    "branch": "task/fixture",
                    "is_bare": False,
                    "is_detached": False,
                    "is_prunable": False,
                    "is_linked_worktree": True,
                    "label": "fixture",
                    "open_workspace_id": "workspace-worktree",
                },
            }
        if method == "worktree.list":
            # Every worktree launch lists its source first. An unscripted
            # one gets a lone main checkout, so it goes on to create.
            request = params if isinstance(params, dict) else {}
            return {
                "type": "worktree_list",
                "source": {
                    "repo_key": "fixture",
                    "repo_name": "fixture",
                    "repo_root": "/tmp/fixture-checkout",
                    "source_checkout_path": "/tmp/fixture-checkout",
                    "source_workspace_id": request.get("workspace_id"),
                },
                "worktrees": [
                    self._worktree_info(
                        "/tmp/fixture-checkout", "main", False, request.get("workspace_id")
                    )
                ],
            }
        if method == "workspace.create":
            return {
                "type": "workspace_created",
                "workspace": self._workspace("workspace-new"),
                "tab": self._tab("tab-workspace", "workspace-new"),
                "root_pane": self._pane(
                    "pane-workspace", "tab-workspace", "workspace-new"
                ),
            }
        if method == "workspace.close":
            return {"type": "ok"}
        if method == "agent.start":
            pane_id = params.get("pane_id", "pane-new") if isinstance(params, dict) else "pane-new"
            workspace_id = (
                "workspace-worktree"
                if pane_id == "pane-worktree"
                else "workspace-new"
                if pane_id == "pane-workspace"
                else "workspace-1"
            )
            return {
                "type": "agent_started",
                "argv": ["codex"],
                "agent": self._agent(pane_id, workspace_id),
            }
        if method in ("agent.rename", "agent.focus", "agent.get"):
            return {"type": "agent_info", "agent": self._agent()}
        if method == "workspace.rename":
            return {"type": "workspace_info", "workspace": self._workspace()}
        return {"type": "ok"}

    def _worktree_launch_state(self, token: str) -> Optional[dict]:
        """The live state of a worktree launch script, created on its first
        request: whether its worktree exists yet, and the Agents `agent.list`
        shows. The worktree is the linked one on `task/<token>` at
        `/tmp/worktree/<token>`, open in `workspace:<token>` with tab
        `tab:<token>` and root pane `pane:<token>` (the ids `worktree.create`
        answers with). None for any other token.

        A finished launch (its records were read) stays finished: a late
        request such as the launch settle's `agent.get` must not bring its
        worktree and Agents back into later tests' listings.
        """
        behavior = token.split(":")[1]
        if behavior not in WORKTREE_LAUNCH_BEHAVIORS:
            return None
        with self.script_lock:
            if token in self.finished_worktree_launches:
                return None
            state = self.worktree_launches.get(token)
            if state is not None:
                return state
        agents = []
        if behavior == "rootagent":
            agents.append(
                self._agent("pane:" + token, "workspace:" + token, tab_id="tab:" + token)
            )
        # taggedPendingAgentBeforeKindDetectionIsReturned: detection is not ready.
        if behavior == "pendingagent":
            agent = self._agent("pane:" + token, "workspace:" + token, tab_id="tab:" + token)
            agent.update(agent=None, launch_pending=True)
            agents.append(agent)
        if behavior == "envagent":
            agents.append(
                self._agent("env-pane:" + token, "workspace:" + token, tab_id="env-tab:" + token)
            )
        if behavior == "existingkinds":
            agents.append(
                self._agent(
                    "existing-claude:" + token,
                    "workspace:" + token,
                    tab_id="existing-tab:" + token,
                    kind="claude",
                )
            )
        if behavior in ("existingagent", "existingkinds"):
            agents.append(
                self._agent(
                    "existing-pane:" + token,
                    "workspace:" + token,
                    tab_id="existing-tab:" + token,
                )
            )
        state = {
            "made": behavior in ("lostcreate", "rootagent", "pendingagent", "envagent", "envorphan")
            or behavior.startswith("existing"),
            "agents": agents,
            "env_tab": behavior in ("envagent", "envorphan"),
        }
        with self.script_lock:
            return self.worktree_launches.setdefault(token, state)

    def _live_worktree_launches(self) -> list[tuple[str, dict]]:
        with self.script_lock:
            return [(token, dict(state)) for token, state in self.worktree_launches.items()]

    @staticmethod
    def _hold_until_closed(connection: socket.socket) -> None:
        """Leaves a request unanswered until the client closes the channel."""
        connection.settimeout(HUNG_CREATE_CAP_SECONDS)
        try:
            while connection.recv(1024):
                pass
        except OSError:
            pass

    def _scripted_result(
        self, method: str, token: str, params: object = None
    ) -> Optional[object]:
        """Ids derived from `token`, so a scripted launch stays self-identifying.

        `tab.create`, `worktree.create` and `workspace.create` hand the
        Transport a pane the token names; the `agent.start`, `pane.close`,
        `worktree.remove` and `workspace.close` that follow therefore carry
        it back without the test having to inject anything else.

        `worktree.list` is `_worktree_list`. `pane.read` on the pane of an
        `SCREEN_BEHAVIORS` launch answers with its scripted screen, and
        `agent.get` on a `signin` pane names cursor, whoever launched it.
        `pane.get`, `tab.get` and `tab.list` describe the token's Workspace
        holding one tab with one pane; with `worktreegroupraced` that
        Workspace gained a second tab after the refused close.
        """
        pane_id = "pane:" + token
        tab_id = "tab:" + token
        workspace_id = "workspace:" + token
        behavior = token.split(":")[1]
        if method == "pane.read" and behavior in SCREEN_BEHAVIORS:
            with self.script_lock:
                served = self.screen_reads.get(token, 0)
                self.screen_reads[token] = served + 1
            first, later = SCREEN_BEHAVIORS[behavior]
            request = params if isinstance(params, dict) else {}
            return self._pane_read_result(
                pane_id,
                later if served > 0 else first,
                source=request.get("source", "recent"),
            )
        if method == "agent.get" and behavior == "signin":
            return {
                "type": "agent_info",
                "agent": self._agent(pane_id, "workspace-1", tab_id=tab_id, kind="cursor"),
            }
        if method == "pane.get":
            return {"type": "pane_info", "pane": self._pane(pane_id, tab_id, workspace_id)}
        if method == "tab.get":
            return {"type": "tab_info", "tab": self._tab(tab_id, workspace_id)}
        if method == "tab.list" and behavior in WORKTREE_GROUP_BEHAVIORS:
            tabs = [self._tab(tab_id, workspace_id)]
            if behavior == "worktreegroupraced":
                tabs.append(self._tab("new-tab:" + token, workspace_id, number=2))
            return {"type": "tab_list", "tabs": tabs}
        if method == "tab.create":
            return {
                "type": "tab_created",
                "tab": self._tab(tab_id, "workspace-1"),
                "root_pane": self._pane(pane_id, tab_id, "workspace-1"),
            }
        if method == "worktree.create":
            return {
                "type": "worktree_created",
                "workspace": self._workspace(workspace_id),
                "tab": self._tab(tab_id, workspace_id),
                "root_pane": self._pane(pane_id, tab_id, workspace_id),
                "worktree": {
                    "path": "/tmp/worktree/" + token,
                    "branch": "task/" + token,
                    "is_bare": False,
                    "is_detached": False,
                    "is_prunable": False,
                    "is_linked_worktree": True,
                    "label": "fixture",
                    "open_workspace_id": workspace_id,
                },
            }
        if method == "worktree.list":
            return self._worktree_list(token, params)
        if method == "workspace.create":
            return {
                "type": "workspace_created",
                "workspace": self._workspace(workspace_id),
                "tab": self._tab(tab_id, workspace_id),
                "root_pane": self._pane(pane_id, tab_id, workspace_id),
            }
        if method == "agent.start":
            # The pane the Transport names: the token's own, or another the
            # script opened (`env-pane:<token>`).
            request = params if isinstance(params, dict) else {}
            started_pane = request.get("pane_id") or pane_id
            return {
                "type": "agent_started",
                "argv": ["codex"],
                "agent": self._agent(started_pane, workspace_id, tab_id=tab_id),
            }
        if method == "worktree.remove":
            return {
                "type": "worktree_removed",
                "forced": False,
                "path": "/tmp/worktree/" + token,
                "workspace_id": workspace_id,
            }
        return None

    def _worktree_list(self, token: str, params: object) -> object:
        """The `worktree.list` a token scripts, for the Workspace it names.

        The source checkout is one the test itself builds with real git on
        this Host, `worktree-<unique>/<name>` beside the count file, so the
        Transport's fetch-and-resolve step runs against it. The name holds a
        space, both quotes and a backslash on purpose: every such run also
        proves the path reaches git intact. It is open in the requesting
        Workspace, or with `linkedsource` that Workspace holds a linked
        worktree of it instead, which herdr refuses as a source.

        Once the token's worktree exists (`_worktree_launch_state`) it is
        listed too.
        """
        request = params if isinstance(params, dict) else {}
        source_workspace_id = request.get("workspace_id")
        behavior = token.split(":")[1]
        checkout = os.path.join(
            os.path.dirname(os.path.abspath(self.count_file)),
            "worktree-" + token.split(":")[2],
            "it's a \"checkout\" \\ dir",
        )
        linked_source = behavior == "linkedsource"
        worktrees = [
            self._worktree_info(
                checkout + "-linked" if linked_source else checkout,
                "main",
                linked_source,
                source_workspace_id,
            )
        ]
        state = self._worktree_launch_state(token)
        with self.script_lock:
            made = state is not None and state["made"]
        if made:
            worktrees.append(
                self._worktree_info(
                    "/tmp/worktree/" + token, "task/" + token, True, "workspace:" + token
                )
            )
        return {
            "type": "worktree_list",
            "source": {
                "repo_key": "fixture:" + token,
                "repo_name": "fixture",
                "repo_root": checkout,
                "source_checkout_path": checkout,
                "source_workspace_id": None if linked_source else source_workspace_id,
            },
            "worktrees": worktrees,
        }

    @staticmethod
    def _worktree_info(
        path: str, branch: str, linked: bool, open_workspace_id: Optional[str]
    ) -> object:
        return {
            "path": path,
            "branch": branch,
            "is_bare": False,
            "is_detached": False,
            "is_prunable": False,
            "is_linked_worktree": linked,
            "label": "fixture",
            "open_workspace_id": open_workspace_id,
        }

    @staticmethod
    def _pane_read_result(
        pane_id: str,
        text: str,
        source: str = "recent",
        output_format: str = "text",
    ) -> object:
        return {
            "type": "pane_read",
            "read": {
                "pane_id": pane_id,
                "workspace_id": "workspace-1",
                "tab_id": "tab-1",
                "source": source,
                "format": output_format,
                "text": text,
                "revision": 1,
                "truncated": False,
            },
        }

    def _agent(
        self,
        pane_id: str = "pane-1",
        workspace_id: str = "workspace-1",
        status: str = "idle",
        tab_id: Optional[str] = None,
        kind: str = "codex",
    ) -> object:
        if tab_id is None:
            if workspace_id == "workspace-worktree":
                tab_id = "tab-worktree"
            elif workspace_id == "workspace-new":
                tab_id = "tab-workspace"
            else:
                tab_id = "tab-new"
        return {
            "terminal_id": "terminal-1",
            "agent": kind,
            "terminal_title": "fixture",
            "terminal_title_stripped": "fixture",
            "agent_status": status,
            "workspace_id": workspace_id,
            "tab_id": tab_id,
            "pane_id": pane_id,
            "focused": False,
            "cwd": "/tmp",
            "foreground_cwd": "/tmp",
            "revision": 1,
        }

    def _workspace(self, workspace_id: str = "workspace-1") -> object:
        return {
            "workspace_id": workspace_id,
            "number": 1,
            "label": "Fixture",
            "focused": False,
            "pane_count": 1,
            "tab_count": 1,
            "active_tab_id": "tab-1",
            "agent_status": "idle",
        }

    def _tab(self, tab_id: str, workspace_id: str, number: int = 1) -> object:
        return {
            "tab_id": tab_id,
            "workspace_id": workspace_id,
            "number": number,
            "label": "Fixture",
            "focused": False,
            "pane_count": 1,
            "agent_status": "idle",
        }

    def _pane(self, pane_id: str, tab_id: str, workspace_id: str) -> object:
        return {
            "pane_id": pane_id,
            "terminal_id": f"terminal-{pane_id}",
            "workspace_id": workspace_id,
            "tab_id": tab_id,
            "focused": False,
            "agent_status": "idle",
            "revision": 1,
        }

    def _increment_count(self) -> None:
        with self.count_lock:
            self.count += 1
            self._write_count()

    def _write_count(self) -> None:
        temporary = f"{self.count_file}.tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            handle.write(f"{self.count}\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, self.count_file)

    def _unlink_paths(self) -> None:
        for path in (self.socket_path, *self.stale_socket_paths):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def main() -> None:
    arguments = parse_arguments()
    server = Server(arguments.socket, arguments.stale_socket, arguments.count_file)

    def stop(_signal: int, _frame: object) -> None:
        server.close()
        raise SystemExit(0)

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    server.start()


if __name__ == "__main__":
    main()
