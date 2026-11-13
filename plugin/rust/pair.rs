//! `waycar pair`: the Pairing Code popup in this terminal (pair-popup.js, with
//! pairing_qr, select_list, copy_pairing_code and pair_fatal).
//!
//! Flow: sweep stale bootstrap lines, enumerate candidate addresses, the user
//! confirms the checklist, a Bootstrap Key is minted and the Pairing Code QR
//! shown. The Bootstrap Key's restricted authorized_keys line lives exactly as
//! long as this popup and its 2-minute TTL, whichever ends first; Enrollment
//! itself happens in `pair_accept`, run by sshd as the forced command.
//!
//! What the user sees is a pure function of the state ([`Machine`] and the
//! `*_screen` functions); [`Popup`] is the thin terminal loop around them.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::addresses::{Platform, candidate_addresses, network_interfaces};
use crate::authorized_keys::{comment_of, remove_key_line, sweep_expired_bootstrap_lines};
use crate::copy_pairing_code::{KeyAction, copy_pairing_code, qr_key_action, run_with_input};
use crate::envelope::PairingPayload;
use crate::error::{CliError, EXIT_FAILURE, Result};
use crate::herdr::run_herdr;
use crate::host_key::{DEFAULT_SSH_DIR, read_host_key_fingerprint};
use crate::keypress::{Decoder, ESCAPE_CODE_TIMEOUT, Key, Name};
use crate::native::Ctx;
use crate::pair_fatal::{MISSING_ADDRESS, MISSING_HOST_KEY, fatal_lines, pairing_start_failed};
use crate::pairing_qr::{BOLD, DIM, Layout, RESET, ScreenView, expiry_text, render_pairing_screen};
use crate::pairing_session::{
    Enrollment, PAIRING_TTL_SECONDS, PairingSession, begin_pairing, end_pairing, expire_pairing,
    now_seconds, read_enrollment, sweep_expired_state_files,
};
use crate::paths::resolve_host_config;
use crate::select_list::Selection;
use crate::tty::{self, STDIN, STDOUT, Signals};

const DEFAULT_SSH_PORT: u32 = 22;
/// How often the QR screen checks whether Enrollment has completed. The
/// pending -> enrolled transition happens server-side in `pair_accept`;
/// polling the record it leaves is simpler than a file watch and just as
/// timely at human scale.
const ENROLL_POLL: Duration = Duration::from_millis(400);
/// How long "copied" stays on the QR screen.
const COPIED_NOTICE: Duration = Duration::from_millis(1500);

// 2J clears the visible screen only; a QR taller than the viewport pushes rows
// into scrollback, which would resurface above later screens. 3J drops the
// scrollback too.
const CLEAR: &str = "\u{1b}[2J\u{1b}[3J\u{1b}[H";
const HIDE_CURSOR: &str = "\u{1b}[?25l";
const SHOW_CURSOR: &str = "\u{1b}[?25h";
const REVERSE: &str = "\u{1b}[7m";

// ---- screens: pure text ----

fn screen(lines: &[String]) -> String {
    format!("{CLEAR}{}\n", lines.join("\n"))
}

fn fatal_screen(message: &str) -> String {
    let mut lines: Vec<String> = fatal_lines(message).iter().map(|s| s.to_string()).collect();
    lines[0] = format!("{BOLD}{}{RESET}", lines[0]);
    let last = lines.len() - 1;
    lines[last] = format!("{DIM}{}{RESET}", lines[last]);
    screen(&lines)
}

fn checklist_screen(selection: &Selection, warning: Option<&str>) -> String {
    let mut lines = vec![
        format!("{BOLD}Pair a Waycar device{RESET}"),
        String::new(),
        "Select the addresses the phone can reach this machine on:".to_string(),
        String::new(),
    ];
    for (index, item) in selection.items.iter().enumerate() {
        let cursor = if index == selection.cursor {
            format!("{REVERSE}>")
        } else {
            " ".to_string()
        };
        let box_ = if item.checked { "[x]" } else { "[ ]" };
        let candidate = &item.candidate;
        let label = format!(
            "{} {DIM}({}, {}){RESET}",
            candidate.address,
            candidate.interface_name,
            candidate.family.as_str()
        );
        lines.push(format!(" {cursor} {box_} {label}{RESET}"));
    }
    lines.push(String::new());
    lines.push(format!(
        "{DIM}up/down move, space toggle, a all, enter confirm, q quit{RESET}"
    ));
    if let Some(warning) = warning {
        lines.push(String::new());
        lines.push(format!("{BOLD}{warning}{RESET}"));
    }
    screen(&lines)
}

