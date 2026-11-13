---
title: Use Waycar away from home
description: Keep using Waycar when your phone leaves the Wi-Fi your computer is on. Join them with a VPN such as Tailscale, then check it with Wi-Fi off.
category: hosts
order: 35
keywords: [tailscale, vpn, cellular, remote, away, outside, subnet router, wi-fi off, not reachable, private address]
related: [cant-connect, jump-host, hosts, add-host-manually]
---

Waycar connects your phone straight to your computer, the Host. It needs a network path between the two. On the same Wi-Fi the path already exists. When your phone leaves that Wi-Fi, a VPN can give it a path back. This page shows how with Tailscale.

## What you need

One of these:

- Your phone and your computer on the same network, such as the same Wi-Fi at home.
- Your phone and your computer both on a VPN, such as Tailscale, which gives them a private network of their own wherever they are.

You also need SSH turned on at the computer. See [Set up a Mac as a Host](/help/mac-host) or [Set up a Linux Host](/help/linux-host).

## Set up Tailscale in 3 steps

[Tailscale](https://tailscale.com) is a separate service with its own sign-in. Waycar is not affiliated with it. You set it up in Tailscale's apps, and Waycar needs nothing from it except the address.

1. Install Tailscale on your phone and on your computer. Sign in to both with the same Tailscale account.
2. On your computer, open Tailscale and note its Tailscale address. Make sure Tailscale is connected on your phone too.
3. Point Waycar at that address. Either show a Pairing Code with `waycar pair` and check the Tailscale address in the **Pair a Waycar device** list, or open the Host, tap **Edit**, and put the address in **Address**.

If the Host already works at home, you can keep that one. Swipe left on its card, tap **Duplicate**, and change only the address. See [Duplicate a Host](/help/hosts#duplicate-a-host). Then you have one Host for home and one for away.

## Test with Wi-Fi off

1. On your phone, turn off Wi-Fi so it uses cellular. Check that Tailscale still shows connected.
2. Open Waycar and open the Host's page. Tap **Run Checks Again**.
3. If the SSH check passes, go back to the Console. If the Host's agents appear there, it works. If a check fails, find its message in [Can't connect to a Host](/help/cant-connect).

## Reach several computers with one device

Installing Tailscale on every computer gets tedious. Instead, put Tailscale on your phone and on one always-on device on your home network. That device is a subnet router. It carries your phone's traffic onto the home network, so nothing is installed on the Hosts. Add each Host in Waycar by its normal home address.

The setup has more steps, such as approving the route in Tailscale. See [Reach any machine on your home network from Waycar with Tailscale](/articles/reach-your-local-network-with-tailscale).

## What Waycar does and doesn't do

- You need no Waycar account.
- No Waycar server relays your sessions. Your phone reaches your computer over the network you set up. See [Security](/help/security).
- The Host still needs its own SSH login. A VPN gets your phone onto the network. It does not sign you in.

## mosh

[mosh](/help/mosh) needs UDP traffic to reach the Host. If it can't, your agents use SSH. See [mosh isn't connecting](/help/mosh-not-connecting).

## Other ways in

If a VPN isn't an option, you can reach a Host through a [Jump Host](/help/jump-host).
