//! Candidate address enumeration for the Pairing Code (addresses.js, ADR 0007).
//!
//! The Pairing Code carries user-selected candidate addresses; this module
//! enumerates the routable ones and pre-checks the ones a phone is most likely
//! to use: the LAN address (the private IPv4 on the platform's primary
//! interface, en0 on macOS and eth0 on Linux, else the best-ranked private
//! IPv4: modern Linux often names interfaces enp3s0-style, so eth0 is a
//! preference, not an assumption) and every Tailscale IPv4 (100.64.0.0/10).
//! A Host with neither falls back to its best-ranked likely address (an IPv6
//! ULA), so something is always checked. Other IPv6 addresses stay listed but
//! unchecked, which keeps the Pairing Code's QR small.

use std::collections::HashSet;
use std::ffi::CStr;
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Family {
    V4,
    V6,
}

impl Family {
    /// Node's name for it (`IPv4`, `IPv6`), which the popup shows.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::V4 => "IPv4",
            Self::V6 => "IPv6",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NetEntry {
    pub address: String,
    pub family: Family,
    pub internal: bool,
}

/// One network interface and its addresses (an entry of Node's
/// `os.networkInterfaces()`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NetInterface {
    pub name: String,
    pub entries: Vec<NetEntry>,
}

/// The platform whose primary interface the LAN address prefers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Darwin,
    Linux,
    Other,
}

impl Platform {
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            Self::Darwin
        } else if cfg!(target_os = "linux") {
            Self::Linux
        } else {
            Self::Other
        }
    }

    fn primary_interface(self) -> Option<&'static str> {
        match self {
            Self::Darwin => Some("en0"),
            Self::Linux => Some("eth0"),
            Self::Other => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub address: String,
    pub family: Family,
    pub interface_name: String,
    pub pre_checked: bool,
}