fn expired_screen() -> String {
    screen(&[
        format!("{BOLD}Pairing Code expired{RESET}"),
        String::new(),
        "The Bootstrap Key was removed; the old QR is now useless.".to_string(),
        String::new(),
        format!("{DIM}enter generate a new code, any other key close{RESET}"),
    ])
}

fn enrolled_screen(record: &Enrollment) -> String {
    let comment = comment_of(&record.line);
    let label = if comment.is_empty() {
        format!("{DIM}(no label){RESET}")
    } else {
        format!("{BOLD}{comment}{RESET}")
    };
    screen(&[
        format!("{BOLD}Device paired{RESET}"),
        String::new(),
        "A device just enrolled its Device Key on this machine:".to_string(),
        String::new(),
        format!("  Fingerprint  {BOLD}{}{RESET}", record.fingerprint),
        format!("  Label        {label}"),
        String::new(),
        "If this was not you, revoke it now to lock that device out.".to_string(),
        String::new(),
        format!("{DIM}r revoke this device, any other key close{RESET}"),
    ])
}

fn revoked_screen(record: &Enrollment) -> String {
    screen(&[
        format!("{BOLD}Device Key revoked{RESET}"),
        String::new(),
        format!("{DIM}{}{RESET}", record.fingerprint),
        "was removed from authorized_keys; that device can no longer connect.".to_string(),
        String::new(),
        format!("{DIM}Press any key to close.{RESET}"),
    ])
}

fn revoke_failed_screen(message: &str) -> String {
    screen(&[
        format!("{BOLD}Could not revoke the Device Key{RESET}"),
        String::new(),
        message.to_string(),
        String::new(),
        "Remove the enrolled line from ~/.ssh/authorized_keys by hand.".to_string(),
        String::new(),
        format!("{DIM}Press any key to close.{RESET}"),
    ])
}

// ---- the state machine: keys in, what to do out ----

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Select,
    Qr,
    Expiring,
    Expired,
    Enrolled,
    Revoking,
    Revoked,
    Fatal,
}

/// What a key asks the terminal loop to do.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Effect {
    None,
    /// Repaint the checklist as this key left it. Each key of one read
    /// repaints, so a burst of keys draws every step, as the JS popup does.
    Paint(String),
    Close(i32),
    /// Mint a Bootstrap Key and show its QR.
    StartCeremony,
    Copy,
    Revoke,
}

struct Machine {
    phase: Phase,
    selection: Selection,
    confirmed: Vec<String>,
    /// The layout the last QR screen drew; none before the first draw of a
    /// ceremony.
    qr_layout: Option<Layout>,
    closing: bool,
}

impl Machine {
    fn new(selection: Selection) -> Self {
        Self {
            phase: Phase::Select,
            selection,
            confirmed: Vec::new(),
            qr_layout: None,
            closing: false,
        }
    }

    /// Start closing; false when it already was, so the second request
    /// (a key and a signal together) does nothing.
    fn begin_close(&mut self) -> bool {
        !std::mem::replace(&mut self.closing, true)
    }

    fn on_key(&mut self, key: Key) -> Effect {
        if self.closing {
            return Effect::None;
        }
        // Ignore every key while a revoke or the expiry check is in flight;
        // both are fast and a stray press must not close the popup before
        // they settle.
        if matches!(self.phase, Phase::Revoking | Phase::Expiring) {
            return Effect::None;
        }
        if self.phase == Phase::Fatal {
            return self.close(1);
        }
        if key.is_char('q') || key.name == Name::Escape || (key.ctrl && key.is_char('c')) {
            return self.close(0);
        }
        match self.phase {
            Phase::Enrolled => {
                if key.is_char('r') {
                    self.phase = Phase::Revoking;
                    Effect::Revoke
                } else {
                    self.close(0)
                }
            }
            Phase::Revoked => self.close(0),
            Phase::Qr => match qr_key_action(key, self.qr_layout) {
                KeyAction::Copy => Effect::Copy,
                KeyAction::Close => self.close(0),
                KeyAction::Ignore => Effect::None,
            },
            Phase::Expired => {
                if key.name == Name::Return {
                    self.phase = Phase::Qr;
                    Effect::StartCeremony
                } else {
                    self.close(0)
                }
            }
            _ => self.on_checklist_key(key),
        }
    }

