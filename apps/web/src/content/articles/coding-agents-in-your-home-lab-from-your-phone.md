---
title: "Check your home lab's coding agents from your phone"
description: "Run coding agents on a mini PC, a Proxmox VM or a Mac mini, and check every box from one list on your iPhone. Covers fleet installs, pair-only boxes, one key for every box and UDP between VLANs."
date: 2026-10-23
keywords: [home lab, homelab, coding agents, raspberry pi, proxmox, tmux, mosh, iphone, ssh]
---

A home lab is a few always-on machines behind one router: a mini PC, a Raspberry Pi, a NAS or a Proxmox VM, maybe a Mac mini. Each can run its own coding agents. Phone access is harder than for one laptop. There are several boxes to reach, none has a public address, you may not want to install software on some of them, and each has to accept your phone's SSH key.

This guide runs the agents in tmux on each box, gives your phone one key that opens every box you pair, and puts every agent in one list. The machine side works with any mosh client. The phone side uses Waycar, the iPhone and iPad app we build. It connects straight to your machines over SSH or mosh, with no relay for your sessions.

## What you need

On each box:

- Linux or a Mac that is on and awake. A box that is off or asleep cannot answer.
- An SSH server. On a Mac, turn on Remote Login.
- tmux 3.2 or later, or herdr 0.7.5 or later.
- `curl`, `tar` and `sha256sum` or `shasum`, for the installer. The host tools need no Node.
- Optional: `mosh-server`, with UDP open to it.

On the phone: an iPhone or iPad on iOS 18 or later.

This guide starts where the phone can already reach the box, for example on the lab's Wi-Fi. To reach the lab from outside, see [Reach any machine on your home network with Tailscale](/articles/reach-your-local-network-with-tailscale) and [How to reach your AI harness while you are away](/articles/reach-your-ai-harness-while-you-are-away).

## Check every box first

Lab machines are different ages, so check before you install. Waycar's [Linux Host page](/help/linux-host) lists distro defaults (read 2026-10-18): Enterprise Linux 8 ships tmux 2.7, which is too old. This loop prints what each box has. The box names are examples; use your own SSH aliases.

```sh
for box in minipc nas dev-ct; do
  echo "== $box"
  ssh "$box" 'tmux -V; command -v mosh-server; command -v curl; command -v tar'
done
```

A missing line means that tool is missing, or not on the PATH of a non-interactive SSH shell.

We have not run this guide on Raspberry Pi hardware or in a Proxmox container. The host tools are a static program for Linux x86_64 and ARM64 and need only the list above, so a Linux box that meets it is a fair candidate. Waycar's own test hosts are Linux containers (Ubuntu 22.04 and 24.04, Debian 12, Fedora 44, Rocky 9), each with its own SSH port. A NAS with a locked-down OS may not offer tmux. Use a VM on it, or pair it only (next section) if it is already there.

## Choose a path for each box

Waycar gives you three ways to add a box. The example lab has one of each: `minipc` is yours to configure, `nas` is somewhere you don't install software, and `dev-ct` is a container whose SSH server listens on port 2222.

| Path | Use it when | What lands on the box |
| --- | --- | --- |
| Install | You own the box and can run a script | The host tools in `~/.local/share/waycar/plugin`, a `waycar` link in `~/.local/bin`, and Status Hooks for the agents already installed |
| Pair only | You may not install software | One Device Key line in `~/.ssh/authorized_keys`, nothing else |
| Add by hand | SSH is not on port 22, or you want a password or a Jump Host from the start | Whatever you paste: the key line |

Pair only downloads the host tools to a temporary folder, shows the Pairing Code from there, and deletes the folder. The box still needs a terminal. It also still needs tmux or herdr, or the app can't open a console on it. Without the host tools there are no Status Hooks and no notifications from that box. On a tmux box, agents without hooks show Unknown. Run it with `ssh -t`, because the script reads your terminal:

```sh
ssh -t nas 'curl -fsSL https://waycar.dev/install.sh | sh -s -- --pair-only'
```

