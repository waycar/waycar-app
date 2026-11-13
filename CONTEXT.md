# Waycar

A native iOS agent console for herdr, with tmux, Zellij, herdr-core, Ultimate, Codex and OpenCode as further Backends. One context: the app. Terms owned by herdr keep herdr's meaning; this glossary pins how we use them client-side.

## Language

**Host**:
A remote machine reachable over SSH that runs herdr, herdr-core, tmux, Zellij, Ultimate, Codex, OpenCode, or a mix (see Backend). The unit a user adds, names, and authenticates against. A Host with several shows one Console list: Agents from the Herdr TUI, herdr-core, tmux, Ultimate, Codex and OpenCode together, with independent visibility controls for the terminal Backends, Codex and OpenCode.
_Avoid_: server, machine, connection

**Find Computers**:
The local-network search for computers with SSH on, offered before the first Host and from Hosts. Opening it (**Scan** on the first-run card, or **Find Computers**) browses Bonjour immediately. **Check Every Address** is a separate tap that tries port 22 on private Wi-Fi addresses, capped to the /24 around the phone. It discovers no Backends and adds no Host until the user signs in.
_Avoid_: backend detection, automatic scan (the network sweep requires a tap)

**Found Computer**:
A computer listed by Find Computers, not yet a saved Host. Bonjour names identify one row even across several interfaces; Waycar prefers the address on the phone's subnet. An SSH banner found by a sweep enriches that row, but says nothing about the Backends available after sign-in.
_Avoid_: discovered Host (it is not a Host until saved)

**Sample Host**:
A labelled, read-only virtual Host offered while the real catalog is empty and readable. It shows fictional agents offline in a separate Console, never enters the real Host or enabled-Host lists, and is never saved or synced. Sample use does not count as an active Host. Adding any real Host, including a Disabled Host, removes the offer. "Connect your machine" returns to real setup with the install command and its Copy and Share actions.
_Avoid_: live demo, connected computer, demo mode (the screenshot mode is separate)

**Disabled Host**:
A Host the user has switched off. Its configuration and per-Host saved state (cached inventories, Closed Sessions, unread marks, preferences) are kept, but Waycar never contacts it: no connection, preflight, or Backend detection, and the Console does not show it. Its Notification Registration is left in place, so the Agent Notifications it sends still arrive; while the app runs, its Live Activities end. Turning it back on resumes it as an app launch would. Whether a Host is enabled syncs with iCloud Sync, kept apart from the Host's own record; a change made on another device applies here at this device's next iCloud Sync pass, so until then (right after a launch, say) the Host may still be contacted.
_Avoid_: paused (a Paused connection is a suspended one), archived, inactive, offline

**Backend**:
The program a Host's Agents run in: herdr, herdr-core, tmux, Zellij, Ultimate, Codex or OpenCode, detected on each connection, not stored as a Host setting. A Host may run both herdr runtimes alongside tmux. The Herdr TUI (the original `herdr`) and herdr-core (`herdr-core`, ADR 0031 amendment) never share agents, but their separate inventories appear together. Host-level roles use an internal TUI-first lead, falling back to core when TUI is absent or hidden; runtime-specific operations stay on their owning Backend. Host settings contain only runtime visibility toggles, no runtime or launch-default setting. Independent visibility controls hide each runtime without hiding the others. Core visibility also controls `notify.json`'s `core_enabled`; hiding TUI does not silence herdr-owned notifications. New Agent offers one runtime picker for new-Workspace launches when multiple Backends are present, in UI order Herdr TUI, Herdr Core, tmux, Codex, OpenCode, and remembers the choice per Host; existing Workspaces keep their own Backend. herdr comes first: richest features, default onboarding. herdr-core is a full Backend for the Console, Attach, the Composer, Close and New Agent; it builds Workspaces and Tabs from its terminals, takes Agent Status only from agents that report it to herdr-core, and has no Take Over. New Agent on it asks for a kind and a folder: Waycar checks the folder, then runs the kind's program with `terminal.run`, sending the Host's login PATH as `env.PATH` (a running core keeps the PATH it started with), and holds the first prompt until the agent reports its status or shows its input. Worktrees, new Workspaces, plain shells, renames, Host Tools surfaces (Chat Mode included) and mosh are not available on it yet. On tmux Waycar speaks control mode (`tmux -C`) and reads Agent Status from Status Hooks; differences from herdr exist only where tmux forces them.

Zellij 0.46 or later is a terminal Backend, after tmux in runtime order. Sessions become Workspaces, tabs become Tabs, and visible terminal panes become Console rows. Status comes first from the Agent's own report, then fresh Host Tools hook documents, then screen detection. Visibility defaults on; hiding it also silences its Host Tools notifications. Waycar learns about changes from a loop it runs on the Host over one SSH exec, which prints Zellij's sessions and panes only when they change. Opening an Agent attaches a new Zellij client and moves only that client to the Agent's tab and pane; the desk keeps its tab and size, and when the desk moves instead (it typed in the same instant) Waycar puts it back and shows the whole session. New Agent opens a tab in a session that has a client attached, otherwise a new background session; the Launch Tag rides the pane's command line. A Zellij Closed Session is a saved (`EXITED`) Zellij session: Resume, the user's tap, attaches and so resurrects it; Delete asks first. Workspace rename, Move to Workspace, worktrees, Chat Mode and Summaries are not available on Zellij. Hook counters are not timestamps; the Watch only uses Zellij report timestamps that are epoch milliseconds.

Codex is a chat-first Backend over the Host's shared Codex server, reached through SSH direct-streamlocal. Codex 0.167.0 or later is required; an older CLI says **Update Codex to use it here**. Only loaded top-level threads are Agents, grouped by folder, with **Show Codex threads** on by default per Host. New Agent › Codex starts a named thread in a folder with an optional first message; its Chat Mode toggle applies the Chat Prompt, Codex model and Quick thinking from Settings. On a Host with a visible terminal Backend it also opens `codex resume <thread>` in a new Workspace (Herdr TUI, then Herdr Core, then tmux); otherwise it is chat-only. The thread owns the card, and its linked terminal is hidden from the list and opens through Show Terminal. Desk terminals are linked by their `codex resume <id>` command line or a unique terminal/thread pair in one folder; without a sure match both cards can show. Codex launched through a terminal Backend keeps `--no-daemon` and stays outside the shared server. Host Tools 2.4.0 sends needs-your-OK and Done pushes with the reply, without changing the installed hook commands; `codex_enabled: false` in `notify.json` silences them. Live Activities and Apple Watch include the threads.

OpenCode is a chat-first Backend over the Host's shared OpenCode 2 server, reached through SSH direct-tcpip; it shares Codex's server-chat layer. OpenCode 2.2 or later is required; an older OpenCode 2 says **Update OpenCode to use it here**, and OpenCode 1 stays a terminal agent. Every unarchived top-level session is an Agent, whoever started it, grouped by folder, with **Show OpenCode sessions** on by default per Host. New Agent › OpenCode creates a named session in a folder under an id Waycar mints once, so a retried launch never duplicates, with an optional first message; its Chat Mode toggle applies the Chat Prompt and OpenCode model from Settings. On a Host with a visible terminal Backend it also opens `opencode --session <id>` in a new Workspace; an OpenCode 2 launch through a terminal Backend joins the shared server the same way. The session owns the card; its linked terminal is hidden and opens through Show Terminal. Desk terminals are linked by `opencode --session <id>` in their command line or a unique terminal/desk-session pair in one folder. Archive (the swipe and the Agent menu) archives the session on the Host; Closed Sessions lists archived sessions and Resume unarchives one. Host Tools 2.5.0 sends needs-your-OK, question and Done pushes with the reply; `opencode_enabled: false` in `notify.json` silences them. Live Activities and Apple Watch include the sessions.

Ultimate is a chat-only Backend: running project instances are discovered from their project-home locks and verified over loopback HTTP through SSH direct-tcpip. A project instance becomes a Workspace led by the @ultimate card (label `agent`, title `@ultimate`), marked lead and pinned before that project's other cards. Other standing Agents (label `agent`, no parent or owning task) keep their own top-level cards named `@<name>`. Without a named @ultimate, the lowest-id conversation with no parent and no branch source is the fallback lead. Non-concluded branches stay folded inside the lead card until Show is tapped; each opens its own Chat Mode conversation. Subagents and the internal lander are hidden. The lead footer and Live Activity row show branch and working counts, plus needs-you counts from open user questions on the root board. An expanded branch with an open question renders a Blocked label, but its activity status stays Working or Idle so replies still use native Chat Mode. Agent Status is Working while its conversation is busy, Idle otherwise. The Composer submits messages to that conversation; Chat Mode reads stored prompts, final replies and first-line turn errors, not intermediate tool narration. Ultimate has no Attach, New Agent, Close, renames, Host Tools dependency or push notifications in this integration.
_Avoid_: server type, engine, mode

