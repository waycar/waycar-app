---
title: "Claude Code on a build server: unblock it from your phone"
description: "Run Claude Code in tmux on a headless Linux build server, then answer its permission prompts and questions from an iPhone over mosh or SSH. Covers modes, trust dialogs and firewalls."
date: 2026-10-18
keywords: [claude code, build server, headless linux, tmux, mosh, ssh, iphone, permission prompts]
---

You start a long Claude Code job on a build server: a migration, or a cycle of running the tests and fixing what fails. Then you leave. Sooner or later it hits something it won't decide alone and sits at a prompt on a machine nobody is watching.

This guide gets you back into that prompt from a phone. The machine half works with any SSH or mosh client. The phone half uses Waycar, the iPhone and iPad app we build. Versions checked on 2026-10-18: Claude Code 2.1.302, tmux 3.6 and mosh 1.4.0. What Anthropic's software does comes from its docs as of the same day, and the text says where.

## What makes Claude Code stop and wait

Claude Code's permission mode decides what it does without asking. These are the modes from Anthropic's [permission modes page](https://code.claude.com/docs/en/permission-modes) as of 2026-10-18:

| Mode | Runs without asking |
| --- | --- |
| `default` (called Manual in the CLI) | Reads only |
| `acceptEdits` | Reads, file edits, and common filesystem commands such as `mkdir`, `mv` and `cp` |
| `plan` | Reads, plus commands the auto mode classifier approves, when auto mode is available |
| `auto` | Everything, with background safety checks |
| `dontAsk` | Reads in your working directories and pre-approved tools. Anything that would prompt is denied |
| `bypassPermissions` | Everything. The docs say isolated containers and VMs only |

From Claude Code 2.1.283, `auto` is the built-in starting mode in a terminal. You can start in another mode:

```sh
claude --permission-mode acceptEdits
```

`claude --help` on 2.1.302 lists the choices: `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`.

Even in `auto`, a job can stop. The docs list actions no mode approves, including any tool matched by one of your `ask` rules and the built-in `AskUserQuestion` tool, which is how Claude asks you a question mid-task. In `auto`, if the classifier blocks an action 3 times in a row or 20 times in total, auto mode pauses and Claude Code goes back to prompting until you approve one.

Only `dontAsk` never gives you a prompt to answer: it denies what would prompt, so the job moves on without that action. `bypassPermissions` approves almost everything, but the actions no mode approves still stop it, `ask` rules and questions included. So the rest of this guide applies to a box that already runs `bypassPermissions`.

## Keep the job alive in tmux

A plain SSH session ends with the connection, and usually takes its jobs with it. tmux keeps the job going on the machine:

```sh
tmux new -As build
cd /srv/ci/my-repo
claude --permission-mode acceptEdits
```

`new -As build` attaches to a session named `build`, or creates it. Detach with Ctrl-b, then d. Anthropic's Remote Control page gives the same advice for a remote machine: start `claude` inside `tmux` or `screen` so it survives an SSH disconnect.

Waycar needs tmux 3.2 or later. Distribution defaults, from Waycar's [Linux Host page](/help/linux-host):

| Distribution | tmux by default |
| --- | --- |
| Ubuntu 24.04 | 3.4 |
| Ubuntu 22.04 | 3.2a |
| Debian 12 | 3.3a |
| Rocky Linux 9 | 3.2a |
| Fedora 44 | 3.7c |

Enterprise Linux 8 ships tmux 2.7, which is too old. Waycar's host tools are one native program and need no Node.

## Set up the box

Do these as the user that runs Claude Code. The phone logs in as one user, sees that user's tmux sessions, and the hooks live in that user's home. If your jobs run as a service account, switch to it before you start.

1. Install `mosh-server` (`sudo apt install mosh` on Debian and Ubuntu) and open inbound UDP 60000 to 61000. That is the default range. On a cloud instance it has to be open in the security group as well as the machine's own firewall. Without UDP, Waycar stays on SSH and still works.
2. Install Claude Code first. Waycar's installer only adds hooks for agents it finds, so rerun it if you install one later.
3. Run the install command:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

It links a `waycar` command at `~/.local/bin/waycar` and offers to draw a Pairing Code in the terminal. Scan it in the app. Pairing adds a Device Key line to `~/.ssh/authorized_keys` for that user. If a tool such as config management owns that file, put the line in its source too, or a later run may remove it.

A Pairing Code always uses SSH port 22. If your build server listens elsewhere, [add the Host by hand](/help/add-host-manually) with its port. On a machine where you may not install software, you can pair without installing anything. You then get no status hooks and no notifications.

```sh
curl -fsSL https://waycar.dev/install.sh | sh -s -- --pair-only
```

A tmux Host needs only plain SSH. `AllowTcpForwarding` matters only for herdr Hosts.

## The trust dialog can stall a job

Claude Code asks whether you trust a folder before it runs its project config. In a checkout with a `.claude/settings.json` that pre-approves a tool, Claude Code 2.1.302 opened "Quick safety check: Is this a project you created or one you trust?" with **No, exit** highlighted and **Yes, I trust this folder** below it. In a plain empty folder there was no dialog.

Pressing Return picks the highlighted option, and the highlighted option is the one that closes Claude Code. Waycar's hooks also stay silent until you answer: while the dialog showed, no `@waycar_*` option was set on the tmux pane, so Waycar has no status for the agent. A job you start on a fresh checkout can sit at this dialog with no Blocked alert. Open the agent in the terminal view and pick **Yes, I trust this folder** on purpose.

## What the phone shows

Check that the hooks landed:

```sh
waycar hooks status
```

```text
claude: installed (/home/you/.claude/settings.json)
```

The same command lists every agent it knows. The file is `~/.claude/settings.json`, or `$CLAUDE_CONFIG_DIR/settings.json` if you set that variable. Waycar merges its entries and keeps your own hooks. These are the main entries on this machine, from reading that file on 2026-10-18. Others keep the status current, such as clearing Blocked after you answer and releasing the pane when Claude Code exits.

| Claude Code event | Waycar status |
| --- | --- |
| `UserPromptSubmit` | Working |
| `PermissionRequest` | Blocked |
| `Notification` of type `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog` or `agent_needs_input` | Blocked |
| `Stop` | Done |

In Waycar's lab on Claude Code 2.1.296 (2026-10-12), `PermissionRequest` fired about 0.3 seconds after the dialog drew. Blocked and Done then send a push notification, once you have turned notifications on. Your machine holds each change for about 5 seconds and checks again before sending, so a prompt you answer within those 5 seconds sends nothing. See [Notifications](/help/notifications).

We did not test `AskUserQuestion` on 2.1.302. Waycar's hooks leave it out of the Working state on purpose, but we haven't confirmed what its card reads. Try one on your own box first.

## Answer from the phone

Tap the Blocked agent. You get Claude Code's real terminal with its dialog, and you answer it as you would at your desk. That covers a numbered question or a prompt that needs typed text.

If you started the agent from Waycar's New Agent screen with Chat Mode on, a **Needs your OK** card shows the prompt instead. **Allow** sends Return and **Cancel** sends Esc. For anything that isn't yes or no, tap **Show Terminal**. Chat Mode is for agents you start from the app. A job you started yourself in tmux opens as a terminal. See [Chat Mode](/help/chat-mode).

If Claude Code exits or its pane closes, the job is a Closed Session in the Console for 30 days, and one tap resumes it. On tmux, Resume picks up the exact session when the hooks are on. From a shell, `claude --continue` reopens the most recent session in the current directory, and `claude --resume` opens a picker. Anthropic's [sessions page](https://code.claude.com/docs/en/sessions) says a resumed terminal session usually gets back the permission mode it was in. Pass `--permission-mode` to change it.

## When Claude Code's own Remote Control fits better

Anthropic has its own way to drive a running session from a phone: [Remote Control](https://code.claude.com/docs/en/remote-control), through the Claude mobile app or claude.ai/code. If you sign in to Claude Code with a claude.ai plan, it is the simpler choice. There is no SSH and no firewall rule. Claude Code and your claude.ai login must already be on the box, `claude` must keep running, and on Team and Enterprise plans an Owner first turns Remote Control on in admin settings.

Build servers often sign in another way. As of 2026-10-18, Anthropic's page says Remote Control:

- is available on Pro, Max, Team and Enterprise plans, and "API keys are not supported";
- does not work with a token from `claude setup-token` or `CLAUDE_CODE_OAUTH_TOKEN`, which "can only make model requests";
- is unavailable on Amazon Bedrock, Google Cloud's Agent Platform and Microsoft Foundry, or when `ANTHROPIC_BASE_URL` points anywhere but `api.anthropic.com`;
- stores the session transcript on Anthropic's servers while it is connected, while execution and filesystem access stay on your machine.

If your box uses an API key, a setup token, a cloud provider or a gateway, that route is closed. Waycar attaches to the terminal, so Claude Code's sign-in method should not matter to it. We have not run Waycar against an API-key, Bedrock or gateway login. There is no relay for your session: your phone connects to the box over SSH or mosh. Only the optional push notifications and Live Activity updates pass through a relay. Your machine encrypts the agent, Host and task details first. The relay still sees delivery details and, for Live Activities, how many agents are in each status.

## A private build network

Build servers often sit on a network your phone can't reach. Two options:

- Put the phone on that network with Tailscale. [Reach any machine on your home network from Waycar with Tailscale](/articles/reach-your-local-network-with-tailscale) and [How to reach your AI harness while you are away](/articles/reach-your-ai-harness-while-you-are-away) walk through it.
- Use a [Jump Host](/help/jump-host): a small server your phone can reach that can see the build machine. Both hops check host keys, and the Jump Host's sshd must allow TCP forwarding. mosh's UDP does not go through a Jump Host. The phone sends it straight to the Host's address, so mosh works only if that address answers over UDP. Otherwise you get SSH.

## Test it from cellular

1. Start a job with `claude --permission-mode manual` and ask it to edit a file. The edit prompts.
2. Turn Wi-Fi off on the phone and open the agent in Waycar. Look for the MOSH or SSH badge beside the Host. Tap **Test Mosh Support** on the Host's page to run a real mosh handshake. See [mosh isn't connecting](/help/mosh-not-connecting) if it fails.
3. When the job blocks, check that the notification arrives and that you can answer it.

Then try signal dropping, as in a tunnel or an elevator. Over mosh the terminal shows a **Reconnecting** pill after about 6 seconds without word from the machine, and it re-attaches when signal comes back.

## What this setup does not do

- The machine has to be on and awake. A stopped or suspended instance can't answer.
- mosh needs UDP. Without it you get SSH, which drops when your phone changes networks and then reconnects.
- Letters you type straight into the terminal show up once the machine echoes them. Waycar doesn't predict ahead the way the desktop mosh client can. The Composer, a draft box under the terminal, isn't affected.
- After a dead zone your phone gets mosh's redraw of the current screen, not a replay of everything that scrolled by.
- When you leave the app, Waycar keeps running for about 20 seconds. Then the terminal session ends and re-attaches by itself when you come back. The job in tmux is unaffected.

## Without Waycar

The tmux half needs no special software. From any mosh client:

```sh
mosh you@build-server -- tmux new -As build
```

Or over plain SSH: `ssh -t you@build-server tmux new -As build`. You attach to the same session and answer the same dialog. Nothing alerts you when the job blocks, so you find out when you look.

## More guides

- [Keep a coding agent attached through dead zones](/articles/keep-a-coding-agent-attached-through-dead-zones): what survives a tunnel, a network switch or a locked phone.
- [Check pi agents from your iPhone](/articles/check-pi-agents-from-your-iphone): what changes when the agent never asks for approval.
