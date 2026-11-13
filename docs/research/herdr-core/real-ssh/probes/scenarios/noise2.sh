cd ~
. /tmp/noise_fn.sh
setnoise none
echo "=== (c) clean rc, login shell fed by stdin, full stdout (cat -A):"; printf 'echo X\n' | $S 2>&1 | cat -A | head -40
setnoise all
echo "=== (c) all noise:"; printf 'echo X\n' | $S 2>&1 | cat -A | head -40
echo "=== hc_probe over ssh with NOISE-BASHRC-TOP:"
cd ~/lab/probes
LAB_REMOTE_LINE="$LINE" python3 hc_probe.py --ssh "$S" call hello 2>&1 | cut -c1-200 | tail -8
echo "=== sentinel remedy: the line prints a marker line before exec"
LINE2="sh -c 'PATH=/usr/local/bin:/usr/bin:/bin:\$HOME/.local/bin; p=\$(command -v herdr-core) || p=\$HOME/.local/bin/herdr-core; [ -x \"\$p\" ] || { echo \"herdr-core is not installed here\" >&2; exit 127; }; printf \"@@WAYCAR-CORE@@\\n\"; exec \"\$p\" connect'"
(printf '%s\n' "$HELLO"; sleep 0.5) | $S "$LINE2" 2>&1 | head -c 100 | cat -A
cd ~; . /tmp/noise_fn.sh; setnoise none
