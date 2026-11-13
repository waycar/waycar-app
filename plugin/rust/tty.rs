//! The terminal the pairing popup runs in: raw mode, window size, signals and
//! waiting for input, on libc. Mirrors what Node's tty streams do for the JS
//! popup (`setRawMode`, `resize`, `process.on(signal)`).

use std::io;
use std::os::fd::RawFd;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::Duration;

use crate::pairing_qr::Pane;

pub const STDIN: RawFd = 0;
pub const STDOUT: RawFd = 1;

/// The settings before raw mode, kept so any exit path (a return, a signal,
/// a panic hook) can put them back.
static SAVED: OnceLock<libc::termios> = OnceLock::new();

pub fn is_tty(fd: RawFd) -> bool {
    // SAFETY: isatty only inspects the descriptor.
    unsafe { libc::isatty(fd) == 1 }
}

/// Raw mode as libuv sets it for Node: no echo, no line editing, no signal
/// keys (Ctrl-C arrives as a key), no CR to NL, output post-processing kept
/// so `\n` still returns the carriage.
pub fn enter_raw(fd: RawFd) -> io::Result<()> {
    // SAFETY: termios is plain data; tcgetattr fills it.
    let mut settings: libc::termios = unsafe { std::mem::zeroed() };
    // SAFETY: settings is a valid out-pointer for the call.
    if unsafe { libc::tcgetattr(fd, &mut settings) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let _ = SAVED.set(settings);
    settings.c_iflag &= !(libc::BRKINT | libc::ICRNL | libc::INPCK | libc::ISTRIP | libc::IXON);
    settings.c_oflag |= libc::ONLCR;
    settings.c_cflag |= libc::CS8;
    settings.c_lflag &= !(libc::ECHO | libc::ICANON | libc::IEXTEN | libc::ISIG);
    settings.c_cc[libc::VMIN] = 1;
    settings.c_cc[libc::VTIME] = 0;
    // SAFETY: settings is a valid termios.
    if unsafe { libc::tcsetattr(fd, libc::TCSADRAIN, &settings) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Put the terminal back as it was before [`enter_raw`]; nothing before it.
pub fn restore(fd: RawFd) {
    if let Some(settings) = SAVED.get() {
        // SAFETY: settings is the termios tcgetattr returned.
        unsafe { libc::tcsetattr(fd, libc::TCSADRAIN, settings) };
    }
}

/// The terminal's size in cells; unknown (`None`) when it reports none.
pub fn window_size(fd: RawFd) -> Pane {
    // SAFETY: winsize is plain data; the ioctl fills it.
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    // SAFETY: size is a valid out-pointer for TIOCGWINSZ.
    if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut size) } != 0 {
        return Pane::default();
    }
    Pane {
        columns: Some(usize::from(size.ws_col)),
        rows: Some(usize::from(size.ws_row)),
    }
}

/// Write to `fd` without going through Rust's buffers, for the panic hook
/// and signal paths where nothing else may be relied on.
pub fn write_raw(fd: RawFd, bytes: &[u8]) {
    // SAFETY: the pointer and length come from a live slice.
    unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
}

/// The write end of the signal pipe, for the handler.
static SIGNAL_PIPE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_signal(signal: libc::c_int) {
    let byte = signal as u8;
    let fd = SIGNAL_PIPE.load(Ordering::Relaxed);
    // SAFETY: write is async-signal-safe; the pipe is non-blocking, so a full
    // pipe drops the byte instead of blocking in a handler.
    unsafe { libc::write(fd, (&raw const byte).cast(), 1) };
}

/// Signals delivered as bytes on a pipe, so the event loop reads them with
/// everything else instead of doing work in a handler.
pub struct Signals {
    read_fd: RawFd,
}

impl Signals {
    /// Catch `signals` (one set per process).
    pub fn install(signals: &[libc::c_int]) -> io::Result<Self> {
        let mut ends = [0 as RawFd; 2];
        // SAFETY: ends has room for the two descriptors pipe writes.
        if unsafe { libc::pipe(ends.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        for fd in ends {
            // SAFETY: fd is the descriptor just created.
            unsafe {
                libc::fcntl(
                    fd,
                    libc::F_SETFL,
                    libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK,
                );
                libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            }
        }
        SIGNAL_PIPE.store(ends[1], Ordering::Relaxed);
        for &signal in signals {
            // SAFETY: sigaction is plain data; the handler is async-signal-safe.
            let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
            action.sa_sigaction = on_signal as *const () as usize;
            // SAFETY: action.sa_mask is a valid sigset to initialise.
            unsafe { libc::sigemptyset(&mut action.sa_mask) };
            // SAFETY: action is fully initialised.
            if unsafe { libc::sigaction(signal, &action, std::ptr::null_mut()) } != 0 {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(Self { read_fd: ends[0] })
    }

    pub fn fd(&self) -> RawFd {
        self.read_fd
    }

    /// The signals that arrived since the last call.
    pub fn take(&self) -> Vec<libc::c_int> {
        let mut buffer = [0u8; 64];
        // SAFETY: buffer is valid for its length.
        let read = unsafe { libc::read(self.read_fd, buffer.as_mut_ptr().cast(), buffer.len()) };
        let count = usize::try_from(read).unwrap_or(0);
        buffer[..count]
            .iter()
            .map(|&b| libc::c_int::from(b))
            .collect()
    }
}

/// Leave with the signal's own fate: default action, as a process that never
/// caught it. The terminal is restored by the caller first.
pub fn die_by(signal: libc::c_int) -> ! {
    // SAFETY: resets the disposition and re-raises; plain libc calls.
    unsafe {
        libc::signal(signal, libc::SIG_DFL);
        libc::raise(signal);
    }
    std::process::exit(128 + signal)
}

/// What [`wait`] saw ready.
#[derive(Debug, Clone, Copy, Default)]
pub struct Ready {
    pub stdin: bool,
    pub signal: bool,
}

/// Wait up to `timeout` (forever for `None`) for input on stdin (when
/// `watch_stdin`) or a signal byte.
pub fn wait(signals: &Signals, watch_stdin: bool, timeout: Option<Duration>) -> Ready {
    let mut fds = [
        libc::pollfd {
            fd: STDIN,
            events: libc::POLLIN,
            revents: 0,
        },
        libc::pollfd {
            fd: signals.fd(),
            events: libc::POLLIN,
            revents: 0,
        },
    ];
    // Round up so a timer is never polled for early and spun on.
    let millis = timeout.map_or(-1, |t| {
        i32::try_from(t.as_millis() + u128::from(t.subsec_nanos() % 1_000_000 != 0))
            .unwrap_or(i32::MAX)
    });
    // Without stdin the set is the signal pipe alone.
    let set = if watch_stdin {
        &mut fds[..]
    } else {
        &mut fds[1..]
    };
    // SAFETY: set is a valid array of pollfd for the call.
    let result = unsafe { libc::poll(set.as_mut_ptr(), set.len() as libc::nfds_t, millis) };
    if result <= 0 {
        // A timeout, or EINTR from a signal whose byte is on the pipe.
        return Ready::default();
    }
    let readable =
        |fd: &libc::pollfd| fd.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0;
    Ready {
        stdin: watch_stdin && readable(&fds[0]),
        signal: readable(&fds[1]),
    }
}

/// One read from stdin; `None` at end of input or on an error (a hung-up
/// terminal reads as `EIO`).
pub fn read_stdin(buffer: &mut [u8]) -> Option<usize> {
    loop {
        // SAFETY: buffer is valid for its length.
        let read = unsafe { libc::read(STDIN, buffer.as_mut_ptr().cast(), buffer.len()) };
        if read > 0 {
            return usize::try_from(read).ok();
        }
        if read < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
            continue;
        }
        return None;
    }
}