/// This machine's interfaces that are up and running with an IPv4 or IPv6
/// address, grouped by name in order of first appearance: what libuv hands
/// Node's `os.networkInterfaces()`.
pub fn read_network_interfaces() -> io::Result<Vec<NetInterface>> {
    let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs fills `list` with a chain freed below.
    if unsafe { libc::getifaddrs(&mut list) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let mut interfaces: Vec<NetInterface> = Vec::new();
    let mut current = list;
    while !current.is_null() {
        // SAFETY: `current` is a node of the chain getifaddrs returned.
        let record = unsafe { &*current };
        current = record.ifa_next;
        let flags = record.ifa_flags;
        let (up, running) = (libc::IFF_UP as u32, libc::IFF_RUNNING as u32);
        if flags & up == 0 || flags & running == 0 || record.ifa_addr.is_null() {
            continue;
        }
        // SAFETY: ifa_addr is non-null, so it points at a sockaddr whose
        // family tells which larger structure it is.
        let Some((address, family)) = (unsafe { socket_address(record.ifa_addr) }) else {
            continue;
        };
        // SAFETY: ifa_name is a NUL-terminated string owned by the chain.
        let name = unsafe { CStr::from_ptr(record.ifa_name) }
            .to_string_lossy()
            .into_owned();
        let entry = NetEntry {
            address,
            family,
            internal: flags & libc::IFF_LOOPBACK as u32 != 0,
        };
        match interfaces.iter_mut().find(|i| i.name == name) {
            Some(known) => known.entries.push(entry),
            None => interfaces.push(NetInterface {
                name,
                entries: vec![entry],
            }),
        }
    }
    // SAFETY: `list` came from getifaddrs and is not used after this.
    unsafe { libc::freeifaddrs(list) };
    Ok(interfaces)
}

/// The text and family of an IPv4 or IPv6 socket address; none for any other.
///
/// # Safety
/// `address` must point at a valid socket address structure.
unsafe fn socket_address(address: *const libc::sockaddr) -> Option<(String, Family)> {
    // SAFETY: the caller guarantees `address` is valid, and the family says
    // which structure it starts.
    unsafe {
        match i32::from((*address).sa_family) {
            libc::AF_INET => {
                let v4 = &*address.cast::<libc::sockaddr_in>();
                let ip = Ipv4Addr::from(u32::from_be(v4.sin_addr.s_addr));
                Some((ip.to_string(), Family::V4))
            }
            libc::AF_INET6 => {
                let v6 = &*address.cast::<libc::sockaddr_in6>();
                Some((Ipv6Addr::from(v6.sin6_addr.s6_addr).to_string(), Family::V6))
            }
            _ => None,
        }
    }
}

/// [`read_network_interfaces`], none when the list cannot be read.
pub fn network_interfaces() -> Vec<NetInterface> {
    read_network_interfaces().unwrap_or_default()
}

/// The first two octets of a dotted address, as the JS reads them.
fn ipv4_octets(address: &str) -> Option<(u32, u32)> {
    let mut octets = address.split('.').map(|part| part.parse::<u32>().ok());
    Some((octets.next()??, octets.next()??))
}

fn is_ipv4_link_local(address: &str) -> bool {
    ipv4_octets(address) == Some((169, 254))
}

fn is_ipv4_private(address: &str) -> bool {
    matches!(
        ipv4_octets(address),
        Some((10, _)) | Some((172, 16..=31)) | Some((192, 168))
    )
}

fn is_ipv4_cgnat(address: &str) -> bool {
    matches!(ipv4_octets(address), Some((100, 64..=127)))
}

/// `/^<prefix>/i` for a lowercase ASCII prefix.
fn starts_with_ignore_case(text: &str, prefix: &str) -> bool {
    text.get(..prefix.len())
        .is_some_and(|head| head.eq_ignore_ascii_case(prefix))
}

/// fe80::/10: `/^fe[89ab]/i`.
fn is_ipv6_link_local(address: &str) -> bool {
    ["fe8", "fe9", "fea", "feb"]
        .iter()
        .any(|prefix| starts_with_ignore_case(address, prefix))
}

/// fc00::/7 ULA, which includes Tailscale's fd7a:...: `/^f[cd]/i`.
fn is_ipv6_likely(address: &str) -> bool {
    starts_with_ignore_case(address, "fc") || starts_with_ignore_case(address, "fd")
}

/// Whether Tailscale hands out this address: IPv4 in 100.64.0.0/10 or IPv6 in
/// fd7a:115c:a1e0::/48. The install script's reach status uses this too, so it
/// and the popup agree on what counts.
pub fn is_tailscale_address(address: &str, family: Family) -> bool {
    match family {
        Family::V4 => is_ipv4_cgnat(address),
        Family::V6 => starts_with_ignore_case(address, "fd7a:115c:a1e0:"),
    }
}

struct Routable<'a> {
    address: String,
    family: Family,
    interface_name: &'a str,
    likely: bool,
    lan: bool,
}