    fn on_checklist_key(&mut self, key: Key) -> Effect {
        match key.name {
            Name::Up | Name::Char('k') => self.selection.move_cursor(-1),
            Name::Down | Name::Char('j') => self.selection.move_cursor(1),
            Name::Space => self.selection.toggle_current(),
            Name::Char('a') => self.selection.toggle_all(),
            Name::Return => {
                let addresses = self.selection.selected_addresses();
                if addresses.is_empty() {
                    return Effect::Paint(checklist_screen(
                        &self.selection,
                        Some("Select at least one address."),
                    ));
                }
                self.phase = Phase::Qr;
                self.confirmed = addresses;
                return Effect::StartCeremony;
            }
            _ => return Effect::None,
        }
        Effect::Paint(checklist_screen(&self.selection, None))
    }

    fn close(&mut self, code: i32) -> Effect {
        self.begin_close();
        Effect::Close(code)
    }
}

// ---- the terminal loop ----

/// What the QR screen shows besides the payload.
#[derive(Debug, Clone, Default)]
struct QrView {
    copied: bool,
    printed_code: Option<String>,
}

struct Popup<'a> {
    home: &'a Path,
    state_dir: &'a Path,
    out: &'a mut dyn Write,
    signals: Signals,
    machine: Machine,
    decoder: Decoder,
    /// The fingerprint the Pairing Code pins.
    host_fingerprint: String,
    session: Option<PairingSession>,
    payload: Option<PairingPayload>,
    displayed_code: Option<String>,
    enrolled: Option<Enrollment>,
    view: QrView,
    stdin_open: bool,
    /// False while a startup failure is held on screen: the signals that
    /// close the popup then end the process as they would uncaught.
    handlers: bool,
    escape_at: Option<Instant>,
    expiry_at: Option<Instant>,
    next_poll: Option<Instant>,
    copied_until: Option<Instant>,
    /// Set when the popup is done: the exit code.
    exit: Option<i32>,
    /// The message of a failure that ends the popup, printed after the
    /// terminal is restored.
    failure: Option<String>,
}

