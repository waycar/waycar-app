//! QR symbols as the `qrcode` npm package (1.5.4) builds them, error
//! correction L (the `create` of qrcode/lib/core/qrcode.js).
//!
//! The Pairing Code screen has to show the same modules as the JS popup, so
//! the two choices where QR encoders differ follow the package: how the text
//! is split into numeric, alphanumeric and byte segments (and so the version),
//! and which of the eight masks wins (its penalty scores). The `qrcode` crate
//! supplies what the standard fixes: the bit stream's field encodings, the
//! Reed-Solomon codewords and the module layout.

use qrcode::bits::Bits;
use qrcode::canvas::{Canvas, MaskPattern};
use qrcode::{EcLevel, Version, ec};

use crate::error::{CliError, Result};

const LEVEL: EcLevel = EcLevel::L;
const VERSIONS: std::ops::RangeInclusive<u8> = 1..=40;

/// The finished symbol: `size` x `size` modules, row by row, `true` dark.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Symbol {
    pub version: u8,
    pub size: usize,
    pub modules: Vec<bool>,
}

impl Symbol {
    pub fn is_dark(&self, x: usize, y: usize) -> bool {
        self.modules[y * self.size + x]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Numeric,
    Alphanumeric,
    Byte,
}

impl Mode {
    /// Bits of the character count field (qrcode's `ccBits`).
    fn count_bits(self, version: u8) -> usize {
        let index = match version {
            1..=9 => 0,
            10..=26 => 1,
            _ => 2,
        };
        match self {
            Self::Numeric => [10, 12, 14][index],
            Self::Alphanumeric => [9, 11, 13][index],
            Self::Byte => [8, 16, 16][index],
        }
    }

    fn data_bits(self, length: usize) -> usize {
        match self {
            Self::Numeric => {
                10 * (length / 3)
                    + if length.is_multiple_of(3) {
                        0
                    } else {
                        length % 3 * 3 + 1
                    }
            }
            Self::Alphanumeric => 11 * (length / 2) + 6 * (length % 2),
            Self::Byte => 8 * length,
        }
    }
}

#[derive(Debug, Clone)]
struct Segment<'a> {
    mode: Mode,
    data: std::borrow::Cow<'a, str>,
    /// Characters, or bytes for a byte segment.
    length: usize,
}

fn is_alphanumeric_symbol(c: char) -> bool {
    matches!(
        c,
        'A'..='Z' | ' ' | '$' | '%' | '*' | '+' | '-' | '.' | '/' | ':'
    )
}

/// The text cut into maximal runs of digits, of the other alphanumeric
/// characters, and of everything else (`rawSplit`).
fn raw_split(text: &str) -> Vec<Segment<'_>> {
    let class = |c: char| match c {
        '0'..='9' => Mode::Numeric,
        c if is_alphanumeric_symbol(c) => Mode::Alphanumeric,
        _ => Mode::Byte,
    };
    let mut segments = Vec::new();
    let mut start = 0;
    let mut current: Option<Mode> = None;
    for (index, c) in text.char_indices() {
        let mode = class(c);
        if current != Some(mode) {
            if let Some(mode) = current {
                segments.push(segment(mode, &text[start..index]));
            }
            current = Some(mode);
            start = index;
        }
    }
    if let Some(mode) = current {
        segments.push(segment(mode, &text[start..]));
    }
    segments
}

fn segment(mode: Mode, data: &str) -> Segment<'_> {
    let length = if mode == Mode::Byte {
        data.len()
    } else {
        data.chars().count()
    };
    Segment {
        mode,
        data: data.into(),
        length,
    }
}

/// Data bits the version holds at level L.
fn capacity_bits(version: u8) -> usize {
    Bits::new(Version::Normal(i16::from(version)))
        .max_len(LEVEL)
        .unwrap_or(0)
}

