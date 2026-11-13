# Moving iOS CI off macOS: feasibility (2026-10-18)

Question: can `ci.yml` (build and test) run on Linux runners, and how much of it can leave the Mac?

Answer: the simulator build and test jobs need a Mac. No Linux tool runs an iOS Simulator or builds an Xcode project. Some steps and some pure-logic tests can move to Linux. The larger win needs a refactor.

> **Superseded in part, 2026-11-13.** Since the open-source cut every workflow in this
> repository runs on GitHub-hosted runners: `ci.yml` on GitHub's Xcode 27 image, the Linux
> jobs on `ubuntu-latest`. No Waycar CI runs on a self-hosted Linux runner any more. Section 2
> and the open questions describe the layout as this research found it.

Status labels: **verified** = read in this repo or in a fetched doc. **inferred** = reasoned, not run. **unverified** = third-party claim, no primary source.

## 1. Linux ports of iOS build and test

| Tool | What it does | Fit for Waycar |
|---|---|---|
| [xtool](https://github.com/xtool-org/xtool) | Builds a SwiftPM package into an iOS `.ipa` on Linux; signs and installs to a device. Its docs also list app extensions, entitlements, Info.plist, icon and resources (verified from xtool.sh). | No. Needs a SwiftPM project (Waycar is `Waycar.xcodeproj`). No test runner and no simulator in its docs (verified: docs cover build, sign, install, device only). Needs a user-supplied `Xcode.xip` to generate the SDK. The author's May 2025 forum post lists asset catalogs and Interface Builder as unsupported (unverified for current xtool; docs not checked for catalog support). We use `.xcassets` (verified). |
| darwin-vm (QEMU) and similar | Research emulation of iOS/macOS | No. Not usable for CI. |
| [Argent Cloud](https://docs.swmansion.com/argent/docs/cloud/integrations/github-actions) | `ubuntu-latest` job drives a remote hosted simulator | No. Paid, still runs on a Mac elsewhere, UI flows only, and the doc says the `.app` build "still needs a Mac". |
| Plain `swift test` on Linux | Runs Foundation-only Swift code | Yes, for code with no Apple framework dependency. This is the realistic route. |

License note (**unverified**): a forum commenter quotes (second-hand; the license text itself was not read) the Apple Developer Program License Agreement as barring use of the Apple SDKs on non-Apple hardware. The xtool author replies he is not a lawyer. Nobody has checked this for us. Treat as a risk to be reviewed before any Linux build that uses Apple's SDK. Plain `swift test` on Linux does not use the Apple SDK.

## 2. Current CI layout (verified)

- `ci.yml`: three jobs, all on the self-hosted Mac (`[self-hosted, macOS, ARM64, waycar]`): `build-test`, `waycarssh-package-e2e`, `swiftmosh-package`.
- `ci-node.yml`: Linux (`[self-hosted, Linux]`). Plugin, relay, codegen drift.
- `tmux-distros.yml`: GitHub-hosted `ubuntu-latest`, because the self-hosted Linux runners have no Docker (AGENTS.md). So a `container:` job such as `swift:6` cannot run on the self-hosted Linux runner. Install Swift there with swiftly, or use billed `ubuntu-latest`.
- Billing is not the driver: the Mac is self-hosted. Linux would reduce load and queue time on the developer's shared Mac.

## 3. Candidate moves

### 3a. Mac-free steps in `build-test` (inferred; needs a run on Linux)

Candidates (not run on Linux): `scripts/test-vps-ssh-access-scripts.sh`, `scripts/test-whats-new.py`. A first grep for Mac tools showed none in `test-whats-new.py` and one hit in the VPS script; the grep was noisy (it matched help text), so do not use it as proof. Run both on Linux to confirm.

Keep on the Mac:
- `scripts/test-sim-slot.sh`, `test-run-with-timeout.sh`: they test `sim-slot.py` and `run-with-timeout.py`, which only run on the Mac (simctl, BSD `ps`). Testing them on Linux trades fidelity for seconds.
- `make verify-ssh-artifacts`: calls `otool`, `codesign`, `xcrun nm` on xcframeworks. Moving it needs `llvm-otool`/`rcodesign` equivalents; low value.

### 3b. SwiftMosh on Linux: adds coverage, frees no Mac time (verified)

An earlier draft recommended this as a way to move a job. That was wrong.

- The app links `MoshCore` (`project.yml`).
- Shipped code is Apple-only: `MoshCryptoOCB/AES128.swift` imports CommonCrypto (`CCCrypt`), `MoshCompression/CompressionAdapter.swift` uses `compression_stream`, `MoshTransport/UDPTransport.swift` uses `NWConnection`, and its tests fake `NWConnection.State`/`NWError`.
- A Linux port with `#if canImport` would test substitute AES/zlib backends that never ship, and transport code would compile out.
- So the macOS `swiftmosh-package` job must stay. A Linux job would add a second implementation inside vendored, patched code (ADR 0021).
- It becomes a real move only if both platforms share one portable backend (OpenSSL or swift-crypto AES, zlib). That changes shipped code and is a Waycar patch to record in `PROVENANCE.md`.

### 3c. Extract a Foundation-only core package (inferred; the main prize)

- Rough count: 267 of 359 test files import no Apple-only framework (a name-based grep, not a build check).
- Nearly all (343) use `@testable import Waycar` and run inside the app host (`TEST_HOST`), so none can run on Linux until the logic is a separate module.
- Candidates: transport parsing, tmux control mode, wire types, prompt and agent-screen logic.
- Cost: a refactor of the 454-file app target. Dependencies on `os`/`OSLog`, `Synchronization`, `CryptoKit`, `Observation` need review (all appear in `Sources/Waycar`).
- Payoff: those tests run on Linux with `swift test`. The app-hosted lane would shrink to UI, Keychain and simulator tests.

### 3d. WaycarSSH on Linux (low priority)

Binary xcframeworks (`COpenSSL`, `CLibSSH2`), 7 `Darwin` imports, one `dnssd` import. Needs a system libssh2/OpenSSL target. The real-SSH E2E also runs against the iOS simulator keychain.

## 4. Must stay on a Mac

App build, `Waycar.xcodeproj`, SwiftUI/UIKit tests, Keychain tests, simulator runs, real-SSH iOS E2E, screenshots, TestFlight.

## 5. Proposed order

1. Confirm 3a on Linux and move those steps to a Linux job.
2. Measure 3c: which test files compile against a Foundation-only slice.
3. Decide on 3c and 3b (shared-backend option) from that data.
4. Get a license read on any Linux build that uses Apple's SDK.

## 6. Open questions

- Is the Mac queue time or Mac load the real pain? That decides whether 3a alone is enough.
- Is a refactor of the app target into a core package acceptable (3c)?
- Does Mike want billed `ubuntu-latest` or swiftly on the self-hosted Linux runner for Swift jobs?