/// Enumerate routable candidate addresses for the Pairing Code.
///
/// Skips loopback and link-local addresses. Pre-checks the LAN address (the
/// private IPv4 on the platform's primary interface, else the best-ranked
/// private IPv4) and every Tailscale IPv4; with neither, the best-ranked
/// likely address. Ordered pre-checked first (LAN, then Tailscale), then
/// likely before unlikely, IPv4 before IPv6 within each group, otherwise
/// input order.
pub fn candidate_addresses(interfaces: &[NetInterface], platform: Platform) -> Vec<Candidate> {
    let mut seen = HashSet::new();
    let mut routable: Vec<Routable> = Vec::new();
    for interface in interfaces {
        for entry in interface.entries.iter().filter(|entry| !entry.internal) {
            // Zone ids (fe80::1%en0) are meaningless off-machine.
            let address = entry.address.split('%').next().unwrap_or_default();
            if seen.contains(address) {
                continue;
            }
            let (likely, lan) = match entry.family {
                Family::V4 => {
                    if is_ipv4_link_local(address) {
                        continue;
                    }
                    let lan = is_ipv4_private(address);
                    (lan || is_ipv4_cgnat(address), lan)
                }
                Family::V6 => {
                    if is_ipv6_link_local(address) {
                        continue;
                    }
                    (is_ipv6_likely(address), false)
                }
            };
            seen.insert(address);
            routable.push(Routable {
                address: address.to_string(),
                family: entry.family,
                interface_name: &interface.name,
                likely,
                lan,
            });
        }
    }

    let rank = |r: &Routable| {
        (if r.likely { 0 } else { 2 }) + (if r.family == Family::V4 { 0 } else { 1 })
    };
    // A stable sort: equal ranks keep their input order.
    routable.sort_by_key(rank);

    let primary = platform.primary_interface();
    let lan_default = routable
        .iter()
        .position(|r| r.lan && Some(r.interface_name) == primary)
        .or_else(|| routable.iter().position(|r| r.lan));
    let mut checked: Vec<usize> = lan_default.into_iter().collect();
    checked.extend(
        routable
            .iter()
            .enumerate()
            .filter(|(_, r)| r.family == Family::V4 && is_tailscale_address(&r.address, r.family))
            .map(|(index, _)| index),
    );
    if checked.is_empty() {
        checked.extend(routable.iter().position(|r| r.likely));
    }

    let candidate = |index: usize, pre_checked: bool| {
        let r = &routable[index];
        Candidate {
            address: r.address.clone(),
            family: r.family,
            interface_name: r.interface_name.to_string(),
            pre_checked,
        }
    };
    checked
        .iter()
        .map(|&index| candidate(index, true))
        .chain(
            (0..routable.len())
                .filter(|index| !checked.contains(index))
                .map(|index| candidate(index, false)),
        )
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn iface(address: &str, family: Family, internal: bool) -> NetEntry {
        NetEntry {
            address: address.into(),
            family,
            internal,
        }
    }

    fn v4(address: &str) -> NetEntry {
        iface(address, Family::V4, false)
    }

    fn v6(address: &str) -> NetEntry {
        iface(address, Family::V6, false)
    }

    fn nics(list: Vec<(&str, Vec<NetEntry>)>) -> Vec<NetInterface> {
        list.into_iter()
            .map(|(name, entries)| NetInterface {
                name: name.into(),
                entries,
            })
            .collect()
    }

    fn by_address(candidates: &[Candidate]) -> BTreeMap<&str, bool> {
        candidates
            .iter()
            .map(|c| (c.address.as_str(), c.pre_checked))
            .collect()
    }

    fn addresses(candidates: &[Candidate]) -> Vec<&str> {
        candidates.iter().map(|c| c.address.as_str()).collect()
    }

    fn pairs(candidates: &[Candidate]) -> Vec<(&str, bool)> {
        candidates
            .iter()
            .map(|c| (c.address.as_str(), c.pre_checked))
            .collect()
    }

    fn map(entries: &[(&'static str, bool)]) -> BTreeMap<&'static str, bool> {
        entries.iter().copied().collect()
    }

    // candidateAddresses
    #[test]
    fn skips_loopback_and_link_local_keeps_routable_addresses() {
        let candidates = candidate_addresses(
            &nics(vec![
                (
                    "lo0",
                    vec![
                        iface("127.0.0.1", Family::V4, true),
                        iface("::1", Family::V6, true),
                    ],
                ),
                (
                    "en0",
                    vec![
                        v4("192.168.1.42"),
                        v4("169.254.10.20"),
                        v6("fe80::1c2d:3e4f:5a6b:7c8d"),
                        v6("2001:db8:85a3::8a2e:370:7334"),
                    ],
                ),
            ]),
            Platform::Other,
        );
        assert_eq!(
            addresses(&candidates),
            ["192.168.1.42", "2001:db8:85a3::8a2e:370:7334"]
        );
    }

    #[test]
    fn pre_checks_en0s_private_address_and_the_tailscale_ipv4_on_macos_listed_first() {
        let candidates = candidate_addresses(
            &nics(vec![
                ("en1", vec![v4("10.0.0.7")]),
                ("en0", vec![v4("192.168.1.42"), v6("2001:db8::7")]),
                (
                    "utun3",
                    vec![v4("100.101.102.103"), v6("fd7a:115c:a1e0::1")],
                ),
                ("en2", vec![v4("203.0.113.9")]),
            ]),
            Platform::Darwin,
        );
        assert_eq!(
            by_address(&candidates),
            map(&[
                ("192.168.1.42", true),
                ("100.101.102.103", true),
                ("10.0.0.7", false),
                ("fd7a:115c:a1e0::1", false),
                ("2001:db8::7", false),
                ("203.0.113.9", false),
            ])
        );
        assert_eq!(
            addresses(&candidates)[..2],
            ["192.168.1.42", "100.101.102.103"]
        );
    }

    #[test]
    fn pre_checks_only_eth0s_private_address_on_linux_not_another_interfaces() {
        let candidates = candidate_addresses(
            &nics(vec![
                ("wlan0", vec![v4("192.168.0.5")]),
                ("eth0", vec![v4("10.1.2.3")]),
            ]),
            Platform::Linux,
        );
        assert_eq!(
            by_address(&candidates),
            map(&[("10.1.2.3", true), ("192.168.0.5", false)])
        );
    }

    #[test]
    fn falls_back_to_the_best_ranked_private_address_when_the_primary_interface_is_absent() {
        let candidates = candidate_addresses(
            &nics(vec![
                ("utun3", vec![v6("fd7a:115c:a1e0::1")]),
                ("en5", vec![v4("192.168.1.42")]),
            ]),
            Platform::Darwin,
        );
        assert_eq!(
            by_address(&candidates),
            map(&[("192.168.1.42", true), ("fd7a:115c:a1e0::1", false)])
        );
    }

    #[test]
    fn never_pre_checks_a_public_address_even_on_the_primary_interface() {
        let candidates = candidate_addresses(
            &nics(vec![
                ("en0", vec![v4("203.0.113.9")]),
                ("en1", vec![v4("192.168.1.42")]),
            ]),
            Platform::Darwin,
        );
        assert_eq!(
            by_address(&candidates),
            map(&[("192.168.1.42", true), ("203.0.113.9", false)])
        );
    }

    #[test]
    fn does_not_pre_check_ipv4_outside_private_and_cgnat_ranges() {
        let candidates = candidate_addresses(
            &nics(vec![(
                "en0",
                vec![
                    v4("172.15.0.1"),
                    v4("172.32.0.1"),
                    v4("100.63.255.255"),
                    v4("100.128.0.1"),
                ],
            )]),
            Platform::Other,
        );
        assert_eq!(
            candidates.iter().map(|c| c.pre_checked).collect::<Vec<_>>(),
            [false; 4]
        );
    }

    #[test]
    fn orders_the_pre_checked_first_then_likely_ipv4_ipv6_then_the_rest() {
        let candidates = candidate_addresses(
            &nics(vec![
                ("en0", vec![v6("2001:db8::7"), v4("203.0.113.9")]),
                (
                    "utun3",
                    vec![v6("fd7a:115c:a1e0::1"), v4("100.101.102.103")],
                ),
                ("en1", vec![v4("192.168.1.42")]),
            ]),
            Platform::Linux,
        );
        assert_eq!(
            addresses(&candidates),
            [
                "192.168.1.42",
                "100.101.102.103",
                "fd7a:115c:a1e0::1",
                "203.0.113.9",
                "2001:db8::7",
            ]
        );
    }

    #[test]
    fn strips_ipv6_zone_ids_and_deduplicates_repeated_addresses() {
        let candidates = candidate_addresses(
            &nics(vec![
                ("utun0", vec![v6("fd7a:115c:a1e0::1%utun0")]),
                ("utun1", vec![v6("fd7a:115c:a1e0::1")]),
            ]),
            Platform::Other,
        );
        assert_eq!(addresses(&candidates), ["fd7a:115c:a1e0::1"]);
    }

    #[test]
    fn reports_the_owning_interface_name() {
        let candidates = candidate_addresses(
            &nics(vec![("en0", vec![v4("192.168.1.42")])]),
            Platform::Other,
        );
        assert_eq!(
            candidates,
            [Candidate {
                address: "192.168.1.42".into(),
                family: Family::V4,
                interface_name: "en0".into(),
                pre_checked: true,
            }]
        );
    }

    #[test]
    fn returns_an_empty_list_when_nothing_is_routable() {
        let candidates = candidate_addresses(
            &nics(vec![("lo0", vec![iface("127.0.0.1", Family::V4, true)])]),
            Platform::Other,
        );
        assert_eq!(candidates, []);
    }

    #[test]
    fn a_host_with_only_a_tailscale_address_pre_checks_it() {
        let candidates = candidate_addresses(
            &nics(vec![
                ("eth0", vec![v4("203.0.113.9")]),
                (
                    "tailscale0",
                    vec![v4("100.101.102.103"), v6("fd7a:115c:a1e0::1")],
                ),
            ]),
            Platform::Linux,
        );
        assert_eq!(
            by_address(&candidates),
            map(&[
                ("100.101.102.103", true),
                ("fd7a:115c:a1e0::1", false),
                ("203.0.113.9", false),
            ])
        );
    }

    #[test]
    fn a_host_with_only_an_ipv6_ula_pre_checks_it_so_something_is_always_checked() {
        let candidates = candidate_addresses(
            &nics(vec![(
                "eth0",
                vec![v6("fd12:3456:789a::5"), v6("2001:db8::7")],
            )]),
            Platform::Linux,
        );
        assert_eq!(
            pairs(&candidates),
            [("fd12:3456:789a::5", true), ("2001:db8::7", false)]
        );
    }

    #[test]
    fn pre_checks_one_lan_address_however_many_the_host_has_and_every_tailscale_ipv4() {
        let candidates = candidate_addresses(
            &nics(vec![
                ("wlan0", vec![v4("192.168.0.5")]),
                ("enp3s0", vec![v4("10.0.0.7")]),
                ("tailscale0", vec![v4("100.101.102.103"), v4("100.64.0.9")]),
            ]),
            Platform::Linux,
        );
        let checked: Vec<&str> = candidates
            .iter()
            .filter(|c| c.pre_checked)
            .map(|c| c.address.as_str())
            .collect();
        assert_eq!(checked, ["192.168.0.5", "100.101.102.103", "100.64.0.9"]);
    }

    #[test]
    fn lists_the_lan_address_first_then_tailscale_whatever_the_interface_order() {
        let candidates = candidate_addresses(
            &nics(vec![
                ("utun3", vec![v4("100.101.102.103")]),
                ("en0", vec![v4("192.168.1.42")]),
            ]),
            Platform::Darwin,
        );
        assert_eq!(
            pairs(&candidates),
            [("192.168.1.42", true), ("100.101.102.103", true)]
        );
    }

    // isTailscaleAddress
    #[test]
    fn tailscale_ipv4_is_exactly_100_64_0_0_10() {
        assert!(is_tailscale_address("100.64.0.0", Family::V4));
        assert!(is_tailscale_address("100.127.255.255", Family::V4));
        assert!(!is_tailscale_address("100.63.255.255", Family::V4));
        assert!(!is_tailscale_address("100.128.0.0", Family::V4));
        assert!(!is_tailscale_address("192.168.1.42", Family::V4));
    }

    #[test]
    fn tailscale_ipv6_is_exactly_fd7a_115c_a1e0_48() {
        assert!(is_tailscale_address("fd7a:115c:a1e0::1", Family::V6));
        assert!(is_tailscale_address("FD7A:115C:A1E0:ab12::9", Family::V6));
        assert!(!is_tailscale_address("fd7a:115c:a1e1::1", Family::V6));
        assert!(!is_tailscale_address("fd12:3456:789a::5", Family::V6));
        assert!(!is_tailscale_address("fd7a:115c:a1e0", Family::V6));
    }

    #[test]
    fn this_machines_interfaces_are_listed_with_loopback_marked_internal() {
        // Every Linux and macOS machine has a running loopback interface.
        let interfaces = read_network_interfaces().unwrap();
        let loopback = interfaces
            .iter()
            .flat_map(|i| &i.entries)
            .find(|e| e.address == "127.0.0.1");
        assert!(loopback.is_some_and(|e| e.internal && e.family == Family::V4));
    }
}
