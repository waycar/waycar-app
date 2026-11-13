---
title: Find Computers
description: Find computers on your Wi-Fi that have SSH on, then pick one and sign in instead of typing its address to add your first Host.
category: get-started
order: 45
keywords: [local network, remote login, bonjour, scan network, password]
related: [add-host-manually, ssh-keys, host-keys]
---

Find Computers lists computers on your Wi-Fi that have SSH on. Pick one to add it as a Host without typing its address. Waycar learns which Backends run there after you sign in.

## Find and sign in

1. Join the same Wi-Fi as your computer and turn on SSH. On a Mac, turn on **Remote Login** in System Settings.
2. In Waycar, tap **Scan** under **Find computers on your network** at the top of **Add Your First Host**. You can also open **Hosts**, tap **Add Host**, then **Find Computers**, or use the Sample's **Connect your machine** sheet.
3. Allow Local Network access when iOS asks. The search starts as soon as you tap.
4. Tap your computer under **Computers with SSH on**. Under **Sign In**, enter **User** and **Password**, then tap **Add**.

To sign in with a key, tap **Use a Key Instead**. The form keeps the computer's address and your user. See [SSH keys and passwords](/help/ssh-keys). After saving, check and trust the Host's fingerprint on its page. See [Host keys and fingerprints](/help/host-keys).

If the computer accepts only keys, its Host page says so and shows one command to run in Terminal on it. Run it, then tap **Check Again**.

## If your computer is missing

Some computers do not announce themselves. Tap **Check Every Address** to try port 22 on the other addresses on this Wi-Fi. This runs only when you tap, only on private home or office networks, and checks at most the small address range around your phone. A scan can appear in your network's logs.

If no computers appear, check SSH and Wi-Fi, then tap **Search Again**. A computer using a different SSH port can be [added by hand](/help/add-host-manually).

## If Local Network access is off

On **Waycar Can't See Your Network**, tap **Open Settings** and turn on Local Network for Waycar. Return to Waycar to search again. You can also tap **Add Manually** and enter an address without searching.