/// The smallest version that holds the segments (`getBestVersionForData`):
/// several segments by their total bits, a single one by the length it can
/// store, which is how the package counts it.
fn best_version(segments: &[Segment<'_>]) -> Option<u8> {
    match segments {
        [] => Some(1),
        [only] => VERSIONS.into_iter().find(|&version| {
            let usable = capacity_bits(version) - only.mode.count_bits(version) - 4;
            let stored = match only.mode {
                Mode::Numeric => usable * 3 / 10,
                Mode::Alphanumeric => usable * 2 / 11,
                Mode::Byte => usable / 8,
            };
            only.length <= stored
        }),
        many => VERSIONS.into_iter().find(|&version| {
            let total: usize = many
                .iter()
                .map(|s| 4 + s.mode.count_bits(version) + s.mode.data_bits(s.length))
                .sum();
            total <= capacity_bits(version)
        }),
    }
}

/// Group of alternatives for one raw segment, as `buildNodes` makes them: a
/// digit run may also be sent as alphanumeric or bytes, an alphanumeric run
/// as bytes.
fn alternatives<'a>(raw: &Segment<'a>) -> Vec<Segment<'a>> {
    let as_mode = |mode| Segment {
        mode,
        data: raw.data.clone(),
        length: raw.length,
    };
    match raw.mode {
        Mode::Numeric => vec![
            raw.clone(),
            as_mode(Mode::Alphanumeric),
            as_mode(Mode::Byte),
        ],
        Mode::Alphanumeric => vec![raw.clone(), as_mode(Mode::Byte)],
        Mode::Byte => vec![raw.clone()],
    }
}

/// The cheapest way to send the raw segments (`buildGraph` and dijkstrajs'
/// `find_path`), costs counted for `version`'s field widths.
///
/// Ties and the running segment lengths follow the package's order of
/// evaluation, quirks included, because they decide which of several
/// equally long encodings it picks.
fn optimize<'a>(raw: &[Segment<'a>], version: u8) -> Vec<Segment<'a>> {
    let groups: Vec<Vec<Segment<'a>>> = raw.iter().map(alternatives).collect();
    // Node 0 is the start; the nodes of each group follow; the end is last.
    let mut nodes: Vec<&Segment<'a>> = Vec::new();
    let mut last_count: Vec<usize> = Vec::new();
    let mut edges: Vec<Vec<(usize, i64)>> = vec![Vec::new()];
    let mut previous: Vec<usize> = vec![0];
    for group in &groups {
        let mut current = Vec::new();
        for node in group {
            let id = edges.len();
            nodes.push(node);
            last_count.push(0);
            edges.push(Vec::new());
            current.push(id);
            for &prev in &previous {
                let cost = if prev == 0 {
                    switch_cost(node, version)
                } else if nodes[prev - 1].mode == node.mode {
                    let before = last_count[prev - 1];
                    last_count[prev - 1] += node.length;
                    node.mode.data_bits(before + node.length) as i64
                        - node.mode.data_bits(before) as i64
                } else {
                    last_count[prev - 1] = node.length;
                    switch_cost(node, version)
                };
                edges[prev].push((id, cost));
            }
        }
        previous = current;
    }
    let end = edges.len();
    edges.push(Vec::new());
    for prev in previous {
        edges[prev].push((end, 0));
    }

    let path = find_path(&edges, 0, end);
    let mut merged: Vec<Segment<'a>> = Vec::new();
    for &id in &path[1..path.len() - 1] {
        let node = nodes[id - 1];
        match merged.last_mut() {
            Some(last) if last.mode == node.mode => {
                last.data.to_mut().push_str(&node.data);
                last.length += node.length;
            }
            _ => merged.push(node.clone()),
        }
    }
    merged
}

fn switch_cost(node: &Segment<'_>, version: u8) -> i64 {
    (node.mode.data_bits(node.length) + 4 + node.mode.count_bits(version)) as i64
}

/// dijkstrajs: a queue kept sorted by a stable sort after every push, stale
/// entries included, so equal costs pop in the order they were pushed.
fn find_path(edges: &[Vec<(usize, i64)>], start: usize, end: usize) -> Vec<usize> {
    let mut costs: Vec<Option<i64>> = vec![None; edges.len()];
    let mut predecessors: Vec<Option<usize>> = vec![None; edges.len()];
    costs[start] = Some(0);
    let mut open: Vec<(usize, i64)> = vec![(start, 0)];
    while !open.is_empty() {
        let (u, cost_to_u) = open.remove(0);
        for &(v, edge) in &edges[u] {
            let through_u = cost_to_u + edge;
            if costs[v].is_none_or(|known| known > through_u) {
                costs[v] = Some(through_u);
                open.push((v, through_u));
                open.sort_by_key(|&(_, cost)| cost);
                predecessors[v] = Some(u);
            }
        }
    }
    let mut path = vec![end];
    let mut at = end;
    while let Some(before) = predecessors[at] {
        path.push(before);
        at = before;
    }
    path.reverse();
    path
}

