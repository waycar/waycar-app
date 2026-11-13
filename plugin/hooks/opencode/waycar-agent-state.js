// installed by waycar
// managed by waycar: `waycar hooks install` overwrites this file and
// `waycar hooks uninstall` removes it. Add your own plugins beside it.
//
// Agent Status for Waycar's tmux and herdr-core backends from opencode. Mirrors herdr's
// opencode integration: a chat message or a busy session status → working;
// permission or question asked, or a session error → blocked; replies →
// working again (from blocked only); tool events keep working but never
// revive idle or done; the session going idle → done after a turn, idle
// otherwise. Child sessions only report blocked/working against their root.
// Status writes go through `<plugin>/bin/waycar-hook opencode <status>`,
// which checks this process's tty against the pane (or herdr-core terminal),
// raises @waycar_seq and starts `waycar notify`. The root session id goes to
// @waycar_session (in a core terminal: `waycar hook-status opencode session`,
// which sets the waycar.session label).
// opencode disposes its instance on every exit (Ctrl+C, /exit, the pane
// closing; verified live on 1.18.34, where process exit handlers never run
// in the server worker): `dispose` releases the pane, after any report still
// queued, and nothing reports after it until opencode starts the plugin again.
// No-op outside tmux and herdr-core, inside a herdr pane that is no core
// terminal and in an Agent Summary run (WAYCAR_SUMMARY=1).

import { execFile, spawn } from "node:child_process";
import path from "node:path";

const PLUGIN_ROOT = "__WAYCAR_PLUGIN_ROOT__";
// opencode, or kilo: Kilo Code is opencode under another name, and loads this
// same plugin from ~/.config/kilo/plugins (docs/research/harnesses/kilo.md).
const AGENT = "__WAYCAR_AGENT__";
// A tmux pane, unless herdr owns this one; and a herdr-core terminal. A core
// started in a tmux or herdr pane hands every terminal that pane's TMUX_PANE
// and HERDR_*, so neither can rule the other out: waycar-hook and ownsPane
// check the tty, and the core path is taken when the tmux pane is not ours.
const pane = process.env.HERDR_PANE_ID || process.env.HERDR_ENV ? undefined : process.env.TMUX_PANE;
const coreTerminal = process.env.HC_TERMINAL_ID;
const zellijPane = process.env.ZELLIJ_PANE_ID && process.env.ZELLIJ_SESSION_NAME;

// Child session id → parent id, so child events cannot replace the root.
const childSessions = new Map();
const CHILD_EVENT_STATUS = new Map([
  ["permission.asked", "blocked"],
  ["question.asked", "blocked"],
  ["permission.replied", "working-if-blocked"],
  ["question.replied", "working-if-blocked"],
  ["question.rejected", "working-if-blocked"],
]);

const WORKING_SESSION_STATUSES = new Set(["active", "busy", "pending", "retry", "running", "streaming", "working"]);

let chain = Promise.resolve();
let active = false;
// The last report came from an idle signal. opencode ends a turn with both
// `session.status {type:idle}` and `session.idle`, in the same millisecond:
// the second must not turn that turn's done into idle.
let settled = false;
let reportedSession;
let paneOwned;
let released = false;

function enqueue(job) {
  chain = chain.then(job, job).catch(() => {});
}

// stdin is /dev/null: waycar-hook drains stdin before anything else.
function runWaycar(bin, args) {
  return new Promise((resolve) => {
    try {
      const child = spawn(path.join(PLUGIN_ROOT, "bin", bin), args, { stdio: "ignore" });
      child.on("error", () => resolve());
      child.on("exit", () => resolve());
    } catch {
      resolve();
    }
  });
}

function waycarHook(status) {
  return runWaycar("waycar-hook", [AGENT, status]);
}

function capture(file, args) {
  return new Promise((resolve) => {
    execFile(file, args, { timeout: 2000 }, (error, stdout) => resolve(error ? undefined : String(stdout)));
  });
}