impl Popup<'_> {
    fn paint(&mut self, text: &str) {
        // A closed terminal is the user's choice, not a failure.
        let _ = self.out.write_all(text.as_bytes());
        let _ = self.out.flush();
    }

    fn deadlines(&self) -> impl Iterator<Item = Instant> {
        [
            self.escape_at,
            self.expiry_at,
            self.next_poll,
            self.copied_until,
        ]
        .into_iter()
        .flatten()
    }

    fn run_loop(&mut self) -> i32 {
        let mut buffer = [0u8; 4096];
        loop {
            if let Some(code) = self.exit {
                return code;
            }
            let next = self.deadlines().min();
            // With the terminal gone and no timer left there is nothing to
            // wait for: the process ends, as Node's does with an empty loop.
            if !self.stdin_open && next.is_none() {
                return 0;
            }
            let timeout = next.map(|at| at.saturating_duration_since(Instant::now()));
            let ready = tty::wait(&self.signals, self.stdin_open, timeout);
            if ready.signal {
                for signal in self.signals.take() {
                    self.on_signal(signal);
                }
            }
            if ready.stdin {
                match tty::read_stdin(&mut buffer) {
                    Some(count) => self.on_input(&buffer[..count]),
                    None => self.stdin_open = false,
                }
            }
            self.fire_timers(Instant::now());
        }
    }

    fn on_signal(&mut self, signal: libc::c_int) {
        if signal == libc::SIGWINCH {
            self.on_resize();
        } else if !self.handlers {
            tty::restore(STDIN);
            self.paint(SHOW_CURSOR);
            tty::die_by(signal);
        } else if self.machine.begin_close() {
            self.finish(0);
        }
    }

    fn on_input(&mut self, bytes: &[u8]) {
        // New input cancels a pending escape timeout.
        self.escape_at = None;
        let machine = &mut self.machine;
        let mut effects = Vec::new();
        let ends_in_escape = self
            .decoder
            .feed(bytes, &mut |key| effects.push(machine.on_key(key)));
        if ends_in_escape {
            self.escape_at = Some(Instant::now() + ESCAPE_CODE_TIMEOUT);
        }
        self.run_effects(effects);
    }

    fn fire_timers(&mut self, now: Instant) {
        if self.escape_at.is_some_and(|at| at <= now) {
            self.escape_at = None;
            let machine = &mut self.machine;
            let mut effects = Vec::new();
            self.decoder
                .flush(&mut |key| effects.push(machine.on_key(key)));
            self.run_effects(effects);
        }
        if self.expiry_at.is_some_and(|at| at <= now) {
            self.expiry_at = None;
            if !self.machine.closing && self.machine.phase == Phase::Qr {
                self.expire_ceremony();
            }
        }
        if self.next_poll.is_some_and(|at| at <= now) {
            self.next_poll = Some(now + ENROLL_POLL);
            self.on_enrollment_poll();
        }
        if self.copied_until.is_some_and(|at| at <= now) {
            self.copied_until = None;
            if !self.machine.closing && self.machine.phase == Phase::Qr && self.payload.is_some() {
                self.show_qr(QrView::default());
            }
        }
    }

    /// Run what the keys of one read asked for. A close in the batch ends
    /// the popup before a ceremony, copy or revoke started by the same read
    /// could finish (the JS popup's key handler returns before those awaits
    /// settle), so those are dropped instead of started and torn down.
    fn run_effects(&mut self, effects: Vec<Effect>) {
        let closing = effects.iter().any(|e| matches!(e, Effect::Close(_)));
        for effect in effects {
            let unfinished = matches!(
                effect,
                Effect::StartCeremony | Effect::Copy | Effect::Revoke
            );
            if !(closing && unfinished) {
                self.run_effect(effect);
            }
        }
    }

    fn run_effect(&mut self, effect: Effect) {
        match effect {
            Effect::None => {}
            Effect::Paint(text) => self.paint(&text),
            Effect::Close(code) => self.finish(code),
            Effect::StartCeremony => self.start_ceremony_or_die(),
            Effect::Copy => self.copy_displayed_code(),
            Effect::Revoke => self.revoke_enrolled_device(),
        }
    }

    /// End the popup: drop the ceremony's key and state first, so the
    /// Bootstrap Key line dies with us (a kill -9 is covered by the startup
    /// sweep instead).
    fn finish(&mut self, code: i32) {
        if let Some(session) = self.session.take() {
            let _ = end_pairing(self.home, self.state_dir, &session.pairing_id);
        }
        self.exit = Some(code);
    }

    fn stop_ceremony_timers(&mut self) {
        self.expiry_at = None;
        self.next_poll = None;
    }

    /// Draw the QR screen for the current payload; the code it shows.
    fn show_qr(&mut self, view: QrView) -> Option<String> {
        let payload = self.payload.as_ref()?;
        let expires = expiry_text(payload.expires_at.unwrap_or_default());
        let screen = render_pairing_screen(
            payload,
            ScreenView {
                copied: view.copied,
                printed_code: view.printed_code.as_deref(),
                pane: tty::window_size(STDOUT),
            },
            &expires,
        )
        .ok()?;
        self.view = view;
        self.machine.qr_layout = Some(screen.layout);
        self.paint(&format!("{CLEAR}{}", screen.lines.join("\n")));
        Some(screen.code)
    }

    /// A font zoom or pane resize redraws the same payload, never a fresh
    /// Bootstrap Key.
    fn on_resize(&mut self) {
        if !self.machine.closing && self.machine.phase == Phase::Qr && self.payload.is_some() {
            self.show_qr(self.view.clone());
        }
    }

    fn start_ceremony_or_die(&mut self) {
        if let Err(message) = self.start_ceremony() {
            self.machine.phase = Phase::Fatal;
            self.stop_ceremony_timers();
            self.paint(&fatal_screen(&pairing_start_failed(&message)));
        }
    }

    fn start_ceremony(&mut self) -> std::result::Result<(), String> {
        let session = begin_pairing(self.home, self.state_dir, now_seconds())
            .map_err(|error| error.message().to_string())?;
        let started = Instant::now();
        self.expiry_at = Some(started + Duration::from_secs(PAIRING_TTL_SECONDS as u64));
        let seed = session.seed.to_vec();
        let expires_at = session.expires_at;
        self.session = Some(session);
        let username = current_username()?;
        self.payload = Some(PairingPayload {
            addresses: self.machine.confirmed.clone(),
            port: DEFAULT_SSH_PORT,
            username,
            host_key_fingerprint: self.host_fingerprint.clone(),
            bootstrap_seed: Some(seed),
            expires_at: Some(expires_at),
        });
        let code = self
            .show_qr(QrView::default())
            .ok_or_else(|| "cannot draw the Pairing Code".to_string())?;
        self.displayed_code = Some(code);
        self.next_poll = Some(started + ENROLL_POLL);
        Ok(())
    }

    /// A device enrolled: the Bootstrap Key has already self-revoked, so stop
    /// the TTL clock and the poll and show the enrolled device with a one-key
    /// revoke.
    fn enter_enrolled(&mut self, record: Enrollment) {
        self.stop_ceremony_timers();
        self.machine.phase = Phase::Enrolled;
        let text = enrolled_screen(&record);
        self.enrolled = Some(record);
        self.paint(&text);
    }

    /// Enrollment happens server-side and leaves a record in the state dir.
    /// Poll for it while the QR is up.
    fn on_enrollment_poll(&mut self) {
        if self.machine.closing || self.machine.phase != Phase::Qr {
            return;
        }
        let Some(session) = self.session.as_ref() else {
            return;
        };
        if let Some(record) = read_enrollment(self.state_dir, &session.pairing_id) {
            self.enter_enrolled(record);
        }
    }

    /// The TTL lapsed. A device can enroll inside the accept script's lock
    /// right up to the deadline, after our last poll, so the check for its
    /// record runs inside that same lock (`expire_pairing`): either the
    /// Enrollment is honored, or the cleanup wins and the accept script
    /// rejects. Anything else could delete an enrolled device's record and
    /// never offer the revoke (ADR 0007's compensating control).
    fn expire_ceremony(&mut self) {
        self.machine.phase = Phase::Expiring;
        self.next_poll = None;
        let Some(pairing_id) = self.session.as_ref().map(|s| s.pairing_id.clone()) else {
            return;
        };
        match expire_pairing(self.home, self.state_dir, &pairing_id) {
            Ok(Some(record)) => self.enter_enrolled(record),
            Ok(None) => {
                // expire_pairing already dropped the bootstrap line and
                // pending state.
                self.session = None;
                // So a resize while the next ceremony starts cannot redraw
                // this code.
                self.payload = None;
                self.machine.qr_layout = None;
                self.machine.phase = Phase::Expired;
                self.paint(&expired_screen());
            }
            Err(error) => {
                self.failure = Some(error.message().to_string());
                self.machine.begin_close();
                self.finish(EXIT_FAILURE);
            }
        }
    }

    fn revoke_enrolled_device(&mut self) {
        let Some(record) = self.enrolled.clone() else {
            self.machine.begin_close();
            self.finish(0);
            return;
        };
        let text = match remove_key_line(self.home, &record.line) {
            Ok(_) => revoked_screen(&record),
            Err(error) => revoke_failed_screen(error.message()),
        };
        self.machine.phase = Phase::Revoked;
        self.paint(&text);
    }

    /// Copy the code on screen; where there is no clipboard, print it on the
    /// screen for selection by hand.
    fn copy_displayed_code(&mut self) {
        if self.machine.closing || self.machine.phase != Phase::Qr || self.payload.is_none() {
            return;
        }
        let Some(code) = self.displayed_code.clone() else {
            return;
        };
        self.copied_until = None;
        if copy_pairing_code(&code, cfg!(target_os = "macos"), run_with_input) {
            self.show_qr(QrView {
                copied: true,
                printed_code: None,
            });
            self.copied_until = Some(Instant::now() + COPIED_NOTICE);
        } else {
            self.show_qr(QrView {
                copied: false,
                printed_code: Some(code),
            });
        }
    }
}

