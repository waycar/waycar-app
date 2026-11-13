# Ultimate backend

Status: v1 in progress (epic E1, 2026-11-01). Fourth Backend: `HostBackend.ultimate`.

[Ultimate](https://github.com/HazAT/ultimate) is a long-running Node server (web UI over pi-durable) with
durable conversations. It has **no terminal entrypoint**: no PTY attach exists, so this is Waycar's first
chat-only Backend — an Agent card opens Chat Mode directly, there is no Attach.

## 1. Load-bearing Ultimate facts

Verified live against Ultimate d0a2e17b (Node 26, macOS) on 2026-11-01 unless noted; source review of
`server/api.ts`, `server/request-security.ts`, `shared/protocol.ts`, `server/main.ts`.

- U1 The server binds `127.0.0.1` only (`server/main.ts:185`); the supervisor picks the first free port
  from 4747. One process per project; each project home is
  `~/.ultimate/projects/<basename>-<sha256(root) first 8 hex>/`.
- U2 `<home>/ultimate.lock` is JSON `{pid, port, project}` (live). It identifies running instances; verify
  by connecting, never by pid alone.
- U3 Admission (`request-security.ts admit()`): a request whose `Host` header is a loopback authority for
  the server's port, with no (or loopback) `Origin` and no proxy headers, is admitted with no credentials.
  An SSH direct-tcpip forward to the loopback port therefore passes by sending
  `Host: 127.0.0.1:<port>` (verified live: `POST /api/conversations` created id 39 through `ssh -L`).
  There is no token scheme; remote origins need identity rules (Tailscale, proxies) Waycar does not use.
- U4 Extension actions (`POST /api/extensions/...`) additionally require browser-shaped requests
  (`api.ts:128`). v1 does not call them.
- U5 `GET /api/events` is SSE and the only long-lived request. Its `conversations` events carry
  `ConversationSummary[]`: `{id, busy, title?, label?, cwd?, parentConversationId?, branchOf?, inputAt?,
  answerAt?}` (`shared/protocol.ts:45`). Concluded ids are not summary fields: the shared
  `ultimate.ui` document arrives automatically as `ui {value}` followed by Chord `uiOps {ops}`
  on the same stream (`server/api.ts:285+`, source review 2026-11-01). Its
  `ext.conversations.concluded` array hides those conversations and their descendants
  (`extensions/conversations/visible.tsx`). Waycar waits for both initial summaries and UI
  before publishing inventory, and resets the document replica on reconnect.
  Per-conversation view/doc subscriptions are managed by
  `POST/DELETE /api/events/<streamId>/<sub>`; the stream's first event names the streamId.
- U6 `POST /api/conversations/:id/submit` takes `{text, images? (≤4, ≤2 MiB base64), whenBusy?:
  'steer'|'followUp'}` and answers `{submissionId}`; `/inbox/:submissionId/cancel` cancels a queued one;
  `/abort` stops the run (`shared/protocol.ts:17`, `api.ts:581+`).
- U7 `GET /api/conversations/:id/history?before=<exclusive>[&after=]` answers `{entries: EntryRecord[],
  before?}` newest-first, 64 per page (512 with `after`) (`api.ts:450`).
- U8 The API is explicitly unstable (README: changes "without migration paths"). Waycar parses leniently,
  enforces nothing but what the contract check pins, and `PINNED_COMMIT` in
  `scripts/ci/ultimate-contract.py` is the only place the Ultimate commit pin lives.
- U9 Malformed/foreign-origin requests get 403; errors are `{error}` JSON with HTTP status codes
  (`api.ts HttpError`).
- U10 History entries (live sample: `docs/research/ultimate/history-sample.json`, conversation 39,
  claude-haiku-4-5): `{id, kind, conversationId, byTaskId?, model?: [pi message], data?}`. Chat kinds:
  `pi.user` (`model[0].content` is a string), `pi.assistant` (`model[0].content` is an array of text,
  toolCall and thinking parts; `stopReason` is `stop`, `toolUse` or `error`, with `errorMessage` on
  error), `pi.tool-result`. Harness kinds such as `conversations.identity` and `models.fallback` also
  carry a user-role message but are not the user's words; `pi.system` holds the whole system prompt.
  A chat transcript keeps only `pi.user` and each turn's final `pi.assistant` text (`stopReason` stop),
  plus error replies.
- U11 A new conversation inherits the root's model; a provider without a login fails the turn at once
  with `stopReason: error` (`Provider is not configured`, `OAuth refresh failed`) instead of refusing
  the submit. `POST /api/conversations/:id/configure {model: {provider, modelId}, thinkingLevel?}`
  changes it (live).

- U12 Every `/api/events` connection starts with `stream`, `system`, then `conversations` (live,
  d0a2e17b, 2026-11-01; trimmed capture `docs/research/ultimate/system-sample.json`). The system
  event's `project.root` must equal the lock's `project`, and `persistence.path` must be inside
  that instance's project home. Waycar checks both before accepting any summaries, at open and
  every stream reconnect, so a reused port cannot identify another project. `process.pid` names
  the child server, not the supervisor PID in the lock; it is not an identity check.

- U13 Standing Agents have `label: "agent"`, title `"@<name>"`, and no `parentConversationId`,
  `ownerTaskId` or `branchOf`. Only the title `"@ultimate"` names the project lead; the label alone does
  not. An ownerless branch has `branchOf: {conversationId, at}` (source conversation and positive entry
  id), with no parent/owning task. A task-owned subagent has `parentConversationId` and `ownerTaskId`,
  not `branchOf`. `inputAt` and `answerAt` are Unix milliseconds; `answerAt` matches a stored assistant
  message's timestamp. Verified by `branch_summaries` against d0a2e17b, 2026-11-01, using actual standing,
  branch and subagent creation with the local model stand-in.
- U14 The root `board` document lives on conversation **1**, not on the lead's conversation. Subscribe
  with `POST /api/events/<streamId>/0 {conversation: 1, docs: ["board"], view: false}`; `doc` and
  `docOps` each put the numeric subscription id on their first SSE `data:` line, then JSON on the next.
  The snapshot is `{kind: "board", value: {messages: [...], next}}`. A question has numeric `from`
  (the asker), `to: "user"`, `reply: true`, optional `questions`, and `state: "delivered"`. Answering
  changes the original to `"answered"`; dismissing changes it to `"dismissed"`. Both append a message
  from `"user"` to the asker with `re` naming the original; dismissal is a one-way note (`reply: false`).
  These arrive as Chord ops, including string append `a` and front-truncate `t` (UTF-16 code units),
  not just whole-property sets. Verified live by `board_questions` against d0a2e17b, 2026-11-01;
  the `sent|delivered|answered|dismissed|failed|stopped` state union is additionally source-pinned
  (`extensions/messages/refs.ts`). Failed/stopped delivery transitions are not exercised live.

`ui_concluded` additionally verifies automatic `ui`/`uiOps` (U5), actual conclude/resume, and a fresh
stream's current concluded snapshot. There is no explicit `docs: ["ultimate.ui"]` subscription: that
kind is not exposed by the extension-document registry on this pin. Browser-shaped extension actions
only drive these scratch fixtures; they do not bypass U4 in Waycar. All turns use the local stand-in,
with no real model credentials or calls.

## 2. Shape

- **Detection** (`HostBackendDetection`): one exec reads every `~/.ultimate/projects/*/ultimate.lock` plus
  the project name from `project.json`. A candidate is usable only after its port answers with
  an SSE system identity matching that lock's project and home (U12), not merely an HTTP 200. Each running instance becomes an Ultimate *project
  group* in the Console; its leader is the Agent.
- **Transport** (`Sources/Waycar/Transport/Ultimate/`): `UltimateTransport` speaks minimal HTTP/1.1 over
  `SSHByteTransport` channels from `openDirectTCPIP("127.0.0.1", port)`:
  - one long-lived channel per instance for `/api/events`; each retries independently with capped
    backoff. A down instance's inventory is removed and restored when it returns. Only an all-instance
    outage after the first retry fails the stream; the existing reconnect path re-discovers lock files,
  - short-lived channels for one-shot requests (admission class `.ultimate`, bounded concurrency).
  `Connection: close` on one-shots; `Host: 127.0.0.1:<port>`; JSON decoded leniently (unknown fields
  ignored, summaries that fail to decode are skipped individually).
- **Projection**: one leader Agent/Tab/Pane per project instance, keyed
  `ultimate:<home-hash>:<conversation id>`, status from `busy` (working) / idle.
  The leader has neither `parentConversationId` nor `branchOf` (lowest id if multiple
  candidates exist); the standalone lander directory is excluded. Ownerless branches
  are carried separately by `Transport.ultimateConversationChildren()`, keyed by leader
  pane id, with each child's conversation id, pane id, name and busy flag. Concluded
  subtrees and owned subagents are excluded. Child pane ids retain the same scheme
  for native submit/history routing. Generated herdr wire types remain unchanged.
- **Composer**: sends via U6 with `whenBusy: "steer"`; text only in v1.
- **Chat Mode**: a transcript reader over U7 mapping `EntryRecord`s: user text, assistant text/markdown;
  tool calls collapse to one-line summaries; unknown kinds skipped. No `waycar chat-read`, no plugin,
  no Status Hooks.
- **No Attach, no push, no question-card controls** in v1 (cards appear as assistant text). Push and the
  Docker bridge (an installless HTTPS path) are explicit later phases.

## 3. Risks

- API churn (U8): mitigated by the contract check and lenient parsing; a drift fails CI, never the Host.
- SSE over an exec-independent channel: direct-tcpip channels do not consume `MaxSessions` slots, but the
  request queue still bounds total channels.
- Multiple Ultimates per Host are normal (one per project); detection must list all and not assume 4747.
