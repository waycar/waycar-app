//! `waycar pair`: the Pairing Code popup in this terminal (pair-popup.js, with
//! pairing_qr, select_list, copy_pairing_code and pair_fatal).
//!
//! Flow: sweep stale bootstrap lines, enumerate candidate addresses, the user
//! confirms the checklist, a Bootstrap Key is minted and the Pairing Code QR
//! shown. The Bootstrap Key's restricted authorized_keys line lives exactly as
//! long as this popup and its 2-minute TTL, whichever ends first; Enrollment
//! itself happens in `pair_accept`, run by sshd as the forced command.
//!
//! What the user sees is a pure function of the state ([`PairPopupMachine`]
//! and the `*_screen` functions); [`Popup`] is the thin terminal loop around
//! them: it owns the terminal, the timers and the ceremony's files, and feeds
//! the machine keys, timer expiries and the results of what it asked for.

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
use crate::state_machine::StateMachine;
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

/// What an event asks the terminal loop to do.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Effect {
    None,
    /// Repaint the checklist as this key left it. Each key of one read
    /// repaints, so a burst of keys draws every step, as the JS popup does.
    /// Also any other finished screen (revoked, revoke failed).
    Paint(String),
    Close(i32),
    /// Mint a Bootstrap Key and show its QR.
    StartCeremony,
    Copy,
    Revoke,
    /// Stop the TTL clock and the Enrollment poll.
    StopCeremonyTimers,
    /// Stop the Enrollment poll only.
    StopPoll,
    /// The start failed: show this message until a key.
    ShowStartFailure(String),
    /// Look for the ceremony's Enrollment record.
    ReadEnrollment,
    /// Keep this Enrollment and show it with its one-key revoke.
    ShowEnrolled(Enrollment),
    /// Expire the ceremony inside the authorized_keys lock.
    Expire,
    /// Forget the expired ceremony's session and code, show the expired screen.
    ShowExpired,
    /// Redraw the QR as it is (a resize).
    RedrawQr,
    /// Redraw the QR without the "copied" notice.
    ClearCopied,
    /// End the popup with exit 1, printing this after the terminal is restored.
    Fail(String),
}

/// What the terminal loop tells the machine.
#[derive(Debug, Clone, PartialEq, Eq)]
enum PopupEvent {
    Key(Key),
    /// A closing signal (SIGINT, SIGTERM, SIGHUP) with the handlers in place.
    CloseRequested,
    /// A startup check failed; its screen is on show.
    StartupFailed,
    CeremonyFailed(String),
    /// A QR screen drew with this layout.
    QrDrawn(Layout),
    PollDue,
    EnrollmentFound(Enrollment),
    ExpiryDue,
    /// `expire_pairing`: the Enrollment that won, none, or its failure.
    ExpireAnswered(std::result::Result<Option<Enrollment>, String>),
    /// The revoke's screen, or none when there was no Enrollment to revoke.
    RevokeAnswered(Option<String>),
    /// SIGWINCH; whether a payload is on show.
    Resized {
        has_payload: bool,
    },
    CopiedNoticeElapsed {
        has_payload: bool,
    },
}

/// The popup's screens and what moves between them (HT-06). `phase` is the
/// state; the selection, the confirmed addresses and the last QR layout are
/// its data, and `closing` stops every later event once a close began.
struct PairPopupMachine {
    phase: Phase,
    selection: Selection,
    confirmed: Vec<String>,
    /// The layout the last QR screen drew; none before the first draw of a
    /// ceremony.
    qr_layout: Option<Layout>,
    closing: bool,
}

impl StateMachine for PairPopupMachine {
    type State = Phase;
    type Event = PopupEvent;
    type Effect = Effect;

    fn state(&self) -> &Phase {
        &self.phase
    }

