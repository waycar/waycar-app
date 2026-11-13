#!/usr/bin/env python3
"""Unit tests for scripts/asc_client.py and scripts/asc-review-state.py.

Stubs only: no network and no API key. Python 3.9 compatible, like the
scripts (the Mac's /usr/bin/python3)."""
import contextlib
import http.client
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import asc_client  # noqa: E402

_spec = importlib.util.spec_from_file_location("asc_review_state", HERE / "asc-review-state.py")
review = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(review)


class Response:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return self.body


def http_error(code, body=b"", headers=None):
    return urllib.error.HTTPError("https://example.invalid", code, "error", headers or {}, io.BytesIO(body))


class FakeAPI:
    """urlopen stand-in: each call takes the next outcome, a body or an exception."""

    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.requests = []

    def __call__(self, request, timeout=None):
        self.requests.append((request.get_method(), request.full_url, timeout, request.get_header("Authorization")))
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return Response(outcome)


def client(api, clock=lambda: 1000.0):
    sleeps = []
    signs = []

    def sign(key_id, issuer, key_path, now):
        signs.append(now)
        return f"token{len(signs)}"

    made = asc_client.Client("KEY", "ISSUER", "/key.p8", urlopen=api, sleep=sleeps.append, clock=clock, sign=sign)
    return made, sleeps, signs


