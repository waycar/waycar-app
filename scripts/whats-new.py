#!/usr/bin/env python3
"""Summarize what changed since the previous TestFlight build for What's New.

The TestFlight workflow runs this before archiving. It asks an LLM, through
OpenRouter, to turn the commits and changelog additions since the previous
TestFlight build into at most five terse, user-facing bullets, each with an
SF Symbol, and writes the app's bundled Sources/Waycar/Resources/WhatsNew.json:

    {"builds": [{"build": 123, "date": "2026-09-26",
                 "items": [{"symbol": "sparkles", "text": "..."}]}, ...]}

Builds are newest first. The app shows every bundled build newer than the
last one it presented, so the file carries history as well as this build.

History lives in git, not in a committed file: after a successful upload the
workflow attaches this build's entry (written via --note-file) as a git note
on the built commit under refs/notes/whats-new. The note's JSON carries the
build number. The previous build is the highest-numbered note below N whose
commit is an ancestor of HEAD — notes on abandoned branches or from later
builds never define the range; up to nine such entries, newest first, are
the history. Unparsable notes are skipped with a warning. If two notes claim
the same build number, the first in `git notes list` order (by commit SHA)
whose commit is an ancestor of HEAD wins; the rest are skipped with a
warning. Without any such note (the first CI build, or a history rewrite)
the range falls back to the last 30 first-parent commits, so the first notes
stay bounded instead of summarizing the whole project. The script reads the
local notes ref; the caller fetches it.

Failure policy: if the model call still fails after one retry, the output
carries history only, no note file is written, and the script exits 0 with
a GitHub `::warning::` annotation. Notes never block an upload, and because
no note is recorded the next build's range covers the missed changes.

Authentication is the OPENROUTER_API_KEY environment variable (a repository
secret in CI); a missing key takes the failure policy above. The model is
--model, else WHATS_NEW_MODEL, else DEFAULT_MODEL. --dry-run prints the
model input and the result and writes nothing.
"""
from __future__ import annotations

import argparse
import datetime
import http.client
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from typing import Callable, List, Optional, Tuple

ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
# The user's pick; OpenRouter lists it with `structured_outputs`, which the
# strict schema below requires. Override with --model or WHATS_NEW_MODEL.
DEFAULT_MODEL = "z-ai/glm-5.3-flash"
KEY_VARIABLE = "OPENROUTER_API_KEY"
TIMEOUT_SECONDS = 60
MAX_ITEMS = 5
TARGET_TEXT = 80  # what the prompt asks for
MAX_TEXT = 100  # hard cap: longer items get one shorten request, then a cut
# A cut at one of these ends the item as a whole clause, with a period.
CLAUSE_BREAKS = (", ", "; ", ": ", " — ")
# Never end an item on a dangling fragment such as "and a" or "instead of".
STOPWORDS = frozenset(
    "and or a an the of to with instead for in on but".split())
MAX_HISTORY = 9  # plus this build: the app bundles at most 10 builds
FALLBACK_COMMITS = 30
INPUT_BUDGET = 24_000
MAX_COMMIT = 2_000
FALLBACK_SYMBOL = "sparkles"
# Git's well-known empty tree: the diff base when the fallback range reaches
# the root commit, so every CHANGELOG line counts as added.
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
CHANGELOG = "CHANGELOG.md"
# `make publish` moves the [Unreleased] body here, one file per release.
RELEASES_DIR = "apps/web/src/content/changelog"
# Release-file front matter and blank lines: bookkeeping and layout, not
# something that changed.
FRONT_MATTER = re.compile(r"^(?:---\s*|version:.*|date:.*|\s*)$")
NOTES_REF = "whats-new"  # refs/notes/whats-new

# Kept in lockstep with the app, which also falls back to `sparkles` when a
# symbol does not resolve on the running iOS version.
SYMBOLS = [
    "sparkles", "wand.and.stars", "bolt.fill", "ant.fill",
    "wrench.and.screwdriver.fill", "paintbrush.fill", "lock.shield.fill",
    "icloud.fill", "bell.badge.fill", "mic.fill", "terminal.fill",
    "rectangle.stack.fill", "arrow.triangle.2.circlepath", "speedometer",
    "hand.tap.fill", "ipad.and.iphone", "keyboard.fill",
    "list.bullet.rectangle.fill", "network", "square.and.arrow.up.fill",
]

