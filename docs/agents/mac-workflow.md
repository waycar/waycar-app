# Mac Workflow

The agent host has no Xcode, so simulator tests, screenshots and device
installs run on the Mac build host. This page is the procedure for that work.
The rules it follows are in [`AGENTS.md`](../../AGENTS.md) › Simulators (shared
Mac). Where the Mac notes in the
[run learnings](run-learnings/) disagree with this page, this page wins.

`mac` below stands for the Mac build host's SSH target, such as a `Host mac`
entry in the agent host's `~/.ssh/config`. Its address and user are kept in
the agent's memory or local SSH config. Never write them into this
repository.

## Prefer `mac_run`

If your agent host has the `mac_run` tool (the personal Ultimate extension
`mac-run`), use it for any one make target at one commit: `test-app`,
`test`, `test-ipad`, `test-ci-app`, `test-ci-package`, `build-sim`, device
builds and installs, screenshots. It does sections 1, 2, 3 and 5 below with the ground rules built
in, and returns one result card: pass or fail, test counts, failing tests,
crash reports, durations and the Mac's load before and after.

- Before it queues, it checks the variables and every test id against the
  commit, and refuses what would break the recipe or select no tests, saying
  how to write it. Write Swift Testing ids as xcodebuild prints them,
  `-only-testing:WaycarTests/FooTests/bar()` or `bar(label:)`; it adds the
  backslashes make's shell needs.
- It stages the exact commit, bundling commits GitHub doesn't have, and
  checks HEAD.
- One run at a time on the whole Mac, first come first served; a waiting run
  says who is ahead.
- It waits while a CI job runs (except for `test-ci-app` and
  `test-ci-package`) or while the Mac is
  already overloaded. It runs make at `nice -n 19`, and caps the app-test
  build of `test-app`, `test` and `test-ipad`, and `build-sim`, at half the
  cores.
- Simulators come only through the make targets' queue, on the runtime that
  holds the pool. Device builds sign in the GUI session; installs need notes.
- It copies deliverables to the Mac's Desktop before it removes anything,
  removes only what it made, then copies them to Google Drive.

`background: true` returns a run id at once, so you can keep working;
`mac_run {run: <id>}` waits for the card later, and
`mac_run {run: <id>, cancel: true}` stops a run. A session step takes
`background: true` too and returns `<session>/<step>` for `run`.

`mac_run {status: true}` shows the queue with ages, who holds the Mac and
what it runs, with its test count and last log line, plus the load and any
CI job. Use it instead of polling the Mac over SSH.

For several targets or commits in a row, such as a compile, a full suite and
base-vs-merged proofs, a flake repeated, or an iPhone and iPad pair, open a
session: `mac_run {session: "open", sha}` takes one place in the same queue
and keeps one clone. `mac_run {session: <id>, target, sha?}` runs one target
in it, at any commit, with incremental builds, and
`mac_run {session: <id>, close: true}` keeps the deliverables, releases the
simulators and removes the clone. Close it as soon as you are done, since
everyone else waits meanwhile. A session is released after 15 idle minutes
and after 2 hours in all.

Never run your own runner script or take your own lock on the Mac, such as a
`/tmp` slot directory or a loop of `make` over SSH. `mac_run` can't see them,
so two builds overlap and everyone in the queue is told the Mac is free.
Use the manual steps below only for what `mac_run` does not cover: OTA
installs and interactive debugging. For anything else it can't do, ask the
user first.

## Ground rules

