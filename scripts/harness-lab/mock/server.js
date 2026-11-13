'use strict';
// Deterministic mock model server for the Waycar harness lab (issue #172). Dependency-free, Node 22.
// Speaks OpenAI Chat Completions + Responses, Anthropic Messages and Gemini generateContent (streaming
// and not) on any path prefix (/v1, /api/v1, /openai/v1, none, ...). Scripted by the last user message:
//   default     → short text after MOCK_DELAY_MS echoing the prompt's WAYCAR_* tokens (else its last word)
//   WAYCAR_SLOW → same after MOCK_SLOW_MS
//   WAYCAR_HOLD → text reply held until POST /_release {id}, or a 120 s safety timeout.
//   opening turn (no assistant message yet: a launch's first message) → at least MOCK_FIRST_MS, so it outlasts
//                 herdr's ~3.6 s launch settle, before which herdr reports no status (herdr-backend.md)
//   WAYCAR_TOOL → one call to the request's shell-like tool running `echo waycar-tool-ok`; text once the result arrives.
//                 Escalation fields the schema offers are set (codex: sandbox_permissions "require_escalated" +
//                 justification), so sandboxed harnesses ask for approval even under on-request policies.
//   WAYCAR_TOOL_MUTATE → same, but the command writes: `touch /tmp/waycar-tool-mutate && echo waycar-tool-ok`
//   WAYCAR_ASK → calls `question`, when offered, with a single Red/Blue color question.
// Bookkeeping calls (no user text, tool-less title/summary prompts, JSON-schema output) answer immediately.
// GET /_log[?since=<epoch ms | ISO time>] (JSON lines, time >= since) · DELETE /_log
// GET /_health (includes pending holds) · POST /_release {id} (releases only that hold)
const http = require('node:http');

const PORT = Number(process.env.PORT || 8080);
const DELAY_MS = Number(process.env.MOCK_DELAY_MS ?? 1500);
const SLOW_MS = Number(process.env.MOCK_SLOW_MS ?? 15000);
const FIRST_MS = Number(process.env.MOCK_FIRST_MS ?? 6000);
const FEATURES = ['log-since', 'log-ts', 'opening-delay', 'title-tool', 'system-notice', 'hold-release'];
const MODELS = (process.env.MOCK_MODELS || [
  'mock-model', 'gpt-5', 'gpt-5-codex', 'gpt-5-mini', 'gpt-4.1', 'claude-sonnet-4-5', 'claude-opus-4-1', 'claude-haiku-4-5',
  'gemini-2.5-pro', 'gemini-2.5-flash', 'gemini-2.5-flash-lite', 'qwen3-coder-plus', 'grok-code-fast-1',
].join(',')).split(',');
const TOOL_CMD = 'echo waycar-tool-ok';
// WAYCAR_TOOL_MUTATE: a write, for harnesses that auto-allow read-only commands like echo (gemini, qwen, copilot, kilo).
const MUTATE_CMD = 'touch /tmp/waycar-tool-mutate && echo waycar-tool-ok';
const SHELL_WORDS = ['bash', 'shell', 'terminal', 'command', 'exec', 'run']; // preference order
const NOT_SHELL = /output|kill|read|write|stop|status|list|background|agent|task|test/i;
const CMD_KEY = /command|cmd|^(script|code|input)$/i;
// Optional fields that make sandboxed harnesses ask for approval (codex exec_command: sandbox_permissions + justification).
const ESCALATE_KEY = /escalat|sandbox_permissions|justification/i;
const LOG_MAX = 500;
const LOG_HEADERS = ['anthropic-version', 'anthropic-beta', 'openai-beta', 'originator', 'session_id', 'x-goog-api-client', 'x-title', 'http-referer'];