SYSTEM_PROMPT = f"""\
You write the "What's New" notes shown to iOS app testers after they update \
Waycar, an iPhone and iPad app for driving coding agents on remote hosts.

You receive CHANGELOG additions (the curated user-facing notes) followed by \
commit messages (which fill gaps). Summarize what changed for the tester.

Rules:
- At most {MAX_ITEMS} items; fewer is better. Merge related changes into one item.
- Each item is one short sentence of at most {TARGET_TEXT} characters, \
present tense, naming a concrete user-visible benefit. For example:
  {{"symbol": "mic.fill", "text": "Dictate into the Composer with the \
microphone button."}}
  {{"symbol": "network", "text": "Hosts reconnect on their own after your \
iPhone wakes."}}
- Skip CI, tests, documentation, refactors, internal renames, dependency \
updates, and build or version bumps.
- No issue or PR numbers, no Markdown, no emoji.
- Pick the best-fitting symbol for each item from this list only: \
{", ".join(SYMBOLS)}.
- If nothing user-visible changed, return zero items.
"""

SHORTEN_PROMPT = (f"Shorten every item to at most {TARGET_TEXT} characters; "
                  "keep meaning; same JSON shape.")

RESPONSE_FORMAT = {
    "type": "json_schema",
    "json_schema": {
        "name": "whats_new",
        "strict": True,
        "schema": {
            "type": "object",
            "properties": {
                "items": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "symbol": {"type": "string", "enum": SYMBOLS},
                            "text": {"type": "string", "maxLength": MAX_TEXT},
                        },
                        "required": ["symbol", "text"],
                        "additionalProperties": False,
                    },
                },
            },
            "required": ["items"],
            "additionalProperties": False,
        },
    },
}


class SummaryError(Exception):
    """The model call failed; the caller applies the failure policy."""


def warn(message: str) -> None:
    # A GitHub annotation in Actions, a plain stderr line elsewhere.
    print(f"::warning::{message}", file=sys.stderr)


# --- Pure pieces --------------------------------------------------------------


def _drop_dangling(text: str) -> str:
    """Strip trailing punctuation and stopwords, keeping at least one word."""
    words = text.split()
    while words:
        last = words[-1].rstrip(".,;:-—")
        if not last or (len(words) > 1 and last.lower() in STOPWORDS):
            words.pop()
            continue
        words[-1] = last
        break
    return " ".join(words)


def truncate(text: str, limit: int = MAX_TEXT) -> str:
    """Fit `text` in `limit` characters without ending on a fragment.

    Prefer the last clause boundary (CLAUSE_BREAKS) and end with a period;
    a boundary leaving under half the limit is too early to be the point
    of the item. Otherwise cut at the last word boundary and append "…".
    Trailing stopwords are dropped either way.
    """
    if len(text) <= limit:
        return text
    # A break starting at index i yields text[:i] + ".", at most `limit`.
    end = max(text.rfind(sep, 0, limit - 1 + len(sep)) for sep in CLAUSE_BREAKS)
    if end > 0:
        clause = _drop_dangling(text[:end])
        if len(clause) >= limit // 2:
            return clause + "."
    # text[:cut] + "…" is at most `limit`.
    cut = text.rfind(" ", 0, limit)
    head = _drop_dangling(text[:cut]) if cut > 0 else ""
    return (head or text[:limit - 1]) + "…"


def too_long(raw: object) -> bool:
    """Whether any model item's text exceeds MAX_TEXT once whitespace folds."""
    return any(isinstance(entry, dict) and isinstance(entry.get("text"), str)
               and len(" ".join(entry["text"].split())) > MAX_TEXT
               for entry in (raw if isinstance(raw, list) else []))


def validate_items(raw: object) -> List[dict]:
    """Normalize model (or note) items: known symbol, clean text, capped."""
    items = []
    for entry in raw if isinstance(raw, list) else []:
        if not isinstance(entry, dict):
            continue
        text = entry.get("text")
        if not isinstance(text, str):
            continue
        text = truncate(" ".join(text.split()))
        if not text:
            continue
        symbol = entry.get("symbol")
        if symbol not in SYMBOLS:
            symbol = FALLBACK_SYMBOL
        items.append({"symbol": symbol, "text": text})
        if len(items) == MAX_ITEMS:
            break
    return items


