# 2026-11-17 — Refused-PTY test: the PTY closed before its command started

- **Broke:** `refusedPTYFailsCleanlyAndAPermittedOneAttaches` failed once on
  hosted CI (7af249e): the permitted PTY's close timed out after its whole
  20 s budget. The test closed as soon as it read `attached`, which was only
  the PTY's echo. sshd's forked child had not yet made the PTY its terminal
  (load 20 on 3 cores), so it missed the hangup and then waited forever
  opening a PTY whose master was gone; sshd never reaped it and never closed
  the channel. A test bug; the app meets it only when an Attach is left
  within the moment a loaded Mac Host takes to start it, and no client
  change can make that sshd close the channel.
- **Worked:** the sshd log in the lane's diagnostics artifact
  (`13-sshd-modern.log`) settled it: the child logged `Setting controlling
  tty using TIOCSCTTY` after sshd had released the PTY, and then nothing.
- **Broke:** the red proof never ran: the Mac sat at load ~300 for hours
  (Mike's apps), and `mac_run` waits for load under 1.5 per core. A command
  that ignores SIGHUP and opens its tty a second late should recreate the
  stuck child on demand; it is still unproven.
- **Worked:** with the Mac out, a `ci.yml` dispatch on a temporary branch
  (pushed by @ultimate) proved the change on hosted runners.
- **Watch out:** every package test that closes a `cat` PTY expecting a
  clean close now opens it through `openPTYRunningCat`, which waits for the
  command's own output (Known trap).
