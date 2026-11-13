// installed by waycar
// managed by waycar: `waycar hooks install` overwrites this file and
// `waycar hooks uninstall` removes it. Add your own extensions beside it.
// @ts-nocheck
//
// Agent Status for Waycar's tmux and herdr-core backends from pi. Mirrors herdr's pi
// integration: the TUI session_start reports the session (working if a run
// is in flight after a reload, else idle); agent_start → working;
// agent_settled with pi idle → done; `waycar:blocked`/`herdr:blocked` events
// from other extensions → blocked while active; session_shutdown unsets
// every @waycar_* option (core: labels). pi before 1.0 (`@mariozechner/pi-coding-agent`
// 0.73) has no ctx.mode and no agent_settled: there a session with a UI
// whose stdin and stdout are terminals counts as the TUI, and agent_end
// settles once pi reads idle, or after a retry grace period when it ended on
// an error pi retries. Status writes go through
// `<plugin>/bin/waycar-hook pi <status>`, which checks this process's tty
// against the pane (or core terminal), raises @waycar_seq and starts
// `waycar notify`. The session file goes to @waycar_session and,
// percent-encoded, @waycar_transcript (in a core terminal: `waycar
// hook-status pi session`, which sets the waycar.session and
// waycar.transcript labels). No-op outside tmux and herdr-core, inside a
// herdr pane that is no core terminal and in an Agent Summary run
// (WAYCAR_SUMMARY=1).

import { execFile, spawn } from "node:child_process";
import path from "node:path";

const PLUGIN_ROOT: string = "__WAYCAR_PLUGIN_ROOT__";
const AGENT = "pi";
// A tmux pane, unless herdr owns this one; and a herdr-core terminal. A core
// started in a tmux or herdr pane hands every terminal that pane's TMUX_PANE
// and HERDR_*, so neither can rule the other out: waycar-hook and ownsPane
// check the tty, and the core path is taken when the tmux pane is not ours.
const pane = process.env.HERDR_PANE_ID || process.env.HERDR_ENV ? undefined : process.env.TMUX_PANE;
const coreTerminal = process.env.HC_TERMINAL_ID;
const zellijPane = process.env.ZELLIJ_PANE_ID && process.env.ZELLIJ_SESSION_NAME;


type Status = "working" | "blocked" | "done" | "idle" | "release";

/** The parts of pi's extension context this file reads. */
interface AgentContext {
  mode?: string;
  hasUI?: boolean;
  isIdle?: () => boolean;
  sessionManager?: { getSessionFile?: () => unknown; getSessionId?: () => unknown };
}

interface AgentEndEvent {
  messages?: unknown;
}

function parseDurationEnv(name: string, fallback: number): number {
  const parsed = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

// pi 0.73 waits 2, 4, then 8 s (retry.baseDelayMs 2000, maxRetries 3) before
// retrying, reading idle all the while.
const retryGraceMs = parseDurationEnv("WAYCAR_PI_RETRY_GRACE_MS", 10_000);

// pi 0.73's own retry test (AgentSession._isRetryableError).
const retryableErrorPattern =
  /overloaded|provider.?returned.?error|rate.?limit|too many requests|429|500|502|503|504|service.?unavailable|server.?error|internal.?error|network.?error|connection.?error|connection.?refused|connection.?lost|websocket.?closed|websocket.?error|other side closed|fetch failed|upstream.?connect|reset before headers|socket hang up|ended without|http2 request did not get a response|timed? out|timeout|terminated|retry delay/i;

function retryable(event: AgentEndEvent | undefined): boolean {
  const messages = Array.isArray(event?.messages) ? event.messages : [];
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const message = messages[i] as { role?: unknown; stopReason?: unknown; errorMessage?: unknown } | undefined;
    if (message?.role !== "assistant") continue;
    return message.stopReason === "error" && retryableErrorPattern.test(String(message.errorMessage ?? ""));
  }
  return false;
}

let chain: Promise<void> = Promise.resolve();

function enqueue(job: () => Promise<void>): void {
  chain = chain.then(job, job).catch(() => {});
}

// stdin is /dev/null: waycar-hook drains stdin before anything else.
function runWaycar(bin: string, args: string[]): Promise<void> {
  return new Promise<void>((resolve) => {
    try {
      const child = spawn(path.join(PLUGIN_ROOT, "bin", bin), args, { stdio: "ignore" });
      child.on("error", () => resolve());
      child.on("exit", () => resolve());
    } catch {
      resolve();
    }
  });
}

function waycarHook(status: Status): Promise<void> {
  return runWaycar("waycar-hook", [AGENT, status]);
}

function capture(file: string, args: string[]): Promise<string | undefined> {
  return new Promise<string | undefined>((resolve) => {
    execFile(file, args, { timeout: 2000 }, (error, stdout) => resolve(error ? undefined : String(stdout)));
  });
}

let paneOwned: Promise<boolean> | undefined;

