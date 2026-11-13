//! HTTPS for the one place the tools reach out: the push relay.
//!
//! The TLS stack (rustls through ureq) carries its own root certificates
//! (webpki-roots), so a Host needs no CA bundle and no curl.

use std::time::Duration;

use serde_json::Value;

use crate::error::{CliError, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub body: String,
}

/// POST `body` as JSON. An HTTP error status is a [`Response`], not an
/// error: only a request that got no answer (DNS, TLS, timeout) fails.
pub fn post_json(
    url: &str,
    headers: &[(&str, &str)],
    body: &Value,
    timeout: Duration,
) -> Result<Response> {
    // No proxy: Node's fetch (what the JS relay client used) ignores HTTPS_PROXY,
    // ureq would read it.
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .proxy(None)
        .timeout_global(Some(timeout))
        .http_status_as_error(false)
        .build()
        .into();
    // Compact bytes, as JSON.stringify writes them: ureq's send_json pretty-prints.
    let mut request = agent.post(url).header("content-type", "application/json");
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    let mut response = request
        .send(body.to_string())
        .map_err(|e| CliError::failure(format!("POST {url} failed: {e}")))?;
    let status = response.status().as_u16();
    let body = response.body_mut().read_to_string().unwrap_or_default();
    Ok(Response { status, body })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    /// One request in, `reply` out, on a local port: the request text comes back.
    fn serve_once(reply: &'static str) -> (String, std::thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/push", listener.local_addr().unwrap());
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            let mut buf = [0u8; 4096];
            // Headers end at a blank line; the JSON body is short and arrives with them.
            while !request.windows(4).any(|w| w == b"\r\n\r\n") || !request.ends_with(b"}") {
                let n = stream.read(&mut buf).unwrap();
                if n == 0 {
                    break;
                }
                request.extend_from_slice(&buf[..n]);
            }
            stream.write_all(reply.as_bytes()).unwrap();
            String::from_utf8_lossy(&request).into_owned()
        });
        (url, handle)
    }

    #[test]
    fn an_http_error_status_is_an_answer_not_a_failure() {
        let (url, server) = serve_once(
            "HTTP/1.1 429 Too Many Requests\r\ncontent-length: 4\r\nconnection: close\r\n\r\nslow",
        );
        let answer = post_json(
            &url,
            &[("x-test", "yes")],
            &serde_json::json!({"a": 1}),
            Duration::from_secs(5),
        )
        .unwrap();
        assert_eq!(
            answer,
            Response {
                status: 429,
                body: "slow".into()
            }
        );
        let request = server.join().unwrap().to_lowercase();
        assert!(request.starts_with("post /push http/1.1"), "{request}");
        assert!(
            request.contains("x-test: yes") && request.contains("application/json"),
            "{request}"
        );
        assert!(request.ends_with("{\"a\":1}"), "{request}");
    }

    #[test]
    fn no_answer_is_a_failure_naming_the_url() {
        // A port nothing listens on: bind, note the port, drop the listener.
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let url = format!("http://127.0.0.1:{port}/");
        let error =
            post_json(&url, &[], &serde_json::json!({}), Duration::from_secs(2)).unwrap_err();
        assert!(
            error.message().starts_with(&format!("POST {url} failed")),
            "{error}"
        );
    }
}
