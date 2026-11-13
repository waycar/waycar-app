'use strict';
// Self-test for the mock model server: every API, streaming and not, plus a tool round trip each.
// Usage: node selftest.js [base-url]   (default $MOCK_URL or http://127.0.0.1:18080). Leaves /_log alone (safe beside smokes).
const BASE = (process.argv[2] || process.env.MOCK_URL || 'http://127.0.0.1:18080').replace(/\/$/, '');
const UA = 'waycar-mock-selftest';
const SHELL_SCHEMA = { type: 'object', properties: { command: { type: 'string' }, description: { type: 'string' }, timeout: { type: 'number' } }, required: ['command'] };
// codex 0.162.1 exec_command (from a live /_log shellTool record), trimmed to the fields the mock cares about.
const CODEX_EXEC_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['cmd'],
  properties: {
    cmd: { type: 'string' }, workdir: { type: 'string' }, justification: { type: 'string' }, prefix_rule: { type: 'array', items: { type: 'string' } },
    sandbox_permissions: { type: 'string', enum: ['use_default', 'require_escalated'] }, yield_time_ms: { type: 'number' },
  },
};
const fail = (msg) => { throw new Error(msg); };

async function request(method, path, body, headers = {}) {
  const res = await fetch(BASE + path, { method, headers: { 'content-type': 'application/json', 'user-agent': UA, ...headers }, body: body && JSON.stringify(body) });
  const raw = await res.text();
  if (!res.ok) fail(`${method} ${path} → ${res.status} ${raw}`);
  return raw;
}

function parseSse(raw) {
  return raw.split(/\n\n+/).filter((b) => b.trim()).map((block) => {
    const ev = { data: '' };
    for (const line of block.split('\n')) {
      if (line.startsWith('event:')) ev.event = line.slice(6).trim();
      else if (line.startsWith('data:')) ev.data += line.slice(5).trim();
    }
    return ev;
  }).filter((e) => e.data && e.data !== '[DONE]').map((e) => ({ event: e.event, ...JSON.parse(e.data) }));
}