/// The symbol for `text`, the way the `qrcode` package builds it at level L.
pub fn create(text: &str) -> Result<Symbol> {
    if text.is_empty() {
        return Err(CliError::failure("No input text"));
    }
    let raw = raw_split(text);
    let estimated = best_version(&raw).unwrap_or(40);
    let segments = optimize(&raw, estimated);
    let version = best_version(&segments).ok_or_else(|| {
        CliError::failure("The amount of data is too big to be stored in a QR Code")
    })?;

    let too_big = |error: qrcode::types::QrError| CliError::failure(error.to_string());
    let qr_version = Version::Normal(i16::from(version));
    let mut bits = Bits::new(qr_version);
    for segment in &segments {
        let bytes = segment.data.as_bytes();
        match segment.mode {
            Mode::Numeric => bits.push_numeric_data(bytes),
            Mode::Alphanumeric => bits.push_alphanumeric_data(bytes),
            Mode::Byte => bits.push_byte_data(bytes),
        }
        .map_err(too_big)?;
    }
    bits.push_terminator(LEVEL).map_err(too_big)?;
    let (data, check) =
        ec::construct_codewords(&bits.into_bytes(), qr_version, LEVEL).map_err(too_big)?;
    let mut canvas = Canvas::new(qr_version, LEVEL);
    canvas.draw_all_functional_patterns();
    canvas.draw_data(&data, &check);

    let size = qr_version.width() as usize;
    let mut best: Option<(u32, Vec<bool>)> = None;
    for pattern in MASKS {
        let mut masked = canvas.clone();
        masked.apply_mask(pattern);
        let modules: Vec<bool> = (0..size * size)
            .map(|index| {
                masked
                    .get((index % size) as i16, (index / size) as i16)
                    .is_dark()
            })
            .collect();
        let score = penalty(&modules, size);
        if best.as_ref().is_none_or(|(lowest, _)| score < *lowest) {
            best = Some((score, modules));
        }
    }
    let modules = best.map(|(_, modules)| modules).unwrap_or_default();
    Ok(Symbol {
        version,
        size,
        modules,
    })
}

const MASKS: [MaskPattern; 8] = [
    MaskPattern::Checkerboard,
    MaskPattern::HorizontalLines,
    MaskPattern::VerticalLines,
    MaskPattern::DiagonalLines,
    MaskPattern::LargeCheckerboard,
    MaskPattern::Fields,
    MaskPattern::Diamonds,
    MaskPattern::Meadow,
];