def parse_note(text: str) -> Optional[dict]:
    """One build entry from a note's text, or None if unusable.

    raw_decode tolerates anything after the JSON (e.g. a hand-added line).
    """
    try:
        value, _ = json.JSONDecoder().raw_decode(text.lstrip())
    except ValueError:
        return None
    if not isinstance(value, dict) or not isinstance(value.get("date"), str):
        return None
    build = value.get("build")
    if not isinstance(build, int) or isinstance(build, bool):
        return None
    if not isinstance(value.get("items"), list):
        return None
    return {"build": build, "date": value["date"],
            "items": validate_items(value["items"])}


def read_entries(notes: List[Tuple[str, str]]) -> List[Tuple[str, dict]]:
    """(commit, entry) for every usable (commit, note text); warns on the rest."""
    entries = []
    for commit, text in notes:
        entry = parse_note(text)
        if entry is None:
            warn(f"note on {commit}: not a What's New entry; skipped")
            continue
        entries.append((commit, entry))
    return entries


def ancestor_entries(entries: List[Tuple[str, dict]], build: int,
                     is_ancestor: Callable[[str], bool],
                     limit: int = MAX_HISTORY) -> List[Tuple[str, dict]]:
    """Entries below `build` whose commit HEAD reaches, newest build first.

    The first element is the previous build (its commit is the range base);
    the list is also the history to carry forward. For a build number
    claimed twice, the first claim (in `entries` order) on an ancestor wins.
    """
    found: List[Tuple[str, dict]] = []
    seen = set()
    # sorted() is stable, so equal build numbers keep their `entries` order.
    for commit, entry in sorted((e for e in entries if e[1]["build"] < build),
                                key=lambda e: e[1]["build"], reverse=True):
        if entry["build"] in seen:
            warn(f"note on {commit}: build {entry['build']} already has a "
                 "note; skipped")
            continue
        if is_ancestor(commit):
            seen.add(entry["build"])
            found.append((commit, entry))
            if len(found) == limit:
                break
    return found


def added_lines(diff: str) -> List[str]:
    """The `+` lines of a unified diff, without the marker or file headers."""
    return [line[1:] for line in diff.splitlines()
            if line.startswith("+") and not line.startswith("+++")]


def removed_lines(diff: str) -> List[str]:
    """The `-` lines of a unified diff, without the marker or file headers."""
    return [line[1:] for line in diff.splitlines()
            if line.startswith("-") and not line.startswith("---")]


def changelog_additions(changelog_diff: str, releases_diff: str) -> List[str]:
    """Changelog lines new since the base, wherever they live at HEAD.

    An entry added under [Unreleased] and released before this build shows
    only as an added line in a release file. A release also moves entries
    that were already in [Unreleased] at the base; those show as removed from
    CHANGELOG.md and are not new, so each removed line cancels one identical
    release-file addition.
    """
    moved = Counter(removed_lines(changelog_diff))
    released = []
    for line in added_lines(releases_diff):
        if FRONT_MATTER.match(line):
            continue
        if moved[line]:
            moved[line] -= 1
            continue
        released.append(line)
    return added_lines(changelog_diff) + released


def build_input(changelog: List[str], commits: List[str],
                budget: int = INPUT_BUDGET) -> str:
    """Model input: CHANGELOG additions first, whole commits fill the rest."""
    sections = []
    notes = "\n".join(changelog).strip()
    if notes:
        sections.append("CHANGELOG additions:\n" + notes[:budget])
    remaining = budget - sum(len(s) for s in sections)
    kept = []
    # Capped per commit so one long body cannot starve the rest.
    for commit in filter(None, (c.strip()[:MAX_COMMIT] for c in commits)):
        remaining -= len(commit) + 2
        if remaining < 0:
            break
        kept.append(commit)
    if kept:
        sections.append("Commits:\n" + "\n\n".join(kept))
    return "\n\n".join(sections)


def assemble(entry: Optional[dict], history: List[dict]) -> dict:
    return {"builds": ([entry] if entry is not None else []) + history}


# --- Git ----------------------------------------------------------------------


