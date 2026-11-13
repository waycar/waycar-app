import Foundation

/// Drives the Console's Host connections from app activity: the one place
/// that turns a suspension into a teardown and a foreground return into a
/// resume.
///
/// A stream consumer rather than a SwiftUI `onChange` on the coordinator's
/// phase, because the transitions it must not miss happen while the app is
/// in the background and rendering nothing (see `AppActivityEvent`). Every
/// event is handled to completion before the next one starts, so a rapid
/// background→foreground bounce resumes *after* the teardown it raced rather
/// than interleaving with it.
@MainActor
struct ConsoleActivityDriver {
    let activity: AppActivityCoordinator
    let console: ConsoleStore

    /// Background time kept back for the teardown when standbys are
    /// prepared ahead of it (#105).
    static let teardownReserve: Duration = .seconds(5)

    /// Consumes activity events until the app ends. Cancellation ends it.
    func run() async {
        for await event in activity.events {
            guard !Task.isCancelled else { return }
            switch event {
            case .activated:
                await console.reactivate()
            case .suspended:
                // Before the teardown, while the SSH connections are still
                // up: each live mosh Agent attach gets a standby a return
                // can start straight at (#105) — only when the grace timer
                // ran out with background time to spare, and bounded by it.
                // Never on the expiration path: nothing there may wait on
                // the network.
                if let budget = activity.backgroundTimeBeforeTeardown(
                    upTo: StandbyMoshStore.bootstrapBudget, leaving: Self.teardownReserve)
                {
                    await console.prepareMoshStandbys(within: budget)
                }
                // The background assertion is held until this returns, so
                // the teardown finishes before the process freezes. Without
                // background time (the expiration path) it waits on nothing
                // the network decides (#105).
                await console.suspend(locally: !activity.hasBackgroundTimeForTeardown)
                activity.didFinishSuspending()
            }
        }
    }
}
