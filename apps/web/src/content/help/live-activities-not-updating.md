---
title: Live Activities aren't updating
description: Find out why a Host's Live Activity doesn't appear or stops updating, using the Live Activity line in Waycar's notification settings.
category: troubleshooting
order: 55
keywords: [lock screen, dynamic island, missing, stale, out of date, idle, start failed]
related: [live-activities, notifications-not-arriving, notifications, update-host-tools]
---

When a Live Activity doesn't show up or stops changing, Waycar tells you why. Open **Settings**, then **Notifications**. Under each Host with **Live Activity** turned on, a **Live Activity:** line shows whether it is active or idle, and the reason.

## Read the Live Activity line

| Line | What it means | What to do |
| --- | --- | --- |
| active — started, updated, adopted, or started by the Host | The Live Activity is running. | Nothing. |
| idle — no working, blocked, or done agents | Every agent is Idle, so there is nothing to show. | Nothing. It starts when an agent works, gets blocked, or finishes. |
| idle — iOS has Live Activities disabled for Waycar | Live Activities are off for Waycar in iOS Settings. | Turn them on in iOS Settings for Waycar. |
| idle — the per-Host toggle is off | **Live Activity** is off for this Host. | Turn on **Live Activity** in the Host's section. |
| idle — no push device token yet | This device hasn't registered for push yet. | Make sure notifications are allowed and you're online. See [Notifications don't arrive](/help/notifications-not-arriving). |
| idle — no Notification Key for this Host | This device is registered with the Host but has no usable Notification Key for it. | Turn **Notifications** off and back on for this Host to register again with a new key. |
| start failed — reason | iOS refused to start it. The reason comes from iOS. | Check the reason, then try again after the next status change or when you reopen Waycar. |
| sealing the update failed | Waycar couldn't encrypt the update. | Reopen Waycar with the Host connected. |

## It says "May be out of date"

The Host hasn't updated the Live Activity recently. A Live Activity your Host started on its own while Waycar was closed gets this caption after a while. Open Waycar with that Host connected and it refreshes.

## The Host never starts one while Waycar is closed

Starting a Live Activity from the Host needs the current Waycar plugin. See [Update Waycar on your Host](/help/update-host-tools). On tmux, status comes through Waycar hooks, so an agent that shows Unknown won't drive it. See [Agent status shows Unknown](/help/status-unknown).

If you dismissed the Live Activity, it stays away until that Host's agents go quiet.

## Still not working?

On herdr, check the plugin's recent errors on the Host:

```sh
herdr plugin log list --plugin waycar --limit 20
```

See [Live Activities](/help/live-activities) for how it works.
