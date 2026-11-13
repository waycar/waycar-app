// The opencode plugin's OpenCode 2 half (hooks/opencode/waycar-agent-state.js
// `setup`): pushes through `waycar opencode-push`, once per event although
// every loaded Location runs its own instance and sees every event. Also
// checks Chat Prompt ownership for opencode/kilo nested under Zellij.
//
//   node --test plugin/test/opencode-v2-pushes.test.mjs
//
// Needs only Node 18+ and a POSIX sh. The Rust half has unit tests in
// rust/opencode_hook.rs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath, pathToFileURL } from "node:url";

const SOURCE = fileURLToPath(new URL("../hooks/opencode/waycar-agent-state.js", import.meta.url));

const root = mkdtempSync(join(tmpdir(), "waycar-oc2-"));
const log = join(root, "pushes.log");
mkdirSync(join(root, "plugin", "bin"), { recursive: true });
// One line per run: the arguments, then the stdin JSON.
writeFileSync(join(root, "plugin", "bin", "waycar"), `#!/bin/sh\nprintf '%s\\t%s\\n' "$*" "$(cat)" >> '${log}'\n`);
chmodSync(join(root, "plugin", "bin", "waycar"), 0o755);

let copies = 0;
/** Install the plugin the way install.sh does and import that copy. */
async function load(agent = "opencode") {
  const file = join(root, `waycar-agent-state-${(copies += 1)}.js`);
  const content = readFileSync(SOURCE, "utf8")
    .replaceAll('"__WAYCAR_PLUGIN_ROOT__"', JSON.stringify(join(root, "plugin")))
    .replaceAll('"__WAYCAR_AGENT__"', JSON.stringify(agent));
  writeFileSync(file, content);
  return import(pathToFileURL(file).href);
}

/** One server: its event bus, sessions and messages, shared by every Location's ctx. */
function server(sessions, messages = {}) {
  const subscribers = new Set();
  const subscriptions = [];
  return {
    subscriptions,
    emit(event) {
      for (const deliver of subscribers) deliver(event);
    },
    ctx(directory) {
      return {
        location: { directory },
        session: {
          get: async ({ sessionID }) => {
            if (!sessions[sessionID]) throw new Error("NotFound");
            return sessions[sessionID];
          },
          context: async ({ sessionID }) => messages[sessionID] ?? [],
        },
        event: {
          subscribe({ types, signal }) {
            subscriptions.push({ types, signal });
            const queue = [];
            let wake;
            const deliver = (event) => {
              queue.push(event);
              wake?.();
            };
            subscribers.add(deliver);
            signal.addEventListener("abort", () => {
              subscribers.delete(deliver);
              wake?.();
            });
            return {
              async *[Symbol.asyncIterator]() {
                while (!signal.aborted) {
                  if (queue.length) yield queue.shift();
                  else await new Promise((resolve) => (wake = resolve));
                }
              },
            };
          },
        },
      };
    },
  };
}

function pushes() {
  if (!existsSync(log)) return [];
  return readFileSync(log, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [args, input] = line.split("\t");
      return { args, input: JSON.parse(input) };
    });
}

async function settle(count) {
  for (let waited = 0; pushes().length < count && waited < 10_000; waited += 20) await delay(20);
  await delay(300); // and nothing more arrives
  return pushes();
}

const TOP = "ses_top0001";
const CHILD = "ses_child0001";
const GRANDCHILD = "ses_grandchild0001";
const sessions = {
  [TOP]: { id: TOP, title: "Top" },
  [CHILD]: { id: CHILD, parentID: TOP },
  [GRANDCHILD]: { id: GRANDCHILD, parentID: CHILD },
  // Corrupt parents never push: a cycle, and a parent that is gone.
  ses_loopA: { id: "ses_loopA", parentID: "ses_loopB" },
  ses_loopB: { id: "ses_loopB", parentID: "ses_loopA" },
  ses_orphan: { id: "ses_orphan", parentID: "ses_gone" },
};
const messages = {
  [TOP]: [
    { type: "user", text: "earlier" },
    { type: "assistant", content: [{ type: "text", text: "An older turn" }] },
    { type: "user", text: "run WAYCAR_TOOL" },
    { type: "assistant", content: [{ type: "text", text: "Running it. " }, { type: "tool", name: "shell" }] },
    { type: "assistant", content: [{ type: "reasoning", text: "hmm" }, { type: "text", text: "The final " }, { type: "text", text: "reply" }] },
    { type: "assistant", content: [{ type: "tool", name: "shell" }] },
    { type: "idle", outcome: "succeeded" },
  ],
};

