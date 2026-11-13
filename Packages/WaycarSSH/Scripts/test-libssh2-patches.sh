#!/bin/bash
#
# Regression test for Waycar's libssh2 patches (Patches/libssh2).
#
# Builds the pinned libssh2 snapshot with the locked patches for the Mac
# (static, OpenSSL backend), then drives Patches/tests/libssh2_patches_test.c
# against a disposable sshd: unprivileged, on a loopback high port, out of one
# temporary directory, behind a proxy that adds a fixed one-way delay so round
# trips show up in wall-clock time. Nothing outside the temporary directory is
# touched; no simulator is used.
#
# The Mac has no OpenSSL headers, so this needs one: WAYCAR_SSH_HOST_OPENSSL
# names its prefix, otherwise Homebrew's openssl@3 is used. It only links the
# test binary; the shipped artifacts build their own pinned OpenSSL.
#
#   Packages/WaycarSSH/Scripts/test-libssh2-patches.sh
#   make test-libssh2-patches
#
# WAYCAR_SSH_PATCH_TEST_DELAY_MS sets the one-way delay (default 40 ms).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_LOCK="${WAYCAR_SSH_SOURCE_LOCK:-${PACKAGE_DIR}/Sources.lock}"
TEST_DIR="${PACKAGE_DIR}/Patches/tests"
DELAY_MS="${WAYCAR_SSH_PATCH_TEST_DELAY_MS:-40}"
RTT_MS=$((DELAY_MS * 2))

# shellcheck source=../Sources.lock
source "${SOURCE_LOCK}"
# shellcheck source=native-sources.sh
source "${SCRIPT_DIR}/native-sources.sh"

for command in curl shasum tar patch cmake cc python3 ssh-keygen; do
    command -v "${command}" >/dev/null || {
        echo "error: required command not found: ${command}" >&2
        exit 1
    }
done
[[ -x /usr/sbin/sshd ]] || {
    echo "error: /usr/sbin/sshd not found" >&2
    exit 1
}

OPENSSL_PREFIX="${WAYCAR_SSH_HOST_OPENSSL:-}"
if [[ -z "${OPENSSL_PREFIX}" ]] && command -v brew >/dev/null; then
    OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