/// The account name, as `os.userInfo().username` gives it.
fn current_username() -> std::result::Result<String, String> {
    // SAFETY: geteuid has no preconditions.
    let uid = unsafe { libc::geteuid() };
    let mut buffer = vec![0u8; 1024];
    loop {
        // SAFETY: passwd is plain data; getpwuid_r fills it.
        let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
        let mut found: *mut libc::passwd = std::ptr::null_mut();
        // SAFETY: entry, buffer and found are valid for the call.
        let status = unsafe {
            libc::getpwuid_r(
                uid,
                &mut entry,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut found,
            )
        };
        if status == libc::ERANGE && buffer.len() < 1 << 20 {
            buffer.resize(buffer.len() * 2, 0);
            continue;
        }
        if status != 0 || found.is_null() {
            return Err(
                "A system error occurred: uv_os_get_passwd returned ENOENT (no such file or directory)"
                    .to_string(),
            );
        }
        // SAFETY: on success pw_name is a NUL-terminated string in buffer.
        let name = unsafe { std::ffi::CStr::from_ptr(entry.pw_name) };
        return Ok(name.to_string_lossy().into_owned());
    }
}

/// The state dir herdr gave the plugin, else the one the host config names.
fn resolve_state_dir(ctx: &Ctx) -> Result<PathBuf> {
    if let Some(dir) = ctx.env.non_empty("HERDR_PLUGIN_STATE_DIR") {
        return Ok(PathBuf::from(dir));
    }
    Ok(resolve_host_config(&ctx.env, &ctx.home, &run_herdr)?.state_dir)
}