- Ask the build Mac's owner before you change the Mac itself: before you
  install or upgrade software there (Homebrew formulas and casks, `npm -g`
  packages, language runtimes such as Node or Python), and before you touch
  anything security-related (Gatekeeper, quarantine flags, TCC permissions,
  keychains, LaunchAgents other than Waycar's own). Setup that stays inside
  your run's own scratch directory needs no ask: a fixture's HOME, a
  fetched and checksummed binary, a user-mode sshd. A CLI installed over SSH
  once hung CI weeks later, and clearing its quarantine flag without asking
  was the wrong fix.
- Pick one slug for everything you create, such as your issue or conversation
  id. Your clone is `~/src/waycar-worktrees/<slug>`. Your files are
  `/tmp/<slug>.bundle`, `/tmp/<slug>-*.log`, `/tmp/<slug>-notes.txt` and
  `/tmp/<slug>-prompt.txt`, on both machines. Every agent and CI job shares the
  Mac's `/tmp`.
- Keep anything sent to Apple or users: review videos, App Store attachments,
  screenshots and release-notes files. Before any `rm`, copy each file to both
  places below on the Mac. Google Drive for desktop syncs the second folder.
  Keep these paths here only; set the variables in the shell doing cleanup:

  ```sh
  DELIVERABLES="$HOME/Desktop/Waycar deliverables/<slug>"
  DRIVE_DELIVERABLES="$HOME/Library/CloudStorage/GoogleDrive-<account>/My Drive/Waycar/Deliverables/<slug>"
  ```

  Never put these files in the repo: it is public, and App Review material
  stays private. Name both paths in the report.
- Limit deliberate load: stress tests, parallel builds and load generators
  such as `yes`:
  - Use at most half the cores (`sysctl -n hw.ncpu`), at `nice -n 19`, for
    10 min or less. Prefer a deterministic reproduction over loading the Mac.
    The 10 minutes are for load you add on purpose: an ordinary build or
    test run (one `mac_run`, one make target) may take longer, and follows
    the queue and the `nice` rules here.
  - Never run it while a CI job runs on this Mac's runner. Check first:
    `pgrep -fl Runner.Worker` must print nothing. A job runs exactly while
    `Runner.Worker` exists; `Runner.Listener` is always there.
  - Use a `trap` on exit that kills only the processes you started. Afterwards,
    `pgrep -x yes` (or the tool's own name) must print nothing.
  - CI jobs run at nice 15. Agent work at normal priority (nice 0) starves CI.
    Keep one simulator test run at a time per worktree.
- A non-interactive SSH shell has neither Homebrew nor `~/.local/bin` on
  `PATH`. Begin every remote command that runs `make`, `herdr`, `gh` or `omp`
  with `export PATH=/opt/homebrew/bin:$HOME/.local/bin:$PATH`. Homebrew holds
  `xcodegen`, `gh` and `omp`; `~/.local/bin` holds `herdr`. Without it, `make`
  stops with `xcodegen: No such file or directory`. That shell also has
  `TERM=dumb`: set `TERM=xterm-256color` for anything that draws a terminal
  (mosh-client otherwise stops with "Terminfo database could not be found").
  Write Python meant to run there outside `make` for `/usr/bin/python3`
  (3.9).
- The remote shell is zsh, which does not word-split an unquoted `$var`.
  Use `timeout <seconds> <command>` (macOS 27.2 has `/usr/bin/timeout`). On an
  older macOS without it, use `perl -e 'alarm 600; exec @ARGV' <command>`.
- macOS updates reset Xcode first-launch; CI self-heals via `sudo -n`
  (`scripts/check-xcode-first-launch.sh`). Other `make` targets don't: when
  `xcodebuild -checkFirstLaunchStatus` exits 69, run
  `sudo -n xcodebuild -runFirstLaunch` first.
- A build tree takes 3–4 GB. Check `df -h /System/Volumes/Data` first, and ask
  before you build with less than 10 GB free.
- Leave these alone:
  - The user's checkout `~/src/waycar`. Don't check out, fetch, reset, stash,
    configure or `git worktree add` there. Reading it is fine.
  - Anything in `~/src/waycar-worktrees` that you did not create.
  - The `Waycar CI` simulator, and simulators another worktree holds.
  - The test Ultimate server. Don't stop or restart it.
  - The user's own herdr workspaces and tabs.

## 1. Put the exact commit on the Mac

Make a fresh clone of your own. Don't `git worktree add` from `~/src/waycar`:
that writes branches, config and worktree entries into the user's `.git`.

```sh
ssh mac 'git clone -q git@github.com:waycar/waycar-app.git ~/src/waycar-worktrees/<slug>'
```

On the Mac, git reaches GitHub only over SSH. The Mac's SSH key works from a
non-interactive session. HTTPS needs the Keychain or the `gh` credential helper,
and neither works outside the GUI session: they fail with `could not read
Username for 'https://github.com'`. So clone with the `git@github.com:` URL. If
a clone's remote uses HTTPS, give it the same repo-local rewrite the user's
checkout has: `git config url.git@github.com:.insteadOf https://github.com/`.
Set it in that clone only, never with `--global`.

Then check out the commit:

- **Already on GitHub** (main, or a branch someone pushed): run
  `git fetch -q origin <branch> && git checkout -q --detach <sha>` in the clone.
- **Not pushed** (the usual case; don't push just to run a test): from your
  worktree on the agent host, bundle the commits GitHub doesn't have:

  ```sh
  git bundle create /tmp/<slug>.bundle origin/main..HEAD
  scp -q /tmp/<slug>.bundle mac:/tmp/<slug>.bundle
  ssh mac 'cd ~/src/waycar-worktrees/<slug> && git fetch -q /tmp/<slug>.bundle HEAD && git checkout -q --detach FETCH_HEAD'
  ```

  The bundle's base must be a commit the clone already has. `origin/main`, as
  you last fetched it, is one. Unpushed local commits below HEAD come along
  in the bundle. If you get `Refusing to create empty bundle`, HEAD is already
  on GitHub, so fetch it instead.

Before you trust any result, check that
`ssh mac 'git -C ~/src/waycar-worktrees/<slug> rev-parse HEAD'` prints your
SHA, and give that SHA with the result. A throwaway file, such as a test that
takes a screenshot, can go into the clone with `scp`. It is deleted along with
the clone.

## 2. Run simulator tests

1. **Choose the OS from the runtimes installed now.** Don't copy an `OS=` from
   an older run. The shared set from AGENTS.md (three iPhone 17 Pro Max and two
   iPad Pro 13-inch (M5)) sits on one iOS 27 runtime. An Xcode update can add
   a newer runtime that doesn't have the set. A destination with only `name=`
   then resolves to `OS:latest` and fails with `Unable to find a device
   matching the provided destination specifier`. Runs in October 2026 needed
   27.2 at one point and 27.0 at another. List the pool:

   ```sh
   ssh mac "xcrun simctl list devices available | grep -E '^-- |iPhone 17 Pro Max|iPad Pro 13-inch \(M5\)'"
   ```

   Use the `-- iOS x.y --` section that has the model and its copies
   (`<model> 2`, `<model> 3`). A stock simulator of the same model on another
   runtime is not part of the pool. Pass the exact version shown: `OS=27.0`,
   not `OS=27`. If no runtime has the pool, stop and report it, following
   AGENTS.md (`make sim-status`, `make sim-pool`). Don't create simulators or
   install runtimes.

2. **Run a make target in the background.** It compiles first, then waits in
   line for a simulator slot (`scripts/sim-slot.py`), and holds that slot
   until `make sim-release`:

   ```sh
   ssh mac 'export PATH=/opt/homebrew/bin:$HOME/.local/bin:$PATH; cd ~/src/waycar-worktrees/<slug> && nohup make test-app SIM_DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro Max,OS=<os>" TEST_FLAGS="-only-testing:WaycarTests/<Suite>" > /tmp/<slug>-test.log 2>&1 < /dev/null & echo started'
   ```

   - **iPad:** use the same command with `name=iPad Pro 13-inch (M5)` and the
     iPad's OS. `make test-ipad` runs all of `make test`, including WaycarSSH
     and SwiftMosh. A `SIM_DESTINATION` you set replaces its iPad, so give it
     the iPad destination too.
   - **iPhone, then iPad:** run `make sim-release` between the two runs. Never
     hold one simulator while you wait in line for the other.
   - **Two devices in one run:** `make test-app` leases only
     `SIM_DESTINATION`. For a second `-destination` in `TEST_FLAGS`, acquire
     both first in one call (`scripts/sim-slot.py acquire <iPhone> <iPad>`)
     and pass the UDIDs it prints; otherwise the test wrapper boots the
     second one without a lease.
   - **Test ids with `()`:** write them as `\(\)` in `TEST_FLAGS`.
   - **`make test-ci-app` and `make test-ci-package`:** they use `Waycar CI`
     and manage their own claim, so never acquire or release that simulator.
     If another run holds it, the target waits, naming the holder's pid once
     a minute, for up to `WAYCAR_CI_SIM_WAIT_SECONDS` (45 min), then stops
     with "Every available Waycar CI Simulator is claimed by a live run".
     `test-ci-app` is CI's app lane; by hand it also needs Node 24 on `PATH`
     and `WAYCAR_PAIR_ACCEPT_BIN` from `scripts/ci/build-native-waycar.sh`
     (`mac_run` sets both). `test-ci-package` is CI's WaycarSSH package E2E
     lane: the fixture-backed `Packages/WaycarSSH` suites
     (`SessionDriver*E2ETests` among them) with the lane's pinned count, a
     few minutes after its build. Run it instead of a hosted draft-PR round
     trip when you change `Packages/WaycarSSH`. `mac_run` gives both the
     ci.yml step's environment (`WAYCAR_CI_MANDATORY=1`,
     `WAYCAR_SSH_E2E_TIMEOUT_SCALE=4`). To run a few suites inside a lane's
     real fixture, use a throwaway copy of `scripts/run-ci-ios-tests.sh` that
     drops the other `run_suite` calls, and read its log, since its count
     gate then fails.

3. **Check on the run instead of sleeping for minutes.** Every 30 s or so:

   ```sh
   ssh mac 'grep -E "Test run with|Executed [0-9]+ test|\*\* (TEST|BUILD) (SUCCEEDED|FAILED)|crash report|make: \*\*\*" /tmp/<slug>-test.log | tail -5'
   ```

   Report the SHA, the number of tests run, any failures or skips, and the
   crash-report line. A Swift Testing suite also prints XCTest's `Executed 0
   tests`; its own count is on the `Test run with` line. A Swift Testing
   selector without its `()` runs zero tests and still passes, so check the
   count. Any crash report
   means the run failed, and you must investigate it (AGENTS.md). If the run waits in line for long, run
   `make sim-status` and then `make sim-doctor`. Never get around the queue.

4. **Release the simulator right away:**
   `ssh mac 'cd ~/src/waycar-worktrees/<slug> && make sim-release'`. The
   simulator's lease belongs to the clone's top-level directory, so run this
   inside the clone, and before you delete it.

**A scratch Host on the Mac**, for a real-SSH probe that must not touch the
owner's account: a user-mode `sshd -D -f <config>` on a high port
(`UsePAM no`, `StrictModes no`, its own host key and `AuthorizedKeysFile`,
`Subsystem sftp /usr/libexec/sftp-server`, `SetEnv HOME=<scratch>`). Probe
herdr or herdr-core in a named session of your own (`HERDR_SESSION=<slug>`,
`HC_SESSION=<slug>`), never the default one, then stop and delete that
session, the sshd and the scratch HOME.

## 3. Install on the iPhone and iPad

Over SSH, `make install` builds the app and then fails to sign it with
`errSecInternalComponent`, because the login keychain is locked outside the
user's GUI session. Don't try to unlock the keychain. Instead, hand the install
to an OMP agent in the Mac's herdr GUI session. herdr's panes run in the
user's logged-in session, where signing works. The user approved this path.
If `herdr workspace list` can't connect, or OMP doesn't start, use the
[launchd fallback](#fallback-a-one-time-launchd-job) instead.

Steps 3 to 5 run on the Mac (`ssh mac '…'`, with the `PATH` above).

1. **Stage** your clone as in
   [step 1](#1-put-the-exact-commit-on-the-mac). The commit doesn't need to
   be pushed.
2. **Write the notes.** Every device build carries What's New notes (AGENTS.md
   › Conventions). A fresh clone has no install history, so `NOTES=auto` would
   fall back to the last 20 commit subjects. Write a file instead, one
   `symbol|text` line for each thing to try:

   ```sh
   ssh mac 'cat > /tmp/<slug>-notes.txt' <<'EOF'
   sparkles|What to try on this build
   EOF
   ```

3. **Start OMP in its own tab:**

   ```sh
   herdr workspace list     # pick a workspace_id, such as the one labelled Waycar
   herdr tab create --workspace <workspace_id> --cwd ~/src/waycar-worktrees/<slug> --label "device build <slug>"
   # note root_pane.pane_id and tab.tab_id in the JSON, then wait about 8 s for the shell prompt
   herdr agent start build-<slug> --kind omp --pane <pane_id>
   ```

   You reach the agent by its name, so make the name unique to this run. It
   must match `^[a-z][a-z0-9_-]{0,31}$`.

4. **Prompt it.** First write the prompt to a file, as you did the notes:
   that keeps the quoting out of the SSH command. Keep the prompt on one
   line: a typed newline can submit it early, and every past run sent a
   single line. Then send it with
   `herdr agent prompt build-<slug> "$(cat /tmp/<slug>-prompt.txt)"`. The
   prompt, shown wrapped here:

   ```text
   You are in ~/src/waycar-worktrees/<slug>, a fresh clone at <sha>. Do NOT pull, fetch, push or change code.
   The iPhone and iPad may be on Wi-Fi, not USB. Run these two commands in order:
   1) make install NOTES=/tmp/<slug>-notes.txt > /tmp/<slug>-iphone.log 2>&1; echo "exit $?" >> /tmp/<slug>-iphone.log
   2) make install-ipad NOTES=/tmp/<slug>-notes.txt > /tmp/<slug>-ipad.log 2>&1; echo "exit $?" >> /tmp/<slug>-ipad.log
   If one fails, show its last 30 lines and stop. If a device is not found, run `xcrun devicectl list devices`
   and say which device is missing. Do nothing else.
   ```

5. **Wait, then read the logs yourself.** Two installs have taken 5–10 min.
   Every 30 s or so, check the agent's `agent_status` in `herdr agent list`.
   Once it reads `done`, check each device:

   ```sh
   grep -E "BUILD FAILED|launch was refused|^exit " /tmp/<slug>-iphone.log /tmp/<slug>-ipad.log
   grep -r . ~/src/waycar-worktrees/<slug>/build/local-installs
   ```

   Install and launch are separate results. Report each one for each device:

   - **Installed:** the log ends with `exit 0`, and
     `build/local-installs/<device id>` holds your SHA. `make install` writes
     that file only after the install.
   - **Launched:** the log has no `Installed, but the launch was refused
     (device locked?)` line. A locked device accepts the install but refuses
     the launch (`CoreDeviceError error 10002`). Then tell the user to unlock
     it and open Waycar.
   - **Build number:** take it from the device, not from `project.yml`:
     `xcrun devicectl device info apps --device <device id> --bundle-id com.otreva.waycar`.
     That command works over SSH.

### Fallback: a one-time launchd job

When herdr or OMP isn't reachable, run the signing command as a one-time
launchd job in the user's logged-in GUI session (`gui/<uid>`). Its processes
sign like herdr's panes do. Approved as the fallback on 2026-11-04. Never
unlock the keychain. `launchctl asuser` doesn't work here: over SSH it fails with
`Could not switch to audit session … Operation not permitted`.

1. **Test signing first.** `security find-identity -v -p codesigning` lists
   two `Apple Development` identities, so give `codesign` the SHA-1 of the
   one you want. Write a script that runs
   `codesign -f -s <sha1> /tmp/<slug>-cs` on a copy of `/usr/bin/true` and
   writes the exit code to `/tmp/<slug>-cstest.log`. Run it as a job, the way
   the next step runs the build, then boot the job out. Go on only if the log shows
   `rc=0`. Over plain SSH the same command fails with `errSecInternalComponent`.
2. **Run the build as a job.** Write the command into `/tmp/<slug>-build.sh`.
   Use the `make install …` lines from step 4 above, or an archive and export
   for an OTA link. Begin the script with the `PATH` export from
   [Ground rules](#ground-rules) and `cd ~/src/waycar-worktrees/<slug> || exit 1`:
   a launchd job has no Homebrew on `PATH` and starts outside your clone.
   Then load it with a plist (replace `<slug>`; the redirects stay
   XML-escaped):

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0"><dict>
     <key>Label</key><string>dev.waycar.<slug>-build</string>
     <key>ProgramArguments</key><array>
       <string>/bin/zsh</string><string>-c</string>
       <string>/bin/zsh /tmp/<slug>-build.sh &gt; /tmp/<slug>-build.log 2&gt;&amp;1; echo "exit $?" &gt;&gt; /tmp/<slug>-build.log</string>
     </array>
     <key>RunAtLoad</key><true/>
   </dict></plist>
   ```

   ```sh
   launchctl bootstrap gui/$(id -u) /tmp/<slug>-build.plist
   ```

