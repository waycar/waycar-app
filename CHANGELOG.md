# Changelog

All notable changes to Waycar are documented here first: unreleased entries
go under [Unreleased] below. `make publish` moves them into
`apps/web/src/content/changelog/<version>.md`, one file per release, and
each release since 1.0.1 is published at waycar.dev/changelog and in
Settings › About › Changelog.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries reference the issue that motivated them.

## [Unreleased]

### Added

- **Find Computers**: Add Your First Host now starts with Scan Computers on
  My Network (also in Hosts › + › Find Computers), and Set up by hand folds
  away until you open it. The scan lists the computers on your Wi-Fi that have
  SSH on, such as a Mac with Remote Login on. Tap one, sign in with its username and password (or pair with a code to use a key), and confirm
  its host key. The scan also tries every address on your Wi-Fi, so computers
  that don't announce themselves show up too. If Local Network access is off,
  Find Computers says so and opens Settings.
- **Keys-only computers**: when a computer doesn't accept password sign-in,
  its Host page says so and shows one command to run on it that adds this
  device's key; Check Again then signs in with the key.
- **Zellij**: Zellij 0.46 or later is a runtime. Its sessions, tabs and panes
  appear in the Console with live status from agents that report it (Claude
  Code, Pi) or from Waycar's hooks. Open an agent's pane without moving your
  desk, send messages and keys, rename and close, and start agents and shells
  in a session or a new one. Saved Zellij sessions are in Closed Sessions:
  Resume brings one back, Delete asks first. Hide Zellij on the Host page.
- **Zellij notifications**: Host Tools 2.6.0 send Blocked and Done
  notifications and Live Activity rows for agents in Zellij panes.
- **Codex chats**: Codex server threads appear in the Console, Live Activities
  and Apple Watch. Send messages, stop turns, approve commands and file changes,
  and answer questions in Chat. Resume unloaded threads from Closed Sessions.
  Host Tools 2.4.0 adds notifications when Codex needs your OK or finishes,
  with its final reply.
- **New Agent › Codex**: start a named thread in a folder, with a first message
  and Chat Mode settings. On Hosts with a terminal runtime, the same session
  opens at your desk too, and still shows as one card: open its terminal with
  Show Terminal in Chat. Start Codex server from New Agent or the Host's page;
  checks never start it. On a Mac, it starts in your login session.
- **OpenCode chats**: every OpenCode 2 session on a Host appears in the
  Console, Live Activities and Apple Watch, including ones you started at your
  desk. Send messages, stop turns, approve commands and file changes, and
  answer questions in Chat. Swipe to Archive a finished session; archived
  sessions are in Closed Sessions, where Resume brings one back. A desk
  terminal showing the session keeps running, hidden with it, and comes back
  with it.
- **New Agent › OpenCode**: start a named OpenCode 2 session in a folder, with
  a first message and Chat Mode settings. On Hosts with a terminal runtime, the
  same session opens at your desk too, and still shows as one card. Start
  OpenCode server from New Agent or the Host's page; checks never start it.
- **OpenCode 2 notifications**: Host Tools 2.5.0 notify you when an OpenCode 2
  session needs your OK, asks you a question or finishes, with its final reply.
- **Waiting agents**: tap a waiting agent in the Console to queue more
  messages, images and files offline. They go out in order once it starts.

### Fixed

- **Hosts with a program that never answers**: checking a Host no longer
  stalls when one of its programs never answers, such as a Codex that macOS
  hasn't approved yet on a Mac you reach over SSH. Waycar gives it a few
  seconds, carries on with the rest, and the Host's page says which one
  didn't respond.
- **Notification taps**: a tapped notification whose Agent had not shown up
  yet no longer opens that Agent later, once you have opened another Agent
  and come back to the Console.
- **Queued messages**: editing a queued message, or one whose preparation
  failed, keeps all of its attachments, even when other files already fill
  the tray.
- **Snippets**: when the saved Snippets can't be read, the keyboard says
  Snippets Unavailable instead of showing an empty list.
- **Dictation**: dictation you cancel can no longer be sent or kept
  afterwards.
- **CarPlay approvals**: when an Agent replaces a question while CarPlay is
  still reading it out, the old question can no longer be allowed.