fi
[[ -f "${OPENSSL_PREFIX}/include/openssl/evp.h" && -f "${OPENSSL_PREFIX}/lib/libcrypto.a" ]] || {
    echo "error: set WAYCAR_SSH_HOST_OPENSSL to an OpenSSL 3 prefix" \
        "(include/openssl, lib/libcrypto.a), e.g. brew install openssl@3" >&2
    exit 1
}
OPENSSL_CLI="${OPENSSL_PREFIX}/bin/openssl"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/waycar-libssh2-patches.XXXXXX")"
background_pids=()
cleanup() {
    local pid
    for pid in "${background_pids[@]:-}"; do
        [[ -n "${pid}" ]] && kill "${pid}" >/dev/null 2>&1 || true
    done
    # sshd's per-connection sshd-session children outlive the listener.
    pkill -f "sshd-session.*${WORK_DIR}" >/dev/null 2>&1 || true
    pkill -f "${WORK_DIR}/sshd_config" >/dev/null 2>&1 || true
    wait >/dev/null 2>&1 || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "==> Building patched libssh2 ${LIBSSH2_VERSION} for the Mac"
download_and_verify "libssh2-${LIBSSH2_VERSION}" "${LIBSSH2_URL}" "${LIBSSH2_SHA256}"
verify_libssh2_patches
LIBSSH2_SOURCE="${WORK_DIR}/libssh2-${LIBSSH2_VERSION}"
apply_libssh2_patches "${LIBSSH2_SOURCE}"
env -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    cmake -S "${LIBSSH2_SOURCE}" -B "${WORK_DIR}/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-DLIBSSH2_NO_AES_CBC" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
        -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
        -DENABLE_ZLIB_COMPRESSION=OFF -DCRYPTO_BACKEND=OpenSSL \
        -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -DOPENSSL_ROOT_DIR="${OPENSSL_PREFIX}" >/dev/null
cmake --build "${WORK_DIR}/build" --parallel "${WAYCAR_SSH_JOBS:-4}" >/dev/null
TEST_BIN="${WORK_DIR}/libssh2_patches_test"
cc -std=c99 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror -O1 \
    -I "${LIBSSH2_SOURCE}/include" -I "${OPENSSL_PREFIX}/include" \
    "${TEST_DIR}/libssh2_patches_test.c" \
    "${WORK_DIR}/build/src/libssh2.a" "${OPENSSL_PREFIX}/lib/libcrypto.a" \
    -o "${TEST_BIN}"

echo "==> Starting the disposable sshd fixture"
"${OPENSSL_CLI}" genpkey -algorithm ed25519 -out "${WORK_DIR}/device.pem" 2>/dev/null
"${OPENSSL_CLI}" genpkey -algorithm ed25519 -out "${WORK_DIR}/no-pty.pem" 2>/dev/null
"${OPENSSL_CLI}" genpkey -algorithm ed25519 -out "${WORK_DIR}/stranger.pem" 2>/dev/null
"${OPENSSL_CLI}" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
    -out "${WORK_DIR}/rsa.pem" 2>/dev/null
ssh-keygen -q -t ed25519 -N '' -f "${WORK_DIR}/host_ed25519"
{
    "${TEST_BIN}" pubkey "${WORK_DIR}/device.pem"
    "${TEST_BIN}" pubkey "${WORK_DIR}/rsa.pem"
    printf 'no-pty %s\n' "$("${TEST_BIN}" pubkey "${WORK_DIR}/no-pty.pem")"
} > "${WORK_DIR}/authorized_keys"

# Every session runs under POSIX sh with an isolated HOME, never the invoking
# account's login shell and dotfiles.
mkdir -p "${WORK_DIR}/home"
cat > "${WORK_DIR}/force-sh" <<'EOF'
#!/bin/sh
exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
EOF
chmod +x "${WORK_DIR}/force-sh"

SOCKET_PATH="${WORK_DIR}/echo.sock"
python3 "${TEST_DIR}/unix_echo_server.py" "${SOCKET_PATH}" >/dev/null &
background_pids+=("$!")

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
wait_for_port() {
    local port="$1"
    for _ in $(seq 1 100); do
        if python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()' \
            "${port}" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    echo "error: nothing is listening on 127.0.0.1:${port}" >&2
    exit 1
}

SSHD_PORT="$(free_port)"
SSHD_LOG="${WORK_DIR}/sshd.log"
# MaxSessions 2 is what the pipelined session-open case counts against.
# LogLevel DEBUG2 logs whether each publickey request is a query or signed.
printf '%s\n' \
    "Port ${SSHD_PORT}" \
    "ListenAddress 127.0.0.1" \
    "HostKey ${WORK_DIR}/host_ed25519" \
    "PidFile ${WORK_DIR}/sshd.pid" \
    "PasswordAuthentication no" \
    "KbdInteractiveAuthentication no" \
    "PubkeyAuthentication yes" \
    "PubkeyAcceptedAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256" \
    "AuthorizedKeysFile ${WORK_DIR}/authorized_keys" \
    "UsePAM yes" \
    "PermitRootLogin no" \
    "AllowUsers ${USER}" \
    "StrictModes no" \
    "PerSourcePenalties no" \
    "PrintMotd no" \
    "PrintLastLog no" \
    "LogLevel DEBUG2" \
    "MaxSessions 2" \
    "AllowStreamLocalForwarding yes" \
    "SetEnv HOME=${WORK_DIR}/home" \
    "ForceCommand ${WORK_DIR}/force-sh" \
    > "${WORK_DIR}/sshd_config"
/usr/sbin/sshd -D -e -f "${WORK_DIR}/sshd_config" 2>>"${SSHD_LOG}" &
background_pids+=("$!")
wait_for_port "${SSHD_PORT}"

python3 "${TEST_DIR}/latency_proxy.py" --target-port "${SSHD_PORT}" \
    --delay-ms "${DELAY_MS}" > "${WORK_DIR}/proxy.port" &
background_pids+=("$!")
for _ in $(seq 1 100); do
    [[ -s "${WORK_DIR}/proxy.port" ]] && break
    sleep 0.1
done
PORT="$(cat "${WORK_DIR}/proxy.port")"
wait_for_port "${PORT}"
for _ in $(seq 1 100); do
    [[ -S "${SOCKET_PATH}" ]] && break
    sleep 0.1
done

passed=0
failed=0
pass() {
    printf 'ok    %s\n' "$1"
    passed=$((passed + 1))
}
fail() {
    printf 'FAIL  %s\n' "$1"
    failed=$((failed + 1))
}
field() {
    sed -n "s/^$2=//p" <<<"$1" | sed -n 1p
}
expect_eq() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi
}
expect_contains() {
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 ('$2' lacks '$3')"; fi
}
# expect_saves <label> <slow_ms> <fast_ms> <minimum saving in ms>
expect_saves() {
    if awk -v slow="$2" -v fast="$3" -v min="$4" 'BEGIN { exit !(slow - fast >= min) }'; then
        pass "$1 (${2} -> ${3} ms)"
    else
        fail "$1 (${2} -> ${3} ms, expected to save >= ${4} ms)"
    fi
}
run() {
    "${TEST_BIN}" "$@" || {
        echo "FAIL  ${TEST_BIN##*/} $*" >&2
        exit 1
    }
}
# Smallest <field> over three runs of one subcommand: a single wall-clock
# sample on a shared Mac (PAM, scheduling) is too noisy to compare round trips.
fastest() {
    local name="$1" best="" value
    shift
    for _ in 1 2 3; do
        value="$(field "$(run "$@")" "${name}")"
        if [[ -z "${best}" ]] ||
            awk -v a="${value}" -v b="${best}" 'BEGIN { exit !(a < b) }'; then
            best="${value}"
        fi
    done
    echo "${best}"
}
log_offset() {
    wc -c < "${SSHD_LOG}" | tr -d ' '
}
# Publickey requests sshd logged since an offset, by kind ("querying" for an
# unsigned PK_OK query, "attempting" for a signed request).
logged_requests() {
    tail -c "+$(($1 + 1))" "${SSHD_LOG}" | grep -c "$2 public key" || true
}

