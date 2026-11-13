#!/bin/sh
# Side-effect-free herdr-core detection for ONE SSH exec (stdin of `sh -s`, or `sh -c '<this>'`).
# Never runs `hc server status`, `hc connect`, `hc ls` ... (all of them AUTO-START a core).
# Only `--version`, which does not touch the core or its state dir (verified).
# Usage:  sh hc_detect.sh            |   ssh host sh -s < hc_detect.sh
# Env:    HC_NAME=<session>  session the Host configuration uses (default "default")
#         HC_BIN=/path/to/herdr-core   optional: try this binary first (default: search PATH and ~/.local/bin)
# Set HC_NAME to the session the Host configuration uses ("default" if none).
HC_NAME=${HC_NAME:-default}
echo "@@WAYCAR-HC-BEGIN@@"
SEARCH="$PATH:$HOME/.local/bin"
found=""; ver=""
for cand in ${HC_BIN:+"$HC_BIN"} herdr-core hc; do                      # herdr-core always exists; `hc` is only a symlink the installer MAY add (and `hc` can be some other program)
  case "$cand" in
    /*) p=$cand ;;
    *) p=$(PATH="$SEARCH" command -v "$cand" 2>/dev/null) || continue ;;
  esac
  [ -x "$p" ] || continue
  v=$("$p" --version 2>/dev/null </dev/null)
  case "$v" in "hc "[0-9]*) found="$p"; ver=${v#hc }; break ;; esac   # the real thing prints "hc X.Y.Z"
done
echo "OS=$(uname -s) ARCH=$(uname -m) HOME=$HOME UID=$(id -u)"
if [ -z "$found" ]; then
  echo "HC=absent"
else
  echo "HC=present"
  echo "HC_PATH=$found"
  echo "HC_VERSION=$ver"
  state="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-core/$HC_NAME"
  sock=""
  # core.lock holds the socket path the core actually listens on (survives stop/crash; written at core start)
  [ -r "$state/core.lock" ] && sock=$(cat "$state/core.lock" 2>/dev/null)
  if [ -z "$sock" ]; then                          # never started here: the endpoint a client would use (docs/security.md#state-and-endpoints)
    if   [ -n "${HC_SOCKET:-}" ];        then sock=$HC_SOCKET
    elif [ -n "${XDG_RUNTIME_DIR:-}" ];  then sock="$XDG_RUNTIME_DIR/herdr-core/$HC_NAME.sock"
    elif [ -d "/run/user/$(id -u)" ];    then sock="/run/user/$(id -u)/herdr-core/$HC_NAME.sock"
    else sock="$state/$HC_NAME.sock"; fi
  fi
  echo "HC_SESSION=$HC_NAME"
  echo "HC_SOCK=$sock"
  # present = a socket file exists. A kill -9'd core leaves a STALE one (verified), so this means
  # "a core has run here", not "alive"; `hc connect` starts a core anyway when the connect fails.
  if [ -S "$sock" ]; then echo "HC_SOCK_STATE=present"; else echo "HC_SOCK_STATE=absent"; fi
fi
echo "@@WAYCAR-HC-END@@"