// The pane is ours only when this process's controlling tty is the pane's tty.
function ownsPane(): Promise<boolean> {
  paneOwned ??= (async () => {
    if (!pane) return false;
    const own = (await capture("ps", ["-o", "tty=", "-p", String(process.pid)]))?.trim();
    if (!own || own === "?" || own === "??" || own === "-") return false;
    const paneTty = (await capture("tmux", ["display-message", "-p", "-t", pane!, "#{pane_tty}"]))?.trim();
    return !!paneTty && paneTty.replace(/^\/dev\//, "") === own.replace(/^\/dev\//, "");
  })();
  return paneOwned;
}

function percentEncodePath(value: string): string {
  let out = "";
  for (const byte of Buffer.from(value, "utf8")) {
    const char = String.fromCharCode(byte);
    out += /[A-Za-z0-9\-._~/]/.test(char) ? char : `%${byte.toString(16).toUpperCase().padStart(2, "0")}`;
  }
  return out;
}

// tmux splits an argument that ends in an unescaped `;`.
function tmuxArg(value: string): string {
  return value.endsWith(";") ? `${value.slice(0, -1)}\\;` : value;
}

let reportedSession: string | undefined;

function reportSession(ctx: AgentContext | undefined): void {
  let file: unknown;
  let id: unknown;
  try {
    file = ctx?.sessionManager?.getSessionFile?.();
  } catch {
    file = undefined;
  }
  try {
    id = ctx?.sessionManager?.getSessionId?.();
  } catch {
    id = undefined;
  }
  const sessionPath =
    typeof file === "string" && (path.posix.isAbsolute(file) || path.win32.isAbsolute(file)) ? file : undefined;
  const session = sessionPath ?? (typeof id === "string" && id ? id : undefined);
  if (!session || session === reportedSession) return;
  reportedSession = session;
  enqueue(async () => {
    if (!(await ownsPane())) {
      // Not that tmux pane (a core terminal inherits the TMUX_PANE of what
      // started the core): `waycar hook-status` checks the tty against the
      // core terminal and labels it.
      if (coreTerminal || zellijPane) {
        await runWaycar("waycar", ["hook-status", AGENT, "session", session, ...(sessionPath ? [sessionPath] : [])]);
      }
      return;
    }
    const args = ["set-option", "-p", "-t", pane!, "@waycar_agent", AGENT, ";",
      "set-option", "-p", "-t", pane!, "@waycar_session", tmuxArg(session)];
    if (sessionPath) {
      args.push(";", "set-option", "-p", "-t", pane!, "@waycar_transcript", percentEncodePath(sessionPath));
    }
    await capture("tmux", args);
  });
}

export default function (pi) {
  // Neither a tmux pane nor a herdr-core terminal, an Agent Summary run, or
  // the uninstalled template: do nothing.
  const env = process.env;
  if ((!pane && !coreTerminal && !zellijPane) || env.WAYCAR_SUMMARY || PLUGIN_ROOT.startsWith("__")) return;

  let rootSession = false;
  // pi before 1.0: no ctx.mode, and agent_end stands in for agent_settled.
  let legacy = false;
  // Raised by every agent_start and session_shutdown: a pending settle check
  // from an earlier run stops.
  let runs = 0;
  let agentActive = false;
  let blockedCount = 0;
  let settled: "idle" | "done" = "idle";
  let lastStatus: Status | undefined;

  function desired(): Status {
    if (blockedCount > 0) return "blocked";
    if (agentActive) return "working";
    return settled;
  }

  function publish(force = false) {
    const next = desired();
    if (!force && next === lastStatus) return;
    lastStatus = next;
    enqueue(() => waycarHook(next));
  }

  const onBlocked = (data) => {
    if (!rootSession) return;
    blockedCount = data?.active ? blockedCount + 1 : Math.max(0, blockedCount - 1);
    publish();
  };
  pi.events?.on?.("waycar:blocked", onBlocked);
  pi.events?.on?.("herdr:blocked", onBlocked);

  pi.on("session_start", (_event, ctx: AgentContext | undefined) => {
    // TUI only: RPC, JSON and print modes are headless, and RPC still reports
    // hasUI=true, so mode is the reliable gate. Before 1.0 there is no mode;
    // RPC talks over pipes, so a UI on a terminal means the TUI.
    legacy = ctx?.mode === undefined;
    const tui = legacy
      ? ctx?.hasUI === true && process.stdin.isTTY === true && process.stdout.isTTY === true
      : ctx?.mode === "tui";
    if (!tui) return;
    rootSession = true;
    reportSession(ctx);
    // A reload can replace this extension mid-run without another agent_start.
    agentActive = ctx?.isIdle?.() === false;
    blockedCount = 0;
    settled = "idle";
    publish(true);
  });

  pi.on("agent_start", (_event, ctx: AgentContext | undefined) => {
    runs += 1;
    if (!rootSession) return;
    reportSession(ctx);
    agentActive = true;
    publish();
  });

  const settle = (ctx: AgentContext | undefined) => {
    if (!rootSession || ctx?.isIdle?.() !== true) return;
    agentActive = false;
    settled = "done";
    publish();
  };
  pi.on("agent_settled", (_event, ctx: AgentContext | undefined) => settle(ctx));
  // pi 0.73 emits agent_end while a finished run still reads as streaming, so
  // settle once it reads idle (checked every 25 ms for up to 5 s), unless
  // another run started first. After an error pi retries, it reads idle
  // through the backoff, so working holds for retryGraceMs before the first
  // check; the retry's agent_start cancels it.
  pi.on("agent_end", (event: AgentEndEvent | undefined, ctx: AgentContext | undefined) => {
    if (!legacy || !rootSession) return;
    const run = runs;
    const check = (left: number) => {
      if (run !== runs) return;
      let idle = false;
      try {
        idle = ctx?.isIdle?.() === true;
      } catch {
        return;
      }
      if (idle) settle(ctx);
      else if (left > 0) setTimeout(check, 25, left - 1).unref?.();
    };
    if (retryable(event)) setTimeout(check, retryGraceMs, 200).unref?.();
    else check(200);
  });

  pi.on("session_shutdown", () => {
    runs += 1;
    if (!rootSession) return;
    lastStatus = "release";
    enqueue(() => waycarHook("release"));
  });
}