class Repo:
    """The git queries the script needs; tests substitute a fake."""

    def _git(self, *args: str) -> str:
        return subprocess.run(["git", *args], check=True, capture_output=True,
                              text=True).stdout

    def notes(self) -> List[Tuple[str, str]]:
        """(annotated commit, note text) for every note in the notes ref."""
        pairs = [line.split() for line in
                 self._git("notes", f"--ref={NOTES_REF}", "list").splitlines()]
        pairs = [p for p in pairs if len(p) == 2]
        if not pairs:
            return []
        # One cat-file for every blob; sizes are bytes, so read raw.
        output = subprocess.run(
            ["git", "cat-file", "--batch"], check=True, capture_output=True,
            input="".join(f"{blob}\n" for blob, _ in pairs).encode()).stdout
        notes = []
        position = 0
        for _, commit in pairs:
            header_end = output.index(b"\n", position)
            header = output[position:header_end].split()
            position = header_end + 1
            if len(header) != 3 or header[1] != b"blob":
                notes.append((commit, ""))  # missing: parse fails, warned
                continue
            size = int(header[2])
            notes.append((commit, output[position:position + size]
                          .decode("utf-8", errors="replace")))
            position += size + 1  # the blob's trailing newline
        return notes

    def is_ancestor(self, commit: str) -> bool:
        # A note may annotate a commit this clone never fetched (a deleted
        # branch); that commit is not in HEAD's history.
        exists = subprocess.run(["git", "cat-file", "-e", f"{commit}^{{commit}}"],
                                capture_output=True)
        if exists.returncode != 0:
            return False
        result = subprocess.run(
            ["git", "merge-base", "--is-ancestor", commit, "HEAD"],
            capture_output=True, text=True)
        if result.returncode not in (0, 1):
            raise RuntimeError(result.stderr.strip())
        return result.returncode == 0

    def fallback_base(self) -> str:
        shas = self._git("rev-list", "--first-parent",
                         f"--max-count={FALLBACK_COMMITS + 1}", "HEAD").split()
        return shas[-1] if len(shas) > FALLBACK_COMMITS else EMPTY_TREE

    def commits(self, base: str) -> List[str]:
        span = "HEAD" if base == EMPTY_TREE else f"{base}..HEAD"
        log = self._git("log", "--no-merges", "--format=%B%x1e", span)
        return [c.strip() for c in log.split("\x1e") if c.strip()]

    def changelog_added(self, base: str) -> List[str]:
        return changelog_additions(
            self._git("diff", base, "HEAD", "--", CHANGELOG),
            self._git("diff", base, "HEAD", "--", f"{RELEASES_DIR}/*.md"))


# --- OpenRouter ---------------------------------------------------------------


def api_key() -> str:
    key = os.environ.get(KEY_VARIABLE, "").strip()
    if not key:
        raise SummaryError(f"{KEY_VARIABLE} is not set; add the repository "
                           f"secret with `gh secret set {KEY_VARIABLE}`")
    return key


def is_timeout(error: BaseException) -> bool:
    # Python 3.9's socket.timeout is not a TimeoutError (3.10 aliases them),
    # and urlopen wraps a connect timeout in URLError.reason.
    timeouts = (socket.timeout, TimeoutError)
    return (isinstance(error, timeouts)
            or isinstance(getattr(error, "reason", None), timeouts))


def request_items(key: str, model: str,
                  messages: List[dict]) -> Tuple[str, object]:
    """One chat completion: (the reply's content, its raw items).

    One retry on 429/5xx or a timeout. Every network, protocol, or decoding
    failure becomes SummaryError.
    """
    body = json.dumps({
        "model": model,
        "temperature": 0.2,
        "messages": messages,
        "response_format": RESPONSE_FORMAT,
        # require_parameters: route only to providers that honor the strict
        # schema, rather than one that silently ignores response_format.
        "provider": {"require_parameters": True},
    }).encode()
    for attempt in (1, 2):
        request = urllib.request.Request(ENDPOINT, data=body, method="POST", headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "X-Title": "Waycar What's New",
        })
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
                payload = json.load(response)
            break
        except urllib.error.HTTPError as error:
            try:
                detail = error.read().decode(errors="replace")[:300]
            except (OSError, http.client.HTTPException):
                detail = "(body unreadable)"
            if attempt == 1 and (error.code == 429 or error.code >= 500):
                retry_after = error.headers.get("Retry-After", "")
                time.sleep(min(int(retry_after), 30) if retry_after.isdigit() else 5)
                continue
            # The body is server text; never let an echoed key reach the log.
            detail = detail.replace(key, "[redacted]")
            raise SummaryError(f"HTTP {error.code}: {detail}") from error
        # OSError covers URLError, socket.timeout, connection resets, and
        # ssl.SSLError; HTTPException covers RemoteDisconnected and
        # IncompleteRead; ValueError covers a malformed JSON body.
        except (OSError, http.client.HTTPException, ValueError) as error:
            if attempt == 1 and is_timeout(error):
                continue
            raise SummaryError(f"{type(error).__name__}: {error}") from error
    try:
        content = payload["choices"][0]["message"]["content"]
        items = json.loads(content)["items"]
    except (KeyError, IndexError, TypeError, ValueError) as error:
        raise SummaryError(f"unexpected response: {error}") from error
    return content, items


