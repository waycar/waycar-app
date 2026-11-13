# tmux as a second backend

Prepared 2026-09-30 from a multi-agent web survey and a static read of Waycar
at `47c3fbf8`. Star counts, ratings and dates are as fetched that day. Nothing
here was run against a live tmux host when it was written; the Validation
section at the end records what a live check confirmed or corrected. The plan
built on it is `docs/design/tmux-backend.md`.

## Goal

- herdr stays first: default onboarding path, hero copy, richest feature set.
- tmux becomes the second backend, so Waycar reaches people who will never
  install herdr.
- Promote tmux support visibly, with an honest per-backend capability table.

## Why herdr stays primary

- Category leader: 41.7k stars in six months (v0.1.0 on 2026-03-27, v0.9.3 on
  2026-09-29), Apache-2.0 since 0.8.0, 22 agent CLIs detected, about 1.4k
  plugins. Herdr, Inc. joined YC F26 and raised a $6M seed on 2026-09-08.
  ([repo](https://github.com/herdrdev/herdr),
  [compare](https://herdr.dev/compare/),
  [seed](https://herdr.dev/blog/herdr-raised-a-seed/))
- No other open-source tool combines a headless server that owns agent PTYs,
  semantic agent status, a socket API with an event stream, headless Linux over
  SSH and an OSI license. Nearest: Paseo (19.1k, structured sessions, no PTY,
  ships its own app), Orca (82k, Electron, headless needs Xvfb), cmux (27.5k,
  macOS GUI, no semantic status).

## Why add tmux

Risks of staying herdr-only:

- Pre-1.0 churn: eight "Breaking Changes" sections in six months. `agent.send`
  was replaced by `agent.prompt` (0.8.0) and `pane.graphics.*` was removed
  (0.9.2). ([CHANGELOG](https://github.com/herdrdev/herdr/blob/HEAD/CHANGELOG.md))
- Status is screen-manifest based. Codex can stay `unknown`, and blocked/idle
  misreads are open ([#3871](https://github.com/herdrdev/herdr/issues/3871),
  [#803](https://github.com/herdrdev/herdr/issues/803),
  [#1217](https://github.com/herdrdev/herdr/issues/1217)).
- Bus factor: one founder plus bots write most commits; unsolicited PRs are
  auto-closed (CONTRIBUTING.md).
- First-party competition: Herdr Cloud (account relay, E2E terminal traffic,
  no SSH setup) and "more clients coming".
  ([connecting the machines](https://herdr.dev/blog/connecting-the-machines/),
  [cloud](https://herdr.dev/cloud/))
- Crowded niche: at least eight herdr mobile clients (Heeler, herdrup, Whip,
  Sherpr, Herdr Mobile, herdr-mobile, Moshi, Redock) plus 20+ web/PWA clients.
  Moshi has 549 US App Store ratings; Heeler has 4.

Where the remaining audience is:

- tmux has 49.6k stars and decades of installed base. Phone-agent guides use
  tmux as the persistence layer, and Anthropic's Remote Control docs tell SSH
  users to run inside tmux/screen.
  ([Remote Control](https://code.claude.com/docs/en/remote-control),
  [Redock survey](https://redock.dev/blog/best-mobile-terminal-apps-ai-coding-2026/))
- tmux is the substrate of claude-squad (8.6k), Agent of Empires (3.3k),
  workmux (2.7k), dmux (1.8k) and agent-deck (1k). One backend serves all of
  their users.

## Competitors that already speak tmux

| App | tmux story | Notes |
| --- | --- | --- |
| [Moshi](https://getmoshi.app/) (iOS, proprietary) | tmux, Zellij, herdr. Status and approvals need the `moshi-hook` host daemon, which keeps a WebSocket to Moshi's server ([hooks](https://getmoshi.app/docs/hooks)) | App Store name "Moshi: herdr/tmux on SSH/MOSH" (iTunes data, `app-store-submission-readiness-2026-09-28.md` §7.4); 4.7 from 549 US ratings; Pro $9.99/mo |
| [Muxly](https://muxly.sh/) (iOS) | tmux control mode; windows as native tabs | Notifications stop at encrypted terminal bells |
| [Redock](https://redock.dev/) (iOS) | Claude/Codex/OpenCode persisted in tmux, herdr or psmux | Chat view, usage reminders |
| [Collie](https://github.com/AltanS/collie) (PWA, MIT, 1.1k stars) | herdr, tmux, Zellij | Runs on your own server |
| [ServerCC](https://servercc.app/blog/tmux-ios-persistent-claude-code), [Hermit](https://github.com/gotoplanb/Hermit), Secure ShellFish | tmux-based sessions | Agent awareness thin or unverified |

Opening: no native iOS client found pairs tmux over plain SSH (no vendor daemon
or relay in the control path) with agent status, a libghostty attach and E2E
push. Against Moshi in particular, Waycar's angle is open source plus no vendor
server.

## Technical approach (hypotheses)

- **Inventory and events.** tmux control mode (`tmux -C`) over one SSH exec
  channel. `list-sessions` / `list-windows` / `list-panes` with `-F` formats
  build the snapshot; notifications such as `%output`, `%window-add`,
  `%window-close`, `%layout-change`, `%session-changed` and `%exit` give the
  delta stream that the Console's snapshot-then-delta design expects. No host
  daemon. ([control mode](https://github.com/tmux/tmux/wiki/Control-Mode))
- **Mapping.** tmux session to Workspace, window to Tab, pane to Pane. Agent
  kind from `#{pane_current_command}` plus hook signals; plain shells stay the
  `shell` kind (ADR 0018).
- **Agent status, the hard part.** tmux has no semantic state. Candidates, in
  rough order:
  1. Agent hooks write state where control mode can see it, such as a pane user
     option (`set -p @waycar_status blocked`). Sources: Claude Code hooks
     (Notification `permission_prompt` / `idle_prompt`, Stop, ...;
     [hooks](https://code.claude.com/docs/en/hooks)) and Codex's notify hook.
     workmux already writes hook-driven working/question/done into tmux window
     names, and tmux-agent-sidebar keeps hook-driven per-pane status; read
     those conventions too.
  2. Screen heuristics over `capture-pane`, reporting `unknown` when unsure.
  3. Optional enrichment when present: Agent of Empires `aoe serve`
     ([API](https://www.agent-of-empires.com/docs/api/)) or agent-deck web
     (HTTP + WebSocket, running/waiting/idle) through an SSH direct-tcpip tunnel
     to loopback.
- **Attach.** `tmux attach -t <target>` on the PTY exec channel into libghostty.
  `-d` detaches other clients, the closest analogue to herdr's `--takeover`.
  Check window-size behaviour with several clients attached.
- **Prompt and keys.** `send-keys -l` for literal text, then `Enter`; or
  `load-buffer` + `paste-buffer -p` for bracketed paste of long drafts.
- **Worktrees.** tmux has none: `git worktree add`, then `new-window -c <path>`
  or a new session, over SSH exec.
- **Notifications.** Without a plugin system, the trigger moves to agent hooks
  (or tmux `alert-bell`, OSC 9/99/777) calling a small host script that posts
  the existing E2E relay payload. Relay and crypto stay unchanged.
- **Pairing.** Today a herdr plugin action prints the Pairing Code (ADR 0007).
  tmux hosts need another way to print the same code, such as a standalone
  host command from `waycar.dev/install.sh`. The manual-key fallback already
  exists.

## Waycar code map (static read at 47c3fbf8)

- Seam: `protocol Transport: Sendable` in
  `Sources/Waycar/Transport/Transport.swift` ("UI code talks to Transport,
  never to SSH primitives (ADR 0011)"). Conformers: `WaycarSSHTransport`
  (production), `DemoScreenshotTransport`, and the test doubles `FakeTransport`
  and `ScriptedTransport`.
- herdr-specific: `WaycarSSHTransport.swift` (NDJSON plumbing, method names,
  attach and mosh command construction, `minimumProtocolVersion`),
  `HerdrWire.swift`, `HerdrEvents.swift` (subscribable event kinds, synthetic
  `local.events_dropped`), `HerdrHostPath.swift`, `SSHTransportSettings.swift`
  (`herdr agent attach`, `herdr terminal attach`, `herdr remote-client-bridge`,
  `herdr plugin list --json`), `Pairing/SSHPairingConnector.swift`, `plugin/`.
- Backend-agnostic: `Packages/WaycarSSH`, `Packages/GhosttyTerminal`,
  `Packages/SwiftMosh`, terminal render and input, Composer, Dictation,
  Snippets, Skills, SFTP attachments, `relay/`, iCloud sync, AI Usage, Live
  Activities.
- Contract a tmux conformer must cover (about 30 methods): handshake, session
  list, agent list, agent kinds, session snapshot, pane and agent read, prompt,
  send keys, send input, start agent or shell (in a workspace, new worktree or
  new workspace), close / move / focus / rename, worktree list and remove,
  event subscription, terminal attach, mosh bootstrap.
- Hardest, because they bypass `Transport` today: pairing (ADR 0007) and
  notifications (ADR 0008).
- Naming: UI-facing types carry herdr names (`HerdrEvent`, `HerdrSession`,
  ...). Decide between generalizing them and mapping tmux into them.

## Promotion guardrails

- herdr first everywhere: onboarding default, hero line, screenshots.
- tmux second but visible: "works with herdr and tmux" style copy in README and
  README-zh, waycar.dev, App Store metadata and onboarding.
- Publish the per-backend capability table and say plainly what tmux lacks
  (status quality depends on hooks).
- "herdr" belongs to Herdr, Inc.; keep the "not affiliated" language.

## Validation (2026-09-30)

Checked against tmux 3.7c (Homebrew) on private `-L` servers, locally and
over `ssh -T localhost`, plus live hook runs of Claude Code 2.1.286 and Codex
0.159.2. Details and consequences: `docs/design/tmux-backend.md` §1.

| Hypothesis above | Verdict | Correction |
| --- | --- | --- |
| Control mode over one SSH exec channel | Holds | Works without a PTY (`-C`; `-CC` needs a tty). The client must stay attached to a session: it cannot idle unattached or come up when no session exists |
| `%window-add`, `%layout-change` and friends give the delta stream | Partial | No per-pane add or close notification exists, and pane changes in other sessions are silent. A session-scope `refresh-client -B` subscription looping `#{S:#{W:#{P:…}}}` sees them (one push per change, 0.3–1.15 s). `%output` must be off (`attach -f no-output`) |
| Agent kind from `#{pane_current_command}` | Partial | claude reports its version (`2.1.286`); codex and omp report their names. Titles are no status signal: Claude's showed no spinner while working, and Codex's spun while idle |
| Hooks write `set -p @waycar_status` | Holds | Hook processes inherit `TMUX` and `TMUX_PANE`; the option reaches the right server and pane and is pushed through the subscription |
| workmux writes status into window names | Partial | It also sets pane option `@workmux_pane_status`; tmux-agent-sidebar uses `@pane_status` and `@pane_session_id` |
| `attach -d` is the analogue of herdr's `--takeover` | Holds, not used | `-d` makes the desk client exit. The plan attaches through a private grouped session, created detached and pointed at the target window before `attach`; an attached `new-session -t` would first shrink the desk's current window. The window the phone shows follows the client that typed last; the active pane and zoom are window-wide |
| `send-keys -l`, or `load-buffer` plus `paste-buffer -p` | Partial | `load-buffer -` fails over control mode and prints an unframed error line, so drafts use `set-buffer` with `\n` escapes (a leading `~` must be escaped too; 1 MB drafts arrived intact). `paste-buffer` turns LF into CR unless `-r`, and brackets the paste only if the app enabled bracketed paste. A bare `;` argument is a command separator |
| Bell or OSC notifications | Partial | Control mode has no bell notification; an `alert-bell` hook fires, scoped to the window |
| A standalone pairing command from install.sh | Holds | The pairing and crypto modules in `plugin/` have no herdr dependency; install.sh still exits when herdr is missing |
| Version floor (not stated above) | Added | 3.2 for subscriptions, pause, `attach -f`, `new-session -e` and `display-popup`; `no-detach-on-destroy` needs 3.6; EL8 (2.7) is below the floor |
| Hook-driven status (not stated above) | Added | herdr took claude and codex status from hooks in 0.3.0–0.6.6, then moved to screen detection in 0.6.7: hooks miss Esc interrupts, trust dialogs and Codex plan questions |

Two claims above need narrowing. QuickTUI ("tmux/herdr for Claude & Codex",
QR pairing), AgentPanes and Multiplex also speak tmux, so the opening rests on
agent status and end-to-end encrypted push with no vendor server, not on tmux
alone. And Waycar could not claim "open source" then: the repository was
private, and Mike decided on 2026-09-30 that it stays closed source (since reversed).