- **Apple Watch approvals**: an approval from an earlier turn no longer comes
  back on the watch when the Agent asks again, and the new one loads.
- **Skills**: a failed refresh of the Skills list now says so, with Retry,
  above the list it keeps.
- **Returning to Waycar**: a background time limit that runs out just after
  you come back no longer drops your open connections.
- **iCloud Sync**: turning sync off while it is checking your Hosts stops
  that check from finishing or reconnecting your Hosts afterwards.
- **CarPlay approvals**: CarPlay says Checking… until your answer is
  confirmed sent, and shows Done only then, not for an answer that was queued,
  kept as a draft or failed.
- **Apple Watch Latest**: Checking… no longer stays under an older reply once
  the recheck has ended.
- **Apple Watch recording**: reopening the recorder for the same Agent is no
  longer closed by the earlier recorder's timer, and an interruption while the
  watch asks for microphone access cancels the recording instead of starting
  it later.
- **Apple Watch**: the notice to update Waycar on your iPhone or watch no
  longer disappears when older data from the iPhone arrives.
- **New Agent**: switching to another Host while a launch prepares its
  attachments no longer starts the Agent in the other Host's workspace.
- **New Agent**: after you install Herdr Core, New Agent says it found
  herdr-core instead of tmux.
- **Hosts**: turning a Host off while it connects no longer installs Status
  Hooks or runs a mosh test afterwards.
- **Host form**: editing a Host's address clears the mosh test result for
  the old address.
- **Install**: when two checks of a Host overlap, the install panel keeps
  the newer one.
- **Codex and OpenCode**: Host details and New Agent no longer say the server
  is not running while it starts.
- **Pairing**: after you allow camera access in Settings, pairing no longer
  says access is denied.
- **Chat**: an interrupted transcript refresh no longer pauses the offline
  copies of a Host's chats for ten minutes.
- **Chat questions**: a question card says Sent only once your answer was
  delivered; an answer that failed can be sent again.
- **Hosts**: after you change a Host's address, a late answer from the old
  address no longer replaces what Waycar remembers about the new one.
- **Closed Sessions**: backing out of an earlier resume no longer closes the
  session you resumed after it.
- **Herdr Core**: an Agent you had already seen finish shows its next turn
  again, instead of staying Idle.
- **tmux**: a Host's Agent list no longer briefly falls back to an older
  state when two refreshes overlap.
- **New Agent › worktree**: while Waycar checks for a worktree it asked for,
  the banner says "Checking for the worktree the Host made" instead of naming
  herdr on Hosts that don't use it.
- **Codex chats**: Stop no longer goes to a turn that had just finished.
- **OpenCode chats**: cancelling an approval no longer marks the session
  Done.
- **New Agent › OpenCode**: retrying a chat whose setup failed finishes that
  chat instead of creating a second one.
- **Network changes**: after a quick network blip, Waycar no longer
  reconnects before the new network has settled.
- **Jump Hosts**: closing a connection through a Jump Host no longer hangs
  past its time limit.
- **Chats on OpenCode, Kilo and Hermes**: opening a chat no longer hangs past
  its timeout when the export leaves a background process running.
- **tmux status**: an old session ending no longer clears the session that
  replaced it in the same pane, a late tool event no longer turns a finished
  Agent back to Working, and a turn's Done is no longer lost when it races a
  tool event. Needs Host Tools 2.6.1.
- **AI Usage on a Mac with the Keychain Fix**: Waycar now waits for the
  CodexBar helper when one provider is slow to read, such as Claude, instead
  of showing that provider as "Couldn't refresh". Fix it for me now gives
  the helper enough time for Claude as well.
- **AI Usage: Claude timed out**: when an existing Keychain Fix helper gives
  up on Claude too soon, AI Usage says so and offers Fix it for me, which
  updates the helper to wait longer. On a Mac without the helper, newer
  CodexBar versions again get the Fix it for me offer instead of
  "Couldn't refresh".
- **OpenCode 2 chats**: with Host Tools 2.4.1, an OpenCode 2 agent's chat
  shows its history, image attachments included. Reading it never starts a
  stopped OpenCode server.
- **Status Hooks beside other tools**: Status Hooks no longer show as
  missing for an agent when another tool, such as agent-deck, added its own
  hooks next to Waycar's. Updating Waycar's hooks leaves the other tool's
  hooks where they are.
