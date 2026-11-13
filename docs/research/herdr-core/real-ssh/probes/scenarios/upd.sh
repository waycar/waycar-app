H=$HOME/.local/bin/herdr-core
cd ~/lab/probes
$H server status | python3 -c 'import sys,json; d=json.load(sys.stdin); print("before: core pid",d["pid"],"uptime_ms",d["uptime_ms"],"live",d["live"],"holder pid",(d["holder"] or {}).get("pid"))'
$H ls --json | python3 -c 'import sys,json; d=json.load(sys.stdin); print("before: terminals",[t["name"]+":"+t["status"] if "status" in t else t["name"] for t in d["terminals"]])'
PIDS_BEFORE=$(ps -eo pid,args | grep -E "[f]ake-agent|sleep 600" | awk '{print $1}' | sort | tr '\n' ' ')
python3 hc_attach_probe_ssh.py --ssh "ssh -T -o BatchMode=yes 127.0.0.1" --subscribe --do sleep:9 --drain 0.1 --width 100 > /tmp/out/upd-sub.log 2>&1 &
A=$(python3 - <<'PY'
PY
)
sleep 1
echo "=== official installer, 2nd+ run with a RUNNING core, ssh exec, no tty"
START=$(date +%s.%N)
ssh -T -o BatchMode=yes 127.0.0.1 'curl -fsSL https://releases.herdr.dev/core/install.sh | sh' >/tmp/out/upd.out 2>/tmp/out/upd.err; rc=$?
END=$(date +%s.%N)
echo "rc=$rc time=$(python3 -c "print(round($END-$START,3))")s"
echo "--stdout"; cat /tmp/out/upd.out; echo "--stderr"; cat /tmp/out/upd.err
$H server status | python3 -c 'import sys,json; d=json.load(sys.stdin); print("after: core pid",d["pid"],"uptime_ms",d["uptime_ms"],"live",d["live"],"holder pid",(d["holder"] or {}).get("pid"))'
PIDS_AFTER=$(ps -eo pid,args | grep -E "[f]ake-agent|sleep 600" | awk '{print $1}' | sort | tr '\n' ' ')
[ "$PIDS_BEFORE" = "$PIDS_AFTER" ] && echo "agent program pids unchanged: $PIDS_AFTER" || echo "agent pids CHANGED: $PIDS_BEFORE -> $PIDS_AFTER"
wait
echo "--- subscriber that was open during the update:"; grep -E "EOF|exit code" /tmp/out/upd-sub.log
sha256sum $H
ls -la ~/.local/bin