// The pane is ours only when this process's controlling tty is the pane's tty.
function ownsPane() {
  paneOwned ??= (async () => {
    if (!pane) return false;
    const own = (await capture("ps", ["-o", "tty=", "-p", String(process.pid)]))?.trim();
    if (!own || own === "?" || own === "??" || own === "-") return false;
    const paneTty = (await capture("tmux", ["display-message", "-p", "-t", pane, "#{pane_tty}"]))?.trim();
    return !!paneTty && paneTty.replace(/^\/dev\//, "") === own.replace(/^\/dev\//, "");
  })();
  return paneOwned;
}

/**
 * Report a status. `working`, `blocked` and `done` mark the turn active or
 * over; an idle session reports done only after a turn, idle otherwise, and
 * once per settle.
 */
function report(status) {
  if (released) return;
  let next = status;
  if (status === "idle") {
    if (settled) return;
    next = active ? "done" : "idle";
    active = false;
    settled = true;
  } else if (status === "working" || status === "blocked") {
    active = true;
    settled = false;
  }
  enqueue(() => waycarHook(next));
}

function reportSession(sessionID) {
  if (released || !sessionID || sessionID === reportedSession) return;
  reportedSession = sessionID;
  // tmux splits an argument that ends in an unescaped `;`.
  const value = sessionID.endsWith(";") ? `${sessionID.slice(0, -1)}\\;` : sessionID;
  enqueue(async () => {
    if (!(await ownsPane())) {
      // Not that tmux pane (a core terminal inherits the TMUX_PANE of what
      // started the core): `waycar hook-status` checks the tty against the
      // core terminal and labels it.
      if (coreTerminal || zellijPane) await runWaycar("waycar", ["hook-status", AGENT, "session", sessionID]);
      return;
    }
    await capture("tmux", ["set-option", "-p", "-t", pane, "@waycar_agent", AGENT, ";",
      "set-option", "-p", "-t", pane, "@waycar_session", value]);
  });
}

// Unsets every @waycar_* option once the reports before it have run.
function release() {
  released = true;
  active = false;
  settled = false;
  reportedSession = undefined;
  enqueue(() => waycarHook("release"));
  return chain;
}

function rootOf(sessionID) {
  let root = sessionID;
  while (childSessions.has(root)) root = childSessions.get(root);
  return root;
}

export const WaycarAgentStatePlugin = async () => {
  const env = process.env;
  if ((!pane && !coreTerminal && !zellijPane) || env.WAYCAR_SUMMARY || PLUGIN_ROOT.startsWith("__")) return {};
  released = false;

  return {
    dispose: release,
    "chat.message": async ({ sessionID }) => {
      if (sessionID && childSessions.has(sessionID)) return;
      reportSession(sessionID);
      report("working");
    },
    event: async ({ event }) => {
      const type = event?.type;
      const properties = event?.properties ?? {};
      const sessionID = typeof properties.sessionID === "string" && properties.sessionID ? properties.sessionID : undefined;

      const info = properties.info;
      if (info?.id && info.parentID) childSessions.set(info.id, info.parentID);
      if (sessionID && childSessions.has(sessionID)) {
        const status = CHILD_EVENT_STATUS.get(type);
        if (status) {
          reportSession(rootOf(sessionID));
          report(status);
        }
        return;
      }

      switch (type) {
        // session.created is server-global (an attached client may own it);
        // the session is reported once this pane updates or prompts it.
        case "session.updated":
          reportSession(sessionID);
          break;
        case "session.status": {
          const kind = typeof properties.status === "string" ? properties.status : properties.status?.type;
          const normalized = typeof kind === "string" ? kind.toLowerCase() : undefined;
          reportSession(sessionID);
          if (normalized === "idle") report("idle");
          else if (WORKING_SESSION_STATUSES.has(normalized)) report("working");
          break;
        }
        case "tool.execute.before":
        case "tool.execute.after":
        case "session.compacted":
          report("working-if-active");
          break;
        case "permission.replied":
        case "question.replied":
        case "question.rejected":
          report("working-if-blocked");
          break;
        case "permission.asked":
        case "question.asked":
        case "session.error":
          report("blocked");
          break;
        case "session.idle":
          report("idle");
          break;
        default:
          break;
      }
    },
  };
};

// OpenCode 2 calls setup() instead of server(), inside its one shared server,
// whose environment is that of whichever client started it: no session can be
// tied to a pane, so V2 reports no Agent Status. It sends pushes instead, as
// `opencode:<sessionID>` through `waycar opencode-push`: a needs-your-OK, a
// question, and a finished turn with its reply. Pushes name top-level
// sessions: a subagent's approval or question holds up its root, so it pushes
// as that root; a subagent's finished turn pushes nothing.
const V2_EVENTS = ["permission.asked", "form.created", "session.execution.succeeded", "session.execution.failed"];

// setup() runs once per loaded Location and every instance sees every event,
// so the instances share one registry of the events already claimed. One
// server process has one globalThis, which also outlives a hot reload.
const CLAIMED_LIMIT = 256;

function claim(eventID) {
  const claimed = (globalThis.__waycarOpencodePushes ??= new Set());
  if (typeof eventID !== "string" || !eventID || claimed.has(eventID)) return false;
  claimed.add(eventID);
  if (claimed.size > CLAIMED_LIMIT) claimed.delete(claimed.values().next().value);
  return true;
}

function pushOf(event) {
  const data = event?.data ?? {};
  switch (event?.type) {
    case "permission.asked":
      return { status: "blocked", sessionID: data.sessionID };
    case "form.created":
      return data.form?.metadata?.kind === "question" ? { status: "blocked", sessionID: data.form.sessionID } : undefined;
    case "session.execution.succeeded":
    case "session.execution.failed":
      return { status: "done", sessionID: data.sessionID };
    default:
      return undefined;
  }
}

// The newest assistant text of the turn that just ended.
function replyOf(messages) {
  for (let i = (Array.isArray(messages) ? messages.length : 0) - 1; i >= 0; i -= 1) {
    const message = messages[i];
    if (message?.type === "user") return undefined;
    if (message?.type !== "assistant" || !Array.isArray(message.content)) continue;
    const text = message.content.filter((part) => part?.type === "text" && typeof part.text === "string").map((part) => part.text).join("").trim();
    if (text) return text;
  }
  return undefined;
}

// The event goes on stdin: a reply can be long and private.
function runWaycarWithInput(args, input) {
  return new Promise((resolve) => {
    try {
      const child = spawn(path.join(PLUGIN_ROOT, "bin", "waycar"), args, { stdio: ["pipe", "ignore", "ignore"] });
      child.on("error", () => resolve());
      child.on("exit", () => resolve());
      child.stdin.on("error", () => {});
      child.stdin.end(JSON.stringify(input));
    } catch {
      resolve();
    }
  });
}

// Bounds the walk up a session's parents, which also ends a cycle.
const MAX_SESSION_DEPTH = 16;

// The top-level session above `sessionID` (itself when it has no parent).
async function rootSession(ctx, sessionID) {
  let session = await ctx.session.get({ sessionID });
  for (let depth = 0; session?.parentID; depth += 1) {
    if (depth >= MAX_SESSION_DEPTH) return undefined;
    session = await ctx.session.get({ sessionID: session.parentID });
  }
  return typeof session?.id === "string" && session.id ? session.id : undefined;
}

async function pushEvent(ctx, event) {
  const push = pushOf(event);
  if (!push || typeof push.sessionID !== "string" || !push.sessionID || !claim(event.id)) return;
  let sessionID = push.sessionID;
  if (push.status === "blocked") {
    sessionID = await rootSession(ctx, sessionID);
    if (!sessionID) return;
  } else {
    const session = await ctx.session.get({ sessionID });
    if (!session || session.parentID) return; // a subagent's turn
  }
  const reply = push.status === "done" ? replyOf(await ctx.session.context({ sessionID }).catch(() => undefined)) : undefined;
  await runWaycarWithInput(["opencode-push", push.status], { session_id: sessionID, key: event.id, reply });
}

// Not a named export, so OpenCode 1 sees exactly the exports it saw before.
function setupServerPushes(ctx) {
  if (AGENT !== "opencode" || PLUGIN_ROOT.startsWith("__") || typeof ctx?.event?.subscribe !== "function") return undefined;
  const controller = new AbortController();
  (async () => {
    for await (const event of ctx.event.subscribe({ types: V2_EVENTS, signal: controller.signal })) {
      pushEvent(ctx, event).catch(() => {});
    }
  })().catch(() => {});
  return () => controller.abort();
}

// V1 (1.18.29+) calls server(), V2 setup().
export default {
  id: `waycar.${AGENT}`,
  server: WaycarAgentStatePlugin,
  setup: setupServerPushes,
};