test("two Locations push once per event; subagent approvals push as their root; subagent and interrupted turns push nothing", async () => {
  rmSync(log, { force: true });
  const { default: plugin } = await load();
  const oc = server(sessions, messages);
  const cleanups = [plugin.setup(oc.ctx("/home/u/proj")), plugin.setup(oc.ctx("/tmp/other"))];
  assert.equal(oc.subscriptions.length, 2);
  assert.deepEqual(oc.subscriptions[0].types, [
    "permission.asked",
    "form.created",
    "session.execution.succeeded",
    "session.execution.failed",
  ]);

  const events = [
    { id: "evt_perm", type: "permission.asked", data: { id: "per_1", sessionID: TOP, action: "shell", resources: ["echo"] } },
    { id: "evt_child_perm", type: "permission.asked", data: { id: "per_2", sessionID: CHILD, action: "shell", resources: [] } },
    { id: "evt_question", type: "form.created", data: { form: { id: "frm_1", sessionID: TOP, metadata: { kind: "question" }, fields: [] } } },
    { id: "evt_grandchild_question", type: "form.created", data: { form: { id: "frm_3", sessionID: GRANDCHILD, metadata: { kind: "question" }, fields: [] } } },
    { id: "evt_loop_perm", type: "permission.asked", data: { id: "per_3", sessionID: "ses_loopA", action: "shell", resources: [] } },
    { id: "evt_orphan_perm", type: "permission.asked", data: { id: "per_4", sessionID: "ses_orphan", action: "shell", resources: [] } },
    { id: "evt_grandchild_failed", type: "session.execution.failed", data: { sessionID: GRANDCHILD, error: {} } },
    { id: "evt_form", type: "form.created", data: { form: { id: "frm_2", sessionID: TOP, metadata: { kind: "other" }, fields: [] } } },
    { id: "evt_interrupted", type: "session.execution.interrupted", data: { sessionID: TOP, reason: "user" } },
    { id: "evt_child_done", type: "session.execution.succeeded", data: { sessionID: CHILD } },
    { id: "evt_gone", type: "session.execution.succeeded", data: { sessionID: "ses_unknown" } },
    { id: "evt_done", type: "session.execution.succeeded", data: { sessionID: TOP } },
  ];
  for (const event of events) oc.emit(event);

  // The runs are concurrent, so their order is not.
  const byKey = (a, b) => a.input.key.localeCompare(b.input.key);
  assert.deepEqual((await settle(5)).sort(byKey), [
    { args: "opencode-push blocked", input: { session_id: TOP, key: "evt_child_perm" } },
    { args: "opencode-push done", input: { session_id: TOP, key: "evt_done", reply: "The final reply" } },
    { args: "opencode-push blocked", input: { session_id: TOP, key: "evt_grandchild_question" } },
    { args: "opencode-push blocked", input: { session_id: TOP, key: "evt_perm" } },
    { args: "opencode-push blocked", input: { session_id: TOP, key: "evt_question" } },
  ]);

  // A failed turn is Done too; a plugin reload (a fresh import, a third
  // instance) shares the registry, so a replayed event stays claimed.
  const { default: reloaded } = await load();
  cleanups.push(reloaded.setup(oc.ctx("/home/u/proj")));
  oc.emit(events.at(-1));
  oc.emit({ id: "evt_failed", type: "session.execution.failed", data: { sessionID: TOP, error: {} } });
  const after = await settle(6);
  assert.equal(after.length, 6);
  assert.deepEqual(after.filter((push) => push.input.key === "evt_failed"), [
    { args: "opencode-push done", input: { session_id: TOP, key: "evt_failed", reply: "The final reply" } },
  ]);

  for (const cleanup of cleanups) cleanup();
  assert.ok(oc.subscriptions.every(({ signal }) => signal.aborted), "cleanup aborts every subscription");
});