**Codex server**:
The Host's shared Codex app-server, which runs threads independently of the phone. Detection starts nothing. Host detail says **Codex server running** or **Codex server not running**; **Start Codex server** appears there and in New Agent › Codex, never as a Console banner. A start runs in the logged-in session on a Mac so commands keep Keychain access. A server started elsewhere appears on the next connection or return to Waycar. SSH local forwarding must be allowed (`AllowTcpForwarding local` or `yes`). Desk Codex sessions started before the server stay on their own until restarted.
_Avoid_: daemon (in UI copy), Codex Host

**OpenCode server**:
The Host's shared OpenCode 2 background server, which owns every OpenCode session and runs turns independently of the phone. OpenCode's own clients start it, so it is usually running. Detection starts nothing. Host detail says **OpenCode server running** or **OpenCode server not running**; **Start OpenCode server** appears there and in New Agent › OpenCode, never as a Console banner, and runs in the logged-in session on a Mac. Waycar reads its password from the Host over SSH and keeps it only in memory. SSH local forwarding to its port must be allowed (`AllowTcpForwarding local` or `yes`).
_Avoid_: daemon, service (in UI copy)

**Status Hooks**:
Waycar's hooks in the agent CLIs (Claude Code, Codex, omp, pi, opencode, Copilot, Qwen, Gemini, Grok, Antigravity, Hermes, Kilo, Cline, Cursor, Devin, Kiro, Muse) that report Agent Status on tmux by writing `@waycar_*` options on the agent's tmux pane, and start a Waycar notification on Blocked or Done. Installed with the Host Tools by the same install command; only Codex's one-time `/hooks` review stays manual. They act only inside a tmux pane whose tty is the agent's, and never inside the Herdr TUI. They also run inside herdr-core terminals and start the notification there, but the app takes herdr-core's Agent Status only from what the agent reports to herdr-core. In a Zellij pane they write a small state document per pane in `~/.local/state/waycar/zellij/` instead, and only when the agent's process ancestry reaches that pane with the agent's tty; an agent's own OSC 7501 report still wins there. Where an agent has no hook for an event (Blocked for agy and cline), tmux and Zellij fall back to reading the screen.
_Avoid_: Waycar hooks, herdr hooks, integrations (that's herdr's)

**Sign-in Screen**:
The login screen an agent CLI (cursor, devin, kiro, agy, muse) shows until the user signs in on the Host. herdr reports it idle and ready, but typing into it starts or aborts the sign-in, so Waycar refuses to send a prompt while one is on screen ("Sign in to … on the Host first.") and never retries.
_Avoid_: login prompt, auth wall

**Host Tools**:
The `waycar` command the plugin package installs on a Host (`~/.local/bin/waycar`): Pairing (`waycar pair`), the Status Hooks (`waycar hooks`), Agent Notifications on tmux (`waycar notify`), Agent Summaries and a status report the app reads. A tmux Host's equivalent of the herdr plugin's actions; the same package serves both. On a herdr-core Host the install works and the hooks run, but the app does not show or use these surfaces for it yet.
_Avoid_: CLI, daemon, agent

**Plugin Version**:
The version of the Waycar plugin package installed on a Host (herdr plugin and Host Tools alike; `version` in `plugin/herdr-plugin.toml` and `plugin/Cargo.toml`, with `Cargo.lock`). Every change to what the package ships bumps it, so one version names one set of files. The app reads it on connect from herdr's plugin list or the Host Tools package.
_Avoid_: Host Tools version, herdr version

**Minimum Plugin Version**:
The oldest Plugin Version this app build relies on (`WaycarPluginRequirement.minimumVersion`). Raised in the same change as any app feature that needs newer plugin behavior, never above the plugin in the repo. A Host below it is out of date: the app prompts there (Console row, agent card, Chat Mode, Host detail) and offers a Plugin Update.
_Avoid_: required version, compatibility level

**Current Plugin Version**:
The Plugin Version this app build ships beside (`WaycarPluginRequirement.currentVersion`, always equal to `plugin/herdr-plugin.toml`). A Host at or above its Minimum Plugin Version but below this one is not out of date: Host detail shows "<version> available" with the Plugin Update, and nothing else prompts or gates.
_Avoid_: latest version, recommended version

**Plugin Update**:
The one-tap "Update Waycar on this Host" flow: after the user consents, the app runs the official install command on an out-of-date Host over SSH (optionally without refreshing the Status Hooks), shows its progress and result, then re-reads the Plugin Version and reconnects. Updates an installed plugin only; a Host without the plugin keeps the copy-the-command install.
_Avoid_: upgrade, auto-update, reinstall

**Backend Install**:
The "Install Herdr TUI", "Install tmux" and "Install herdr-core" flow for a Host with no usable Backend (`BackendInstallCenter`): after the user consents, the app runs the Herdr TUI's own installer from herdr.dev or herdr-core's from releases.herdr.dev (as the account, files in `~/.local/bin`) or the Host's package manager (`sudo -n`, never a password; no sudo for root or Homebrew) over SSH, and streams its output. A preflight read on opening the panel decides which buttons exist (`HostInstallPreflight`). It is found only when a fresh Backend detection finds the tool (for herdr-core, at or above its version floor), never because the installer exited 0 (ADR 0023); a tmux below 3.2 is a failure, not a success. A failure is one of a fixed list (`BackendInstallFailure`), not a log line. One run per Host, owned by the app, so hiding the sheet neither cancels it nor loses its outcome. After a Herdr TUI or herdr-core install the app starts that runtime once, since neither installer starts one (Start Herdr TUI / Start Herdr Core). Not a Plugin Update: that installs Waycar's own plugin.
On iOS the panel (`BackendInstallPanelStore`) shows on New Agent, with Default Shell unavailable and Start off, and from the Console banner's sheet, for a Host last detected with neither herdr runtime nor a tmux at 3.2 or later (`HostBackendGap`), offering Install Herdr TUI, Install tmux and Install herdr-core in that order with none recommended. Consent is asked for every run, Retry and Install Herdr TUI instead included. Hide, or a swipe down, leaves a run going. Check Again asks the Host with no install, and starts nothing.
_Avoid_: setup, provisioning, auto-install

