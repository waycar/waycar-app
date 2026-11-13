# Composer Staging Store

Status: Proposed for review

## Decision

Replace the production-unreachable Composer-less image staging route and the
parallel `ImageAttachStore` and `FileAttachStore` workflows with one deep
`ComposerStagingStore` module.

`AgentAttachStore` owns and lifecycle-coordinates the module. The Agent detail
View uses it through `attach.staging`, without media-specific forwarding
methods. This is a bounded ownership compromise: Attach remains display-only
under ADR 0013, while the staging module is nested there solely because that
owner already serializes false-disappear recovery, staging cancellation, and
terminal teardown. Renaming the owner or adding an Agent-detail aggregate is a
separate architecture change.

The design keeps `Transport.stageImage(_:)` and `Transport.stageFile(_:)` as
two typed operations. Their shared SFTP implementation is already deep enough;
merging them would erase useful domain types without removing a caller burden.

## Evidence and rejected seams

The only production construction of `AgentTerminalView` comes from
`AgentDetailView`, and it always supplies an `AgentComposerStore`. The optional
Composer and terminal insertion route are therefore compatibility code without
a production adapter.

Three ownership seams were considered:

1. A child of `AgentAttachStore`. Chosen. The owner survives terminal-child
   replacement and already orders staging shutdown before terminal shutdown.
2. A sibling in `AgentDetailView`. Rejected. It has exactly the same lifetime
   as the attach owner, gains no reconnect persistence, and would duplicate or
   weaken the existing lifecycle guard.
3. A store cached above the detail branch. Rejected. It would make an upload
   survive the reconnect placeholder, a new product behavior with no current
   requirement and no resume contract.

The selected seam passes the deletion test: the old stores, the legacy terminal
destination, and all paired staging forwards can be removed without a
compatibility wrapper. The remaining module boundary carries the real workflow
invariants used by both image and file adapters.

## Interface

Since #128 the store is a single-slot upload worker. It has no Composer,
clipboard, presentation, or auto-dismiss dependency; `ComposerTray` (owned by
`AgentComposerStore` for the lifetime of the draft) owns ordering, queueing,
chip state, Copy Path, and Send composition, and drives this store one item at
a time.

```swift
@MainActor
@Observable
final class ComposerStagingStore {
    private(set) var state: State
    var activeOperationID: UInt64? { get }
    @ObservationIgnored var onOperationEvent: (@MainActor (OperationEvent) -> Void)?

    @discardableResult func begin(_ source: Source) -> UInt64?
    func cancel(operationID: UInt64)
    @discardableResult func retry(operationID: UInt64) -> Bool
    func dismiss(operationID: UInt64)
    func didEnterBackground()
    func leave() async

    enum Source { case photo(any ImageSelection); case file(URL) }

    enum State: Equatable {
        case idle
        case preparing(Medium)
        case uploading(Medium, AttachmentStageProgress)
        case failed(Failure)
        case backgroundInterrupted(Failure)
    }

    enum Medium: Equatable { case image, file }

    struct Failure: Equatable {
        let medium: Medium
        let message: String
        let isRetryable: Bool
    }

    enum OperationEvent: Equatable {
        case completed(id: UInt64, path: String)
        case failed(id: UInt64, message: String, retryable: Bool)
        case cancelled(id: UInt64)
    }
}
```

`begin` returns the new operation identifier, or `nil` while busy. Every
terminal outcome is published once through `onOperationEvent`; success returns
the store to `.idle` and publishes `.completed(id:path:)`. The module does not
throw across its interface; preparation and staging errors become explicit
states and `.failed` events. `ComposerTray` binds to the staging store of the
Attach the on-screen Agent view presents (the view calls `bindStaging`;
`AgentAttachStore.init` does not bind) and ignores events from any other
instance. Teardown suspension and rejoin resumption are scoped to the bound
staging instance: a departing or stale Attach cannot suspend or resume a
successor's tray.

## Invariants

1. There is one operation slot across both media. A begin request while busy
   returns `nil`; the store never queues. `ComposerTray` holds the queue (at
   most 10 items) and starts the next item only when the slot is free.
2. Beginning a new operation silently discards any retained failure and its
   local preparation. `dismiss(operationID:)` does the same for a named
   operation and publishes nothing.
3. An operation identifier rejects progress and completion from superseded
   tasks, and names the operation in `cancel`, `retry`, and `dismiss`.
4. The module deletes only app-created local prepared files. It never deletes a
   completed Host file, per ADR 0005; removing a chip never does either.
5. A retryable failure retains its prepared local file. A non-retryable failure
   deletes it.
6. Background interruption never retries implicitly on foregrounding. The user
   may retry explicitly; `retry(operationID:)` re-uploads under the same
   identifier when the preparation remains, otherwise the tray re-queues the
   item from its source.
7. Successful staging only publishes the Host path. It never touches the draft,
   the clipboard, or the Composer, and never submits. The tray keeps the path on
   a ready chip until Send appends it after the draft text; on a Shell the tray
   inserts it at the caret.
8. `leave()` is idempotent. It cancels and awaits an in-flight task (publishing
   `.cancelled`), deletes its local preparation, and returns to idle.
