//! Copy for pairing popup startup failures (pair-fatal.js). The popup paints
//! these and waits for a key so herdr does not close the pane before the user
//! can read them.

pub const MISSING_STATE_DIR: &str =
    "HERDR_PLUGIN_STATE_DIR is not set. Run this popup through herdr.";

pub const MISSING_HOST_KEY: &str = "No SSH host key found under /etc/ssh.\n\
\n\
Enable Remote Login (System Settings > General > Sharing), or run:\n\
\x20 sudo ssh-keygen -A\n\
Then invoke pairing again.";

pub const MISSING_ADDRESS: &str =
    "No routable network address found. Connect to a LAN or VPN and retry.";

pub fn pairing_start_failed(error_message: &str) -> String {
    format!("Could not start pairing: {error_message}")
}

pub fn fatal_lines(message: &str) -> [&str; 5] {
    [
        "Pairing cannot start",
        "",
        message,
        "",
        "Press any key to close.",
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fatal_lines_hold_the_title_body_and_keypress_hint() {
        assert_eq!(
            fatal_lines("reason"),
            [
                "Pairing cannot start",
                "",
                "reason",
                "",
                "Press any key to close."
            ]
        );
    }

    #[test]
    fn missing_host_key_tells_the_user_how_to_generate_one() {
        assert!(MISSING_HOST_KEY.contains("/etc/ssh"));
        assert!(MISSING_HOST_KEY.contains("Remote Login"));
        assert!(MISSING_HOST_KEY.contains("sudo ssh-keygen -A"));
    }

    #[test]
    fn other_startup_failures_keep_their_existing_wording() {
        assert_eq!(
            MISSING_STATE_DIR,
            "HERDR_PLUGIN_STATE_DIR is not set. Run this popup through herdr."
        );
        assert_eq!(
            MISSING_ADDRESS,
            "No routable network address found. Connect to a LAN or VPN and retry."
        );
        assert_eq!(
            pairing_start_failed("disk full"),
            "Could not start pairing: disk full"
        );
    }
}