const log = [];
let seq = 0;
const newId = (prefix) => `${prefix}_waycar_${++seq}`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const holds = new Map();
function hold(res, id, userAgent, lastUser) {
  return new Promise((resolve) => {
    const release = () => {
      clearTimeout(timer);
      res.off('close', release);
      holds.delete(id);
      resolve();
    };
    const timer = setTimeout(release, 120000);
    holds.set(id, { id, userAgent, lastUser, release });
    res.once('close', release);
  });
}
const tokens = (s) => Math.max(1, Math.ceil(String(s).length / 4));
const pieces = (s) => s.match(/[\s\S]{1,20}/g) || [''];
const unix = () => Math.floor(Date.now() / 1000);

// ---------- request normalization: { model, stream, system, messages[{role,text}], tools[{name,schema}], ... }

/** Flattens any provider content shape (string, parts, tool_result content) to text. */
function textOf(c) {
  if (c == null) return '';
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) return c.map(textOf).filter(Boolean).join('\n');
  if (typeof c === 'object') return textOf(c.text ?? c.content ?? c.output ?? '');
  return String(c);
}

const toTool = (t) => {
  const f = t.function ?? t;
  return f.name ? { name: f.name, schema: f.parameters ?? f.input_schema ?? f.parametersJsonSchema } : null;
};
// Muse Code groups its function tools in one Responses `{type: "namespace", tools}` item and accepts plain
// function calls back by tool name.
const tools = (list) => (list || []).flatMap((t) => (t?.type === 'namespace' ? t.tools || [] : [t])).map(toTool).filter(Boolean);
const isSystem = (m) => m.role === 'system' || m.role === 'developer';

const NORM = {
  chat: (b) => {
    const msgs = b.messages || [];
    const rf = b.response_format;
    return {
      model: b.model, stream: !!b.stream, includeUsage: !!b.stream_options?.include_usage,
      system: msgs.filter(isSystem).map((m) => textOf(m.content)).join('\n\n'),
      messages: msgs.filter((m) => !isSystem(m)).map((m) => ({ role: m.role === 'function' ? 'tool' : m.role, text: textOf(m.content) })),
      tools: tools([...(b.tools || []), ...(b.functions || [])]),
      effort: b.reasoning_effort ?? b.reasoning?.effort, reasoning: b.reasoning,
      jsonSchema: rf?.type === 'json_schema' ? rf.json_schema?.schema : rf?.type === 'json_object' ? { type: 'object' } : null,
      maxTokens: b.max_completion_tokens ?? b.max_tokens,
    };
  },
  responses: (b) => {
    const system = [textOf(b.instructions)];
    const messages = [];
    for (const it of typeof b.input === 'string' ? [{ role: 'user', content: b.input }] : b.input || []) {
      const type = it.type || 'message';
      if (type === 'message') isSystem(it) ? system.push(textOf(it.content)) : messages.push({ role: it.role, text: textOf(it.content) });
      else if (type.endsWith('_call_output')) messages.push({ role: 'tool', text: textOf(it.output) });
      else if (type.endsWith('_call')) messages.push({ role: 'assistant', text: '' });
    }
    return {
      model: b.model, stream: !!b.stream, system: system.filter(Boolean).join('\n\n'), messages, tools: tools(b.tools),
      effort: b.reasoning?.effort, reasoning: b.reasoning,
      jsonSchema: b.text?.format?.type === 'json_schema' ? b.text.format.schema : null, maxTokens: b.max_output_tokens,
    };
  },
  anthropic: (b) => ({
    model: b.model, stream: !!b.stream, // mid-conversation role:"system" messages (Claude Code ≥2.1) count as system text
    system: [textOf(b.system), ...(b.messages || []).filter(isSystem).map((m) => textOf(m.content))].filter(Boolean).join('\n\n'),
    messages: (b.messages || []).filter((m) => !isSystem(m)).map((m) => {
      const blocks = Array.isArray(m.content) ? m.content : [{ type: 'text', text: m.content }];
      const results = blocks.filter((x) => x.type === 'tool_result');
      return results.length
        ? { role: 'tool', text: textOf(results.map((r) => r.content)) }
        : { role: m.role, text: textOf(blocks.filter((x) => x.type === 'text')) };
    }),
    tools: tools(b.tools),
    effort: b.output_config?.effort ?? (b.thinking?.budget_tokens ? `budget:${b.thinking.budget_tokens}` : b.thinking?.type),
    reasoning: b.thinking || b.output_config ? { thinking: b.thinking, output_config: b.output_config } : null,
    jsonSchema: b.output_format?.schema ?? b.output_config?.format?.schema, maxTokens: b.max_tokens,
  }),
  gemini: (b) => {
    const gc = b.generationConfig || b.generation_config || {};
    const tc = gc.thinkingConfig;
    const si = b.systemInstruction ?? b.system_instruction;
    return {
      system: textOf(si?.parts ?? si),
      messages: (b.contents || []).map((c) => {
        const parts = c.parts || [];
        const results = parts.map((p) => p.functionResponse ?? p.function_response).filter(Boolean);
        return results.length
          ? { role: 'tool', text: JSON.stringify(results.map((r) => r.response)) }
          : { role: c.role === 'model' ? 'assistant' : 'user', text: textOf(parts.filter((p) => typeof p.text === 'string' && !p.thought)) };
      }),
      tools: tools((b.tools || []).flatMap((t) => t.functionDeclarations ?? t.function_declarations ?? [])),
      effort: tc?.thinkingLevel ?? (tc?.thinkingBudget != null ? `budget:${tc.thinkingBudget}` : null), reasoning: tc,
      jsonSchema: gc.responseMimeType === 'application/json' ? gc.responseJsonSchema ?? gc.responseSchema ?? { type: 'object' } : null,
      maxTokens: gc.maxOutputTokens,
    };
  },
};

