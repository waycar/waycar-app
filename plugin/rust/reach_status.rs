//! `waycar reach-status [--tailscale-cli]`: what install.sh prints about how a
//! phone can reach this computer away from home (reach-status.js).
//!
//! It looks at this machine's own interface addresses (the same ones the
//! pairing popup lists) and at whether install.sh found a Tailscale command;
//! it installs, writes and fetches nothing. Away detection in the app keys on
//! the phone's VPN, not on a Tailscale address on the Host: a Host behind one
//! subnet-router device has a LAN address and no 100.x address and still
//! works. So "not detected" never says Waycar cannot work away from home; it
//! says what a phone needs instead.

use std::io::Write;

use crate::addresses::{NetInterface, is_tailscale_address, read_network_interfaces};
use crate::native::Ctx;

const GUIDE: &str = "https://waycar.dev/articles/reach-your-ai-harness-while-you-are-away";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReachState {
    Connected,
    Installed,
    Absent,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReachStatus {
    pub state: ReachState,
    pub addresses: Vec<String>,
}

/// The Tailscale addresses of this computer (IPv4 first: that is the one the
/// pairing popup checks) and the state they and `cli_present` make.
pub fn reach_status(interfaces: &[NetInterface], cli_present: bool) -> ReachStatus {
    let mut addresses: Vec<String> = Vec::new();
    for entry in interfaces
        .iter()
        .flat_map(|interface| &interface.entries)
        .filter(|entry| !entry.internal)
    {
        let address = entry.address.split('%').next().unwrap_or_default();
        if is_tailscale_address(address, entry.family) && !addresses.iter().any(|a| a == address) {
            addresses.push(address.to_string());
        }
    }
    addresses.sort_by_key(|address| address.contains(':'));
    let state = if !addresses.is_empty() {
        ReachState::Connected
    } else if cli_present {
        ReachState::Installed
    } else {
        ReachState::Absent
    };
    ReachStatus { state, addresses }
}

/// The lines install.sh prints for a status.
pub fn reach_lines(status: &ReachStatus) -> Vec<String> {
    match status.state {
        ReachState::Connected => vec![format!(
            "reach: Tailscale detected ({}). The pairing popup offers it next to your home network address.",
            status.addresses.join(", ")
        )],
        ReachState::Installed => vec![
            "reach: Tailscale command found, but no Tailscale address detected on this computer."
                .to_string(),
            format!(
                "reach: A subnet router can provide access without Tailscale on this computer: {GUIDE}"
            ),
        ],
        ReachState::Absent => vec![
            "reach: Tailscale not detected on this computer. On your home Wi-Fi Waycar connects as it is."
                .to_string(),
            format!(
                "reach: Away from home your phone needs a way into your home network. One always-on device at home running Tailscale as a subnet router covers every computer there, so nothing more is needed on this one: {GUIDE}"
            ),
        ],
    }
}

/// Print the status lines. A courtesy: it never fails the install, whatever
/// the arguments; an unreadable interface list prints nothing. Any
/// `--tailscale-cli` among the arguments says install.sh found the command.
pub fn run(_ctx: &Ctx, args: &[String], out: &mut dyn Write, _err: &mut dyn Write) -> i32 {
    let cli_present = args.iter().any(|arg| arg == "--tailscale-cli");
    let Ok(interfaces) = read_network_interfaces() else {
        return 0;
    };
    let status = reach_status(&interfaces, cli_present);
    for line in reach_lines(&status) {
        let _ = writeln!(out, "{line}");
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::addresses::{Family, NetEntry};

    fn nic(address: &str, family: Family, internal: bool) -> NetEntry {
        NetEntry {
            address: address.into(),
            family,
            internal,
        }
    }

    fn v4(address: &str) -> NetEntry {
        nic(address, Family::V4, false)
    }

    fn v6(address: &str) -> NetEntry {
        nic(address, Family::V6, false)
    }

    fn nics(list: Vec<(&str, Vec<NetEntry>)>) -> Vec<NetInterface> {
        list.into_iter()
            .map(|(name, entries)| NetInterface {
                name: name.into(),
                entries,
            })
            .collect()
    }

    fn status(state: ReachState, addresses: &[&str]) -> ReachStatus {
        ReachStatus {
            state,
            addresses: addresses.iter().map(|a| a.to_string()).collect(),
        }
    }

    #[test]
    fn a_tailscale_address_means_connected_whether_or_not_the_command_is_on_path() {
        let interfaces = nics(vec![
            ("en0", vec![v4("192.168.1.42")]),
            ("utun3", vec![v4("100.101.102.103")]),
        ]);
        let connected = status(ReachState::Connected, &["100.101.102.103"]);
        assert_eq!(reach_status(&interfaces, false), connected);
        assert_eq!(reach_status(&interfaces, true), connected);
    }

    #[test]
    fn an_ipv6_only_tailnet_address_counts_listed_after_ipv4_without_its_zone_id() {
        let found = reach_status(
            &nics(vec![
                (
                    "utun3",
                    vec![v6("fd7a:115c:a1e0::1%utun3"), v4("100.64.0.9")],
                ),
                ("utun4", vec![v6("fd7a:115c:a1e0::1")]),
            ]),
            false,
        );
        assert_eq!(
            found,
            status(ReachState::Connected, &["100.64.0.9", "fd7a:115c:a1e0::1"])
        );
    }

    #[test]
    fn only_the_command_present_means_installed_neither_means_absent() {
        let lan = nics(vec![("en0", vec![v4("192.168.1.42")])]);
        assert_eq!(reach_status(&lan, true).state, ReachState::Installed);
        assert_eq!(reach_status(&lan, false).state, ReachState::Absent);
    }

    #[test]
    fn other_cgnat_or_ula_addresses_and_loopback_are_not_tailscale() {
        let found = reach_status(
            &nics(vec![
                ("lo0", vec![nic("100.100.100.100", Family::V4, true)]),
                (
                    "en0",
                    vec![
                        v4("100.63.255.255"),
                        v4("100.128.0.1"),
                        v6("fd12:3456:789a::5"),
                    ],
                ),
            ]),
            false,
        );
        assert_eq!(found.state, ReachState::Absent);
    }

    #[test]
    fn the_lines_say_what_each_state_means() {
        let text = |state: ReachStatus| reach_lines(&state).join("\n");
        assert_eq!(
            text(status(
                ReachState::Connected,
                &["100.64.0.9", "fd7a:115c:a1e0::1"]
            )),
            "reach: Tailscale detected (100.64.0.9, fd7a:115c:a1e0::1). The pairing popup offers it next to your home network address."
        );
        assert_eq!(
            text(status(ReachState::Installed, &[])),
            "reach: Tailscale command found, but no Tailscale address detected on this computer.\nreach: A subnet router can provide access without Tailscale on this computer: https://waycar.dev/articles/reach-your-ai-harness-while-you-are-away"
        );
        assert_eq!(
            text(status(ReachState::Absent, &[])),
            "reach: Tailscale not detected on this computer. On your home Wi-Fi Waycar connects as it is.\nreach: Away from home your phone needs a way into your home network. One always-on device at home running Tailscale as a subnet router covers every computer there, so nothing more is needed on this one: https://waycar.dev/articles/reach-your-ai-harness-while-you-are-away"
        );
    }
}