Add by hand is for `dev-ct`. A Pairing Code always uses port 22, so type the Host's address, port 2222 and user into the Add Host form. Choose Device Key, tap Copy authorized_keys Line, and paste that line into `~/.ssh/authorized_keys` inside the container. Waycar then asks you to trust the host key. Compare its fingerprint with the one on the box:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Containers need care. Their tmux sessions end when they stop. A rebuilt one gets a new SSH host key, which Waycar refuses until you confirm it, and it usually loses its hooks unless the home folder is a volume. To get status from `dev-ct`, run the install command inside it too, as in the next section.

## Install across the fleet

For the boxes you own, run the install command on each. It is a script, so read it first if you like. It downloads a package and checks its SHA-256 before it unpacks anything. Install your agents first, because the hooks are added only for agents already on the box. The loop skips `nas`, which is pair only.

```sh
for box in minipc dev-ct; do
  echo "== $box"
  ssh "$box" 'curl -fsSL https://waycar.dev/install.sh | WAYCAR_NO_PAIR=1 sh'
done
```

This is an example, not a tested fleet tool. It assumes a POSIX login shell on each box. We reasoned it from the install page and the script:

- Environment variables go right before `sh`, so `WAYCAR_NO_PAIR=1` goes there. It skips the pairing prompt and the install-or-pair question, which suits scripted installs. Over SSH without a terminal the script skips those questions anyway.
- A box that fails, for example one with no tmux or herdr, prints the installer's error. The loop carries on with the next box.
- A box with herdr and tmux defaults to herdr. Add `sh -s -- --tmux` to set it up for tmux, or `--no-hooks` to skip the agent hooks.
- The script looks for tmux and herdr on the PATH of the shell that runs it. A non-interactive SSH shell can have a shorter PATH than your terminal (Homebrew's tmux on a Mac, for one). If the installer says tmux or herdr is missing, run it from a terminal on that box.

Installed a new agent on a box later? Run the install command there again. It updates Waycar and keeps your pairing.

Pairing needs a terminal and a phone that can reach the box, so do it per box, on the lab Wi-Fi. `waycar pair` draws the Pairing Code in the terminal. The over-SSH form is our reasoning, not something we ran in a loop:

```sh
ssh -t minipc '~/.local/bin/waycar pair'
```

The pairing screen lists the box's addresses, and a box with Docker or a hypervisor bridge may have several. Check the ones your phone can reach, then scan. Waycar makes the phone's key, adds it to the box, and pins the box's host key from the code.

## One list for the whole lab

After pairing, the Console lists the agents and shells on all your Hosts. It sorts by status: Blocked, then Done, then Working, then Idle. Inside one status, agents are grouped by Host, newest change first. A Host menu in the bottom bar narrows the list to one box. See [The Console](/help/console).

The Hosts sheet has a card per box with its latency, a MOSH or SSH badge, and CPU, memory and swap gauges. A box with both herdr and tmux shows both in one list, and tmux agent cards carry a tmux badge. See [The Hosts sheet](/help/hosts) and [Waycar with tmux](/help/tmux).

A box you power down on purpose, like a lab machine that is off for the weekend, can have its switch turned off on its card. Waycar stops connecting and hides it from the Console. Its settings stay.

Status comes from your boxes. On tmux it comes from Status Hooks in Claude Code, Codex, omp, pi and opencode, and other agents show Unknown. On herdr it is what herdr detects. See [Agent status](/help/agent-status).

## Keys and trust

Every Host that uses a Device Key shares the same one. It is an ed25519 key made on the phone, and its private half stays in the Keychain. You add the same line to every box. On each box you can count Waycar's lines with:

```sh
for box in minipc nas dev-ct; do
  echo "== $box"
  ssh "$box" 'grep -cE " waycar( rsa)?\$" ~/.ssh/authorized_keys'
done
```

Waycar's help says the Device Key line ends with `waycar`, and the RSA Key line with `waycar rsa`. A box that has your phone's Device Key prints 1, or 2 if it also has the RSA Key line.

So one phone key opens every box you paired. If the phone is lost, remove its line on each box by hand. Removing a Host in the app only deletes it on the phone. With [iCloud Sync](/help/icloud-sync) on, your devices share one key, so deleting that line locks out all of them. Syncing needs the same Apple Account, two-factor authentication and iCloud Keychain. [SSH keys and passwords](/help/ssh-keys) covers replacing the key, and [Remove Waycar from a Host](/help/remove-host-tools) takes the hooks and the key line off one box.

During pairing, the box shows Device paired with the key's fingerprint, and you can press `r` to revoke it. For a Host you added by hand, Waycar asks you to confirm the host key. If a box later shows a different host key, Waycar stops and shows both fingerprints. That can mean you rebuilt a VM or container, and it can mean something else is answering at that address. Only trust the new key when you know why it changed. Keeping `/etc/ssh/ssh_host_*` on a volume keeps the key stable across rebuilds. See [Host keys and fingerprints](/help/host-keys).

## Network inside the lab

- Fixed addresses: give each box a DHCP reservation. If a box's address changes, a Host saved by IP address can no longer be found.
- UDP between networks: mosh needs UDP, 60000 to 61000 by default, between the phone and the box. If the lab has VLANs, a guest network or a firewall between the phone's path and the box, open that range on that path or accept SSH. Waycar tries mosh and falls back to SSH, so nothing breaks. You lose roaming across network changes.
- Boxes the phone can't reach: a [Jump Host](/help/jump-host) is a machine that can see the box. Both machines must accept the same key, and the Jump Host must allow TCP forwarding. mosh UDP does not go through it. The phone sends it straight to the Host's address, so expect SSH unless that address answers over UDP.
- Hardened sshd: a herdr box needs `AllowTcpForwarding` set to `local` or `yes`. tmux boxes don't need that.

## Awake boxes, running agents

The agents run in tmux or herdr on each box, not on your phone, and they keep working when your phone locks or leaves. Waycar keeps running for about 20 seconds after you leave the app. After that the terminal session ends, and it re-attaches when you return. A Mac mini or laptop in the lab can sleep, and a sleeping box can't be reached. Waycar can't wake it.

## Test it from cellular

1. Turn Wi-Fi off on the phone. If you rely on a VPN or subnet router, leave it on.
2. Open Waycar and tap Hosts. Every connected box shows MOSH or SSH. Mosh working on the lab Wi-Fi doesn't prove it works on this path, so check here.
3. Tap a box that shows SSH, then Test Mosh Support, to run a real mosh handshake.
4. Open an agent and flip Wi-Fi on and off. Over mosh the terminal stays attached.

We have not tested mosh UDP through a Tailscale subnet router. The badge tells you what you got.

## What this does not do

- It lists agents that run in herdr or tmux. An agent started in a bare SSH session is not in the list.
- Letters you type straight into the terminal show up once the box echoes them. Waycar does not predict ahead.
- It does not open your network. Away from home, the phone still needs a path to the lab, such as a VPN subnet router or a Jump Host.

## Without Waycar

The machine setup above works with any mosh client. Pick one session name and use it on every box:

```sh
mosh you@minipc -- tmux new -As agents
```

For a quick look across the lab, list each box's sessions:

```sh
for box in minipc nas dev-ct; do
  echo "== $box"
  ssh "$box" 'tmux list-sessions 2>&1'
done
```

`mosh -p 60001` pins one UDP port, for a firewall that forwards only that. You lose the single list, the Blocked and Done alerts, and Chat Mode. The agents keep running in tmux either way.

## More guides

- [Claude Code on a build server: unblock it from your phone](/articles/claude-code-on-a-build-server-from-your-phone): answering permission prompts on a headless box.
- [Keep a coding agent attached through dead zones](/articles/keep-a-coding-agent-attached-through-dead-zones): what survives a tunnel, a network switch or a locked phone.
- [Run omp from your phone over mosh](/articles/run-omp-from-your-phone-over-mosh): approval modes and what triggers Blocked.
