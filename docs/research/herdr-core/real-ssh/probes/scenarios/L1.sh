export LAB_REMOTE_LINE="sh -c 'PATH=/usr/local/bin:/usr/bin:/bin:\$HOME/.local/bin; p=\$(command -v herdr-core) || p=\$HOME/.local/bin/herdr-core; [ -x \"\$p\" ] || { echo \"herdr-core is not installed here\" >&2; exit 127; }; exec \"\$p\" connect'"
cd ~/lab/probes
python3 hc_probe.py --ssh 'ssh -T -o BatchMode=yes 127.0.0.1' call hello 
