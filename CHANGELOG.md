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

- Find Computers lists the computers on your Wi-Fi that have SSH on, such as
  a Mac with Remote Login. Tap one, sign in with its user name and password
  (or pair with a code to use a key), then check its host key.
- Find Computers also tries every address on your Wi-Fi, so computers that
  don't announce themselves show up too. If Local Network access is off, it
  says so and opens Settings.
- A computer you already added opens its Host. Pairing a found computer keeps
  its name.
- Add Your First Host now puts Scan Computers on My Network in the middle. Try
  the Sample is under it, and Set up by hand is folded at the bottom. Find
  Computers is also in Hosts › + › Find Computers.
- Some computers don't take a password. The Host page now says so and offers
  Scan Pairing Code: run the command it shows on that computer, scan the code,
  and the Host switches to this device's key.
- Add the Key Yourself shows one command that adds your key to a computer.
  Check Again then signs in with it.
- Zellij 0.46 or later is now a runtime. Its sessions, tabs and panes show in
  the Console. Status is live for agents that report it (Claude Code, Pi) or
  that use Waycar's hooks.
- In Zellij, open an agent's pane without moving your desk. Send messages and
  keys, rename and close, and start agents and shells in a session or a new
  one.
- Saved Zellij sessions are in Closed Sessions. Resume brings one back, and
  Delete asks first. You can hide Zellij on the Host page.
- Host Tools 2.6.0 send Blocked and Done notifications and Live Activity rows for
  agents in Zellij panes.
- Codex server threads show in the Console, Live Activities and Apple Watch.
  In Chat, send messages, stop a turn, approve commands and file changes, and
  answer questions.
- Unloaded Codex threads are in Closed Sessions, where Resume brings one back.
- Host Tools 2.4.0 notify you when Codex needs your OK or finishes, with its
  final reply.
- New Agent › Codex starts a named thread in a folder, with a first message
  and Chat Mode settings.
- If the Host also has a terminal runtime, a new Codex thread opens at your
  desk too. It stays one card: tap Show Terminal in Chat to see it.
- Start Codex server from New Agent or the Host's page. Checks never start it.
  On a Mac, it starts in your login session.
- Every OpenCode 2 session on a Host shows in the Console, Live Activities and
  Apple Watch, even ones you started at your desk. In Chat, send messages, stop
  a turn, approve commands and file changes, and answer questions.
- Swipe a finished OpenCode session to Archive it. Archived sessions are in
  Closed Sessions, where Resume brings one back.
- A desk terminal that shows an archived OpenCode session keeps running. It
  hides with the session and comes back with it.
- New Agent › OpenCode starts a named OpenCode 2 session in a folder, with a
  first message and Chat Mode settings.
- If the Host also has a terminal runtime, a new OpenCode session opens at
  your desk too. It still shows as one card.
- Start OpenCode server from New Agent or the Host's page. Checks never start
  it.
- Host Tools 2.5.0 notify you when an OpenCode 2 session needs your OK, asks a
  question or finishes, with its final reply.
- Tap a waiting agent in the Console to queue more messages, images and files
  while offline. They go out in order once it starts.

### Changed

- Agent cards are shorter. The line above an agent's details is gone, the
  spacing is tighter, and the AI summary is one smaller line. More agents fit
  on screen.
- After CarPlay introduces an agent, it now asks for your question in a few
  different ways.

### Fixed

- Opening, closing or restyling a terminal no longer risks a crash while the
  screen around it is still updating. This was seen on iPad.
