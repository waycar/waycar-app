#!/usr/bin/env python3
"""Unit tests for scripts/whats-new.py; the model call is faked, and git is
faked except for the Repo tests, which use a throwaway repository."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import socket
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path

SCRIPT = Path(__file__).with_name("whats-new.py")
_spec = importlib.util.spec_from_file_location("whats_new", SCRIPT)
assert _spec is not None and _spec.loader is not None
wn = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wn)


class FakeRepo:
    def __init__(self, notes, ancestors, changelog=(), commits=()):
        self.note_list = list(notes)
        self.ancestors = set(ancestors)
        self.changelog = list(changelog)
        self.commit_list = list(commits)
        self.bases = []

    def notes(self):
        return self.note_list

    def is_ancestor(self, commit):
        return commit in self.ancestors

    def fallback_base(self):
        return "FALLBACK"

    def commits(self, base):
        self.bases.append(base)
        return self.commit_list

    def changelog_added(self, base):
        return self.changelog


def entry(build, text="Something changed.", symbol="sparkles"):
    return json.dumps({"build": build, "date": "2026-09-01",
                       "items": [{"symbol": symbol, "text": text}]})


def parsed(build, text="Something changed."):
    return {"build": build, "date": "2026-09-01",
            "items": [{"symbol": "sparkles", "text": text}]}


class ValidateItemsTests(unittest.TestCase):
    def test_unknown_symbol_becomes_sparkles(self):
        items = wn.validate_items([{"symbol": "car.fill", "text": "Faster."},
                                   {"symbol": "mic.fill", "text": "Dictate."}])
        self.assertEqual([i["symbol"] for i in items], ["sparkles", "mic.fill"])

    def test_long_text_is_cut_at_the_last_clause_with_a_period(self):
        text = ("Filter the Hosts list by Host and Workspace, pin favorite Agents "
                "to the top, and see each Agent's status at a glance from anywhere")
        (item,) = wn.validate_items([{"symbol": "network", "text": text}])
        self.assertEqual(item["text"], "Filter the Hosts list by Host and "
                                       "Workspace, pin favorite Agents to the top.")

    def test_clause_cut_drops_trailing_stopwords(self):
        text = "Hosts reconnect when you wake the device and; " + "x" * 80
        self.assertEqual(wn.truncate(text, limit=60),
                         "Hosts reconnect when you wake the device.")

    def test_too_early_a_clause_falls_back_to_a_word_cut(self):
        text = ("The Console shows a Needs Attention pill; tap it to jump to the "
                "Agent waiting on you and answer it right from the list")
        cut = wn.truncate(text)
        self.assertEqual(cut, "The Console shows a Needs Attention pill; tap it "
                              "to jump to the Agent waiting on you and answer it…")

    def test_word_cut_drops_dangling_stopwords_and_adds_an_ellipsis(self):
        text = ("Hosts now reconnect automatically after the device wakes and every "
                "Agent session stays put instead of jumping back to the start")
        cut = wn.truncate(text)
        self.assertLessEqual(len(cut), wn.MAX_TEXT)
        self.assertEqual(cut, "Hosts now reconnect automatically after the device "
                              "wakes and every Agent session stays put…")
        self.assertEqual(wn.truncate("Keep the Agent and a " + "y" * 60, limit=25),
                         "Keep the Agent…")

    def test_unbroken_text_is_hard_cut_with_an_ellipsis(self):
        (item,) = wn.validate_items([{"symbol": "network", "text": "x" * 120}])
        self.assertEqual(item["text"], "x" * (wn.MAX_TEXT - 1) + "…")

    def test_text_at_the_limit_is_kept_whole(self):
        text = "a" * (wn.MAX_TEXT - 2) + " b"
        (item,) = wn.validate_items([{"symbol": "network", "text": text}])
        self.assertEqual(item["text"], text)

    def test_caps_at_five_items(self):
        raw = [{"symbol": "sparkles", "text": f"Change {n}."} for n in range(8)]
        items = wn.validate_items(raw)
        self.assertEqual([i["text"] for i in items],
                         [f"Change {n}." for n in range(5)])

    def test_blank_and_malformed_items_are_dropped_before_the_cap(self):
        raw = [{"symbol": "sparkles", "text": "   "}, "junk", {"symbol": "x"}]
        raw += [{"symbol": "sparkles", "text": f" Change\n {n}. "} for n in range(5)]
        items = wn.validate_items(raw)
        self.assertEqual([i["text"] for i in items],
                         [f"Change {n}." for n in range(5)])


class PreviousBuildTests(unittest.TestCase):
    def test_highest_ancestor_below_build_is_first(self):
        entries = [(f"c{b}", parsed(b)) for b in (90, 101, 95, 100, 120, 99)]
        found = wn.ancestor_entries(entries, 101, lambda c: c != "c100")
        self.assertEqual(found[0][0], "c99")
        self.assertEqual([e["build"] for _, e in found], [99, 95, 90])

    def test_none_when_no_note_qualifies(self):
        self.assertEqual(wn.ancestor_entries(
            [("c101", parsed(101)), ("c120", parsed(120))], 101, lambda c: True), [])
        self.assertEqual(wn.ancestor_entries(
            [("c5", parsed(5))], 101, lambda c: False), [])

    def test_history_is_limited(self):
        entries = [(f"c{b}", parsed(b)) for b in range(1, 40)]
        found = wn.ancestor_entries(entries, 40, lambda c: True)
        self.assertEqual([e["build"] for _, e in found],
                         list(range(39, 39 - wn.MAX_HISTORY, -1)))

    def test_duplicate_build_keeps_first_claim_on_an_ancestor(self):
        entries = [("gone", parsed(99, "Abandoned.")),
                   ("first", parsed(99, "First.")),
                   ("second", parsed(99, "Second.")),
                   ("c98", parsed(98))]
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            found = wn.ancestor_entries(entries, 100, lambda c: c != "gone")
        self.assertEqual([(c, e["build"]) for c, e in found],
                         [("first", 99), ("c98", 98)])
        self.assertIn("note on second", stderr.getvalue())


class HistoryTests(unittest.TestCase):
    def test_bad_notes_skipped_with_a_warning(self):
        notes = [("c99", entry(99, "Newest.")), ("c98", "not json at all"),
                 ("c97", ""), ("c96", '{"build": 96, "items": []}'),
                 ("c94", '{"build": "94", "date": "2026-09-01", "items": []}'),
                 ("c93", '{"build": true, "date": "2026-09-01", "items": []}'),
                 ("c95", entry(95, "Oldest.") + "\ntrailing text\n")]
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            entries = wn.read_entries(notes)
        self.assertEqual([(c, e["build"], e["items"][0]["text"]) for c, e in entries],
                         [("c99", 99, "Newest."), ("c95", 95, "Oldest.")])
        for skipped in ("c98", "c97", "c96", "c94", "c93"):
            self.assertIn(f"note on {skipped}", stderr.getvalue())

    def test_history_is_newest_first_whatever_the_note_order(self):
        entries = wn.read_entries([("a", entry(97)), ("b", entry(99)),
                                   ("c", entry(98))])
        found = wn.ancestor_entries(entries, 100, lambda c: True)
        self.assertEqual([e["build"] for _, e in found], [99, 98, 97])

    def test_note_items_are_revalidated(self):
        note = wn.parse_note(entry(7, "x" * 200, "nope"))
        self.assertEqual(note["build"], 7)
        self.assertEqual(note["items"],
                         [{"symbol": "sparkles", "text": "x" * (wn.MAX_TEXT - 1) + "…"}])


def reply(texts):
    """A fake OpenRouter response whose content carries `texts` as items."""
    content = json.dumps({"items": [{"symbol": "sparkles", "text": t} for t in texts]})
    return io.BytesIO(json.dumps({"choices": [{"message": {"content": content}}]}).encode())


class SummarizeTests(unittest.TestCase):
    LONG = ("Filter the Hosts list by Host and Workspace, pin favorite Agents "
            "to the top, and see each Agent's status at a glance from anywhere")

    def summarize(self, responses):
        """Run summarize against queued urlopen outcomes; returns (items, requests, stderr)."""
        requests = []

        def urlopen(request, timeout):
            requests.append(json.loads(request.data))
            outcome = responses.pop(0)
            if isinstance(outcome, BaseException):
                raise outcome
            return outcome

        stderr = io.StringIO()
        with mock.patch.dict(os.environ, {"OPENROUTER_API_KEY": "sk-secret"}), \
                mock.patch.object(wn.urllib.request, "urlopen", urlopen), \
                mock.patch.object(wn.time, "sleep", lambda seconds: None), \
                contextlib.redirect_stderr(stderr):
            items = wn.summarize("input", "m")
        self.assertEqual(responses, [])  # every queued outcome was consumed
        return [i["text"] for i in items], requests, stderr.getvalue()

    def test_items_within_the_limit_make_one_request(self):
        texts, requests, _ = self.summarize([reply(["Short.", "x" * wn.MAX_TEXT])])
        self.assertEqual(texts, ["Short.", "x" * wn.MAX_TEXT])
        self.assertEqual(len(requests), 1)

    def test_an_item_over_the_limit_asks_once_to_shorten(self):
        first = reply(["Short.", self.LONG])
        texts, requests, _ = self.summarize([first, reply(["Short.", "Filter Hosts."])])
        self.assertEqual(texts, ["Short.", "Filter Hosts."])
        self.assertEqual(len(requests), 2)
        follow_up = requests[1]["messages"]
        self.assertEqual(follow_up[:2], requests[0]["messages"])
        self.assertEqual(follow_up[2]["role"], "assistant")
        self.assertIn(self.LONG, json.loads(follow_up[2]["content"])["items"][1]["text"])
        self.assertEqual(follow_up[3], {"role": "user", "content": wn.SHORTEN_PROMPT})

    def test_still_too_long_after_shortening_is_cut(self):
        texts, requests, _ = self.summarize([reply([self.LONG]), reply([self.LONG + "!"])])
        self.assertEqual(len(requests), 2)  # never a third request
        self.assertEqual(texts, ["Filter the Hosts list by Host and Workspace, "
                                 "pin favorite Agents to the top."])

    def test_failed_shorten_request_keeps_the_first_reply(self):
        failure = wn.urllib.error.HTTPError(wn.ENDPOINT, 400, "Bad Request", {},
                                            io.BytesIO(b"no"))
        texts, requests, stderr = self.summarize([reply(["Short.", self.LONG]), failure])
        self.assertEqual(len(requests), 2)
        self.assertEqual(texts, ["Short.", "Filter the Hosts list by Host and "
                                           "Workspace, pin favorite Agents to the top."])
        self.assertIn("::warning::", stderr)
        self.assertIn("HTTP 400", stderr)

    def test_malformed_shorten_reply_keeps_the_first_reply(self):
        garbage = io.BytesIO(json.dumps({"choices": [{"message": {
            "content": json.dumps({"items": "nope"})}}]}).encode())
        texts, _, stderr = self.summarize([reply([self.LONG]), garbage])
        self.assertEqual(texts, ["Filter the Hosts list by Host and Workspace, "
                                 "pin favorite Agents to the top."])
        self.assertIn("::warning::", stderr)


class BuildInputTests(unittest.TestCase):
    def test_changelog_comes_first_and_commits_fill_the_budget(self):
        text = wn.build_input(["- Dictation"], ["feat: a", "feat: b" + "!" * 50],
                              budget=45)
        self.assertTrue(text.startswith("CHANGELOG additions:\n- Dictation"))
        self.assertIn("feat: a", text)
        self.assertNotIn("feat: b", text)

    def test_added_lines_skip_headers_and_context(self):
        diff = "--- a/CHANGELOG.md\n+++ b/CHANGELOG.md\n@@ -1 +1,2 @@\n ctx\n+- New\n-old\n"
        self.assertEqual(wn.added_lines(diff), ["- New"])


class RepoNotesTests(unittest.TestCase):
    """Repo against a throwaway git repository: notes, ancestry, changelog diffs."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        cwd = os.getcwd()
        os.chdir(self.dir.name)
        self.addCleanup(os.chdir, cwd)
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *args):
        return subprocess.run(["git", *args], check=True, capture_output=True,
                              text=True).stdout.strip()

    def commit(self, message):
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def test_notes_round_trip_and_ancestry(self):
        repo = wn.Repo()
        self.commit("root")
        self.assertEqual(repo.notes(), [])  # no notes ref yet
        first = self.commit("first")
        second = self.commit("second")
        self.git("checkout", "-q", "-b", "side", first)
        side = self.commit("side")
        self.git("checkout", "-q", "-")
        # Multi-byte text: cat-file sizes are bytes, not characters.
        notes = {first: entry(1, "Café ☕ first."), second: entry(2, "Second."),
                 side: "not json"}
        for commit, text in notes.items():
            self.git("notes", f"--ref={wn.NOTES_REF}", "add", "-m", text, commit)
        self.assertEqual(sorted(repo.notes()),
                         sorted((c, t + "\n") for c, t in notes.items()))
        self.assertTrue(repo.is_ancestor(first))
        self.assertFalse(repo.is_ancestor(side))
        self.assertFalse(repo.is_ancestor("0" * 40))  # never fetched

    def write(self, path, text):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)
        self.git("add", path)

    def test_changelog_added_follows_entries_into_release_files(self):
        header = "# Changelog\n\n## [Unreleased]\n\n"
        self.write(wn.CHANGELOG, header + "### Added\n\n- **Old**: built before.\n")
        base = self.commit("base build")
        self.write(wn.CHANGELOG, header + "### Added\n\n- **Old**: built before.\n"
                   "- **New**: added since,\n  then released.\n")
        self.commit("feat: new")
        # make publish: the [Unreleased] body moves into a release file.
        self.write(wn.CHANGELOG, header)
        self.write(f"{wn.RELEASES_DIR}/1.2.0.md",
                   "---\nversion: 1.2.0\ndate: 2026-10-12\n---\n\n### Added\n\n"
                   "- **Old**: built before.\n"
                   "- **New**: added since,\n  then released.\n")
        self.commit("chore: release v1.2.0")
        self.write(wn.CHANGELOG, header + "### Fixed\n\n- **Later**: after it.\n")
        self.commit("fix: later")
        # The entry already in [Unreleased] at the base moved, so it is not new;
        # front matter and layout blanks are not fed to the model.
        added = [line for line in wn.Repo().changelog_added(base) if line]
        self.assertEqual(added, ["### Fixed", "- **Later**: after it.",
                                 "- **New**: added since,", "  then released."])


class RunTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.out = os.path.join(self.dir.name, "WhatsNew.json")
        self.note_file = os.path.join(self.dir.name, "entry.json")
        self.repo = FakeRepo(notes=[("c101", entry(101)), ("c98", entry(98, "Older.")),
                                    ("c99", entry(99, "Newer."))],
                             ancestors=["c98", "c99", "c101"],
                             changelog=["- Dictation"], commits=["feat: x"])

    def args(self, dry_run=False):
        return argparse.Namespace(build=100, out=self.out, note_file=self.note_file,
                                  model="m", dry_run=dry_run)

    def run_script(self, summarizer, dry_run=False):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = wn.run(self.args(dry_run), self.repo, summarizer,
                          today=lambda: "2026-09-26")
        return code, stdout.getvalue(), stderr.getvalue()

    def test_success_writes_new_entry_then_history_and_note_file(self):
        seen = []

        def summarizer(prompt_input, model):
            seen.append(prompt_input)
            return [{"symbol": "mic.fill", "text": "Dictate into the Composer."}]

        code, _, _ = self.run_script(summarizer)
        self.assertEqual(code, 0)
        self.assertEqual(self.repo.bases, ["c99"])
        self.assertIn("- Dictation", seen[0])
        new = {"build": 100, "date": "2026-09-26",
               "items": [{"symbol": "mic.fill", "text": "Dictate into the Composer."}]}
        with open(self.out) as handle:
            builds = json.load(handle)["builds"]
        self.assertEqual(builds[0], new)
        self.assertEqual([b["build"] for b in builds], [100, 99, 98])
        with open(self.note_file) as handle:
            self.assertEqual(json.load(handle), new)

    def test_empty_summary_is_still_an_entry_and_a_note(self):
        self.run_script(lambda prompt_input, model: [])
        with open(self.out) as handle:
            self.assertEqual(json.load(handle)["builds"][0]["items"], [])
        self.assertTrue(os.path.exists(self.note_file))

    def test_failure_writes_history_only_and_no_note_file(self):
        def summarizer(prompt_input, model):
            raise wn.SummaryError("HTTP 503")

        code, _, stderr = self.run_script(summarizer)
        self.assertEqual(code, 0)
        self.assertIn("::warning::", stderr)
        with open(self.out) as handle:
            self.assertEqual([b["build"] for b in json.load(handle)["builds"]],
                             [99, 98])
        self.assertFalse(os.path.exists(self.note_file))

    def test_missing_api_key_takes_the_failure_path_without_network(self):
        def no_network(*args, **kwargs):
            raise AssertionError("no request without a key")

        with mock.patch.dict(os.environ, {"OPENROUTER_API_KEY": "  "}), \
                mock.patch.object(wn.urllib.request, "urlopen", no_network):
            code, _, stderr = self.run_script(wn.summarize)
        self.assertEqual(code, 0)
        self.assertIn("::warning::", stderr)
        self.assertIn("OPENROUTER_API_KEY", stderr)
        with open(self.out) as handle:
            self.assertEqual([b["build"] for b in json.load(handle)["builds"]],
                             [99, 98])
        self.assertFalse(os.path.exists(self.note_file))

    def run_with_urlopen(self, urlopen):
        with mock.patch.dict(os.environ, {"OPENROUTER_API_KEY": "sk-secret"}), \
                mock.patch.object(wn.urllib.request, "urlopen", urlopen), \
                mock.patch.object(wn.time, "sleep", lambda seconds: None):
            code, _, stderr = self.run_script(wn.summarize)
        self.assertEqual(code, 0)
        self.assertIn("::warning::", stderr)
        self.assertNotIn("sk-secret", stderr)
        with open(self.out) as handle:
            self.assertEqual([b["build"] for b in json.load(handle)["builds"]],
                             [99, 98])
        self.assertFalse(os.path.exists(self.note_file))
        return stderr

    def test_socket_timeout_is_retried_once_then_takes_the_failure_path(self):
        # Python 3.9's socket.timeout is not a TimeoutError subclass.
        calls = []

        def urlopen(request, timeout):
            calls.append(request)
            raise socket.timeout("timed out")

        self.run_with_urlopen(urlopen)
        self.assertEqual(len(calls), 2)

    def test_connection_reset_while_reading_takes_the_failure_path(self):
        class Response(io.BytesIO):
            def read(self, *args):
                raise ConnectionResetError(54, "Connection reset by peer")

        stderr = self.run_with_urlopen(lambda request, timeout: Response())
        self.assertIn("ConnectionResetError", stderr)

    def test_without_a_previous_note_the_fallback_range_is_used(self):
        self.repo = FakeRepo(notes=[], ancestors=[])
        self.run_script(lambda prompt_input, model: [])
        self.assertEqual(self.repo.bases, ["FALLBACK"])
        with open(self.out) as handle:
            self.assertEqual([b["build"] for b in json.load(handle)["builds"]], [100])

    def test_dry_run_prints_and_writes_nothing(self):
        code, stdout, _ = self.run_script(
            lambda prompt_input, model: [{"symbol": "sparkles", "text": "Hi."}],
            dry_run=True)
        self.assertEqual(code, 0)
        self.assertIn("- Dictation", stdout)
        self.assertIn('"Hi."', stdout)
        self.assertEqual(os.listdir(self.dir.name), [])


if __name__ == "__main__":
    unittest.main()
