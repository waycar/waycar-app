H=$HOME/.local/bin/herdr-core
S='ssh -T -o BatchMode=yes 127.0.0.1'
cd ~/lab/probes
CMD='sh -c '"'"'echo PATH=$PATH SHELL=$SHELL HOME=$HOME PWD=$PWD; env | grep -E "^(SSH_|XDG_|HC_|LANG|TERM|USER|LOGNAME|MAIL)" | sort'"'"
LINE_PLAIN="sh -c 'p=\$(command -v herdr-core) || p=\$HOME/.local/bin/herdr-core; [ -x \"\$p\" ] || { echo \"herdr-core is not installed here\" >&2; exit 127; }; exec \"\$p\" connect'"
stopfresh() { $H server stop >/dev/null 2>&1; sleep 1; rm -rf ~/.local/state/herdr-core; ps -eo pid,cmd | grep -E "herdr-core (serve|hold)" | grep -v grep || echo "(no core/holder processes)"; }
runterm() { python3 - <<PY
import json,subprocess,os
os.environ["LAB_REMOTE_LINE"]="""$LINE_PLAIN"""
import sys; sys.path.insert(0,".")
import hc_probe
c=hc_probe.Hc(prefix=["ssh","-T","-o","BatchMode=yes","127.0.0.1"],echo=False)
r=c.call("terminal.run",{"line":"""echo PATH=\$PATH SHELL=\$SHELL HOME=\$HOME PWD=\$PWD; env | grep -E '^(SSH_|XDG_|HC_|LANG|TERM|USER|LOGNAME|MAIL)' | sort""","wait":True})
print(r["output"]); c.close()
PY
}
echo "### login PATH probes"
echo -n 'ssh exec PATH     : '; $S 'printf %s "$PATH"'; echo
echo -n 'bash -lc          : '; $S 'bash -lc "printf %s \"\$PATH\""'; echo
echo -n '$SHELL -lc        : '; $S '$SHELL -lc "printf %s \"\$PATH\""'; echo
echo -n 'sh -lc            : '; $S 'sh -lc "printf %s \"\$PATH\""'; echo
echo -n 'bash -ilc         : '; $S 'bash -ilc "printf %s \"\$PATH\"" 2>/dev/null'; echo
echo "### A: core first started by ssh exec 'herdr-core server status' (ssh default PATH)"
stopfresh
$S "$H server status"; echo "exit=$?"
runterm
echo "### B: core first started by the connect line WITHOUT a PATH export (hc's own line)"
stopfresh
LOGINPATH=$($S 'bash -lc "printf %s \"\$PATH\""')
export LINE_PLAIN
LAB_REMOTE_LINE="$LINE_PLAIN" python3 hc_probe.py --ssh "$S" -q call hello >/dev/null
runterm
echo "### C: core first started by the design's connect line exporting the login PATH: $LOGINPATH"
stopfresh
LINE_C="sh -c 'PATH=$LOGINPATH; p=\$(command -v herdr-core) || p=\$HOME/.local/bin/herdr-core; [ -x \"\$p\" ] || { echo \"herdr-core is not installed here\" >&2; exit 127; }; exec \"\$p\" connect'"
LAB_REMOTE_LINE="$LINE_C" python3 hc_probe.py --ssh "$S" -q call hello >/dev/null
runterm
