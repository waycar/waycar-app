//! Waycar Host Tools: the `waycar` command and what the milestones share.
//!
//! Many modules mirror one retired JS module's observable behavior (the
//! Node plugin, removed in 2.0.0); their docs name it. The JS names are
//! history, not files: nothing in this crate reads or runs JavaScript.

pub mod activity_envelope;
pub mod activity_hook;
pub mod activity_plan_steps;
pub mod activity_rows;
pub mod activity_start;
pub mod activity_state;
pub mod activity_tick;
pub mod addresses;
pub mod approval_watch;
pub mod atomic;
pub mod authorized_keys;
pub mod base64;
pub mod bootstrap_key;
pub mod chat;
pub mod chat_marker;
pub mod chat_shared;
pub mod cli;
pub mod codex_hook;
pub mod copy_pairing_code;
pub mod core;
pub mod deps;
pub mod device_key;
pub mod display_text;
pub mod env;
pub mod envelope;
pub mod error;
pub mod exec;
pub mod herdr;
pub mod hook_runtime;
pub mod hook_session;
pub mod hook_status;
pub mod hooks;
pub mod host_key;
pub mod http;
pub mod js_compat;
pub mod js_date;
pub mod js_json;
pub mod jspath;
pub mod jsx;
pub mod keypress;
pub mod launch_rivals;
pub mod native;
pub mod notification_config;
pub mod notification_envelope;
pub mod notify_core;
pub mod notify_hook;
pub mod notify_seams;
pub mod opencode_hook;
pub mod pair;
pub mod pair_accept;
pub mod pair_action;
pub mod pair_fatal;
pub mod pairing_qr;
pub mod pairing_session;
pub mod paths;
pub mod plan_progress;
pub mod qr_symbol;
pub mod reach_status;
pub mod seal;
pub mod select_list;
pub mod sidebar_config;
pub mod status;
pub mod summary;
pub mod tmux;
pub mod tty;
pub mod zellij;
pub mod zellij_notify;

#[cfg(test)]
mod activity_fakes;
#[cfg(test)]
mod real_tmux;
#[cfg(test)]
mod test_support;

#[cfg(test)]
pub mod notify_fake;

/// The Host Tools version: the Cargo package version, which
/// `scripts/check-plugin-version.sh` keeps equal to `herdr-plugin.toml`.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