// ---------- scripting

/** A message's text minus harness wrapper blocks like <system-reminder>…</system-reminder>. */
function unwrapped(text) {
  return text
    // Antigravity's resumed conversation adds a user message after the prompt, "The following is a
    // <SYSTEM_MESSAGE> not actually sent by the user. …<SYSTEM_MESSAGE>…</SYSTEM_MESSAGE>" (agy.md §4).
    .replace(/The following is an? <([A-Z_]+)> not actually sent by the user\.[\s\S]*?<\1>[\s\S]*?<\/\1>/g, '')
    .replace(/<(user_query|user_request)>([\s\S]*?)<\/\1>/gi, '$2') // Grok Build / Antigravity wrap the prompt itself
    .replace(/<([A-Za-z][\w-]*)[^>]*>[\s\S]*?<\/\1>/g, '').trim();
}

/** Text of the trailing user turn(s), minus wrapper blocks. */
function lastUserText(messages) {
  for (let i = messages.length - 1; i >= 0 && messages[i].role === 'user'; i--) {
    const text = unwrapped(messages[i].text);
    if (text) return text;
  }
  return '';
}

function pickShell(list) {
  const rank = (t) => SHELL_WORDS.findIndex((w) => t.name.toLowerCase().includes(w));
  return list.filter((t) => rank(t) >= 0 && !NOT_SHELL.test(t.name))
    .sort((a, b) => rank(a) - rank(b) || a.name.length - b.name.length)[0];
}

/** Builds a value for a JSON schema: required fields only (all with ctx.all); with ctx.cmd, command-ish fields get
 *  the command and escalation fields ask for unsandboxed execution so approval-gated harnesses block. */