9. `AgentAttachStore.leave()` retains its synchronous false-disappear guard and
   serialized order: `staging.leave()` completes before `terminal.stop()`.
10. Replacing the terminal child does not replace staging. Leaving the detail
    screen does; uploads are not persisted across a reconnect placeholder.
    Teardown turns the tray's in-flight item into a retryable failure, pauses
    the tray (queued and ready items stay), and never retries implicitly. A
    retryable failure likewise pauses the tray until it is retried or removed.

The state sequence is:

```text
begin -> preparing -> uploading -> idle (completed) | failed | backgroundInterrupted
```

`retry` succeeds only for a retryable failure or background interruption that
still retains its prepared file, `cancel` only for the active operation, and
`dismiss` only for a retained failure.

## Adapter and naming boundaries

Image and file preparation remain medium-specific adapters. The workflow
normalizes their prepared source, progress reporting, staging closure, error
classification, and event publication behind private
implementation types. There is no public medium registry or type-erased
extension point. A third medium can justify another internal adapter when it
exists; it does not justify interface cost now.

Mechanism types shared by both media receive neutral names:

| Current | Proposed |
| --- | --- |
| `ImageStageProgress` | `AttachmentStageProgress` |
| `ImageStageProgressReporter` | `AttachmentStageProgressReporter` |
| `ImageStagingError` | `AttachmentStagingError` |
| `ImageClipboard` | `AttachmentClipboard` |
| `invalidPreparedImage` | `invalidPreparedSource` |

The domain operations and results remain medium-specific:
`Transport.stageImage(_:)`, `Transport.stageFile(_:)`, `StagedImage`, and
`StagedFile` do not change. This separates neutral implementation mechanisms
from the two domain results and keeps Transport behavior, concurrency, retry,
and error semantics unchanged.

## Test migration

Historical plan for the original refactor; #128 removed the Composer insertion
and clipboard recovery it mentions.

The current staging baseline is 16 tests: 14 in `ImageAttachStoreTests` and two
staging happy paths in `ComposerAttachmentTests`.

- Delete three tests whose only invariant is the unreachable terminal
  destination: generation-matched insertion, pausing terminal input, and
  explicit insertion into the current live session.
- Merge the test where both post-stage actions fail into the existing recovery
  test. Composer insertion is constructionally available, leaving clipboard
  copy as the sole recoverable post-stage failure.
- Migrate the remaining ten workflow tests and parameterize each across image
  and file, producing 20 cases.
- Add two cross-media cases: a file begin is ignored while an image is active,
  and a new begin clears a prior presented result.
- Remove the two superseded Composer staging happy paths while retaining the
  unrelated link-presentation test.
- Add `stageFile` and `configureFileStaging` to `ScriptedTransport`; file staging
  currently lacks the scripted adapter required for symmetric unit coverage.

The result is 22 staging-specific cases with symmetric media coverage.
`AgentSurfaceReplacementTests` keeps its eight production SwiftUI seam cases,
but their fixtures must move to the production configuration: six currently
construct a Composer-less detail and must receive the required Composer, while
direct `owner.selectImage` and `owner.imageState` calls move to
`owner.staging`. These fixture changes do not count toward the 22 staging cases.
`ImageStagingE2ETests` remains the real-SSH SFTP check and changes only for
mechanical type renames.

## Implementation sequence

Each step must leave the relevant checks passing and must replace rather than
layer compatibility wrappers:

1. Rename the shared staging mechanism types without changing behavior.
2. Remove the Composer-less image route and its three terminal-only tests.
3. Add scripted file staging support to the Transport test double.
4. Introduce `ComposerStagingStore`, replace both old stores in one change, and
   migrate the staging suite to 22 cases.
5. Regenerate and commit `Waycar.xcodeproj` for source moves, then update domain
   and architecture documentation.

## Documentation changes

- `CONTEXT.md` replaces obsolete **Attach Image** with the Composer action
  **Add**, adds **Staged File**, and deliberately does not add a **Staged
  Attachment** umbrella term.
- ADR 0006 names the unified workflow and records why its display-only Attach
  owner coordinates the lifecycle.
- ADR 0005 and ADR 0013 remain unchanged and authoritative.
- No changelog entry is needed because the removed route is production
  unreachable and the rest is an internal refactor.

## Non-goals

- No changes to Transport method shape or behavior.
- No unification of `StagedImage` and `StagedFile`.
- No third-medium registry or generalized attachment framework.
- No rename of `AgentAttachStore` and no Agent-detail aggregate.
- No staging persistence across the missing-Agent reconnect placeholder.
- No Host-side cleanup or upload resume contract.
- No terminal keyboard, Composer delivery, or SSH package changes.
- No rewrite of the historical `docs/research/image-input.md`; its superseded
  action and insertion route are marked at the top of that record.

## Review frontier

Superseded in part by #128: the Composer dependency, path insertion on
completion, and clipboard copy described below moved out of the store (see
Interface).

Codex and Claude Code agree on this version. User review should focus on the
only material product simplification beyond structural refactoring: a live
Composer is made a required dependency, so path insertion is guaranteed and
the unreachable `Insert Path` recovery button is removed. Reverting that choice
is bounded to making the dependency weak again, restoring one command and one
outcome flag, and adding two recovery cases; it does not change the selected
module seam.