test("kilo and an uninstalled copy subscribe to nothing; V1 keeps its exports", async () => {
  const oc = server(sessions);
  const { default: kilo } = await load("kilo");
  assert.equal(kilo.setup(oc.ctx("/p")), undefined);
  const raw = await import(pathToFileURL(SOURCE).href);
  assert.equal(raw.default.setup(oc.ctx("/p")), undefined);
  assert.equal(oc.subscriptions.length, 0);

  const module = await load();
  assert.deepEqual(Object.keys(module).sort(), ["WaycarAgentStatePlugin", "default"]);
  assert.equal(module.default.server, module.WaycarAgentStatePlugin);
  assert.equal(module.default.id, "waycar.opencode");
});

test("opencode/kilo Chat Mode survives inherited Zellij variables in herdr/core but stays off owned Zellij panes", async () => {
  const source = fileURLToPath(new URL("../hooks/opencode/waycar-chat-prompt.js", import.meta.url));
  const keys = ["ZELLIJ_PANE_ID", "ZELLIJ_SESSION_NAME", "TMUX_PANE", "HERDR_PANE_ID", "HC_TERMINAL_ID", "HC_SESSION", "WAYCAR_TEST_ZELLIJ_EXIT"];
  const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  try {
    for (const agent of ["opencode", "kilo"]) {
      for (const [backend, vars, owned, expected] of [
        ["herdr", { HERDR_PANE_ID: "w1:p1" }, 125, "chat prompt"],
        ["core", { HC_TERMINAL_ID: "t1", HC_SESSION: "default" }, 125, "chat prompt"],
        ["zellij", { HERDR_PANE_ID: "w1:p1", HC_TERMINAL_ID: "t1" }, 0, undefined],
      ]) {
        for (const key of keys) delete process.env[key];
        Object.assign(process.env, { ZELLIJ_PANE_ID: "0", ZELLIJ_SESSION_NAME: "outer", WAYCAR_TEST_ZELLIJ_EXIT: String(owned), ...vars });
        const dir = join(root, `${agent}-${backend}`);
        mkdirSync(join(dir, "bin"), { recursive: true });
        mkdirSync(join(dir, "chat"));
        const cli = join(dir, "bin", "waycar");
        writeFileSync(cli, `#!/bin/sh\ncase "$*" in\n  'hook-status opencode owns-zellij') exit "$WAYCAR_TEST_ZELLIJ_EXIT" ;;\n  config-dir) printf '%s' '${dir}' ;;\n  *) exit 99 ;;\nesac\n`);
        chmodSync(cli, 0o755);
        for (const id of ["w1:p1", "hc:t1"]) {
          writeFileSync(join(dir, "chat", `${Buffer.from(id).toString("base64url")}.json`), JSON.stringify({ prompt: "chat prompt" }));
        }
        const file = join(dir, "chat-prompt.js");
        writeFileSync(file, readFileSync(source, "utf8").replaceAll('"__WAYCAR_PLUGIN_ROOT__"', JSON.stringify(dir)));
        const module = await import(pathToFileURL(file).href);
        const plugin = await module.WaycarChatPromptPlugin();
        const output = { system: [] };
        await plugin["experimental.chat.system.transform"]({ sessionID: "s1" }, output);
        assert.deepEqual(output.system, expected ? [expected] : [], `${agent} in ${backend}`);
      }
    }
  } finally {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  }
});

test.after(() => rmSync(root, { recursive: true, force: true }));