3. **Wait** for the `exit` line in the log, as in step 5, and read the
   results the same way.
4. **Remove the job**, whatever the result:
   `launchctl bootout gui/$(id -u)/dev.waycar.<slug>-build`. Then
   `launchctl print gui/$(id -u)/dev.waycar.<slug>-build` must fail.

A job started with `launchctl submit` instead is KeepAlive: launchd reruns
it when it exits, and the rerun overwrites its output. Make such a script
refuse a second run (a marker file, then `exec sleep`) and `launchctl remove`
it as soon as it has run.

## 4. Install over the air (OTA)

When `make install` can't find the iPhone or iPad (not on USB or the Mac's
Wi-Fi), build a signed Debug IPA on the Mac and serve an install page over
Tailscale. Signing still needs the GUI session. Run the build through the
[OMP agent](#3-install-on-the-iphone-and-ipad) or the
[launchd fallback](#fallback-a-one-time-launchd-job), never by unlocking the
keychain.

1. **Stage the clone and notes** as in section 3. Write steps 2–3 into
   `/tmp/<slug>-ota.sh` and have OMP or the launchd job run it. Replace the
   placeholders first. Use fresh archive/export paths; before removing any
   earlier output, keep its deliverables as in [Ground rules](#ground-rules).

2. **Archive with local What's New notes.** Keep the restore trap even if
   the build fails:

   ```sh
   #!/bin/zsh
   set -euo pipefail
   export PATH=/opt/homebrew/bin:$HOME/.local/bin:$PATH
   cd "$HOME/src/waycar-worktrees/<slug>"
   BASE='https://<mac-tailscale-name>/waycar-ipa'
   OUT='/tmp/<slug>-ota'
   TEAM_ID='<team id>'
   trap 'git restore -- Sources/Waycar/Resources/WhatsNew.json' EXIT
   scripts/write-local-whats-new.sh /tmp/<slug>-notes.txt ota
   make generate
   xcodebuild -project Waycar.xcodeproj -scheme Waycar -configuration Debug \
       -destination generic/platform=iOS -archivePath build/OTA.xcarchive \
       -allowProvisioningUpdates -allowProvisioningDeviceRegistration archive
   ```

   The device must be listed in the provisioning profile. Automatic signing
   with device registration includes registered devices; if it is missing,
   register it before exporting. An OTA link alone cannot register a device.

3. **Export and prepare the page.** Continue the same script so `$BASE`,
   `$OUT`, `$TEAM_ID` and the restore trap still apply. The plist's `thinning`
   value is the literal `<none>` (XML-escaped below):

   ```sh
   cat > /tmp/<slug>-export.plist <<PL
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0"><dict>
     <key>method</key><string>debugging</string>
     <key>teamID</key><string>$TEAM_ID</string>
     <key>signingStyle</key><string>automatic</string>
     <key>thinning</key><string>&lt;none&gt;</string>
     <key>manifest</key><dict>
       <key>appURL</key><string>$BASE/Waycar.ipa</string>
       <key>displayImageURL</key><string>$BASE/icon.png</string>
       <key>fullSizeImageURL</key><string>$BASE/icon.png</string>
     </dict>
   </dict></plist>
   PL
   xcodebuild -exportArchive -archivePath build/OTA.xcarchive \
       -exportOptionsPlist /tmp/<slug>-export.plist -exportPath build/ota-export \
       -allowProvisioningUpdates
   mkdir -p "$OUT"
   cp build/ota-export/Waycar.ipa build/ota-export/manifest.plist "$OUT/"
   cp build/OTA.xcarchive/Products/Applications/Waycar.app/AppIcon60x60@2x.png "$OUT/icon.png"
   SHA=$(git rev-parse HEAD)
   BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/OTA.xcarchive/Products/Applications/Waycar.app/Info.plist)
   cat > "$OUT/index.html" <<HT
   <!doctype html>
   <meta name="viewport" content="width=device-width, initial-scale=1">
   <title>Waycar $BUILD</title>
   <h1>Waycar $BUILD (Debug)</h1>
   <p>$SHA</p>
   <p><a href="itms-services://?action=download-manifest&amp;url=$BASE/manifest.plist">Install Waycar</a></p>
   HT
   echo "Install: $BASE/; SHA: $SHA; build: $BUILD"
   ```

4. **Serve only your path.** Check `tailscale serve status` before and after.
   Preserve the existing `/` mapping. Add only `/waycar-ipa`; never use
   `serve reset` or Funnel. If the CLI is not on `PATH`, use
   `/Applications/Tailscale.app/Contents/MacOS/Tailscale` in its place.
   If `/waycar-ipa` already serves a previous build, preserve any deliverables
   first, then replace the four files in its served folder in place. Reuse its
   server and path; don't start a second server or add another path. Arrange
   cleanup for the replacement build, replacing the old cleanup schedule too.

   For a new route only, pick a free `<port>`
   (`lsof -nP -iTCP:<port> -sTCP:LISTEN` prints nothing).
   Write `/tmp/<slug>-serve.py`:

   ```python
   import functools
   import http.server

   handler = functools.partial(http.server.SimpleHTTPRequestHandler,
                               directory="/tmp/<slug>-ota")
   handler.func.extensions_map.update({".plist": "text/xml",
                                       ".ipa": "application/octet-stream"})
   http.server.ThreadingHTTPServer(("127.0.0.1", <port>), handler).serve_forever()
   ```

   Run on the Mac:

   ```sh
   tailscale serve status
   nohup /usr/bin/python3 /tmp/<slug>-serve.py > /tmp/<slug>-serve.log 2>&1 < /dev/null &
   echo $! > /tmp/<slug>-serve.pid
   tailscale serve --bg --set-path /waycar-ipa http://127.0.0.1:<port>
   tailscale serve status
   ```

   Check the page, manifest, IPA and icon over HTTPS before reporting the link.
   The user opens `$BASE/` in Safari on the device with Tailscale on and taps
   **Install Waycar**. Report that link, the full SHA and the archived build
   number. Don't claim installation until the user confirms it.

5. **Remove the OTA route** when the user has installed, or schedule removal
   for 24 h after setup. Keep the IPA in both deliverable folders first only
   if it was sent to users. Follow [Clean up](#5-clean-up); if a copy fails,
   stop and report it. Then remove only your Serve path, stop the file server
   by its recorded pid, and delete the OTA folder:

   ```sh
   tailscale serve status
   tailscale serve --set-path /waycar-ipa off
   tailscale serve status
   ps -p "$(cat /tmp/<slug>-serve.pid)" -o pid=,command=   # confirm it is your server
   kill "$(cat /tmp/<slug>-serve.pid)"
   rm -rf /tmp/<slug>-ota
   ```

   Verify `/` is unchanged and the file server is gone. When replacing a
   build, use the existing server's recorded pid and folder, not a guessed
   pid. Then finish cleanup below, including any launchd build job.

## 5. Clean up

Once you have the result, remove only what you created. On the Mac, in order:

**Keep deliverables first.** Set the two path variables from
[Ground rules](#ground-rules) in this shell. Repeat both lines for each file
sent to Apple or users, using its full path for `<deliverable>`. If either
copy fails, stop: do not remove the clone or scratch files, and say so in the
report. Name both destination paths in the report, even after cleanup.

```sh
mkdir -p "$DELIVERABLES" && cp -p "<deliverable>" "$DELIVERABLES/" || exit 1
mkdir -p "$DRIVE_DELIVERABLES" && cp -p "<deliverable>" "$DRIVE_DELIVERABLES/" || exit 1
```

Only after every required copy succeeds, continue. If an OTA route is still
needed, schedule its cleanup and keep its folder and server until then; do
not run the broad `/tmp/<slug>-*` removal yet. Otherwise remove the
[OTA route](#4-install-over-the-air-ota) first, if you made one.

```sh
cd ~/src/waycar-worktrees/<slug> && make sim-release && make sim-status   # if you used a simulator
herdr tab close <tab_id>                                                  # if you started OMP; ends the agent too
launchctl bootout gui/$(id -u)/dev.waycar.<slug>-build                    # if you used the launchd fallback
cd && rm -rf ~/src/waycar-worktrees/<slug> /tmp/<slug>.bundle /tmp/<slug>-*
pgrep -fl <slug>                                                          # expect nothing
```

On the agent host, run `rm -f /tmp/<slug>.bundle`. Then say in your report what
you removed. Leave everything in [Ground rules](#ground-rules)'s "Leave these
alone" list as it was.
