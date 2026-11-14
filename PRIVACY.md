# Privacy Policy

_Last updated: November 14, 2026._

Waycar is an iPhone and iPad app for [herdr](https://herdr.dev) and tmux.
Waycar is made by OTREVA, LLC ("we" or "us"), which is responsible for the
personal data described in this policy. Our contact details are at the end.
Waycar connects your device straight to computers you control, called Hosts,
over SSH or mosh.

The short version:

- The Waycar app has no accounts, no ads, and no tracking across other apps
  or sites. Apart from Apple's SKAdNetwork install signal to Reddit, with a
  copy to Singular, our measurement vendor (see "SKAdNetwork attribution"),
  it never shares your data with advertisers. Our website, waycar.dev, uses
  Reddit and X ad-conversion pixels to measure our own ads. They load only
  where the law allows: after you choose Allow in the EU, the EEA, the UK,
  and Switzerland, never under Global Privacy Control, and not after you
  choose Decline (see "Advertising pixels" under "This website").
- If you allow it, Waycar sends usage analytics, such as which features are
  used. They are pseudonymous: tied to a random ID, not to your name or Apple
  Account. They never include Host names, commands, prompts, or terminal
  content. Waycar asks before sending any, and you can change your choice in
  Settings.
- Your SSH keys, passwords, terminal output, and prompts go only between your
  device and your Hosts, unless you turn on AI Summaries, which have your Host
  send recent screen text to an AI provider (see
  [AI Summaries](#ai-summaries)). They never pass through a server we run,
  except the end-to-end encrypted notification details described below,
  which can include a Chat Mode Agent's final reply.
- If you use iCloud Sync, your Hosts and keys sync through your own iCloud
  Keychain, which is end-to-end encrypted.
- The only server we run is a push relay for notifications. It forwards
  encrypted messages and keeps no records of them.
- On Apple Watch, Waycar gets everything from your iPhone over Apple's
  encrypted watch link. Voice messages you record on the watch are turned
  into text on your iPhone and then deleted (see [Apple Watch](#apple-watch)).

## What stays on your device

- **SSH credentials.** Waycar makes your Device Key on your device. Its
  private half stays in the iOS Keychain. Saved Host passwords and trusted
  Host fingerprints are kept in the Keychain too. If iCloud Sync is on, they
  also sync as described in the next section.
- **Hosts and settings.** Your list of Hosts and your Waycar settings are
  stored on your device.
- **Last-known Agent list.** So Waycar can show your Agents right away when
  it opens, it keeps a copy of each Host's latest list of herdr, herdr-core
  or tmux sessions on your device, and which of herdr, herdr-core and tmux
  each Host runs. This copy holds what herdr, herdr-core or tmux reports
  about each Workspace, tab, pane, and Agent: names and labels, IDs, Agent
  kinds, working folders, terminal titles, statuses, Git repository and
  worktree paths, references to Agent sessions on the Host, sidebar values
  from the herdr plugin, and the herdr, herdr-core or tmux version. It also
  holds where the herdr-core program is on the Host (its file path) and the
  Host's sidebar layout file and the Host's address, port, username, herdr
  session, and Jump Host details, so Waycar can tell the copy still belongs
  to that Host. To connect faster, it also keeps the path of your home folder
  on the Host and the herdr protocol version the Host last reported. It
  never holds terminal output. The copy is
  left out of backups, never synced, and cannot be read while your device is
  locked. Waycar deletes it when you remove the Host or change its connection
  details.
- **Terminal screens.** So an Agent or Shell you open again shows its last
  screen while it reconnects, Waycar keeps a picture of the latest screen of
  the eight terminals you used most recently. A picture can show anything the
  screen did, including secrets a command printed. Each picture is kept for
  at most 24 hours, in the app's cache, which is not backed up and cannot be
  read while your device is locked. Waycar never stores the screen as text.
  Next to each picture it keeps the pane's ID, when the picture was taken,
  and the Host's connection details, so a picture is never shown for a
  different Host.
  It deletes a picture when that terminal's session ends, when its pane
  closes, and when you remove the Host or change its connection details.
- **Mosh reachability.** So Waycar knows whether mosh works on the network
  you are on, it keeps a short record for each Host and network: whether mosh
  got through, when, the Host's connection details, and the kind and name of
  the network interface with the first part of your device's local address on
  it. Records expire after a day. They are left out of backups, never synced,
  and cannot be read while your device is locked. Waycar deletes a Host's
  records when you remove the Host or change its connection details.
- **Terminal output and prompts.** What you type and what your Agents print
  travel only over the direct connection between your device and your Host.
  The only exceptions are the limited notification data described below and,
  if you turn them on, AI Summaries. Messages and prompts you send to an
  Agent go over SSH or mosh to that Agent on your Host, which sends them to
  the AI provider it is set up to use, under that account. Apart from AI
  Summaries, Waycar never sends them to an AI provider.
- **Saved conversations.** So a Chat Mode chat opens right away, and so you
  can read an Agent's conversation with no signal, Waycar keeps a copy of
  each Chat Mode Agent's latest messages on your device, and of every other
  Agent that reports its session to Waycar and that you open or that
  finished recently while the app was open: your
  prompts and the Agent's replies, up to 300 messages. Images and videos
  that cannot change once written (images inside the transcript, omp and
  pi image blobs,
  and web images and videos) are kept in the app's cache too, up to 300 MB,
  the least recently viewed removed first; an image, video, or other file a
  reply names or attaches by its path on the Host is read again from the Host
  each time it is shown and kept only in temporary storage while the app
  runs. These copies are left out of backups, never synced, and cannot be
  read while your device is locked. Waycar deletes a chat's messages after
  the Agent closes, when you remove the Host or change its connection
  details, and after 30 days without use; cached images and videos are
  deleted after 30 days without use. Videos load only when you tap them.
  When a reply links an image or video on the web, Waycar loads it only when
  you tap it, straight from that address, which then sees your device's IP
  address, the same as opening the link.
  Waycar does not load web addresses that name a local or private host, such
  as `localhost`, `.local` names or bare IP addresses.
- **Closed Sessions.** When an Agent closes, Waycar keeps a record of it for
  30 days so you can resume it: the Host, the Agent's kind and name, its
  title, working folder, Workspace and tab labels, and a reference to its
  session on the Host. It never holds terminal output. The records are left
  out of backups and cannot be read until you first unlock your device after
  a restart. With iCloud Sync on, they sync through your iCloud Keychain, and
  forgetting one forgets it on all your devices.
- **AI Usage.** If a Host has CodexBar installed, Waycar reads its usage
  numbers over SSH to show how much of each AI plan is left. Waycar does not
  save these numbers.
- **Dictation.** When you tap Dictate, Waycar uses the microphone and turns
  your speech into text on your device with Apple's built-in speech model.
  Audio is never saved or sent anywhere, not even to your Host. Nothing you
  dictate reaches your Host until you tap Send. The first time you dictate in
  a language, iOS may download that language's speech model from Apple.
- **CarPlay.** In the car, speech is also turned into text on your device.
  In CarPlay, a question to an Agent is sent as soon as you pause, without
  being read back or a tap, and Waycar keeps listening for your next one
  until you go back or stay quiet for two minutes. A Blocked prompt can be
  answered by saying "Allow" or "Deny", without a tap. Agent replies, Agent
  names and the command you are asked to approve are read aloud, so
  passengers can hear them. No audio or transcripts leave your device; only
  the text you send reaches your own Host. The optional Natural Voice
  (Settings › CarPlay Voice) offers several optional voice models. Each is
  downloaded once, only when you tap its Download button in Settings (never
  in the car), from Hugging Face (`huggingface.co`), which sees your
  device's IP address like any website.
  No speech or text is sent with it; after the download, the voice runs on
  your device. You can delete any downloaded model at any time.

## Apple Watch

The Waycar watch app never connects to your Hosts. It gets everything from
Waycar on your paired iPhone over Apple's WatchConnectivity link, which is
encrypted between your two devices.

- **What the watch keeps.** Your iPhone sends the watch your Agent titles,
  their statuses and how long they have had them, a rough progress estimate
  (plan steps done of total, or a phase word such as Verifying), and your
  Host names. The watch keeps the latest copy so it can show the list right
  away.
- **Fetched when you look.** An Agent's last reply when your iPhone can
  read its transcript, otherwise its Summary, and a Blocked Agent's command, are read by your iPhone only when you open
  that Agent on the watch. The watch holds them in memory while you look
  and never stores them.
- **Voice messages.** When you record a voice message, the watch uses the
  microphone and sends the recording to your iPhone over the same encrypted
  link. Your iPhone turns it into text on the device with Apple's built-in
  speech model and sends the text to your Host. The recording is deleted on
  both devices once the message is sent or abandoned. The text you sent comes
  back to the watch so it can show it as sent. The audio never goes to
  Apple's servers or to your Host. If
  your iPhone runs a version of iOS older than iOS 26, the watch uses
  Apple's own dictation instead, which may send your speech to Apple to turn
  it into text, under Apple's privacy policy.

## iCloud Sync

iCloud Sync is on by default. It stores your Hosts, saved Host passwords, SSH
keys, trusted Host fingerprints, and app settings in your iCloud Keychain.
That way they show up on your other devices signed in to the same Apple
Account. With iCloud Sync on, your Closed Sessions sync the same way. iCloud
Keychain is end-to-end encrypted, so neither we nor Apple can read these
items.

You can turn iCloud Sync off in Settings › iCloud Sync. This device then stops
syncing and keeps its current Hosts, passwords, and keys. Copies already in
your iCloud Keychain stay there for your other devices. Waycar never deletes a
synced SSH key or fingerprint. If you replace your key in Settings › iCloud
Sync, every device switches to the new one. Notification Keys never sync.

## Terms

Waycar is licensed under Apple's
[Licensed Application End User License Agreement](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/).

## AI Summaries

AI Summaries are off until you turn them on. If you have not chosen yet,
Waycar asks when you turn on notifications for a Host in Settings. Not Now
keeps them off, and Waycar does not ask again. The **AI Summaries** switch in
Waycar's Settings asks the same way, and you can turn them on or off there at
any time. Before they start, Waycar shows what will be sent and to which AI
providers (Anthropic, OpenAI, OpenRouter and Google) and asks for your
permission; nothing is turned on for you. Waycar saves that setting
(`"summary_enabled"`) in the herdr plugin's `notify.json` file on each of
your Hosts, whether or not you use notifications. A Host that is offline gets
the change the next time it connects. Turning the setting off writes `false`
the same way.

While AI Summaries are on, the herdr plugin on each Host sends up to the last
60 lines of an Agent's screen to an AI model. It asks for one sentence about
what the Agent is doing, where it ended up, or what it needs from you. It
does this when an Agent turns Blocked or Done, and, while Waycar is open on
your device, about once a minute and when an Agent changes status, but only
for Agents whose screen changed since their last summary. The model is
whichever one the Host can already reach: Claude from Anthropic (through
Claude Code or omp, or an Anthropic API key), ChatGPT from OpenAI (through
Codex or omp, or an OpenAI API key), or OpenRouter (an OpenRouter API key;
OpenRouter passes the request to a Google Gemini or OpenAI model), cheapest
first, or a command you choose. These providers are not our service
providers: they receive the text under your Host's own account and their own
terms and privacy policies.

Screens can contain secrets such as tokens or file contents. The request goes
from your Host straight to that model's provider, under your account there
and the provider's terms. It never passes through Waycar, the push relay, or
us. When the plugin uses an AI command-line tool, it runs it from an empty
private folder with its tools, MCP servers, and project settings turned off,
so the model sees only the screen text and a fixed instruction.

The summary is saved on your Host, in the plugin's settings folder, with one
entry per pane. The next summary replaces it. Entries not touched for 7 days
are deleted, and turning AI Summaries off deletes all of them on the next
status change. Waycar reads summaries over SSH to show them on the Agent
cards and keeps them only in memory. A summary travels inside the encrypted
notification, just like task titles.

On a Host that uses tmux, Waycar's tools on your Host do the same job: they
read the pane's screen on the Host only while AI Summaries are on, exactly as
the herdr plugin does, and save the setting in the same kind of file in
Waycar's settings folder there.

## Waycar's tools on your Host

If you use tmux, the install command also puts Waycar's tools on your Host:
a `waycar` command and small Status Hooks in your coding agents (Claude Code,
Codex, omp, pi and opencode) that tell Waycar whether each Agent is working,
blocked, done or idle. They run on your own computer and write that status,
the agent's session ID and its transcript path into tmux on the same
computer, where Waycar reads it over SSH. They send nothing off your computer
except the end-to-end encrypted notifications described below, through the
push relay, and, only if you turn them on, the AI Summaries requests above.
`waycar hooks uninstall` removes the hooks.

## Notifications and the Push Relay

Agent Notifications can tell you when an Agent is blocked or done while
Waycar is in the background or closed. Apple's push service (APNs) only
accepts pushes signed with a credential for this app. So App Store builds
send notifications through a push relay we run at
`https://waycar-apns.otreva.com`.

Waycar asks once, after you have used an Agent, whether to turn on
notifications and Live Activities. If iOS has not asked yet, Continue shows
Apple's permission prompt, and allowing notifications there turns them on.
If you already allow notifications, Turn On does. Waycar then registers this
device on every Host, including Hosts you add later, and turns on their Live
Activities. Not Now or Don't Allow turns nothing on.

When a Chat Mode Agent finishes, its Done notification can carry the Agent's
final reply, up to 1,000 bytes, inside the encrypted notification.

The relay has no accounts, database, message queue, or message history. Your
Host encrypts the notification details with a Notification Key. The relay
then signs the push and forwards it to Apple. It never gets the key, so it
cannot read the details.

### Notification Keys

Waycar makes a separate Notification Key on your device for each Host. It is
kept in the Keychain and in the app's shared storage so Live Activities can be
decrypted while your device is locked. That shared copy is protected until
you first unlock your device after a restart, and it is left out of backups.
Waycar copies the key over SSH to its Host so the herdr plugin can encrypt
notifications. The push relay never receives it.

### What the relay sees

For every notification, the relay handles:

- the Apple push token that tells Apple which device to notify;
- the encrypted notification;
- your Host's IP address;
- when, how often, and how large the requests are; and
- which APNs environment to use and a few routing values.

For a Live Activity update, Apple needs a few values it can read, so iOS can
update or end the activity without opening Waycar:

- how many Agents are working, blocked, done, or idle;
- whether the update starts, changes, or ends the activity, its priority, and
  its time; and
- when present, the times the activity goes stale or is removed.

When your Host starts a Live Activity while Waycar is closed, the request
also carries:

- a random ID Waycar made for that Host when you added it. It is not based on
  the Host's name, address, or account. It lets Waycar open the right Host
  when you tap the activity, and it lets the relay tell that the requests came
  from the same Host; and
- a fixed alert, "Agents active", which Apple requires to start an activity.
  It is the same for every Host and never names an Agent or task.

For this, Waycar stores its start token and that Host ID in the Host's
notification settings while the Host's Live Activity is on. It removes them
when you turn it off.

None of these values identify a single Agent. Project names, task titles, AI
Summaries, a Chat Mode Agent's final reply, Agent types and names, Host
names, pane IDs, and per-Agent details stay inside the encrypted
notification. If a notification cannot be decrypted, Waycar shows a generic
message instead of anything it cannot verify.

### How the relay uses and keeps data

The relay uses this data only to check requests, prevent abuse, and deliver
notifications to Apple. It never uses it for ads, analytics, tracking,
profiling, or sale.

The relay does not save push tokens, notifications, or request history. It
holds IP addresses and push tokens in temporary memory for one minute to
enforce rate limits. That memory is not a lasting record and is cleared
whenever the relay restarts.

The relay runs on Cloudflare Workers, and Apple delivers the notifications.
See "Service providers" for how they handle this data.

- [Cloudflare Privacy Policy](https://www.cloudflare.com/privacypolicy/)
- [Apple Privacy Policy](https://www.apple.com/legal/privacy/)

### Your own relay

The herdr plugin and Waycar let you set your own push relay address instead of
ours. A custom relay only works with an app you build and sign yourself, using
APNs credentials for that app's bundle ID. Only our relay can deliver
notifications to App Store builds.

## SKAdNetwork attribution

If you install Waycar after seeing or tapping a Reddit ad, Apple's own
SKAdNetwork tells Reddit that one of its ads led to an install.
Waycar calls Apple's on-device API
directly; no ad company's SDK is built into the app. Your device sends
this signal straight to Reddit, the same way it would reach any server you
connect to, so Reddit sees its IP address. Your device also sends a copy
the same way to Singular, our measurement vendor, so we can see how our
Reddit ads are doing; Singular sees the same signal and your IP address
too, under its own privacy policy. This does not use the App Tracking
Transparency prompt or any advertising identifier, and Apple does not
count it as tracking.

## Your choices and deleting data

Agent Notifications, Live Activities, AI Summaries, and usage analytics are
all optional.

- You can turn off usage analytics in Waycar's Settings. See "Usage
  analytics" below.
- You can turn off notification and Live Activity permissions at any time in
  iOS Settings.
- Removing a Host's notification registration deletes this device's push
  token and Notification Key from that Host, then removes the Notification
  Key from your device.
- Removing a Host from Waycar deletes it and any saved password from your
  device. With iCloud Sync on, it also removes them from your other devices.
  Devices that were offline or had sync off drop the Host the next time they
  sync. A small marker noting the deletion stays in your iCloud Keychain.
- Deleting Waycar removes its files from your device. Keychain items, such
  as your keys and passwords, can stay after the app is gone.
- On the website, use "Cookie settings" in the footer to allow or decline
  analytics cookies and the advertising pixels at any time, or turn on Global
  Privacy Control in your browser to keep the pixels from loading.

We have no accounts and no database of your content, so there is usually
nothing on our side to look up or delete. For a privacy or deletion request,
email [privacy@waycar.dev](mailto:privacy@waycar.dev). Please do not include
passwords, keys, tokens, Host details, or other sensitive information.

## Service providers

We use these companies to run Waycar and waycar.dev.

- **PostHog, Inc.** (United States): app and website usage analytics, and
  choosing which home page version a website visitor sees, under
  PostHog's [terms](https://posthog.com/terms) and
  [privacy policy](https://posthog.com/privacy).
- **Cloudflare, Inc.** (United States): hosts waycar.dev and runs the push
  relay. Cloudflare's
  [data processing addendum](https://www.cloudflare.com/cloudflare-customer-dpa/)
  is part of its terms and requires it to protect this data.
  [Privacy policy](https://www.cloudflare.com/privacypolicy/)
- **Google LLC** (United States): Google Workspace hosts the mailbox for email
  sent to our waycar.dev addresses. Google processes this email under its
  [Cloud Data Processing Addendum](https://cloud.google.com/terms/data-processing-addendum),
  which requires it to protect it.
  [Privacy policy](https://policies.google.com/privacy)
- **Singular Labs, Inc.** (United States): measures our Reddit app-install
  ads from the copy of the app's SKAdNetwork signal described under
  "SKAdNetwork attribution", under Singular's
  [privacy policy](https://www.singular.net/privacy-policy).

**Apple** delivers notifications (APNs) and stores your iCloud Keychain,
under the Apple Developer Program License Agreement and
[Apple's Privacy Policy](https://www.apple.com/legal/privacy/).

**Advertising partners (third parties):** these companies are not our
service providers. Reddit also receives the app's SKAdNetwork install
signal (see "SKAdNetwork attribution"); otherwise they use the data their
pixels collect on waycar.dev, under their own policies and for their own
purposes.

- **Reddit, Inc.** (United States): the Reddit Ads conversion pixel and the
  app's SKAdNetwork install signal (see "SKAdNetwork attribution"), under
  Reddit's [privacy policy](https://www.reddit.com/policies/privacy-policy).
- **X Corp.** (United States): the X Ads conversion pixel, under X's
  [privacy policy](https://x.com/en/privacy).

The Reddit and X pixels on the website, described under "Advertising
pixels" in "This website", may count as a sale or sharing for advertising
under some US state laws. The app's SKAdNetwork signal to Reddit,
described under "SKAdNetwork attribution", is a separate channel that
Apple's own framework sends directly from your device; we make no such
classification for it. Beyond these two channels, we sell or share
nothing else.

## Usage analytics

Waycar uses PostHog, Inc. (US cloud, `us.i.posthog.com`) for usage analytics,
so we can learn which features are used. The analytics are pseudonymous: they
are tied to a random ID, not to your name, email address, or Apple Account. We
do not use them for tracking or advertising, and we do not sell them.

The app sends these events: `app_opened`, `host_added`, `pairing_succeeded`,
`pairing_started`, `pairing_abandoned`, `agent_launched`, `notification_opened`,
`invite_shared`, `console_active` and `milestone`.
`agent_launched` includes `kind`, the type of Agent launched (for example
`claude` or `codex`). `host_added` says how the Host was added (`method`:
`scan`, `paste`, `discovered` or `manual`). `pairing_started` and
`pairing_abandoned` say how a Pairing Code reached the app (`method`: `scan`
or `paste`) and, for `pairing_abandoned`, which pairing step the Scan to Pair
sheet was closed at (`stage`, a fixed word such as `scan` or `verify`). They
carry no error text and no Host details.
`console_active` says you opened the Console with at least one Host
connected. It is sent at most once a day on a device, however often you open
the app. It carries ranges and fixed words, never exact numbers or names: how
many Hosts you have switched on (`hosts`: `1`, `2-3` or `4+`), which
programs the connected Hosts run (`backend`: `herdr`, `tmux`, `both` for
herdr with tmux, `core` for herdr-core, `core_tmux`, `herdr_core` for Hosts
on each of the two, or `all`), how many Agents the
Console lists (`agents`: `0`, `1`, `2-4` or `5+`), whether you sent an Agent a
message since the last `console_active` (`steered`: `true` or `false`), and
whether this device is registered for Agent Notifications (`push`: `on` or
`off`). `milestone` is sent the first time you reach one of a short list of
firsts, once for each on an install: `host_connected`, `agent_seen`,
`attention_seen` (the Console showed an Agent that is Blocked or Done),
`first_steer` (a message reached an Agent), `sample_host_opened` (you opened
the offline sample). It carries the name and `days_since_first_open` (`0`,
`1-3`, `4-7` or `8+`). Find Computers sends `lan_scan_started` when a search
starts, `lan_scan_found` when it first settles, and `lan_permission_denied`
when iOS refuses Local Network access. `lan_scan_found` also says how many
computers the search listed (`found`: `0`, `1` or `2+`). No computer names,
addresses or SSH banners are sent.
`invite_shared` says that you opened the share sheet for the app's App Store link in
Settings › About; sharing the app earns nothing, and who (if anyone) you
shared it with, or whether they installed it, is never reported. Every
event includes `env`, which says whether it came from a debug or release
build. Events are tied to a random ID the app makes. When iCloud Sync is on,
that ID is stored in your iCloud Keychain so your iPhone and iPad share it;
otherwise it stays on the device.

Internal test builds of Waycar (debug builds and our own TestFlight test
builds, never the version on the App Store) may also send five
connection and pairing events, and only if you chose **Allow**: `host_connect`,
`terminal_attach`, `transport_lost`, `app_foregrounded` and `pairing_failed`
(which adds the pairing step that failed, as `reason`). They say how a
connection or terminal went in fixed words (an outcome such as `success` or
`timeout`, and whether it used mosh or SSH) and rounded times (such as
"under 500 ms" or "away under 20 s"). They never include Host names,
addresses, usernames, pane IDs, paths, or anything shown in a terminal. The
App Store version sends none of them. A TestFlight build sends them only
after Apple's signed receipt confirms it is not the App Store version; until
then they are dropped.

PostHog's SDK also adds to each event the device model, OS name and version,
app version and build number, locale, time zone, screen size, network type
(such as Wi-Fi or cellular), and a session ID that groups the events from one
use of the app. Each request carries your IP address, which PostHog uses only
to work out a coarse location (such as country and city). The IP address
itself is not stored. On Waycar's App Store privacy label these items appear
under Data Linked to You, as Product Interaction (the events), User ID (the
random ID), Other Usage Data (the device and app details) and Coarse
Location, because they share one random ID. They are not used for tracking.

Analytics never include your SSH credentials, Host names, IP addresses you
connect to, usernames, file paths, commands, prompts, Agent names, or
terminal content. There is no session replay and no advertising identifier.
Waycar does not use your Apple Account for analytics.

The first time you open Waycar on a device, it asks whether to share usage
analytics. Until you choose **Allow**, the app sends nothing to PostHog. You
can change your choice at any time in Waycar's Settings. When analytics are
off, the app sends no analytics events. Turning them off also deletes the
analytics ID on this device and, while iCloud Sync is on, from your iCloud
Keychain. If another of your devices still shares analytics, it keeps its ID
and puts it back in your iCloud Keychain, so this device may use that same ID
again if you turn analytics back on. Otherwise, turning them back on starts a
new ID.

To send `console_active` and each `milestone` only once, the app keeps a small
record on the device: the day it was first opened, the milestones and the day
it has already reported, and whether you sent an Agent a message since. It
never leaves the device. Turning analytics off keeps these records on the
device, so turning analytics back on does not send a milestone or a day again.
Nothing new is recorded while analytics are off, and the steered note is
cleared.

The ID is random and not shown in the app, so we cannot link analytics events
to you by name. PostHog keeps analytics events for as long as our PostHog
plan retains them (1 year on PostHog's free plan, 7 years on its paid plans)
and may delete them after that. We can't shorten that period, but you can ask
us to delete your data sooner. To ask for analytics data to be deleted, email
[privacy@waycar.dev](mailto:privacy@waycar.dev).

## This website

`waycar.dev` is a static site served by Cloudflare. It uses PostHog to count
page views, opens of the Get Waycar picker, clicks on App Store links and on
the GitHub link beside them, and copies of the install command,
with the same `env` property. How visitors are counted depends on where you
are, which Cloudflare works out from your IP address:

- **In the EU, the EEA, the UK, or Switzerland** (or if your country cannot be
  determined, or you visit over Tor), the site shows a small cookie choice.
  Until you choose, nothing is stored on your device, and page events are
  still counted without cookies: PostHog combines your IP address and browser
  user agent with a secret value it changes every day and keeps only the
  resulting one-way hash, so page views on the same day count as one visitor
  and visits on different days are not linked. If you choose "Decline",
  counting stays cookieless and only your choice is stored, in local storage.
  If you choose "Allow", PostHog stores a random, pseudonymous visitor ID in a
  first-party cookie and local storage, plus window and session IDs in session
  storage, so return visits count as the same visitor. Your choice is kept in
  local storage.
- **Everywhere else**, PostHog stores that pseudonymous visitor ID in a
  first-party cookie and local storage, and window and session IDs in session
  storage, from your first visit, without asking. If your browser sends a
  Global Privacy Control signal, the site does not stop page events; it
  switches to the same cookieless counting and stores nothing. If you then
  choose "Allow" in "Cookie settings", PostHog's cookie and storage are used,
  but the advertising pixels still never load.

Sometimes we test two versions of the home page to learn which one works
better. Page events on the home page say which version was shown. When you
open the home page in a browser, the site's server asks PostHog which version
to show you, or whether a test is running at all; no location is worked out
for it. How the server does this depends on the same things as page
counting:

- **Where the site does not ask first and your browser sends no Global
  Privacy Control signal**, the server sends PostHog a random ID (the one in
  `waycar_ab`, or a new one) and nothing else about you. While a test is
  running, it sets a first-party cookie named `waycar_ab`, so you see the
  same version when you come back. That cookie holds the random ID, used only
  to keep you in the same version, and which version you saw (`a` or `b`),
  nothing else. It is kept for 90 days after you were last shown a version on
  the home page. While you are part of a test, events on other pages also say
  which version you saw.
- **In the EU, the EEA, the UK, or Switzerland** (or if your country cannot be
  determined, or you visit over Tor), **and whenever your browser sends a
  Global Privacy Control signal**, no cookie is set and nothing is stored on
  your device for the test. When you open the home page, the server computes
  a one-way code from your IP address and browser user agent, using today's
  date and a secret kept only by the site, sends only that code to PostHog,
  and keeps nothing. This is similar in purpose to PostHog's cookieless
  counting. Without that secret, PostHog or anyone else cannot turn the code
  back into your IP address or link it across days. A day ends at your local
  midnight, based on Cloudflare's estimate of your time zone, so your version
  can change from day to day (or when your network or browser changes).
  Events on other pages do not say which version you saw. This cookieless
  choice of version cannot be turned off, because nothing is stored that
  could identify you later; the only data that leaves the server is the
  one-day code.

If you later turn on Global Privacy Control or visit from one of those
regions, the site deletes the `waycar_ab` cookie on your next visit; when the
test ends, it deletes it the next time you open the home page. An older test
cookie named `waycar_variant`, which held only `a` or `b`, is deleted on your
next visit.

So that automated traffic does not skew the counts, page events from a browser
that reports it is automated carry a `likely_bot` flag. So do page events from
a browser with a UTC time zone (the default for automated browsers) that also
has an 800 by 600 screen, reports a desktop operating system with a
phone-sized screen, or lists no preferred languages. This is worked out in
your browser from the operating system, screen size, language, and time zone
listed below; nothing extra is collected or stored.

Each download of `https://waycar.dev/install.sh` is also counted, as one
anonymous event sent by the site's server, and so is each download of the
plugin package that script then fetches. Each event contains only a new
random ID, the event name, the same `env` property, and, when the download
comes from our own tools, an `internal` flag. The requests can add up to two
more fixed values: whether the plugin is being installed or updated, and
whether the run is a full install or a pair-only run that installs nothing.
PostHog receives it from Cloudflare's network, PostHog is set to discard IP
addresses, and no location is worked out for it.

Our paid ads (on X and Reddit, for example) link to `https://waycar.dev/go/…`
addresses, which send you on to a short "Opening the App Store" page of ours
and then the App Store, or to this site. That page runs the advertising pixels
described below, under the same rules, and forwards you after a moment. If the
pixels are not allowed for you, the page forwards you at once and nothing is
sent to Reddit or X. The ad
platform's click ID in the ad link (X's `twclid` or Reddit's `rdt_cid`) is
passed along in the address so its pixel can match the click to the ad. Our own
servers and PostHog do not record it. Where the pixels load, they may save it
themselves in a cookie on `waycar.dev` (`_twclid`, `_rdt_cid`), as described
under "Advertising pixels". "Decline" removes those cookies. Each such click
is counted the same way: one anonymous event sent by the site's server, with a
new random ID, the event name, the same `env` property, which ad link it was
and where it sent you (the App Store or the site), the campaign tags in the
link (such as `utm_source=x`), and, when the click comes from our own tools, an
`internal` flag. It does not contain ad-platform click IDs, and PostHog
discards IP addresses and works out no location for it. The App Store link
carries a campaign name, so Apple's App Analytics can report, without
identifying you, how many App Store visits and downloads came from each ad.

With each page event, PostHog receives the page address (including any
campaign parameters), the page you came from, your browser, operating system,
and device type, your screen and window size, your language, your time zone,
a session ID that groups page views from one visit, and your IP address. When
the visitor ID is in a cookie, PostHog uses the IP address to work out a coarse
location (such as country and city) and then discards it. When nothing is
stored, PostHog uses it only for the daily visitor hash and discards it before
storing the event, so no location is worked out. The site does not record
session replays or capture what you type. Cloudflare keeps standard request
logs, such as your IP address and browser type, to serve the site.

The analytics switch in Waycar's Settings covers the app only. On the website,
every visitor can change their choice at any time with "Cookie settings" in
the footer. Where the site asks first, "Decline" and Global Privacy Control do
not stop page events; they switch to cookieless counting. Where it does not
ask first, "Decline" stops page events to PostHog as well. Blocking JavaScript
stops page events entirely. To reset the visitor ID, clear this site's cookies
and site data in your browser. `install.sh` and ad-link click counts cannot be turned off.

**Advertising pixels.** We advertise Waycar on Reddit and X. To count how many
visitors from those ads reach the App Store, the site runs a conversion pixel
from each: scripts from Reddit, Inc. (`redditstatic.com`) and X Corp.
(`ads-twitter.com`) that load in your browser and record a page view on every
page, and a conversion when you click an App Store link. Each receives, among
other things, your IP address, browser user agent, the page address
(including, when you arrive from one of our ads, the ad's click ID from the
link (`twclid` or `rdt_cid`)), the page you came from, and the
identifiers it stores itself, in cookies or local storage on `waycar.dev` or
on its own domain. The scripts also read standard browser details, such as
your screen size and language. We send them no name, email address, or ID of
our own, and nothing else of ours. Reddit and X use this data under their own
privacy policies, including to measure and improve ads, which some US state
laws treat as "sharing" for cross-context behavioral advertising. The pixels
never load:

- if your browser sends a Global Privacy Control signal. If you choose
  "Allow" in "Cookie settings" anyway, that turns on PostHog's cookie, but
  the pixels still do not load;
- in the EU, the EEA, the UK, or Switzerland (or if your country cannot be
  determined, or you visit over Tor), until you choose "Allow"; or
- after you choose "Decline" in "Cookie settings" in the footer, anywhere.
  If they had already loaded, the page reloads and the site deletes the
  cookies they set on `waycar.dev`; cookies they keep on their own domains
  are cleared in your browser's settings.

Everywhere else they load from your first visit, without asking.

Where the site asks first, the cookie and the advertising pixels are used on
the basis of your consent. Cookieless counting, the cookieless choice of home
page version, the cookies in regions where the site does not ask, and the
advertising pixels in those regions, rely on our legitimate interest in
understanding how the site is used and measuring our advertising. Page
events go to PostHog, Inc. in the United States (PostHog US Cloud). PostHog
keeps them for as long as our PostHog plan retains them (1 year on
PostHog's free plan, 7 years on its paid plans) and may delete them after
that. We can't shorten that period, but you can ask us to delete your data
sooner. You can
withdraw consent with "Cookie settings" in the footer, object to the
processing, ask for your data to be deleted by emailing
[privacy@waycar.dev](mailto:privacy@waycar.dev), and complain to a data
protection supervisory authority.

## Children

Waycar is a tool for software developers and is not directed to children. We
do not knowingly collect personal data from children under 13, or under 16
where local law sets a higher age. If you believe a child has sent us personal
data, email [privacy@waycar.dev](mailto:privacy@waycar.dev) and we will delete
it.

## Your rights

If you are in the EU, the EEA, the UK, or Switzerland, we use app analytics on
the basis of your consent, which you give by choosing Allow and can withdraw
at any time in Waycar's Settings. Withdrawing does not affect analytics sent
before. The legal bases for the website are described under "This website".
Wherever you live, you can ask us for access to or deletion of personal data
we hold about you, and you can object to our processing, by emailing
[privacy@waycar.dev](mailto:privacy@waycar.dev). You may also complain to your
data protection authority. Data is processed in the United States by the
service providers above.

To opt out of the sale or sharing of your personal information (for example
under California law), use Global Privacy Control, choose "Decline" in "Cookie
settings" on the website, or email
[privacy@waycar.dev](mailto:privacy@waycar.dev). We treat a Global Privacy
Control signal as a valid opt-out of sale and sharing for that browser. We do
not use or disclose sensitive personal information beyond what the law
allows, and we do not knowingly sell or share the personal information of
anyone under 16.

## Changes to this policy

If this policy changes, we will update it here and change the date at the
top.

## Contact

Questions about this policy? Email
[privacy@waycar.dev](mailto:privacy@waycar.dev). Please do not include
sensitive information. You can also write to OTREVA, LLC, 9169 W State St
#1395, Garden City, ID 83714, USA. For help with the app, see
[waycar.dev/support](https://waycar.dev/support).