**Start Herdr TUI** / **Start Herdr Core**:
The one way Waycar starts a Host's stopped herdr server or herdr-core: a button on the Host's Console row and its Host page, offered when that runtime is installed but not running (for Herdr TUI also when its socket cannot be opened, a stale socket left by a crash). It runs the runtime's start once (on a Mac with a logged-in user, in that login session, so Agents keep the Keychain), shows its progress, then reconnects; a failure shows the runtime's own error text. Waycar never starts herdr, herdr-core or any other Host service on its own (#389); the only other start is Backend Install's, right after the user taps Install Herdr TUI or Install herdr-core. A named herdr session (or socket path) whose folder does not exist is never started, since herdr would create it: it reads as a session that doesn't exist.
_Avoid_: wake (the start exec's internal name), auto-start

**Jump Host**:
An SSH endpoint that forwards a Host connection when the Host is not directly
reachable from the device. The Host's address and port are resolved from the
Jump Host, normally through a loopback-only reverse tunnel. The app authenticates
and verifies host keys independently at both hops.
_Avoid_: bastion, proxy server

**Device Key**:
The SSH identity: an Ed25519 keypair generated on a device. The private key never leaves the Keychain, which with iCloud Sync on includes the user's iCloud Keychain, so the user's devices share one canonical Device Key; the public half is what a Host authorizes.
_Avoid_: app key, client key

**RSA Key**:
The alternative SSH identity for a Host that requires RSA-SHA2-512:
one 3072-bit RSA keypair generated on a device and shared by every Host
configured for this method. Its private half stays in the Keychain, which with
iCloud Sync on includes the user's iCloud Keychain, so the user's devices share
one canonical RSA Key. The user registers its OpenSSH public-key line wherever
each Host accepts SSH identities.
Rotating it requires updating every such Host, including both machines when a
Jump Host is configured.
_Avoid_: gateway key, provider key, legacy RSA

**Pairing**:
The full new-device ceremony: scan a Pairing Code, connect with its Bootstrap Key, complete Enrollment, then reconnect with the Device Key. Success produces a working Host, persisted only at that point.
_Avoid_: scan to connect, binding

**Pairing Code**:
The versioned pairing payload (candidate addresses, host key fingerprint, Bootstrap Key, expiry) produced by the pairing plugin. The QR image is just its rendering.
_Avoid_: QR code, invite

**Bootstrap Key**:
A single-use, TTL-bound Ed25519 keypair carried inside a Pairing Code. Its authorized_keys line is restricted to a forced command that can only perform Enrollment; it is destroyed on success or expiry.
_Avoid_: temp key, one-time password

**Enrollment**:
The server-side step of Pairing: the forced command appends the Device Key's public key to authorized_keys. Distinct from Pairing as a whole — failure copy must say which step failed.
_Avoid_: install key, authorization

**Agent**:
The primary object of the app. On terminal Backends, a coding agent process (claude, codex, ...) running inside a herdr pane, as reported by herdr's detection, a herdr-core terminal, or a tmux pane, as reported by its Status Hooks or the pane's foreground process. A Codex Agent is a loaded top-level Codex server thread, addressed as `codex:<threadId>`, and always opens in Chat Mode. It reports Working, Blocked (approval or answer needed), Done or Idle. Send starts or steers a turn; Stop interrupts it. Command and file-change approvals show a **Needs your OK** card with Allow and Cancel; questions show **Needs your answer**. An approval answered at the desk disappears. Answers require a live connection and never become Queued Answers. A known terminal pane showing the same thread is hidden from the merged Console, not from its backend's inventory: the thread is the Agent, and its Show Terminal opens that pane, with Show Chat returning. Links come from Waycar's launch marker, an explicit daemon-mode resume command, or an unambiguous same-folder CLI thread and Codex pane; otherwise both cards stay visible. Linked panes never become Closed Sessions; the thread's unload does, with its thread id as its session. An Ultimate Agent is a conversation, not a terminal process, and always opens in Chat Mode. Its @ultimate lead and other standing Agents have top-level cards; branches are folded under the lead. Needs-you counts come from open user questions on the root board, and a branch awaiting a reply displays a Blocked label without changing its native message-delivery path. The Console also projects each plain shell Pane as an Agent of kind `shell` (see Shell), so everything said of Agent rows and Agent detail applies to shells unless it names Agent Status or an Agent-only herdr call.
_Avoid_: bot, task, session

**Staged Image**:
A user-selected image that exists on a Host at a remote path, whether or not the Agent has accepted it into a prompt.
_Avoid_: attachment, uploaded image

**Staged File**:
A user-selected file that exists on a Host at a remote path, whether or not the Agent has used it from a prompt.
_Avoid_: attachment, uploaded file

**Image Attachment**:
A Staged Image that the Agent has accepted into its current prompt as image input.
_Avoid_: staged image, image path

**Add**:
The Composer action that prepares one or more selected images or files and
creates Staged Images or Staged Files. Each shows in the Composer Tray until
Send appends its Host path after the draft text; on a Shell the path is
inserted at the caret instead. Add never submits. The action does not assert that the Agent accepted an Image
Attachment or used a Staged File.
_Avoid_: attach image, send image, upload image

**Composer Tray**:
The row of chips above the Composer draft holding the images and files added
to this draft. They upload one at a time, and Add accepts at most 10 items per message
(Edit Draft can bring back a failed send's items even beyond that); each chip
shows its progress, failure, or readiness. Removing a chip never deletes the
Host file.
_Avoid_: attachment bar, attachments

**Agent Status**:
herdr's detected state of an Agent, or on tmux the state its Status Hooks wrote: Idle, Working, Blocked, Done, or Unknown. Blocked means the agent is waiting for human input and drives sort order and notifications. A tmux Agent without hooks (not installed, or Codex's not yet reviewed) is Unknown.
_Avoid_: agent state, activity

**Pane**:
herdr's unit of terminal real estate, or a tmux pane (id `tmux:%N`). A Pane hosts either an Agent or an
ordinary shell — a workspace's root pane starts as a shell. Used as an address
(`pane_id`), never as a layout concept in this app.
_Avoid_: window, tile

**Workspace**:
herdr's unit that groups tabs and panes around one working directory. New
Agent can start in an existing Workspace, a new Worktree of one, or a new
Workspace opened at a remote directory — or land a Default Shell in them:
the sheet's plain-shell choice, which creates the same fresh tab without
starting an agent on it. The id is an opaque string. On tmux a Workspace is a
tmux session, and each Agent or Shell gets its own window.
_Avoid_: project, folder, window

**Worktree**:
A fresh git checkout of a workspace's repository, created by herdr as its own
workspace so a new Agent starts on a clean copy of the code. When the Branch
field is empty, Waycar names the branch itself in herdr's format
(`worktree/<adjective>-<noun>-<hex>`), so a retry can recognise the worktree
its launch made and continue in it instead of making a second one. With
Start From Latest Main on (the default, remembered per device) Waycar asks
`origin` for its latest main (origin's default branch, whatever its name) and
starts the branch from that commit; with it off, the branch starts from the
Base the user typed, or HEAD of the workspace's checkout. A branch that
already exists is checked out as-is, whichever start is chosen; a typed
branch that is already open in a Worktree is reused: its running Agent
opens, or the new Agent or shell starts in a new tab there.
Removing the Worktree deletes the checkout and closes its workspace, but the
branch survives. Snapshot worktree metadata also describes the main
checkout; only `is_linked_worktree` makes a workspace eligible for
linked-Worktree removal.
_Avoid_: sandbox, branch copy, checkout folder

**Console**:
The native dashboard surface: Agents across Hosts as cards sorted Blocked, Done, Working, Idle, scoped by a Host menu and a Workspace menu in the Console's bottom bar (with New Agent, Hosts and Settings), and filtered by Status pills (All, Chat = Chat Mode Agents whatever their status, Needs Attention = Blocked or Done, Blocked, Done, Working, and the Closed chip, an exclusive filter listing only Closed Sessions), plus the Agent detail screen. A Chat Mode Agent's card, and a closed one's, wears a chat badge on its kind glyph. A repository's linked-worktree Agents count under its main-checkout Workspace. Its cards include Shells: plain shell Panes (such as Default Shell launches) listed as ordinary Agent cards under the same Host and Workspace scope, search, Pins, moves and row actions, sorted in the bottom status bucket and shown only under the All Status pill. Closed Sessions list in their own Closed section, newest first, under the same Host and Workspace scope: the Closed chip after the Status pills is an exclusive filter like a pill, showing only Closed Sessions and no Agent (tapping it again returns to All); every other pill hides them, and a search always matches them, listed after every Agent card, whatever the pill. Scoping is independent of Agent ordering and Pin priority.
_Avoid_: dashboard, home

**AI Usage**:
How much of each AI provider account's rate-limit windows (session, weekly,
and provider-specific) is left, as reported by the CodexBar CLI on a Host.
It belongs to the accounts, not to a Host: one report is shown, read from
the Host the Console is scoped to when it has CodexBar and AI Usage is on,
else from the first connected Host that does. Shown as remaining
percentage, never as used. A Host is on by default unless another Host
already is, since each extra Host asks the same accounts again; the user
may turn on more. **Pace** is CodexBar's estimate of whether the window's
quota lasts until it resets: in reserve when usage runs slower than the
window elapses, in deficit — with how much longer it will last — when it
does not.
_Avoid_: quota, credits, cost (CodexBar's separate spend panels)

**Keychain Fix**:
What AI Usage offers when CodexBar on a Host cannot read a provider over SSH
because the Host's login keychain belongs to its GUI session (Claude's
browser cookies, for one). After the user confirms, Waycar opens the New
Agent sheet titled Fix AI Usage, locked to that Host, with a first message
asking the Agent to install a `codexbar serve` LaunchAgent in the GUI
session, which AI Usage then reads first. When that server gives up on a
provider ("usage timed out"), the same fix asks the Agent to update its
LaunchAgent with a longer request timeout. It is the same kind of prefilled
sheet as Ask an Agent. Nothing starts until the user taps Start. Waycar
changes nothing on the Host itself; the Agent explains the plan and asks
before it does.
_Avoid_: keychain unlock, auto-fix

**Ask an Agent**:
A help page's action that opens the New Agent sheet titled Ask an Agent,
with the Host still editable and the page attached as the first message in
a Launch Prompt File. Only agent kinds that take a first message are
offered; there is no Default Shell or Chat Mode, and the sheet leaves its
Last Used choices unchanged. Nothing starts until the user taps Start; the
Agent reads the page, then asks what the user wants to do.
_Avoid_: chat about this page, help bot

**Agent Row Layout**:
The ordered rows of fields that identify an Agent in the Console. Each Host follows its herdr plugin's fields until the user saves
that Host's own layout, which may start from a Sync from plugin copy. There
is no user-facing default layout. The Console shows at most three rows, as
three fixed Row Slots, and every Agent on a Host shares them: herdr's
per-kind `rows_by_agent` overrides are decoded but never applied. herdr's
`state_icon` never appears as a field; the status badge at the end of Row 1
owns it. Agent Status and Waycar Pin remain independent chrome; choosing
status as a field repeats it in the row.
On tmux Hosts the rows use Waycar's built-in layout; the plugin's layout and
Sync from plugin cover herdr rows only.
_Avoid_: card template, sidebar format

**Row Slot**:
One of the three fixed positions in an Agent Row Layout. Row 1 and Row 2 are
herdr rows: they start from herdr's sidebar fields and are what Sync from
plugin refills. Row 3 is Waycar's row, which Sync fills only when herdr
defines a third row. Every slot accepts herdr fields and the Waycar-only
fields herdr does not define (Host name, Agent Status as text, working
directory). Slots are never added, moved, or deleted; an empty slot renders
nothing.
_Avoid_: extra row, custom row

**Pin**:
A user-chosen Console marker on a row's pane slot (`hostID` + `paneID`), Agent or Shell.
Pinned agents float to the top of the Console list and the Live Activity
by recency. Pins persist locally and are never pruned, so a pane id that
returns after a herdr restart stays pinned.
_Avoid_: favorite, star, bookmark

**Unread Mark**:
A user-chosen Console marker (Mark as Unread, on a row's menu or the Agent
screen's More menu, which then returns to the Console index) on an Idle Agent's row
(`hostID` + `paneID`) that lists it as Done in the Console — badge, Status
pills and sort — because herdr derives Done as idle and not yet seen and
cannot reset seen. It is Waycar-local and device-local: it never reaches
herdr, `agent.focus`, Agent Notifications or Live Activities, which keep
Agent Status. Opening the Agent, Mark as Read, herdr reporting any status but
Idle for it, or a verified snapshot without its pane clears it.
_Avoid_: unseen, flag, badge

**Selection Mode**:
The Console state, entered from an Agent card's Select menu item, where cards
carry checkboxes and the bottom bar becomes bulk actions (Pin, Mark
Read/Unread, Move to Workspace, Close) over the checked Agents. A selection
may span Hosts; Move needs every checked Agent on one Host. Close schedules
each Agent's own pending tab close, so each row keeps its own undo.
_Avoid_: edit mode, bulk mode

**Composer**:
The local input control below the Agent's live terminal: a native draft field
that composes a message entirely on device and delivers it in one piece. Its
tools keyboard sends explicit keys, including characters on its Terminal
page, directly to the Agent without editing the draft, and so do the Keys and
Combos on the Toolbar. Its Snippet and Skill tools, and a Toolbar text item
(Paste, a Snippet, a Custom Key's text) tapped while it is open, insert into
that draft. Message Agent (💬 on the Toolbar) opens and closes the Composer
card, with the text field focused when 💬 opens it. Its own fixed row is `+`,
More, …, the mic and Send. A draft insertion edits the draft and
nothing more; delivery is a separate, explicit act: Send, or a Custom Key
that presses Enter after its text, which is delivered the way Send delivers
the draft.
Authored delivery is one `agent.prompt` request, except when Agent Status is
Blocked: Send then inserts the draft into Attach without Enter, and the tools
keyboard submits or cancels. On a Shell, Send is one `pane.send_input`
carrying the draft and Enter, because herdr refuses `agent.prompt` on an
ordinary shell; there is no Agent Status, Blocked insert or launch wait.
Delivered means the Host accepted the text into
the pane — whether the Agent queues or acts on it is the Agent's business,
and the Composer never claims otherwise. A delivery that fails on a dropped
link after its request was written is never resent automatically, since
herdr may already have run it; the user resends deliberately. One that fails
before anything left the phone becomes a Queued Message instead.
Composer is the authored-input path on Agent detail while Message Agent is
open, for Agents and Shells alike. With it closed, the terminal takes local
input (taps, Paste, Snippets, text Custom Keys) straight into Attach. Raising
the terminal keyboard (⌨, Direct Input) closes the Composer card without
clearing or submitting the draft.
_Avoid_: reply bar, compose bar (the shelved predecessors), input box, message box

**Queued Answer**:
An Allow, Deny or Cancel on a Blocked Agent prompt, taken while the Host
could not be reached to read the screen, kept in memory on the phone
(never on disk) for up to 10 minutes. Unlike a Queued Message it
replays only under the same guard as a live answer: the screen is read
again and the keys go out only while it still shows the prompt the user
answered (and, for a car Allow, still classifies the same way); a changed
prompt drops it with a notification. One per Agent; the newest replaces
the older. Chat's Blocked card and CarPlay queue; the Watch reports the
failure, and raw terminal keys are input, not answers (mosh may still
retransmit them briefly). Codex Backend approvals and questions require a
live connection and never queue.

**Queued Message**:
An Agent Composer message waiting on the phone because its Host could not
take it: sent while the Host was not connected, or failed before its request
was written (no connection, no channel). Ambiguous failures, where the
request went out and the answer was lost, are never queued; they fail with
Retry. A Queued Message keeps its text, its Composer Tray items (unready ones
copied onto the phone and uploaded before the prompt), the Agent it was sent
to (`agent_session`, else pane and Agent kind) and when it was sent. It is
saved on the phone per Host and Agent, survives the app being closed, and
goes out on its own, oldest first and one at a time, each time the Host is
connected and its rows verified; failures that left nothing on the Host retry
with backoff while Waycar is in the foreground, and never expire. If a
different Agent now runs in its pane, or none does (checked again right
before the prompt, after the uploads), or none was listed when it was sent,
it is **held**: only the user sends it anyway, edits it or deletes it.
Removing a Host, or changing its address or user, deletes its Queued
Messages. Shell rows never queue. A launch's first message for an Agent
kind with no first-message flag (GitHub Copilot CLI, for one), and the
first message typed in New Agent with its images and files, for any kind,
are queued too, for the Agent the launch started: they go out once that
Agent takes input, before anything sent after them, and for the launch's
first 45 seconds a pane that lists no identified Agent yet is waited out,
not held.
_Avoid_: outbox, pending message, offline message

**Queued Launch**:
A New Agent Start taken while its Host had no verified connection. Nothing
goes to the Host: the launch waits on the phone as the user set it up
(Host, Workspace or new directory, runtime, Agent, name, Arguments, Chat
Mode, and the first message with its images and files), saved per Host so
it survives the app being closed. It starts on its own, oldest first and
one at a time, each time the Host is connected and its rows verified, the
way Start would start it then: an empty Agent name gets a default not taken
on the Host when kept or first tried, pinned for every later try along with
its worktree branch. A Workspace with no directory opens in the Host's home.
Its first message and any follow-up messages, with their images and files,
wait in its own Composer's queue on the phone. Once its Agent
starts, those Queued Messages follow in order, first message first.
A launch that failed before anything reached the Host waits for the next
connection. One Waycar closed, or whose answer the connection lost, in the
middle of starting waits too: reconnect checks its Launch Tag, uses the
Agent it made, or starts what is missing, with nothing to confirm. Other
failures wait for the user's Retry or Delete.
Removing a Host, or changing its address or user, deletes its Queued
Launches, and one in the middle of starting goes no further. The Agent
picker meanwhile offers the Agent kinds the Host's last detection found.
_Avoid_: pending launch, offline launch, deferred start

**Launch Tag**:
The stable id a New Agent launch carries to the Host, so reconnect can find
what an earlier try created instead of starting a duplicate Agent. Every try
keeps the same tag, resolved name and worktree branch; on herdr, the name
avoids existing Agent names and tab labels on the Host.

**Saved Conversation**:
An Agent's transcript as this device last read it from the Host's plugin
reader (`readChatTranscript`), kept on the device per Agent launch (pane,
terminal, Chat Marker launch) and the Agent's identity (herdr keeps pane and
terminal ids when an Agent is replaced in the same pane or resumed under a
new session: a chat's identity is its launch, any other Agent's is its
reported `agent_session`; a copy saved for another is never shown or merged,
and an Agent with no session has no copy until one is reported), newest 300
messages within about 2 MB, with
the time it was last read or confirmed current. The terminal screen reads
it for every Agent the user opens, and the Console prefetches the eight most
recently finished Agents (Done or Idle, one read at a time, only in the
foreground with their rows verified and their Host's markers settled, each
Agent at most every 10 minutes). One merge rule serves every writer (Chat
Mode's list and the terminal's reads): a list starting inside the copy never
makes it smaller, and one sharing no message with it (`/clear`, a new
session in the same terminal) replaces it unless the reader truncated. While
a terminal cannot be read live (detached, Host unavailable, stalled, a
device with no network, or plainly connecting for 8 seconds on a device that
has one) and a copy exists, the terminal shows an
offline card (what is wrong: You're offline only for a device with no
network per the app's network path monitor; Read saved copy; the copy's age) and the connection dot's popover offers Read saved
conversation; either opens the Offline Reader over the terminal, a
scrollable snapshot of the copy under the Agent's Composer, so a reply
queues as a Queued Message. A reply to a Blocked Agent is refused while its
Host is out of reach, not queued, because it types into the terminal. The
copy is text (no tool output or screen), exists only for Agents seen while
online, and needs the Host's plugin reader.
_Avoid_: offline transcript, history cache

**Dictation**:
Speaking into the Composer draft. A tap on the Composer's microphone starts
listening at once; speech is transcribed on device by the system's own
SpeechAnalyzer models (iOS 26+, hidden before). The draft stays untouched while
listening; everything heard lands at the caret in one insertion when the
session ends, so typing meanwhile is kept. In the Composer, like every draft
insertion, it never sends: stop keeps the text, Send waits for the last words
and then delivers as usual. From the Toolbar's 🎤 (Dictate to Agent), which
shows a red circle with a stop square while recording, stop sends the text to
the Agent as its own message, leaving the draft, the Composer and the
keyboard alone; leaving the screen, a covering
sheet, or backgrounding discards it. A Blocked Agent, or a session the system
interrupts, puts the text into the draft and opens the Composer for review
instead. Agents only; a Shell's commands stay typed.
_Avoid_: voice input, speech mode, hold-to-talk (the removed predecessor)

**Car Voice Turn**:
One exchange with an Agent from CarPlay (ADR 0028), started only by the
driver tapping "Talk to Waycar" or an Agent row. A question is read back and
goes out on an explicit Send, with the Spoken Reply Suffix, and the Agent's
answer is spoken, at most two sentences. A Blocked claude or codex Agent's
plain-Yes command approval may be allowed or denied by voice; anything risky,
not readable in full, or not a plain approval is held or only read out.
Unsent text goes to the Composer draft. The car screen never shows what was
said or what the Agent wrote.
_Avoid_: car chat, voice mode

**Spoken Reply Suffix**:
The fixed instruction appended to every prompt sent from the car, asking the
Agent for two short sentences without code or markdown
(`CarVoiceScript.spokenReplyInstruction`).

**Watch App**:
The Waycar companion app on a paired Apple Watch (ADR 0029). It never opens
SSH: it shows the Watch State and sends every read and action to the iPhone
app as a Watch Message, so it needs the iPhone nearby. Lists Agents in
CarPlay order, shows an Agent's Latest, records Watch Voice Messages, and
answers Blocked prompts by CarPlay's rules (Allow only for a plain, lossless,
non-risky approval). Silent: it never speaks.
_Avoid_: watch client, wrist app, standalone watch app

**Watch State**:
What the iPhone publishes to the Watch App through WatchConnectivity
application context: Hosts with their condition (confirmed, connecting,
unreachable), Agent rows (title, status, status age, Host name, Chat Mode),
and whether the iPhone can transcribe voice. Never carries Latest text or
Blocked commands. The watch keeps the last one and shows its age when the
iPhone is unreachable.
_Avoid_: watch cache, watch sync, watch model

**Watch Message**:
One request from the Watch App to the iPhone (refresh, read Latest, read a
Blocked prompt, Allow or Deny, send text, send voice), carrying a message id
the iPhone dedupes. The iPhone acknowledges receipt before any SSH work, and
the outcome (sent, not sent, unknown, kept as draft, no words) follows keyed
by that id. Never retried on its own; Try again reuses the id and only
follows a definite not-sent.
_Avoid_: watch command, watch RPC, watch event

**Watch Voice Message**:
A message spoken on the watch with Waycar's recorder: no live text, stopped
by a tap, a double tap, or 3.5 s of silence after speech (8 s with no speech
cancels; 60 s cap). The audio goes to the iPhone, is transcribed there with
SpeechAnalyzer, sent at once without the Spoken Reply Suffix, and deleted on
both devices. When the iPhone is below iOS 26 the watch uses system text
input instead.
_Avoid_: watch dictation, voice reply, voice memo

**Latest**:
The text the Watch App shows on an Agent's detail, always in full (the watch
never truncates; the Digital Crown scrolls): the Agent's last reply whenever
the iPhone can read its transcript (a Chat Mode Agent, or a supported kind
with a live agent session), else its Agent Summary. A Working Agent with a
fresh Summary shows the Summary first, then the reply under "LAST REPLY". A
reply over the 48 KB WatchConnectivity reply budget keeps its end after "Earlier text is on
your iPhone." Fetched from the iPhone on demand, never stored on the watch;
a stale Summary is dimmed with "Checking…" while the iPhone refreshes it.
_Avoid_: preview, last message, watch summary

**Chat Mode**:
A New Agent toggle for claude, codex, omp, pi, opencode, copilot, qwen, gemini,
grok, agy, hermes, kilo, cline and muse, chosen at launch: the Agent
starts with the Chat Prompt injected, and its Agent detail shows the Chat view
instead of the live terminal: a greeting bubble that opens every chat (a local
line, the same for a given chat, never sent to the Agent or read from its
transcript), the user's prompts, the Agent's final reply of
each turn (read by the herdr plugin from the harness's own transcript, never
from the screen) with the images it opened during that turn and any image or
video the reply names, a live status line, and a Blocked card with Allow, Cancel and
Show Terminal. A Chat Marker file on the Host records it, so every device and
the plugin know; a Done push from a Chat Mode Agent carries its reply (or the
harness's error when the turn ended without one) instead of an Agent Summary.
The marker follows its chat Agent's terminal and session, so a chat herdr
restores in a new terminal stays a chat; it is retired when the Agent closes. On terminal Backends only Agents launched in Chat Mode
are chats. Ultimate conversations and Codex threads always use Chat Mode,
without a Chat Marker or Host Tools staging: no Add action. Codex reads prompts,
final replies and failures from its server transcript and presents structured
approvals and question cards; Send starts or steers a turn, and Stop interrupts
it. Its New Agent Chat Mode toggle controls the Chat Prompt and the Codex model
and Quick thinking from Settings, not whether the thread opens as a chat. A plain launch of claude, pi, copilot, qwen or grok pins a fresh
`--session-id` too (unless the user's Arguments pick a session or open with a
subcommand) and writes a marker with `chat_mode: false` that records only that
pin, so its Closed Session resumes that exact session on herdr, which reports
none without its own integration.
The device keeps a copy of each chat's messages, so a chat opens with
them before the Host answers. Attach does not start until Show
Terminal, which swaps this Agent's detail to its terminal and back; it is
distinct from Open Terminal, which opens a Shell. See ADR 0025.
Settings › Chat Mode also sets the model per harness and Quick thinking (on by
default), which adds a low-effort flag at launch: claude `--effort low`, codex
`-c model_reasoning_effort="low"`, omp `--thinking=low`, pi `--thinking low`,
copilot `--reasoning-effort low`, agy `--effort low`, grok `--effort low`,
hermes `--reasoning low`, cline `--thinking low` and muse
`--reasoning-effort low` (opencode, kilo, gemini and qwen have no
reasoning-effort flag, so Quick thinking sends them nothing; opencode and kilo
models are `provider/model`, and their prompt rides the Waycar plugin rather
than a launch flag). The user's own Arguments win over both. It also
holds the New Chat defaults.
_Avoid_: chat view (that's the screen, not the mode), conversation mode, chat agent

**Chat Prompt**:
The instruction text injected at launch into a Chat Mode Agent — through its
harness's launch flag pointing at a Launch Prompt File or carrying the text
inline (qwen, grok, muse), an instructions directory Waycar stages (gemini, agy,
copilot), an environment variable
(hermes), or, for opencode and kilo, through the Waycar plugin reading the
Chat Marker's `prompt` field (they have no system-prompt flag). cline gets none:
its only flag replaces its system prompt. It asks for
short, texting-style final replies. The
built-in default can be overridden in Settings › Chat Mode and syncs through
iCloud Sync. Line breaks and tabs are sent as spaces, because herdr rejects
them in agent arguments; running Agents keep the prompt they started with.
_Avoid_: system prompt, instructions, persona

**Launch Prompt File**:
A private file Waycar writes on the Host just before an Agent launch, holding
the Chat Prompt or the first user message, so the launch passes only the
file's path (a kind with no first-message flag gets the first message as a
Queued Message instead; codex receives a profile name, `-p waycar-<uuid>`, not a
path). herdr types the launch line into the new pane, and a line over the
terminal's 1,024-byte limit hangs the shell; files keep it short. Stage files
live in a per-user private directory (`$TMPDIR` when it is `0700`, else
`$XDG_RUNTIME_DIR`, else `~/.cache/waycar/launch-prompts`). They are never
cleaned up by Waycar, except codex profiles: those older than 10 minutes are
removed by the next codex launch that writes one.
_Avoid_: prompt file, temp prompt

**New Chat**:
The Home Screen quick action (touch and hold the Waycar icon › New Chat) that
starts a brand-new Chat Mode Agent at once. Its Host + Workspace and Agent come
from Settings › Chat Mode's New Chat defaults, each Last Used unless the user
picks one; a picked Host that was removed falls back to Last Used. The Agent
opens in the Chat view with the keyboard up. A Workspace that is gone is
recreated in its saved directory. When the defaults can't be used (no Last
Used yet, Host gone, Agent not installed) or the Host isn't ready within 20
seconds, the sheet opens instead, titled New Chat, with Chat Mode on. With no
Hosts, New Chat only opens the app.
_Avoid_: quick chat, instant chat, shortcut

**Attach**:
The realtime PTY stream behind Agent detail, for an Agent or a Shell. While
Message Agent (the Composer) is open it is display-only: libghostty renders
the complete TUI, owns local scrollback, and reports its grid size so the
remote PTY resizes with the view, while authored input belongs to Composer.
With Message Agent closed the terminal takes local input: a tap sends the
TUI's pointer click, and Paste, Snippets and text Custom Keys type into Attach;
Direct Input lets the system keyboard type that same Attach PTY.
An Agent attaches with `herdr agent attach`; a Shell attaches by terminal id
with `herdr terminal attach`, because `agent attach` refuses a plain pane.
On tmux an Agent or Shell attaches by pane id through a private grouped
session that dies with the Attach, so it never takes the window over or
detaches the desk; the window's size follows whichever client typed last.
An Agent's delivery is one `agent.prompt` request, except when Agent Status is
Blocked, in which case Composer Send inserts the draft into Attach without
Enter and the tools keyboard submits or cancels; a Shell's is one
`pane.send_input` carrying the draft and Enter (see Composer). Only explicit
controls send terminal control sequences: the tools keyboard; the Toolbar's
Keys, Combos and key-step Custom Keys, whether or not the Composer is open;
and Direct Input's system Return.
_Avoid_: takeover (that's herdr's flag, not our surface), connect

**Attach Link**:
An ordinary web URL observed in the terminal during one Agent detail session. It remains
available after scrolling or reconnecting, but is forgotten when the user
leaves the detail; a later session discovers whatever its terminal shows anew.
Attach Links surface in the status row's strip beside the files the terminal
printed, and in that strip's Files & Links list, after the files.
_Avoid_: recent link, visible link, link history

**Terminal Link**:
Link text a tap on the terminal opens: an `http`/`https` URL (opened in the
browser) or a file path on the Host (fetched, bounded, and shown — a **File
Preview**: in Quick Look, or, for a Markdown file of at most 1 MiB, rendered
by the app in its own sheet). Ghostty finds it under the finger, an OSC 8
hyperlink's target before visible text. It opens at once only when its target
is the text on screen; otherwise the user confirms the real address or path
first. A tap in the terminal fetches nothing but the tapped path, and a link in a Markdown File
Preview once the user confirms it. A File Preview opened from the Files &
Links list shows over the list, and closing it returns there. Tapping an
image or PDF there opens a gallery that swipes through the list's images and
PDFs, in list order (never Markdown, never links). A PDF is read only when
opened or swiped to; an image may be read one ahead (the strip already reads
every listed image for its thumbnail). Every local copy is deleted when the
gallery, the list, or the terminal closes.
_Avoid_: hyperlink (that's only the OSC 8 kind), file download

**Shell**:
An ordinary shell Pane as a Console row: an Agent of kind `shell` with no
herdr Agent behind it. It uses the Agent row, Agent detail, Composer and
Direct Input unchanged; the only differences are the herdr calls an Agent-only
API forces — Attach by `terminal attach`, Composer Send by `pane.send_input`,
rename by `tab.rename` (its name is its Tab label). On tmux it attaches by
pane id, renames by its window, and Composer Send is a bracketed paste plus
Enter. It has no Agent Status: its card shows Running and the command while a
foreground command runs (see Shell Activity) and "Shell" otherwise, and it is
excluded from Agent Notifications, Live Activities and status totals. Agent
detail's Open Terminal opens an existing Shell in the Workspace (offering a
choice when there are several) and creates a tab in the Agent's launch
directory only as a fallback or via New Terminal. Shells share the per-Host
limit of five retained terminal connections with Agents; remote panes stay
alive when one is detached. An Agent starting on the Pane replaces its Shell
row under the same id, and an Agent exiting back to its shell becomes the
Shell row again.
_Avoid_: Shell Terminal (the retired separate screen), shell console, terminal
pane view

**Shell Activity**:
What a Shell Pane's foreground is doing: idle, or running a command (shown as
Running plus the command, such as `sudo apt update`). It is shown only on that
Shell's Console card, and is never an Agent Status: it is excluded from Agent
Notifications, Live Activities, CarPlay, sort order, Status pills and status
totals. herdr Hosts poll `pane.process_info` for each Shell every ~3 s while
the phone app is in the foreground; tmux Hosts reuse `pane_current_command` and
the existing `ps` resolution of the tty's foreground process. Unknown reads as
"Shell". Known limits: `ssh`, `tmux attach`, editors and REPLs always read
Running; on tmux a script run through a shell interpreter (`./deploy.sh` with a
bash shebang, `sh -c …`) reads idle, and a command under ~1 s may never show;
on herdr a command under ~3 s may never show.
_Avoid_: shell status, busy status

