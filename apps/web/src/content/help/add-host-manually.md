---
title: Add a Host by hand
description: Add a Host without a Pairing Code by typing its address, port and user, then choosing a Device Key, RSA Key or password to sign in.
category: get-started
order: 50
keywords: [add manually, add host, address, authorized_keys, device key, password, port, user]
related: [pairing, ssh-keys, host-keys, jump-host]
---

You can add a Host without scanning a Pairing Code. Type its address and user, pick how Waycar signs in, and add Waycar's key to the Host yourself. Waycar then runs its checks and asks you to trust the Host's key.

On the same Wi-Fi, [Find Computers](/help/find-computers) lets you pick a computer with SSH on instead of typing its address.

## Add the Host

1. Open the form:
   - With no Host yet, tap **Add Manually** under **Scan to Pair**.
   - In the Hosts sheet, tap **Add Host**, then **Add Manually**.
   - If the scanner shows **Camera Access Needed**, or your device can't scan codes, tap **Add Manually** there.
2. Under **Host**, fill in **Address** and **User**. **Port** starts at 22. **Name (optional)** is the label you see in Waycar. A Pairing Code always uses port 22, so add a Host whose SSH server listens on another port here and enter that **Port**. See [Pair with a Pairing Code](/help/pairing#troubleshooting).
3. Under **Authentication**, pick a **Method**: **Device Key**, **RSA Key**, or **Password**.
4. Tap **Save**.

## Let the Host accept your key

- **Device Key**: tap **Copy authorized_keys Line** and add that line to `~/.ssh/authorized_keys` on the Host. Waycar makes this key on your device, and the private key stays in the Keychain.
- **RSA Key**: tap **Copy RSA Public Key** and register it wherever the Host accepts SSH identities. The Host must offer RSA-SHA2-512 signatures.
- **Password**: type the password. Waycar saves it when you save the Host.

See [SSH keys and passwords](/help/ssh-keys).

## Optional settings

- **herdr Session**: leave **Session name** blank for the default herdr session.
  On herdr-core, Waycar uses the Host's default session only. See [Waycar with herdr-core](/help/herdr-core).
- **Jump Host**: fill in **Jump Host address (optional)** to reach a Host through another machine. Leave it blank to connect directly. See [Jump Host](/help/jump-host).
- **Mosh**: **Test Mosh on this Host** only works for a Host whose key is already trusted, such as a paired Host or one that has connected before. For a new Host it ends with "Could not connect to test. The host key is not trusted". Save the Host, trust its key on its page, then tap **Test Mosh Support** there. See [mosh](/help/mosh). A failed test doesn't block saving; sessions use SSH whenever mosh fails.

## Trust this Host?

When the Host's page opens, Waycar asks **Trust this Host?** and shows the key fingerprint. Check it matches the Host's key, then tap **Trust**. Pairing skips this step because the Pairing Code already carries the key. See [Host keys and fingerprints](/help/host-keys).

## Troubleshooting

- **Save is dimmed.** **Save** stays off until:
  - **Address** and **User** are filled in.
  - **Port** is a number from 1 to 65535. With a Jump Host address set, **Jump Host port** must be valid too.
  - **Session name** is blank, or uses only letters, digits, `.`, `_` and `-`, up to 64 characters, and isn't `.` or `..`.
  - With **Password**, a password is typed in. When you edit a Host that already used a password, a blank field keeps the saved one.
- **Could not save the Host.** Saving failed after you tapped **Save**. Try again.

After you save, the Host's page runs checks and says what to fix. See [A Host's page and checks](/help/host-page):

- **"The Host rejected the device key."** Add this Host's key line to `~/.ssh/authorized_keys` on the Host.
- **"The Host rejected the login. Check the username and password."**
- **"Could not reach the Host over SSH. Check the address and port."**

More in [Can't connect to a Host](/help/cant-connect).
