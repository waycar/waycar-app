# Build Waycar to your own iPhone

Exact steps for an AI coding agent (a person can follow them too) to install
Waycar from this repository on someone's own iPhone, from their own Mac,
signed with their own Apple Account. A free Apple Account works. A paid Apple
Developer Program membership works the same way, without the free limits.

Steps marked **Person** need hands on the Mac or the phone: ask for them,
say exactly what to tap, and wait for the answer. Run everything else
yourself, in Terminal on that Mac.

Tell the person up front what they get: the same app as the App Store's,
installed beside it as a separate app (both are called Waycar). It starts
empty: Hosts paired in the App Store app don't carry over. Notifications,
Live Activities and CarPlay don't work in a build of your own
([What doesn't work](#what-doesnt-work-in-your-own-build)). With a free
account the install stops opening after 7 days until you run it again.

## 1. Check the Mac

```sh
xcodebuild -version    # Xcode 27 or later
xcode-select -p        # /Applications/Xcode.app/Contents/Developer
xcodegen --version     # 2.42.0 or later
git --version && python3 --version && make --version | head -1
```

Fix whatever fails, then check again:

- **No Xcode, or older than 27** (**Person**): install Xcode from the Mac
  App Store, open it once, and install the iOS and watchOS components it
  offers (Waycar includes a Watch app). Its App Store page lists the macOS
  version it needs.
- **`xcode-select -p` prints `/Library/Developer/CommandLineTools`**:
  `sudo xcode-select -s /Applications/Xcode.app`.
- **First use of Xcode on this Mac**: `sudo xcodebuild -license accept` and
  `sudo xcodebuild -runFirstLaunch`. `sudo` asks the **Person** for their
  Mac password.
- **No `xcodegen`**: `brew install xcodegen`. Without Homebrew, the
  **Person** installs it from <https://brew.sh> first. `git`, `python3` and
  `make` come with Xcode.

The first build downloads Swift packages from GitHub; leave about 10 GB of
disk free for it.

## 2. Get the code

```sh
git clone https://github.com/waycar/waycar-app.git
cd waycar-app
```

Skip this if you're already in a checkout. Every command below runs from its
root.

## 3. Sign in to Xcode and find the Team ID

**Person:** in Xcode, choose **Xcode › Settings › Apple Accounts**, click
**+**, choose **Apple Account** and sign in. A free account shows one team,
"*Their Name* (Personal Team)".

Then read the Team ID, ten letters and digits such as `ABCDE12345`:

```sh
defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier \
    | grep -E 'teamID|teamName|teamType|isFreeProvisioningTeam'
```

Each team prints its `teamID`, `teamName` and `teamType`.
A free account's team reads `teamType = "Personal Team"` and
`isFreeProvisioningTeam = 1`. When several teams show, ask the
**Person** which one to use. Nothing printed means Xcode has no account yet:
go back to the sign-in. This list is Xcode's cache and can outlive a
sign-out, so if the build later stops at `No Accounts`, the account is no
longer signed in: sign in again.

## 4. Pair the iPhone

Xcode 27 pairs phones in **Device Hub**. It has no "Connect via network"
checkbox: a paired phone on the same Wi-Fi as the Mac connects by itself.

**Person**, on the Mac: open Device Hub from the run destination menu
(**Manage Devices…**) or **Xcode › Open Developer Tool › Device Hub**. Then
either:

- **iOS 27 or later, wirelessly:** put the iPhone on the Mac's Wi-Fi
  network, click **+** in Device Hub's toolbar, choose **Pair Nearby
  Device…**, pick iPhone and follow the instructions. If the Mac asks to
  allow finding devices, click **Allow**.
- **Any iOS, with a cable** (needed before iOS 27): connect the iPhone to
  the Mac, select it in Device Hub's sidebar and click **Pair** if it
  appears. Afterwards the cable can go: the phone connects over Wi-Fi.

On the iPhone, tap **Trust** in "Trust This Computer?" and enter the
passcode. If it asks for Developer Mode: **Settings › Privacy & Security ›
Developer Mode** (the switch appears only once pairing has started), turn it
on, tap **Restart**, and after the restart tap **Enable** and enter the
passcode. If the phone doesn't show up after Trust, restart it. After an iOS
update, pair it again.

Then check from Terminal:

```sh
xcrun devicectl list devices
```

The iPhone's row reads `physical` and `connected` (or `available (paired)`).
Its **UDID** is the value marked `(UDID)` in the Identifier column, such as
`00008110-001234567890801E`. Check Developer Mode with:

```sh
xcrun devicectl device info details --device <UDID> | grep 'Developer Mode'
```

It must read `Enabled`.

## 5. Build and install

```sh
make install TEAM=<Team ID> DEVICE=<UDID>
```

Pass `TEAM` on make's command line, as here: an exported `TEAM` environment
variable is ignored. This one command:

- regenerates `Waycar.xcodeproj` from `project.yml` (`git status` may then
  show it changed: expected, never commit it);
- builds the Debug app signed by that team, under bundle IDs of its own:
  `com.<team id in lowercase>.waycar` for the app, the same plus
  `.NotificationService`, `.Widgets` and `.watchkitapp` for the extensions
  and the Watch app, and `group.<app's bundle ID>.shared` for the app group;
- leaves out the push and CarPlay entitlements, which only Waycar's own team
  can use;
- registers the iPhone, the App IDs and the app group with the team, and
  makes the development profiles (`-allowProvisioningUpdates`);
- installs the app on the iPhone and opens it.

The first build takes 10 to 30 minutes; later ones are much quicker. To
choose the bundle ID yourself, add `BUNDLE_ID=com.<something unique>.waycar`;
keep it the same from then on (see the App ID limit below).

While it runs:

- If macOS asks whether `codesign` may use a key in the keychain, the
  **Person** enters their Mac login password and clicks **Always Allow**.
- Run it in a Terminal of the person's logged-in session. Over SSH, signing
  fails with `errSecInternalComponent`.
- `NOTES=` is the maintainers' What's New for their shared test devices; you
  don't need it.

It worked when the output shows `App installed:` and then either the launch
or `Installed, but the launch was refused`. The second is expected the first
time with a free account; the next step fixes it.

## 6. Trust the developer (free account, first install)

**Person**, on the iPhone: **Settings › General › VPN & Device Management**,
under Developer App tap **Apple Development: *their Apple Account***, tap
**Trust "Apple Development: …"** and confirm. Then open Waycar from the Home
Screen. To add a computer, run the install command on it
(<https://waycar.dev/help/install>) and scan its Pairing Code, as with the
App Store app (<https://waycar.dev/help/pairing>).

## Updating and renewing

```sh
git pull
make install TEAM=<Team ID> DEVICE=<UDID>
```

Reinstalling keeps the app's data. With a free account the profile expires
7 days after the install, and the app stops opening: run the same command to
renew it.

For an iPad, pair it the same way and run
`make install-ipad TEAM=<Team ID> DEVICE_IPAD=<iPad UDID>`.

Use `make`, not Xcode's Run button: the project itself signs with Waycar's
own team and entitlements, and only the `TEAM` path swaps in yours.

## What doesn't work in your own build

| Feature | In your build |
| --- | --- |
| Notifications (Blocked, Done) | No. Waycar's Push Relay delivers only to Waycar's own bundle ID, and a free account has no push at all. |
| Live Activities | No: they are updated by push. |
| CarPlay | No. Apple turns its voice-conversation capability on per team, and only Waycar's team has it. |
| iCloud Sync | Only between copies of your build signed by the same team with the same bundle ID; never with the App Store app. Not tried yet. |
| Apple Watch app | Built and embedded; to run it, the watch needs pairing in Device Hub with Developer Mode on, like the iPhone. Not tried with a build of your own. |
| Everything else | Works: the Console, terminals, the Composer, Chat Mode, pairing, mosh, Jump Hosts, Dictation. |

## Free Apple Account limits

- **7 days:** each install's profile expires after a week. Run
  `make install …` again before or after it does.
- **3 apps:** a phone runs at most three apps from free teams at once.
  Delete one to make room.
- **10 App IDs per 7 days:** Waycar uses four (the app, its two extensions
  and the Watch app). Each new `BUNDLE_ID` spends four more, so keep one.
- **Capabilities:** Apple's table lists App Groups and Keychain Sharing
  for free teams, which your build keeps, but not Push Notifications, Time
  Sensitive Notifications or iCloud containers
  ([Apple's table](https://developer.apple.com/help/account/reference/supported-capabilities-ios)).
  A free team's App Groups have not been tried with this build yet.

## Troubleshooting

| What you see | Fix |
| --- | --- |
| `No physical iPhone found; pass DEVICE=<device identifier>` | Pass `DEVICE=<UDID>` from `xcrun devicectl list devices`; if the phone isn't listed, pair it (step 4). |
| `No Accounts: Add a new account in Accounts settings.` (with `No profiles for '…' were found`), `No Account for Team "…"`, or `Signing for "Waycar" requires a development team` | Xcode has no signed-in account for that team: sign in (step 3) and use a `teamID` it lists. |
| `Personal development teams … do not support the Push Notifications capability`, or a profile missing `aps-environment` or CarPlay | The build ran without `TEAM`, or from Xcode's Run button: use `make install TEAM=…`. |
| `… is not available` or `cannot be registered to your development team` (bundle ID or app group) | Another team has that ID: add `BUNDLE_ID=com.<something unique>.waycar`. |
| `Your maximum App ID limit has been reached` | The free account made 10 App IDs this week: wait for the oldest to expire, or go back to the `BUNDLE_ID` you used before. |
| `Provisioning profile … doesn't include the currently selected device` | Make sure the phone is `connected` in `xcrun devicectl list devices` and run `make install` again; it registers the phone. |
| `Developer Mode disabled` | Turn on Developer Mode (step 4). |
| `Installed, but the launch was refused` | First time with a free account: trust the developer (step 6). Otherwise the phone was locked: unlock it and open Waycar. |
| `… has not been explicitly trusted by the user` or "Untrusted Developer" on the phone | Trust the developer (step 6). |
| `The maximum number of apps for free development profiles has been reached` | Delete another app installed from a free team, then run `make install` again. |
| The app stopped opening after a week | The free profile expired: run `make install …` again. |
| `errSecInternalComponent` while signing | The build ran over SSH or outside the logged-in session: run it in the person's Terminal. |
| A message that the iOS or watchOS platform is not installed | `xcodebuild -downloadPlatform iOS`, then `xcodebuild -downloadPlatform watchOS`, or **Xcode › Settings › Components**. |

## How it works

`TEAM` makes `make build`, `make build-device`, `make install` and
`make install-ipad` pass three build settings to `xcodebuild`:
`DEVELOPMENT_TEAM`, `WAYCAR_BUNDLE_ID` (`BUNDLE_ID`; `project.yml` derives
every target's bundle ID and the app group from it), and
`WAYCAR_APP_ENTITLEMENTS=Sources/Waycar/WaycarSelfBuild.entitlements`, which
keeps only the app group. Without `TEAM` nothing changes. The Makefile's
self-build block and `project.yml`'s `WAYCAR_BUNDLE_ID` are the code.

Last checked 2026-11-13 with Xcode 27.2 on macOS 27.2: the default build
signs and validates unchanged, and `TEAM` gives every target its own bundle
ID, the app group follows and push and CarPlay are gone. Signing, installing
and opening a build under a free team are not checked end to end yet: the
build Mac had no Apple Account signed in to Xcode.
