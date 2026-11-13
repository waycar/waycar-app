//! The event tables of every agent kind and the constants the hook files
//! share (the top of agent-hooks.js).

/// Placeholder in the extension templates, replaced by the plugin root's JSON string.
pub const PLUGIN_ROOT_PLACEHOLDER: &str = "\"__WAYCAR_PLUGIN_ROOT__\"";
/// Placeholder in the extension templates, replaced by the agent kind's JSON string.
pub const AGENT_PLACEHOLDER: &str = "\"__WAYCAR_AGENT__\"";
/// Marker line every extension file we install carries.
pub const EXTENSION_MARKER: &str = "installed by waycar";

/// The agent kinds the hooks cover, in the order the commands report them.
pub const HOOK_AGENTS: [&str; 17] = [
    "claude", "codex", "omp", "pi", "opencode", "copilot", "qwen", "gemini", "grok", "agy",
    "hermes", "kilo", "cline", "cursor", "devin", "kiro", "muse",
];

/// The action that runs hook-session.js instead of a waycar-hook status.
pub const SESSION: &str = "session";

pub const HOOK_TIMEOUT_SEC: u32 = 10;
/// Codex clamps SessionEnd and Interrupt hooks to 1..3 s.
pub const CODEX_SHORT_EVENTS: [&str; 2] = ["SessionEnd", "Interrupt"];
pub const CODEX_SHORT_TIMEOUT_SEC: u32 = 3;