/// The package's mask penalty: N1 runs, N2 blocks, N3 finder-like rows, N4
/// dark balance (mask-pattern.js `getPenaltyN1`..`N4`).
fn penalty(modules: &[bool], size: usize) -> u32 {
    let at = |row: usize, col: usize| u32::from(modules[row * size + col]);
    let (mut runs, mut finder) = (0u32, 0u32);
    for row in 0..size {
        let (mut same_col, mut same_row) = (0u32, 0u32);
        let (mut last_col, mut last_row) = (None, None);
        let (mut bits_col, mut bits_row) = (0u32, 0u32);
        for col in 0..size {
            let module = at(row, col);
            if last_col == Some(module) {
                same_col += 1;
            } else {
                if same_col >= 5 {
                    runs += 3 + (same_col - 5);
                }
                last_col = Some(module);
                same_col = 1;
            }
            let module = at(col, row);
            if last_row == Some(module) {
                same_row += 1;
            } else {
                if same_row >= 5 {
                    runs += 3 + (same_row - 5);
                }
                last_row = Some(module);
                same_row = 1;
            }
            bits_col = ((bits_col << 1) & 0x7ff) | at(row, col);
            if col >= 10 && (bits_col == 0x5d0 || bits_col == 0x05d) {
                finder += 1;
            }
            bits_row = ((bits_row << 1) & 0x7ff) | at(col, row);
            if col >= 10 && (bits_row == 0x5d0 || bits_row == 0x05d) {
                finder += 1;
            }
        }
        if same_col >= 5 {
            runs += 3 + (same_col - 5);
        }
        if same_row >= 5 {
            runs += 3 + (same_row - 5);
        }
    }
    let mut blocks = 0u32;
    for row in 0..size - 1 {
        for col in 0..size - 1 {
            let sum = at(row, col) + at(row, col + 1) + at(row + 1, col) + at(row + 1, col + 1);
            if sum == 4 || sum == 0 {
                blocks += 1;
            }
        }
    }
    let dark = modules.iter().filter(|&&dark| dark).count() as f64;
    let total = (size * size) as f64;
    let steps = ((dark * 100.0 / total) / 5.0).ceil();
    let balance = (steps - 10.0).abs() as u32;
    runs + blocks * 3 + finder * 40 + balance * 10
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pairing_qr::fixtures::{config_only, largest, seeded};

    /// FNV-1a over the modules as `0`/`1` characters, row by row.
    fn fingerprint(symbol: &Symbol) -> u64 {
        symbol
            .modules
            .iter()
            .fold(0xcbf2_9ce4_8422_2325u64, |hash, &dark| {
                (hash ^ u64::from(if dark { b'1' } else { b'0' })).wrapping_mul(0x0100_0000_01b3)
            })
    }

    fn dark(symbol: &Symbol) -> usize {
        symbol.modules.iter().filter(|&&dark| dark).count()
    }

    // The expected values come from `QRCode.create(code, { errorCorrectionLevel: "L" })`
    // of the qrcode package, hashed the same way.
    #[test]
    fn the_modules_equal_what_the_qrcode_package_builds_for_the_vectors() {
        let (_, seeded_code) = seeded();
        let (_, largest_code) = largest();
        for (code, version, size, count, hash) in [
            (seeded_code, 10, 57, 1664, 0x8fa4_8154_f9ad_c685),
            (largest_code, 11, 61, 1844, 0x3023_c653_8e42_39c9),
            (config_only(), 7, 45, 1052, 0xa18d_5621_7bf6_dbc7),
        ] {
            let symbol = create(&code).unwrap();
            assert_eq!((symbol.version, symbol.size), (version, size));
            assert_eq!(dark(&symbol), count);
            assert_eq!(fingerprint(&symbol), hash);
        }
    }

    #[test]
    fn text_is_split_where_the_package_splits_it() {
        let modes = |text: &str| {
            raw_split(text)
                .iter()
                .map(|s| (s.mode, s.data.to_string()))
                .collect::<Vec<_>>()
        };
        assert_eq!(
            modes("HERDR-PAIR:1:eyJh"),
            [
                (Mode::Alphanumeric, "HERDR-PAIR:".to_string()),
                (Mode::Numeric, "1".to_string()),
                (Mode::Alphanumeric, ":".to_string()),
                (Mode::Byte, "ey".to_string()),
                (Mode::Alphanumeric, "J".to_string()),
                (Mode::Byte, "h".to_string()),
            ]
        );
    }

    #[test]
    fn a_digit_run_is_cheapest_in_the_mode_the_package_picks() {
        let digits = "7".repeat(30);
        let segments = optimize(&raw_split(&digits), 1);
        assert_eq!(segments.len(), 1);
        assert_eq!(segments[0].mode, Mode::Numeric);
        let mixed = format!("{digits}abc");
        let modes: Vec<Mode> = optimize(&raw_split(&mixed), 1)
            .iter()
            .map(|s| s.mode)
            .collect();
        assert_eq!(modes, [Mode::Numeric, Mode::Byte]);
    }

    #[test]
    fn empty_and_oversized_text_fail_with_the_package_messages() {
        assert_eq!(create("").unwrap_err().message(), "No input text");
        assert_eq!(
            create(&"x".repeat(2954)).unwrap_err().message(),
            "The amount of data is too big to be stored in a QR Code"
        );
        assert_eq!(create(&"x".repeat(2953)).unwrap().version, 40);
    }
}
