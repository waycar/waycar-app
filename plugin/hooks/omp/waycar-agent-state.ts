// installed by waycar
// managed by waycar: `waycar hooks install` overwrites this file and
// `waycar hooks uninstall` removes it. Add your own extensions beside it.
// @ts-nocheck
//
// Agent Status for Waycar's tmux and herdr-core backends from omp. Mirrors herdr's omp
// integration: agent_start → working; tool_approval_requested and the `ask`
// tool → blocked, resolved → working; agent_end (unless willContinue, after a
// 250 ms debounce) → done; a retryable provider error holds working for a
// grace period, then blocked; session_shutdown unsets every @waycar_* option
// (core: labels).
// Status writes go through `<plugin>/bin/waycar-hook omp <status>`, which
// checks this process's tty against the pane (or core terminal), raises
// @waycar_seq and starts `waycar notify`. The session file goes to
// @waycar_session and, percent-encoded, @waycar_transcript (in a core
// terminal: `waycar hook-status omp session`, which sets the waycar.session
// and waycar.transcript labels). No-op outside tmux and herdr-core, inside a
// herdr pane that is no core terminal, for an omp started from another omp's
// shell (OMPCODE=1), and in an Agent Summary run (WAYCAR_SUMMARY=1).

import { execFile, spawn } from "node:child_process";
import path from "node:path";

const PLUGIN_ROOT: string = "__WAYCAR_PLUGIN_ROOT__";
const AGENT = "omp";
// A tmux pane, unless herdr owns this one; and a herdr-core terminal. A core
// started in a tmux or herdr pane hands every terminal that pane's TMUX_PANE
// and HERDR_*, so neither can rule the other out: waycar-hook and ownsPane
// check the tty, and the core path is taken when the tmux pane is not ours.
const pane = process.env.HERDR_PANE_ID || process.env.HERDR_ENV ? undefined : process.env.TMUX_PANE;
const coreTerminal = process.env.HC_TERMINAL_ID;
const zellijPane = process.env.ZELLIJ_PANE_ID && process.env.ZELLIJ_SESSION_NAME;


type Status = "working" | "blocked" | "done" | "idle" | "release";

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

function parseDurationEnv(name: string, fallback: number): number {
  const parsed = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

const settleDebounceMs = parseDurationEnv("WAYCAR_OMP_IDLE_DEBOUNCE_MS", 250);
const retryGraceMs = parseDurationEnv("WAYCAR_OMP_RETRY_GRACE_MS", 2500);
type Timer = NodeJS.Timeout;

/** The parts of omp's extension context this file reads. */
interface AgentContext {
  hasUI?: boolean;
  isIdle?: () => boolean;
  sessionManager?: { getSessionFile?: () => unknown; getSessionId?: () => unknown };
}

interface AgentEndEvent {
  willContinue?: boolean;
  messages?: unknown;
}

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

export default function (pi) {
  // Neither a tmux pane nor a herdr-core terminal, a nested omp
  // (OMPCODE=1), an Agent Summary run, or the uninstalled template: do
  // nothing.
  const env = process.env;
  if ((!pane && !coreTerminal && !zellijPane) || env.OMPCODE === "1" || env.WAYCAR_SUMMARY || PLUGIN_ROOT.startsWith("__")) return;

  let rootSession = false;
  let agentActive = false;
  let retryHold = false;
  let failureBlocked = false;
  let blockedCount = 0;
  let settled: "idle" | "done" = "idle";
  let lastStatus: Status | undefined;
  let settleTimer: Timer | undefined;
  let retryTimer: Timer | undefined;

  function clearTimers() {
    clearTimeout(settleTimer);
    clearTimeout(retryTimer);
    settleTimer = undefined;
    retryTimer = undefined;
  }

  function desired(): Status {
    if (blockedCount > 0 || failureBlocked) return "blocked";
    if (agentActive || retryHold) return "working";
    return settled;
  }

  function publish(force = false) {
    const next = desired();
    if (!force && next === lastStatus) return;
    lastStatus = next;
    enqueue(() => waycarHook(next));
  }

  function activateRoot(ctx: AgentContext | undefined): boolean {
    if (rootSession) return true;
    if (ctx?.hasUI !== true) return false;
    rootSession = true;
    return true;
  }

  function resetSession() {
    clearTimers();
    agentActive = false;
    retryHold = false;
    failureBlocked = false;
    blockedCount = 0;
    settled = "idle";
  }

  function block() {
    clearTimers();
    blockedCount += 1;
    publish();
  }

  function unblock() {
    blockedCount = Math.max(0, blockedCount - 1);
    publish();
  }

  const onBlocked = (data) => {
    if (!rootSession) return;
    if (data?.active) block();
    else unblock();
  };
  pi.events?.on?.("waycar:blocked", onBlocked);
  pi.events?.on?.("herdr:blocked", onBlocked);

  pi.on("session_start", (_event, ctx) => {
    if (!activateRoot(ctx)) return;
    reportSession(ctx);
    // A reload can replace this extension mid-run without another agent_start.
    agentActive = ctx?.isIdle?.() === false;
    publish(true);
  });

  pi.on("session_switch", (_event, ctx) => {
    if (!activateRoot(ctx)) return;
    resetSession();
    reportSession(ctx);
    publish(true);
  });

  pi.on("agent_start", (_event, ctx) => {
    if (!activateRoot(ctx)) return;
    reportSession(ctx);
    clearTimers();
    retryHold = false;
    failureBlocked = false;
    agentActive = true;
    publish();
  });

  pi.on("tool_approval_requested", (_event, ctx) => {
    if (activateRoot(ctx)) block();
  });

  pi.on("tool_approval_resolved", (_event, ctx) => {
    if (activateRoot(ctx)) unblock();
  });

  pi.on("tool_execution_start", (event, ctx) => {
    if (event?.toolName === "ask" && activateRoot(ctx)) block();
  });

  pi.on("tool_execution_end", (event, ctx) => {
    if (event?.toolName === "ask" && activateRoot(ctx)) unblock();
  });

  pi.on("agent_end", (event) => {
    // Duplicate or late ends arrive while a retry hold keeps the pane working.
    if (!rootSession || !agentActive) return;
    // A continuation is already scheduled, so this end is not a settle.
    if (event?.willContinue === true) return;
    agentActive = false;
    clearTimers();
    if (retryable(event)) {
      retryHold = true;
      failureBlocked = false;
      publish();
      retryTimer = setTimeout(() => {
        retryTimer = undefined;
        retryHold = false;
        failureBlocked = true;
        publish();
      }, retryGraceMs);
      retryTimer.unref?.();
      return;
    }
    retryHold = false;
    failureBlocked = false;
    settleTimer = setTimeout(() => {
      settleTimer = undefined;
      settled = "done";
      publish();
    }, settleDebounceMs);
    settleTimer.unref?.();
  });

  pi.on("session_shutdown", () => {
    if (!rootSession) return;
    clearTimers();
    lastStatus = "release";
    enqueue(() => waycarHook("release"));
  });
}