pub fn run(ctx: &Ctx, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let state_dir = match resolve_state_dir(ctx) {
        Ok(dir) => dir,
        Err(error) => {
            let _ = writeln!(err, "waycar: {error}");
            return EXIT_FAILURE;
        }
    };
    if !tty::is_tty(STDIN) || !tty::is_tty(STDOUT) {
        let _ = writeln!(err, "pair-popup must run inside a terminal pane");
        return EXIT_FAILURE;
    }
    let signals =
        match Signals::install(&[libc::SIGINT, libc::SIGTERM, libc::SIGHUP, libc::SIGWINCH]) {
            Ok(signals) => signals,
            Err(error) => {
                let _ = writeln!(err, "waycar: {error}");
                return EXIT_FAILURE;
            }
        };
    // A panic must not leave the terminal raw with the cursor hidden.
    std::panic::set_hook(Box::new(|info| {
        tty::restore(STDIN);
        tty::write_raw(STDOUT, SHOW_CURSOR.as_bytes());
        eprintln!("{info}");
    }));

    let mut popup = Popup {
        home: &ctx.home,
        state_dir: &state_dir,
        out,
        signals,
        machine: Machine::new(Selection::new(Vec::new())),
        decoder: Decoder::default(),
        host_fingerprint: String::new(),
        session: None,
        payload: None,
        displayed_code: None,
        enrolled: None,
        view: QrView::default(),
        stdin_open: true,
        handlers: false,
        escape_at: None,
        expiry_at: None,
        next_poll: None,
        copied_until: None,
        exit: None,
        failure: None,
    };
    popup.paint(HIDE_CURSOR);
    let code = match popup.start() {
        Ok(()) => popup.run_loop(),
        Err(error) => {
            let _ = writeln!(err, "waycar: {error}");
            EXIT_FAILURE
        }
    };
    tty::restore(STDIN);
    popup.paint(SHOW_CURSOR);
    if let Some(message) = popup.failure.take() {
        let _ = writeln!(err, "waycar: {message}");
    }
    code
}