    fn handle(&mut self, event: PopupEvent) -> Vec<Effect> {
        let live_qr = !self.closing && self.phase == Phase::Qr;
        match event {
            PopupEvent::Key(key) => match self.on_key(key) {
                Effect::None => Vec::new(),
                effect => vec![effect],
            },
            PopupEvent::CloseRequested => {
                if self.begin_close() {
                    vec![Effect::Close(0)]
                } else {
                    Vec::new()
                }
            }
            PopupEvent::StartupFailed => {
                self.phase = Phase::Fatal;
                Vec::new()
            }
            PopupEvent::CeremonyFailed(message) => {
                self.phase = Phase::Fatal;
                vec![
                    Effect::StopCeremonyTimers,
                    Effect::ShowStartFailure(message),
                ]
            }
            PopupEvent::QrDrawn(layout) => {
                self.qr_layout = Some(layout);
                Vec::new()
            }
            PopupEvent::PollDue if live_qr => vec![Effect::ReadEnrollment],
            PopupEvent::PollDue => Vec::new(),
            PopupEvent::EnrollmentFound(record) | PopupEvent::ExpireAnswered(Ok(Some(record))) => {
                self.phase = Phase::Enrolled;
                vec![Effect::StopCeremonyTimers, Effect::ShowEnrolled(record)]
            }
            PopupEvent::ExpiryDue if live_qr => {
                self.phase = Phase::Expiring;
                vec![Effect::StopPoll, Effect::Expire]
            }
            PopupEvent::ExpiryDue => Vec::new(),
            PopupEvent::ExpireAnswered(Ok(None)) => {
                // So a resize while the next ceremony starts cannot redraw
                // this code.
                self.qr_layout = None;
                self.phase = Phase::Expired;
                vec![Effect::ShowExpired]
            }
            PopupEvent::ExpireAnswered(Err(message)) => {
                self.begin_close();
                vec![Effect::Fail(message)]
            }
            PopupEvent::RevokeAnswered(Some(screen)) => {
                self.phase = Phase::Revoked;
                vec![Effect::Paint(screen)]
            }
            PopupEvent::RevokeAnswered(None) => vec![self.close(0)],
            PopupEvent::Resized { has_payload } if live_qr && has_payload => {
                vec![Effect::RedrawQr]
            }
            PopupEvent::CopiedNoticeElapsed { has_payload } if live_qr && has_payload => {
                vec![Effect::ClearCopied]
            }
            PopupEvent::Resized { .. } | PopupEvent::CopiedNoticeElapsed { .. } => Vec::new(),
        }
    }
}

