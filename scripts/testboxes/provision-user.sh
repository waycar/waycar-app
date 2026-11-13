#!/bin/sh
# Run ON a test box as the waycar user (ssh ... 'sh -s' < provision-user.sh).
# Moves the toolchain staged in /opt/waycar-stage (nvm + Node LTS, pi, opencode)
# into ~ with the same .bashrc lines the nvm and opencode installers write, so
# the box ends up like a user who ran those installers. Idempotent.
set -eu
stage=/opt/waycar-stage
[ -d "$stage/.nvm" ] || { echo "no staged toolchain in $stage" >&2; exit 1; }
for d in .nvm .opencode .npm; do
  if [ -d "$stage/$d" ] && [ ! -e "$HOME/$d" ]; then cp -a "$stage/$d" "$HOME/$d"; fi
done
# The installers' rc lines, with the stand-in home replaced by ~.
if ! grep -q 'NVM_DIR' "$HOME/.bashrc" 2>/dev/null; then
  sed "s#$stage#\$HOME#g" "$stage/.bashrc" >>"$HOME/.bashrc"
fi
# nvm.sh needs bash; under dash it returns 3.
bash -c '. "$HOME/.nvm/nvm.sh" && echo "node $(node -v) at $(command -v node); pi: $(command -v pi); opencode: $HOME/.opencode/bin/opencode"'