HALF_RTT=$((RTT_MS / 2))
echo "==> Patch A: publickey without the PK_OK query (RTT ${RTT_MS} ms)"
for key in device rsa; do
    for path in callback memory; do
        label="${key}/${path}"
        offset="$(log_offset)"
        stock="$(run auth "${PORT}" "${WORK_DIR}/${key}.pem" "${path}" 0)"
        expect_eq "${label} default: authenticates" "$(field "${stock}" rc)" 0
        expect_eq "${label} default: sends the unsigned query" \
            "$(logged_requests "${offset}" querying)" 1

        offset="$(log_offset)"
        skip="$(run auth "${PORT}" "${WORK_DIR}/${key}.pem" "${path}" 1)"
        expect_eq "${label} skip-query: authenticates" "$(field "${skip}" rc)" 0
        expect_eq "${label} skip-query: sends no query" \
            "$(logged_requests "${offset}" querying)" 0
        expect_eq "${label} skip-query: sends one signed request" \
            "$(logged_requests "${offset}" attempting)" 1
        expect_saves "${label} skip-query saves a round trip" \
            "$(fastest auth_ms auth "${PORT}" "${WORK_DIR}/${key}.pem" "${path}" 0)" \
            "$(fastest auth_ms auth "${PORT}" "${WORK_DIR}/${key}.pem" "${path}" 1)" \
            "${HALF_RTT}"
        if [[ "${path}" == callback ]]; then
            expect_eq "${label} skip-query: signs once" "$(field "${skip}" sign_count)" 1
            if [[ "${key}" == rsa ]]; then
                expect_eq "${label} skip-query: signs rsa-sha2-512" \
                    "$(field "${skip}" signed_alg)" rsa-sha2-512
            fi
        fi
    done
done
stranger="$(run auth "${PORT}" "${WORK_DIR}/stranger.pem" callback 0)"
expect_eq "unauthorized key, default: refused at the query" "$(field "${stranger}" rc)" -18
expect_eq "unauthorized key, default: never signs" "$(field "${stranger}" sign_count)" 0
stranger="$(run auth "${PORT}" "${WORK_DIR}/stranger.pem" callback 1)"
expect_eq "unauthorized key, skip-query: refused signature" "$(field "${stranger}" rc)" -19