/// `(event, matcher, status)`: `SESSION` runs hook-session.js, anything else
/// is a waycar-hook status.
pub type Entry = (&'static str, Option<&'static str>, &'static str);

/// Claude Code entries, in install order. PreToolUse skips AskUserQuestion
/// and ExitPlanMode, which wait on the user. SubagentStop and PostToolBatch
/// are deliberately absent.
pub const CLAUDE_ENTRIES: &[Entry] = &[
    ("SessionStart", None, SESSION),
    ("UserPromptSubmit", None, "working"),
    (
        "PreToolUse",
        Some("^(?!(AskUserQuestion|ExitPlanMode)$)"),
        "working-if-active",
    ),
    ("PermissionRequest", None, "blocked"),
    (
        "Notification",
        Some("permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"),
        "blocked",
    ),
    ("Notification", Some("idle_prompt"), "idle-if-working"),
    ("PostToolUse", None, "working-if-blocked"),
    ("PostToolUseFailure", None, "working-if-blocked"),
    ("ElicitationResult", None, "working-if-blocked"),
    ("Stop", None, "done"),
    ("StopFailure", None, "done"),
    ("SessionEnd", None, "release"),
];

/// Codex entries, in install order: `(event, status)`.
pub const CODEX_ENTRIES: &[(&str, &str)] = &[
    ("SessionStart", SESSION),
    ("UserPromptSubmit", "working"),
    ("PreToolUse", "working-if-active"),
    ("PermissionRequest", "blocked"),
    ("PostToolUse", "working-if-blocked"),
    ("Stop", "done"),
    ("Interrupt", "idle"),
    ("SessionEnd", "release"),
];

/// Qwen Code 0.25.1. `Notification` is left out: its `idle_prompt` fires
/// mid-turn after every PreToolUse, and `PermissionRequest` already fires
/// only while an approval dialog shows.
pub const QWEN_ENTRIES: &[Entry] = &[
    ("SessionStart", None, SESSION),
    ("UserPromptSubmit", None, "working"),
    ("PreToolUse", None, "working-if-active"),
    ("PermissionRequest", None, "blocked"),
    ("PostToolUse", None, "working-if-blocked"),
    ("PostToolUseFailure", None, "working-if-blocked"),
    ("Stop", None, "done"),
    ("StopFailure", None, "done"),
    ("SessionEnd", None, "release"),
];

/// Muse Code 1.4.6. SessionStart is left out: it fires only with a new
/// session's first prompt, never on resume, while every UserPromptSubmit
/// names the session. PermissionRequest fires as the approval dialog opens;
/// Notification `permission_prompt` follows ~6 s later even when already
/// answered. Esc fires Interrupt, never Stop.
pub const MUSE_ENTRIES: &[Entry] = &[
    ("UserPromptSubmit", None, SESSION),
    ("PreToolUse", None, "working-if-active"),
    ("PermissionRequest", None, "blocked"),
    ("PostToolUse", None, "working-if-blocked"),
    ("PostToolUseFailure", None, "working-if-blocked"),
    ("Stop", None, "done"),
    ("StopFailure", None, "done"),
    ("Interrupt", None, "idle"),
    ("SessionEnd", None, "release"),
];

/// Gemini CLI 0.63.0: its own event names. PreCompress (fires every turn) is
/// left out; SessionEnd fires up to three times, which release tolerates.
/// BeforeAgent re-records the transcript path, since a resumed session's
/// SessionStart names a file Gemini never creates.
pub const GEMINI_ENTRIES: &[Entry] = &[
    ("SessionStart", Some("*"), SESSION),
    ("BeforeAgent", Some("*"), SESSION),
    ("BeforeTool", Some("*"), "working-if-active"),
    ("Notification", Some("*"), SESSION),
    ("AfterTool", Some("*"), "working-if-blocked"),
    ("AfterAgent", Some("*"), "done"),
    ("SessionEnd", Some("*"), "release"),
];

/// Grok Build 1.0.50. Grok's matchers are look-ahead-free regexes, so
/// Notification types are told apart in hook-session.js. Stop also fires
/// about 50 ms after SessionEnd, hence `done-if-active`.
pub const GROK_ENTRIES: &[Entry] = &[
    ("SessionStart", None, SESSION),
    ("UserPromptSubmit", None, SESSION),
    ("PreToolUse", None, "working-if-active"),
    ("Notification", None, SESSION),
    ("PostToolUse", None, "working-if-blocked"),
    ("PostToolUseFailure", None, "working-if-blocked"),
    ("Stop", None, "done-if-active"),
    ("StopFailure", None, "done-if-active"),
    ("StopCancelled", None, "idle"),
    ("SessionEnd", None, SESSION),
];

/// GitHub Copilot CLI 1.0.95, PascalCase events so payloads are
/// Claude-shaped. PermissionRequest is left out: it fires for auto-approved
/// tools too. SessionStart comes lazily after the first UserPromptSubmit.
pub const COPILOT_ENTRIES: &[Entry] = &[
    ("UserPromptSubmit", None, "working"),
    ("SessionStart", None, SESSION),
    ("PreToolUse", None, "working-if-active"),
    ("Notification", None, SESSION),
    ("PostToolUse", None, "working-if-blocked"),
    ("Stop", None, "done"),
    ("SessionEnd", None, SESSION),
];

/// Cursor CLI: no approval-pending event, so blocked comes only from the
/// app's screen detection.
pub const CURSOR_ENTRIES: &[Entry] = &[
    ("sessionStart", None, SESSION),
    ("beforeSubmitPrompt", None, "working"),
    ("preToolUse", None, "working-if-active"),
    ("stop", None, "done-if-active"),
    ("sessionEnd", None, "release"),
];

/// Devin CLI: Claude's events and format.
pub const DEVIN_ENTRIES: &[Entry] = &[
    ("SessionStart", None, SESSION),
    ("UserPromptSubmit", None, "working"),
    ("PreToolUse", None, "working-if-active"),
    ("PermissionRequest", None, "blocked"),
    ("PostToolUse", None, "working-if-blocked"),
    ("Stop", None, "done"),
    ("SessionEnd", None, "release"),
];

/// Kiro CLI V3 hooks: `~/.kiro/hooks/*.json` is read by the V3 engine only,
/// and there is no approval event.
pub const KIRO_ENTRIES: &[Entry] = &[
    ("SessionStart", None, SESSION),
    ("UserPromptSubmit", None, "working"),
    ("PreToolUse", None, "working-if-active"),
    ("Stop", None, "done"),
    ("SessionEnd", None, "release"),
];

/// Antigravity CLI 1.3.3: no session, prompt or approval events.
/// `PreToolUse` fires before every tool, just before an approval dialog
/// draws, so it starts the Host's approval watch for Blocked and its push.
pub const AGY_ENTRIES: &[Entry] = &[
    ("PreInvocation", None, SESSION),
    ("PreToolUse", Some("*"), "watch-approval"),
    ("Stop", None, SESSION),
];

/// Hermes Agent: on_session_end fires at every turn end, so it is done (or
/// idle when interrupted), and on_session_finalize is the exit.
pub const HERMES_ENTRIES: &[Entry] = &[
    ("pre_llm_call", None, SESSION),
    ("on_human_input_request", None, "blocked"),
    ("on_human_input_resolved", None, "working-if-blocked"),
    ("on_session_end", None, SESSION),
    ("on_session_finalize", None, "release"),
];

/// Cline CLI 3.0.70: one bash file per event in ~/.cline/hooks, which `exec`s
/// our command so its parent stays the pane's `.cline`. There is no approval
/// event: PreToolUse fires just before an approval dialog draws, so it starts
/// the screen watch. SessionShutdown is Esc (the TUI stays open).
pub const CLINE_ENTRIES: &[Entry] = &[
    ("TaskStart", None, SESSION),
    ("TaskResume", None, SESSION),
    ("PreToolUse", None, "watch-approval"),
    ("TaskComplete", None, "done"),
    ("TaskError", None, "done"),
    ("TaskCancel", None, "idle"),
    ("SessionShutdown", None, "idle"),
];
