//! The Pairing Code screen, fitted to the popup pane (pairing-qr.js, issue #65).
//!
//! A zoomed terminal font leaves too few rows for the half-block QR, and a
//! clipped QR is unscannable, so the QR falls back to sextants (2x3 modules
//! per cell, two thirds of the half-block's rows) and, when even that cannot
//! fit, asks for a bigger pane instead of drawing a QR the phone cannot read.

use crate::envelope::{PairingPayload, encode_pairing_code};
use crate::error::{CliError, Result};
use crate::qr_symbol::{self, Symbol};

// Black modules on a white background, as qrcode's terminal renderer draws
// them: not every decoder tries light-on-dark, and an explicit background
// keeps the polarity independent of the terminal theme.
const LINE_SETUP: &str = "\u{1b}[47m\u{1b}[30m";
pub const RESET: &str = "\u{1b}[0m";
pub const BOLD: &str = "\u{1b}[1m";
pub const DIM: &str = "\u{1b}[2m";

const HALF_BLOCKS: [&str; 4] = [" ", "\u{2580}", "\u{2584}", "\u{2588}"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Layout {
    HalfBlock,
    Sextant,
    TooSmall,
    /// The QR would fit, but not together with the printed Pairing Code.
    CodeOnly,
}

impl Layout {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::HalfBlock => "half-block",
            Self::Sextant => "sextant",
            Self::TooSmall => "too-small",
            Self::CodeOnly => "code-only",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        [
            Self::HalfBlock,
            Self::Sextant,
            Self::TooSmall,
            Self::CodeOnly,
        ]
        .into_iter()
        .find(|layout| layout.as_str() == name)
    }

    fn cells(self) -> Option<Cells> {
        match self {
            Self::HalfBlock => Some(Cells::HalfBlock),
            Self::Sextant => Some(Cells::Sextant),
            Self::TooSmall | Self::CodeOnly => None,
        }
    }
}

/// How many modules one terminal cell covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cells {
    HalfBlock,
    Sextant,
}

impl Cells {
    fn size(self) -> (usize, usize) {
        match self {
            Self::HalfBlock => (1, 2),
            Self::Sextant => (2, 3),
        }
    }

    fn glyph(self, mask: usize, out: &mut String) {
        match self {
            Self::HalfBlock => out.push_str(HALF_BLOCKS[mask]),
            Self::Sextant => out.push(sextant_glyph(mask)),
        }
    }
}

/// The pane size in terminal cells. A size that is not a positive integer
/// (the output is not a terminal, or it never reported its size) is unknown
/// and counts as unbounded.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Pane {
    pub columns: Option<usize>,
    pub rows: Option<usize>,
}

/// A pane size that is known: positive.
fn known(size: Option<usize>) -> Option<usize> {
    size.filter(|&size| size > 0)
}

impl Pane {
    pub fn new(columns: usize, rows: usize) -> Self {
        Self {
            columns: Some(columns),
            rows: Some(rows),
        }
    }

    fn columns(self) -> Option<usize> {
        known(self.columns)
    }

    fn rows(self) -> Option<usize> {
        known(self.rows)
    }
}

