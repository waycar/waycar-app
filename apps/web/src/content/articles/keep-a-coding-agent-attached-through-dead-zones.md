---
title: "Keep a coding agent attached through dead zones"
description: "What survives a tunnel, an elevator, a Wi-Fi to cellular switch or a locked phone when you watch a coding agent over mosh, with the timings and where each one comes from."
date: 2026-10-18
keywords: [mosh, tmux, dead zones, ssh, cellular, roaming, coding agents, iphone]
---

Your coding agent keeps running when your phone loses signal. What drops is the terminal you watch it through. This guide splits the problem into layers: what keeps running on the machine, what mosh keeps alive between the machine and the phone, and what Waycar adds. Waycar is the iPhone and iPad app we build for checking on coding agents that run in tmux or herdr on your own machines. Numbers come from Waycar's help and the code of the released app, checked on 2026-10-18, and from mosh 1.4.0.

## What keeps running where

The agent runs inside tmux or herdr on your machine. Your phone is a window onto that terminal, not a place where anything runs.

| Layer | Where it runs | What a dead zone does to it |
| --- | --- | --- |
| Coding agent | The machine, inside tmux or herdr | Nothing. It never talks to your phone. |
| tmux or herdr | The machine | Nothing. It holds the terminal with or without a client attached. |
| `mosh-server` | The machine | Waits for the phone. In Waycar's setup it gives up after 60 seconds of silence. |
| Waycar's own link to the machine | Phone to machine, over SSH | Follows SSH's rules. It drops on a network switch and Waycar redials. |
| The terminal on screen | The phone | Shows a redraw of the machine's screen. Ends about 20 seconds after you leave the app. |

We checked the first two rows for tmux on tmux 3.6, 2026-10-18. We started a session on a throwaway socket that wrote a line every second, attached a client on a pty, then sent that client SIGKILL, which is what a dropped connection looks like to tmux. The client count went to 0, the session stayed, and the counter kept going. We did not run that test on herdr. Its `--help` (0.9.5, same day) describes plain `herdr` as launching or attaching to "the persistent session".

This guide covers the phone's dead zone. If the machine loses its own internet, the agent can't reach its model provider, and nothing on the phone changes that.

## What mosh does

SSH is one TCP connection tied to your phone's current address. Change networks and it drops. mosh uses SSH once, to log in and start `mosh-server` on the machine. After that it talks over UDP. Its man page (mosh 1.4.0, checked 2026-10-18) puts the default ports at 60000 to 61000. Three details explain the behavior in the rest of this guide.

