//! Error and exit-code conventions of the `waycar` command (waycar-cli.js).
//!
//! * `0` success.
//! * `1` a failure: `waycar: <message>` on stderr.
//! * `2` a usage error: `waycar: <message>` and the usage text on stderr.
//!
//! Hook-class commands (`notify`, `watch-approval`) are started detached by
//! the agent hooks, which must never fail the agent; those callers discard
//! the exit code themselves.

use std::fmt;

pub const EXIT_OK: i32 = 0;
pub const EXIT_FAILURE: i32 = 1;
pub const EXIT_USAGE: i32 = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CliError {
    /// The command line is wrong; exit 2 and print the usage.
    Usage(String),
    /// The command ran and failed; exit 1.
    Failure(String),
}

impl CliError {
    pub fn usage(message: impl Into<String>) -> Self {
        Self::Usage(message.into())
    }

    pub fn failure(message: impl Into<String>) -> Self {
        Self::Failure(message.into())
    }

    pub fn message(&self) -> &str {
        match self {
            Self::Usage(message) | Self::Failure(message) => message,
        }
    }

    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Usage(_) => EXIT_USAGE,
            Self::Failure(_) => EXIT_FAILURE,
        }
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for CliError {}

impl From<std::io::Error> for CliError {
    fn from(error: std::io::Error) -> Self {
        Self::Failure(error.to_string())
    }
}

pub type Result<T> = std::result::Result<T, CliError>;
