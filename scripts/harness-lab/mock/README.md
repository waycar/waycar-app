# Harness lab mock model server

`server.js` is a dependency-free Node 22 server and the only "model" harnesses in the lab talk to. It listens on `http://mock:8080` inside the compose network and `http://127.0.0.1:18080` from the Mac. It accepts any key and any model.

| API | Routes (any prefix: `/v1`, `/api/v1`, `/openai/v1`, none, …) |
|---|---|
| OpenAI Chat Completions | `POST …/chat/completions` (SSE with `tool_calls` deltas, usage) |
| OpenAI Responses | `POST …/responses` (SSE `response.created` … `response.completed`) |
| Anthropic Messages | `POST …/messages`, `POST …/messages/count_tokens` |
| Gemini | `POST /v1beta/models/{model}:generateContent`, `:streamGenerateContent` (`?alt=sse` or JSON array), `:countTokens` |
| Model lists | `GET …/models[/{id}]`: OpenAI/Anthropic shape, or Gemini shape for `v1beta` paths and Google-style keys |

## Scripting (last user message)

The mock reads the last user turn. Before reading it, it removes harness wrapper blocks such as `<system-reminder>…</system-reminder>` and unwraps `<user_query>` (Grok) and `<USER_REQUEST>` (Antigravity). Antigravity's notice on a resumed conversation ("The following is a `<SYSTEM_MESSAGE>` not actually sent by the user. …"), a user message after the prompt, is removed whole, so the prompt before it is the one read.

- **default**: after `MOCK_DELAY_MS` (1500), replies `waycar-mock-reply: <WAYCAR_* tokens or last word>`.
- **`WAYCAR_SLOW`**: same reply, after `MOCK_SLOW_MS` (15000).
- **`WAYCAR_HOLD`**: text reply waits for an explicit release instead of a delay. Find its `{id, userAgent, lastUser}` in `GET /_health`'s `holds` array, then `POST /_release {"id":"…"}`. Only that request is released; the response is `{released:true}` (false for an absent/already released hold). Disconnect cancels the hold; a 120 s safety timeout prevents abandoned requests hanging forever. Use this for assertions made while an agent is running.
- **Opening turn** (no assistant message in the request yet, so a launch's first message): at least `MOCK_FIRST_MS` (6000). herdr reports no status until about 3.6 s after a launch (`docs/research/harnesses/herdr-backend.md`, finding 1), so a 1.5 s first turn would finish unseen and read `idle` with no `working`. A real first turn, which reads the staged first-message file, takes longer anyway.
- **`WAYCAR_TOOL`**: makes one call to the request's shell-like tool (name contains bash > shell > terminal > command > exec > run, skipping output/kill/read/write helpers). Arguments come from the tool's JSON schema: command fields get `echo waycar-tool-ok`, given as `["bash","-lc",…]` when the field is an array. Escalation fields are filled whenever the schema offers them: an enum value containing `escalat`, boolean `*escalat*` / `*approv*` set to true, and a `justification` string. With codex 0.162.1 this produces `exec_command {cmd, sandbox_permissions: "require_escalated", justification}`, so codex shows its approval prompt even under `on-request`. Once the tool result arrives, the reply is `waycar-tool-done: saw waycar-tool-ok`.
- **`WAYCAR_TOOL_MUTATE`**: like `WAYCAR_TOOL`, but the command is `touch /tmp/waycar-tool-mutate && echo waycar-tool-ok`. Use it for harnesses that auto-allow read-only commands such as `echo`: gemini, qwen, copilot, and kilo's `echo *` safe list. After the tool result, the reply text is the same.
- **`WAYCAR_ASK`**: calls `question` when offered, with one single-choice “Pick a color” question (header `Color`, Red/warm and Blue/cool). A tool result ends the turn as for shell tools; without `question`, replies with ordinary text.
- **Tool-completion harnesses**: if the request offers `attempt_completion` (Cline/Kilo), text replies are sent inside that call.
- **Bookkeeping** (no user text, tool-less title/summary prompts, `max_tokens` ≤ 32, JSON-schema output, a request whose only tool is a title tool such as grok's `session_title`): the reply is immediate. Schema requests get JSON built from the schema; a title tool is called with arguments built from its schema.

## Request log

- `GET /_log[?since=<epoch ms | ISO time>]` returns JSON lines, oldest first, keeping the last 500. Each record has: `time`, `ts`, `method`, `path`, `userAgent`, `headers` (a subset), `auth` (kind only), `api`, `model`, `stream`, `effort`, `reasoning`, `system`, `lastUser`, `messages`, `tools`, `shellTool` (the picked tool's name and schema), `reply`, `replyText`, `toolCall`.
- Several runs share the log, so filter it with `since` and don't use `DELETE /_log`, which clears it for everyone.
- `GET /_health` is the health check.

## Self-test

`node scripts/harness-lab/mock/selftest.js [base]` (default `http://127.0.0.1:18080`) covers every API in streaming and non-streaming form, a tool round trip for each, the codex escalation arguments, the wrapped-prompt shapes, explicit hold/release for every API and stream format, and the log fields. It reads back only its own log entries.