- Waycar no longer starts Herdr TUI or Herdr Core on its own. If one is installed
  but not running, after a Mac restart for example, the Host's row in the
  Console and its Host page say so. Tap Start Herdr TUI or Start Herdr Core. (refs #389)
- On a Mac, Herdr TUI and Herdr Core start in your login session, so agents
  keep Keychain access.
- A herdr session that doesn't exist on the Host now says so. Checks and
  errors name Herdr TUI or Herdr Core, so you can tell which one is down and
  which is still connected.
- A short command Waycar runs on a Host, such as a check or a tmux or Codex
  action, no longer waits out its whole time limit. This happened when its
  output and its end came at the same moment.
- Checking a Host no longer stalls when one of its programs never answers.
  One example is a Codex that macOS hasn't approved yet. Waycar waits a few
  seconds and goes on, and the Host's page names the program that didn't
  answer.
- Turning Herdr Core, tmux or Zellij back on for a Host turns its notifications
  back on too, even when that restarts the Host's connection.
- A notification you tapped before its agent showed up no longer opens that
  agent later, once you have opened another agent and come back to the
  Console.
- A Done notification is no longer skipped when the agent starts its next turn while
  the last one is still being sent. Update Host Tools to 2.3.1 to get this.
- A Live Activity update can no longer undo turning notifications off. The switches
  stay locked while a change saves, and a change that fails shows what the
  Host really has.
- Turning notifications off in iOS Settings now shows in Waycar. Hiding tmux and
  herdr-core sessions one right after the other saves both choices.
- A Host's Live Activity no longer shows twice on the Lock Screen. When iOS
  ends one after 8 hours, Waycar clears it instead of leaving it frozen beside
  the new one.
- A computer you added twice, by two addresses, gets one Live Activity.
- A Live Activity that failed to start is tried again when you come back to
  Waycar. A new push token is no longer lost when you change pins or the
  layout at the same time.
- If the answer to a start is lost, Waycar checks the Host when it reconnects.
  It uses the agent it already started, or starts it. You get no second agent
  and nothing to confirm.
- New herdr agents avoid names that another agent or tab on the Host already
  uses.
- An agent you started while its Host was offline starts as soon as the Host
  connects, even if you tapped Start just as it came back.
- Tapping Start just after your phone loses its connection keeps the agent
  waiting, with its first message, until the Host is back. It no longer fails
  with "The Host is not connected."
- A waiting message whose files failed to upload stays failed after you
  reopen Waycar, until you tap Retry.
- Waiting messages go out once the agent's question is answered, even if it
  was answered while one was being sent.
- Editing a queued message, or one that failed to get ready, keeps all of its
  attachments, even when other files already fill the tray.
- Switching to another Host while a new agent's attachments get ready no
  longer starts the agent in the other Host's workspace.
- After you install Herdr Core, New Agent says it found herdr-core, not tmux.
- New Agent no longer stays on Starting when the agent you picked goes away
  from the Host while Waycar looks up its home folder.
- In New Agent, while Waycar checks for a worktree it asked for, the banner
  says "Checking for the worktree the Host made". It no longer names herdr on
  Hosts that don't use it.
- An agent you name in New Agent keeps that name on a Herdr Core Host. It no
  longer shows its kind.
- On Herdr Core, an agent you had already seen finish shows its next turn
  again. It no longer stays Idle.
- A prompt to a herdr-core agent that finishes right after it is no longer
  reported as failed and sent again.
- Ultimate conversations no longer flip back to an older state while they reconnect.
- Hosts keep reporting the status of new panes when the pane list changes
  during a reconnect. An agent no longer stays on Connecting after its Host
  fails.
- On tmux, a status change right after connecting is no longer missed. An
  agent started in the same pane as another no longer shows the old one's
  status.
- On tmux, an old session that ends no longer clears the new session in the
  same pane. A late tool event no longer turns a finished agent back to
  Working. A turn's Done is no longer lost when a tool event arrives at the
  same time. This needs Host Tools 2.6.1.
- A Host's agent list on tmux no longer jumps back to an older state when two
  refreshes overlap.
- Two quick messages to a gemini, cline or hermes agent on tmux now go out as
  two messages, not one.
- Status Hooks no longer show as missing when another tool, such as
  agent-deck, adds its own hooks next to Waycar's. Updating Waycar's hooks
  leaves the other tool's hooks alone.
- Host details and New Agent no longer say the Codex or OpenCode server is not
  running while it starts.
- Stop in a Codex chat no longer goes to a turn that had just ended.
- Cancelling an approval in an OpenCode chat no longer marks the session Done.
- In New Agent, retrying an OpenCode chat whose setup failed finishes that
  chat. It no longer makes a second one.
- With Host Tools 2.4.1, an OpenCode 2 chat shows its history, images
  included. Reading it never starts a stopped OpenCode server.
- When the desk terminal of an archived OpenCode chat starts a new session,
  that session's card now opens the terminal with Show Terminal. The terminal
  no longer stays hidden.
- Opening a chat on OpenCode, Kilo or Hermes no longer hangs past its time
  limit when the chat export leaves a program running in the background.
- A question card in Chat says Sent only once your answer arrives. If the
  answer fails, you can send it again.
- A chat refresh that gets cut off no longer pauses the offline copies of a
  Host's chats for ten minutes.
- Chats keep refreshing in the background after you come back to Waycar.
- In Chat, switching to the terminal and back can no longer send one approval
  twice.
- In CarPlay, when an agent replaces a question while it is being read out,
  the old question can no longer be allowed.
- CarPlay says Checking… until your answer is sent, and only then says Done.
  It no longer says Done for an answer that was queued, kept as a draft or
  failed.
- CarPlay no longer says "Nothing was sent" about an approval that was being
  sent. Leaving CarPlay right after you pick an agent no longer keeps the
  car's audio.
- On Apple Watch, an approval from an earlier turn no longer comes back when
  the agent asks again, and the new one loads. The result of an old approval
  no longer replaces the buttons of a new question.
- On Apple Watch, Checking… no longer stays under an older reply in Latest
  after the check ends.
- Reopening the Apple Watch recorder for the same agent is no longer closed by
  the old recorder's timer. If something interrupts while the watch asks for
  the microphone, the recording is cancelled instead of starting later.
- The notice to update Waycar on your iPhone or watch no longer goes away when
  older data comes from the iPhone.
- Dictation you cancel can no longer be sent or kept.
- When saved Snippets can't be read, the keyboard says Snippets Unavailable.
  It no longer shows an empty list.
- If the Skills list fails to refresh, it says so above the list it keeps,
  with Retry.
- Preview opens the file the confirmation named, even if the agent changed
  folders since.
- After you allow camera access in Settings, pairing no longer says access is
  denied.
- A time limit in the background that runs out just after you come back no
  longer drops your open connections.
- Turning iCloud Sync off while it checks your Hosts stops that check. It no
  longer finishes or reconnects your Hosts later.
- A synced setting that you reset and then change on two devices keeps this
  device's choice. Syncing Agent List fields for two Hosts at once keeps both.
- Turning a Host off while it connects no longer installs Status Hooks or runs
  a mosh test later. Turning it off while its checks run stops them.
- Editing a Host's address clears the mosh test result for the old address.
- After you change a Host's address, a late answer from the old address no
  longer replaces what Waycar knows about the new one.
- When two checks of a Host overlap, the install panel keeps the newer one.
- When you add a Host, a host key question that shows up just as an earlier
  check is cancelled is no longer turned down on its own.
- In Closed Sessions, backing out of an earlier resume no longer closes the
  session you resumed after it.
- After a quick network blip, Waycar waits for the new network to settle
  before it reconnects.
- Closing a connection through a Jump Host no longer hangs past its time
  limit.
- An agent's terminal on herdr no longer opens on a connection Waycar has
  already dropped. That could keep the agent's pane at your phone's size.
- If you used a herdr Host while it was reconnecting, the next time its
  connection dropped could go unshown. Now it shows Reconnecting like any
  other drop.
- Leaving an agent while its terminal switches from mosh to SSH no longer
  opens the terminal once more on the Host later.
- The terminal says Connecting as soon as you tap Use SSH Instead. A second
  tap no longer reconnects it twice.
- After Waycar falls back to SSH, Retest and Upgrade Sessions tests mosh again.
  If mosh works, it moves the Host's sessions to it.
- An agent's last screen saved while your iPhone was locked now still shows
  after Waycar restarts.
- AI Usage on a Mac with the Keychain Fix now waits for the CodexBar helper
  when one provider is slow to read, such as Claude. It no longer shows that
  provider as "Couldn't refresh". Fix it for me also gives the helper enough
  time for Claude.
- When an existing Keychain Fix helper gives up on Claude too soon, AI Usage
  says so and offers Fix it for me. It updates the helper to wait longer.
- On a Mac without the helper, newer CodexBar versions get the Fix it for me
  offer again, instead of "Couldn't refresh".
- Settings › About › Acknowledgements now credits FreeType, libpng, stb, herdr
  and the other open-source code in Waycar.
- Acknowledgements now has the full NeMo text-processing credits, and a libintl
  relinking offer for Waycar 1.0.1 and 1.0.2.