- Acknowledgements now includes complete NeMo text-processing credits and a libintl relinking offer for Waycar 1.0.1 and 1.0.2.
- Settings › About › Acknowledgements now credits FreeType, libpng, stb, herdr and the other open-source code inside Waycar.
- **Herdr TUI and Herdr Core after a restart**: Waycar no longer starts
  either on its own. When one is installed but not running, after a Mac
  restart say, the Host's row in the Console and its Host page say so: tap
  Start Herdr TUI or Start Herdr Core. On a Mac it starts in your login
  session, so agents keep Keychain access.
  A herdr session that doesn't exist on the Host now says so. Checks and
  errors name Herdr TUI or Herdr Core, so it's clear which one is down and
  which is still connected. (refs #389)
- **Live Activities**: a Host's Live Activity no longer shows up twice on
  the Lock Screen. When iOS ends one after its 8-hour limit, Waycar now
  clears it instead of leaving it, frozen, beside the new one. A computer
  you added twice, by two addresses, gets one Live Activity.
- **Interrupted starts**: if a start's answer is lost, Waycar checks the
  Host when it reconnects and uses the agent it already started, or starts
  it. No duplicate agent, nothing to confirm. New herdr launches also avoid
  names already used by another agent or tab on the Host.
- **Done notifications**: a Done notification is no longer skipped when the
  agent starts its next turn while the previous one is still being sent.
  Update the Waycar Host Tools on your Hosts to 2.3.1 to get it.
- **Waiting launches and messages**: an agent you started while its Host was
  offline starts as soon as the Host connects, even when you tapped Start
  just as it came back. A waiting message whose files failed to upload stays
  failed after you reopen Waycar, until you tap Retry. Waiting messages go
  out once the agent's question is answered, even when it was answered while
  one was being sent.
- **New Agent offline**: tapping Start just after your phone lost its
  connection now keeps the agent waiting until its Host is back, with its
  first message, instead of failing with "The Host is not connected."
- **Agent names on Herdr Core**: an agent you name in New Agent keeps that
  name in Waycar on a Herdr Core Host, instead of showing its kind.
- **Quick messages on tmux**: two messages sent to a gemini, cline or hermes
  agent on tmux in quick succession now go out as two messages, not one.
- **New Agent**: the sheet no longer stays on Starting when the agent you
  picked disappears from the Host while Waycar looks up its home folder.
- **Agent status**: Hosts keep reporting the status of new panes when the
  pane list changes during a reconnect, and an agent no longer stays on
  Connecting after its Host fails. On tmux, a status change right after
  connecting is no longer missed, and an agent started in the same pane as
  another no longer shows the old one's status.
- **Notification settings**: a Live Activity update can no longer undo
  turning notifications off, the switches stay locked while a change is
  saved, a change that fails shows what the Host really has, and turning
  notifications off in iOS Settings now shows in Waycar. Hiding tmux and
  herdr-core sessions in quick succession saves both choices.
- **Live Activities**: a Live Activity that failed to start is tried again
  when you return to Waycar, and a new push token is no longer lost when you
  change pins or the layout at the same time.
- **mosh**: after Waycar fell back to SSH, **Retest and Upgrade Sessions**
  tests mosh again and switches the Host's sessions to it when it works.
- **Approvals**: on Apple Watch, the result of an earlier approval no longer
  replaces the buttons of a new question. In Chat, switching to the terminal
  and back can no longer send one approval twice. CarPlay no longer says
  "Nothing was sent" about an approval that was being sent, and leaving
  CarPlay right after picking an agent no longer keeps the car's audio.
- **File links**: Preview opens the file the confirmation named, even when
  the agent changed folders meanwhile.
- **herdr-core and Ultimate**: a prompt to a herdr-core agent that finishes
  right after it is no longer reported failed and sent again, and Ultimate
  conversations no longer flip back to an older state while reconnecting.
- **Settings**: a synced setting you reset and then change on two devices
  keeps this device's choice, syncing Agent List fields for two Hosts at
  once keeps both, and turning a Host off while its checks run stops them.
- **Chat**: chat transcripts keep refreshing in the background after you
  return to Waycar.