function fill(schema, ctx, key = '') {
  let s = schema || {};
  s = (s.anyOf || s.oneOf)?.find((v) => v.type !== 'null') ?? s;
  if (s.const !== undefined) return s.const;
  if (s.enum) return (ctx.cmd && s.enum.find((v) => /escalat/i.test(v))) || s.enum[0];
  if (s.default !== undefined) return s.default;
  const type = String((Array.isArray(s.type) ? s.type.find((t) => t !== 'null') : s.type) || (s.properties ? 'object' : 'string')).toLowerCase();
  const isCmd = ctx.cmd && CMD_KEY.test(key);
  if (type === 'object') {
    const props = s.properties || {};
    const keys = Object.keys(props).filter((k) => ctx.all || s.required?.includes(k) || (ctx.cmd && (CMD_KEY.test(k) || ESCALATE_KEY.test(k))));
    return Object.fromEntries(keys.map((k) => [k, fill(props[k], ctx, k)]));
  }
  if (type === 'array') return isCmd ? ['bash', '-lc', ctx.cmd] : ctx.all ? [fill(s.items, ctx)] : [];
  if (type === 'boolean') return /approv|escalat/i.test(key);
  if (type === 'integer' || type === 'number') return /timeout/i.test(key) ? 60000 : s.minimum ?? 1;
  if (isCmd) return ctx.cmd;
  if (ctx.cmd && /justification/i.test(key)) return `Waycar lab: allow \`${ctx.cmd}\` to run outside the sandbox?`;
  if (/dir|cwd|path/i.test(key)) return '.';
  return ctx.text ?? 'Waycar mock check';
}

/** Decides the reply: { kind, delay, text?, call?: { name, args } }. */
function plan(n) {
  const user = lastUserText(n.messages);
  // Skips trailing wrapper-only user messages: Qwen Code follows a tool result with a
  // `<system-reminder>` memory catalog (qwen.md §1).
  const last = n.messages.findLast((m) => m.role !== 'user' || unwrapped(m.text));
  if (n.jsonSchema) return { kind: 'json', delay: 0, user, text: JSON.stringify(fill(n.jsonSchema, { all: true, text: 'Waycar mock session' })) };
  if (last?.role === 'tool') {
    const saw = last.text.includes('waycar-tool-ok') ? 'saw waycar-tool-ok' : 'tool output missing waycar-tool-ok';
    return finish({ kind: 'after-tool', delay: DELAY_MS, user, text: `waycar-tool-done: ${saw}` }, n);
  }
  if (!user || (!n.tools.length && (/\b(title|summar|topic|compact)/i.test(n.system) || n.maxTokens <= 32))) {
    return { kind: 'bookkeeping', delay: 0, user, text: 'Waycar mock session' };
  }
  // A title request whose only tool sets the title (grok's `session_title`, sent as model grok-4.6 at the
  // first prompt, grok.md §8): bookkeeping, answered by calling that tool.
  const titleTool = n.tools.length === 1 && /title/i.test(n.tools[0].name) ? n.tools[0] : null;
  if (titleTool) {
    return { kind: 'bookkeeping', delay: 0, user, call: { name: titleTool.name, args: fill(titleTool.schema || { type: 'object' }, { all: true, text: 'Waycar mock session' }) } };
  }
  const opening = !n.messages.some((m) => m.role === 'assistant');
  const delay = Math.max(user.includes('WAYCAR_SLOW') ? SLOW_MS : DELAY_MS, opening ? FIRST_MS : 0);
  const reply = `waycar-mock-reply: ${(user.match(/WAYCAR_\w+/g) || [user.split(/\s+/).pop()]).join(' ')}`;
  if (user.includes('WAYCAR_HOLD')) return finish({ kind: 'hold', delay: 0, user, text: reply }, n);
  const question = n.tools.find((t) => t.name === 'question');
  if (user.includes('WAYCAR_ASK') && question) {
    return { kind: 'question', delay, user, call: { name: question.name, args: { questions: [{
      question: 'Pick a color', header: 'Color',
      options: [{ label: 'Red', description: 'warm' }, { label: 'Blue', description: 'cool' }], multiple: false,
    }] } } };
  }
  if (!user.includes('WAYCAR_TOOL')) return finish({ kind: 'text', delay, user, text: reply }, n);
  const shell = pickShell(n.tools);
  const cmd = user.includes('WAYCAR_TOOL_MUTATE') ? MUTATE_CMD : TOOL_CMD;
  if (shell) return { kind: 'tool', delay, user, call: { name: shell.name, args: fill(shell.schema || { type: 'object' }, { cmd }) } };
  if (n.system.includes('<execute_command>')) { // XML-tool harnesses (Cline-style prompts without native tools)
    return { kind: 'tool-xml', delay, user, text: `<execute_command>\n<command>${cmd}</command>\n<requires_approval>true</requires_approval>\n</execute_command>` };
  }
  return finish({ kind: 'text', delay, user, text: `${reply} (no shell tool among: ${n.tools.map((t) => t.name).join(', ') || 'none'})` }, n);
}

