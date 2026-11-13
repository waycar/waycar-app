//! The two outside-world seams the hook runtime shares: the relay's HTTP
//! client and the clock. The JS injects `fetch`, `now` and `sleep` the same
//! way, so tests run the real flow against a recorded relay on fake time.

use std::time::Duration;

use serde_json::Value;

use crate::error::Result;
use crate::http::{Response, post_json};

/// One POST to the push relay. An HTTP error status is a [`Response`]; only a
/// request that got no answer is an `Err` (see [`post_json`]).
pub trait Fetch {
    fn post_json(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        body: &Value,
        timeout: Duration,
    ) -> Result<Response>;
}

/// The real network.
pub struct HttpFetch;

impl Fetch for HttpFetch {
    fn post_json(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        body: &Value,
        timeout: Duration,
    ) -> Result<Response> {
        post_json(url, headers, body, timeout)
    }
}

/// Wall time in milliseconds since the Unix epoch, and sleeping.
pub trait Clock {
    fn now_ms(&self) -> u64;
    fn sleep(&self, duration: Duration);
}

/// The real clock.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
    }

    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}