**Closed Session**:
An Agent that left its Pane — it exited back to its shell, or its Pane or Tab
closed — kept in the Console so the user can resume it. herdr has no closed
state, so the Console records one when a live snapshot no longer runs an
Agent it listed before: no Agent of that kind is left on the terminal it ran
in (a `pane.move` is no closure), or, in the first snapshot after a
reconnect, the one there now reports a different session (it exited and the
same kind started again in the Pane meanwhile). While connected, a different
session is a switch in place (claude's `/clear` or `/resume`), not a closure;
one made while the app was away is recorded as one. A relaunch that has not
reported a session cannot be told from the Agent it replaced.
The rows a reconnect kept, or a cold launch showed from the on-device cache,
count as listed — an Agent gone by the time the Host answers again did close
— but a disconnect or a Host leaving the catalog records nothing, and neither
does an Agent last seen running more than 30 days ago or at an unknown time.
Shells are never recorded, nor kinds New Agent cannot start; an Agent in any
Agent Status, Unknown included, is. The record keeps the Host, Workspace (id
and label), Tab, working directory, Agent kind and name, the last title,
herdr's `agent_session` reference (a session id or file path), remembered
from earlier snapshots because herdr clears it as the Agent leaves (never
across a reconnect, when a relaunch may have replaced the Agent), and when it
was last seen running. Tapping one resumes it: a fresh tab in its Workspace
running the Agent's own resume command for that exact session (herdr's
reference, the `@waycar_session` a tmux Status Hook wrote, or the id the launch
pinned in its Chat Marker), or, when none is known, its own fallback: a picker
for claude, codex, omp, pi and devin; the latest session for grok, hermes, qwen,
copilot, kilo, agy, gemini, kiro and muse; a fresh start for the rest
(opencode, cline and others) — a new Workspace at its directory when
the Workspace is gone — then opens the resumed Agent unless another was opened
meanwhile. herdr lists the launching Agent before it knows which kind it is;
naming it is no closure. While the resumed Agent runs it leaves the Closed
list, but the record stays on this device until the user sends it input from
the app (keys, Paste, a Snippet, the Composer; scrolling, the terminal's own
replies and merely viewing are not input) or moves it: then it is used.
Backing out of it unused (leaving its detail for another or the list) at once
takes its row off the Console and lists the record again as it was, same
closure time, while its Pane closes silently — only an unused resumed Agent
that is Idle or Done is closed; a close that fails brings the
row back and uses the record. Backgrounding or a disconnect is no backing
out, and a relaunch counts a still-pending resume as used. A record with a
session is never forgotten for being used or live again: it is simply not
listed while its session runs on its Host (resumed on any device, or restored
by herdr), each device judging from the rows it lists, and returns when that
Agent closes. Only Forget (swipe), or using the resume of a record without a
session, removes it on every device; a copy last seen running before that
stays removed. A search finds it by the Host's current name. It syncs
through iCloud Sync, and expires 30 days after it closed. A record keeps its
Backend, so a tmux one resumes on tmux. A Codex server thread nobody has open
unloads about a minute after it goes idle and is also recorded, with its thread
id as its session. Resume reopens that thread as a chat and, on a Host with a
terminal Backend, opens a linked `codex resume <thread>` terminal there too.
_Avoid_: history, recent agents, dead agent