echo "==> Patch B: pty-req and exec back to back"
command='tty; echo waycar-ptyexec-ok'
stock="$(run ptyexec "${PORT}" "${WORK_DIR}/device.pem" stock exec "${command}")"
combined="$(run ptyexec "${PORT}" "${WORK_DIR}/device.pem" combined exec "${command}")"
expect_eq "stock PTY + exec succeeds" "$(field "${stock}" rc)" 0
expect_eq "combined PTY + exec succeeds" "$(field "${combined}" rc)" 0
expect_eq "combined PTY + exec reports nothing denied" "$(field "${combined}" denied)" 0
expect_contains "combined exec runs on a PTY" "$(field "${combined}" output)" /dev/tty
expect_contains "combined exec runs the command" "$(field "${combined}" output)" waycar-ptyexec-ok
expect_saves "combined PTY + exec saves a round trip" \
    "$(fastest request_ms ptyexec "${PORT}" "${WORK_DIR}/device.pem" stock exec "${command}")" \
    "$(fastest request_ms ptyexec "${PORT}" "${WORK_DIR}/device.pem" combined exec "${command}")" \
    "${HALF_RTT}"
no_pty="$(run ptyexec "${PORT}" "${WORK_DIR}/no-pty.pem" combined exec "${command}")"
expect_eq "refused PTY: request denied" "$(field "${no_pty}" rc)" -22
expect_eq "refused PTY: only the PTY is reported" "$(field "${no_pty}" denied)" 1
expect_contains "refused PTY: the command still ran, without a TTY" \
    "$(field "${no_pty}" output)" "not a tty|waycar-ptyexec-ok"
no_process="$(run ptyexec "${PORT}" "${WORK_DIR}/device.pem" combined subsystem waycar-missing)"
expect_eq "refused process: request denied" "$(field "${no_process}" rc)" -22
expect_eq "refused process: only the process is reported" "$(field "${no_process}" denied)" 2
both="$(run ptyexec "${PORT}" "${WORK_DIR}/no-pty.pem" combined subsystem waycar-missing)"
expect_eq "refused PTY and process: both are reported" "$(field "${both}" denied)" 3

echo "==> Patch C: pipelined channel opens"
pipelined="$(run streamlocal "${PORT}" "${WORK_DIR}/device.pem" "${SOCKET_PATH}" 4 pipelined)"
expect_eq "four pipelined direct-streamlocal channels exchange data" \
    "$(field "${pipelined}" exchanged)" 4
expect_saves "four pipelined opens take one round trip, not four" \
    "$(fastest open_ms streamlocal "${PORT}" "${WORK_DIR}/device.pem" "${SOCKET_PATH}" 4 stock)" \
    "$(fastest open_ms streamlocal "${PORT}" "${WORK_DIR}/device.pem" "${SOCKET_PATH}" 4 pipelined)" \
    "$((RTT_MS * 2))"
mixed="$(run mixed "${PORT}" "${WORK_DIR}/device.pem" "${SOCKET_PATH}" "${WORK_DIR}/missing.sock")"
expect_eq "a refused open fails alone, around a stock open" \
    "$(field "${mixed}" results)" 0,-21,0
expect_eq "a refused open stays refused" "$(field "${mixed}" refused_again)" -39
expect_eq "channels around the refused open stay usable" "$(field "${mixed}" ok)" 1
sessions="$(run sessions "${PORT}" "${WORK_DIR}/device.pem")"
expect_eq "MaxSessions 2 confirms two pipelined session opens" \
    "$(field "${sessions}" max_sessions_confirmed)" 2
expect_eq "MaxSessions 2 refuses the third" "$(field "${sessions}" max_sessions_refused)" 1
expect_eq "freeing in-flight opens closes them on the server" \
    "$(field "${sessions}" after_free)" 0,0

echo
echo "${passed} passed, ${failed} failed"
[[ "${failed}" == 0 ]]