def summarize(prompt_input: str, model: str) -> List[dict]:
    """Ask OpenRouter for items, validated for the app.

    If any item exceeds MAX_TEXT, one follow-up turn in the same
    conversation asks the model to shorten them; if that fails (or its
    items are not a list), the first reply stands. validate_items then
    cuts whatever is still too long.
    Failures of the first request raise SummaryError, so the caller's
    failure policy (history-only notes, exit 0) always applies.
    """
    key = api_key()
    messages = [{"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": prompt_input}]
    content, items = request_items(key, model, messages)
    if too_long(items):
        try:
            _, shorter = request_items(key, model, messages + [
                {"role": "assistant", "content": content},
                {"role": "user", "content": SHORTEN_PROMPT}])
            if not isinstance(shorter, list):
                raise SummaryError("unexpected response: items is not a list")
            items = shorter
        except SummaryError as error:
            warn(f"What's New shorten request failed, keeping the first reply: {error}")
    return validate_items(items)


# --- Orchestration ------------------------------------------------------------


def today_utc() -> str:
    return datetime.datetime.now(datetime.timezone.utc).date().isoformat()


def write_file(path: str, content: str) -> None:
    # Replace atomically so an interrupted run never leaves a half-written
    # resource for the archive to bundle.
    temp = path + ".tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.replace(temp, path)


def run(args: argparse.Namespace, repo: Repo,
        summarizer: Callable[[str, str], List[dict]] = summarize,
        today: Callable[[], str] = today_utc) -> int:
    found = ancestor_entries(read_entries(repo.notes()), args.build,
                             repo.is_ancestor)
    if found:
        base = found[0][0]
        print(f"Previous build: {found[0][1]['build']} ({base})", file=sys.stderr)
    else:
        base = repo.fallback_base()
        print(f"No previous build note; using the last {FALLBACK_COMMITS} "
              "first-parent commits", file=sys.stderr)
    history = [entry for _, entry in found]
    prompt_input = build_input(repo.changelog_added(base), repo.commits(base))

    if args.dry_run:
        print(prompt_input)
        print("---")

    try:
        entry: Optional[dict] = {"build": args.build, "date": today(),
                                 "items": summarizer(prompt_input, args.model)}
    except SummaryError as error:
        warn(f"What's New summary failed, shipping history only: {error}")
        entry = None

    output = assemble(entry, history)
    if args.dry_run:
        print(json.dumps(output, indent=2))
        return 0
    write_file(args.out, json.dumps(output, indent=2, ensure_ascii=False) + "\n")
    if entry is not None and args.note_file:
        write_file(args.note_file,
                   json.dumps(entry, separators=(",", ":"), ensure_ascii=False) + "\n")
    return 0


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--build", type=int, required=True,
                        help="build number being uploaded")
    parser.add_argument("--out", required=True,
                        help="path of the WhatsNew.json to write")
    parser.add_argument("--note-file",
                        help="also write this build's entry here (compact JSON), "
                             "for the refs/notes/whats-new note")
    parser.add_argument("--model",
                        default=os.environ.get("WHATS_NEW_MODEL") or DEFAULT_MODEL,
                        help="OpenRouter model id (default: $WHATS_NEW_MODEL, "
                             f"else {DEFAULT_MODEL})")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the model input and result; write nothing")
    return parser.parse_args(argv)


if __name__ == "__main__":
    sys.exit(run(parse_args(), Repo()))