**Direct Input**:
The system keyboard typing straight into the live Attach PTY of an Agent or a
Shell, raised and dismissed by ⌨ (Terminal Keyboard) on the Toolbar. Raising
it closes the Composer card; opening the Composer (💬) dismisses it, so the
two never show together. The Toolbar above it holds the user's items (by
default Esc, Tab, Shift-Tab, arrows, Backspace, Shift-Enter, Paste, Enter,
More and Tools keyboard). Its tools keyboard also exposes Snippets (and
Skills, for Agents that have them), inserting their text into the PTY without
adding Enter. The draft stays in `AgentComposerStore` untouched.
Distinct from the tools keyboard swap under the Composer.
_Avoid_: Keys mode, terminal mode, raw input, Attach mode

**Terminal Keyboard**:
The two keyboards below Composer, swapped in place at one shared measured
height. The standard iOS keyboard edits the draft with composition,
autocorrection, dictation, and language switching. The tools keyboard replaces
it with a tabbed pad. Its controls tab pages horizontally between large Agent
controls and a full Terminal keyboard (characters, Ctrl/Alt/Shift, and function
keys), both sending directly to the pane without changing the Composer draft.
Paging and key layers always share the measured iOS keyboard height;
they never resize the dock or the Composer. Skills and Snippets insert into the
Composer draft or directly into Attach in Direct Input, without adding Enter;
appearance changes only the terminal rendering. Direct Input shows only the
full Terminal keyboard in the controls tab, without the Agent page or pager.
It reuses the same measured footprint for an optional tools dock, but its
primary keys persist on the Toolbar rather than replacing the system
keyboard.
_Avoid_: desktop keyboard, reply keyboard, Keys mode (the direct-input predecessor)

