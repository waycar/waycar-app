#!/bin/sh
# Install Waycar Host Tools from the worktree's plugin/ (mounted read-only at
# /opt/waycar-plugin) the way a user would, through plugin/install.sh with
# WAYCAR_PLUGIN_SOURCE. herdr is on PATH, so this is herdr mode, and tmux 3.4
# also gets the `waycar` command and the agent Status Hooks. Run as waycar on
# every container start and by `make harness-lab-reinstall-plugin`.
set -eu
WAYCAR_PLUGIN_SOURCE=/opt/waycar-plugin WAYCAR_NO_PAIR=1 sh /opt/waycar-plugin/install.sh </dev/null
