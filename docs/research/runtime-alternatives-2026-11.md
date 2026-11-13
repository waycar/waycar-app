# Runtime alternatives to herdr — market scan, Nov 2026

All links checked **2026-11-11** unless marked. The market scan is source and docs review only. Two hands-on probes followed on scratch Docker, after Mike's go: see [Probe results](#probe-results-2026-11-11). Ratings are US App Store (iTunes Lookup API). Downloads are Homebrew 30-day installs or npm last-month downloads, which count installs and CI pulls, not users. GitHub stargazer history is not available through this API, so momentum is shown as stars against age, release cadence and commits in the last 30 days.

## Verdict

- herdr is no longer the only agent runtime, and it now ships its own iOS app ([Herdr, Inc., released 2026-11-06](https://itunes.apple.com/lookup?id=6828898364&country=us), herdr-core only). Waycar's herdr-first lead is shrinking.
- The biggest new openings are **agent-native servers** that now persist sessions on the Host: Codex's shared app-server daemon and OpenCode's V2 background server. Both are reachable over plain SSH with no cloud, and both give real status and approvals. Neither needs a multiplexer.
- **OSC 7501 is becoming the shared status signal.** herdr-core, Zellij 0.46 and TUIOS all read it, and Claude Code and Pi send it. A runtime that reads OSC 7501 gives status without Waycar's hooks.
- Most "agent session managers" (Claude Squad, Agent of Empires, agent-deck, dmux, OpenRig, Emdash on POSIX) run their agents in tmux, so Waycar's tmux Backend largely sees them already.

**Mike's picks (2026-11-11):** all three, in the order Codex, then OpenCode right after, then Zellij. A probe came first; the tmux managers check runs now; Codex agents Waycar starts move into the shared daemon once the Backend exists.

## Top 3 to support next

### 1. Codex app-server (shared daemon): chat Backend, effort M

- **What:** OpenAI's official integration API. The interactive CLI now runs on a "shared background server" by default (`--no-daemon` opts out), and `codex agents` browses every chat on it ([CLI reference](https://developers.openai.com/codex/cli/reference/)). The daemon exists for "Codex instances launched over SSH" and remote clients; its lifecycle commands print one JSON object each ([daemon README](https://github.com/openai/codex/blob/main/codex-rs/app-server-daemon/README.md)).
- **Why:** it is the biggest harness: [96.8M npm/month](https://api.npmjs.org/downloads/point/last-month/@openai/codex), [388k cask installs/30d](https://formulae.brew.sh/api/cask/codex.json) and [134.9k stars](https://github.com/openai/codex), with 0.167.1 shipped 2026-11-10. One daemon holds every Codex session on the Host, including desk sessions outside tmux and herdr. It works on a Host with no multiplexer at all.
- **Surface** ([app-server docs](https://developers.openai.com/codex/app-server/)):
  - transport: JSON-RPC over stdio, or WebSocket on the default **Unix control socket** (`--listen unix://`). TCP WebSocket is "experimental and unsupported".
  - inventory and history: `thread/list` (with runtime status), `thread/read`, `thread/turns/list`.
  - prompts: `turn/start` and `turn/interrupt`.
  - status: `thread/status/changed` with `activeFlags: ["waitingOnApproval"]`, plus approval requests sent by the server (Blocked, answerable natively).
  - session lifetime: a thread unloads only after its last subscriber leaves and a grace period passes, so sessions outlive the phone.
- **Maps onto Waycar:** the Ultimate chat shape (Chat Mode, Composer, question cards) over the herdr Backend's direct-streamlocal channel. Reuse is high.
- **Third-party clients exist:** [Agmente](https://github.com/rebornix/Agmente), [CC Pocket](https://github.com/K9i-0/ccpocket), [codex-android](https://github.com/hebo6/codex-android), and Kittylitter's [SSH bridge](https://github.com/0xSero/litter/blob/main/shared/rust-bridge/codex-mobile-client/src/ssh_bridge.rs).
- **Risks:**
  - The daemon contract "may change" (README).
  - Waycar launches Codex with `--no-daemon` (AGENTS.md, for hook environment reasons), so the agents Waycar starts would not appear in the daemon.
  - A Codex TUI attached to the daemon inside a tmux or herdr pane would show twice unless joined by thread id.
  - Starting the daemon needs the user's tap (memory `no-auto-start-host-services`).
  - Unix socket forwarding needs `AllowTcpForwarding local`, as herdr does.
  - The daemon auto-updates hourly by default and restarts, which interrupts turns.
- **First step (done 2026-11-11, on scratch Docker rather than the harness lab; see [Probe results](#probe-results-2026-11-11)):** a 15-minute probe:
  1. Does `codex app-server daemon version` start anything?
  2. What is the socket path?
  3. Does `thread/list` from a forwarded socket show a desk TUI's thread?
  4. Disconnect mid-turn and mid-approval, then reconnect: are the turn and the pending approval still there?

### 2. Zellij: fourth terminal Backend, effort M

- **What:** the only mainstream multiplexer besides tmux: [36.0k stars, 6 years, 66 commits/30d, MIT](https://github.com/zellij-org/zellij), and [3,629 installs/30d](https://formulae.brew.sh/api/formula/zellij.json). [0.46.0 shipped today](https://github.com/zellij-org/zellij/releases/tag/v0.46.0) with an **attention inbox built on OSC 7501** ([announcement](https://zellij.dev/news/terminal-inbox-session-previews/)).
- **Why:** it reaches users who today cannot use Waycar at all. Competitors already list it: [Moshi](https://getmoshi.app/) ("Herdr, tmux & Zellij"), [Termind](https://github.com/AkinoKaede/Termind) and [Collie](https://github.com/AltanS/collie). Agents that send OSC 7501 get status with no hooks.
- **Surface** ([CLI actions](https://zellij.dev/documentation/cli-actions)):
  - inventory: `list-panes` and `list-tabs` (`--json`), `list-sessions`.
  - screen and input: `dump-screen`, `write-chars` / `paste`.
  - launch and close: `new-pane` / `new-tab` with a cwd and command, `close-pane`.
  - status: `go-to-next-attention`, `mark-pane-seen`.
  - events: `zellij subscribe` streams pane renders only, not topology. A richer event feed needs the plugin API with [pipes](https://zellij.dev/documentation/plugin-pipes).
  - [built-in web client](https://zellij.dev/documentation/web-client).
- **Maps onto Waycar:** like tmux: session to Workspace, tab to Tab, pane to Pane, ids prefixed `zellij:`.
- **Risks:**
  - No push for topology changes, so either polling execs or a Zellij plugin shipped with the Host Tools.
  - `zellij attach` is per session, not per pane: per-client focus and size against the desk are unknown.
  - Zellij has no pane user options, so Waycar's Status Hooks need another store; OSC 7501 covers only agents that send it.
  - Zellij's own web client is a free competitor.
- **First step:** a probe on a scratch Docker host:
  1. Which status and attention fields does `list-panes --json` return for an agent that sends OSC 7501?
  2. Can a PTY `zellij attach` show one pane without moving the desk client's focus or size?
  3. What does one inventory poll cost?

### 3. OpenCode V2 server: chat Backend, effort M (after Codex, same shape)

- **What:** V2 runs one **shared background server** that also powers the TUI and the web UI. It listens on loopback **49374**, is password-protected (HTTP Basic), and documents SSH forwarding ([web.mdx](https://github.com/anomalyco/opencode/blob/main/services/site/src/docs/content/cli/web.mdx)). The [OpenAPI](https://github.com/anomalyco/opencode/blob/main/packages/protocol/openapi.json) has 139 paths: session list, history, prompt, interrupt, permission and form replies (Blocked), `/api/session/active`, and `/api/event` SSE.
- **Why:** huge audience: [226k stars](https://github.com/anomalyco/opencode), [47.4k installs/30d](https://formulae.brew.sh/api/formula/opencode.json) (twice herdr's) and [14.8M npm/month](https://api.npmjs.org/downloads/point/last-month/opencode-ai). Prompts go through the API instead of typing into the TUI, which would replace Waycar's opencode input-box gate (AGENTS.md). The client code for Codex carries over.
- **Risks:**
  - The spec calls itself "Experimental HttpApi", version `0.0.1`.
  - V1 (1.18.34, [2026-09-30](https://github.com/anomalyco/opencode/releases/tag/v1.18.34)) became V2 within weeks, and the [V1 docs](https://opencode.ai/v1/docs/server/) (port 4096, `opencode attach`) are now stale.
  - SSE drops events while disconnected, so every reconnect refetches.
  - The password lives on the Host: where it is stored, and whether Waycar may read it, needs a probe.
- **First step:** pin the API with a contract check, like `scripts/ci/ultimate-contract.py`, once two V2 minor releases keep it stable.

### Quick win, not a Backend: tmux-based managers, effort S

- **Already visible on the default tmux socket:**
  - [Claude Squad](https://github.com/smtg-ai/claude-squad) (8.8k stars; quiet since 2026-08).
  - [Agent of Empires](https://github.com/agent-of-empires/agent-of-empires) (4.1k; [default tmux](https://github.com/agent-of-empires/agent-of-empires/blob/main/src/tmux/mod.rs#L98)).
  - [agent-deck](https://github.com/asheshgoplani/agent-deck) ([default socket](https://github.com/asheshgoplani/agent-deck/blob/main/internal/tmux/tmux.go#L518)).
  - [dmux](https://github.com/standardagents/dmux).
  - [OpenRig](https://github.com/mvschwarz/openrig) (8.8k stars, [23.6k npm/month](https://api.npmjs.org/downloads/point/last-month/@openrig/cli)).
  - [Emdash](https://github.com/generalaction/emdash/blob/main/packages/core/src/services/pty/api/tmux-commands.ts) on POSIX.
  - [amux](https://github.com/mixpeek/amux).
  - [AWS CAO](https://github.com/awslabs/cli-agent-orchestrator).
- **Invisible today:** managers on a private socket, [nodeterm](https://github.com/eneskirca/nodeterm/blob/main/src/core/tmux-naming.ts) (`-L node-terminal`) and [agent-manager](https://github.com/wainmann/agent-manager#usage) (`agentmgr`). Waycar's control command selects no `-L`/`-S` socket (`Sources/Waycar/Transport/Tmux/TmuxTransport.swift`).
- **First step (done 2026-11-11; see [Probe results](#probe-results-2026-11-11)):**
  1. Confirm that sessions from Claude Squad, Agent of Empires and agent-deck appear and that hooks coexist with the managers' own.
  2. Then decide whether to list extra sockets found in `$TMUX_TMPDIR/tmux-$UID/`.

## Watch, not now

| Candidate | Why it matters | Why not now / revisit when |
|---|---|---|
| [TUIOS](https://github.com/Gaurav-Gosain/tuios) (6.5k★, [2,728 installs/30d](https://formulae.brew.sh/api/formula/tuios.json), 2,621 commits/30d) | Serves a [herdr-0.9.5/protocol-22 compatible socket](https://github.com/Gaurav-Gosain/tuios/blob/v0.12.1/docs/AGENT_STATE.md#herdr-compatibility) and reads OSC 7501 and herdr reports | No herdr terminal-attach compat; small. Cheap probe: point the herdr Backend at its socket |
| [cmux](https://github.com/manaflow-ai/cmux) (28.8k★, [4,727 installs/30d](https://formulae.brew.sh/api/cask/cmux.json)) | Mac GUI [socket API](https://cmux.com/docs/api.md); new [`cmux-tui`](https://github.com/manaflow-ai/cmux/tree/main/cmux-tui) runtime with JSONL events, PTY attach and [hooks](https://github.com/manaflow-ai/cmux/blob/main/cmux-tui/docs/agent-hooks.md) | cmux-tui exists only on main ([npm](https://registry.npmjs.org/cmux) 0.13.4, Sep); GUI terminals have no attach. Revisit at a cmux-tui release |
| [Paseo](https://github.com/getpaseo/paseo) (23.8k★, [131.6k npm/month](https://api.npmjs.org/downloads/point/last-month/@getpaseo/cli)) | Persistent daemon for ~30 harnesses on loopback 6767; [SSH access documented, never auto-starts](https://github.com/getpaseo/paseo/blob/main/public-docs/connectivity.md) | Ships its own free mobile apps (direct competitor); beta wire protocol. Revisit if users ask |
| [Happy Agent](https://github.com/slopus/happy-agent) | New local daemon: [HTTP on a Unix socket](https://github.com/slopus/happy-agent/blob/main/packages/happy-agent/API.md), resumable SSE, questions, relay optional | Preview, 39★; Happy's apps cover it |
| ACP ([spec](https://github.com/agentclientprotocol/agent-client-protocol), [registry: 46 agents](https://github.com/agentclientprotocol/registry), [30.5M SDK npm/month](https://api.npmjs.org/downloads/point/last-month/@agentclientprotocol/sdk)) | One protocol for gemini, goose, opencode, kiro, copilot, cursor, cline, kilo, qwen, devin, grok, OMP (plus Claude, Codex and Pi adapters) | [Stable transport is stdio only](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/protocol/v1/transports.mdx); [remote transport is an RFD](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/rfds/streamable-http-websocket-transport.mdx); work dies with the SSH channel. Revisit when a persistent ACP host gets traction |
| [AHP](https://github.com/microsoft/agent-host-protocol) (Microsoft, 1.0 on Oct 2, [712k npm/month](https://api.npmjs.org/downloads/point/last-month/@microsoft/agent-host-protocol)) / [Hydra ACP](https://github.com/smagnuso/hydra-acp) | Host-owned, multi-client, [replay on reconnect](https://github.com/microsoft/agent-host-protocol/blob/main/docs/specification/lifecycle.md); AHP ships a Swift SDK | A protocol, not a runtime users run. Hydra: 49★ |
| [Orca](https://github.com/stablyai/orca) (122k★) / [Agent Orchestrator](https://github.com/OrchestratorInc/agent-orchestrator) (14.4k★) | Own PTY daemons with local sockets/REST, working/waiting/done | Both ship native iOS/Android apps; large app-specific protocols; no tmux |
| [rmux](https://github.com/Helvesec/rmux) (2.7k★) | [Typed daemon SDK](https://github.com/Helvesec/rmux/blob/main/docs/scripting-sdk.md) | 0 commits/30d; no agent classification |
| Claude Code local server | Would be the #2 harness ([52.0M npm/month](https://api.npmjs.org/downloads/point/last-month/@anthropic-ai/claude-code)) | None exists: [Remote Control routes through Anthropic](https://code.claude.com/docs/en/remote-control); an [Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview) host would be a Waycar daemon, and [credential rules](https://code.claude.com/docs/en/legal-and-compliance) are ambiguous. Keep terminal + transcript |

**Reject:**
- **[WezTerm](https://github.com/wezterm/wezterm):** no stable release since 2024-02-03, 2 commits/30d, no PTY attach CLI.
- **[GNU screen](https://man7.org/linux/man-pages/man1/screen.1.html), [abduco](https://github.com/martanne/abduco), [dtach](https://github.com/crigler/dtach):** no topology or status, and 937/18/65 installs/30d.
- **[Vibe Kanban](https://www.vibekanban.com/blog/shutdown):** its company shut down 2026-04-10.
- **[Conductor](https://www.conductor.build/announcement):** joined Meta, no downloads since 2026-11-04.
- **[Crystal](https://github.com/stravu/crystal):** deprecated, now Nimbalyst, which has its own iOS app.
- **[Terragon](https://github.com/terragon-labs/terragon-oss):** shut down.
- **[container-use](https://github.com/dagger/container-use):** an MCP environment tool, last release 2025-08.
- **[AgentAPI](https://github.com/coder/agentapi):** archived.
- **[Paradev](https://github.com/ParadevAI/Paradev/blob/main/apps/docs/content/docs/cli/host-server.mdx)** (ex-Superset): requires sign-in.
- **[Paperclip](https://github.com/paperclipai/paperclip):** a task and organization domain, not sessions.
- **[OpenClaw](https://docs.openclaw.ai/gateway/protocol):** a whole gateway.
- **[Pi RPC](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md) / [OMP RPC](https://github.com/can1357/oh-my-pi/blob/main/docs/rpc.md):** the subprocess owns the session and EOF ends it.
- **[goose serve](https://github.com/aaif-goose/goose/blob/main/crates/goose/src/acp/server.rs):** cancels a run when the connection drops.

## Mobile client landscape

- **First-party apps now control local work:**
  - [Herdr](https://itunes.apple.com/lookup?id=6828898364&country=us) (4 ratings, new, herdr-core).
  - [Claude Remote Control](https://code.claude.com/docs/en/mobile): relayed by Anthropic, Claude only.
  - [ChatGPT/Codex](https://developers.openai.com/codex/remote-connections): relayed, needs the desktop app, which can reach SSH Hosts.
  - Cursor, GitHub Copilot and Kilo native apps, for their cloud agents.
- **Free OSS umbrella apps, each with its own daemon** (chat, approvals, push; relay or direct):
  - [Happy](https://itunes.apple.com/lookup?id=6748571505&country=us): 1,062 ratings, 4.87.
  - [T3 Code](https://itunes.apple.com/lookup?id=6787819824&country=us): 205.
  - [Paseo](https://itunes.apple.com/lookup?id=6758887924&country=us): 113.
  - [Orca](https://itunes.apple.com/lookup?id=6766130217&country=us): 77.
  - [Kittylitter](https://itunes.apple.com/lookup?id=6759521788&country=us): 45, Codex app-server over SSH.
  - [Vicoa](https://itunes.apple.com/lookup?id=6751626168&country=us): 27.
  - [Happier](https://itunes.apple.com/lookup?id=6758554297&country=us): 16; also follows existing sessions, chat and terminal.
- **Terminal-first:**
  - [Moshi](https://itunes.apple.com/lookup?id=6757859949&country=us): 616 ratings, 4.74; [$9.99/mo, $89.99/yr](https://getmoshi.app/pricing). Supports herdr, tmux and **Zellij**, with chat, an inbox, Live Activities and Watch.
  - [Termius](https://itunes.apple.com/lookup?id=549039908&country=us): 19.7k.
  - [ShellFish](https://itunes.apple.com/lookup?id=1336634154&country=us): 1,574; mosh since 2026-10-31, experimental.
  - Also Blink, La Terminal, Prompt 3, and [Termind](https://github.com/AkinoKaede/Termind) (herdr, tmux, Zellij, zmx).
- **herdr clients are crowded:**
  - native: [Heeler](https://itunes.apple.com/lookup?id=6797263135&country=us) (21), herdrup, two Shepherdr apps, HerdrChat, Drover, Corral, Shepherd, Cowboy (mostly 0–3 ratings).
  - web: the PWAs Ovis, Collie and Sheprd.
- **Waycar** ([5 ratings](https://itunes.apple.com/lookup?id=6815881853&country=us)):
  - **Unique together:** native iPhone and iPad, direct SSH and mosh, no account, relay or Waycar daemon, and four runtimes in one list running about 17 harnesses.
  - **Table stakes, not moats:** mosh, push and Live Activities.
  - **Behind on:** ratings, Android, open source (launch prepared), Zellij, and structured approvals for Codex and OpenCode.

## Evidence

### Terminal runtimes and managers

| Name | Stars / age | Last release | Commits 30d | Installs | License | Effort |
|---|---|---|---:|---|---|---|
| [herdr](https://github.com/herdrdev/herdr) (baseline) | 50.2k / 7.5 mo | 0.9.5 · Oct 14 | 40 | [22,276 brew/30d](https://formulae.brew.sh/api/formula/herdr.json) (92.6k/yr) | Apache-2.0 | shipped |
| [tmux](https://github.com/tmux/tmux) (baseline) | 50.3k | 3.8 | — | [60,294 brew/30d](https://formulae.brew.sh/api/formula/tmux.json) | ISC | shipped |
| [Zellij](https://github.com/zellij-org/zellij) | 36.0k / 6.2 y | 0.46.0 · Nov 11 | 66 | [3,629](https://formulae.brew.sh/api/formula/zellij.json) | MIT | M |
| [cmux](https://github.com/manaflow-ai/cmux) | 28.8k / 9.5 mo | 0.65.2.2 · Oct 27 | 1,041 | [4,727 cask](https://formulae.brew.sh/api/cask/cmux.json) | GPL-3 (+BUSL server) | M/L |
| [WezTerm](https://github.com/wezterm/wezterm) | 29.5k / 8.8 y | Feb 2024 | 2 | [1,849 cask](https://formulae.brew.sh/api/cask/wezterm.json) | MIT | L |
| [TUIOS](https://github.com/Gaurav-Gosain/tuios) | 6.5k / 14 mo | 0.12.1 · Oct 31 | 2,621 | [2,728](https://formulae.brew.sh/api/formula/tuios.json) | MIT | S/M |
| [rmux](https://github.com/Helvesec/rmux) | 2.7k / 6 mo | 0.10.0 · Aug 4 | 0 | [3,122 npm SDK](https://api.npmjs.org/downloads/point/last-month/@rmux/sdk) | MIT/Apache | M |
| [Claude Squad](https://github.com/smtg-ai/claude-squad) (tmux) | 8.8k / 20 mo | 1.0.20 · Aug 20 | 0 | [178](https://formulae.brew.sh/api/formula/claude-squad.json) | AGPL-3.0 | works |
| [OpenRig](https://github.com/mvschwarz/openrig) (tmux) | 8.8k / 7 mo | 0.7.11 · Nov 10 | 1,373 | [23,594 npm](https://api.npmjs.org/downloads/point/last-month/@openrig/cli) | Apache-2.0 | works |
| [Agent of Empires](https://github.com/agent-of-empires/agent-of-empires) (tmux) | 4.1k / 10 mo | 1.22.3 · Nov 9 | 511 | — | MIT | works |
| [Emdash](https://github.com/generalaction/emdash) (tmux on POSIX) | 6.2k / 14 mo | 1.2.11 · Nov 6 | 201 | — | Apache-2.0 | S |
| [nodeterm](https://github.com/eneskirca/nodeterm) (private tmux socket) | 2.5k / 5 mo | 0.5.1 · Nov 6 | 530 | [110 cask](https://formulae.brew.sh/api/cask/nodeterm.json) | BUSL-1.1 | S |
| [agent-deck](https://github.com/asheshgoplani/agent-deck) (tmux) | 1.2k / 11 mo | 1.16.38 · Nov 7 | 334 | — | MIT | works |
| [GNU screen](https://ftp.gnu.org/gnu/screen/) | — | 5.0.2 · Jul 11 | — | [937](https://formulae.brew.sh/api/formula/screen.json) | GPL-3 | reject |

### Agent servers and protocols

| Name | Transport over SSH | Sessions outlive the phone | Status / approvals | Monthly downloads | Effort |
|---|---|---|---|---|---|
| [Codex app-server](https://developers.openai.com/codex/app-server/) | Unix-socket WebSocket (streamlocal) or stdio | Yes (shared daemon) | `thread/status/changed`, `waitingOnApproval`, approval requests | [96.8M](https://api.npmjs.org/downloads/point/last-month/@openai/codex) | M |
| [OpenCode V2](https://github.com/anomalyco/opencode/blob/main/packages/protocol/openapi.json) | HTTP + SSE on loopback 49374 (direct-tcpip), Basic auth | Yes (background server) | active sessions, permission and form requests | [14.8M](https://api.npmjs.org/downloads/point/last-month/opencode-ai) | M |
| [Paseo](https://paseo.sh/docs/connectivity) | WebSocket on loopback 6767 | Yes | timeline, permissions | [131.6k](https://api.npmjs.org/downloads/point/last-month/@getpaseo/cli) | M |
| [ACP](https://github.com/agentclientprotocol/agent-client-protocol) | stdio (exec) | No | permission requests | [30.5M SDK](https://api.npmjs.org/downloads/point/last-month/@agentclientprotocol/sdk) | L |
| [acpx](https://github.com/openclaw/acpx) | local IPC | Yes, 300 s idle TTL | owner health only; [denies permissions non-interactively](https://github.com/openclaw/acpx/blob/main/docs/permissions.md) | [2.27M](https://api.npmjs.org/downloads/point/last-month/acpx) | L |
| [Claude Code](https://code.claude.com/docs/en/headless) | `claude -p` stream-json (exec) | No (Remote Control is relayed) | via SDK callbacks | [52.0M](https://api.npmjs.org/downloads/point/last-month/@anthropic-ai/claude-code) | L |
| [Pi](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md) / [OMP](https://github.com/can1357/oh-my-pi/blob/main/docs/rpc.md) RPC | stdio JSONL | No | `agent_settled`, extension dialogs | [21.7M](https://api.npmjs.org/downloads/point/last-month/@earendil-works/pi-coding-agent) / [1.07M](https://api.npmjs.org/downloads/point/last-month/@oh-my-pi/pi-coding-agent) | L |
| [goose serve](https://github.com/aaif-goose/goose/blob/main/documentation/docs/gdk/acp/index.md) | ACP over HTTP/WS on loopback 3284 | No (cancels on drop) | ACP | — | M |

### HN

- herdr: [404](https://news.ycombinator.com/item?id=48756578) and [367](https://news.ycombinator.com/item?id=50298436) points.
- Zellij: [414](https://news.ycombinator.com/item?id=26902430).
- cmux: [198](https://news.ycombinator.com/item?id=47079718).
- rmux: [194](https://news.ycombinator.com/item?id=48219918).
- Agent of Empires: [118](https://news.ycombinator.com/item?id=46588905).
- Reddit was not used.

## Probe results (2026-11-11)

Both probes ran on a scratch Docker host: Ubuntu 24.04 x86_64 containers prefixed `rtprobe-*` (removed afterwards, verified empty), with tmux 3.4, OpenSSH 9.6p1 and the harness lab's mock model (`scripts/harness-lab/mock/server.js`). No real accounts. Each line comes from a command run with its output recorded.

### Codex 0.167.1 shared daemon

1. **Detection starts nothing.** Neither `codex --version` nor `codex app-server daemon version` started a process or created a socket (`ps` and `find -type s`, before and after). With no daemon running, `daemon version` exits 1 with `failed to connect to …/app-server-control.sock` and prints no JSON, so treat exit 1 as "not running".
2. **Socket:** `~/.codex/app-server-control/app-server-control.sock`, mode 777 inside a 700 directory owned by the user. A same-user client connects with no token: a WebSocket upgrade over the Unix socket, then `initialize`.
3. **Lifetime:** `codex app-server daemon start` prints one JSON object (`status`, `pid`, `socketPath`, `appServerVersion`). The daemon (`codex app-server --listen unix:// --managed-daemon`, parent pid 1) outlived the exec that started it, and was still up after 127 s idle. Longer idle exit was not measured.
4. **Desk sessions show up.** A plain `codex` TUI in a tmux pane joined the daemon by default. `thread/list` from another client showed its thread as `active` during the turn and `idle` after. Listing also returns `notLoaded` history, which must be told apart from live threads.
5. **Turns survive a disconnect.** A turn started over the socket (15 s reply), with the client dropped at 3 s and back at 20 s, had completed. `thread/read` and `thread/turns/list` returned the reply. `turn/interrupt` ends a turn with `status: interrupted`.
6. **Approvals survive a disconnect.**
   - What arrives: `thread/status/changed` with `activeFlags: ["waitingOnApproval"]`, then `item/commandExecution/requestApproval` with `availableDecisions`.
   - Recovery: after a drop, the request is replayed once on `thread/resume`; listing alone does not replay it. A new connection answered it.
   - Approvals raised in the TUI reach a subscribed client too. The first answer wins: the TUI's Enter beat a later API `cancel`, and `serverRequest/resolved` tells the other side.
7. **Over SSH like Waycar:** `initialize` and `thread/list` worked through OpenSSH direct-streamlocal (`ssh -L /tmp/c.sock:<socket>`) with `AllowTcpForwarding local` and `AllowStreamLocalForwarding local`, the same as herdr needs.
8. **Hook bleed is still there.** Two TUIs in panes `%3` and `%4` on one daemon (started from `%3`): every SessionStart and Stop hook saw `TMUX_PANE=%3`. So the tmux Status Hooks cannot attribute daemon-run Codex sessions to their pane. `--no-daemon` still exists. (`--dangerously-bypass-hook-trust` silently selects embedded mode.)
9. **Launch via API works.** `thread/start {cwd, approvalPolicy, sandbox}` created a thread in that folder, which then appeared in `codex agents` and `codex resume`.

**Design consequences:**
- **Detection:** `codex --version`, then `codex app-server daemon version`; exit 1 means "Codex server not running". `daemon start` is a user tap.
- **Transport:** reuse herdr's direct-streamlocal.
- **Status:** for daemon sessions, take status from the app-server, not hooks.
- **Approvals:** recover with `thread/resume`; dismiss on `serverRequest/resolved`.
- **Pane ↔ thread join:** decision 4b needs one by construction, either `thread/start` and then `codex resume <id>` in the pane, or ids from the TUI. Hooks cannot supply it.

### tmux-based agent managers

Versions: Claude Squad 1.0.20, Agent of Empires 1.22.3, agent-deck 1.16.38, agent-manager 0.48.1, claude 2.1.322, Waycar Host Tools 2.3.1 (`install.sh --tmux`).

1. **Visible today.** All three use the default tmux server. Session names: `claudesquad_<title>`, `aoe_<title>_<id>`, `agentdeck_<title>_<id>`. The claude panes are listed with their cwd. Agent of Empires wraps claude in `bash /tmp/aoe-pane-env-*`, so `pane_current_command` reads `bash`. Claude Squad moves the agent into its own worktree (`~/.claude-squad/worktrees/…`).
2. **No attach conflict.** None of the managers uses grouped sessions or `destroy-unattached`. A `waycar-*` group created on each session left the manager's list intact and was neither adopted nor killed, and the original panes survived its removal. The phone and desk resize interplay was not exercised.
3. **Status works.** Waycar's hooks went `working` → `done` in all three panes, with `@waycar_agent=claude` and a valid `@waycar_session`.
4. **Hooks coexist, with one Waycar bug.**
   - Claude Squad installs no hooks.
   - Agent of Empires appends its own guarded handlers, and both its hooks and Waycar's fired.
   - agent-deck (`agent-deck hooks install`, opt-in) merges its handlers **into Waycar's hook groups**: all 12 Waycar commands remain and both fire.
   - The bug: `waycar hooks status` then says `claude: out of date`, because `has_exactly` (`plugin/rust/hooks/groups.rs`) compares whole groups. What `waycar hooks install` would do to the merged groups was not tested.
5. **Machine-readable lists:**
   - `agent-deck list --json` gives title, status, tmux session and Claude session id, and starts nothing.
   - `aoe list --json` **starts a daemon** (`aoe serve --daemon-child`), and `aoe --no-autostart list --json` exits 2. Never call it from Waycar (memory `no-auto-start-host-services`).
   - Claude Squad has no list command.
6. **Private socket confirmed:** agent-manager's sessions exist only on `tmux -L agentmgr`, so the default server does not see them.

**Consequences:**
- No new Backend is needed for Claude Squad, Agent of Empires or agent-deck.
- Fix the `hooks status` false positive: a plugin patch, with a version bump.
- Optionally label these sessions by name prefix.
- Private sockets remain a separate, small decision.

## Open questions

1. **Codex:**
   - Which pane ↔ thread join to use for decision 4b.
   - Whether the daemon ever exits when idle.
   - Whether its hourly self-update interrupts a phone-started turn.
2. **Zellij:**
   - Which OSC 7501 status fields appear in `list-panes --json`?
   - Can a per-pane attach avoid disturbing the desk's focus and size?
   - What does polling cost against a plugin bridge?
3. **OpenCode V2:**
   - Where is the server password stored, and is it readable over SSH?
   - Is the server running when only the TUI is?
   - How much does a reconnect refetch cost?
4. **tmux managers:** what `waycar hooks install` does to groups agent-deck has merged into.