**Snippet**:
A phrase the user writes once and reuses, kept in one global set independent of
any Host or Agent. Tapping one, in the tools keyboard or as a Toolbar Item,
inserts its text into the Composer draft, or into Attach in Direct Input,
and nothing more; the user still
delivers it. A Snippet may carry a Title: a short name the user gives it,
shown above its text wherever Snippets are listed.
_Avoid_: macro, template, shortcut (don't call a Snippet one; the Toolbar may
hold a Snippet), quick reply, tip

**Toolbar**:
The one bar at the bottom of Agent detail, the same whether the Composer is
open, the terminal keyboard is up, or neither. Only the Agent Footer sits below it: there
is no Agent chips row, and the user switches Agents with back navigation
(iPhone) or the sidebar (iPad). On the left, the user's Toolbar Items scroll
horizontally with an edge fade. On the right are three fixed buttons that are
not items: 💬 Message Agent (opens or closes the Composer), ⌨ Terminal
Keyboard (raises or dismisses Direct Input) and 🎤 Dictate to Agent (see
Dictation). 💬 and ⌨ exclude each other. Edited in Settings → Toolbar; the
whole Toolbar catalog (layout, spacing and Custom Keys) is kept per device
type (iPhone, iPad), synced through iCloud Sync so a reinstall restores it,
and not shared between iPhone and iPad.
_Avoid_: Shortcut Bar, Agent Bar (the retired two-bar design), accessory bar,
keyboard toolbar, switcher strip, chip row

