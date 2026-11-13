import Foundation

/// Which SSH connection `SSHSessionPool` shares for each key (ADR 0026,
/// #105): the live one, the one kept open across a suspension, a hedged
/// replacement dialed for a connection that did not answer, the dial in
/// flight with its waiters, and dials new acquirers no longer join.
///
/// The pool performs every await (probing, retaining and releasing a
/// session, dialing) and comes back with an event; the machine checks it
/// against the connection's serial, the token every later call names, so a
/// probe or retain that finished after the key moved on changes nothing it
/// should not. Within one call, the rules are the pool's as before:
///
/// - An acquire tries the live connection, unless it is the one the caller
///   found unanswered; a live one that fails its probe stops being shared.
///   A replacing acquire then tries the hedge already dialed, and else joins
///   (or starts) the dial in flight. A dial that replaces a connection that
///   is still live becomes the hedge, shared only once that one is retired,
///   since its probe may still answer.
/// - A dial nobody waits for any more is cancelled; one that lands with no
///   waiter is released at once. An abandoned dial serves the waiters it
///   has; when it lands, a newer live connection that is still connected
///   stays the shared one.
/// - A kept connection holds one hold; keeping twice, or two keeps racing,
///   leaves one.
struct SessionPoolMachine<Session: SSHPooledSession>: StateMachine {
    /// One pooled connection: compared by serial and identity.
    struct Entry: Equatable, Sendable {
        let session: Session
        let serial: UInt64

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.serial == rhs.serial && lhs.session === rhs.session
        }
    }

    struct Dial: Equatable, Sendable {
        let id: UInt64
        /// The serial of the live connection this dial replaces, if one
        /// asked for a replacement.
        let replaces: UInt64?
        /// Waiting acquirers, in arrival order.
        var waiters: [UInt64]
    }

    struct AbandonedDial: Equatable, Sendable {
        let key: String
        var dial: Dial
    }

    struct State: Equatable, Sendable {
        var live: [String: Entry] = [:]
        /// Connections held open across a suspension, one hold each.
        var kept: [String: Entry] = [:]
        /// A replacement that landed while the connection it replaces was
        /// still live.
        var replacements: [String: Entry] = [:]
        var dials: [String: Dial] = [:]
        /// Dials new acquirers no longer join, by dial id.
        var abandoned: [UInt64: AbandonedDial] = [:]
    }

    enum Event: Sendable {
        /// An acquire of `key`; `stale` is the serial its caller found
        /// unanswered.
        case lookUp(key: String, stale: UInt64?)
        /// The live connection was probed: connected and retained, or not.
        case liveProbed(key: String, Entry, retained: Bool, stale: UInt64?)
        case replacementProbed(key: String, Entry, retained: Bool, stale: UInt64?)
        /// The acquirer waiting under `waiter` joins the dial for `key`.
        case join(key: String, waiter: UInt64, stale: UInt64?)
        case cancelWaiter(key: String, waiter: UInt64)
        /// The dial ended with `session`, or failed when nil.
        case dialEnded(key: String, dial: UInt64, session: Session?)
        /// The live connection a landed dial met was found connected or not.
        case currentChecked(key: String, placing: Entry, waiters: [UInt64], connected: Bool)
        case keep(key: String, serial: UInt64)
        case keepRetained(key: String, Entry, retained: Bool)
        case releaseKept(key: String, serial: UInt64)
        case retire(key: String, serial: UInt64)
        case replacementChecked(key: String, Entry, connected: Bool)
        case abandonDial(key: String)
    }

    enum Effect: Equatable, Sendable {
        /// Probe the live connection: connected, then retained.
        case probeLive(Entry)
        /// Probe the hedge dialed for the caller's stale connection.
        case probeReplacement(Entry)
        /// The acquire returns this connection, held once for the caller.
        case handOut(Entry)
        /// The acquire parks under `waiter` until a dial lands.
        case wait(waiter: UInt64)
        case startDial(UInt64)
        case cancelDial(UInt64)
        /// Fail the waiter as cancelled.
        case cancelWaiter(UInt64)
        /// Fail these waiters with the dial's error.
        case failWaiters([UInt64])
        /// The landed dial has nobody to take its hold: release it.
        case releaseUnclaimed
        /// Ask whether `current` is still connected before placing a dial.
        case checkCurrent(current: Entry, placing: Entry, waiters: [UInt64])
        /// The dial's hold goes to the first waiter, one more retain each to
        /// the rest; a waiter it cannot retain for is told the connection
        /// closed.
        case distribute(Entry, waiters: [UInt64])
        case retainForKeep(Entry)
        case keepAnswered(Bool)
        /// Release now, before the call returns.
        case release(Entry)
        /// Release without waiting.
        case releaseLater(Entry)
        /// Ask whether the hedge is connected before sharing it.
        case checkReplacement(Entry)
    }

    private(set) var state = State()
    /// Waiter ids, dial ids and serials share one counter, never reused.
    private var lastToken: UInt64 = 0

    init() {}

    func waiterCount(key: String) -> Int {
        state.dials[key]?.waiters.count ?? 0
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .lookUp(let key, let stale):
            return nextCandidate(key: key, stale: stale)

        case .liveProbed(let key, let entry, let retained, let stale):
            if retained { return [.handOut(entry)] }
            if state.live[key]?.serial == entry.serial { state.live[key] = nil }
            return nextCandidate(key: key, stale: stale)

        case .replacementProbed(_, let entry, let retained, _):
            if retained { return [.handOut(entry)] }
            return [.wait(waiter: mint())]

        case .join(let key, let waiter, let stale):
            if var dial = state.dials[key] {
                dial.waiters.append(waiter)
                state.dials[key] = dial
                return []
            }
            let replaces = stale.flatMap { state.live[key]?.serial == $0 ? $0 : nil }
            let id = mint()
            state.dials[key] = Dial(id: id, replaces: replaces, waiters: [waiter])
            return [.startDial(id)]

        case .cancelWaiter(let key, let waiter):
            if var dial = state.dials[key], let index = dial.waiters.firstIndex(of: waiter) {
                dial.waiters.remove(at: index)
                if dial.waiters.isEmpty {
                    state.dials[key] = nil
                    return [.cancelWaiter(waiter), .cancelDial(dial.id)]
                }
                state.dials[key] = dial
                return [.cancelWaiter(waiter)]
            }
            for (id, var orphan) in state.abandoned where orphan.key == key {
                guard let index = orphan.dial.waiters.firstIndex(of: waiter) else { continue }
                orphan.dial.waiters.remove(at: index)
                if orphan.dial.waiters.isEmpty {
                    state.abandoned[id] = nil
                    return [.cancelWaiter(waiter), .cancelDial(id)]
                }
                state.abandoned[id] = orphan
                return [.cancelWaiter(waiter)]
            }
            return []

        case .dialEnded(let key, let id, let session):
            var finished: Dial?
            if let dial = state.dials[key], dial.id == id {
                state.dials[key] = nil
                finished = dial
            } else if let orphan = state.abandoned.removeValue(forKey: id) {
                finished = orphan.dial
            }
            let waiters = finished?.waiters ?? []
            guard let session else { return [.failWaiters(waiters)] }
            guard !waiters.isEmpty else { return [.releaseUnclaimed] }
            let entry = Entry(session: session, serial: mint())
            if let replaces = finished?.replaces, state.live[key]?.serial == replaces {
                state.replacements[key] = entry
            } else if let current = state.live[key] {
                return [.checkCurrent(current: current, placing: entry, waiters: waiters)]
            } else {
                state.live[key] = entry
            }
            return [.distribute(entry, waiters: waiters)]

        case .currentChecked(let key, let entry, let waiters, let connected):
            // A later dial got there first (this one was abandoned): it stays
            // the shared one while connected, and these waiters keep their own.
            if !connected { state.live[key] = entry }
            return [.distribute(entry, waiters: waiters)]

        case .keep(let key, let serial):
            if state.kept[key]?.serial == serial { return [.keepAnswered(true)] }
            guard let entry = state.live[key], entry.serial == serial else {
                return [.keepAnswered(false)]
            }
            return [.retainForKeep(entry)]

        case .keepRetained(let key, let entry, let retained):
            guard retained else { return [.keepAnswered(false)] }
            // Retired while the retain was in flight: no keep comes back.
            guard state.live[key]?.serial == entry.serial else {
                return [.release(entry), .keepAnswered(false)]
            }
            // Another keep won meanwhile: one hold is enough.
            if state.kept[key]?.serial == entry.serial {
                return [.release(entry), .keepAnswered(true)]
            }
            let previous = state.kept.updateValue(entry, forKey: key)
            return (previous.map { [.releaseLater($0)] } ?? []) + [.keepAnswered(true)]

        case .releaseKept(let key, let serial):
            guard let entry = state.kept[key], entry.serial == serial else { return [] }
            state.kept[key] = nil
            if state.live[key]?.serial == serial { state.replacements[key] = nil }
            return [.releaseLater(entry)]

        case .retire(let key, let serial):
            var effects: [Effect] = []
            if let entry = state.kept[key], entry.serial == serial {
                state.kept[key] = nil
                effects.append(.releaseLater(entry))
            }
            guard state.live[key]?.serial == serial else { return effects }
            state.live[key] = nil
            guard let replacement = state.replacements.removeValue(forKey: key) else {
                return effects
            }
            return effects + [.checkReplacement(replacement)]

        case .replacementChecked(let key, let entry, let connected):
            if connected, state.live[key] == nil { state.live[key] = entry }
            return []

        case .abandonDial(let key):
            guard let dial = state.dials.removeValue(forKey: key) else { return [] }
            state.abandoned[dial.id] = AbandonedDial(key: key, dial: dial)
            return []
        }
    }

    /// An acquire's next step: the live connection unless it is the stale
    /// one, then for a replacing acquire the hedge, else a wait for a dial.
    private mutating func nextCandidate(key: String, stale: UInt64?) -> [Effect] {
        if let entry = state.live[key], entry.serial != stale { return [.probeLive(entry)] }
        if stale != nil, let replacement = state.replacements[key] {
            return [.probeReplacement(replacement)]
        }
        return [.wait(waiter: mint())]
    }

    private mutating func mint() -> UInt64 {
        lastToken &+= 1
        return lastToken
    }
}
