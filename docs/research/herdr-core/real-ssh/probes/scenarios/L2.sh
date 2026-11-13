export LAB_REMOTE_LINE="sh -c 'PATH=/usr/local/bin:/usr/bin:/bin:\$HOME/.local/bin; p=\$(command -v herdr-core) || p=\$HOME/.local/bin/herdr-core; [ -x \"\$p\" ] || { echo \"herdr-core is not installed here\" >&2; exit 127; }; exec \"\$p\" connect'"
cd ~/lab/probes
S='ssh -T -o BatchMode=yes 127.0.0.1'
python3 hc_probe.py --ssh "$S" features
python3 hc_probe.py --ssh "$S" -q call terminal.list '{"labels":{"herdr.space":"sp1"}}' | python3 -c 'import sys,json; print(sys.stdin.read()[:300])'
python3 hc_probe.py --ssh "$S" -q call terminal.run '{"argv":["sh","-c","echo hi; exit 3"],"wait":true}' | cut -c1-400