**Agent Footer**:
Configurable metadata drawn in the empty band below the Toolbar on the
terminal Agent screen (not Chat Mode), as an overlay so the terminal never
resizes. One to three lines, each a set of fields (Agent List Fields plus
branch, model, context, cost, tokens/s, backend, connection) joined " · ",
at a Small, Medium or Large text size. Defaults to one line: Agent name ·
directory. Hidden while a keyboard is up; iPhone landscape shows the first
line only; on iPad it stops short of the system keyboard and mic icons. A
usage figure it shows leaves the usage strip above the terminal. Edited in
Settings → Agent Footer; kept per device type and synced through iCloud Sync.
_Avoid_: status bar, footer bar, info strip

**Message Agent**:
The Toolbar's fixed 💬 button, and its label. It opens the Composer card with
the text field focused; a second tap closes it. The card itself is the Composer.
_Avoid_: compose button, reply button

**Toolbar Item**:
One entry in the Toolbar layout: a Key (a non-character key such as Esc, an
arrow or F1–F12, which applies any armed sticky modifier), a Combo (a key
plus Ctrl, Alt or Shift, sent exactly as shown, ignoring armed modifiers), a
sticky modifier chip, an app action (Paste, More, Tools keyboard, Add Image,
Skills, …), a Snippet (which only inserts) or a Custom Key. Keys, Combos and
key-step Custom Keys go to Attach. Text items go into the draft while the
Composer is open, otherwise into Attach without Enter. An item appears at
most once, and its identity is what it refers to. Items the current Agent
can't use are hidden (Skills on a Shell). Every item can be removed; Close
Agent is never an item.
_Avoid_: button, tile, widget

**Custom Key**:
A Toolbar Item the user builds once in Settings → Toolbar; a new one is added
to the Toolbar unless the user switches off "Add to bar". It is either one to eight key presses, sent like Combos,
or one text with an optional Enter after it. The cap shows its Label, or its
keys or text when it has none. Text without Enter inserts like a Snippet. Text with Enter is
delivered the way Send delivers the draft: one `agent.prompt`, or one
`pane.send_input` on a Shell. While the Agent is Blocked, it inserts without
Enter. Such a key is marked ⏎ and "Sends". Deleting it removes it from the
Toolbar; the library syncs with the layout.
_Avoid_: macro

**Agent Notification**:
A notification telling the user an Agent crossed a notify-worthy status boundary (Blocked, Done): an APNs push while backgrounded or killed, an in-app banner off the live event stream while foregrounded. Deep-links to the Agent's detail surface.
_Avoid_: alert, push message, task notification