- It sends screen state, not bytes. The server and client each keep a snapshot of the current screen, and mosh works to bring the client to the newest server-side state, skipping frames in between ([how mosh works](https://mosh.org/#techinfo)). After a gap you jump to the live screen. You do not get a replay.
- Roaming needs no handshake. The client numbers its datagrams and sends a heartbeat at least every 3 seconds. When the server gets an authentic packet with a higher number than any before it, it starts answering to that packet's source address, whatever it is. A new Wi-Fi network or a cellular address needs no negotiation.
- It tolerates loss. [mosh.org](https://mosh.org) says its UDP protocol "handles packet loss gracefully" and sets the frame rate from network conditions, and its datagrams are encrypted and authenticated.

There is a documented case. On 2012-08-22 Iain Learmonth was stuck in a lift in Aberdeen. Once it moved near his flat he had weak Wi-Fi that dropped a lot of packets. A web page would not load, but [mosh got him logged in](https://mosh.org/elevator.txt) to a shared Unix system, where he sent an email, and the fire brigade was called. That is one anecdote, not a benchmark.

## What happens at which second

These are the timings in Waycar's help ([Network changes and reconnecting](/help/reconnecting), checked 2026-10-18). Where the code of the released app (App Store 1.1.3) gives a more exact value, we say so.

With the app open and a mosh terminal on screen:

| When | What happens |
| --- | --- |
| You switch Wi-Fi and cellular | Waycar re-checks every Host at once. The mosh terminal moves to the new network and stays attached. |
| Same switch, terminal on plain SSH | The connection drops. Waycar reconnects and re-attaches. A switch that killed the connection is noticed within seconds. Otherwise it takes about 35 seconds (the app pings every 30 seconds and allows a few round trips for the answer). |
| About 6 seconds of silence from the machine | A Reconnecting pill appears over the live screen. The app's code uses 6.5 seconds, the same threshold mosh's own client uses to call a server late (mosh 1.4.0 source). |
| The machine answers again after an outage | Waycar reconnects right away instead of waiting for its next retry. |
| 65 seconds of silence | Waycar reconnects the terminal over mosh. Waycar starts each server with `MOSH_SERVER_NETWORK_TMOUT=60`, so the old one has exited and this is a new server on the same agent. |

If Waycar's one automatic reattach does not recover the terminal, the screen says "The Host stopped answering over UDP for 65s." and offers Reattach or Use SSH Instead. Waycar's help words it as "Waycar already reattached once on its own". See [What connection messages mean](/help/connection-messages). The agent kept running throughout.

The 60-second limit is Waycar's choice. Stock `mosh-server` waits forever unless you set `MOSH_SERVER_NETWORK_TMOUT` (its man page, mosh 1.4.0, checked 2026-10-18), so a laptop can come back a week later. Waycar bounds it so a phone that vanished doesn't leave a server behind that keeps a herdr pane sized to the phone.

When you leave the app or lock the phone:

| When | What happens |
| --- | --- |
| 0 to about 20 seconds | Waycar keeps running as normal. |
| After about 20 seconds | The terminal session ends. The agent keeps running on the machine. |
| Back within about 50 seconds after the session ends (about 70 seconds after you leave) | For a mosh terminal, Waycar had started a fresh mosh server before letting the old one go, so the terminal re-attaches with no SSH work. |
| Back later | Waycar checks each Host's saved SSH connection with one quick request, and dials a new one only if that is slow to answer. |
| Any return after the session ended | You see the terminal's last screen under a Reconnecting veil until the live one draws. Waycar stores that picture on the device for the 8 most recent terminals, up to a day. See [Privacy](/privacy). |

## What you see afterward

You see the current screen. Whatever the agent printed during the gap and then scrolled away is not replayed on the phone. If the agent finished, or stopped to ask for approval, while you were out of range, the screen shows where it stands now.

Typing is plain. Letters you type straight into the terminal appear once the machine echoes them back, because Waycar does not predict ahead the way the desktop mosh client can. On a weak link that is visible. The Composer, the draft box under the terminal, is local, so drafting a prompt costs nothing on a bad link. Send it after the pill is gone. We did not test what keys typed straight into the terminal during a stall do, so we make no claim about that.

Blocked and Done notifications come from the machine, not from the terminal link. With notifications on, they reach you while Waycar is in the background or closed ([Notifications](/help/notifications)). The machine encrypts each one before it passes through the push relay.

## What stops it

- The machine is asleep or off. It has to be on and awake to answer. Waycar can't wake it.
- UDP is blocked. Some office and hotel Wi-Fi blocks it. Waycar then uses SSH, and a network switch drops that terminal and brings it back. Waycar remembers per Host and per network whether mosh gets through. A badge beside the Host says MOSH or SSH, and Test Mosh Support on the Host's page runs a real handshake ([mosh](/help/mosh), [mosh isn't connecting](/help/mosh-not-connecting)).
- The gap is longer than about a minute with the app open. The mosh session ends and Waycar starts a new one when the machine answers.
- You are away from the app for more than 20 seconds. Nothing watches the terminal then. It re-attaches when you return.
- You go through a Jump Host. mosh's UDP does not travel through it. The phone sends UDP straight to the Host's address as you entered it, so that address must be reachable over UDP from where you are. If it is not, you get SSH.
- On herdr, re-attaching takes the terminal back from your desk client, as opening it does. tmux lets both attach ([Your desk and phone on one terminal](/help/take-over)).

## Test it yourself

You need a Host that shows the MOSH badge. If it shows SSH, fix that first.

1. Open an agent in Waycar and note the badge beside the Host.
2. Toggle Wi-Fi off and let cellular carry on. A mosh terminal should stay attached. Toggle it back on.
3. Turn on airplane mode and count. Expect the Reconnecting pill at about 6 seconds. Turn airplane mode off before 60 seconds and expect the screen to catch up on its own.
4. Do it again and wait past 65 seconds, then restore signal. Expect Waycar to reconnect the terminal on its own, or the red Detached icon in the toolbar with Reattach if it cannot. With no signal at all we have not traced which message shows.
5. Leave the app for 10 seconds and return. The same live terminal is still there with no veil, because Waycar was still running. Then leave for a minute and return. The session ended, so you see the last screen under the Reconnecting veil until the live one draws.
6. On the machine, `pgrep -a mosh-server` lists the running mosh servers. Right after you leave the app, one extra may appear for up to a minute: Waycar starts a spare server so a quick return re-attaches fast. Waycar's 60-second limit means a server whose phone vanished should be gone about a minute later.

We wrote these steps from Waycar's help and source, not from a stopwatch run on a phone, so treat the numbers as what to expect and report what you see. For an SSH comparison, put the Host on SSH (or use a network that blocks UDP) and repeat step 2. Per the help, that terminal drops and Waycar brings it back.

## Without Waycar

The machine side needs no Waycar. Install `mosh-server`, open UDP 60000 to 61000, and from any mosh client:

```sh
mosh you@your-machine -- tmux new -As work
```

`new -As work` attaches to a session named `work`, or creates it. Start your agent inside it. If the link drops, mosh's own client warns that it has not heard from the server, and it picks up when the network returns. Without mosh, `ssh -t you@your-machine tmux new -As work` re-attaches by hand.

Without Waycar you lose the list of agents across machines, Blocked and Done status, push notifications and the automatic re-attach after the connection ends. The desktop mosh client adds typing prediction, which Waycar does not have.

## More guides

- [Claude Code on a build server: unblock it from your phone](/articles/claude-code-on-a-build-server-from-your-phone): answering permission prompts on a headless box.
- [Check pi agents from your iPhone](/articles/check-pi-agents-from-your-iphone): what changes when the agent never asks for approval.
