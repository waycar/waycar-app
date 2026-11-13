---
title: mosh isn't connecting
description: Get mosh working when a Host shows SSH instead of MOSH or the mosh handshake fails. Install mosh-server and let UDP through.
category: troubleshooting
order: 20
keywords: [udp, mosh-server, handshake failed, ssh badge, firewall, test mosh]
related: [mosh, cant-connect, reconnecting, hosts]
---

If mosh can't get through, Waycar keeps your agents on SSH, so nothing breaks. You lose mosh's roaming across network changes. mosh needs two things on your Host: `mosh-server` installed, and UDP traffic able to reach it. Waycar starts mosh for you over SSH, so there's nothing else to set up.

## Check what's happening

1. Open the Host's page.
2. Tap **Test Mosh Support**.
3. Read the result:
   - **Mosh supported — agent sessions ride mosh UDP**: mosh works.
   - **Mosh handshake failed — sessions will use SSH**, with a reason underneath, such as "The mosh handshake timed out.": work through the steps below.

While editing a Host, **Test Mosh on this Host** shows different wording: **Mosh available on this Host**, **Mosh handshake failed — sessions will use SSH**, or **Could not connect to test.** with a reason. That form test only works for a Host whose key Waycar already trusts. If it says "The host key is not trusted", save the Host, trust its key on its [page](/help/host-page), and use **Test Mosh Support** there. On a disabled Host the button is off: "This Host is disabled. Turn it on to test mosh."

## 1. Install mosh-server on the Host

If the reason mentions that `mosh-server did not print a MOSH CONNECT banner`, install mosh on the Host. Instructions for every system are at [mosh.org](https://mosh.org/#getting). Then tap **Test Mosh Support** again.

## 2. Let UDP reach the Host

If the reason is **The Host has mosh-server but the UDP handshake did not complete** or **The Host did not answer over UDP within …**, SSH works but UDP is blocked somewhere.

- Open the Host's firewall to mosh's UDP ports (60000 to 61000 by default, per mosh.org).
- If the Host is behind a router, forward those UDP ports to it.
- Some networks block UDP entirely, such as some office or hotel Wi-Fi. Try again from another network. Waycar remembers, per Host and network, whether mosh gets through, so a network that blocks UDP goes straight to SSH next time.

## 3. Using a Jump Host?

mosh's UDP doesn't go through the Jump Host. Your phone sends it straight to the Host's address as you entered it, so that address must be reachable over UDP from where you are. If it isn't, expect agents to use SSH.

## Good to know

- After you fix the Host, an open terminal can move over with **Retest and Upgrade Sessions** on the Host's page.
- There's no local echo prediction on mosh. Letters you type straight into the terminal appear once your Host sends them back. The Composer isn't affected.
- More about how Waycar uses mosh: [mosh](/help/mosh).