**Agent Summary**:
One sentence of at most 100 characters saying what an Agent is doing (Working), where it ended up (Done, Idle), or what it needs from the user (Blocked), written by a cheap model on the Host through the herdr plugin (the Host's Claude, ChatGPT, or OpenRouter access, cheapest first). While the app is in the foreground each connected Host refreshes them about once a minute and on an Agent's status change; the plugin calls the model only for an Agent whose screen changed since its last summary. It is also written when an Agent turns Done or Blocked and rides in that APNs Agent Notification ("Done: fixed 14 missing VoiceOver labels…"); the in-app foreground banner opens with the fixed wording and takes the summary's when the silenced foreground push delivers it. Chat Mode is the exception at Done: a chat Agent's Done push carries its reply instead, no summary is written for that turn, and the hook stores a tombstone that retires the previous summary; the notification and the in-app banner show the reply. The Host keeps the latest one per pane, with the status it was written in; the Console card shows it under the headline, with its age (a clock and "2m") under the status, fresh while the Agent is still in that status and under three minutes old, otherwise dimmed as stale, and a placeholder while an Agent's first one is on its way. On by default: the app's AI Summaries setting is written into each Host's plugin config, and while it is off no card line shows and no screen text leaves the Host. Best-effort: with no model available, a failure, or a timeout, the notification keeps its fixed wording and the card keeps its last summary, or none. The Agent's screen text goes from the Host to that model's provider.
_Avoid_: digest, recap, AI title

**Agent Progress**:
How far a Working Agent is through its current turn: its own plan steps (done of total) when it wrote a plan this turn, read by the plugin from the harness transcript without a model; otherwise a Phase (exploring, implementing, verifying, wrapping up) the Working Agent Summary call also returns, which only moves forward within a turn. It rides on the Agent Summary record (so it needs summaries on), is shown only while the Agent is Working or Blocked (frozen), and is never a percentage or time estimate. Shown as the Console card's edge bar, the Agent Footer's Progress field, a CarPlay ring, and Live Activity rows; while a Live Activity runs, the Host's plan-step tick keeps steps current with the phone locked.
_Avoid_: ETA, percent complete, progress estimate

**Attention Badge**:
The app icon badge: how many Agents need attention (Blocked or Done) summed across every Host, Shells excluded. Each Host contributes its own count from one producer that reads both Backends on a Host with both. While the app holds a Host's connection with a known Agent Inventory, that count is live; otherwise it is the last one known — from the app, or from the Host's latest Agent Notification, which carries its current count. A Host removed from the catalog stops counting, and so does a Disabled Host. Opening a Done Agent lowers it as the Agent turns Idle; there is no separate "seen" mark.
_Avoid_: unread count, notification count

**Push Relay**:
The developer-hosted, stateless forwarder that holds the APNs credentials and relays encrypted notification payloads from Hosts to Apple. It sees device tokens and ciphertext, never content.
_Avoid_: server, backend (that's herdr or tmux), push service

**Notification Key**:
The symmetric key generated on device and stored on a Host during Notification Registration; encrypts Agent Notification content end to end so the Push Relay cannot read it.
_Avoid_: shared secret, push key

**Notification Registration**:
The act of writing the device's push token and Notification Key to a Host over SSH. Per host, repeatable, and independent of Pairing; removing it disables Agent Notifications from that Host. A Host has one registration file whatever its Backends: in the herdr plugin's config directory when the plugin is installed, else in `${XDG_CONFIG_HOME:-~/.config}/waycar`. The app does not register a herdr-core Host yet.
_Avoid_: subscribe, enable push

**Notification Ask**:
The one-time in-app question whether to turn on Agent Notifications and Live Activities. It waits for one Agent session on the install (a window showing one Agent for at least 20 seconds of foreground time), then comes up at a natural break, when the user returns to the Console or Waycar comes back to the foreground on its own (not because a notification, Live Activity, or link was tapped), in a window showing nothing else. There is no session count, so a long-time user who never turned them on is asked too. It returns at later breaks only while unanswered and something is still off. While iOS has never asked for notification permission it is the message before the iOS prompt and offers only Continue, which always leads to that prompt (App Review guideline 5.1.1(iv)); once iOS allows notifications it offers Turn On and Not Now; a refused permission closes it as Not Now. Continue or Turn On does Notification Registration and turns the Live Activity on for every Host on the device, and for Hosts the device gets later; refusing the iOS prompt that Continue leads to ends it like Not Now, and Hosts stay off even if notifications are allowed later. Notifications switched off later in iOS Settings only pause it until they are back. Either answer is final until a reinstall. Device-local, never synced.
_Avoid_: onboarding, permission prompt (that's iOS's own)

**Review Prompt**:
Waycar's occasional request for Apple's system rating sheet (`requestReview`, never a custom dialog). It is eligible after at least 15 value events (a successful New Agent launch, closed-Agent Resume, Composer message to an Agent, or a message the Host accepted through `AgentActionService`: the Apple Watch send, the notification Reply, and CarPlay's spoken questions and Deny-and-instruct) on 3 distinct days, the first 7 or more days ago, at most once per marketing version and 120 days apart, and then comes up when an Agent the phone prompted finishes while the user is on the Console or that Agent, with nothing else showing or waiting on them. The counters reset after each ask, so the next one needs fresh use. Local only, and no reward of any kind (App Review guidelines 3 and 5.6.1). Settings › About › Rate Waycar is a plain link to the App Store review page.
_Avoid_: review ask, rating popup, review reward

**iCloud Sync**:
Syncing Hosts, Host passwords, the Device Key, the RSA Key, trusted host key fingerprints, Closed Sessions and app preferences between the user's devices as synchronizable iCloud Keychain items, end-to-end encrypted. On by default; switched off per device in Settings › iCloud Sync. Eventual, with no "synced" confirmation: the app cannot tell whether iCloud Keychain is on. Notification Keys and Notification Registration never sync.
_Avoid_: backup, cloud account, iCloud Drive, CloudKit

**Transport**:
The app-side abstraction that executes herdr API requests, tmux control-mode commands, or herdr-core's framed `herdr-core connect` stream, and delivers event streams over SSH. A Host with both Backends has one Transport per Backend over one shared SSH connection. UI code talks to Transport, never to SSH primitives.
_Avoid_: client, bridge, tunnel

**Host Connection Status**:
Where one Host's events session stands, as the user is entitled to see it. Five
connection conditions, plus one ownership terminal. Connecting, Reconnecting
and Connected say connection work is under way or done; Suspended and Failed
say none is. Ended is not a connection condition at all: it retires the events
session for good, and belongs to whoever owns that session.
Connecting means a new activation is establishing its first usable events path
— the SSH connection, the herdr ping, the events subscription — outside the
automatic retry loop. Every activation announces it, synchronously, before its
run begins: a first dial, a return from Suspended, and a Reconnect Request from
Connected, Reconnecting or Failed alike. Automatic iterations inside one
activation stay Reconnecting.
Reconnecting is automatic recovery after a retryable failure, and covers its
announced backoff as well as the dial that follows. It is observable only while
that cycle is still the current one. Failed means automatic recovery stopped
because retrying without user intervention cannot repair the failure. It is
observable only while no connection work is running; an explicit retry or
foreground re-proof starts a new Connecting activation and carries the prior
explanation as Standing Failure.
Connected means the session established a usable events path and is maintaining
it on a trusted Transport; a deliberate same-Transport subscription reinstall
stays Connected through its brief stream gap. Suspended means lifecycle
teardown deliberately stopped all connection work until the app is active
again; the Host's SSH connection itself may stay open as a Kept Connection,
but nothing runs on it. A foreground return that finds the connection still
believed live proves it with a ping and stays Connected while that ping is in
flight, so a healthy trip out of the app costs the user no churn.
The status never claims that stopped work is running, and never hides running
work behind a stopped condition. Whatever a surface then chooses to say is a
presentation question, answered by Standing Failure and Transport Error
Presentation.
On a Host with both Backends this is herdr's status while tmux lists no
sessions; otherwise the Host is Connected while either Backend is.
_Avoid_: Agent Status, Reconnect Request, loading, syncing

**Agent Inventory**:
The Agents the Console believes a Host has. It is replaced wholesale when a
snapshot lands, never merged, because herdr replays no state on subscribe.
It is **verified** only by a snapshot taken on the Host's current connection.
A Host Connection Status transition ends that verification without discarding
the rows: they stay on screen, unchanged and unmarked, as the **last-known
inventory** until the next live snapshot replaces them. A cold launch starts
from the last-known inventory kept on the device. A Host with no last-known
inventory has an unknown one, so an empty Console there means unknown rather
than none. A same-Transport subscription reinstall is not such a transition
and keeps the current inventory verified until its refresh lands.
Last-known rows are shown, not trusted: Agent-scoped work (prompt, rename,
close) waits for verification, and the first verified snapshot is a silent
baseline, so moving from last-known to live statuses never announces Blocked
or Done or drives a Live Activity. An Attach does not wait: it starts at once
and, if it fails or ends before verification, waits for it, then attaches
once more if the verified rows still list its pane, or lets its outcome stand
if they do not.
Readiness is a data condition and not a Host Connection Status: a Host is
Connected while its inventory is still unverified. Surfaces say the Agents are
loading there. They must not say the Host is connecting, and must never say a
pane is gone, which is answerable only once the inventory is verified. A Host
with last-known rows says none of this during its **Reconnect Grace** — the
first 10 seconds of an activation or reconnect — unless the user must act.
On a Host with both Backends each keeps its own inventory and verification,
and the Console lists them together.
_Avoid_: agent list, snapshot state, syncing, stale

**Standing Failure**:
The failure that last stopped automatic recovery on a Host, kept after the next
activation begins and discarded only when that activation resolves — by
connecting, by entering automatic recovery, or by failing again, which replaces
it.
It exists so Host Connection Status can report running work honestly without
the app withdrawing the explanation at the moment the user is reading it: a
Host re-proved on a foreground return is Connecting, and every status-derived
surface keeps presenting the Standing Failure until the activation answers,
except that a Reconnect Request may temporarily suppress the Host detail footer
while its button shows request progress. The failure remains stored and
continues to render on Agent detail, the Console, and the Hosts chip, except
that on the Console row a trust hold for the current dial outranks it: that
dial reached the Host and waits on the user.
Only a failure that reached Failed becomes standing. A retryable failure inside
a recovery cycle does not, because nothing stopped and Reconnecting already
says what happened.
_Avoid_: last error, cached failure, sticky error

**Transport Error Presentation**:
What one `TransportError` is allowed to say to the user: a Summary naming what
happened, an optional Detail carrying the error's own interpolated text, and an
optional Recovery Suggestion naming something the user can do about it. It is
total over the error set and is therefore not only about connections — a
rejected herdr request means the connection worked — so it serves failed
one-off requests as readily as a stopped Host.
The Suggestion is optional because most errors do not support one: of the
errors automatic retry accepts, only an unreachable Host does. An API total
over the set may not promise that every case is actionable. Detail is the
error's own words, never authored instruction: a transport's failure string, or
herdr's own code and message.
Which parts a surface shows is decided by whether anything but the user can
change the outcome. A Failed Host shows the whole presentation, and so does a
failed one-off request wherever the surface has no more specific words of its
own, because in both cases nothing changes until the user acts. While
automatic recovery is running, no surface shows the Recovery Suggestion — an
instruction misstates who has to act and invites a restart that discards the
attempt already running — so Reconnecting shows the Summary, and, where the
surface is about one Host's connection health rather than about the Agents, the
Detail with it. Hosts sheet rows are chips rather than prose and sit outside
this term. A first-hop failure is presented against the Jump Host; where no
Jump-Host-directed text exists, the Suggestion is dropped rather than aimed at
the wrong machine.
This replaces Connection Guidance, whose name promised an instruction that the
retryable errors never carried.
_Avoid_: Connection Guidance, error message, connection error, retry hint,
actionable error

**Reconnect Request**:
A user's explicit Reconnect press on Host detail, and the brief window in which
the app shows that press being served. It is feedback about a request, not a
Host Connection Status: it is never derived from the status and never changes
it, an automatic Reconnecting is not a Reconnect Request, and a press in flight
suppresses the Host detail failure footer while driving the button's own
progress (#160).
_Avoid_: retry, reconnecting, manual reconnect state

**Background Grace Period**:
The window after backgrounding during which the app keeps running under an iOS background-execution assertion and holds its Host connections, so a short trip out of the app costs nothing on return. Only when it elapses does the app suspend: it starts a Standby for each live mosh Attach, then ends the events streams and Attaches but keeps each Host's SSH connection as a Kept Connection. Bounded by what iOS grants (tens of seconds); staying reachable for longer is what Agent Notifications are for.
_Avoid_: background mode, keep alive (that's the events session's ping)

**Kept Connection**:
A Host's SSH connection held open across a suspension with nothing running on it. On return the app proves it with a ping under a deadline of a few round trips, while a fresh dial starts beside it once the ping is slow; whichever answers first is used and the other is closed. One kept longer than ten minutes is redialed instead. It saves the dial, not the Attach or the events stream, which always start anew.
_Avoid_: persistent connection, background connection, keep alive

**Standby**:
A mosh-server started for an Agent's Attach before any client uses it, so a later Attach can start the mosh client straight at it with no SSH work. mosh-server runs the Agent's attach only once the client's first datagram arrives and exits a minute after start if none does, so an unused Standby never touches the pane. The app makes one for each live mosh Attach at the end of the Background Grace Period, and keeps one per Host for the last-viewed Agent while the Console is in front. Each serves one Attach within 50 seconds of its start.
_Avoid_: resume, prewarm, reserved session

**Last Frame**:
The image of an Agent's terminal as it last painted, kept on the device for the eight Agents (Shells included) captured most recently, 24 hours at most, and shown under Ignition's Reconnecting veil when the Agent's detail opens before its Attach paints. It is a picture, never terminal text, and is dropped when the Attach ends, the Host is removed or re-targeted, or the pane is gone.
_Avoid_: snapshot (that's herdr's `session.snapshot`), screenshot, cached screen
