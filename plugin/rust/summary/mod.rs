//! Agent Summaries: the screen summary of each Agent, its store and the
//! refresh the app triggers over SSH (agent-summary.js, summary-store.js,
//! refresh-summaries.js).

pub mod agent;
pub mod refresh;
pub mod store;

#[cfg(test)]
mod test_support;