impl Popup<'_> {
    /// Startup checks and the first screen: the checklist, or a failure held
    /// until a key so herdr does not close the pane before it is read.
    fn start(&mut self) -> Result<()> {
        let Some(host_key) = read_host_key_fingerprint(Path::new(DEFAULT_SSH_DIR))? else {
            return self.hold_fatal(MISSING_HOST_KEY);
        };
        let candidates = candidate_addresses(&network_interfaces(), Platform::current());
        if candidates.is_empty() {
            return self.hold_fatal(MISSING_ADDRESS);
        }
        // Startup sweep: crashed or killed ceremonies must leave no residue,
        // neither authorized_keys lines nor pending/enrolled state files.
        sweep_expired_bootstrap_lines(self.home, now_seconds())?;
        sweep_expired_state_files(self.state_dir, now_seconds())?;

        self.host_fingerprint = host_key.fingerprint;
        self.machine = Machine::new(Selection::new(candidates));
        self.handlers = true;
        let text = checklist_screen(&self.machine.selection, None);
        self.paint(&text);
        self.enter_raw()
    }

    fn hold_fatal(&mut self, message: &str) -> Result<()> {
        self.machine.phase = Phase::Fatal;
        self.paint(&fatal_screen(message));
        self.enter_raw()
    }

    fn enter_raw(&mut self) -> Result<()> {
        tty::enter_raw(STDIN).map_err(CliError::from)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::addresses::{Candidate, Family};

    fn candidate(address: &str, interface_name: &str, family: Family, checked: bool) -> Candidate {
        Candidate {
            address: address.to_string(),
            family,
            interface_name: interface_name.to_string(),
            pre_checked: checked,
        }
    }

    fn machine() -> Machine {
        Machine::new(Selection::new(vec![
            candidate("192.168.1.42", "en0", Family::V4, true),
            candidate("fd7a::1", "utun3", Family::V6, false),
        ]))
    }

    fn press(machine: &mut Machine, name: Name) -> Effect {
        machine.on_key(Key::plain(name))
    }

    fn repaint(state: &Machine) -> Effect {
        Effect::Paint(checklist_screen(&state.selection, None))
    }

    fn ch(c: char) -> Name {
        Name::Char(c)
    }

    #[test]
    fn checklist_screen_marks_the_cursor_and_the_checked_rows() {
        let state = machine();
        assert_eq!(
            checklist_screen(&state.selection, None),
            "\u{1b}[2J\u{1b}[3J\u{1b}[H\
             \u{1b}[1mPair a Waycar device\u{1b}[0m\n\
             \n\
             Select the addresses the phone can reach this machine on:\n\
             \n \
             \u{1b}[7m> [x] 192.168.1.42 \u{1b}[2m(en0, IPv4)\u{1b}[0m\u{1b}[0m\n   \
             [ ] fd7a::1 \u{1b}[2m(utun3, IPv6)\u{1b}[0m\u{1b}[0m\n\
             \n\
             \u{1b}[2mup/down move, space toggle, a all, enter confirm, q quit\u{1b}[0m\n"
        );
    }

    #[test]
    fn checklist_warning_goes_under_the_help_line() {
        let text = checklist_screen(&machine().selection, Some("Select at least one address."));
        assert!(
            text.ends_with("q quit\u{1b}[0m\n\n\u{1b}[1mSelect at least one address.\u{1b}[0m\n")
        );
    }

    #[test]
    fn fatal_screen_bolds_the_title_and_dims_the_hint() {
        assert_eq!(
            fatal_screen("No luck."),
            "\u{1b}[2J\u{1b}[3J\u{1b}[H\
             \u{1b}[1mPairing cannot start\u{1b}[0m\n\
             \n\
             No luck.\n\
             \n\
             \u{1b}[2mPress any key to close.\u{1b}[0m\n"
        );
    }

    #[test]
    fn enrolled_screen_labels_the_device_or_says_there_is_none() {
        let record = |line: &str| Enrollment {
            pairing_id: "p".into(),
            expires_at: None,
            fingerprint: "SHA256:abc".into(),
            line: line.into(),
        };
        assert!(
            enrolled_screen(&record("ssh-ed25519 AAAA my phone"))
                .contains("  Label        \u{1b}[1mmy phone\u{1b}[0m\n")
        );
        assert!(
            enrolled_screen(&record("ssh-ed25519 AAAA"))
                .contains("  Label        \u{1b}[2m(no label)\u{1b}[0m\n")
        );
    }

    #[test]
    fn arrows_and_vi_keys_move_the_cursor_and_repaint() {
        let mut state = machine();
        assert_eq!(press(&mut state, Name::Down), repaint(&state));
        assert_eq!(state.selection.cursor, 1);
        assert_eq!(press(&mut state, ch('k')), repaint(&state));
        assert_eq!(state.selection.cursor, 0);
        press(&mut state, ch('j'));
        assert_eq!(state.selection.cursor, 1);
        press(&mut state, Name::Up);
        assert_eq!(state.selection.cursor, 0);
    }

    #[test]
    fn space_toggles_and_a_toggles_all() {
        let mut state = machine();
        press(&mut state, Name::Space);
        assert_eq!(state.selection.selected_addresses(), Vec::<String>::new());
        press(&mut state, ch('a'));
        assert_eq!(state.selection.selected_addresses().len(), 2);
    }

    #[test]
    fn an_unbound_key_does_not_repaint() {
        assert_eq!(press(&mut machine(), ch('x')), Effect::None);
    }

    #[test]
    fn enter_with_nothing_checked_warns_instead_of_starting() {
        let mut state = machine();
        press(&mut state, ch('a'));
        press(&mut state, ch('a'));
        let Effect::Paint(text) = press(&mut state, Name::Return) else {
            panic!("expected a repaint");
        };
        assert_eq!(
            text,
            checklist_screen(&state.selection, Some("Select at least one address."))
        );
        assert_eq!(state.phase, Phase::Select);
    }

    #[test]
    fn enter_confirms_the_checked_addresses_and_starts_a_ceremony() {
        let mut state = machine();
        assert_eq!(press(&mut state, Name::Return), Effect::StartCeremony);
        assert_eq!(state.phase, Phase::Qr);
        assert_eq!(state.confirmed, ["192.168.1.42"]);
    }

    #[test]
    fn q_escape_and_ctrl_c_close_from_every_live_phase() {
        for phase in [
            Phase::Select,
            Phase::Qr,
            Phase::Expired,
            Phase::Enrolled,
            Phase::Revoked,
        ] {
            for key in [
                Key::plain(ch('q')),
                Key::plain(Name::Escape),
                Key::ctrl('c'),
            ] {
                let mut state = machine();
                state.phase = phase;
                assert_eq!(state.on_key(key), Effect::Close(0), "{phase:?}");
            }
        }
    }

    #[test]
    fn a_closing_popup_ignores_further_keys() {
        let mut state = machine();
        assert_eq!(press(&mut state, ch('q')), Effect::Close(0));
        assert_eq!(press(&mut state, ch('q')), Effect::None);
        assert!(!state.begin_close());
    }

    #[test]
    fn the_qr_screen_copies_on_c_and_closes_by_layout() {
        let mut state = machine();
        state.phase = Phase::Qr;
        assert_eq!(press(&mut state, ch('c')), Effect::Copy);
        // No QR drawn yet behaves like the full-size one: any key closes.
        let mut fresh = machine();
        fresh.phase = Phase::Qr;
        assert_eq!(press(&mut fresh, Name::Other), Effect::Close(0));
        // A compact QR ignores keys that are not q, escape or Ctrl-C.
        let mut compact = machine();
        compact.phase = Phase::Qr;
        compact.qr_layout = Some(Layout::Sextant);
        assert_eq!(press(&mut compact, Name::Other), Effect::None);
        assert_eq!(press(&mut compact, ch('c')), Effect::Copy);
    }

    #[test]
    fn expired_offers_a_fresh_code_on_enter_and_closes_on_anything_else() {
        let mut state = machine();
        state.phase = Phase::Expired;
        assert_eq!(press(&mut state, Name::Return), Effect::StartCeremony);
        assert_eq!(state.phase, Phase::Qr);
        let mut other = machine();
        other.phase = Phase::Expired;
        assert_eq!(press(&mut other, ch('x')), Effect::Close(0));
    }

    #[test]
    fn enrolled_revokes_on_r_and_closes_on_anything_else() {
        let mut state = machine();
        state.phase = Phase::Enrolled;
        assert_eq!(press(&mut state, ch('r')), Effect::Revoke);
        assert_eq!(state.phase, Phase::Revoking);
        let mut other = machine();
        other.phase = Phase::Enrolled;
        assert_eq!(press(&mut other, Name::Space), Effect::Close(0));
    }

    #[test]
    fn keys_are_ignored_while_a_revoke_or_expiry_is_in_flight() {
        for phase in [Phase::Revoking, Phase::Expiring] {
            let mut state = machine();
            state.phase = phase;
            for key in [
                Key::plain(ch('q')),
                Key::ctrl('c'),
                Key::plain(Name::Return),
            ] {
                assert_eq!(state.on_key(key), Effect::None);
            }
        }
    }

    #[test]
    fn revoked_closes_on_any_key() {
        let mut state = machine();
        state.phase = Phase::Revoked;
        assert_eq!(press(&mut state, ch('x')), Effect::Close(0));
    }

    #[test]
    fn a_failed_start_waits_for_any_key_and_exits_one() {
        let mut state = machine();
        state.phase = Phase::Fatal;
        assert_eq!(press(&mut state, ch('x')), Effect::Close(1));
    }

    #[test]
    fn control_chords_act_as_their_letter_in_the_checklist_like_readline() {
        // Ctrl-K and Ctrl-A are named k and a by readline.
        let mut state = machine();
        press(&mut state, Name::Down);
        assert_eq!(state.on_key(Key::ctrl('k')), repaint(&state));
        assert_eq!(state.selection.cursor, 0);
        assert_eq!(state.on_key(Key::ctrl('q')), Effect::Close(0));
    }
}
