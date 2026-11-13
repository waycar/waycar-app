---
status: accepted
---

# Host Tools are a static Rust binary, not Node scripts

_2026-10-29, accepted: the owner's decision (WAY-338), delivered in milestones M1 to M4 (WAY-443 is the cutover). Amends ADR 0007, whose "Plugin: Node ≥ 20" decision no longer holds. The first native release is plugin 2.0.0._

## Context

The Host Tools (Pairing, the agent status hooks, Agent Notifications, Live Activity, Chat Mode readers, the Mirror bridge) were Node scripts: `plugin/src/*.js`, `bin/node.sh`, an `npm ci` build. Every Host therefore needed Node 20 or later, and a missing or old Node was the top install failure. Ubuntu 22.04, Ubuntu 24.04, Debian 12 and Rocky 9 all ship an older Node by default, a non-interactive SSH shell often finds the distro's Node and not the user's nvm, and macOS launchd gives herdr a PATH with no Node at all. `bin/node.sh` grew a search over nvm, fnm, Volta, asdf, mise and Homebrew to cope, and the install page, the Linux and Mac Host pages and several articles told readers to install Node first.

The spike behind WAY-338 built the Host Tools' core as a Rust binary and ran it. The result:

- The binary was 2.0 MB and static (musl on Linux).
- It ran on bare Ubuntu 24.04, Debian 12 slim and Alpine 3.20 containers with nothing installed, and on Apple Silicon.
- HTTPS to the push relay worked with built-in root certificates, so no CA bundle is needed.

## Decision

- **Rewrite the Host Tools in Rust**, in `plugin/rust`, as one binary named `waycar`. `bin/waycar-hook` stays POSIX sh, and the agent extension files in `plugin/hooks` stay as they are because they run inside the agents.
- **One file per OS and CPU, chosen by `install.sh` from `uname`:** Linux x86_64 and ARM64 (static musl, no libc version floor, so Alpine works) and macOS Apple Silicon and Intel (deployment target 11.0). The installer checks the file's SHA-256 before it installs anything.
- **A Host needs herdr or tmux 3.2 or later, and `curl` and `tar` to install.** No Node, npm, nvm, Homebrew or CA bundle.
- **Strangler migration, then cutover.** The Rust code was added next to the JS and checked against it with a parity harness that runs both on the same cases (milestones M1 to M3, plugin 1.10.0 on main before the cutover). Hook commands tried Node first and fell back to native when a Host had none. The cutover (M4, WAY-443) deletes the JS, `bin/node.sh` and `node_modules`, and ships 2.0.0.
- **Existing Node Hosts move through the app's existing update flow.** The app runs `install.sh` again. The update removes what Waycar put on the Host (`src/*.js`, `bin/node.sh`, `node_modules`, `package*.json`, the Node version cache, the bridge-off state), rewrites Node-era agent hook entries to call `bin/waycar hook-session`, and never touches the user's own Node, npm, nvm or Homebrew, config, keys, `authorized_keys` or `@waycar_*` options. `install.sh` stages the new package next to the install directory and runs `bin/waycar version` first; if that fails the old install stays. After the swap it runs `waycar status --json` and moves the old install back on failure.
- **The app works against both eras.** Each SSH command probes in the same exec: if `src/<script>.js` exists it runs the Node path unchanged, otherwise it runs `bin/waycar <subcommand>` when that is executable, otherwise it exits with the existing plugin-too-old status. Native subcommands are `chat-read`, `chat-media` and `mirror`, with the same arguments, stdin and stdout protocol and exit codes as the scripts.

## Consequences

- Building the Linux musl targets from a Linux or Mac developer machine needs cargo-zigbuild and zig. `scripts/build-plugin-binaries.sh` installs the pinned toolchain on demand.
- There is no reproducible build yet: the package tarball hash differs on every build, so a binary cannot be checked against its source.
- Intel macOS is cross-built but unproven until it runs on an Intel Mac. The spike ran on the Linux images and the Apple Silicon Mac named above; Linux ARM64 is built but not run by this work.
- The trust model is the tarball's: the SHA-256 comes from the same origin as the file, so it catches corruption and a bad mirror but not a compromised waycar.dev.
- Codex asks for one `/hooks` review after the move, because its trust hash covers the hook command, which changed.
- Old Node processes (herdr's sidebar hook, a Mirror bridge) keep running until herdr restarts. `install.sh` prints how many and does not kill them.
- The plugin tests are `cargo test --locked` in `plugin/`. The parity harness and its Node oracle go away with the JS, so the shared test vectors in `plugin/test-vectors/` and the Rust unit tests carry the behavior from here.
- Dropping the Node requirement lets help pages, articles and the site's requirements list stop telling readers to install Node for the Host Tools. Agents that are themselves Node programs still need Node, and the docs say so where it matters.

## Considered options

- **Keep Node and make the install smarter**: rejected. The Node requirement was the top install failure, and `bin/node.sh` already searched every common version manager without fixing it.
- **A glibc build**: rejected. It would bring back a libc version floor and break Alpine.
- **Cut over in one change**: rejected. The Host Tools carry pairing, push and Live Activity, so the port was done in milestones, each checked against the JS before the next.
