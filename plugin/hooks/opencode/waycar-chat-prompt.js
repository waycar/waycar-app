// installed by waycar
// managed by waycar: `waycar hooks install` overwrites this file and
// `waycar hooks uninstall` removes it. Add your own plugins beside it.
//
// Chat Prompt injection for Waycar's Chat Mode (design:
// docs/adr/0025-chat-mode-reads-harness-transcripts.md). opencode has no
// launch-time system-prompt flag and herdr's `agent.start` passes no env, so
// the Chat Prompt cannot ride the launch; instead this extension appends it
// to the system messages of every model request through opencode's
// `experimental.chat.system.transform` hook (verified against opencode
// 1.18.33: `packages/opencode/src/session/llm/request.ts` triggers it once
// per request with input `{ sessionID, model }` and output `{ system }`,
// where `system` starts as the joined base prompt and everything appended
// lands in the request).
//
// The prompt lives in the pane's Chat Marker, written by the app under
// `<plugin config dir>/chat/<pane file name>.json` as the optional `prompt`
// field. The config dir is resolved exactly as the app and every plugin hook
// resolve it, by asking the plugin's own `bin/waycar config-dir`:
// HERDR_PLUGIN_CONFIG_DIR, else the enabled `waycar` herdr plugin's
// `herdr plugin config-dir`, else `${XDG_CONFIG_HOME:-~/.config}/waycar`.
// herdr does not inject HERDR_PLUGIN_CONFIG_DIR into the Agents it starts,
// so inside a herdr pane this normally asks the herdr CLI; resolution is
// done once per process and kept, and a failed one is retried at most every
// RESOLVE_RETRY_MS. The pane comes from the process env: herdr sets
// `HERDR_PANE_ID` for the Agent processes it starts, tmux sets `TMUX_PANE`
// (the app keys tmux markers by its `tmux:%N` id) and a herdr-core terminal
// sets `HC_TERMINAL_ID` (keyed `hc:<address>`). Outside all three, or on any
// resolve, read or parse problem, this is a silent no-op: no marker, no
// prompt. Injection matches the marker's session once the app records it
// there, so the prompt survives a herdr server restart and a pane restored
// into a new terminal. Per request the marker is read again: it may be
// written after this process started. Unlike the Agent Status extension this
// never touches tmux or the status pane options (it reads the tmux pane's tty
// only to tell a tmux pane from a core terminal that inherited its TMUX_PANE).

import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const PLUGIN_ROOT = "__WAYCAR_PLUGIN_ROOT__";

/** How long after a failed config dir resolution the next request may retry it. */
const RESOLVE_RETRY_MS = 30_000;

/**
 * The unpadded base64url of the UTF-8 pane id plus `.json`, exactly matching
 * `pane_file_name` in the Host Tools (rust/atomic.rs); kept here so a request
 * needs nothing from the plugin but `bin/waycar config-dir`.
 */
export function paneFileName(paneId) {
  return `${Buffer.from(paneId, "utf8").toString("base64url")}.json`;
}

/** `ps`/`tmux` output, or undefined when the command fails. */
function capture(file, args) {
  return new Promise((resolve) => {
    execFile(file, args, { timeout: 2000 }, (error, stdout) => resolve(error ? undefined : String(stdout).trim()));
  });
}

/** Whether this process's controlling tty is the tmux pane's tty. */
async function ownsTmuxPane(pane) {
  const own = await capture("ps", ["-o", "tty=", "-p", String(process.pid)]);
  if (!own || own === "?" || own === "??" || own === "-") return false;
  const paneTty = await capture("tmux", ["display-message", "-p", "-t", pane, "#{pane_tty}"]);
  return !!paneTty && paneTty.replace(/^\/dev\//, "") === own.replace(/^\/dev\//, "");
}

/**
 * The app-side id of this process's pane, or null outside herdr, tmux and
 * herdr-core. A herdr-core terminal (`hc:<address>`, default session only)
 * inherits the TMUX_PANE and HERDR_* of whatever started the core, so with
 * HC_TERMINAL_ID set a tmux pane counts only when this process's tty is that
 * pane's, and core otherwise. HERDR_PANE_ID keeps its meaning: a herdr pane
 * whose server was started from a core terminal also carries HC_TERMINAL_ID,
 * and herdr's id stays what it was before core support.
 */
async function ownPaneId(env) {
  // No Chat Mode on an owned Zellij pane. Inherited variables alone cannot
  // suppress a herdr/core pane: native ownership checks its ancestry and tty.
  if (env.ZELLIJ_PANE_ID && env.ZELLIJ_SESSION_NAME && !(env.TMUX_PANE && (await ownsTmuxPane(env.TMUX_PANE))) &&
      (await capture(join(PLUGIN_ROOT, "bin", "waycar"), ["hook-status", "opencode", "owns-zellij"])) !== undefined) return null;
  const core = env.HC_TERMINAL_ID && !env.HERDR_PANE_ID && (!env.HC_SESSION || env.HC_SESSION === "default");
  if (core && !(env.TMUX_PANE && (await ownsTmuxPane(env.TMUX_PANE)))) {
    return `hc:${env.HC_TERMINAL_ID}`;
  }
  if (env.HERDR_PANE_ID) return env.HERDR_PANE_ID;
  if (env.TMUX_PANE) return `tmux:${env.TMUX_PANE}`;
  return null;
}

let configDir = null;
let pending = null;
let failedAt = -Infinity;

/**
 * The plugin config dir, resolved once per process (resolution may run the
 * herdr CLI, so never per request). Concurrent requests share one
 * resolution; a failure answers null and holds retries off for
 * RESOLVE_RETRY_MS.
 */
function resolveConfigDir() {
  if (configDir !== null) return configDir;
  if (pending !== null) return pending;
  if (Date.now() - failedAt < RESOLVE_RETRY_MS) return null;
  pending = new Promise((resolve, reject) => {
    execFile(
      join(PLUGIN_ROOT, "bin", "waycar"),
      ["config-dir"],
      { env: process.env, timeout: 10_000, windowsHide: true },
      (error, stdout) => {
        const dir = String(stdout ?? "").trim();
        if (error || !dir.startsWith("/") || dir.includes("\n")) reject(error ?? new Error("no config dir"));
        else resolve(dir);
      },
    );
  })
    .then(
      (dir) => {
        configDir = dir;
        return configDir;
      },
      () => {
        failedAt = Date.now();
        return null;
      },
    )
    .finally(() => {
      pending = null;
    });
  return pending;
}

export const WaycarChatPromptPlugin = async () => {
  return {
    "experimental.chat.system.transform": async (input, output) => {
      const pane = await ownPaneId(process.env);
      if (pane === null) return;
      const dir = await resolveConfigDir();
      if (dir === null) return;
      let marker;
      try {
        marker = JSON.parse(await readFile(join(dir, "chat", paneFileName(pane)), "utf8"));
      } catch {
        return;
      }
      if (marker === null || typeof marker !== "object") return;
      if (typeof marker.prompt !== "string" || marker.prompt.length === 0) return;
      const session = marker.session;
      if (session !== null && session !== undefined) {
        if (session.kind !== "id" || session.value !== input?.sessionID) return;
      }
      output?.system?.push(marker.prompt);
    },
  };
};

export default {
  id: "waycar.chat-prompt",
  server: WaycarChatPromptPlugin,
  setup() {},
};