#!/usr/bin/env bash
# Exercise the machine-wide simulator queue (scripts/sim-slot.py, refs #25)
# against a fake CoreSimulator, a fake process table, and seeded queue state.
# Never touches a real simulator.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/waycar-sim-slot.XXXXXX")"
work="$(cd "$work" && pwd -P)"
sleep 600 &
sleeper=$!  # A live pid for seeded queue tickets and CI claims.
background=("$sleeper")
cleanup() {
    exec 2>/dev/null  # No job-kill notices.
    kill -9 "${background[@]}" || true
    chmod -R u+rwx "$work"
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$work/bin" "$work/sims" "$work/flags"
export FAKE_SIM_DIR="$work/sims" FAKE_FLAGS="$work/flags" FAKE_PS_FILE="$work/ps"
export GIT_CEILING_DIRECTORIES="$work"
export PATH="$work/bin:$PATH"

# One file per device, `<name>|<state>|<device type>[|unavailable]` (the type
# defaults to the name), plus a log of every simctl call.
cat > "$work/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
set -eu
[[ "$1" == simctl ]] || exit 1
shift
printf '%s\n' "$*" >> "$FAKE_FLAGS/calls"
runtime=com.apple.CoreSimulator.SimRuntime.iOS-26-0
device="$FAKE_SIM_DIR/${2:-none}"
put() {
    printf '%s|%s|%s%s\n' "$name" "$1" "$type" "${unavailable:+|$unavailable}" > "$device"
}
case "$*" in
    'list runtimes --json')
        printf '{"runtimes":[{"identifier":"%s","version":"26.0","platform":"iOS","isAvailable":true}]}\n' "$runtime"
        ;;
    'list devices --json'|'list devices available --json')
        printf '{"devices":{"%s":[' "$runtime"
        separator=''
        for file in "$FAKE_SIM_DIR"/*; do
            IFS='|' read -r name state type unavailable < "$file"
            available=true
            [[ -z "$unavailable" ]] || available=false
            [[ "$available" == true || "$*" != *available* ]] || continue
            printf '%s{"udid":"%s","name":"%s","state":"%s","isAvailable":%s,"deviceTypeIdentifier":"%s"}' \
                "$separator" "$(basename "$file")" "$name" "$state" "$available" "${type:-$name}"
            separator=','
        done
        printf ']}}\n'
        ;;
    create\ *)
        udid=$(uuidgen)
        printf '%s|Shutdown|%s\n' "$2" "$3" > "$FAKE_SIM_DIR/$udid"
        echo "$udid"
        ;;
    boot\ *)
        IFS='|' read -r name state type unavailable < "$device"
        [[ "$state" == Shutdown ]] || { echo "Unable to boot device in current state: $state" >&2; exit 149; }
        put Booted
        ;;
    bootstatus\ *)
        [[ ! -e "$FAKE_FLAGS/slow-$2" ]] || sleep "$(cat "$FAKE_FLAGS/slow-$2")"
        IFS='|' read -r name state type unavailable < "$device"
        [[ ! -e "$FAKE_FLAGS/fail-$2" && "$state" == Booted ]]
        ;;
    shutdown\ *)
        IFS='|' read -r name state type unavailable < "$device"
        [[ "$state" != Shutdown ]] || { echo "Unable to shutdown device in current state: Shutdown" >&2; exit 149; }
        put Shutdown
        ;;
    spawn\ *\ launchctl\ print\ system)
        [[ ! -e "$FAKE_FLAGS/broken-$2" ]]
        ;;
    *) exit 1 ;;
esac
STUB

# The process table is a file in the format of the one ps call sim-slot.py
# makes (see ps_row); copies from before the doctor list fewer columns. CI
# claim start-time checks (`ps -o lstart= -p <pid>`) see the real process.
cat > "$work/bin/ps" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    '-S -axo pid=,ppid=,etime=,time=,%cpu=,args=') cat "$FAKE_PS_FILE" ;;
    '-axo pid=,ppid=,args=')
        while read -r pid ppid _ _ _ args; do
            printf '%s %s %s\n' "$pid" "$ppid" "$args"
        done < "$FAKE_PS_FILE"
        ;;
    *) exec /bin/ps "$@" ;;
esac
STUB
chmod +x "$work/bin/xcrun" "$work/bin/ps"

phone=11111111-1111-1111-1111-111111111111
ipad=22222222-2222-2222-2222-222222222222
max=33333333-3333-3333-3333-333333333333
other=44444444-4444-4444-4444-444444444444
spare=55555555-5555-5555-5555-555555555555
max2=66666666-6666-6666-6666-666666666666
ipad2=77777777-7777-7777-7777-777777777777
ci=88888888-8888-8888-8888-888888888888
max3=99999999-9999-9999-9999-999999999999
max4=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA
max10=BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB
max_type=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max
ipad_type=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB

# Fresh devices (all shut down), queue state, CI claims, and owners.
reset() {
    rm -f "$FAKE_SIM_DIR"/* "$FAKE_FLAGS"/*
    printf 'iPhone 17|Shutdown\n' > "$FAKE_SIM_DIR/$phone"
    printf 'iPad Pro 13-inch (M5)|Shutdown|%s\n' "$ipad_type" > "$FAKE_SIM_DIR/$ipad"
    printf 'iPhone 17 Pro Max|Shutdown|%s\n' "$max_type" > "$FAKE_SIM_DIR/$max"
    printf 'Legacy|Shutdown\n' > "$FAKE_SIM_DIR/$other"
    printf 'Spare|Shutdown\n' > "$FAKE_SIM_DIR/$spare"
    : > "$FAKE_FLAGS/calls"
    : > "$FAKE_PS_FILE"
    export WAYCAR_SIM_SLOTS_DIR="$work/state-$1" WAYCAR_SIM_SLOTS_CI_LOCK_ROOT="$work/ci-$1"
    export WAYCAR_SIM_SLOTS=2
    unset WAYCAR_SIM_IDLE_MINUTES
    rm -rf "$work/owner-a" "$work/owner-b" "$work/owner-c" "$work/owner-d"
    mkdir -p "$work/owner-a" "$work/owner-b" "$work/owner-c" "$work/owner-d"
}

# Second copies of the Pro Max and the iPad, plus CI's own Pro Max, which
# shares the device type but never joins the pool.
add_pool() {
    printf 'iPhone 17 Pro Max 2|Shutdown|%s\n' "$max_type" > "$FAKE_SIM_DIR/$max2"
    printf 'iPad Pro 13-inch (M5) 2|Shutdown|%s\n' "$ipad_type" > "$FAKE_SIM_DIR/$ipad2"
    printf 'Waycar CI|Shutdown|%s\n' "$max_type" > "$FAKE_SIM_DIR/$ci"
}

state_of() {
    cut -d'|' -f2 "$FAKE_SIM_DIR/$1"
}

# put_state <Booted|Booting|Shutdown> <udid...>: as if changed by hand.
put_state() {
    local state=$1 udid name type unavailable
    shift
    for udid in "$@"; do
        IFS='|' read -r name _ type unavailable < "$FAKE_SIM_DIR/$udid"
        printf '%s|%s|%s%s\n' "$name" "$state" "$type" "${unavailable:+|$unavailable}" > "$FAKE_SIM_DIR/$udid"
    done
}

# ps_row <pid> <ppid> <elapsed> <cpu time> <%cpu> <args>: one process in the
# fake table, padded like real ps output.
ps_row() {
    printf '%6s %6s %11s %10s %5s %s\n' "$@" >> "$FAKE_PS_FILE"
}

# live: a real process (sleep) to stand in for one in the fake table; its
# pid lands in live_pid.
live() {
    (sleep 600 & echo $! > "$work/live.pid")
    live_pid=$(cat "$work/live.pid")
    background+=("$live_pid")
}

# seed <python dict>: queue state relative to now, via lease(owner, renewed
# seconds ago), booting(lease, pid), ticket(pid, owner, udids, seconds ago;
# refused once, so waiting), and ago(seconds). Sampling ran just now.
seed() {
    mkdir -p "$WAYCAR_SIM_SLOTS_DIR"
    python3 - "$WAYCAR_SIM_SLOTS_DIR/state.json" "$1" <<'PY'
import json, sys, time
now = time.time()
def ago(seconds): return now - seconds
def lease(owner, renewed): return {"owner": owner, "acquired_at": ago(renewed), "renewed_at": ago(renewed)}
def booting(lease, pid): return dict(lease, booting=[pid, now + 1000])
def ticket(pid, owner, udids, seen=0):
    return {"id": f"{pid}{owner}{seen}", "pid": pid, "owner": owner, "udids": udids,
            "created_at": ago(seen), "seen_at": ago(seen), "blocked_at": ago(seen)}
state = {"leases": {}, "idle": {}, "tickets": [], "snapshot": None, "sampled_at": now}
state.update(eval(sys.argv[2]))
json.dump(state, open(sys.argv[1], "w"))
PY
}

# edit_state <python statements>: change the live queue state under its lock,
# with now, ago(seconds), and mine(owner) (that worktree's ticket) at hand.
edit_state() {
    python3 - "$WAYCAR_SIM_SLOTS_DIR" "$1" <<'PY'
import fcntl, json, sys, time
from pathlib import Path
now = time.time()
def ago(seconds): return now - seconds
directory = Path(sys.argv[1])
with open(directory / "lock", "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    state = json.loads((directory / "state.json").read_text())
    def mine(owner): return next(ticket for ticket in state["tickets"] if ticket["owner"].endswith("/" + owner))
    exec(sys.argv[2])
    (directory / "state.json").write_text(json.dumps(state))
PY
}

# slot <owner> <args...>: run as that worktree; stderr lands in $work/err.
# SIM_SLOT runs another copy of the script (an old one, for compatibility).
slot() {
    local owner=$1
    shift
    (cd "$work/$owner" && "${SIM_SLOT:-$repo_root/scripts/sim-slot.py}" "$@") 2> "$work/err"
}

# expect <status> <owner> <args...>; stdout lands in $work/out.
expect() {
    local wanted=$1 status=0
    shift
    slot "$@" > "$work/out" || status=$?
    [[ "$status" == "$wanted" ]] || { cat "$work/err" >&2; fail "sim-slot ${*:2} as $1 exited $status, expected $wanted"; }
}

# Background waiters get a start-up budget of about 60 s; the machine may be loaded.
start_waiter() {
    (cd "$work/$1" && exec "${SIM_SLOT:-$repo_root/scripts/sim-slot.py}" acquire --timeout 30 "$2") \
        > "$work/$1.out" 2> "$work/$1.err" &
    background+=("$!")
    echo "$!" > "$work/$1.pid"
}
# wait_granted <owner>: until that waiter prints its grant (a poll is 15 s),
# then it must exit 0.
wait_granted() {
    local attempt status=0
    for ((attempt = 0; attempt < 60; attempt += 1)); do
        if [[ -s "$work/$1.out" ]]; then
            wait "$(cat "$work/$1.pid")" || status=$?
            [[ "$status" == 0 ]] || { cat "$work/$1.err" >&2; fail "$1 printed a grant but exited $status"; }
            return 0
        fi
        sleep 1
    done
    cat "$work/$1.err" >&2
    fail "$1 was never granted"
}
# wait_polled <owner>: until that waiter finishes a poll begun after this call
# (each poll writes its heartbeat with the queue state it decided on).
wait_polled() {
    local attempt since
    since=$(python3 -c 'import time; print(time.time())')
    for ((attempt = 0; attempt < 60; attempt += 1)); do
        python3 - "$WAYCAR_SIM_SLOTS_DIR/state.json" "$1" "$since" <<'PY' && return 0
import json, sys
tickets = json.load(open(sys.argv[1]))["tickets"]
sys.exit(not any(t["owner"].endswith("/" + sys.argv[2]) and t["seen_at"] > float(sys.argv[3]) for t in tickets))
PY
        sleep 1
    done
    cat "$work/$1.err" >&2
    fail "$1 never polled again"
}
wait_queued() {
    local attempt
    for ((attempt = 0; attempt < 300; attempt += 1)); do
        slot owner-d status | grep -q "^  $1\. $2 wants" && return 0
        sleep 0.2
    done
    cat "$work/$2.err" >&2
    fail "$2 never queued at position $1"
}

lease_row() {
    grep -qE "^  $2 +$1 +[A-Za-z]+ +$3 " "$work/out"
}

a="'$work/owner-a'"
b="'$work/owner-b'"
c="'$work/owner-c'"

# Cap reached: --no-wait exits 75 and boots nothing.
reset cap
WAYCAR_SIM_SLOTS=1
put_state Booted "$other"
expect 75 owner-a acquire --no-wait "$phone"
grep -q 'slots in use' "$work/err" || fail 'cap refusal reason missing'
[[ "$(state_of "$phone")" == Shutdown ]] || fail 'refused request booted a simulator'
! grep -q '^boot' "$FAKE_FLAGS/calls" || fail 'refused request called simctl boot'

# A grant (by name, resolved like the app runner) boots the simulator, prints
# its UDID, and status names the owner; the unleased boot counts too.
reset grant
put_state Booted "$other"
expect 0 owner-a acquire --no-wait 'iPhone 17'
[[ "$(cat "$work/out")" == "$phone" ]] || fail 'acquire did not print the granted UDID'
[[ "$(state_of "$phone")" == Booted ]] || fail 'grant did not boot the simulator'
expect 0 owner-b status
grep -q '^Simulator slots: 2/2 in use' "$work/out" || fail 'status miscounts slots'
lease_row "$phone" 'iPhone 17' owner-a || fail 'status does not show the owner'
lease_row "$other" Legacy unleased || fail 'status hides the unleased simulator'
expect 0 owner-a acquire --no-wait 'generic/platform=iOS Simulator'
[[ ! -s "$work/out" ]] || fail 'a generic destination printed a UDID'

# At the cap the owner renews its own lease; another owner is refused it, and
# more simulators than the cap is an error, not a wait.
expect 0 owner-a acquire --no-wait "$phone"
expect 75 owner-b acquire --no-wait "$phone"
grep -q 'leased by owner-a' "$work/err" || fail 'held-simulator refusal reason missing'
expect 1 owner-b acquire --no-wait "$ipad" "$max" "$other"

# A non-owner cannot release it. The owner's release --all touches only its
# own leases.
WAYCAR_SIM_SLOTS=3
expect 0 owner-b acquire --no-wait "$ipad"
expect 1 owner-b release "$phone"
[[ "$(state_of "$phone")" == Booted ]] || fail 'non-owner release shut the simulator down'
expect 0 owner-a release --all
[[ "$(state_of "$phone")" == Shutdown ]] || fail 'release --all left the simulator booted'
[[ "$(state_of "$ipad")" == Booted && "$(state_of "$other")" == Booted ]] || fail 'release --all touched another simulator'
expect 0 owner-c status
! grep -q "$phone" "$work/out" || fail 'release --all kept the lease'
lease_row "$ipad" 'iPad Pro 13-inch \(M5\)' owner-b || fail "release --all dropped another owner's lease"

# Nobody leased it (hand-booted?): release refuses unless forced.
expect 1 owner-c release "$other"
[[ "$(state_of "$other")" == Booted ]] || fail 'release shut down an unleased simulator'
expect 0 owner-c release --force "$other"
[[ "$(state_of "$other")" == Shutdown ]] || fail 'release --force kept an unleased simulator'

# All or nothing: a free simulator is not leased alongside one held by
# someone else, nor when there is room for only one of the two.
reset atomic
WAYCAR_SIM_SLOTS=3
expect 0 owner-a acquire --no-wait "$phone"
expect 75 owner-b acquire --no-wait "$ipad" "$phone"
[[ "$(state_of "$ipad")" == Shutdown ]] || fail 'partial grant booted the free simulator'
WAYCAR_SIM_SLOTS=2
expect 75 owner-b acquire --no-wait "$ipad" "$max"
[[ "$(state_of "$ipad")" == Shutdown && "$(state_of "$max")" == Shutdown ]] || fail 'grant went past the cap'
expect 0 owner-c status
! grep -qE "$ipad|$max" "$work/out" || fail 'a refused request left a lease'

# Queue order: an earlier ticket that needs capacity keeps its room and its
# simulator, so a later caller is refused once both don't fit (or it wants
# that simulator), and served while both fit; one waiting on another owner's
# simulator blocks nobody. Dead and silent tickets are dropped.
reset order
put_state Booted "$phone"
true & dead=$!
wait "$dead"
seed "{'leases': {'$phone': lease($a, 0)}, 'tickets': [ticket($sleeper, $b, ['$max'])]}"
expect 75 owner-c acquire --no-wait "$ipad"
grep -q '1 earlier request' "$work/err" || fail 'queue refusal reason missing'
WAYCAR_SIM_SLOTS=3
expect 75 owner-c acquire --no-wait "$max"
grep -q 'wanted by an earlier request' "$work/err" || fail 'a later caller took the simulator an earlier ticket waits for'
expect 0 owner-c acquire --no-wait "$ipad"
[[ "$(state_of "$ipad")" == Booted && "$(state_of "$max")" == Shutdown ]] || fail 'room for both did not serve the later caller'
WAYCAR_SIM_SLOTS=2
put_state Shutdown "$ipad"
seed "{'leases': {'$phone': lease($a, 0)}, 'tickets': [ticket($sleeper, $b, ['$max', '$phone'])]}"
expect 0 owner-c acquire --no-wait "$ipad"
[[ "$(state_of "$ipad")" == Booted ]] || fail 'a conflict-blocked ticket held back free capacity'
seed "{'tickets': [ticket($dead, $b, ['$max']), ticket($sleeper, $b, ['$max'], 400), ticket($sleeper, $c, ['$max'])]}"
expect 0 owner-a status
grep -q '^Queue: 1 waiting' "$work/out" || fail 'dead or silent tickets were kept'
grep -q '^  1\. owner-c wants iPhone 17 Pro Max' "$work/out" || fail 'status does not list the queue'

# A lease on a simulator that never booted survives the boot grace, or its
# booter.
seed "{'leases': {'$max': lease($a, 400), '$spare': lease($a, 10), '$other': booting(lease($a, 400), $sleeper)}}"
expect 0 owner-a status
! grep -q "$max" "$work/out" || fail 'lease on a never-booted simulator outlived the grace'
lease_row "$spare" Spare owner-a || fail 'lease dropped inside the boot grace'
lease_row "$other" Legacy owner-a || fail 'lease dropped while its acquire was still booting it'

# Blocking waiters are served FIFO once capacity frees up; here a worktree is
# deleted while someone polls `status`, which must not stop the waiters'
# reclaim pass.
reset fifo
expect 0 owner-a acquire --no-wait "$phone"
expect 0 owner-d acquire --no-wait "$ipad"
start_waiter owner-b "$max"
waiter_b=$!
wait_queued 1 owner-b
start_waiter owner-c "$other"
waiter_c=$!
wait_queued 2 owner-c
expect 75 owner-d acquire --no-wait "$spare"
grep -q '2 earlier request' "$work/err" || fail 'third caller did not queue behind both waiters'
rm -rf "$work/owner-a"
attempt=0
while [[ ! -s "$work/owner-b.out" ]] && ((attempt < 45)); do
    slot owner-d status > /dev/null
    sleep 1
    attempt=$((attempt + 1))
done
status=0
kill -0 "$waiter_b" 2>/dev/null || wait "$waiter_b" || status=$?
[[ "$status" == 0 && "$(cat "$work/owner-b.out")" == "$max" ]] || { cat "$work/owner-b.err" >&2; fail 'first waiter not granted'; }
[[ "$(state_of "$phone")" == Shutdown && "$(state_of "$other")" == Shutdown ]] || fail 'wrong waiter granted'
expect 0 owner-d status
grep -q '^  1\. owner-c wants' "$work/out" || fail 'second waiter left the queue'

# A blocking caller that times out exits 1.
expect 1 owner-d acquire --timeout 0.01 "$spare"
kill "$waiter_c"
wait "$waiter_c" || true

# Deleting a worktree reclaims its simulator, unless a process still uses it.
# A worktree that can't be read (TCC, unmounted) is not deleted, and
# read-only status never shuts anything down.
reset deleted
put_state Booted "$phone" "$ipad" "$max"
mkdir -p "$work/sealed/owner-x"
seed "{'leases': {'$phone': lease($a, 0), '$ipad': lease($b, 0), '$max': lease('$work/sealed/owner-x', 0)}}"
rm -rf "$work/owner-a" "$work/owner-b"
chmod 000 "$work/sealed"
ps_row 424246 1 1-02:03:04 1:23.45 0,0 "xcodebuild test -destination platform=iOS Simulator,id=$ipad"
expect 0 owner-c status
[[ "$(state_of "$phone")" == Booted ]] || fail 'status shut a simulator down'
expect 0 owner-c release --all
chmod 755 "$work/sealed"
[[ "$(state_of "$phone")" == Shutdown ]] || fail 'deleted owner left its simulator booted'
[[ "$(state_of "$ipad")" == Booted ]] || fail 'deleted owner reclaim shut down a simulator in use'
[[ "$(state_of "$max")" == Booted ]] || fail 'an unreadable worktree counted as deleted'
expect 0 owner-c status
! grep -q "$phone" "$work/out" || fail 'deleted owner kept its lease'
lease_row "$ipad" 'iPad Pro 13-inch \(M5\)' unleased || fail 'deleted owner kept a lease on a simulator in use'
lease_row "$max" 'iPhone 17 Pro Max' owner-x || fail 'an unreadable worktree lost its lease'

# Idle reclaim needs a refused waiter: a blocking acquire granted at once is
# nobody waiting.
reset idle
put_state Booted "$phone" "$ipad" "$max" "$other" "$spare"
seed "{'leases': {'$ipad': lease($b, 900)}, 'idle': {'$ipad': ago(900), '$spare': ago(900)}}"
expect 0 owner-c acquire "$max"
[[ "$(state_of "$ipad")" == Booted && "$(state_of "$spare")" == Booted ]] || fail 'a caller granted at once reclaimed'

# While someone waits (default 10 min): counted from the later of the first
# idle observation and the lease renewal, restarted after a sampling gap. An
# unleased simulator a waiter can take right now is kept for it.
waiting="{'leases': {'$phone': lease($a, 900), '$ipad': lease($b, 900), '$max': lease($a, 60)},
          'idle': {'$phone': ago(300), '$ipad': ago(700), '$max': ago(900), '$other': ago(900), '$spare': ago(900)},
          'tickets': [ticket($sleeper, $c, ['$other'])]"
seed "$waiting, 'sampled_at': ago(100)}"
expect 0 owner-c release --all
[[ "$(state_of "$ipad")" == Booted && "$(state_of "$spare")" == Booted ]] || fail 'idle clocks survived a sampling gap'
seed "$waiting}"
expect 0 owner-c release --all
for udid in "$phone" "$max" "$other"; do
    [[ "$(state_of "$udid")" == Booted ]] || fail "$udid reclaimed before it was idle for 10 min"
done
[[ "$(state_of "$ipad")" == Shutdown ]] || fail 'leased simulator idle for over 10 min kept'
[[ "$(state_of "$spare")" == Shutdown ]] || fail 'unleased simulator idle for over 10 min kept'

# A simulator its acquire is still booting is left alone.
seed "{'leases': {'$phone': booting(lease($a, 900), $sleeper)}, 'idle': {'$phone': ago(900)},
       'tickets': [ticket($sleeper, $c, ['$ipad'])]}"
expect 0 owner-c release --all
[[ "$(state_of "$phone")" == Booted ]] || fail 'idle reclaim shut down a simulator still booting'

# A wanted unleased simulator is not kept for a ticket queued behind one that
# needs that room first.
put_state Shutdown "$phone" "$max"
seed "{'idle': {'$other': ago(900)},
       'tickets': [ticket($sleeper, $a, ['$phone', '$ipad'], 20), ticket($sleeper, $b, ['$other', '$max'], 10)]}"
expect 0 owner-c release --all
[[ "$(state_of "$other")" == Shutdown ]] || fail 'a simulator was kept for a ticket that cannot take it yet'

# Activity: the waiter's own make parent and processes inside the simulator
# don't count; another process naming an unleased simulator (`name=`, longest
# name wins) does. Queued runs pin `id=`, so `name=` never keeps a lease.
reset activity
put_state Booted "$phone" "$ipad" "$max" "$other"
seed "{'leases': {'$max': lease($a, 900), '$other': lease($a, 900)},
       'idle': {'$phone': ago(900), '$ipad': ago(900), '$max': ago(900), '$other': ago(900)},
       'tickets': [ticket($sleeper, $b, ['$other'])]}"
ps_row "$sleeper" 424242 01:00 0:00.10 0.0 "python3 scripts/sim-slot.py acquire $other"
ps_row 424242 1 01:00 0:00.01 0.0 "/usr/bin/make sim-id SIMULATOR_UDID=$other"
ps_row 424243 1 01:00 0:00.20 0.0 "/Library/Developer/CoreSimulator/Devices/$other/data/usr/libexec/backboardd"
ps_row 424244 1 01:00 0:02.00 3.0 "xcodebuild build-for-testing -destination platform=iOS Simulator,name=iPhone 17 Pro Max"
ps_row 424245 1 01:00 0:02.00 3.0 "xcodebuild test -destination platform=iOS Simulator,name=iPad Pro 13-inch (M5) -quiet"
expect 0 owner-c release --all
[[ "$(state_of "$other")" == Shutdown ]] || fail "the waiter's own processes kept the simulator busy"
[[ "$(state_of "$ipad")" == Booted ]] || fail 'a name= reference did not keep an unleased simulator'
[[ "$(state_of "$phone")" == Shutdown ]] || fail 'a longer name= matched a shorter simulator name'
[[ "$(state_of "$max")" == Shutdown ]] || fail 'a name= reference kept a leased simulator'

# A live CI claim (pid plus matching start time) is never leased or shut
# down; a claim whose pid was reused is stale.
reset ci
put_state Booted "$phone"
mkdir -p "$WAYCAR_SIM_SLOTS_CI_LOCK_ROOT/device-$phone"
printf '%s' "$sleeper" > "$WAYCAR_SIM_SLOTS_CI_LOCK_ROOT/device-$phone/pid"
/bin/ps -o lstart= -p "$sleeper" > "$WAYCAR_SIM_SLOTS_CI_LOCK_ROOT/device-$phone/start"
expect 75 owner-a acquire --no-wait "$phone"
grep -q 'CI' "$work/err" || fail 'CI refusal reason missing'
expect 1 owner-a release "$phone"
[[ "$(state_of "$phone")" == Booted ]] || fail 'release shut down a CI-claimed simulator'
echo 'Thu Jan  1 00:00:00 1970' > "$WAYCAR_SIM_SLOTS_CI_LOCK_ROOT/device-$phone/start"
expect 0 owner-a acquire --no-wait "$phone"

# A failed or interrupted boot gives back only what that call leased: the new
# simulator is shut down, a renewed lease stays.
reset boot
expect 0 owner-a acquire --no-wait "$phone"
touch "$FAKE_FLAGS/fail-$ipad"
expect 1 owner-a acquire --no-wait "$ipad" "$phone"
[[ "$(state_of "$ipad")" == Shutdown ]] || fail 'failed boot left the simulator running'
expect 0 owner-a status
! grep -q "$ipad" "$work/out" || fail 'failed boot kept its lease'
lease_row "$phone" 'iPhone 17' owner-a || fail 'failed boot dropped a renewed lease'
rm "$FAKE_FLAGS/fail-$ipad"
echo 30 > "$FAKE_FLAGS/slow-$ipad"
(cd "$work/owner-a" && exec "$repo_root/scripts/sim-slot.py" acquire --no-wait "$ipad" "$phone") \
    > /dev/null 2> "$work/booter.err" &
booter=$!
background+=("$booter")
for ((attempt = 0; attempt < 300; attempt += 1)); do
    grep -q booting "$work/booter.err" && break
    sleep 0.2
done
sleep 1
kill -TERM "$booter"
status=0
wait "$booter" || status=$?
[[ "$status" == 143 && "$(state_of "$ipad")" == Shutdown ]] || fail 'interrupted boot left the new simulator'
expect 0 owner-a status
! grep -q "$ipad" "$work/out" || fail 'interrupted boot kept its new lease'
lease_row "$phone" 'iPhone 17' owner-a || fail 'interrupted boot dropped a renewed lease'

# A lease lost while booting (its worktree was deleted) fails the acquire.
reset lost
echo 8 > "$FAKE_FLAGS/slow-$phone"
ps_row 424247 1 01:00 0:01.00 1.0 "xcodebuild test -destination platform=iOS Simulator,id=$phone"
(cd "$work/owner-d" && exec "$repo_root/scripts/sim-slot.py" acquire --no-wait "$phone") \
    > "$work/booter.out" 2> "$work/booter.err" &
booter=$!
background+=("$booter")
for ((attempt = 0; attempt < 300; attempt += 1)); do
    grep -q booting "$work/booter.err" && break
    sleep 0.2
done
rm -rf "$work/owner-d"
expect 0 owner-c release --all
status=0
wait "$booter" || status=$?
[[ "$status" == 1 && ! -s "$work/booter.out" ]] || fail 'acquire succeeded without its lease'

# Pools: a base model name or a `name=` destination gets any free simulator of
# that model (`<name>` or `<name> <N>` of the same device type and runtime,
# the named one first); Waycar CI shares the type but never joins. A second
# acquire by name renews the copy the owner holds, and a UDID stays pinned.
reset pool
add_pool
WAYCAR_SIM_SLOTS=4
expect 0 owner-a acquire --no-wait 'iPhone 17 Pro Max'
[[ "$(cat "$work/out")" == "$max" ]] || fail 'a pool did not grant the named simulator first'
expect 0 owner-a acquire --no-wait 'iPhone 17 Pro Max'
[[ "$(cat "$work/out")" == "$max" ]] || fail 'acquiring by name again did not renew the copy the owner holds'
expect 75 owner-b acquire --no-wait "$max"
grep -q 'leased by owner-a' "$work/err" || fail 'a UDID request was not refused its held simulator'
[[ "$(state_of "$max2")" == Shutdown ]] || fail 'a UDID request took another copy'
expect 0 owner-d acquire --no-wait 'platform=iOS Simulator,name=iPhone 17 Pro Max'
[[ "$(cat "$work/out")" == "$max2" ]] || fail 'a destination did not get the free copy'

# Two waiters for one model each get a copy once both copies free up.
start_waiter owner-b 'iPhone 17 Pro Max'
wait_queued 1 owner-b
start_waiter owner-c 'iPhone 17 Pro Max'
wait_queued 2 owner-c
expect 0 owner-d status
grep -q '^  1\. owner-b wants any iPhone 17 Pro Max (2 in pool)' "$work/out" || fail 'status does not show a pool ticket'
expect 0 owner-a release --all
expect 0 owner-d release --all
wait_granted owner-b
wait_granted owner-c
[[ "$(sort "$work/owner-b.out" "$work/owner-c.out" | tr '\n' ' ')" == "$(printf '%s\n' "$max" "$max2" | sort | tr '\n' ' ')" ]] \
    || fail 'two waiters for one model did not get one copy each'
[[ "$(state_of "$ci")" == Shutdown ]] || fail 'Waycar CI joined the pool'

# A pool leaves a copy that a queued ticket pins (an old copy of this script
# can wait for nothing else) to that ticket.
reset pinned
add_pool
WAYCAR_SIM_SLOTS=4
put_state Booted "$phone"
seed "{'leases': {'$phone': lease($c, 0)}, 'tickets': [ticket($sleeper, $b, ['$max', '$phone'])]}"
expect 0 owner-a acquire --no-wait 'iPhone 17 Pro Max'
[[ "$(cat "$work/out")" == "$max2" ]] || fail 'a pool took the copy a queued ticket pins'

# A joint request takes one of each model atomically, printed in request
# order; with every iPhone held it leases nothing, and the cap still holds.
reset joint
add_pool
WAYCAR_SIM_SLOTS=4
expect 0 owner-a acquire --no-wait "$max2"
expect 0 owner-b acquire --no-wait 'iPhone 17 Pro Max' 'iPad Pro 13-inch (M5)'
[[ "$(cat "$work/out")" == "$max"$'\n'"$ipad" ]] || fail 'a joint request did not get one of each in order'
expect 75 owner-c acquire --no-wait 'iPhone 17 Pro Max' 'iPad Pro 13-inch (M5)'
grep -q 'all 2 iPhone 17 Pro Max simulators are taken' "$work/err" || fail 'joint refusal reason missing'
[[ "$(state_of "$ipad2")" == Shutdown && "$(state_of "$ci")" == Shutdown ]] || fail 'a refused joint request booted a simulator'
expect 0 owner-d status
! grep -q "$ipad2" "$work/out" || fail 'a refused joint request left a lease'
expect 0 owner-a release --all
WAYCAR_SIM_SLOTS=3
expect 75 owner-c acquire --no-wait 'iPhone 17 Pro Max' 'iPad Pro 13-inch (M5)'
grep -q '2/3 slots in use' "$work/err" || fail 'a joint request went past the cap'
WAYCAR_SIM_SLOTS=2
expect 75 owner-c acquire --no-wait 'iPhone 17 Pro Max'
grep -q '2/2 slots in use' "$work/err" || fail 'a free copy went past the cap'
[[ "$(state_of "$max2")" == Shutdown && "$(state_of "$ipad2")" == Shutdown ]] || fail 'the cap let a copy boot'

# Copies go in number order (2, 3, then 10, never an unavailable one); a
# booted copy goes first (no added load), one that failed to boot lately last.
reset pool-order
add_pool
printf 'iPhone 17 Pro Max 3|Shutdown|%s\n' "$max_type" > "$FAKE_SIM_DIR/$max3"
printf 'iPhone 17 Pro Max 4|Shutdown|%s|unavailable\n' "$max_type" > "$FAKE_SIM_DIR/$max4"
printf 'iPhone 17 Pro Max 10|Shutdown|%s\n' "$max_type" > "$FAKE_SIM_DIR/$max10"
WAYCAR_SIM_SLOTS=6
put_state Booted "$max3"
expect 0 owner-a acquire --no-wait 'iPhone 17 Pro Max'
[[ "$(cat "$work/out")" == "$max3" ]] || fail 'a pool did not prefer the booted copy'
expect 0 owner-a release --all
granted=''
for owner in owner-a owner-b owner-c owner-d; do
    expect 0 "$owner" acquire --no-wait 'iPhone 17 Pro Max'
    granted="$granted $(cat "$work/out")"
done
[[ "$granted" == " $max $max2 $max3 $max10" ]] || fail "a pool granted$granted, not in number order"
for owner in owner-a owner-b owner-c owner-d; do
    expect 0 "$owner" release --all
done
seed "{'boot_failures': {'$max': ago(60)}}"
expect 0 owner-a acquire --no-wait 'iPhone 17 Pro Max'
[[ "$(cat "$work/out")" == "$max2" ]] || fail 'a pool did not pick the copy that failed to boot last'

# Overlapping pools in one request never share a simulator: the request waits
# rather than get fewer than it asked for. The same target twice, or a UDID
# plus the name of that lone simulator, is one simulator.
reset overlap
add_pool
printf 'iPhone 17 Pro Max 3|Shutdown|%s\n' "$max_type" > "$FAKE_SIM_DIR/$max3"
WAYCAR_SIM_SLOTS=6
expect 0 owner-c acquire --no-wait "$max"
expect 0 owner-d acquire --no-wait "$max3"
expect 75 owner-a acquire --no-wait 'iPhone 17 Pro Max' 'iPhone 17 Pro Max 2'
grep -q "iPhone 17 Pro Max 2 $max2 is granted for another target" "$work/err" || fail 'overlapping pools shared a simulator'
expect 75 owner-a acquire --no-wait "$max2" 'iPhone 17 Pro Max'
[[ "$(state_of "$max2")" == Shutdown ]] || fail 'a refused overlapping request booted a simulator'
expect 0 owner-d release --all
expect 0 owner-a acquire --no-wait 'iPhone 17 Pro Max' 'iPhone 17 Pro Max 2'
[[ "$(cat "$work/out")" == "$max3"$'\n'"$max2" ]] || fail 'overlapping pools did not get one simulator per target in order'
expect 0 owner-a acquire --no-wait 'iPhone 17 Pro Max' 'iPhone 17 Pro Max'
[[ "$(cat "$work/out")" == "$max2" ]] || fail 'the same target twice was not one simulator'
expect 0 owner-b acquire --no-wait "$phone" 'iPhone 17'
[[ "$(cat "$work/out")" == "$phone" ]] || fail 'a UDID plus the name of that lone simulator was not one simulator'

# make screenshots acquires both models by name, so any free copy serves it
# (here the originals failed to boot lately). It runs from a copy of the
# scripts so the screenshot paths stay in $work; it stops at the fake's
# missing `simctl ui`.
reset screenshots
add_pool
WAYCAR_SIM_SLOTS=4
seed "{'boot_failures': {'$max': ago(60), '$ipad': ago(60)}}"
mkdir -p "$work/repo/scripts"
for file in capture-screenshots.sh sim-slot.py sim_slot_probe.py run-app-simulator-tests.py check-crash-reports.py; do
    cp "$repo_root/scripts/$file" "$work/repo/scripts/$file"
done
# The capture checks for the hero's tools first; this run stops long before
# it uses them, so stand-ins keep the test off the host's Homebrew.
for tool in ffmpeg ffprobe img2webp; do
    printf '#!/bin/sh\nexit 0\n' > "$work/bin/$tool"
    chmod +x "$work/bin/$tool"
done
(cd "$work/owner-a" && "$work/repo/scripts/capture-screenshots.sh" 'iPhone 17 Pro Max' 'iPad Pro 13-inch (M5)') \
    > /dev/null 2> "$work/err" || true
grep -qx "boot $max2" "$FAKE_FLAGS/calls" && grep -qx "boot $ipad2" "$FAKE_FLAGS/calls" \
    || { cat "$work/err" >&2; fail 'make screenshots did not take a free copy of each model'; }

# ensure-pool creates `<name> <N>` copies of the same type up to the size,
# once; it refuses UDIDs and Waycar simulators.
reset ensure
add_pool
rm "$FAKE_SIM_DIR/$max2" "$FAKE_SIM_DIR/$ipad2"
expect 0 owner-a ensure-pool 'iPhone 17 Pro Max' 'iPad Pro 13-inch (M5)'
grep -qxF "iPhone 17 Pro Max 2|Shutdown|$max_type" "$FAKE_SIM_DIR"/* || fail 'ensure-pool did not create the iPhone copy'
grep -qxF "iPad Pro 13-inch (M5) 2|Shutdown|$ipad_type" "$FAKE_SIM_DIR"/* || fail 'ensure-pool did not create the iPad copy'
expect 0 owner-a ensure-pool --size 3 'iPhone 17 Pro Max' 'iPad Pro 13-inch (M5)'
expect 0 owner-a ensure-pool --size 3 'iPhone 17 Pro Max' 'iPad Pro 13-inch (M5)'
[[ "$(grep -c '^create ' "$FAKE_FLAGS/calls")" == 4 ]] || fail 'ensure-pool created more than the missing copies'
grep -qxF "iPhone 17 Pro Max 3|Shutdown|$max_type" "$FAKE_SIM_DIR"/* || fail 'ensure-pool misnumbered a copy'
expect 2 owner-a ensure-pool "$max"
expect 2 owner-a ensure-pool 'Waycar CI'

# State compatibility with the copies of this script already running in other
# worktrees (before pools): each honours the leases and tickets the other
# writes, and the old copy keeps the keys it doesn't know.
old_rev=af358cff1bdc7d38e8fe9f1d750f2bc33bbfcbcc
old="$work/old/scripts"
if git -C "$repo_root" cat-file -e "$old_rev:scripts/sim-slot.py" 2>/dev/null; then
    mkdir -p "$old"
    for file in sim-slot.py sim_slot_probe.py run-app-simulator-tests.py; do
        git -C "$repo_root" show "$old_rev:scripts/$file" > "$old/$file"
    done
    chmod +x "$old/sim-slot.py"
    reset compat
    add_pool
    WAYCAR_SIM_SLOTS=4
    expect 0 owner-a acquire --no-wait 'iPhone 17 Pro Max'
    expect 0 owner-d acquire --no-wait 'iPhone 17 Pro Max'
    start_waiter owner-b 'iPhone 17 Pro Max'
    wait_queued 1 owner-b
    SIM_SLOT="$old/sim-slot.py" start_waiter owner-c "$max"
    wait_queued 2 owner-c
    SIM_SLOT="$old/sim-slot.py" expect 0 owner-d status
    lease_row "$max" 'iPhone 17 Pro Max' owner-a || fail 'the old copy does not see a pool lease'
    grep -q '^  1\. owner-b wants iPhone 17 Pro Max' "$work/out" || fail 'the old copy does not see a pool ticket'
    SIM_SLOT="$old/sim-slot.py" expect 75 owner-d acquire --no-wait "$max"
    grep -q 'leased by owner-a' "$work/err" || fail 'the old copy ignored a pool lease'
    # The old waiter wrote the state back after owner-b queued, and a new copy
    # writes `wants` only when it creates its ticket.
    python3 - "$WAYCAR_SIM_SLOTS_DIR/state.json" <<'PY' || fail 'the old copy dropped the pool ticket'
import json, sys
state = json.load(open(sys.argv[1]))
assert state["tickets"][0]["wants"][0]["name"] == "iPhone 17 Pro Max", state["tickets"]
assert "wants" not in state["tickets"][1], state["tickets"]
PY
    expect 0 owner-d status
    grep -q "^  2\. owner-c wants iPhone 17 Pro Max ($max)" "$work/out" || fail 'an old ticket is not shown pinned'
    expect 0 owner-d release --all
    wait_granted owner-b
    [[ "$(cat "$work/owner-b.out")" == "$max2" ]] || fail 'the pool waiter did not get the free copy'
    expect 0 owner-a release --all
    wait_granted owner-c
    [[ "$(cat "$work/owner-c.out")" == "$max" ]] || fail 'the old waiter did not get its simulator'
else
    echo "skipping old-copy compatibility: $old_rev is not in this clone" >&2
fi

# Doctor: a simctl diagnose (any Xcode path; run directly, through xcrun, or
# under a shell) tied to a leased simulator is killed once it and its
# children have used no CPU for 3 min while its test run idles; only it dies,
# never the xcodebuild that started it or a wrapper shell.
reset doctor
put_state Booted "$max"
live
xcodebuild=$live_pid
live
shell=$live_pid
live
diagnose=$live_pid
ps_row "$xcodebuild" 1 20:00 0:30.00 0,0 \
    "/Applications/Xcode 26.app/Contents/Developer/usr/bin/xcodebuild test -destination platform=iOS Simulator,id=$max"
ps_row "$shell" "$xcodebuild" 05:00 0:00.01 0,0 "/bin/sh -c /usr/bin/xcrun simctl diagnose -l -b --timeout=600"
ps_row "$diagnose" "$shell" 05:00 0:00.40 0,0 \
    "/Applications/Xcode 26.app/Contents/Developer/usr/bin/simctl diagnose -l -b --timeout=600"
ps_row 424252 "$diagnose" 04:00 0:01.00 0,0 "/usr/bin/log collect --output /tmp/diagnose"
# Both have been quiet for 4 min; only the innermost is the diagnose.
seed "{'leases': {'$max': lease($a, 60)}, 'diagnoses': {'$diagnose': [ago(240), 1.4], '$shell': [ago(240), 1.41]}}"
expect 0 owner-c doctor
if kill -0 "$diagnose" 2>/dev/null; then fail 'a hung diagnose survived the doctor'; fi
kill -0 "$xcodebuild" && kill -0 "$shell" || fail 'the doctor killed more than the diagnose'
grep -qF "killed simctl diagnose pid $diagnose (5m old, on iPhone 17 Pro Max $max (owner-a)): it used no CPU for 4m" \
    "$work/out" || fail 'the diagnose kill was not reported with its owner'
[[ "$(state_of "$max")" == Booted ]] || fail 'the doctor shut down a leased simulator'

# The kill re-checks the process right before each signal: a pid that now
# runs something else, or a process started after the decision (a reused
# pid), is never signalled.
live
python3 - "$repo_root/scripts" "$live_pid" <<'PY' || fail 'the doctor signalled a reused pid'
import importlib.util, sys, time
sys.path.insert(0, sys.argv[1])
from sim_slot_probe import Process
spec = importlib.util.spec_from_file_location("sim_slot", sys.argv[1] + "/sim-slot.py")
slot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(slot)
pid, decided = int(sys.argv[2]), time.time() - 60
for args, elapsed in (("SLEEP 600", 600), ("XCRUN SIMCTL DIAGNOSE -L", 5)):
    slot.processes = lambda: {pid: Process(1, elapsed, 0.0, 0.0, args)}
    assert slot.stop(pid, decided) and slot.pid_alive(pid), args
slot.processes = lambda: {pid: Process(1, 600, 0.0, 0.0, "XCRUN SIMCTL DIAGNOSE -L")}
assert slot.stop(pid, decided) and not slot.pid_alive(pid)
PY

# One whose test still uses CPU, one that used CPU since its last look, and
# one no lease ties to are left alone.
live
diagnose=$live_pid
: > "$FAKE_PS_FILE"
ps_row 424250 1 20:00 0:30.00 0.5 "xcodebuild test -project Waycar.xcodeproj -destination platform=iOS Simulator,id=$max"
ps_row "$diagnose" 424250 1-02:03:04 0:00.40 0.0 "xcrun simctl diagnose -l -b --timeout=600"
ps_row 424251 1 20:00 1:00.00 40.0 \
    "/Users/x/Library/Developer/CoreSimulator/Devices/$max/data/Containers/Bundle/Application/A/Waycar.app/Waycar"
edit_state "state['diagnoses'] = {'$diagnose': [ago(600), 0.4]}"
expect 0 owner-c doctor
kill -0 "$diagnose" || fail 'the doctor killed a diagnose while its test used CPU'
grep -q 'left alone, its test run is using CPU' "$work/out" || fail 'an active test was not reported'
: > "$FAKE_PS_FILE"
ps_row 424250 1 20:00 0:30.00 0.0 "xcodebuild test -project Waycar.xcodeproj -destination platform=iOS Simulator,id=$max"
ps_row "$diagnose" 424250 1-02:03:04 0:05.00 0.0 "xcrun simctl diagnose -l -b --timeout=600"
expect 0 owner-c doctor
kill -0 "$diagnose" || fail 'the doctor killed a diagnose that used CPU lately'
grep -q "pid $diagnose .*left alone, it has used no CPU for only [0-9]*s;" "$work/out" || fail 'a busy diagnose was not reported'
: > "$FAKE_PS_FILE"
ps_row "$diagnose" 1 1-02:03:04 0:05.00 0.0 "xcrun simctl diagnose -l -b --timeout=600"
edit_state "state['diagnoses'] = {'$diagnose': [ago(600), 5.0]}"
expect 0 owner-c doctor
kill -0 "$diagnose" || fail 'the doctor killed a diagnose no lease ties to'
grep -q "pid $diagnose .*left alone, it is not tied to a leased simulator" "$work/out" || fail 'an untied diagnose was not reported'
expect 0 owner-c status
lease_row "$max" 'iPhone 17 Pro Max' owner-a || fail 'the doctor dropped an active lease'

# A waiter refused for 5 min runs the doctor itself and logs what it did; a
# second one waits out the 5 min since that run, machine-wide.
reset auto-doctor
put_state Booted "$max"
live
diagnose=$live_pid
ps_row 424250 1 20:00 0:30.00 0.0 "xcodebuild test -project Waycar.xcodeproj -destination platform=iOS Simulator,id=$max"
ps_row "$diagnose" 424250 10:00 0:00.40 0.0 "xcrun simctl diagnose -l -b --timeout=600"
seed "{'leases': {'$max': lease($a, 60)}, 'doctor_at': ago(400), 'diagnoses': {'$diagnose': [ago(400), 0.4]}}"
start_waiter owner-b "$max"
wait_queued 1 owner-b
edit_state "mine('owner-b')['blocked_at'] = ago(400)"
for ((attempt = 0; attempt < 60; attempt += 1)); do
    grep -q "doctor: killed simctl diagnose pid $diagnose" "$work/owner-b.err" && break
    sleep 1
done
grep -q "doctor: killed simctl diagnose pid $diagnose" "$work/owner-b.err" \
    || { cat "$work/owner-b.err" >&2; fail 'a waiter refused for 5 min did not run the doctor'; }
if kill -0 "$diagnose" 2>/dev/null; then fail "the waiter's doctor left the hung diagnose"; fi
live
diagnose=$live_pid
: > "$FAKE_PS_FILE"
ps_row 424250 1 20:00 0:30.00 0.0 "xcodebuild test -project Waycar.xcodeproj -destination platform=iOS Simulator,id=$max"
ps_row "$diagnose" 424250 10:00 0:00.40 0.0 "xcrun simctl diagnose -l -b --timeout=600"
start_waiter owner-c "$max"
wait_queued 2 owner-c
doctor_at() {
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["doctor_at"])' "$WAYCAR_SIM_SLOTS_DIR/state.json"
}
ran_at=$(doctor_at)
edit_state "mine('owner-c')['blocked_at'] = ago(400); state['diagnoses']['$diagnose'] = [ago(400), 0.4]"
wait_polled owner-c
[[ "$(doctor_at)" == "$ran_at" ]] && kill -0 "$diagnose" && ! grep -q 'doctor:' "$work/owner-c.err" \
    || fail 'a second waiter ran the doctor within 5 min of the last run'
kill "$(cat "$work/owner-b.pid")" "$(cat "$work/owner-c.pid")"
wait "$(cat "$work/owner-b.pid")" "$(cat "$work/owner-c.pid")" || true

# Doctor reuses the reclaim pass: a deleted worktree's lease, and one idle
# for 10 min while someone waits, are freed and reported with their owners.
reset doctor-reclaim
put_state Booted "$phone" "$spare"
seed "{'leases': {'$phone': lease($a, 0), '$spare': lease($b, 900)}, 'idle': {'$spare': ago(900)},
       'tickets': [ticket($sleeper, $c, ['$other'])]}"
rm -rf "$work/owner-a"
expect 0 owner-d doctor
[[ "$(state_of "$phone")" == Shutdown && "$(state_of "$spare")" == Shutdown ]] || fail 'the doctor did not reclaim'
grep -q "freed iPhone 17 $phone from owner-a (its worktree is gone)" "$work/out" || fail 'dead-owner reclaim not reported'
grep -q "freed Spare $spare from owner-b" "$work/out" || fail 'idle reclaim not reported'

# Doctor restarts an unleased simulator stuck booting, or one whose probe
# failed on doctor runs 2 to 15 min apart (one slow answer on a loaded Mac is
# not enough), so the next grant boots it fresh; a leased one, a healthy one,
# one an app runs in (Xcode or hands-on use), and Waycar CI are left alone.
reset doctor-health
add_pool
WAYCAR_SIM_SLOTS=6
put_state Booted "$spare" "$other" "$max" "$ci" "$phone"
put_state Booting "$max2"
touch "$FAKE_FLAGS/broken-$spare" "$FAKE_FLAGS/broken-$other" "$FAKE_FLAGS/broken-$ci" "$FAKE_FLAGS/broken-$phone"
ps_row 424260 1 05:00 0:03.00 0.0 \
    "/Users/x/Library/Developer/CoreSimulator/Devices/$phone/data/Containers/Bundle/Application/B/Waycar.app/Waycar"
seed "{'leases': {'$other': lease($a, 0)}, 'booting_since': {'$max2': ago(1000)},
       'snapshot': {'at': now, 'devices': {}, 'active': [], 'ci': []}}"
expect 0 owner-c doctor
[[ "$(state_of "$max2")" == Shutdown ]] || fail 'a simulator stuck booting was kept'
grep -q "shut down unleased iPhone 17 Pro Max 2 $max2 (stuck booting" "$work/out" || fail 'the stuck boot was not reported'
[[ "$(state_of "$spare")" == Booted ]] || fail 'one failed probe restarted a simulator'
grep -q "Spare $spare does not answer; if it still does not on a doctor run in 2m" "$work/out" \
    || fail 'the first failed probe was not reported'
edit_state "state['unanswered']['$spare'] = ago(1000)"
expect 0 owner-c doctor
[[ "$(state_of "$spare")" == Booted ]] || fail 'probes failed too far apart restarted a simulator'
edit_state "state['unanswered'].update({'$spare': ago(200), '$phone': ago(200)})"
expect 0 owner-c doctor
[[ "$(state_of "$spare")" == Shutdown ]] || fail 'an unleased simulator that failed two probes was kept'
grep -q "shut down unleased Spare $spare (launchctl inside it did not answer on doctor runs 3m apart)" "$work/out" \
    || fail 'the unhealthy restart was not reported'
[[ "$(state_of "$phone")" == Booted ]] || fail 'the doctor restarted a simulator an app runs in'
grep -q "iPhone 17 $phone does not answer, but an app runs in it" "$work/out" || fail 'the app in use was not reported'
[[ "$(state_of "$other")" == Booted ]] || fail 'the doctor restarted a leased simulator'
[[ "$(state_of "$ci")" == Booted ]] || fail 'the doctor touched Waycar CI'
[[ "$(state_of "$max")" == Booted ]] || fail 'the doctor restarted a healthy simulator'
rm "$FAKE_FLAGS/broken-$spare"
expect 0 owner-b acquire --no-wait "$spare"
[[ "$(state_of "$spare")" == Booted ]] || fail 'the restarted simulator was not granted fresh'

# Bad configuration is a usage error.
WAYCAR_SIM_IDLE_MINUTES=0 expect 2 owner-a status

echo "sim-slot tests passed"