// Each adapter: path(mode), body(turns, stream), parse(raw, mode) → { text, call?: { id, name, args } }.
// turns: [{ user }, { call }, { result: { id, name, output } }]; modes: json | sse (| array for Gemini).
const ADAPTERS = {
  chat: {
    path: () => '/v1/chat/completions',
    body: (turns, stream) => ({
      model: 'mock-model', stream, stream_options: stream ? { include_usage: true } : undefined, reasoning_effort: 'high',
      messages: [{ role: 'system', content: 'SYS_CHAT' }, ...turns.map((t) => (t.user ? { role: 'user', content: t.user }
        : t.call ? { role: 'assistant', content: null, tool_calls: [{ id: t.call.id, type: 'function', function: { name: t.call.name, arguments: JSON.stringify(t.call.args) } }] }
          : { role: 'tool', tool_call_id: t.result.id, content: t.result.output }))],
      tools: [{ type: 'function', function: { name: 'bash', parameters: SHELL_SCHEMA } }, { type: 'function', function: { name: 'read_file', parameters: { type: 'object' } } }],
    }),
    parse(raw, mode) {
      if (mode === 'json') {
        const msg = JSON.parse(raw).choices[0].message;
        const tc = msg.tool_calls?.[0];
        return { text: msg.content ?? '', call: tc && { id: tc.id, name: tc.function.name, args: JSON.parse(tc.function.arguments) } };
      }
      if (!raw.includes('data: [DONE]')) fail('chat stream missing [DONE]');
      const evs = parseSse(raw);
      if (!evs.at(-1).usage || evs.at(-1).choices.length) fail('chat stream missing trailing usage chunk');
      let text = '';
      let call;
      for (const tc of evs.flatMap((e) => e.choices[0]?.delta?.tool_calls ?? [])) {
        call ??= { id: tc.id, name: tc.function.name, args: '' };
        call.args += tc.function.arguments ?? '';
      }
      for (const e of evs) text += e.choices[0]?.delta?.content ?? '';
      return { text, call: call && { ...call, args: JSON.parse(call.args) } };
    },
  },
  responses: {
    path: () => '/v1/responses',
    body: (turns, stream) => ({
      model: 'gpt-5-codex', stream, instructions: 'SYS_RESPONSES', reasoning: { effort: 'medium' },
      input: turns.map((t) => (t.user ? { type: 'message', role: 'user', content: [{ type: 'input_text', text: t.user }] }
        : t.call ? { type: 'function_call', call_id: t.call.id, name: t.call.name, arguments: JSON.stringify(t.call.args) }
          : { type: 'function_call_output', call_id: t.result.id, output: t.result.output })),
      tools: [{ type: 'function', name: 'exec_command', parameters: CODEX_EXEC_SCHEMA },
        { type: 'function', name: 'write_stdin', parameters: { type: 'object', properties: { chars: { type: 'string' } }, required: ['chars'] } }],
    }),
    parse(raw, mode) {
      let output;
      if (mode === 'json') output = JSON.parse(raw).output;
      else {
        const evs = parseSse(raw);
        const types = evs.map((e) => e.type);
        for (const t of ['response.created', 'response.output_item.added', 'response.output_item.done', 'response.completed']) if (!types.includes(t)) fail(`responses stream missing ${t}`);
        if (!evs.at(-1).response.usage) fail('response.completed without usage');
        if (evs.some((e, i) => e.sequence_number !== i)) fail('responses sequence_number not monotonic');
        const deltas = evs.filter((e) => e.type.endsWith('.delta')).map((e) => e.delta).join('');
        output = evs.filter((e) => e.type === 'response.output_item.done').map((e) => e.item);
        const item = output[0];
        if (deltas !== (item.arguments ?? item.content?.[0].text)) fail('responses deltas do not add up to the item');
      }
      const fc = output.find((i) => i.type === 'function_call');
      return {
        text: output.filter((i) => i.type === 'message').flatMap((i) => i.content).map((c) => c.text).join(''),
        call: fc && { id: fc.call_id, name: fc.name, args: JSON.parse(fc.arguments) },
      };
    },
  },
  anthropic: {
    path: () => '/v1/messages?beta=true',
    headers: { 'anthropic-version': '2023-06-01', 'x-api-key': 'mock' },
    body: (turns, stream) => ({
      model: 'claude-sonnet-4-5', max_tokens: 1024, stream, system: [{ type: 'text', text: 'SYS_ANTHROPIC' }], thinking: { type: 'enabled', budget_tokens: 2048 },
      messages: [...turns.map((t) => (t.user ? { role: 'user', content: [{ type: 'text', text: '<system-reminder>ignore WAYCAR_SLOW</system-reminder>' }, { type: 'text', text: t.user }] }
        : t.call ? { role: 'assistant', content: [{ type: 'tool_use', id: t.call.id, name: t.call.name, input: t.call.args }] }
          : { role: 'user', content: [{ type: 'tool_result', tool_use_id: t.result.id, content: t.result.output }] })),
        { role: 'system', content: '# Environment (trailing system message, as Claude Code 2.1 sends)' }],
      tools: [{ name: 'BashOutput', input_schema: { type: 'object', properties: { bash_id: { type: 'string' } }, required: ['bash_id'] } },
        { name: 'Bash', input_schema: SHELL_SCHEMA }, { name: 'KillShell', input_schema: { type: 'object' } }],
    }),
    parse(raw, mode) {
      let blocks;
      if (mode === 'json') blocks = JSON.parse(raw).content;
      else {
        const evs = parseSse(raw);
        if (evs[0].type !== 'message_start' || evs.at(-1).type !== 'message_stop') fail('anthropic stream not framed by message_start/message_stop');
        blocks = evs.filter((e) => e.type === 'content_block_start').map((e) => ({ ...e.content_block, json: '' }));
        for (const e of evs.filter((x) => x.type === 'content_block_delta')) {
          if (e.delta.type === 'text_delta') blocks[e.index].text += e.delta.text;
          else blocks[e.index].json += e.delta.partial_json;
        }
        for (const b of blocks) if (b.type === 'tool_use') b.input = JSON.parse(b.json);
      }
      const tu = blocks.find((b) => b.type === 'tool_use');
      return { text: blocks.filter((b) => b.type === 'text').map((b) => b.text).join(''), call: tu && { id: tu.id, name: tu.name, args: tu.input } };
    },
  },
  gemini: {
    path: (mode) => `/v1beta/models/gemini-2.5-pro:${mode === 'json' ? 'generateContent' : 'streamGenerateContent'}${mode === 'sse' ? '?alt=sse' : ''}`,
    headers: { 'x-goog-api-key': 'mock' },
    body: (turns) => ({
      systemInstruction: { parts: [{ text: 'SYS_GEMINI' }] }, generationConfig: { thinkingConfig: { thinkingBudget: 1024 } },
      contents: turns.map((t) => (t.user ? { role: 'user', parts: [{ text: t.user }] }
        : t.call ? { role: 'model', parts: [{ functionCall: { name: t.call.name, args: t.call.args } }] }
          : { role: 'user', parts: [{ functionResponse: { name: t.result.name, response: { output: t.result.output } } }] })),
      tools: [{ functionDeclarations: [{ name: 'run_shell_command', parameters: { type: 'OBJECT', properties: { command: { type: 'STRING' }, is_background: { type: 'BOOLEAN' } }, required: ['command', 'is_background'] } }] }],
    }),
    parse(raw, mode) {
      const chunks = mode === 'json' ? [JSON.parse(raw)] : mode === 'array' ? JSON.parse(raw) : parseSse(raw);
      if (chunks.at(-1).candidates[0].finishReason !== 'STOP' || !chunks.at(-1).usageMetadata) fail('gemini last chunk lacks finishReason/usageMetadata');
      const parts = chunks.flatMap((c) => c.candidates[0].content.parts);
      const fc = parts.find((p) => p.functionCall)?.functionCall;
      return { text: parts.map((p) => p.text ?? '').join(''), call: fc && { id: 'gemini-call', name: fc.name, args: fc.args } };
    },
  },
};