/** Harnesses that only end a turn via attempt_completion (Cline/Kilo) get their text wrapped in it. */
function finish(p, n) {
  const done = n.tools.find((t) => t.name === 'attempt_completion');
  if (done) return { ...p, call: { name: done.name, args: fill(done.schema || { type: 'object' }, { text: p.text }) }, text: undefined };
  if (!n.tools.length && n.system.includes('<attempt_completion>')) {
    return { ...p, text: `<attempt_completion>\n<result>\n${p.text}\n</result>\n</attempt_completion>` };
  }
  return p;
}

// ---------- response formats: json(o, n, u) → body; stream(o, n, u) → { pre, post } events ({event?, data})
// pre is sent immediately, post after the scripted delay. o = { id, text, call?: { id, name, args (JSON), input } }

const chatCall = (c) => ({ id: c.id, type: 'function', function: { name: c.name, arguments: c.args } });
const chatUsage = (u) => ({ prompt_tokens: u.in, completion_tokens: u.out, total_tokens: u.in + u.out });
const responseItem = (o) => (o.call
  ? { type: 'function_call', id: o.id.replace('resp', 'fc'), call_id: o.call.id, name: o.call.name, arguments: o.call.args, status: 'completed' }
  : { type: 'message', id: o.id.replace('resp', 'msg'), status: 'completed', role: 'assistant', content: [{ type: 'output_text', text: o.text, annotations: [] }] });
const responseObj = (o, n, u, status, output) => ({
  id: o.id, object: 'response', created_at: unix(), status, model: n.model, output, parallel_tool_calls: true, tool_choice: 'auto',
  tools: [], error: null, incomplete_details: null,
  usage: status === 'completed'
    ? { input_tokens: u.in, input_tokens_details: { cached_tokens: 0 }, output_tokens: u.out, output_tokens_details: { reasoning_tokens: 0 }, total_tokens: u.in + u.out }
    : null,
});
const anthropicMsg = (o, n) => ({ id: o.id, type: 'message', role: 'assistant', model: n.model, stop_sequence: null });
const anthropicBlock = (o) => (o.call ? { type: 'tool_use', id: o.call.id, name: o.call.name, input: o.call.input } : { type: 'text', text: o.text });
const anthropicUsage = (i, out) => ({ input_tokens: i, output_tokens: out, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 });
const geminiParts = (o) => (o.call ? [[{ functionCall: { name: o.call.name, args: o.call.input } }]] : pieces(o.text).map((text) => [{ text }]));
const geminiChunk = (o, n, parts, u) => ({
  candidates: [{ content: { role: 'model', parts }, index: 0, ...(u && { finishReason: 'STOP' }) }],
  ...(u && { usageMetadata: { promptTokenCount: u.in, candidatesTokenCount: u.out, totalTokenCount: u.in + u.out } }),
  modelVersion: n.model, responseId: o.id,
});

