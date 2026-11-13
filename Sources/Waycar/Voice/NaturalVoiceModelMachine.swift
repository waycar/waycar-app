/// Serializes model mutations and fences asynchronous disk snapshots. The
/// snapshot is the last UI projection, retained while work runs and until the
/// post-work disk read completes; cancellation does not free the work slot.
struct NaturalVoiceModelMachine: StateMachine {
    struct Snapshot: Equatable, Sendable {
        var phases: [NaturalVoiceModelID: NaturalVoiceModelStore.Phase] = [:]
        var voices: [NaturalVoiceModelID: [NaturalVoiceOption]] = [:]
        var freed: [NaturalVoiceModelID: Int64] = [:]
        var download: [NaturalVoiceModelID: Int64] = [:]
        var total: Int64 = 0
    }
    struct Operation: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case download, delete }
        let token: UInt64
        let model: NaturalVoiceModelID
        let kind: Kind
    }
    enum State: Equatable, Sendable {
        case ready
        case checking(UInt64)
        case downloading(Operation)
        case preparing(Operation)
        case cancelling(Operation, fetched: Bool)
        case deleting(Operation)
    }
    enum Event: Sendable {
        case refresh
        case snapshot(UInt64, Snapshot)
        case download(NaturalVoiceModelID)
        case delete(NaturalVoiceModelID)
        case cancel
        case progress(UInt64, Double)
        case fetched(UInt64)
        case completed(UInt64)
    }
    enum Effect: Equatable, Sendable {
        case readSnapshot(UInt64)
        case download(Operation)
        case delete(Operation)
        case cancel(UInt64)
        case clearWork(UInt64)
    }

    private(set) var state: State = .ready
    private(set) var snapshot = Snapshot()
    private var lastToken: UInt64 = 0

    var operation: Operation? {
        switch state {
        case .downloading(let op), .preparing(let op), .cancelling(let op, _), .deleting(let op): op
        case .ready, .checking: nil
        }
    }
    var busyModel: NaturalVoiceModelID? { operation?.model }
    var isDownloading: Bool { operation?.kind == .download }
    var fetched: Bool {
        switch state {
        case .preparing: true
        case .cancelling(_, let fetched): fetched
        case .ready, .checking, .downloading, .deleting: false
        }
    }
    func isCurrent(_ token: UInt64) -> Bool { operation?.token == token }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.ready, .refresh), (.checking, .refresh):
            lastToken += 1
            state = .checking(lastToken)
            return [.readSnapshot(lastToken)]
        case (.checking(let current), .snapshot(let token, let snapshot)):
            guard current == token else { return [] }
            self.snapshot = snapshot
            state = .ready
            return []
        case (.ready, .download(let model)), (.checking, .download(let model)):
            lastToken += 1
            let op = Operation(token: lastToken, model: model, kind: .download)
            snapshot.phases[model] = .downloading(0)
            state = .downloading(op)
            return [.download(op)]
        case (.ready, .delete(let model)), (.checking, .delete(let model)):
            lastToken += 1
            let op = Operation(token: lastToken, model: model, kind: .delete)
            snapshot.phases[model] = .checking
            state = .deleting(op)
            return [.delete(op)]
        case (_, .delete(let model)):
            guard busyModel == model else { return [] }
            return handle(.cancel)
        case (.downloading(let op), .cancel), (.deleting(let op), .cancel):
            state = .cancelling(op, fetched: false)
            return [.cancel(op.token)]
        case (.preparing(let op), .cancel):
            state = .cancelling(op, fetched: true)
            return [.cancel(op.token)]
        case (.cancelling(let op, _), .cancel):
            return [.cancel(op.token)]
        case (.downloading(let op), .progress(let token, let progress)),
            (.cancelling(let op, false), .progress(let token, let progress)):
            guard op.token == token, op.kind == .download else { return [] }
            snapshot.phases[op.model] = .downloading(progress)
            return []
        case (.downloading(let op), .fetched(let token)):
            guard op.token == token else { return [] }
            snapshot.phases[op.model] = .preparing
            state = .preparing(op)
            return []
        case (.cancelling(let op, _), .fetched(let token)):
            guard op.token == token, op.kind == .download else { return [] }
            snapshot.phases[op.model] = .preparing
            state = .cancelling(op, fetched: true)
            return []
        case (_, .completed(let token)):
            guard operation?.token == token else { return [] }
            lastToken += 1
            state = .checking(lastToken)
            return [.clearWork(token), .readSnapshot(lastToken)]
        case (.ready, _), (.checking, _), (.downloading, _), (.preparing, _),
            (.cancelling, _), (.deleting, _):
            return []
        }
    }
}
