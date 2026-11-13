//! The per-harness transcript readers (chat-readers/*.js). Each module
//! exports `READER`: where its transcripts live, how to find one and how to
//! parse it into [`ChatTurns`]. `chat::transcript` picks one by kind.

use crate::chat::shared::{AbortSignal, ChatResult, ChatTurns};
use crate::env::Env;

pub mod agy;
pub mod cline;
pub mod copilot;
pub mod gemini;
pub mod gemini_parts;
pub mod grok;
pub mod hermes;
pub mod muse;
pub mod qwen;

/// What `parse(file, {root, env, home, cwd, turns, signal})` gets besides the
/// file and the turns to fill.
pub struct ReaderContext<'a> {
    pub root: &'a str,
    pub env: &'a Env,
    pub home: &'a str,
    pub cwd: Option<&'a str>,
    pub signal: Option<&'a AbortSignal>,
}

/// `findByLaunch({cwd, launchedAt, root, home})`; `launched_at` is epoch ms
/// (`None` when the request named none or it did not parse).
pub struct LaunchQuery<'a> {
    pub cwd: Option<&'a str>,
    pub launched_at: Option<f64>,
    pub root: &'a str,
    pub home: &'a str,
}

/// `findByLaunch`: the launch match, None when nothing matches.
pub type FindByLaunch = fn(&LaunchQuery<'_>) -> ChatResult<Option<String>>;
/// `resolvePath`: the file the harness really wrote for a reported path.
pub type ResolvePath = fn(&str) -> ChatResult<Option<String>>;

/// One harness's reader. `root(env, home)` is where its data lives;
/// `find_by_id(id, root)` the newest transcript of a session id;
/// `find_by_launch` the launch match (None: the kind has none);
/// `resolve_path` maps a reported path to the file the harness really wrote
/// (gemini); `parse` reads a transcript into the turns.
pub struct Reader {
    pub root: fn(&Env, &str) -> String,
    pub find_by_id: fn(&str, &str) -> ChatResult<Option<String>>,
    pub find_by_launch: Option<FindByLaunch>,
    pub resolve_path: Option<ResolvePath>,
    pub parse: fn(&str, &ReaderContext<'_>, &mut ChatTurns) -> ChatResult<()>,
}

/// The reader of a harness kind that has its own module (the JS `READERS`).
pub fn reader(kind: &str) -> Option<&'static Reader> {
    Some(match kind {
        "agy" => &agy::READER,
        "cline" => &cline::READER,
        "copilot" => &copilot::READER,
        "gemini" => &gemini::READER,
        "grok" => &grok::READER,
        "hermes" => &hermes::READER,
        "muse" => &muse::READER,
        "qwen" => &qwen::READER,
        _ => return None,
    })
}