const API = {
  chat: {
    prefix: 'chatcmpl',
    json: (o, n, u) => ({
      id: o.id, object: 'chat.completion', created: unix(), model: n.model,
      choices: [{
        index: 0, logprobs: null, finish_reason: o.call ? 'tool_calls' : 'stop',
        message: { role: 'assistant', content: o.call ? null : o.text, ...(o.call && { tool_calls: [chatCall(o.call)] }) },
      }],
      usage: chatUsage(u),
    }),
    stream(o, n, u) {
      const chunk = (delta, finish_reason = null, extra = {}, choices = [{ index: 0, delta, finish_reason, logprobs: null }]) => ({
        data: { id: o.id, object: 'chat.completion.chunk', created: unix(), model: n.model, choices, ...extra },
      });
      const post = o.call
        ? [chunk({ tool_calls: [{ index: 0, ...chatCall({ ...o.call, args: '' }) }] }),
          ...pieces(o.call.args).map((d) => chunk({ tool_calls: [{ index: 0, function: { arguments: d } }] }))]
        : pieces(o.text).map((d) => chunk({ content: d }));
      post.push(chunk({}, o.call ? 'tool_calls' : 'stop', n.includeUsage ? {} : { usage: chatUsage(u) }));
      if (n.includeUsage) post.push(chunk(null, null, { usage: chatUsage(u) }, []));
      post.push({ data: '[DONE]' });
      return { pre: [chunk({ role: 'assistant', content: '' })], post };
    },
  },
  responses: {
    prefix: 'resp',
    json: (o, n, u) => responseObj(o, n, u, 'completed', [responseItem(o)]),
    stream(o, n, u) {
      let sq = 0;
      const ev = (type, x) => ({ event: type, data: { type, sequence_number: sq++, ...x } });
      const item = responseItem(o);
      const at = { item_id: item.id, output_index: 0 };
      const pre = [ev('response.created', { response: responseObj(o, n, u, 'in_progress', []) }),
        ev('response.in_progress', { response: responseObj(o, n, u, 'in_progress', []) })];
      const post = [];
      if (o.call) {
        post.push(ev('response.output_item.added', { output_index: 0, item: { ...item, arguments: '', status: 'in_progress' } }),
          ...pieces(o.call.args).map((delta) => ev('response.function_call_arguments.delta', { ...at, delta })),
          ev('response.function_call_arguments.done', { ...at, arguments: o.call.args }));
      } else {
        const part = { type: 'output_text', text: '', annotations: [] };
        post.push(ev('response.output_item.added', { output_index: 0, item: { ...item, status: 'in_progress', content: [] } }),
          ev('response.content_part.added', { ...at, content_index: 0, part }),
          ...pieces(o.text).map((delta) => ev('response.output_text.delta', { ...at, content_index: 0, delta, logprobs: [] })),
          ev('response.output_text.done', { ...at, content_index: 0, text: o.text, logprobs: [] }),
          ev('response.content_part.done', { ...at, content_index: 0, part: { ...part, text: o.text } }));
      }
      post.push(ev('response.output_item.done', { output_index: 0, item }),
        ev('response.completed', { response: responseObj(o, n, u, 'completed', [item]) }));
      return { pre, post };
    },
  },
  anthropic: {
    prefix: 'msg',
    json: (o, n, u) => ({ ...anthropicMsg(o, n), content: [anthropicBlock(o)], stop_reason: o.call ? 'tool_use' : 'end_turn', usage: anthropicUsage(u.in, u.out) }),
    stream(o, n, u) {
      const ev = (type, x = {}) => ({ event: type, data: { type, ...x } });
      const deltas = o.call
        ? pieces(o.call.args).map((d) => ({ type: 'input_json_delta', partial_json: d }))
        : pieces(o.text).map((d) => ({ type: 'text_delta', text: d }));
      return {
        pre: [ev('message_start', { message: { ...anthropicMsg(o, n), content: [], stop_reason: null, usage: anthropicUsage(u.in, 1) } }), ev('ping')],
        post: [
          ev('content_block_start', { index: 0, content_block: o.call ? { ...anthropicBlock(o), input: {} } : { type: 'text', text: '' } }),
          ...deltas.map((delta) => ev('content_block_delta', { index: 0, delta })),
          ev('content_block_stop', { index: 0 }),
          ev('message_delta', { delta: { stop_reason: o.call ? 'tool_use' : 'end_turn', stop_sequence: null }, usage: { output_tokens: u.out } }),
          ev('message_stop'),
        ],
      };
    },
  },
  gemini: {
    prefix: 'gen',
    json: (o, n, u) => geminiChunk(o, n, o.call ? geminiParts(o)[0] : [{ text: o.text }], u),
    stream: (o, n, u) => {
      const parts = geminiParts(o);
      return { pre: [], post: parts.map((p, i) => ({ data: geminiChunk(o, n, p, i === parts.length - 1 && u) })) };
    },
  },
};