class ClientTests(unittest.TestCase):
    def setUp(self):
        stderr = contextlib.redirect_stderr(io.StringIO())
        self.stderr = stderr.__enter__()
        self.addCleanup(stderr.__exit__, None, None, None)

    def test_get_retries_server_errors_with_backoff(self):
        api = FakeAPI(http_error(500), http_error(503), b'{"data": [1]}')
        made, sleeps, _ = client(api)
        self.assertEqual(made.get("/v1/builds"), {"data": [1]})
        self.assertEqual(sleeps, [2.0, 4.0])
        self.assertEqual([r[2] for r in api.requests], [30, 30, 30])
        self.assertIn("retrying in 2 s (attempt 2 of 4)", self.stderr.getvalue())

    def test_get_retries_connection_failures(self):
        api = FakeAPI(ConnectionResetError(54, "reset"), urllib.error.URLError(ConnectionRefusedError(61, "refused")),
                      TimeoutError("timed out"), b'{"data": []}')
        made, sleeps, _ = client(api)
        self.assertEqual(made.get("/v1/builds"), {"data": []})
        self.assertEqual(sleeps, [2.0, 4.0, 8.0])

    def test_get_honours_retry_after_up_to_a_minute(self):
        api = FakeAPI(http_error(429, headers={"Retry-After": "10"}), http_error(429, headers={"Retry-After": "600"}), b"{}")
        made, sleeps, _ = client(api)
        made.get("/v1/builds")
        self.assertEqual(sleeps, [10.0, 60.0])

    def test_get_gives_up_after_four_attempts(self):
        body = b'{"errors": [{"code": "UNEXPECTED_ERROR", "detail": "An unexpected error occurred."}]}'
        api = FakeAPI(*[http_error(500, body) for _ in range(4)])
        made, sleeps, _ = client(api)
        with self.assertRaises(asc_client.ASCError) as caught:
            made.get("/v1/builds")
        self.assertTrue(caught.exception.temporary)
        self.assertEqual(str(caught.exception),
                         "GET /v1/builds failed: HTTP 500 UNEXPECTED_ERROR An unexpected error occurred.")
        self.assertEqual(len(api.requests), 4)
        self.assertEqual(sleeps, [2.0, 4.0, 8.0])

    def test_get_retries_a_server_error_whose_body_is_cut_short(self):
        truncated = http_error(500)
        truncated.read = mock.Mock(side_effect=http.client.IncompleteRead(b'{"err'))
        made, sleeps, _ = client(FakeAPI(truncated, b"{}"))
        self.assertEqual(made.get("/v1/builds"), {})
        self.assertEqual(sleeps, [2.0])

    def test_get_does_not_retry_client_errors(self):
        body = b'{"errors": [{"code": "PARAMETER_ERROR.ILLEGAL", "detail": "The parameter \'sort\' can not be used"}]}'
        made, sleeps, _ = client(FakeAPI(http_error(400, body)))
        with self.assertRaises(asc_client.ASCError) as caught:
            made.get("/v1/apps/1/appStoreVersions?sort=-createdDate")
        self.assertFalse(caught.exception.temporary)
        self.assertIn("HTTP 400 PARAMETER_ERROR.ILLEGAL The parameter 'sort'", str(caught.exception))
        self.assertEqual(sleeps, [])

    def test_post_is_not_replayed_without_verify(self):
        api = FakeAPI(http_error(500))
        made, sleeps, _ = client(api)
        with self.assertRaises(asc_client.ASCError):
            made.post("/v1/betaGroups/g/relationships/builds", {"data": []})
        self.assertEqual(len(api.requests), 1)
        self.assertEqual(sleeps, [])

    def test_post_that_landed_is_not_sent_again(self):
        api = FakeAPI(http_error(502))
        made, sleeps, _ = client(api)
        checks = []
        self.assertIsNone(made.post("/v1/x", {"data": []}, verify=lambda: checks.append(1) or True))
        self.assertEqual((len(api.requests), len(checks), sleeps), (1, 1, [2.0]))

    def test_post_that_did_not_land_is_sent_again(self):
        api = FakeAPI(ConnectionResetError(54, "reset"), b"")
        made, _, _ = client(api)
        self.assertIsNone(made.post("/v1/x", {"data": []}, verify=lambda: False))
        self.assertEqual([r[0] for r in api.requests], ["POST", "POST"])

    def test_post_client_error_skips_verify(self):
        made, _, _ = client(FakeAPI(http_error(409)))
        with self.assertRaises(asc_client.ASCError):
            made.post("/v1/x", {"data": []}, verify=lambda: self.fail("verify called"))

    def test_token_is_reused_then_refreshed(self):
        now = [1000.0]
        api = FakeAPI(b"{}", b"{}", b"{}")
        made, _, signs = client(api, clock=lambda: now[0])
        made.get("/a")
        now[0] += 14 * 60
        made.get("/b")
        now[0] += 60
        made.get("/c")
        self.assertEqual(signs, [1000.0, 1900.0])
        self.assertEqual([r[3] for r in api.requests], ["Bearer token1", "Bearer token1", "Bearer token2"])

    def test_get_all_follows_next_pages_on_the_api_host_only(self):
        api = FakeAPI(json.dumps({"data": [1], "links": {"next": asc_client.API + "/v1/x?cursor=2"}}).encode(),
                      b'{"data": [2]}')
        made, _, _ = client(api)
        self.assertEqual(made.get_all("/v1/x"), [1, 2])
        self.assertEqual(api.requests[1][1], asc_client.API + "/v1/x?cursor=2")
        made, _, _ = client(FakeAPI(b'{"data": [1], "links": {"next": "https://elsewhere.invalid/v1/x"}}'))
        with self.assertRaises(asc_client.ASCError):
            made.get_all("/v1/x")

    def test_der_signature_becomes_raw_r_and_s(self):
        r = b"\x00" + b"\x81" * 32  # a high bit gets a 0x00 pad
        s = b"\x01" * 31  # a short integer gets left-padded
        der = bytes([0x30, 4 + len(r) + len(s), 0x02, len(r)]) + r + bytes([0x02, len(s)]) + s
        self.assertEqual(asc_client.der_to_raw(der), b"\x81" * 32 + b"\x00" + b"\x01" * 31)

    def test_run_maps_errors_to_exit_codes(self):
        def fail(temporary):
            raise asc_client.ASCError("boom", temporary=temporary)
        self.assertEqual(asc_client.run(lambda: fail(True)), asc_client.TEMPFAIL)
        self.assertEqual(asc_client.run(lambda: fail(False)), 1)
        self.assertIn(": boom", self.stderr.getvalue())


class EnvTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        patch = mock.patch.dict(os.environ, {"HOME": self.home.name}, clear=True)
        patch.start()
        self.addCleanup(patch.stop)

    def write_env(self, text):
        Path(self.home.name, ".env").write_text(text)

    def test_load_env_reads_shell_style_lines_and_keeps_set_variables(self):
        os.environ["KEPT"] = "from environment"
        self.write_env("# comment\nexport A=1\nB=\"two words\"\nC='3'\nD=4 # note\nE=\"5 # kept\" # note\n"
                       "KEPT=from file\nnot a line\n")
        asc_client.load_env()
        self.assertEqual({k: os.environ.get(k) for k in "ABCDE"},
                         {"A": "1", "B": "two words", "C": "3", "D": "4", "E": "5 # kept"})
        self.assertEqual(os.environ["KEPT"], "from environment")

    def test_missing_env_file_is_fine(self):
        asc_client.load_env()

    def test_from_env_names_missing_variables(self):
        with self.assertRaises(asc_client.ASCError) as caught:
            asc_client.Client.from_env()
        self.assertIn("ASC_API_KEY_ID and ASC_API_ISSUER_ID not set", str(caught.exception))

    def test_from_env_takes_the_key_path_from_env_file(self):
        Path(self.home.name, "key.p8").write_text("key")
        self.write_env("ASC_API_KEY_ID=K\nASC_API_ISSUER_ID=I\nASC_API_KEY_PATH=~/key.p8\n")
        made = asc_client.Client.from_env()
        self.assertEqual((made.key_id, made.issuer, made.key_path, made.app_id),
                         ("K", "I", os.path.join(self.home.name, "key.p8"), asc_client.WAYCAR_APP_ID))

    def test_from_env_refuses_a_missing_key(self):
        self.write_env("ASC_API_KEY_ID=K\nASC_API_ISSUER_ID=I\n")
        with self.assertRaises(asc_client.ASCError) as caught:
            asc_client.Client.from_env()
        self.assertIn("AuthKey_K.p8", str(caught.exception))


def version(name, created, store="WAITING_FOR_REVIEW", app=None):
    return {"attributes": {"versionString": name, "createdDate": created, "appStoreState": store,
                           "appVersionState": app or store}}


def submission(state, submitted):
    return {"attributes": {"state": state, "submittedDate": submitted}}


