//! Chat Mode: the transcript reader (`waycar chat-read`) and what it shares
//! with Agent Summaries. Each module mirrors one JS module in `plugin/src`
//! and names it in its docs; the JS stays the behavior spec until M4.

pub mod launch_rivals;
pub mod marker;
pub mod media;
pub mod read;
pub mod readers;
pub mod session_export;
pub mod shared;
pub mod transcript;
