import Foundation

/// One gallery's selection, dwell and reads. Only the owner touches Tasks
/// and local files. Closed keeps the last presentation, not live ownership.
struct TerminalPreviewGalleryMachine: StateMachine {
    enum Page: Equatable, Sendable {
        case waiting
        case loading
        case ready(URL)
        case failed(message: String)

        var isSettled: Bool {
            switch self {
            case .ready, .failed: true
            case .waiting, .loading: false
            }
        }
    }

    enum Selection: Equatable, Sendable {
        case initial(Int)
        case shown(Int)

        var index: Int {
            switch self {
            case .initial(let index), .shown(let index): index
            }
        }
    }

    struct Dwell: Equatable, Sendable {
        let index: Int
        let token: UInt64
    }

    struct Open: Equatable, Sendable {
        var pages: [Page]
        var selection: Selection
        var reads: [Int: UInt64] = [:]
        var dwell: Dwell?
    }

    enum State: Equatable, Sendable {
        case open(Open)
        case closed(pages: [Page], current: Int)
    }

    enum Event: Equatable, Sendable {
        case show(Int)
        case dwellElapsed(UInt64)
        case readFinished(index: Int, token: UInt64, page: Page)
        case close
    }

    enum Effect: Equatable, Sendable {
        case read(index: Int, token: UInt64)
        case cancelRead(UInt64)
        case armDwell(UInt64)
        case cancelDwell(UInt64)
        case pageChanged(Int)
        case removeCopy(URL)
        case removeAllCopies
    }

    private(set) var state: State
    private var lastToken: UInt64 = 0
    private let kinds: [TerminalFileKind]
    private let heldCopyLimit: Int

    init(kinds: [TerminalFileKind], startIndex: Int, heldCopyLimit: Int) {
        self.kinds = kinds
        self.heldCopyLimit = heldCopyLimit
        state = .open(Open(
            pages: Array(repeating: .waiting, count: kinds.count),
            selection: .initial(min(max(startIndex, 0), max(kinds.count - 1, 0)))))
    }

    var pages: [Page] {
        switch state {
        case .open(let open): open.pages
        case .closed(let pages, _): pages
        }
    }

    var current: Int {
        switch state {
        case .open(let open): open.selection.index
        case .closed(_, let current): current
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.open(var open), .show(let index)):
            guard open.pages.indices.contains(index) else { return [] }
            let isFirst: Bool
            if case .initial = open.selection { isFirst = true } else { isFirst = false }
            open.selection = .shown(index)
            var effects: [Effect] = []
            if isFirst, open.pages[index] == .waiting { startReading(index, in: &open, effects: &effects) }
            schedule(&open, effects: &effects)
            state = .open(open)
            return effects
        case (.open(var open), .dwellElapsed(let token)):
            guard let dwell = open.dwell, dwell.token == token else { return [] }
            open.dwell = nil
            var effects: [Effect] = []
            if dwell.index == open.selection.index, open.pages[dwell.index] == .waiting {
                startReading(dwell.index, in: &open, effects: &effects)
            }
            state = .open(open)
            return effects
        case (.open(var open), .readFinished(let index, let token, let page)):
            guard open.reads[index] == token else { return discard(page) }
            open.reads[index] = nil
            var effects: [Effect] = []
            set(page, at: index, in: &open, effects: &effects)
            evict(&open, effects: &effects)
            schedule(&open, effects: &effects)
            state = .open(open)
            return effects
        case (.open(let open), .close):
            state = .closed(pages: open.pages, current: open.selection.index)
            var effects = open.reads.values.sorted().map { Effect.cancelRead($0) }
            if let dwell = open.dwell { effects.insert(.cancelDwell(dwell.token), at: 0) }
            return effects + [.removeAllCopies]
        case (.closed, .readFinished(_, _, let page)):
            return discard(page)
        case (.closed, .show), (.closed, .dwellElapsed), (.closed, .close):
            return []
        }
    }

    private func discard(_ page: Page) -> [Effect] {
        if case .ready(let url) = page { return [.removeCopy(url)] }
        return []
    }

    private func isReadAhead(_ index: Int, in open: Open) -> Bool {
        abs(index - open.selection.index) == 1 && kinds.indices.contains(index) && kinds[index] == .image
    }

    private mutating func schedule(_ open: inout Open, effects: inout [Effect]) {
        let current = open.selection.index
        for index in open.reads.keys.sorted() where index != current && !isReadAhead(index, in: open) {
            if let token = open.reads.removeValue(forKey: index) {
                effects.append(.cancelRead(token))
                set(.waiting, at: index, in: &open, effects: &effects)
            }
        }
        if let dwell = open.dwell, dwell.index != current {
            effects.append(.cancelDwell(dwell.token))
            open.dwell = nil
        }
        if open.pages[current] == .waiting {
            guard open.dwell?.index != current else { return }
            lastToken &+= 1
            open.dwell = Dwell(index: current, token: lastToken)
            effects.append(.armDwell(lastToken))
            return
        }
        guard open.pages[current].isSettled, open.reads.isEmpty else { return }
        if let next = [current + 1, current - 1].first(where: {
            isReadAhead($0, in: open) && open.pages[$0] == .waiting
        }) {
            startReading(next, in: &open, effects: &effects)
        }
    }

    private mutating func startReading(_ index: Int, in open: inout Open, effects: inout [Effect]) {
        set(.loading, at: index, in: &open, effects: &effects)
        lastToken &+= 1
        open.reads[index] = lastToken
        effects.append(.read(index: index, token: lastToken))
    }

    private func set(_ page: Page, at index: Int, in open: inout Open, effects: inout [Effect]) {
        guard open.pages[index] != page else { return }
        open.pages[index] = page
        effects.append(.pageChanged(index))
    }

    private func evict(_ open: inout Open, effects: inout [Effect]) {
        let current = open.selection.index
        var held = open.pages.indices.filter { if case .ready = open.pages[$0] { true } else { false } }
        while held.count > heldCopyLimit,
              let farthest = held.filter({ $0 != current }).max(by: { abs($0 - current) < abs($1 - current) }) {
            if case .ready(let copy) = open.pages[farthest] { effects.append(.removeCopy(copy)) }
            set(.waiting, at: farthest, in: &open, effects: &effects)
            held.removeAll { $0 == farthest }
        }
    }
}