class SelectionTests(unittest.TestCase):
    def test_newest_version_compares_times_across_offsets(self):
        older = version("1.1.3", "2026-10-15T09:00:00Z")
        newer = version("1.2.2", "2026-10-15T03:00:39-07:00")  # 10:00:39 UTC
        self.assertIs(review.newest_version([newer, older]), newer)
        self.assertIs(review.newest_version([older, newer]), newer)

    def test_latest_submission_prefers_a_draft_then_the_newest(self):
        old = submission("COMPLETE", "2026-10-18T14:51:23.852Z")
        new = submission("UNRESOLVED_ISSUES", "2026-11-01T13:36:11.2Z")
        draft = submission("READY_FOR_REVIEW", None)
        self.assertIs(review.latest_submission([new, old]), new)
        self.assertIs(review.latest_submission([old, draft, new]), draft)
        self.assertIsNone(review.latest_submission([]))

    def test_fetch_state_sorts_locally(self):
        class FakeClient:
            app_id = "1"
            paths = []

            def get_all(self, path):
                self.paths.append(path)
                if "appStoreVersions" in path:
                    return [version("1.1.3", "2026-09-24T16:58:40-07:00", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION"),
                            version("1.2.3", "2026-10-15T03:00:39-07:00", "PREPARE_FOR_SUBMISSION")]
                return [submission("COMPLETE", "2026-10-18T14:51:23.852Z"),
                        submission("UNRESOLVED_ISSUES", "2026-11-01T13:36:11.247Z")]

        fake = FakeClient()
        state = review.fetch_state(fake)
        self.assertEqual(state, {"version": "1.2.3", "created": "2026-10-15T03:00:39-07:00",
                                 "appStoreState": "PREPARE_FOR_SUBMISSION",
                                 "appVersionState": "PREPARE_FOR_SUBMISSION",
                                 "reviewSubmission": "UNRESOLVED_ISSUES", "submitted": "2026-11-01T13:36:11.247Z"})
        self.assertFalse(any("sort" in path for path in fake.paths), fake.paths)
        self.assertEqual(review.describe(state),
                         "version 1.2.3: appStoreState PREPARE_FOR_SUBMISSION, appVersionState PREPARE_FOR_SUBMISSION, "
                         "reviewSubmission UNRESOLVED_ISSUES (submitted 2026-11-01T13:36:11.247Z)")


def state(store, sub="WAITING_FOR_REVIEW", name="1.2.3", app=None):
    return {"version": name, "appStoreState": store, "appVersionState": app or store, "reviewSubmission": sub}


class Watch:
    """Drives review.watch with a fake clock, sleep and fetch."""

    def __init__(self, outcomes, directory=None, interval=300, deadline=3600, now=0.0):
        self.outcomes = list(outcomes)
        self.now = now
        self.lines = []
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.result = review.watch(self.fetch, interval, deadline, directory, clock=lambda: self.now,
                                       sleep=self.sleep, out=lambda text, flush=False: self.lines.append(text))
        self.stderr = stderr.getvalue()

    def fetch(self):
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    def sleep(self, seconds):
        self.now += seconds


class WatchTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def test_silent_until_a_change_then_fires_and_finishes_on_a_final_state(self):
        run = Watch([state("WAITING_FOR_REVIEW"), state("WAITING_FOR_REVIEW"),
                     state("IN_REVIEW", "IN_REVIEW"), state("PENDING_DEVELOPER_RELEASE", "COMPLETE")])
        self.assertEqual(run.lines, [
            "FIRE 1.2.3 WAITING_FOR_REVIEW/WAITING_FOR_REVIEW/WAITING_FOR_REVIEW -> IN_REVIEW/IN_REVIEW/IN_REVIEW",
            "FIRE 1.2.3 IN_REVIEW/IN_REVIEW/IN_REVIEW -> PENDING_DEVELOPER_RELEASE/PENDING_DEVELOPER_RELEASE/COMPLETE",
            "DONE"])
        self.assertEqual(run.result, 0)

    def test_every_final_state_ends_the_watch(self):
        for final in ("READY_FOR_SALE", "PENDING_DEVELOPER_RELEASE", "REJECTED", "METADATA_REJECTED",
                      "DEVELOPER_REJECTED"):
            run = Watch([state("IN_REVIEW"), state(final)])
            self.assertEqual(run.lines[-1], "DONE", final)
        run = Watch([state("IN_REVIEW"), state(None, "COMPLETE", app="READY_FOR_DISTRIBUTION")])
        self.assertEqual(run.lines[-1], "DONE")

    def test_a_final_state_on_the_first_check_fires_once(self):
        run = Watch([state("REJECTED", "UNRESOLVED_ISSUES")])
        self.assertEqual(run.lines, ["FIRE 1.2.3 REJECTED/REJECTED/UNRESOLVED_ISSUES (already final)", "DONE"])

    def test_a_resumed_watch_does_not_report_a_final_state_twice(self):
        directory = self.directory.name
        first = Watch([state("IN_REVIEW"), state("REJECTED", "UNRESOLVED_ISSUES")], directory=directory)
        self.assertEqual(first.lines[-1], "DONE")
        self.assertEqual(len(first.lines), 2)
        resumed = Watch([state("REJECTED", "UNRESOLVED_ISSUES")], directory=directory)
        self.assertEqual(resumed.lines, ["DONE"])

    def test_a_new_version_names_the_old_one(self):
        run = Watch([state("PREPARE_FOR_SUBMISSION", "COMPLETE", name="1.2.2"), state("WAITING_FOR_REVIEW"),
                     state("READY_FOR_SALE")])
        self.assertEqual(run.lines[0], "FIRE 1.2.3 1.2.2:PREPARE_FOR_SUBMISSION/PREPARE_FOR_SUBMISSION/COMPLETE"
                                       " -> WAITING_FOR_REVIEW/WAITING_FOR_REVIEW/WAITING_FOR_REVIEW")

    def test_temporary_failures_go_on_and_the_deadline_counts_them(self):
        error = asc_client.ASCError("GET /v1/x failed: HTTP 503", temporary=True)
        run = Watch([state("WAITING_FOR_REVIEW")] + [error] * 20, interval=300, deadline=1200)
        self.assertEqual(run.lines, ["FIRE 1.2.3 deadline passed after 20m; still "
                                     "WAITING_FOR_REVIEW/WAITING_FOR_REVIEW/WAITING_FOR_REVIEW; "
                                     "last error: GET /v1/x failed: HTTP 503", "DONE"])
        self.assertEqual(run.now, 1200)
        self.assertIn("check failed, trying again: GET /v1/x failed: HTTP 503", run.stderr)

    def test_deadline_without_any_successful_check(self):
        error = asc_client.ASCError("ssh mac: Connection refused", temporary=True)
        run = Watch([error] * 3, interval=300, deadline=600)
        self.assertEqual(run.lines, ["FIRE ? deadline passed after 10m; no successful check; "
                                     "last error: ssh mac: Connection refused", "DONE"])

    def test_a_permanent_failure_stops_the_watch(self):
        with self.assertRaises(asc_client.ASCError):
            Watch([state("WAITING_FOR_REVIEW"), asc_client.ASCError("HTTP 401", temporary=False)])

    def test_a_relaunch_keeps_the_last_state_and_the_deadline(self):
        directory = self.directory.name
        with self.assertRaises(IndexError):  # the first process dies after two checks
            Watch([state("WAITING_FOR_REVIEW"), state("IN_REVIEW")], directory=directory, deadline=3600, now=100.0)
        memory = json.loads(Path(directory, review.STATE_FILE).read_text())
        self.assertEqual((memory["started"], memory["last"]["appStoreState"]), (100.0, "IN_REVIEW"))

        run = Watch([state("IN_REVIEW")] * 20, directory=directory, deadline=3600, now=2000.0)
        self.assertEqual(run.now, 3700.0)  # started at 100, not 2000
        self.assertEqual(run.lines, ["FIRE 1.2.3 deadline passed after 1h; still IN_REVIEW/IN_REVIEW/WAITING_FOR_REVIEW",
                                     "DONE"])
        self.assertNotIn("started", json.loads(Path(directory, review.STATE_FILE).read_text()))


class RemoteTests(unittest.TestCase):
    def remote(self, returncode, stdout="", stderr=""):
        calls = []

        def fake_run(command, **options):
            calls.append((command, options))
            return subprocess.CompletedProcess(command, returncode, stdout, stderr)

        with mock.patch.object(review.subprocess, "run", fake_run), contextlib.redirect_stderr(io.StringIO()):
            try:
                return review.remote_state("mac"), calls
            except asc_client.ASCError as error:
                return error, calls

    def test_remote_state_reads_the_last_json_line(self):
        result, calls = self.remote(0, stdout='motd\n{"version": "1.2.3"}\n')
        self.assertEqual(result, {"version": "1.2.3"})
        self.assertEqual(calls[0][0], ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "mac", "python3", "-"])

    def test_remote_failures_are_temporary_only_for_ssh_and_tempfail(self):
        for code, temporary in ((255, True), (asc_client.TEMPFAIL, True), (1, False), (127, False)):
            error, _ = self.remote(code, stderr="asc-review-state.py: something\n")
            self.assertIsInstance(error, asc_client.ASCError)
            self.assertEqual((error.temporary, str(error)), (temporary, "ssh mac: asc-review-state.py: something"))

    def test_the_program_sent_over_ssh_runs_the_script(self):
        _, calls = self.remote(0, stdout="{}")
        program = calls[0][1]["input"]
        with tempfile.TemporaryDirectory() as home:
            result = subprocess.run([sys.executable, "-"], input=program, capture_output=True, text=True,
                                    cwd=home, env={"HOME": home, "PATH": os.environ.get("PATH", "")})
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stderr.strip(),
                         "asc-review-state.py: ASC_API_KEY_ID and ASC_API_ISSUER_ID not set: export it or add it to ~/.env")


if __name__ == "__main__":
    unittest.main()