/// Glyph for a 2x3 cell. Bits, top to bottom and left to right: 0 top-left,
/// 1 top-right, 2 mid-left, 3 mid-right, 4 bottom-left, 5 bottom-right; a set
/// bit is a dark module. Unicode's Symbols for Legacy Computing block omits
/// the three sextants that already exist as blank, left half and right half
/// blocks, so later masks shift down past each gap.
pub fn sextant_glyph(mask: usize) -> char {
    match mask {
        0 => ' ',
        63 => '\u{2588}',
        21 => '\u{258C}',
        42 => '\u{2590}',
        _ => {
            let gaps = usize::from(mask > 21) + usize::from(mask > 42);
            // Masks are at most 6 bits, so the code point is in the block.
            char::from_u32(0x1fb00 + (mask - 1 - gaps) as u32).unwrap_or(' ')
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Footprint {
    pub columns: usize,
    pub rows: usize,
}

/// Cells a layout needs for a QR of `module_size` modules plus its 1-module
/// quiet zone.
pub fn qr_footprint(module_size: usize, cells: Cells) -> Footprint {
    let n = module_size + 2;
    let (width, height) = cells.size();
    Footprint {
        columns: n.div_ceil(width),
        rows: n.div_ceil(height),
    }
}

fn fits_within(limit: Option<usize>, needed: usize) -> bool {
    limit.is_none_or(|limit| needed <= limit)
}

pub fn choose_qr_layout(module_size: usize, pane: Pane) -> Layout {
    for (layout, cells) in [
        (Layout::HalfBlock, Cells::HalfBlock),
        (Layout::Sextant, Cells::Sextant),
    ] {
        let needed = qr_footprint(module_size, cells);
        if fits_within(pane.columns(), needed.columns) && fits_within(pane.rows(), needed.rows) {
            return layout;
        }
    }
    Layout::TooSmall
}

/// A QR drawn with `cells`, one string per terminal row.
fn render_cells(code: &Symbol, cells: Cells) -> Vec<String> {
    let size = code.size;
    let (width, height) = cells.size();
    let n = size + 2;
    // Grid coordinates include the quiet zone: module (x, y) sits at (x+1, y+1).
    // Everything outside the matrix, quiet zone and cell padding alike, is light.
    let dark = |gx: usize, gy: usize| {
        (1..=size).contains(&gx) && (1..=size).contains(&gy) && code.is_dark(gx - 1, gy - 1)
    };
    let mut lines = Vec::with_capacity(n.div_ceil(height));
    for gy in (0..n).step_by(height) {
        let mut line = String::from(LINE_SETUP);
        for gx in (0..n).step_by(width) {
            let mut mask = 0;
            for row in 0..height {
                for col in 0..width {
                    if dark(gx + col, gy + row) {
                        mask |= 1 << (row * width + col);
                    }
                }
            }
            cells.glyph(mask, &mut line);
        }
        line.push_str(RESET);
        lines.push(line);
    }
    lines
}

/// `line` without its SGR color sequences (`ESC [ digits and ; m`).
pub fn visible_text(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut rest = line;
    while let Some(start) = rest.find('\u{1b}') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        let sequence = after.strip_prefix('[').and_then(|params| {
            let end = params.find(|c: char| !(c.is_ascii_digit() || c == ';'))?;
            params[end..].starts_with('m').then_some(end + 2)
        });
        match sequence {
            Some(length) => rest = &after[length..],
            None => {
                out.push('\u{1b}');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Qr {
    pub layout: Layout,
    pub lines: Vec<String>,
    /// The smallest pane that shows a QR.
    pub needs: Footprint,
}

/// The QR lines that fit `pane`, or none when even the sextant QR would be
/// clipped.
pub fn render_pairing_qr(code: &str, pane: Pane) -> Result<Qr> {
    let modules = qr_symbol::create(code)?;
    let layout = choose_qr_layout(modules.size, pane);
    let needs = qr_footprint(modules.size, Cells::Sextant);
    let lines = match layout.cells() {
        Some(cells) => render_cells(&modules, cells),
        None => Vec::new(),
    };
    Ok(Qr {
        layout,
        lines,
        needs,
    })
}

// Over-estimates on purpose: an East Asian wide character takes two columns,
// and counting one would let a wrapped line scroll the QR's top edge away.
fn display_width(text: &str) -> usize {
    text.chars().map(|c| if c.is_ascii() { 1 } else { 2 }).sum()
}

fn line_rows(line: &str, columns: Option<usize>) -> usize {
    let width = display_width(&visible_text(line));
    match known(columns) {
        Some(columns) => width.div_ceil(columns).max(1),
        None => 1,
    }
}

fn pane_rows<S: AsRef<str>>(lines: &[S], columns: Option<usize>) -> usize {
    lines
        .iter()
        .map(|line| line_rows(line.as_ref(), columns))
        .sum()
}

/// The longest prefix of `lines` that fits in `rows` pane rows, where a line
/// wider than the pane wraps onto as many rows as it covers. `rows` of `None`
/// keeps every line; unknown `columns` count one row per line.
pub fn clamp_to_pane<S: AsRef<str>>(
    lines: &[S],
    columns: Option<usize>,
    rows: Option<usize>,
) -> &[S] {
    let Some(rows) = rows else {
        return lines;
    };
    let mut used = 0;
    let mut kept = 0;
    for line in lines {
        used += line_rows(line.as_ref(), columns);
        if used > rows {
            break;
        }
        kept += 1;
    }
    &lines[..kept]
}

fn too_small_notice(needs: Footprint, pane: Pane) -> Vec<String> {
    let now = match (pane.columns(), pane.rows()) {
        (Some(columns), Some(rows)) => format!(", now {columns} x {rows}"),
        _ => String::new(),
    };
    vec![
        format!("{BOLD}Window too small for the QR code{RESET}"),
        "Zoom out (Cmd - or Ctrl -) or enlarge the window".to_string(),
        format!("Needs {} columns x {} rows{now}", needs.columns, needs.rows),
    ]
}

fn hint_line(layout: Layout, copied: bool) -> String {
    // Only the full-size QR closes on any key; see `qr_key_action`.
    let close = if layout == Layout::HalfBlock {
        "any other key close"
    } else {
        "q close"
    };
    if copied {
        format!("{BOLD}copied{RESET} {DIM}-- {close}{RESET}")
    } else if matches!(layout, Layout::HalfBlock | Layout::Sextant) {
        format!("{BOLD}Scan with Waycar{RESET} {DIM}-- c: copy pairing code, {close}{RESET}")
    } else {
        format!("c: copy pairing code, {close}")
    }
}

/// What the QR screen shows besides the payload.
#[derive(Debug, Clone, Copy, Default)]
pub struct ScreenView<'a> {
    pub copied: bool,
    /// Set when copying failed: shown under the hint.
    pub printed_code: Option<&'a str>,
    pub pane: Pane,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Screen {
    pub code: String,
    pub layout: Layout,
    pub lines: Vec<String>,
}

/// The whole QR screen for `payload`, its code and the layout it drew.
/// When the QR, hint and printed code cannot share the pane, the QR gives way
/// to the code. `expires_text` is the clock time the code stays valid until.
pub fn render_pairing_screen(
    payload: &PairingPayload,
    view: ScreenView<'_>,
    expires_text: &str,
) -> Result<Screen> {
    let code = encode_pairing_code(payload).map_err(|error| CliError::failure(error.message))?;
    let pane = view.pane;
    let qr = render_pairing_qr(&code, pane)?;
    let mut layout = qr.layout;
    if layout != Layout::TooSmall
        && let Some(printed) = view.printed_code
        && let Some(rows) = pane.rows()
    {
        let tail = [hint_line(layout, view.copied), printed.to_string()];
        if qr.lines.len() + pane_rows(&tail, pane.columns) > rows {
            layout = Layout::CodeOnly;
        }
    }
    let hint = hint_line(layout, view.copied);
    if matches!(layout, Layout::TooSmall | Layout::CodeOnly) {
        let notice = if layout == Layout::TooSmall {
            too_small_notice(qr.needs, pane)
        } else {
            Vec::new()
        };
        let Some(printed) = view.printed_code else {
            let mut lines = notice;
            lines.push(hint);
            let kept = clamp_to_pane(&lines, pane.columns, pane.rows).len();
            lines.truncate(kept);
            return Ok(Screen {
                code,
                layout,
                lines,
            });
        };
        // No QR can scroll away here, so the code the user asked for is never
        // clamped; the notice only gets the rows left over.
        let head = [hint, printed.to_string()];
        let spare = pane
            .rows()
            .map(|rows| rows.saturating_sub(pane_rows(&head, pane.columns)));
        let kept = clamp_to_pane(&notice, pane.columns, spare).len();
        let mut lines = Vec::from(head);
        lines.extend(notice.into_iter().take(kept));
        return Ok(Screen {
            code,
            layout,
            lines,
        });
    }
    let mut footer = vec![hint];
    footer.extend(view.printed_code.map(str::to_string));
    // A terminal that draws sextants from its font shows boxes when the font
    // has none, as with macOS's Menlo, SF Mono and Monaco.
    if layout == Layout::Sextant {
        footer
            .push("Boxes instead of a QR? Zoom out (Cmd - or Ctrl -) or enlarge the window".into());
    }
    footer.push(format!(
        "{BOLD}{}{RESET} on port {BOLD}{}{RESET}",
        payload.username, payload.port
    ));
    footer.push(format!("Host key {}", payload.host_key_fingerprint));
    footer.push(format!("Addresses: {}", payload.addresses.join(", ")));
    footer.push(format!(
        "Code valid until {BOLD}{expires_text}{RESET}, single use"
    ));
    // QR first, starting at row 1. The QR fits the pane by construction; the
    // footer gets the rows left over, since writing past the last pane row
    // (wrapped text included) would scroll the QR's top edge away.
    let footer_rows = pane.rows().map(|rows| rows.saturating_sub(qr.lines.len()));
    let kept = clamp_to_pane(&footer, pane.columns, footer_rows).len();
    let mut lines = qr.lines;
    lines.extend(footer.into_iter().take(kept));
    Ok(Screen {
        code,
        layout,
        lines,
    })
}

/// The local clock time of a Unix timestamp as `new Date(s * 1000)
/// .toLocaleTimeString()` prints it in en-US: `3:07:09 PM`.
pub fn expiry_text(unix_seconds: i64) -> String {
    unsafe extern "C" {
        // POSIX, but missing from the libc crate's bindings.
        fn tzset();
    }
    // SAFETY: tm is plain integers and pointers; zeroed is a valid value.
    let mut local: libc::tm = unsafe { std::mem::zeroed() };
    let seconds = unix_seconds as libc::time_t;
    // SAFETY: both pointers are valid for the call. tzset first so a TZ
    // change since the last call is seen (localtime_r need not read it).
    let converted = unsafe {
        tzset();
        libc::localtime_r(&seconds, &mut local)
    };
    if converted.is_null() {
        return "Invalid Date".to_string();
    }
    clock_text(local.tm_hour, local.tm_min, local.tm_sec)
}

/// en-US's 12-hour clock: no leading zero on the hour, an ASCII space.
fn clock_text(hour: i32, minute: i32, second: i32) -> String {
    let shown = match hour % 12 {
        0 => 12,
        hour => hour,
    };
    let meridiem = if hour < 12 { "AM" } else { "PM" };
    format!("{shown}:{minute:02}:{second:02} {meridiem}")
}

/// The Pairing Code vectors and the payloads the JS tests build from them.
#[cfg(test)]
pub(crate) mod fixtures {
    use serde_json::Value;

    use crate::envelope::{PairingPayload, encode_pairing_code};

    const VECTORS: &str = include_str!("../test-vectors/pairing-code-v1.json");

    fn valid() -> Vec<Value> {
        let all: Value = serde_json::from_str(VECTORS).expect("vectors parse");
        all["valid"].as_array().expect("valid vectors").clone()
    }

    fn payload_of(vector: &Value) -> PairingPayload {
        let json = &vector["payload"];
        let strings = |value: &Value| -> Vec<String> {
            value
                .as_array()
                .expect("a list")
                .iter()
                .map(|v| v.as_str().expect("a string").to_string())
                .collect()
        };
        PairingPayload {
            addresses: strings(&json["addresses"]),
            port: json["port"].as_u64().expect("port") as u32,
            username: json["username"].as_str().expect("username").to_string(),
            host_key_fingerprint: json["hostKeyFingerprint"]
                .as_str()
                .expect("fingerprint")
                .to_string(),
            bootstrap_seed: json["bootstrapSeed"].as_str().map(crate::base64::decode),
            expires_at: json["expiresAt"].as_i64(),
        }
    }

    /// The vector with a Bootstrap Key: its payload and its code.
    pub fn seeded() -> (PairingPayload, String) {
        let vector = valid()
            .into_iter()
            .find(|v| v["payload"]["bootstrapSeed"].is_string())
            .expect("a seeded vector");
        let code = vector["code"].as_str().expect("code").to_string();
        (payload_of(&vector), code)
    }

    /// The largest realistic code: a Bootstrap Key plus three addresses.
    pub fn largest() -> (PairingPayload, String) {
        let (mut payload, _) = seeded();
        let three = valid()
            .into_iter()
            .find(|v| v["payload"]["addresses"].as_array().map(Vec::len) == Some(3))
            .expect("a three-address vector");
        payload.addresses = payload_of(&three).addresses;
        let code = encode_pairing_code(&payload).expect("encodes");
        (payload, code)
    }

    /// The first vector: no Bootstrap Key.
    pub fn config_only() -> String {
        valid()[0]["code"].as_str().expect("code").to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::{largest, seeded};
    use super::*;

    // At ECC L the seeded code is a version 10 QR (57 modules, 59 with the
    // quiet zone): half blocks need 59 x 30 cells, sextants 30 x 20. The
    // largest code is version 11 (61 modules, 63 with the quiet zone): 63 x 32
    // and 32 x 21.
    const HALF: Pane = Pane {
        columns: Some(59),
        rows: Some(30),
    };
    const SEXTANT: Pane = Pane {
        columns: Some(30),
        rows: Some(20),
    };

    fn pane(columns: usize, rows: usize) -> Pane {
        Pane::new(columns, rows)
    }

    fn layout_at(code: &str, pane: Pane) -> Layout {
        render_pairing_qr(code, pane).unwrap().layout
    }

    fn visible_lines(lines: &[String]) -> Vec<String> {
        lines.iter().map(|line| visible_text(line)).collect()
    }

    fn screen_of(payload: &PairingPayload, view: ScreenView<'_>) -> Screen {
        render_pairing_screen(payload, view, "3:07:09 PM").unwrap()
    }

    fn view(pane: Pane) -> ScreenView<'static> {
        ScreenView {
            pane,
            ..ScreenView::default()
        }
    }

    #[test]
    fn half_block_when_it_fits_exactly_sextant_one_row_or_column_short() {
        let (_, seeded) = seeded();
        assert_eq!(layout_at(&seeded, HALF), Layout::HalfBlock);
        assert_eq!(layout_at(&seeded, pane(59, 29)), Layout::Sextant);
        assert_eq!(layout_at(&seeded, pane(58, 30)), Layout::Sextant);
    }

    #[test]
    fn sextant_when_it_fits_exactly_too_small_one_row_or_column_short() {
        let (_, seeded) = seeded();
        assert_eq!(layout_at(&seeded, SEXTANT), Layout::Sextant);
        assert_eq!(layout_at(&seeded, pane(30, 19)), Layout::TooSmall);
        assert_eq!(layout_at(&seeded, pane(29, 20)), Layout::TooSmall);
    }

    #[test]
    fn the_largest_realistic_code_has_the_same_boundaries_one_version_up() {
        let (_, code) = largest();
        assert_eq!(layout_at(&code, pane(63, 32)), Layout::HalfBlock);
        assert_eq!(layout_at(&code, pane(62, 32)), Layout::Sextant);
        assert_eq!(layout_at(&code, pane(63, 31)), Layout::Sextant);
        assert_eq!(layout_at(&code, pane(32, 21)), Layout::Sextant);
        assert_eq!(layout_at(&code, pane(31, 21)), Layout::TooSmall);
        assert_eq!(layout_at(&code, pane(32, 20)), Layout::TooSmall);
    }

    #[test]
    fn an_unknown_pane_size_is_unbounded() {
        let (_, seeded) = seeded();
        let at = |columns, rows| layout_at(&seeded, Pane { columns, rows });
        assert_eq!(at(None, None), Layout::HalfBlock);
        assert_eq!(at(Some(0), Some(0)), Layout::HalfBlock);
        assert_eq!(at(Some(59), None), Layout::HalfBlock);
        assert_eq!(at(None, Some(20)), Layout::Sextant);
    }

    #[test]
    fn the_half_block_qr_uses_exactly_its_footprint_in_rows_and_columns() {
        let (_, seeded) = seeded();
        let qr = render_pairing_qr(&seeded, HALF).unwrap();
        assert_eq!(qr.lines.len(), 30);
        for line in &qr.lines {
            assert_eq!(visible_text(line).chars().count(), 59);
        }
    }

    #[test]
    fn the_sextant_qr_uses_ceil_n_over_3_rows_of_ceil_n_over_2_cells() {
        let (_, seeded) = seeded();
        let qr = render_pairing_qr(&seeded, SEXTANT).unwrap();
        assert_eq!(qr.lines.len(), 20);
        for line in &qr.lines {
            assert_eq!(visible_text(line).chars().count(), 30);
        }
    }

    #[test]
    fn sextant_glyphs_map_to_the_unicode_block_sextants_and_reuse_the_older_blocks() {
        for (mask, expected) in [
            (1, '\u{1FB00}'),
            (2, '\u{1FB01}'),
            (3, '\u{1FB02}'),
            (20, '\u{1FB13}'),
            (22, '\u{1FB14}'),
            (41, '\u{1FB27}'),
            (43, '\u{1FB28}'),
            (62, '\u{1FB3B}'),
            (0, ' '),
            (21, '\u{258C}'),
            (42, '\u{2590}'),
            (63, '\u{2588}'),
        ] {
            assert_eq!(sextant_glyph(mask), expected, "mask {mask}");
        }
    }

    #[test]
    fn the_other_60_masks_cover_the_sextant_block_one_to_one_in_order() {
        let code_points: Vec<u32> = (0..64)
            .filter(|mask| ![0, 21, 42, 63].contains(mask))
            .map(|mask| u32::from(sextant_glyph(mask)))
            .collect();
        assert_eq!(code_points, (0x1fb00..0x1fb00 + 60).collect::<Vec<_>>());
    }

    // Written out by hand rather than taken from the renderer, so a swapped
    // glyph or bit order fails. Bits run left to right, then top to bottom.
    fn cells_reproduce_the_matrix(
        pane: Pane,
        width: usize,
        height: usize,
        mask_of: impl Fn(char) -> Option<usize>,
    ) {
        let (_, seeded) = seeded();
        let qr = render_pairing_qr(&seeded, pane).unwrap();
        let symbol = qr_symbol::create(&seeded).unwrap();
        for (cell_y, line) in qr.lines.iter().enumerate() {
            for (cell_x, glyph) in visible_text(line).chars().enumerate() {
                let mask = mask_of(glyph).unwrap_or_else(|| panic!("unexpected glyph {glyph}"));
                for bit in 0..width * height {
                    let gx = cell_x * width + bit % width;
                    let gy = cell_y * height + bit / width;
                    let inside = gx >= 1 && gy >= 1 && gx <= symbol.size && gy <= symbol.size;
                    let expected = inside && symbol.is_dark(gx - 1, gy - 1);
                    assert_eq!(mask & (1 << bit) != 0, expected, "module at {gx},{gy}");
                }
            }
        }
    }

    #[test]
    fn half_block_cells_reproduce_the_qr_matrix_inside_a_light_quiet_zone() {
        cells_reproduce_the_matrix(HALF, 1, 2, |glyph| match glyph {
            ' ' => Some(0),
            '\u{2580}' => Some(1),
            '\u{2584}' => Some(2),
            '\u{2588}' => Some(3),
            _ => None,
        });
    }

    #[test]
    fn sextant_cells_reproduce_the_qr_matrix_inside_a_light_quiet_zone() {
        cells_reproduce_the_matrix(SEXTANT, 2, 3, |glyph| {
            (0..64).find(|&mask| sextant_glyph(mask) == glyph)
        });
    }

    #[test]
    fn an_80_x_24_pane_draws_the_largest_code_as_a_sextant_qr() {
        let (payload, _) = largest();
        let screen = screen_of(&payload, view(pane(80, 24)));
        assert_eq!(screen.layout, Layout::Sextant);
    }

    #[test]
    fn a_footer_that_would_wrap_past_the_pane_is_dropped_never_qr_rows() {
        // The hint is wider than 40 columns, so it alone takes the last two rows.
        let (payload, seeded) = seeded();
        let size = pane(40, 22);
        let qr = render_pairing_qr(&seeded, size).unwrap();
        let screen = screen_of(&payload, view(size));
        assert_eq!(qr.lines.len(), 20);
        assert_eq!(screen.lines[..20], qr.lines[..]);
        assert_eq!(screen.lines.len(), 21);
    }

    #[test]
    fn a_pane_exactly_the_qrs_footprint_shows_the_qr_and_no_footer() {
        let (payload, seeded) = seeded();
        for size in [HALF, SEXTANT] {
            let qr = render_pairing_qr(&seeded, size).unwrap();
            assert_eq!(screen_of(&payload, view(size)).lines, qr.lines);
        }
    }

    #[test]
    fn the_too_small_screen_names_the_size_it_needs_and_offers_the_copy() {
        let (payload, _) = seeded();
        let screen = screen_of(&payload, view(pane(29, 19)));
        let text = visible_lines(&screen.lines).join("\n");
        assert_eq!(screen.layout, Layout::TooSmall);
        assert!(text.contains("Needs 30 columns x 20 rows, now 29 x 19"));
        assert!(text.contains("c: copy pairing code"));
        assert!(!text.contains("Scan") && !text.contains("Host key"));
    }

    #[test]
    fn an_unknown_pane_width_never_reports_an_undefined_size() {
        let (payload, _) = seeded();
        let screen = screen_of(
            &payload,
            view(Pane {
                columns: None,
                rows: Some(10),
            }),
        );
        assert_eq!(screen.layout, Layout::TooSmall);
        let text = visible_lines(&screen.lines).join("\n");
        assert!(
            text.contains("Needs 30 columns x 20 rows\n")
                || text.ends_with("Needs 30 columns x 20 rows")
        );
        assert!(!text.contains("now"));
    }

    #[test]
    fn a_printed_code_that_cannot_share_the_pane_with_the_qr_replaces_it() {
        // The sextant QR fills all 20 rows of this pane, leaving none for the
        // hint and the 244-character code (nine rows at 30 columns).
        let (payload, seeded) = seeded();
        let screen = screen_of(
            &payload,
            ScreenView {
                printed_code: Some(&seeded),
                pane: SEXTANT,
                ..ScreenView::default()
            },
        );
        assert_eq!(screen.layout, Layout::CodeOnly);
        assert!(screen.lines.contains(&seeded));
        assert!(screen.lines.len() < 5);
        let block_glyph =
            |c: char| matches!(c, '\u{2580}'..='\u{259F}' | '\u{1FB00}'..='\u{1FB3B}');
        assert!(
            visible_lines(&screen.lines)
                .iter()
                .all(|line| !line.chars().any(block_glyph))
        );
    }

    #[test]
    fn a_printed_code_that_fits_goes_right_under_the_qr_and_its_hint() {
        let (payload, seeded) = seeded();
        let size = pane(120, 60);
        let qr_rows = render_pairing_qr(&seeded, size).unwrap().lines.len();
        let screen = screen_of(
            &payload,
            ScreenView {
                printed_code: Some(&seeded),
                pane: size,
                ..ScreenView::default()
            },
        );
        assert_eq!(screen.layout, Layout::HalfBlock);
        assert!(visible_text(&screen.lines[qr_rows]).contains("Scan with Waycar"));
        assert_eq!(screen.lines[qr_rows + 1], seeded);
    }

    #[test]
    fn a_line_exactly_as_wide_as_the_pane_takes_one_row() {
        let lines = ["\u{1b}[1mabcd\u{1b}[0m", "efgh", "ijklm"];
        let clamp = |rows| clamp_to_pane(&lines, Some(4), Some(rows)).len();
        assert_eq!(clamp(2), 2);
        assert_eq!(clamp(3), 2);
        assert_eq!(clamp(4), 3);
    }

    #[test]
    fn non_ascii_text_is_budgeted_at_two_columns_per_character() {
        // Three Hangul syllables are six columns wide: two rows of a 4-column pane.
        let lines = ["\u{c624}\u{d6c4}\u{c624}", "x"];
        assert_eq!(clamp_to_pane(&lines, Some(4), Some(2)), &lines[..1]);
        assert_eq!(clamp_to_pane(&lines, Some(4), Some(3)), &lines[..]);
    }

    #[test]
    fn an_empty_line_takes_a_row() {
        let lines = ["", "", "x"];
        assert_eq!(clamp_to_pane(&lines, Some(10), Some(2)), &lines[..2]);
    }

    #[test]
    fn a_zero_budget_keeps_nothing() {
        assert!(clamp_to_pane(&["a"], Some(10), Some(0)).is_empty());
    }

    #[test]
    fn an_unknown_width_counts_one_row_per_line() {
        let lines = ["abcdefgh", "x"];
        assert_eq!(clamp_to_pane(&lines, None, Some(1)), &lines[..1]);
    }

    #[test]
    fn an_unknown_height_keeps_every_line() {
        let lines = ["a", "b"];
        assert_eq!(clamp_to_pane(&lines, Some(10), None), &lines[..]);
    }

    #[test]
    fn visible_text_drops_color_sequences_and_nothing_else() {
        assert_eq!(visible_text("\u{1b}[1mbold\u{1b}[0m"), "bold");
        assert_eq!(visible_text("\u{1b}[47m\u{1b}[30m x\u{1b}[0m"), " x");
        assert_eq!(visible_text("\u{1b}[?25l\u{1b}[1A"), "\u{1b}[?25l\u{1b}[1A");
        assert_eq!(visible_text("a\u{1b}b\u{1b}"), "a\u{1b}b\u{1b}");
    }

    #[test]
    fn the_expiry_is_a_12_hour_clock_time_with_am_pm() {
        assert_eq!(clock_text(0, 0, 0), "12:00:00 AM");
        assert_eq!(clock_text(0, 5, 9), "12:05:09 AM");
        assert_eq!(clock_text(9, 7, 9), "9:07:09 AM");
        assert_eq!(clock_text(12, 0, 0), "12:00:00 PM");
        assert_eq!(clock_text(15, 7, 9), "3:07:09 PM");
        assert_eq!(clock_text(23, 59, 59), "11:59:59 PM");
    }
}