async function converse(api, mode, turns) {
  const a = ADAPTERS[api];
  const raw = await request('POST', a.path(mode), a.body(turns, mode !== 'json'), a.headers);
  return a.parse(raw, mode);
}

async function timed(fn) {
  const t0 = Date.now();
  const value = await fn();
  return [value, Date.now() - t0];
}

const checks = [];
const check = (name, fn) => {
  const run = timed(fn);
  run.catch(() => {}); // reported in order below
  checks.push({ name, run });
};

async function main() {
  const started = Date.now();
  const health = JSON.parse(await request('GET', '/_health'));
  if (!health.ok) fail('health not ok');

  for (const [api, modes] of [['chat', ['json', 'sse']], ['responses', ['json', 'sse']], ['anthropic', ['json', 'sse']], ['gemini', ['json', 'sse', 'array']]]) {
    for (const mode of modes) {
      const other = mode === 'json' ? 'sse' : 'json';
      check(`${api}/${mode} WAYCAR_HOLD waits for its release`, async () => {
        const token = `WAYCAR_HOLD_${api.toUpperCase()}_${mode.toUpperCase()}`;
        let completed = false;
        const pending = converse(api, mode, [{ user: token }]).then((reply) => { completed = true; return reply; });
        pending.catch(() => {});
        let held;
        const deadline = Date.now() + 30000;
        while (!held && Date.now() < deadline) {
          const state = JSON.parse(await request('GET', '/_health'));
          held = state.holds.find((h) => h.userAgent === UA && h.lastUser === token);
        }
        if (!held || completed) fail('model did not remain held before release');
        const release = JSON.parse(await request('POST', '/_release', { id: held.id }));
        if (release.released !== true) fail('hold disappeared before release');
        const reply = await pending;
        if (reply.call || !reply.text.includes(token)) fail(`held reply ${JSON.stringify(reply)}`);
        const again = JSON.parse(await request('POST', '/_release', { id: held.id }));
        if (again.released !== false) fail('hold released twice');
      });
      check(`${api}/${mode} text`, async () => {
        const token = `WAYCAR_ECHO_${api.toUpperCase()}_${mode.toUpperCase()}`;
        const [r, ms] = await timed(() => converse(api, mode, [{ user: `please echo ${token}` }]));
        if (r.call || !r.text.includes(token)) fail(`expected text echoing ${token}, got ${JSON.stringify(r)}`);
        if (ms < 1200) fail(`replied too fast (${ms} ms)`);
      });
      check(`${api}/${mode} tool → ${other} result`, async () => {
        const user = { user: 'run it WAYCAR_TOOL' };
        const r = await converse(api, mode, [user]);
        if (!r.call || !JSON.stringify(r.call.args).includes('echo waycar-tool-ok')) fail(`expected shell tool call, got ${JSON.stringify(r)}`);
        const after = await converse(api, other, [user, { call: r.call }, { result: { id: r.call.id, name: r.call.name, output: 'waycar-tool-ok\n' } }]);
        if (after.call || !after.text.includes('saw waycar-tool-ok')) fail(`expected text after tool result, got ${JSON.stringify(after)}`);
        return `${r.call.name} ${JSON.stringify(r.call.args)}`;
      });
    }
  }
  for (const api of Object.keys(ADAPTERS)) {
    for (const mode of ['json', 'sse']) {
      check(`${api}/${mode} WAYCAR_ASK question → result`, async () => {
        const a = ADAPTERS[api];
        const body = a.body([{ user: 'WAYCAR_ASK' }], mode !== 'json');
        const schema = { type: 'object' };
        body.tools = api === 'chat' ? [{ type: 'function', function: { name: 'question', parameters: schema } }]
          : api === 'responses' ? [{ type: 'function', name: 'question', parameters: schema }]
            : api === 'anthropic' ? [{ name: 'question', input_schema: schema }]
              : [{ functionDeclarations: [{ name: 'question', parameters: schema }] }];
        const r = a.parse(await request('POST', a.path(mode), body, a.headers), mode);
        const q = r.call?.args.questions;
        if (r.call?.name !== 'question' || q?.length !== 1 || q[0].question !== 'Pick a color'
          || q[0].header !== 'Color' || q[0].multiple !== false
          || JSON.stringify(q[0].options) !== JSON.stringify([{ label: 'Red', description: 'warm' }, { label: 'Blue', description: 'cool' }])) fail(`question args ${JSON.stringify(r)}`);
        const after = await converse(api, mode, [{ user: 'WAYCAR_ASK' }, { call: r.call }, { result: { id: r.call.id, name: r.call.name, output: 'Blue' } }]);
        if (after.call || !after.text.includes('waycar-tool-done')) fail(`question result ${JSON.stringify(after)}`);
      });
    }
  }
  check('WAYCAR_ASK without question replies with text', async () => {
    const r = await converse('chat', 'json', [{ user: 'WAYCAR_ASK' }]);
    if (r.call || !r.text.includes('WAYCAR_ASK')) fail(`question fallback ${JSON.stringify(r)}`);
  });
  check('WAYCAR_TOOL_MUTATE writes', async () => {
    const r = await converse('chat', 'json', [{ user: 'WAYCAR_TOOL_MUTATE' }]);
    if (r.call?.args.command !== 'touch /tmp/waycar-tool-mutate && echo waycar-tool-ok') fail(`mutate args ${JSON.stringify(r)}`);
  });
  check('codex exec_command asks for escalation; legacy shell array', async () => {
    const codex = await converse('responses', 'json', [{ user: 'WAYCAR_TOOL' }]);
    const a = codex.call.args;
    if (a.cmd !== 'echo waycar-tool-ok' || a.sandbox_permissions !== 'require_escalated' || !a.justification || 'prefix_rule' in a) fail(`codex args ${JSON.stringify(a)}`);
    const legacy = JSON.parse(await request('POST', '/v1/responses', {
      model: 'm', input: 'WAYCAR_TOOL',
      tools: [{ type: 'function', name: 'shell', parameters: { type: 'object', properties: { command: { type: 'array', items: { type: 'string' } }, with_escalated_permissions: { type: 'boolean' }, justification: { type: 'string' } }, required: ['command'] } }],
    })).output[0];
    const l = JSON.parse(legacy.arguments);
    if (l.command.at(-1) !== 'echo waycar-tool-ok' || l.with_escalated_permissions !== true || !l.justification) fail(`legacy args ${legacy.arguments}`);
  });
  check('chat WAYCAR_SLOW waits ~15 s', async () => {
    const [, ms] = await timed(() => converse('chat', 'json', [{ user: 'take your time WAYCAR_SLOW' }]));
    if (ms < 14000) fail(`slow reply after only ${ms} ms`);
  });
  check('opening turn waits MOCK_FIRST_MS; a later one does not', async () => {
    const [, opening] = await timed(() => converse('chat', 'json', [{ user: 'hello WAYCAR_OPEN' }]));
    if (opening < 5500) fail(`opening reply after only ${opening} ms`);
    const [, later] = await timed(() => request('POST', '/v1/chat/completions', {
      model: 'm', tools: [{ type: 'function', function: { name: 'bash', parameters: { type: 'object' } } }],
      messages: [{ role: 'user', content: 'hello' }, { role: 'assistant', content: 'hi' }, { role: 'user', content: 'again WAYCAR_LATER' }],
    }));
    if (later > 4000) fail(`later reply took ${later} ms`);
  });
  const fast = async (path, body, headers) => {
    const [raw, ms] = await timed(() => request('POST', path, body, headers));
    if (ms > 500) fail(`bookkeeping reply took ${ms} ms`);
    return raw;
  };
  check('bookkeeping via /api/v1 chat prefix', () => fast('/api/v1/chat/completions', { model: 'm', messages: [{ role: 'system', content: 'Generate a short title' }, { role: 'user', content: 'WAYCAR_SLOW' }] }));
  check('bookkeeping via /openai/v1 responses prefix', () => fast('/openai/v1/responses', { model: 'm', input: [] }));
  check('bookkeeping via unprefixed /messages', () => fast('/messages', { model: 'm', max_tokens: 1, messages: [{ role: 'user', content: 'quota' }] }));
  for (const [name, wrapped] of [['grok <user_query>', '<user_query>\nhello WAYCAR_GROK\n</user_query>'],
    ['agy <USER_REQUEST>', '<USER_REQUEST>\nhello WAYCAR_GROK\n</USER_REQUEST>\n<ADDITIONAL_METADATA>x</ADDITIONAL_METADATA>']]) {
    check(`${name} prompt unwrapped`, async () => {
      const raw = await request('POST', '/v1/chat/completions', { model: 'm', messages: [{ role: 'user', content: '<user_info>x</user_info>' }, { role: 'user', content: wrapped }] });
      if (!JSON.parse(raw).choices[0].message.content.includes('WAYCAR_GROK')) fail(`not unwrapped: ${raw}`);
    });
  }
  check('qwen tool result followed by a <system-reminder>-only user message', async () => {
    const raw = await request('POST', '/v1/chat/completions', {
      model: 'm', tools: [{ type: 'function', function: { name: 'run_shell_command', parameters: SHELL_SCHEMA } }],
      messages: [{ role: 'user', content: 'run WAYCAR_TOOL_MUTATE' },
        { role: 'assistant', content: null, tool_calls: [{ id: 'c1', type: 'function', function: { name: 'run_shell_command', arguments: '{}' } }] },
        { role: 'tool', tool_call_id: 'c1', content: 'Output: waycar-tool-ok' },
        { role: 'user', content: '<system-reminder>\n# Current auto-memory catalog\n</system-reminder>' }],
    });
    if (!JSON.parse(raw).choices[0].message.content?.includes('saw waycar-tool-ok')) fail(`not read as a tool result: ${raw}`);
  });
  check('grok session_title request: bookkeeping that calls the title tool', async () => {
    const raw = await fast('/v1/chat/completions', {
      model: 'grok-4.6', stream: false,
      tools: [{ type: 'function', function: { name: 'session_title', parameters: { type: 'object', properties: { session_title: { type: 'string' } }, required: ['session_title'] } } }],
      messages: [{ role: 'system', content: 'You are tasked with generating the session title.' }, { role: 'user', content: '<user_query>\nhello WAYCAR_TITLE\n</user_query>' }],
    });
    const call = JSON.parse(raw).choices[0].message.tool_calls?.[0];
    if (call?.function.name !== 'session_title' || !JSON.parse(call.function.arguments).session_title) fail(`no title call: ${raw}`);
  });
  check('agy resume: the system notice after the prompt is not the prompt', async () => {
    const notice = 'The following is a <SYSTEM_MESSAGE> not actually sent by the user. It is provided by the system as important information to pay attention to.\n\n<SYSTEM_MESSAGE>\n[Message] sender=system content=[Notice] All your subagents and background tasks have been stopped due to server restart.\n</SYSTEM_MESSAGE>';
    const raw = await request('POST', '/v1beta/models/gemini-3.6-flash:generateContent', {
      contents: [{ role: 'user', parts: [{ text: '<USER_REQUEST>\nhello WAYCAR_BEFORE\n</USER_REQUEST>' }] }, { role: 'model', parts: [{ text: 'waycar-mock-reply: WAYCAR_BEFORE' }] },
        { role: 'user', parts: [{ text: '<USER_REQUEST>\nafter resume WAYCAR_RESUMED\n</USER_REQUEST>\n<ADDITIONAL_METADATA>x</ADDITIONAL_METADATA>' }] },
        { role: 'user', parts: [{ text: notice }] }],
    });
    const text = JSON.parse(raw).candidates[0].content.parts.map((p) => p.text).join('');
    if (text !== 'waycar-mock-reply: WAYCAR_RESUMED') fail(`not the prompt's reply: ${raw}`);
  });
  check('gemini JSON-schema bookkeeping', async () => {
    const raw = await fast('/v1beta/models/gemini-2.5-flash:generateContent', {
      contents: [{ role: 'user', parts: [{ text: 'who speaks next?' }] }],
      generationConfig: { responseMimeType: 'application/json', responseSchema: { type: 'OBJECT', properties: { reasoning: { type: 'STRING' }, next_speaker: { type: 'STRING', enum: ['user', 'model'] } }, required: ['reasoning', 'next_speaker'] } },
    });
    const v = JSON.parse(JSON.parse(raw).candidates[0].content.parts[0].text);
    if (v.next_speaker !== 'user' || typeof v.reasoning !== 'string') fail(`bad schema fill ${JSON.stringify(v)}`);
  });
  check('anthropic count_tokens', async () => {
    if (!(JSON.parse(await request('POST', '/v1/messages/count_tokens', { model: 'm', messages: [{ role: 'user', content: 'hi' }] })).input_tokens > 0)) fail('no input_tokens');
  });
  check('model lists (OpenAI/Anthropic + Gemini)', async () => {
    const list = JSON.parse(await request('GET', '/v1/models'));
    if (!list.data.some((m) => m.id === 'mock-model' && m.object === 'model' && m.type === 'model')) fail('openai/anthropic list lacks mock-model');
    const gem = JSON.parse(await request('GET', '/v1beta/models'));
    if (!gem.models.some((m) => m.name === 'models/gemini-2.5-pro')) fail('gemini list lacks models/gemini-2.5-pro');
  });

  let failed = 0;
  for (const c of checks) {
    try {
      const [detail, ms] = await c.run;
      console.log(`ok    ${c.name} (${(ms / 1000).toFixed(1)} s)${typeof detail === 'string' && detail.length < 160 ? ` ${detail}` : ''}`);
    } catch (err) {
      failed++;
      console.log(`FAIL  ${c.name}: ${err.message}`);
    }
  }

  const entries = (await request('GET', `/_log?since=${started}`)).split('\n').filter(Boolean).map((l) => JSON.parse(l)).filter((e) => e.userAgent === UA);
  if (entries.some((e) => e.ts < started)) fail('/_log?since returned older entries');
  for (const [api, sys, effort] of [['chat', 'SYS_CHAT', 'high'], ['responses', 'SYS_RESPONSES', 'medium'], ['anthropic', 'SYS_ANTHROPIC', 'budget:2048'], ['gemini', 'SYS_GEMINI', 'budget:1024']]) {
    const e = entries.find((x) => x.api === api && x.system.startsWith(sys));
    const ok = e && e.effort === effort && e.userAgent === UA && e.tools.length >= 1 && e.lastUser && e.model;
    if (!ok) failed++;
    console.log(`${ok ? 'ok   ' : 'FAIL '} /_log ${api} entry (system, effort ${effort}, tools [${e?.tools}], lastUser, user-agent)`);
  }
  console.log(failed ? `selftest FAILED: ${failed} check(s)` : `selftest passed: ${checks.length + 4} checks, ${entries.length} own log entries`);
  process.exit(failed ? 1 : 0);
}

main().catch((err) => { console.error(`selftest error: ${err.message}`); process.exit(1); });
