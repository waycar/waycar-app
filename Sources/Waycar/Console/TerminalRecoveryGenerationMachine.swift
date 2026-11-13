/// Joins a recovery pipeline's acquisition and the Console's independently
/// scheduled projection. Rebinding forgets acquisition, never projection;
/// only the bound pipeline can finish recovery, and projection never recedes.
struct TerminalRecoveryGenerationMachine: StateMachine {
    enum State: Equatable, Sendable {
        case inactive
        case unbound(projected: UInt64?)
        case bound(TerminalSurfaceID, acquired: UInt64?, projected: UInt64?)
    }

    enum Decision: Equatable, Sendable {
        case pending
        case acknowledge(UInt64)
        case replace(UInt64)
        case retain(UInt64)
    }

    enum Event: Equatable, Sendable {
        case begin(projected: UInt64?)
        case bind(TerminalSurfaceID)
        case project(UInt64)
        case acquire(UInt64, by: TerminalSurfaceID)
        case clearBound(TerminalSurfaceID)
        case clear
    }

    enum Effect: Equatable, Sendable {
        case decide(Decision)
    }

    private(set) var state: State = .inactive

    var isActive: Bool { state != .inactive }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.inactive, .begin(let projected)):
            state = .unbound(projected: projected)
            return []
        case (.unbound(let projected), .bind(let pipeline)),
             (.bound(_, _, let projected), .bind(let pipeline)):
            state = .bound(pipeline, acquired: nil, projected: projected)
            return []
        case (.unbound(let projected), .project(let generation)):
            state = .unbound(projected: max(projected ?? generation, generation))
            return [.decide(.pending)]
        case (.bound(let pipeline, let acquired, let projected), .project(let generation)):
            return reconcile(
                pipeline: pipeline, acquired: acquired,
                projected: max(projected ?? generation, generation))
        case (.bound(let pipeline, _, let projected), .acquire(let generation, let received))
            where pipeline == received:
            return reconcile(pipeline: pipeline, acquired: generation, projected: projected)
        case (.bound(let pipeline, _, _), .clearBound(let received)) where pipeline == received:
            state = .inactive
            return []
        case (_, .clear):
            state = .inactive
            return []
        case (.inactive, .bind), (.inactive, .project), (.inactive, .acquire), (.inactive, .clearBound),
             (.unbound, .begin), (.unbound, .acquire), (.unbound, .clearBound),
             (.bound, .begin), (.bound, .acquire), (.bound, .clearBound):
            return []
        }
    }

    private mutating func reconcile(
        pipeline: TerminalSurfaceID, acquired: UInt64?, projected: UInt64?
    ) -> [Effect] {
        guard let acquired, let projected else {
            state = .bound(pipeline, acquired: acquired, projected: projected)
            return [.decide(.pending)]
        }
        state = .inactive
        if projected == acquired { return [.decide(.acknowledge(acquired))] }
        if projected > acquired { return [.decide(.replace(projected))] }
        return [.decide(.retain(acquired))]
    }
}
