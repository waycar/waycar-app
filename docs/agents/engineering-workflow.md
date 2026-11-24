# Engineering Workflow

The one workflow every engineering run in this repo follows — CTO and Senior
Software Engineers alike. Repo conventions, build commands, and load-bearing
facts stay in [`AGENTS.md`](../../AGENTS.md), [`CONTRIBUTING.md`](../../CONTRIBUTING.md),
and [`CONTEXT.md`](../../CONTEXT.md); this skill covers only how a run is
structured, and how the skill itself improves.

Two lanes land work. The PR flow below is for humans and for agents that work
through GitHub and Paperclip. Branches run by an Ultimate coordinator take the
[Ultimate lane](#ultimate-lane) instead. Both run the
[Before submit](#before-submit) checks and end with cleanup and a
[run-learnings entry](#each-run-makes-the-skill-better).

## The lifecycle

1. **Worktree.** Do all work in a worktree, never on the main checkout:

   ```sh
   git fetch origin main
   git worktree add -b <task-slug> ~/src/waycar-worktrees/<task-slug> origin/main
   ```

   Fetch first: `origin/main` is only as new as your last fetch, and a
   worktree started from a stale one misses what just merged.
   Branch names are the task slug (`agent-workflow-skill`), not `patch-1`.
   Delete the worktree when the PR is merged or closed, using the same
   absolute path it was created at:
   `git worktree remove ~/src/waycar-worktrees/<task-slug>`. If it refuses
   because the worktree is dirty, push or discard leftovers deliberately;
   use `--force` only after confirming nothing worth keeping remains.
   Never `git stash` in a worktree: the stash list is shared by every
   worktree of the repo, so a stash there takes the branch's edits with it
   (and into the other worktrees' `git stash pop`). Copy files aside instead.

2. **PR.** Every run that changes the repo opens a PR — including docs-only
   changes. No run lands code or docs any other way, except an Ultimate
   branch through the [Ultimate lane](#ultimate-lane). Before opening it:
   run [Before submit](#before-submit), verify the changed surface
   (build/run the thing, not just tests; on the Mac build host follow
   [Mac workflow](mac-workflow.md), which takes `SIM_DESTINATION`'s `OS=`
   from the runtime that holds AGENTS.md's shared iPhone 17 Pro Max set
   instead of a pinned version), keep commits Conventional, and add a
   `[Unreleased]` CHANGELOG entry for user-visible changes only.

3. **Review assignment.** Assign the PR to **another** engineer or the CTO
   for code review — never review your own PR. On Paperclip, this is a child
   issue assigned to the reviewer naming the PR; on GitHub, request the
   reviewer too.

4. **Bounce-back.** The reviewer assigns the work back to the original owner
   — the PR's GitHub assignee, which is also the owner of the Paperclip parent
   task — with findings as GitHub review comments, and then does nothing more
   on it. This applies to an approval-only review too: approve, reassign, stop;
   the owner merges. The owner addresses any feedback, re-pushes, and merges
   or closes. If the owner and reviewer disagree after one round, the CTO
   decides.

5. **Cleanup.** The host disk is shared and has hit the 15% free alert
   repeatedly (WAY-449). When the PR merges or closes, in the same run:
   - remove every worktree you created, including the build output inside it
     (`plugin/target`, `apps/android/**/build`, `.gradle`); a Rust worktree
     is 1-2G and an Android one about 5G;
   - delete scratch clones and smoke dirs you made under `/tmp`;
   - kill any dev servers or simulators the run started (see `AGENTS.md` ›
     Simulators);
   - archive your Paperclip execution workspace once the issue is closed. If
     the archive returns 409 because the folder is not a git repo, confirm
     nothing unpushed is left, `rm -rf` the folder, then archive again;
   - leave the reviewer subtask resolved and put a `Cleanup:` line in your
     final comment saying what you removed.

   A worktree whose issue is `done` or `cancelled` is stale. Remove it even if
   you did not create it, after checking the branch is pushed.

## Ultimate lane

For branches an Ultimate coordinator runs (started by `@ultimate` in this
project). No PR, no GitHub review comments, no Paperclip review child.

1. **Worktree.** Ultimate creates the branch's worktree and removes it after
   landing; do not make one under `~/src/waycar-worktrees`. Never commit,
   reset or land in the main checkout. The same verification rules as the PR
   flow apply (build/run the changed surface, Conventional commits, CHANGELOG
   for user-visible changes, [Mac workflow](mac-workflow.md) for Mac runs).
   With no PR, a CHANGELOG entry and commits reference the GitHub issue
   (`refs #<n>`) when there is one, and nothing otherwise.
2. **Review.** A `reviewer` subagent replaces steps 3–4: the coordinator
   starts it on the immutable `base..head` range with the acceptance
   criteria, checks each finding itself, and fixes the real ones before
   submitting. A missing run-learnings entry is still a blocking finding.
3. **Land.** Run [Before submit](#before-submit) first. `workspace submit`
   hands the branch to the lander, which merges it into local `main` with
   whatever landed meanwhile, runs the project's checks and fast-forwards
   local `main`. A failure comes back to the coordinator, which fixes the
   cause and submits again.
4. **Push.** `@ultimate` pushes `origin main` after a landing whose branch
   was reviewed and whose checks passed (standing permission from the user),
   after `git log origin/main..HEAD` shows only reviewed commits: a shared
   checkout's `main` can hold another run's unpushed ones. Coordinators and
   their subagents never push.
5. **CI.** `@ultimate` watches the pushed commit with
   `scripts/ci/watch-main.py --sha <sha>` (an `automation ask` script). A red
   run is fixed forward on a new branch through this lane.
6. **Still the user's call.** Releases (`make publish`), App Store Connect
   steps (TestFlight distribution, App Review submissions), installs on the
   user's devices, other externally visible steps that cannot be undone, and
   big hard-to-undo architecture questions. Ask first.
7. **Cleanup.** As in the PR flow, minus Paperclip: simulators, dev
   servers, Mac scratch worktrees and `/tmp` dirs the run made.

## Before submit

Before `workspace submit`, or before opening the PR, run the checks for what
the branch touched. Each item below once turned `main` red because a branch
ran only its own tests. On the Mac, run the make targets through `mac_run`
where your agent host has it ([Mac workflow](mac-workflow.md)).

- **Every branch:** run `python3 scripts/secret-scan/scan.py --no-external .`
  and expect `scan: clean`. The lander never runs it, so a hit shows up only
  as a red Secret scan after the push: example LAN addresses in the Find
  Computers tests failed every push to `main` for a day. A made-up address
  gets a scoped line in `scripts/secret-scan/scan-allow.tsv` (that file, the
  exact values, a reason); a real one comes out of the change.
- **Launch arguments, the `agent.start` wire, or any Transport:** run the
  full CI app lane, `make test-ci-app`, not only the suites you changed. The
  real-SSH suites pin exact wire payloads: a change to herdr launch
  arguments failed 12 of them on `main`.
- **The plugin** (anything under `plugin/`, or the packaging scripts AGENTS.md
  lists): in `plugin/`, run `cargo fmt --check`,
  `cargo clippy --locked --all-targets --all-features -- -D warnings` and
  `cargo test --locked`; then, from the repository root,
  `sh scripts/check-plugin-version.sh`, the package-clean check and the
  install check, as CI's Plugin binaries job does:

  ```sh
  eval "$(sh scripts/ci/provision-plugin-build.sh)"
  sh scripts/build-plugin-binaries.sh /tmp/<slug>-bin
  WAYCAR_PLUGIN_BINARIES=/tmp/<slug>-bin sh scripts/package-plugin.sh /tmp/<slug>-dist
  sh scripts/ci/package-clean-check.sh /tmp/<slug>-dist
  sh scripts/ci/native-install-check.sh --host /tmp/<slug>-dist
  ```

  This runs on Linux, in about 2 minutes once the toolchain is cached. An
  unformatted plugin release, a notices file the clean check refused, and a
  `status --json` field the install check did not expect each turned
  `main`'s CI (Node) red. A version that already has a
  `plugin-v<version>` tag, or that another branch took first, is spent:
  bump to the next one.
- **Real-SSH fixtures** never resolve the CI runner's own programs. Make
  every Host probe the code runs injectable and stub it in the fixture, and
  keep `detectionSearchesSystemDirectories` and `wakesInLoginSession` off:
  a fixture that ran the runner's real `codex --help`, then its hanging
  `--version`, turned `main` red. A new real-SSH or package test also updates
  its lane's pinned count and test names in `scripts/run-ci-ios-tests.sh`
  (`run_suite`, `tmux_suite_tests`); a parameterized `@Test` counts once.
  Two branches that each add one test both write the same new count, git
  merges that cleanly, and the lane is one short: recount after merging.
- **Keyboard, terminal or iPad layout:** run `make test-ipad`. CI tests only
  the iPhone, so 23 iPad tests failed on `main` unseen; the weekly
  [iPad run](../../.github/workflows/ipad-weekly.yml) catches the rest, a
  week late.
- **`Packages/WaycarSSH`:** run CI's package lane on the Mac,
  `make test-ci-package` (through `mac_run`), not a hosted draft-PR round
  trip: it runs the fixture-backed `SessionDriver*E2ETests` with the lane's
  pinned count.
- **`Packages/SwiftMosh`:** run its real-server suites,
  `SWIFTMOSH_REAL_E2E=1 swift test --package-path Packages/SwiftMosh`, which
  need a local `mosh-server`; without one, prove CI's SwiftMosh job on a
  draft PR (`gh pr create --draft`; the PR sweeper skips drafts) and close
  it and delete its branch at submit.
- **Help pages** (`apps/web/src/content/help/`): run `npm run build` in
  `apps/web`, then, from the repository root, `make test-app
  TEST_FLAGS='-only-testing:WaycarTests/HelpCatalogTests'`. Both check the
  front matter bounds (3-10 keywords, title and description lengths): a page
  that grew to 13 keywords stopped waycar.dev's deploy and failed iOS CI.
- **Waiting for hosted CI** (a PR, a dispatch, a pushed commit): make one
  call, `python3 scripts/ci/ci-evidence.py --pr <n> --wait` (or
  `--sha <sha>`), or hand the wait to an automation (an `automation ask`
  script running it with `--wait --fire`) and end your turn. Never poll with
  ad-hoc `gh run view`/`gh run list` loops: one branch spent 38 of its 227
  tool calls and 128 tool-minutes that way, and one poll timed out at 600 s
  while an automation already watched. In a bash tool, give the call a
  timeout above its `--deadline` (default 2 h) and mark it interruptible.
  The report gives each workflow and job its conclusion and duration, each
  CI lane its executed, pinned and skipped counts, the failing tests, the
  first `##[error]`, and which runs were cancelled or superseded; `--json`
  for scripts. Exit 0 is green, 1 red, 2 incomplete (gh failed, or a job
  log it could not read), 3 still running.

## Parallel work

When a coordinator splits one change across workers:

- Commit the shared contract first (new request fields, an error case, a
  seam both sides call), so every worker builds on it and compiles.
- Give each worker files of its own, and name the owner of any helper two
  of them need, or both write it.
- Merge the coordinator's branch, and `main`, into a worker's branch before
  its Mac run and before merging the slices, not after the last one: a
  worker on an older base fails on what another already fixed, and `main`
  may have landed the same module meanwhile.
- A worker makes one focused commit unless its brief asks for one commit per
  finding in so many words.
- Keep long-tested exec strings byte-stable. When a check objects to one,
  narrow the check.
- Run formatters once, early, and tell everyone: `cargo fmt` on a shared
  target reformats files the other branches edit.
- Check `docs/adr/` and the open branches before taking the next ADR number.
- `subagent land` refuses a child once the parent merged `main` after
  starting it ("Target moved or diverged"): merge the child's branch with
  `git merge ultimate/<id>`, or merge `main` only after landing the
  children, then rerun the checks on the merged tree.
- Check every product claim a brief fixes as verbatim copy against the
  release tag (`git show v<version>:<file>`), and read how a page calls a
  component before pinning a count on it: a worker told to copy exactly
  ships a wrong claim exactly.

## Proving a change

- **Red first.** A new test counts once it fails on the base: run it there,
  or as a mutant (take the fix back out in a scratch copy, run only that
  suite, expect the new test to fail). A fixture set the code passes proves
  little until a broken version fails it. One `mac_run` session does both:
  a throwaway commit of the base plus the new tests (a scratch
  `GIT_INDEX_FILE` and `git commit-tree` keep it off the branch) fails, then
  the tip runs incrementally. A fix that adds the fact it decides on leaves
  no new test that compiles on the base: prove red with the same flow test
  minus that one fact line.
- **Reproduce a flake where its cause sits**, not by loading the Mac: queue
  a `Thread.sleep` on the main thread before the step, delay a fake's reply,
  hold a fake on a continuation, or pause the test process
  (`kill -STOP`/`kill -CONT` in a loop). Then fix it where the shared piece
  is made: a repro of one call site does not clear its siblings. To pin a
  main-actor race, release the awaited answer and ask for the competing
  step in the same main-actor job (`Task { gate.release(); await leave() }`):
  the released continuation is queued first. A gate whose `wait()` is
  nonisolated resumes off the main actor, so its order is not fixed.
- **Loop in fresh processes.** For a flaky suite, run it again and again with
  `scripts/run-app-simulator-tests.py … test-without-building`.
  `-test-iterations N` through `make test-app` repeats each Swift Testing
  test N times in a row in one test host (Xcode 27.2, a `.serialized`
  suite, 2026-11-19): a quick repeat, but every repetition shares the
  process, and elsewhere it has started every repetition at the same time.
- **Read the counts.** A Swift Testing selector without its `()` runs zero
  tests and passes. Check the `Test run with N tests` line and the
  crash-report line of every run.
- **Compare with `main`.** Before blaming a branch for a failure on a
  simulator CI does not run, run `main` on the same simulator.
- **Fakes are not the Host.** Fakes written from research notes have passed
  while the real program differed: herdr-core's replies carry no newline, a
  resumed Codex thread sends no `thread/started`, an Ultimate endpoint is
  POST-only. Run the real-binary suite or contract check before you trust
  them, and feed fakes recorded payloads. A live OpenCode 2 check needs no
  Mac or testbox: `opencode-contract.py --fetch` gives the pinned binary on
  this agent host, and the harness-lab mock runs as a plain
  `node server.js`.
- **Inject randomness as a closure** (`randomIndex: { $0.lowerBound }`), not
  a stored `any RandomNumberGenerator`: Swift does not open an existential
  for an `inout` generic argument (Xcode 27). A constant-0 test generator
  hangs `Int.random(in:using:)` on any range that isn't a power of two; a
  constant 1 always draws the first index.
- **Run the exec strings.** A Host command the app builds can be exported by
  a throwaway test and run under `dash` and the Mac's `/bin/sh`, against a
  scratch HOME or a container, before a Mac run.
- **Deleting is a change too.** Before removing a screen, type or entry
  point, grep every consumer of it and of its side effects: a screen can
  host unrelated controls, a store can be the only caller of an app-wide
  setup. Sweep by the feature's type names; a plain word over-matches.
- **Say what did not run.** A host without Xcode cannot compile the app, a
  build is not a test run, and a local server is not a deploy.
- **UI proof stays out of the commit.** Use a throwaway hosted test
  (`makeTestWindow`; a bare `UIWindow(frame:)` captures black) or a throwaway
  XCUITest in `Tests/WaycarScreenshots/`, run through
  `scripts/run-app-simulator-tests.py`. `drawHierarchy` leaves out the
  keyboard window and draws Ghostty black, so terminal shots use
  `xcrun simctl io <udid> screenshot`. The first UI test after a simulator
  boots can fail with kAXError -25218: retry once, or run a warm-up test
  first. `TEST_RUNNER_<NAME>=…` on the command line reaches the test process.
  In a hosted test, wait for a control's enabled accessibility state after a
  programmatic edit before tapping it, and fire native toolbar `UIButton`s
  with `sendActions`, not `accessibilityActivate`. A desk Codex TUI driven
  through tmux needs about 1 s between the text and Enter.
  SwiftUI's nodes in a hosted window have an empty
  `accessibilityIdentifier`: find them by label. For a Console row the demo
  never shows, a throwaway commit in a scratch worktree adds a demo launch
  flag (a Host's connect throws the failure, `detectBackends` returns the
  plugin version you need), injects any store the demo leaves nil, adds one
  XCUITest to `ReadmeScreenshots`, and points `capture-screenshots.sh` at it
  with `exit 0` after the run; then `mac_run target: screenshots` with that
  `repo` and `deliverables`. One run can capture two layouts behind a second
  throwaway flag. For a design choice, render "before" and each variant side
  by side (a static knob in the throwaway commit, one `mac_run` step per
  device) so the owner picks from one sheet; `AgentCardChrome` pads every
  card (Console, Hosts sheet, AI Usage, closed sessions), and the summary's
  loading skeleton has a fixed height to change with its font.

## Known traps

**Swift**

- `let x = …` before a `switch` expression ends the implicit return: write
  `return switch`.
- `guard a < b, c > .zero` parses as a generic argument list.
- A new defaulted parameter placed before a trailing closure takes that
  closure: label it at the call sites.
- `try #require(x)()`, and an optional async closure in a large initializer,
  crash the type checker: split the expression, or give the closure an
  explicit type.
- `await` on the right of `||` does not compile (it is an autoclosure): read
  both values first.
- `Mutex` is `~Copyable`, so an escaping closure cannot capture one: keep it
  in a small `final class`.
- A synchronous method beside an `async` protocol default leaves the default
  as the witness: spell it `async` in every conformer and fake.
- A `@TaskLocal` follows every `Task {}` started in its scope: pass a
  behaviour flag down as a parameter instead.
- Check for cancellation after every `await` that comes before a side
  effect. Separate `Task`s keep no order: serialize ordered work on one.
- A stream made inside `Task {}` subscribes only when the task first runs,
  and a stream that reports changes only (an activity's state) loses what
  came before: make it before the `Task` and iterate it inside. A test's
  poll can resume first on a busy main thread (hosted CI did).
- `#expect` on an `await` prints `<not evaluated>`, and a failed `waitUntil`
  prints no values: read the value into a local, or compute the difference,
  and `#expect` that.
- `Process` is not in the iOS SDK; `posix_spawn` works in the simulator.
- One Core Animation call off the main thread, even `setNeedsDisplay`,
  opens an implicit transaction that commits only when that thread exits,
  and the commit can lay out UIKit there (GhosttyTerminal patch 7).
  `CA_DEBUG_TRANSACTIONS=1` in the scheme's test environment (a throwaway
  commit) names who opened it. A red test for a logged symptom reads
  `OSLogStore(scope: .currentProcessIdentifier)` up to a marker it logs
  itself, so the read is known to be complete.
- `ScrollViewReader.scrollTo` while an opening animates goes nowhere (from
  `onChange` or the next main-queue turn alike): scroll from
  `withAnimation { … } completion:`.
- A view keyed with `.id(…)` is rebuilt when that id changes, and so is
  every sheet it presents: a sheet that updates the record behind the id
  (the Host page's `.id(host.recordForm)`) must be presented above that
  view, as HostListView's `HostAdditionSheet` is.

**Xcode and the project**

- A new source or test file needs its `Waycar.xcodeproj` entries, which any
  `make` build target regenerates on the Mac: commit the regenerated project.
- A compile-only build for `generic/platform=iOS Simulator` also links
  x86_64, which the committed SSH artifacts lack: build for an iPhone
  destination, or add `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`.
- `module file … is out of date`: delete
  `build/DerivedData/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules`.

**Tests and CI**

- Never put "skipped" in a test name: `run_suite` counts `Test .* skipped`
  lines.
- A workflow that runs only on some paths rots unseen: give it a weekly
  schedule too.
- Read CI results with `scripts/ci/ci-evidence.py`, which already reads
  each finished job's log. By hand, `gh run view --log` refuses a run still
  in progress, and `gh api repos/<owner>/<repo>/actions/jobs/<id>/logs`
  returns a finished job's log only with `--allow-escape-sequences` (gh
  2.103 refuses a body with terminal escapes, and CI logs have them). A
  pinned lane prints `==> <lane>: ran all N pinned tests, S skipped (A
  allowed)`, which `ci-evidence.py`'s `PINNED` pattern reads: change them
  together (`scripts/test-ci-evidence.py` runs the shipped echo). A test
  host that crashed relaunches, and Swift Testing's summary counts only its
  last launch: `ci-evidence.py` reports the launches and crash reports, and
  the app lanes upload `Waycar*.ips` when they fail.
- In one concurrency group a newly queued run cancels the run already
  pending, even with `cancel-in-progress: false`; check for queued `main`
  runs before a `workflow_dispatch`. A dispatch needs the workflow on the
  default branch.
- `apt-get update` exits 0 when its fetches fail: read its `W:` lines.
- Console rows show before the events channel carries their panes: the
  Console replaces its subscription after the snapshot that changed the
  Agent pane set, then snapshots again, and `ScriptedTransport.emit`
  returns false in between. After a fixture's first rows call
  `waitForInitialConsoleSync`; around a later change take
  `consoleSyncMark` before it and `waitForConsoleResync` after its effect,
  before the next `setSnapshot`, emit or count baseline. That second
  snapshot reads a `setSnapshot` staged for after an action too, so an
  action that checks identity (worktree removal, move) finds its target
  already gone (`.staleIdentity`). A step that only needs a fresh snapshot
  can `await store.refreshSidebarLayouts()`, which waits for every resync.
  A reconnect is such a change: the new connection subscribes without the
  panes, snapshots, then resubscribes and snapshots again, and a
  `refreshSidebarMetadata()` barrier can return before that resubscribe;
  wait for the live pane set and the revision read before the drop plus
  two. Hosted iPad and iPhone runs hit this six times. The gap also has no
  live channel: `revalidate()` (`reactivate()`, a foreground return) pings
  nothing there, and a `ScriptedTransport` closed there still accepts the
  replacement subscribe, so its Host stays connected. Wait for the sync
  before a gated ping or a `close()` too (flake hunt, twice).
- A fake's call counter moves when the call starts, before the call reads
  what it answers and before the store handles that answer. Before you
  change what a later call sees (a server starting), wait for the state the
  answer leaves, not for the count. A stopped-server probe's count let the
  test start the server while the probe was still out, so the probe saw it
  (flake hunt, `stoppedOpenCodeUsesOnlyAPortProbeUntilAnExternalStart`). A
  probe-only detection shows nothing, so wait for the Host's
  `backendDetections` machine to leave `.detecting`. A counter bumped at the
  end of a `@MainActor` closure that a main-actor caller awaits is
  different: that caller resumes without another hop, so a main-actor test
  that sees the count knows the code right after the await ran.
  Red proof: hold the call behind a gate after it is counted, and open the
  gate after the change.
- The [flake hunt](../../.github/workflows/flake-hunt.yml) runs the WaycarSSH
  package E2E lane and the full app lane 4 times each on two hosted runners,
  one with busy loops beside them (weeknights until 2026-11-30, then
  Mondays; by hand, `gh workflow run flake-hunt.yml --ref main -f passes=N
  -f package_passes=N`). Each job's
  summary lists every failing test and how many passes it failed in; the
  run itself never fails. Treat a test it names like a hosted CI failure:
  fix it at its cause, red-first. `scripts/ci/flake-hunt-report.py <folder>…`
  reads its downloaded artifacts.
- `actions/cache` saves only when the whole job passes, so a lane that never
  goes green rebuilds its cache every run: save a costly cache in its own
  `actions/cache/save` step.
- Hosted iOS lanes keep `host-load.log` in their diagnostics artifact
  (one-minute load against cores, free memory, top processes); a gap of
  minutes between samples means the runner itself stalled. A new iOS 27
  simulator's first boot saturates the 3-core `xcode-27` runner for about
  15 minutes. A throwaway probe workflow on a scratch branch settles a
  hosted-runner question in one run.
- A new `node --test` file under `plugin/` needs its own step in
  `ci-node.yml`.
- A real-sshd test that closes a PTY must first read something the remote
  command printed (`openPTYRunningCat` in the WaycarSSH package tests):
  reading back what it typed proves nothing, since the PTY echoes input
  before any process reads it. On a macOS Host, a PTY closed before sshd's
  forked child has made it its terminal never closes: the child misses the
  hangup, then waits forever opening a PTY whose master is gone, so sshd
  never reaps it (hosted CI, OpenSSH 10.3, load 20 on 3 cores).
- A scratch Codex config sets `check_for_update_on_startup = false`: once a
  newer Codex ships, a pinned TUI opens on an "Update available" menu and
  never shows the reply.
- A Codex test that stops a turn must first wait until the transcript shows
  the prompt, not just Working: Codex announces the turn 7–20 ms before it
  stores the prompt, and an interrupt in that gap drops the prompt for good
  (X26 in `docs/design/codex-backend.md`, hosted CI).
- The simulator's keyboard runs in its own process, InputUI, which a loaded
  hosted runner can lose mid-test. The pass log then shows
  `[Client] XPC connection invalidated` (or `interrupted`) and
  `-[_UIRemoteKeyboards proxy] … Failed to access remote service`; the
  keyboard leaves, its text view resigns first responder, and an inset test
  reads 0 (flake hunt, `terminalKeyboardTakesMessageAgentsVisibleKeyboardWithoutReloading`).
  Wait for the settled keyboard right before the step under test, raise it
  again when focus went, and read heights only there. A settled check must
  compare samples with the live value too: samples stable at 0 say nothing
  about an inset published since. To reproduce it, a throwaway test lists
  its simulator's processes (`sysctl` `KERN_PROC_ALL`, parent `getppid()`,
  the test host's own `launchd_sim`) and `SIGKILL`s `InputUI`.

**Shell**

- macOS `/bin/bash` is 3.2: an empty `"${a[@]}"` is unbound under `set -u`.
  Run shell test harnesses (`scripts/test-run-ci-ios-tests-guards.sh`) on the
  Mac before trusting them.
- Under `set -e` and `pipefail`, a `grep` that matches nothing inside
  `$(…)` ends the script without a word; give `grep -c` an `|| true`.
- `pgrep -f`/`pkill -f` can match the shell command line that runs them
  (`bash -lc '…'`, an agent's shell call): kill by pid, or bracket a letter
  (`[x]codebuild`).
- `ssh` inside a script fed to `bash -s` reads the rest of the script: pass
  `-n`. An installer that reads stdin (`apt-get`) eats a piped script too:
  copy the script in and run the file.
- Unix socket paths stop at 103 bytes on macOS and 107 on Linux: keep
  scratch HOMEs and socket folders short, under `/tmp`.
- A fake agent that is a `sh` script reads as a shell: start it as
  `exec -a claude sh agent.sh`, and give a pane that must stay busy
  `exec sleep`.
- Containers that run a server need `docker run --init`, or exited
  processes stay as zombies that still read as running.
- `/tmp` is shared by every agent on a host: name scratch files after your
  branch or issue.
- Agent CLIs can keep their config outside a scratch `HOME` (environment
  variables win, as `omp config set` showed): on a shared machine, run only
  `--help`, `--version` and status commands of the real ones.

**Plugin (Rust)**

- `eval "$(sh scripts/ci/provision-plugin-build.sh)"` puts the pinned cargo
  and zig on `PATH`. On a box with no Rust yet, run it once without `eval`
  to install, then `eval` it.
- A `cargo test` that passes alone proves nothing about forks: before review,
  run the `cargo test --no-run` binary 24 times in parallel. Tests write stub
  scripts through `test_support::write_script`.
- Tests never find machine-wide programs (`/usr/local/bin`,
  `/opt/homebrew/bin`): such lookups are dead ends under `cfg(test)`.
- `Command::spawn` returns before the kernel sets the child's new command
  line: `/proc/<pid>/cmdline` read right after it was empty 289 times in
  300. A test that reads a child's arguments starts it with
  `test_support::spawn_shell`, which waits for the shell's first line. A
  verdict that needs a subprocess to exit within 300 ms flaked on a loaded
  runner too: give it seconds.
- `rust/` ships, test modules included: a test-only change there bumps the
  plugin patch version like any other.
- A value placed in a tmux format (`#{==:…,value}`) must hold no `#`, `,`,
  `}` or control character; anything else takes the unconditional path
  instead of a format it could break.
- A Dependabot cargo PR changes `Cargo.lock` but never regenerates
  `plugin/THIRD-PARTY-LICENSES` or bumps the plugin version, so it fails
  the Plugin version guard and `plugin-licenses.py --check`. Push the fix
  onto Dependabot's branch: bump the plugin patch version (both tomls,
  `cargo update -p waycar --offline`, `currentVersion`), run
  `python3 scripts/plugin-licenses.py`, then the Before submit plugin checks;
  review, wait for green and squash-merge the PR. Keep that branch to the
  bump and what it needs: the run-learnings entry and any doc edits land
  through `workspace submit`, or the PR sweeper treats it as a human PR and
  asks for an issue. Other Dependabot PRs merge one at a time, oldest first,
  with `gh pr merge <n> --squash --match-head-commit <full 40-char sha>`.

**Site (`apps/web`)**

- The site uses npm, and the repository has no root `package.json`, so
  `pnpm check` is no gate. Install per worktree with `npm ci --include=dev`
  (with `NODE_ENV=production`, plain `npm ci` leaves Astro out), then run
  `npm run check`, `npm test` and `npm run build`.
- Help pages ship in the app and go live on the site on push: a product-wide
  copy change gets a commit of its own, so it can be timed with the release.
- A product claim lives in more than `content/help`: grep all of
  `apps/web/src` and the root docs.
- A component that must look the same everywhere takes no caller
  attributes: Astro hands every child the parent's `data-astro-cid-*`, so a
  spread inherits the caller's scoped styles. Underline a span inside an
  `inline-flex` link, not the link, or its `inline-block` children get it too.
- A new line in an article-rail module also changes `MODULE_HEIGHTS`
  (`src/data/article-rail.ts`), and `scripts/articles.test.mjs` allows no
  off-site link there but the App Store and the repository's GitHub page. A
  new site analytics event also changes the "This website" sentence and date
  in `PRIVACY.md`.
- A green deploy is not a live site. Prove a deploy on the live URL with what
  that run built (for `install.sh`, its hash-named tarballs, as
  `scripts/ci/check-live-installer.sh` does), not with a version you expect,
  and check again before you report: one check passed at 20:14, and another
  deploy put an old snapshot back at 20:57. When the live file is wrong, read
  which Worker version serves (`npx wrangler deployments list` in
  `apps/web`) before you blame caches. `cf-cache-status: HIT` on a Workers
  asset does not mean stale across deploys.

**Public history**

- A tree scan misses text one commit adds and a later one removes, which the
  push still publishes: `scan.py --commits <rev>` checks what each
  unpublished commit adds, and its message.
- GitHub keeps serving commits force-pushed away or left on deleted
  branches (by SHA), and the edit history of issue and PR bodies and
  comments: editing text out removes nothing. A leak sweep scans every blob
  reachable from any ref of a mirror clone (`refs/pull/*` included), plus
  the commits the repository activity API lists as force-pushed or on
  deleted branches, fetched by SHA.
- A public repository's Actions logs and artifacts are public too. The
  `.xcresult` data files in the CI diagnostics artifacts are
  zstd-compressed, so a plain grep finds nothing in them.

## Each run makes the skill better

This skill is load-bearing only if it absorbs what runs learn. Every run that
follows it adds **one entry** to the [run learnings](run-learnings/): a file of
its own, `docs/agents/run-learnings/<YYYY-MM-DD>-<slug>.md`, in the format the
[folder's README](run-learnings/README.md) gives:

- what worked and what broke, in one line each;
- anything a future run would otherwise rediscover (a command that failed, a
  gate that caught something, a convention that wasn't where the docs said).

One file per run keeps parallel branches from conflicting: when the log was
one list in this file, every lander conflict for days was in it.

When the same lesson appears twice, fold it into the rules above (or the
[Mac workflow](mac-workflow.md), or `AGENTS.md`) and delete the entries that
carried it. Keep at most 20 entries: the run whose entry makes 21 folds what
is still worth keeping from the oldest and deletes them. Folding and pruning
are the only permitted edits to other runs' entries.

The entry rides the same PR (or Ultimate branch) as the run's work — never a
PR of its own. A fixed Dependabot PR is the exception: its entry lands
through `workspace submit`, so a reviewer of that PR does not ask for one. If
a lesson surfaces after that PR has merged (during review, or at cleanup),
carry it into the next run's PR or branch. A reviewer treats a missing
run-learnings entry as a blocking finding: it is the only thing that enforces
this loop.

## Run learnings

The entries live in [`run-learnings/`](run-learnings/), newest first by file
name (`ls -r docs/agents/run-learnings/2*.md`). The log starts again at the
open-source cut; the entries before it stay in the maintainers' archive.
