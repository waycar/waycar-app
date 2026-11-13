/// Ownership of the last frame, not its UIKit resources. A cached copy and
/// a painted surface are mutually exclusive; an unpainted replacement cannot
/// retire the predecessor's copy. Capture and weak view storage stay in the owner.
struct TerminalLastFrameMachine: StateMachine {
    enum State: Equatable, Sendable {
        case empty
        case cached
        case painted(TerminalSurfaceID)
    }

    enum Event: Equatable, Sendable {
        case offer
        case paint(TerminalSurfaceID, hasView: Bool)
        /// The owner verified the retiring surface, then synchronously captured
        /// its weak view. A failed capture leaves no frame.
        case retired(hasSnapshot: Bool)
        case discard
    }

    enum Effect: Equatable, Sendable {
        case storeSnapshot
        case clearSnapshot
        case storePaintedView
        case clearPaintedView
    }

    private(set) var state: State = .empty

    var paintedSurface: TerminalSurfaceID? {
        if case .painted(let surface) = state { return surface }
        return nil
    }

    func hasFrame(for surface: TerminalSurfaceID) -> Bool {
        state == .cached || paintedSurface == surface
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.empty, .offer):
            state = .cached
            return [.storeSnapshot]
        case (.cached, .offer), (.painted, .offer):
            return []
        case (.painted(let current), .paint(let surface, let hasView)) where current == surface:
            // Repeated status delivery must not invalidate observed ownership;
            // a nil repeat must not forget the weak view already known.
            return hasView ? [.storePaintedView] : []
        case (.empty, .paint(let surface, _)), (.painted, .paint(let surface, _)):
            state = .painted(surface)
            return [.storePaintedView]
        case (.cached, .paint(let surface, _)):
            state = .painted(surface)
            return [.storePaintedView, .clearSnapshot]
        case (_, .retired(let hasSnapshot)):
            state = hasSnapshot ? .cached : .empty
            return [hasSnapshot ? .storeSnapshot : .clearSnapshot, .clearPaintedView]
        case (_, .discard):
            state = .empty
            return [.clearSnapshot, .clearPaintedView]
        }
    }
}
