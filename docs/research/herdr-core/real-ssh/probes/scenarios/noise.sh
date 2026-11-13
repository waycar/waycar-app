cd ~; cp -n .bashrc .bashrc.orig; cp -n .profile .profile.orig
S='ssh -T -o BatchMode=yes 127.0.0.1'
LINE="sh -c 'PATH=/usr/local/bin:/usr/bin:/bin:\$HOME/.local/bin; p=\$(command -v herdr-core) || p=\$HOME/.local/bin/herdr-core; [ -x \"\$p\" ] || { echo \"herdr-core is not installed here\" >&2; exit 127; }; exec \"\$p\" connect'"
HELLO='{"jsonrpc":"2.0","id":0,"method":"hello","params":{"framed":true}}'
setnoise() { # which: none|profile|bashrctop|bashrcafter|all
  cp .bashrc.orig .bashrc; cp .profile.orig .profile
  case "$1" in *profile*|all) sed -i '1i echo NOISE-PROFILE' .profile;; esac
  case "$1" in *bashrctop*|all) sed -i '1i echo NOISE-BASHRC-TOP' .bashrc;; esac
  case "$1" in *bashrcafter*|all) n=$(grep -n '^esac' .bashrc | head -1 | cut -d: -f1); sed -i "${n}a echo NOISE-BASHRC-AFTER-GUARD" .bashrc;; esac
}
run() {
  echo "--- [$1] $2"
  echo "(a) ssh -T host '<connect line>' ; stdin = framed hello; stdout bytes before the first '{':"
  (printf '%s\n' "$HELLO"; sleep 0.5) | $S "$LINE" 2>/tmp/err.txt | head -c 120 | od -c | head -4
  echo "   stderr: $(cat /tmp/err.txt | head -c 200)"
  echo "(b) ssh -T host 'echo X'  ->"; $S 'echo X' 2>&1 | od -c | head -3
  echo "(c) printf 'echo X\\n' | ssh -T host (login shell reads stdin) ->"; printf 'echo X\n' | $S 2>&1 | od -c | head -4
  echo "(d) printf 'echo X\\n' | ssh -T host sh -s ->"; printf 'echo X\n' | $S sh -s 2>&1 | od -c | head -3
}
for m in none profile bashrctop bashrcafter all; do setnoise $m; run $m; done
setnoise none