impl PairPopupMachine {
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
    machine: PairPopupMachine,
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
        } else {
            self.send(PopupEvent::CloseRequested);
        }
    }

    /// Feed the machine one event and run what it asks for at once.
    fn send(&mut self, event: PopupEvent) {
        for effect in self.machine.handle(event) {
            self.run_effect(effect);
        }
    }

    fn on_input(&mut self, bytes: &[u8]) {
        // New input cancels a pending escape timeout.
        self.escape_at = None;
        let machine = &mut self.machine;
        let mut effects = Vec::new();
        let ends_in_escape = self.decoder.feed(bytes, &mut |key| {
            effects.extend(machine.handle(PopupEvent::Key(key)));
        });
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
            self.decoder.flush(&mut |key| {
                effects.extend(machine.handle(PopupEvent::Key(key)));
            });
            self.run_effects(effects);
        }
        if self.expiry_at.is_some_and(|at| at <= now) {
            self.expiry_at = None;
            self.send(PopupEvent::ExpiryDue);
        }
        if self.next_poll.is_some_and(|at| at <= now) {
            self.next_poll = Some(now + ENROLL_POLL);
            self.send(PopupEvent::PollDue);
        }
        if self.copied_until.is_some_and(|at| at <= now) {
            self.copied_until = None;
            let has_payload = self.payload.is_some();
            self.send(PopupEvent::CopiedNoticeElapsed { has_payload });
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
            Effect::StopCeremonyTimers => self.stop_ceremony_timers(),
            Effect::StopPoll => self.next_poll = None,
            Effect::ShowStartFailure(message) => {
                self.paint(&fatal_screen(&pairing_start_failed(&message)));
            }
            Effect::ReadEnrollment => self.on_enrollment_poll(),
            Effect::ShowEnrolled(record) => self.show_enrolled(record),
            Effect::Expire => self.expire_ceremony(),
            Effect::ShowExpired => {
                // expire_pairing already dropped the bootstrap line and
                // pending state.
                self.session = None;
                // So a resize while the next ceremony starts cannot redraw
                // this code.
                self.payload = None;
                self.paint(&expired_screen());
            }
            Effect::RedrawQr => {
                self.show_qr(self.view.clone());
            }
            Effect::ClearCopied => {
                self.show_qr(QrView::default());
            }
            Effect::Fail(message) => {
                self.failure = Some(message);
                self.finish(EXIT_FAILURE);
            }
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
        self.send(PopupEvent::QrDrawn(screen.layout));
        self.paint(&format!("{CLEAR}{}", screen.lines.join("\n")));
        Some(screen.code)
    }

    /// A font zoom or pane resize redraws the same payload, never a fresh
    /// Bootstrap Key.
    fn on_resize(&mut self) {
        let has_payload = self.payload.is_some();
        self.send(PopupEvent::Resized { has_payload });
    }

    fn start_ceremony_or_die(&mut self) {
        if let Err(message) = self.start_ceremony() {
            self.send(PopupEvent::CeremonyFailed(message));
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

    /// A device enrolled: the Bootstrap Key has already self-revoked, so the
    /// machine stopped the TTL clock and the poll; show the enrolled device
    /// with a one-key revoke.
    fn show_enrolled(&mut self, record: Enrollment) {
        let text = enrolled_screen(&record);
        self.enrolled = Some(record);
        self.paint(&text);
    }

    /// Enrollment happens server-side and leaves a record in the state dir.
    /// Polled for while the QR is up.
    fn on_enrollment_poll(&mut self) {
        let Some(session) = self.session.as_ref() else {
            return;
        };
        if let Some(record) = read_enrollment(self.state_dir, &session.pairing_id) {
            self.send(PopupEvent::EnrollmentFound(record));
        }
    }

    /// The TTL lapsed. A device can enroll inside the accept script's lock
    /// right up to the deadline, after our last poll, so the check for its
    /// record runs inside that same lock (`expire_pairing`): either the
    /// Enrollment is honored, or the cleanup wins and the accept script
    /// rejects. Anything else could delete an enrolled device's record and
    /// never offer the revoke (ADR 0007's compensating control).
    fn expire_ceremony(&mut self) {
        let Some(pairing_id) = self.session.as_ref().map(|s| s.pairing_id.clone()) else {
            return;
        };
        let answer = expire_pairing(self.home, self.state_dir, &pairing_id)
            .map_err(|error| error.message().to_string());
        self.send(PopupEvent::ExpireAnswered(answer));
    }

    fn revoke_enrolled_device(&mut self) {
        let screen =
            self.enrolled
                .clone()
                .map(|record| match remove_key_line(self.home, &record.line) {
                    Ok(_) => revoked_screen(&record),
                    Err(error) => revoke_failed_screen(error.message()),
                });
        self.send(PopupEvent::RevokeAnswered(screen));
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
        machine: PairPopupMachine::new(Selection::new(Vec::new())),
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
        self.machine = PairPopupMachine::new(Selection::new(candidates));
        self.handlers = true;
        let text = checklist_screen(&self.machine.selection, None);
        self.paint(&text);
        self.enter_raw()
    }

    fn hold_fatal(&mut self, message: &str) -> Result<()> {
        self.send(PopupEvent::StartupFailed);
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

    fn machine() -> PairPopupMachine {
        PairPopupMachine::new(Selection::new(vec![
            candidate("192.168.1.42", "en0", Family::V4, true),
            candidate("fd7a::1", "utun3", Family::V6, false),
        ]))
    }

    fn press(machine: &mut PairPopupMachine, name: Name) -> Effect {
        machine.on_key(Key::plain(name))
    }

    fn repaint(state: &PairPopupMachine) -> Effect {
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

    // The machine's non-key events.

    fn in_phase(phase: Phase) -> PairPopupMachine {
        let mut state = machine();
        state.phase = phase;
        state
    }

    fn record() -> Enrollment {
        Enrollment {
            pairing_id: "p".into(),
            expires_at: None,
            fingerprint: "SHA256:device".into(),
            line: "ssh-ed25519 AAAA".into(),
        }
    }

    #[test]
    fn a_close_request_closes_once() {
        let mut state = in_phase(Phase::Qr);
        assert_eq!(state.handle(PopupEvent::CloseRequested), [Effect::Close(0)]);
        assert_eq!(state.handle(PopupEvent::CloseRequested), []);
        assert_eq!(state.handle(PopupEvent::Key(Key::plain(ch('q')))), []);
    }

    #[test]
    fn a_failed_start_or_startup_is_fatal() {
        let mut state = in_phase(Phase::Qr);
        assert_eq!(
            state.handle(PopupEvent::CeremonyFailed("boom".into())),
            [
                Effect::StopCeremonyTimers,
                Effect::ShowStartFailure("boom".into())
            ]
        );
        assert_eq!(state.state(), &Phase::Fatal);
        let mut state = machine();
        assert_eq!(state.handle(PopupEvent::StartupFailed), []);
        assert_eq!(state.state(), &Phase::Fatal);
    }

    #[test]
    fn the_poll_and_the_expiry_act_only_on_a_live_qr() {
        for (phase, closing) in [
            (Phase::Select, false),
            (Phase::Expired, false),
            (Phase::Enrolled, false),
            (Phase::Qr, true),
        ] {
            let mut state = in_phase(phase);
            state.closing = closing;
            assert_eq!(state.handle(PopupEvent::PollDue), [], "{phase:?}");
            assert_eq!(state.handle(PopupEvent::ExpiryDue), [], "{phase:?}");
            assert_eq!(state.phase, phase);
        }
        let mut state = in_phase(Phase::Qr);
        assert_eq!(state.handle(PopupEvent::PollDue), [Effect::ReadEnrollment]);
        assert_eq!(
            state.handle(PopupEvent::ExpiryDue),
            [Effect::StopPoll, Effect::Expire]
        );
        assert_eq!(state.state(), &Phase::Expiring);
    }

    #[test]
    fn an_enrollment_from_the_poll_or_the_expiry_shows_the_device() {
        for event in [
            PopupEvent::EnrollmentFound(record()),
            PopupEvent::ExpireAnswered(Ok(Some(record()))),
        ] {
            let mut state = in_phase(Phase::Expiring);
            assert_eq!(
                state.handle(event),
                [Effect::StopCeremonyTimers, Effect::ShowEnrolled(record())]
            );
            assert_eq!(state.state(), &Phase::Enrolled);
        }
    }

    #[test]
    fn an_expiry_with_no_enrollment_forgets_the_layout_and_one_that_failed_ends() {
        let mut state = in_phase(Phase::Expiring);
        state.qr_layout = Some(Layout::HalfBlock);
        assert_eq!(
            state.handle(PopupEvent::ExpireAnswered(Ok(None))),
            [Effect::ShowExpired]
        );
        assert_eq!((state.phase, state.qr_layout), (Phase::Expired, None));
        let mut state = in_phase(Phase::Expiring);
        assert_eq!(
            state.handle(PopupEvent::ExpireAnswered(Err("locked".into()))),
            [Effect::Fail("locked".into())]
        );
        assert!(state.closing);
    }

    #[test]
    fn a_revoke_shows_its_screen_or_closes_without_a_record() {
        let mut state = in_phase(Phase::Revoking);
        assert_eq!(
            state.handle(PopupEvent::RevokeAnswered(Some("done".into()))),
            [Effect::Paint("done".into())]
        );
        assert_eq!(state.state(), &Phase::Revoked);
        let mut state = in_phase(Phase::Revoking);
        assert_eq!(
            state.handle(PopupEvent::RevokeAnswered(None)),
            [Effect::Close(0)]
        );
        assert!(state.closing);
    }

    #[test]
    fn resize_and_the_copied_notice_redraw_only_a_live_qr_with_a_payload() {
        let mut state = in_phase(Phase::Qr);
        assert_eq!(
            state.handle(PopupEvent::Resized { has_payload: true }),
            [Effect::RedrawQr]
        );
        assert_eq!(
            state.handle(PopupEvent::CopiedNoticeElapsed { has_payload: true }),
            [Effect::ClearCopied]
        );
        assert_eq!(state.handle(PopupEvent::Resized { has_payload: false }), []);
        let mut state = in_phase(Phase::Expired);
        assert_eq!(state.handle(PopupEvent::Resized { has_payload: true }), []);
        assert_eq!(
            state.handle(PopupEvent::CopiedNoticeElapsed { has_payload: true }),
            []
        );
    }

    #[test]
    fn a_drawn_qr_sets_the_layout_keys_use() {
        let mut state = in_phase(Phase::Qr);
        assert_eq!(state.handle(PopupEvent::QrDrawn(Layout::Sextant)), []);
        assert_eq!(state.handle(PopupEvent::Key(Key::plain(Name::Other))), []);
    }

    // The popup around the machine, with a private home and state dir and
    // the terminal output in a buffer.

    use crate::authorized_keys::{self, parse_bootstrap_line};
    use crate::pairing_session::{enrolled_path, pending_path, record_enrollment};
    use crate::test_support::TempDir;

    struct Stage {
        home: TempDir,
        out: Vec<u8>,
    }

    impl Stage {
        fn new() -> Self {
            Self {
                home: TempDir::new("pair-popup"),
                out: Vec::new(),
            }
        }

        fn state(&self) -> PathBuf {
            self.home.path().join("state")
        }

        fn bootstrap_lines(&self) -> usize {
            std::fs::read_to_string(authorized_keys::path(self.home.path()))
                .unwrap_or_default()
                .lines()
                .filter(|line| parse_bootstrap_line(line).is_some())
                .count()
        }
    }

    fn popup<'a>(home: &'a Path, state: &'a Path, out: &'a mut Vec<u8>) -> Popup<'a> {
        Popup {
            home,
            state_dir: state,
            out,
            signals: Signals::install(&[]).unwrap(),
            machine: machine(),
            decoder: Decoder::default(),
            host_fingerprint: "SHA256:ef+f9Jda6ZPkcW5GiL7pQZXJ57mCFnFAGkir3AcfTIM".into(),
            session: None,
            payload: None,
            displayed_code: None,
            enrolled: None,
            view: QrView::default(),
            stdin_open: true,
            handlers: true,
            escape_at: None,
            expiry_at: None,
            next_poll: None,
            copied_until: None,
            exit: None,
            failure: None,
        }
    }

    const DEVICE_LINE: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYSCTemrZWEXptQyehHLI9kbqjHxNUGtQN2lF1ucCce waycar";

    fn enroll(state: &Path, pairing_id: &str) {
        record_enrollment(
            state,
            &Enrollment {
                pairing_id: pairing_id.into(),
                expires_at: None,
                fingerprint: "SHA256:device".into(),
                line: DEVICE_LINE.into(),
            },
        )
        .unwrap();
    }

    #[test]
    fn enter_starts_a_ceremony_with_its_ttl_and_poll_and_draws_the_qr() {
        let mut stage = Stage::new();
        let (home, state) = (stage.home.path().to_path_buf(), stage.state());
        let mut popup = popup(&home, &state, &mut stage.out);
        popup.on_input(b"\r");
        assert_eq!(popup.machine.phase, Phase::Qr);
        let id = popup.session.as_ref().unwrap().pairing_id.clone();
        assert!(pending_path(&state, &id).exists());
        assert!(popup.payload.is_some() && popup.displayed_code.is_some());
        assert!(popup.expiry_at.is_some() && popup.next_poll.is_some());
        assert!(popup.machine.qr_layout.is_some());
        drop(popup);
        assert_eq!(stage.bootstrap_lines(), 1);
    }

    #[test]
    fn a_close_in_the_same_read_as_enter_starts_no_ceremony() {
        let mut stage = Stage::new();
        let (home, state) = (stage.home.path().to_path_buf(), stage.state());
        let mut popup = popup(&home, &state, &mut stage.out);
        popup.on_input(b"\rq");
        assert_eq!(popup.exit, Some(0));
        assert!(popup.session.is_none());
        drop(popup);
        assert_eq!(stage.bootstrap_lines(), 0);
    }

    #[test]
    fn the_poll_finds_an_enrollment_and_stops_the_ceremony_timers() {
        let mut stage = Stage::new();
        let (home, state) = (stage.home.path().to_path_buf(), stage.state());
        let mut popup = popup(&home, &state, &mut stage.out);
        popup.on_input(b"\r");
        let id = popup.session.as_ref().unwrap().pairing_id.clone();
        // Nothing enrolled: the poll re-arms.
        let first = popup.next_poll.unwrap();
        popup.fire_timers(first);
        assert_eq!(popup.machine.phase, Phase::Qr);
        assert_eq!(popup.next_poll, Some(first + ENROLL_POLL));
        enroll(&state, &id);
        popup.fire_timers(first + ENROLL_POLL);
        assert_eq!(popup.machine.phase, Phase::Enrolled);
        assert_eq!((popup.expiry_at, popup.next_poll), (None, None));
        assert_eq!(
            popup.enrolled.as_ref().unwrap().fingerprint,
            "SHA256:device"
        );
        // r revokes the device's line.
        authorized_keys::edit_authorized_keys(&home, |mut lines| {
            lines.push(DEVICE_LINE.into());
            Ok(Some(lines))
        })
        .unwrap();
        popup.on_input(b"r");
        assert_eq!(popup.machine.phase, Phase::Revoked);
        let keys = std::fs::read_to_string(authorized_keys::path(&home)).unwrap();
        assert!(!keys.contains(DEVICE_LINE));
        // Any key closes, and closing ends the ceremony's state.
        popup.on_input(b"x");
        assert_eq!(popup.exit, Some(0));
        assert!(!enrolled_path(&state, &id).exists());
    }

    #[test]
    fn the_ttl_expires_the_ceremony_and_enter_starts_a_fresh_one() {
        let mut stage = Stage::new();
        let (home, state) = (stage.home.path().to_path_buf(), stage.state());
        let mut popup = popup(&home, &state, &mut stage.out);
        popup.on_input(b"\r");
        let id = popup.session.as_ref().unwrap().pairing_id.clone();
        popup.fire_timers(popup.expiry_at.unwrap());
        assert_eq!(popup.machine.phase, Phase::Expired);
        assert!(popup.session.is_none() && popup.payload.is_none());
        assert!(popup.machine.qr_layout.is_none());
        assert!(popup.next_poll.is_none());
        assert!(!pending_path(&state, &id).exists());
        popup.on_input(b"\r");
        assert_eq!(popup.machine.phase, Phase::Qr);
        assert_ne!(popup.session.as_ref().unwrap().pairing_id, id);
        drop(popup);
        assert_eq!(stage.bootstrap_lines(), 1);
    }

    #[test]
    fn an_enrollment_at_the_deadline_wins_over_the_expiry() {
        let mut stage = Stage::new();
        let (home, state) = (stage.home.path().to_path_buf(), stage.state());
        let mut popup = popup(&home, &state, &mut stage.out);
        popup.on_input(b"\r");
        let id = popup.session.as_ref().unwrap().pairing_id.clone();
        enroll(&state, &id);
        // The expiry fires before the poll sees the record.
        popup.next_poll = None;
        popup.fire_timers(popup.expiry_at.unwrap());
        assert_eq!(popup.machine.phase, Phase::Enrolled);
        assert!(enrolled_path(&state, &id).exists());
    }

    #[test]
    fn a_signal_closes_once_and_ends_the_ceremony() {
        let mut stage = Stage::new();
        let (home, state) = (stage.home.path().to_path_buf(), stage.state());
        let mut popup = popup(&home, &state, &mut stage.out);
        popup.on_input(b"\r");
        let id = popup.session.as_ref().unwrap().pairing_id.clone();
        popup.on_signal(libc::SIGTERM);
        assert_eq!(popup.exit, Some(0));
        assert!(popup.machine.closing);
        assert!(!pending_path(&state, &id).exists());
        popup.exit = None;
        popup.on_signal(libc::SIGTERM);
        assert_eq!(popup.exit, None, "a second close does nothing");
        drop(popup);
        assert_eq!(stage.bootstrap_lines(), 0);
    }

    #[test]
    fn copy_without_a_clipboard_prints_the_code_on_the_qr_screen() {
        let mut stage = Stage::new();
        let (home, state) = (stage.home.path().to_path_buf(), stage.state());
        let mut popup = popup(&home, &state, &mut stage.out);
        popup.on_input(b"\r");
        popup.on_input(b"c");
        if cfg!(target_os = "macos") {
            return;
        }
        assert_eq!(popup.view.printed_code, popup.displayed_code);
        assert!(popup.copied_until.is_none());
        assert_eq!(popup.machine.phase, Phase::Qr);
    }

    #[test]
    fn a_ceremony_that_cannot_start_holds_the_failure_until_a_key_exits_one() {
        let mut stage = Stage::new();
        // A home that is a file: no authorized_keys can be written.
        let home = stage.home.path().join("not-a-dir");
        std::fs::write(&home, "").unwrap();
        let state = stage.state();
        let mut popup = popup(&home, &state, &mut stage.out);
        popup.on_input(b"\r");
        assert_eq!(popup.machine.phase, Phase::Fatal);
        assert!(popup.session.is_none());
        assert_eq!((popup.expiry_at, popup.next_poll), (None, None));
        popup.on_input(b"x");
        assert_eq!(popup.exit, Some(1));
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
