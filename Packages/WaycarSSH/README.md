# WaycarSSH

`WaycarSSH` is Waycar's repository-local Swift package for the native SSH
implementation accepted in ADR 0011. The package owns libssh2 and OpenSSL so
the app target consumes only the `WaycarSSH` product and never imports native
modules or owns native pointers directly.

The checked-in XCFrameworks are the normal build input. Rebuilding them is a
dependency-maintenance operation, not part of ordinary app or CI builds.

## Audit and rebuild

`Sources.lock` records the exact upstream source archives, tags, commits, and
SHA-256 hashes. `Scripts/build-native.sh` verifies both archives before
extracting or compiling them. A mismatch is fatal. It then applies Waycar's
reviewed libssh2 patches (see [libssh2 patches](#libssh2-patches)).

Run the complete rebuild from the repository root. `make ssh-artifacts` uses
the globally selected Xcode, so pick the one recorded in
`Artifacts/PROVENANCE.md` per command with `DEVELOPER_DIR` instead of
`xcode-select`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
WAYCAR_SSH_XCFRAMEWORK_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
    make ssh-artifacts
```

The command builds Release arm64 slices for iPhoneOS and iPhone Simulator,
creates both XCFrameworks, refreshes licenses and provenance, writes file-level
SHA-256 checksums, signs the OpenSSL XCFramework, and verifies the result. Use
an Apple Development or Apple Distribution identity belonging to team
`5NWMRTN5BA`. With the same pins and toolchain, `Artifacts/PROVENANCE.md` comes
out unchanged; a diff there means the toolchain drifted. File checksums still
change on every rebuild (archive member dates, OpenSSL's build date, libssh2's
temporary source path, signatures, and XCFramework library order), so reviewers
compare the compiled code instead: per-member `__TEXT,__text`, symbols,
headers, and `LC_BUILD_VERSION`.

The recorded toolchain is now Xcode 27.0 (27A266a) with the iOS 27.0 SDK. #105
rebuilt both XCFrameworks with it on purpose, because Xcode 26.6 is no longer
installed. The deployment target (iOS 18.0), build flags and signing identity
did not change, but every compiled member differs from the 26.6 artifacts, so
compare a rebuild against the 27.0 artifacts, not older ones.

To verify the committed artifacts without downloading or compiling sources:

```sh
make verify-ssh-artifacts
```

OpenSSL is built without its legacy provider and without the legacy algorithms
listed in the provenance record. The pinned libssh2 snapshot disables obsolete
algorithms upstream; the build additionally defines `LIBSSH2_NO_AES_CBC`.

## libssh2 patches

`Patches/libssh2/*.patch` are Waycar's changes on top of the pinned libssh2
snapshot. `LIBSSH2_PATCHES` in `Sources.lock` lists them in application order
with each file's reviewed SHA-256; `Scripts/native-sources.sh` refuses a patch
that is missing, unlisted, or changed, and applies them with `patch -p1
--fuzz=0`, so a rejected hunk is fatal. `build-native.sh --verify-sources-only`
checks the archives and applies the patches without compiling.
`Artifacts/PROVENANCE.md` records one `libssh2 patch:` line per patch with its
hash, and `make verify-ssh-artifacts` requires the patch files, `Sources.lock`
and the provenance record to agree exactly, and every `CLibSSH2` slice to
define the symbols in `LIBSSH2_PATCH_SYMBOLS` and declare those and the
macros in `LIBSSH2_PATCH_MACROS`. Changing a patch therefore means updating its
hash in `Sources.lock`, rebuilding the artifacts, and running the patch tests.

| Patch | Adds |
| --- | --- |
| `0001` userauth | `LIBSSH2_FLAG_PUBKEY_SKIP_QUERY` session flag: publickey auth signs its first request instead of waiting for `SSH_MSG_USERAUTH_PK_OK` (one round trip less). Off by default. |
| `0002` channel | `libssh2_channel_request_pty_process_startup()`: pty-req and exec/shell/subsystem back to back, replies collected in order; refusals reported through `LIBSSH2_CHANNEL_DENIED_PTY` / `LIBSSH2_CHANNEL_DENIED_PROCESS`. |
| `0003` packet | `ssh2_packet_requirev()` keeps waiting when a reply of the wanted type belongs to another channel, instead of failing the wait. |
| `0004` channel | `libssh2_channel_open_start()`, `libssh2_channel_direct_tcpip_start()`, `libssh2_channel_direct_streamlocal_start()` and `libssh2_channel_open_finish()`: channel opens with per-channel state, so several can await their replies at once. |

The exact contracts are the comments next to the declarations in
`include/libssh2.h`, inside the patches.

`make test-libssh2-patches` is their regression test. It builds the patched
snapshot for the Mac and runs `Patches/tests/libssh2_patches_test.c` against a
disposable unprivileged sshd on a loopback port behind
`Patches/tests/latency_proxy.py`, a proxy adding a fixed one-way delay
(`WAYCAR_SSH_PATCH_TEST_DELAY_MS`, default 40 ms) so saved round trips show in
wall-clock time. It checks behavior against stock OpenSSH (sshd's log shows
whether a publickey query was sent; `no-pty` keys and unknown subsystems
produce the refusals; `MaxSessions 2` shows whether a freed in-flight open was
closed on the server) as well as the saved round trips. It needs an OpenSSL 3
prefix for the test binary only: `WAYCAR_SSH_HOST_OPENSSL`, else Homebrew's
`openssl@3`. No simulator is involved.

## Session scheduling

`SessionDriver` owns one `LIBSSH2_SESSION` and serializes every call into it
behind one operation mutex. What may release that mutex mid-operation is fixed
by where libssh2 keeps its non-blocking continuation state, so re-check this
section against `Sources.lock` whenever libssh2 is bumped.

In 1.11.1 an unfinished channel open is **session** state: `open_state`,
`open_channel`, `open_packet`, `open_data` and `open_packet_requirev_state`
drive `_libssh2_channel_open`, and `direct_state` with `direct_message` drives
both `channel_direct_tcpip` and `channel_direct_streamlocal` — one state
machine for the two, despite the declaring comment naming only the first. All
of them are fields of `LIBSSH2_SESSION` in
`src/libssh2_priv.h`. `_libssh2_channel_open` only builds its request while
`open_state` is idle, so a second open entered during another's `EAGAIN`
resumes the first state machine and hands the first call's channel to the
second caller. Stock channel opens must not interleave.

The pipelined opens from patch `0004` are the exception: `libssh2_channel_*_start()`
keeps the request in `openNB_*` fields of the `LIBSSH2_CHANNEL` it returns, and
`libssh2_channel_open_finish()` waits only for the reply addressed to that
channel's local id, so any number of them, and one stock open, can be awaiting
replies at once. That relies on patch `0003`: unpatched,
`_libssh2_packet_requirev` fails a channel-filtered wait whenever the packet it
reads is another channel's reply of the same type. Their sends still obey the
transport rule below: a request the transport holds partially sent can only
be drained by its own `libssh2_channel_open_finish()` or `libssh2_channel_free()`.
Freeing a pipelined open the server may have seen waits for its reply and
closes a confirmed channel, so it holds a channel-admission lease until then.

`SessionDriver` drives every channel open through these entry points
(`openChannel`): `claimChannelOpenSlot` admits up to
`pipelinedChannelOpenLimit` (32) opens in flight, of which at most one is a
stock open (`libssh2_sftp_init`, which still uses the session's `open_state`),
and the opener releases the operation mutex between `open_finish` turns. A
direct-tcpip open keeps the mutex (`yielding: false`) because the forwarding
pump needs the session to itself. Waiting for a slot is not an open attempt:
a task cancelled or timed out while queued leaves no native state behind. One
cancelled or timed out after its open started is not abandoned to invalidate
the session either: `freeAbandonedChannelOpen` frees it through the registry
(never cancellable, 2 s budget, yielding between turns) before the caller
sees the error. Only two outcomes invalidate: a free that cannot finish, and
a transport that ended under it. `libssh2_channel_free()` reports success
whatever its settling hit, so after the native free a non-blocking `MSG_PEEK`
(`transportHasEnded`) checks for FIN or RST. A refused open
(`CHANNEL_OPEN_FAILURE`, which is final) fails only that channel: it is freed
locally and spares the session. The caller's admission lease is therefore
held until the native channel is really gone.

Who goes next is a priority decision. `SSHOperationPriority` is a task-local
(`.normal` by default); the operation mutex and the open slot both hand off
directly to the next waiter, interactive first and in arrival order within a
class. The app runs terminal work (attach, mosh bootstrap, grace-expiry
standbys and the first standby an intent waits on) at `.interactive` so it overtakes summaries, probes and detection queued on the
same connection. Background cleanup inherits its caller's priority.

One-shot work returns before its channel closes. `exchangeStreamLocal`,
`executeResponseLine` and `executeUntilLine` hand the caller its answer as
soon as it is read (for `executeUntilLine`, the first stdout line the
predicate matches), then finish EOF, close and free in a background task that
takes the mutex and cleans up by identity (`finishOneShotInBackground`).
`onChannelReleased` runs exactly once, after that cleanup, so an admission
lease released there never undercounts a channel the server still holds
(#148). A cleanup that fails is logged and invalidates the session. `execute`
keeps its synchronous close, because its exit status needs the peer's close
anyway.

Most of what follows open is **channel** state — `process_state`, `read_state`,
`write_state`, `close_state`, `wait_eof_state`, `wait_closed_state`,
`free_state` and `reqPTY_state` all live on `LIBSSH2_CHANNEL` — which is why
the PTY and long-lived stream-local paths can take one short turn per call.
Any operation that means to release the mutex between turns has to re-resolve
its channel by id from a driver registry afterwards: invalidation frees the
session, `libssh2_session_free` destroys every channel attached to it, and a
pointer captured before the release would dangle.

Sending is the exception, and it cuts across every channel. The pending
outbound packet is **session** state: `odata`, `olen`, `osent` and `ototal_num`
on `struct transportpacket` (`src/libssh2_priv.h`), reached through
`session->packet`. `_libssh2_transport_send` records them whenever a send could
not flush the whole packet — including when it sent nothing — and
`send_existing` refuses any retry whose `data` pointer or length differs, with
the comment "Address is different, returning EAGAIN" (`src/transport.c`). It
returns `EAGAIN` without advancing the packet, so a foreign producer can never
drain it.

The consequence is a livelock, not a slowdown. `_libssh2_channel_write` sends
from the channel's own `write_packet` buffer, so the owning channel can resume
across a mutex release; anyone else cannot. If a caller holds the operation
mutex across its own `EAGAIN` loop while another channel owns a pending packet,
it spins until its deadline and the owner never gets a turn. Channel open is
such a caller. Any call that loops on `EAGAIN` while holding the mutex must
therefore first establish that no other operation is the transport-send owner;
`libssh2_session_block_directions` reporting an outbound block after a
packet-producing `EAGAIN` is the public signal for it, and `send_existing` runs
before `_libssh2_transport_send` clears that bit, so the report is conservative
rather than falsely clear.

The **exact** owning call decides how ownership ends. A successful
non-`EAGAIN` result clears ownership even if libssh2's direction bit is stale.
A negative result clears only when no outbound block remains; with outbound
still reported, the caller first reads any native error status it needs and
then invalidates the whole session. Completed invalidation frees
`session->packet` along with the session. A cancelled or timed-out Swift task
is not one of them — the native packet outlives it. `_libssh2_channel_write`
leaves `write_state` at `libssh2_NB_state_created` on `EAGAIN`, so re-calling
`libssh2_channel_write_ex` on the same channel resends the same
`write_packet`/`write_packet_len` and is the only call that can drain it;
`send_existing` sanity-checks `data` and `data_len` alone and never the payload,
so a caller that resumes with a different payload buffer gets no diagnostic.
Before #130, `writePTY` and `writeStreamLocal` threw directly out of their wait,
so cancellation could strand a packet for the rest of the session's life.
Cleanup now drives the exact owning call non-cancellably to a non-`EAGAIN`
result within its reclamation budget, and invalidates the session if that
budget expires. A negative non-`EAGAIN` result while libssh2 still reports
outbound state also invalidates: clearing the owner in that state would admit
a foreign producer while the native packet may still be pending.

Channel teardown has its own resource transition. As soon as PTY exit-status,
PTY close, or direct-streamlocal close begins, the registry entry stops
accepting reads, writes, and resizes. Cleanup may still re-resolve that entry
across yielded turns, but user I/O cannot interleave with close/free on the
same native channel. PTY close waits for an in-flight exit-status handshake;
if that handshake fails, ordinary PTY I/O is enabled again so the caller can
retry or close explicitly.

SFTP is a second exception and a stronger one. `struct _LIBSSH2_SFTP`
(`src/sftp.h`) carries one continuation slot per operation kind —
`mkdir_state`/`mkdir_packet`/`mkdir_request_id`, `stat_*`, `unlink_*`,
`rename_*`, `fstat_*` and the rest — plus one shared inbound parser
(`packet_state`, `partial_packet`, `partial_len`, `partial_received`). A second
call of the same kind resumes the first call's state instead of starting its
own, so it can combine one request's packet with another's length or deliver
one call's result into another's output buffer. Re-resolving the handle by id
does not isolate this, because the id resolves to the same shared state. Every
call on one SFTP handle stays mutually exclusive for its whole logical
operation, waits included, and `libssh2_sftp_init` stays serialized on its own
session-owned `open_state`.

Waits are released session-wide rather than per channel. libssh2 buffers what
it decrypts, so an operation reading its own channel consumes the packets the
others are blocked on and the socket keeps no edge to report; `SessionActivity`
therefore counts receives and wakes every wait armed before the last one. The
number of wakeups per inbound packet grows with the number of channels parked
at once, so turn bodies stay small.

## Test lanes

`make test` runs the app suites and then `scripts/run-waycarssh-package-tests.sh`
for this package's own suites, including `SessionDriverE2ETests`. The local
package runner asserts only that something executed, not an exact count, so
machines without the disposable sshd fixture can skip the E2E suite cleanly.

`scripts/run-ci-ios-tests.sh` runs the package lane against its disposable
sshd fixture (including a no-pty key, `WAYCAR_SSH_E2E_NO_PTY_KEY_SEED`, for
the PTY-denial cases) and requires exactly **138 tests in 10 suites** with no
skips, plus a list of display names it greps for one by one (the block after
"WaycarSSH package E2E" in that script is the authority; it currently pins 44
names, among them `outbound backpressure does not livelock a channel open`,
`one-shot RPCs yield so a live PTY can progress` and
`a serialized channel-open wait honors deadline and cancellation`). The
scheduling and patched-libssh2 suites (`SessionDriverSchedulingE2ETests`,
`SessionDriverPatchedLibSSH2E2ETests`) and the state-machine transition suites
(`ByteTransportMachineTests`, `TransportSendOwnerMachineTests`,
`ChannelOpenSlotMachineTests`) count toward the 138; tests that rely on
a single open slot set it with `setChannelOpenLimitForTesting(1)`.

The post-quantum handshake uses its own ML-KEM-only sshd endpoint. The shared
resource and timing suites remain on a Curve25519-only baseline so algorithm
coverage cannot change their fixture behavior.

The package lane treats the count and display names as merge gates, so adding
E2E behavior requires updating both in the same change. The patches have
their own host-only lane, `make test-libssh2-patches` (see "libssh2
patches").

## Direct-streamlocal acceptance

`scripts/run-ci-ios-tests.sh` provisions disposable OpenSSH endpoints and a
temporary Unix-socket fake herdr server, then runs the mandatory
`WaycarSSHDirectStreamLocalE2ETests` suite.

Every sshd instance runs unprivileged, as the invoking account, so the whole
gate runs on a developer machine with no `sudo` and leaves nothing behind. Each
session is forced through POSIX `sh` with an isolated `HOME` and a fixed `PATH`
that contains a `herdr` stub and no `socat`, so the fixture means the same thing
on every machine and can never reach a real herdr server. The single exception
is real password authentication: macOS cannot verify an account password
without root, and an unprivileged sshd can only authenticate the account it
already runs as. Those two tests need a disposable account and one root-owned
sshd, so they skip without passwordless `sudo` and are mandatory in merge CI
(`WAYCAR_CI_MANDATORY=1`).

The suite includes a repeatable 25-exchange loopback measurement. Its printed
output is telemetry for local channel open, exchange, and close cost — not a
merge gate, not a machine-speed promise, and not a WAN latency promise.
Absolute loopback timing varies with the CI scheduler; accidental remote-process
fallback is a hard functional failure under the socat-free Host PATH the
fixture already enforces (see `scripts/run-ci-ios-tests.sh`).

### Recorded exec-plus-socat baseline

The transport spike measured both transports on loopback over the same
authenticated session (spec #110, ADR 0011). Kept as historical context for
telemetry comparison only:

| Transport | Mean per exchange |
| --- | --- |
| `exec` + `socat` | 22.368 ms |
| `direct-streamlocal` | 0.514 ms |

The socat backend was deleted with the Citadel cutover, so that number cannot be
re-measured. Architecture regression (reintroducing per-request remote process
startup) is caught by the socat-free fixture and the suite's functional
direct-streamlocal coverage, not by an absolute timing ceiling.

## Jump Host acceptance

`SSHConnection.connectThrough(to:timeout:)` opens a `direct-tcpip` channel on
an authenticated Jump Host and runs a second, independent SSH session over its
byte stream. The target performs its own Host Key verification and
authentication. Closing the target connection tears down the target session,
forwarding channel, and Jump Host session in that order.

The same CI fixture also runs `WaycarSSHJumpHostGateE2ETests` against two
disposable sshd instances with independent Host Keys. The suite is a hard gate
for protocol-17 direct-streamlocal traffic, failure taxonomy, cancellation,
deadlines, cleanup, and sequential and concurrent stress.