// ---------- HTTP

const openaiModel = (id) => ({ id, object: 'model', type: 'model', display_name: id, created: 1735689600, created_at: '2025-01-01T00:00:00Z', owned_by: 'waycar-mock' });
const geminiModel = (id) => ({
  name: `models/${id}`, baseModelId: id, version: '1', displayName: id, inputTokenLimit: 1048576, outputTokenLimit: 65536,
  supportedGenerationMethods: ['generateContent', 'streamGenerateContent', 'countTokens'],
});

function sendJson(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

function record(entry) {
  log.push(entry);
  if (log.length > LOG_MAX) log.shift();
  console.log([entry.time, entry.method, entry.path, entry.api, entry.model, entry.reply].filter(Boolean).join(' '));
}

const readBody = (req) => new Promise((resolve, reject) => {
  const chunks = [];
  req.on('data', (d) => chunks.push(d)).on('end', () => resolve(Buffer.concat(chunks).toString('utf8'))).on('error', reject);
});

async function generate(api, req, res, url, base, body, raw, pathModel, gemStream) {
  const n = NORM[api](body);
  if (api === 'gemini') Object.assign(n, { model: pathModel, stream: gemStream });
  const p = plan(n);
  const call = p.call && { id: newId(api === 'anthropic' ? 'toolu' : 'call'), name: p.call.name, args: JSON.stringify(p.call.args), input: p.call.args };
  const o = { id: newId(API[api].prefix), text: p.text ?? '', call };
  const u = { in: tokens(raw), out: tokens(call ? call.args : o.text) };
  record({
    ...base, api, model: n.model ?? null, stream: n.stream, effort: n.effort ?? null, reasoning: n.reasoning ?? null,
    system: n.system, lastUser: p.user, messages: n.messages.map((m) => ({ role: m.role, text: m.text.slice(0, 8000) })),
    tools: n.tools.map((t) => t.name), shellTool: pickShell(n.tools) ?? null, // shellTool: { name, schema } for probing harness schemas
    reply: p.kind, replyText: o.text, toolCall: call ? { name: call.name, args: call.input } : null,
  });
  const ready = p.kind === 'hold' ? hold(res, o.id, base.userAgent, p.user) : sleep(p.delay);
  if (!n.stream) {
    await ready;
    return res.destroyed || sendJson(res, 200, API[api].json(o, n, u));
  }
  const { pre, post } = API[api].stream(o, n, u);
  const array = api === 'gemini' && url.searchParams.get('alt') !== 'sse'; // Gemini without alt=sse streams a JSON array
  res.writeHead(200, { 'content-type': array ? 'application/json' : 'text/event-stream', 'cache-control': 'no-cache' });
  res.flushHeaders();
  let sent = 0;
  const send = ({ event, data }) => res.write(array
    ? `${sent++ ? ',' : '['}\n${JSON.stringify(data)}`
    : `${event ? `event: ${event}\n` : ''}data: ${typeof data === 'string' ? data : JSON.stringify(data)}\n\n`);
  pre.forEach(send);
  await ready;
  if (res.destroyed) return;
  post.forEach(send);
  res.end(array ? '\n]' : undefined);
}

async function handle(req, res) {
  const url = new URL(req.url, 'http://mock');
  const path = url.pathname.replace(/\/+$/, '') || '/';
  // `features`: what the e2e suite relies on; run-e2e.sh refuses a mock without them (a stale image).
  if (path === '/_health') return sendJson(res, 200, {
    ok: true, logged: log.length, features: FEATURES,
    holds: [...holds.values()].map(({ id, userAgent, lastUser }) => ({ id, userAgent, lastUser })),
  });
  if (path === '/_log') {
    if (req.method === 'DELETE') {
      console.log(`${new Date().toISOString()} DELETE /_log (${log.length} entries) ${req.headers['user-agent'] ?? ''}`);
      log.length = 0;
      return sendJson(res, 200, { ok: true });
    }
    const since = url.searchParams.get('since');
    const from = !since ? 0 : /^\d+$/.test(since) ? Number(since) : Date.parse(since);
    if (Number.isNaN(from)) return sendJson(res, 400, { error: { message: 'since must be epoch ms or an ISO time' } });
    res.writeHead(200, { 'content-type': 'application/x-ndjson' });
    return res.end(log.filter((e) => e.ts >= from).map((e) => `${JSON.stringify(e)}\n`).join(''));
  }
  const raw = await readBody(req);
  let body;
  try { body = raw ? JSON.parse(raw) : {}; } catch { return sendJson(res, 400, { error: { type: 'invalid_request_error', message: 'body is not JSON' } }); }
  if (req.method === 'POST' && path === '/_release') {
    const pending = holds.get(body.id);
    pending?.release();
    return sendJson(res, 200, { released: !!pending });
  }
  const h = req.headers;
  const base = {
    time: new Date().toISOString(), ts: Date.now(), method: req.method, path: req.url, userAgent: h['user-agent'] ?? null,
    headers: Object.fromEntries(LOG_HEADERS.filter((k) => h[k]).map((k) => [k, h[k]])),
    auth: h.authorization ? 'bearer' : h['x-api-key'] ? 'x-api-key' : h['x-goog-api-key'] ? 'x-goog-api-key' : url.searchParams.has('key') ? 'key-param' : null,
  };
  const gem = path.match(/\/models\/([^/:]+):(\w+)$/);
  const isGemini = gem || /\/v1(beta|alpha)\b/.test(path) || base.auth === 'x-goog-api-key' || base.auth === 'key-param';
  let m;
  if (req.method === 'POST') {
    if (path.endsWith('/chat/completions')) return generate('chat', req, res, url, base, body, raw);
    if (path.endsWith('/responses')) return generate('responses', req, res, url, base, body, raw);
    if (path.endsWith('/messages/count_tokens')) { record({ ...base, api: 'anthropic-count', model: body.model }); return sendJson(res, 200, { input_tokens: tokens(raw) }); }
    if (path.endsWith('/messages')) return generate('anthropic', req, res, url, base, body, raw);
    if (gem?.[2] === 'countTokens') { record({ ...base, api: 'gemini-count', model: gem[1] }); return sendJson(res, 200, { totalTokens: tokens(raw) }); }
    if (gem && /^(stream)?generateContent$/i.test(gem[2])) return generate('gemini', req, res, url, base, body, raw, gem[1], gem[2].startsWith('stream'));
  } else if (req.method === 'GET') {
    if (path.endsWith('/models')) {
      record({ ...base, api: 'models' });
      return sendJson(res, 200, isGemini
        ? { models: MODELS.map(geminiModel) }
        : { object: 'list', data: MODELS.map(openaiModel), has_more: false, first_id: MODELS[0], last_id: MODELS.at(-1) });
    }
    if ((m = path.match(/\/models\/([^/]+)$/))) {
      record({ ...base, api: 'models', model: m[1] });
      return sendJson(res, 200, isGemini ? geminiModel(m[1]) : openaiModel(m[1]));
    }
  }
  record({ ...base, api: 'unknown' });
  return sendJson(res, 404, { error: { type: 'not_found_error', message: `waycar mock: no route for ${req.method} ${path}` } });
}

http.createServer((req, res) => {
  res.on('error', () => {});
  handle(req, res).catch((err) => {
    console.error(err);
    if (!res.headersSent) sendJson(res, 500, { error: { type: 'api_error', message: String(err?.message || err) } });
    else res.destroy();
  });
}).listen(PORT, () => console.log(`waycar mock model server on :${PORT} (delay ${DELAY_MS} ms, slow ${SLOW_MS} ms)`));

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
