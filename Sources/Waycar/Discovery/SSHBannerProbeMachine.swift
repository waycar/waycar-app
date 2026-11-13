import Foundation

/// A bounded connect/read attempt. Cancellation before start is remembered so
/// the continuation supplied later is resumed exactly once, without dialing.
struct SSHBannerProbeMachine: StateMachine {
    enum State: Equatable, Sendable {
        case idle
        case cancelledBeforeStart
        case connecting(timer: UInt64)
        case reading(timer: UInt64, bytes: Data, received: Int)
        case finished
    }
    enum Event: Equatable, Sendable {
        case start
        case connected
        case received(Data, complete: Bool, failed: Bool)
        case failed(SSHProbeResult)
        case timeout(UInt64)
        case cancel
    }
    enum Effect: Equatable, Sendable {
        case connect
        case armTimeout(UInt64)
        case receive
        case finish(SSHProbeResult)
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .start):
            lastToken += 1
            state = .connecting(timer: lastToken)
            return [.armTimeout(lastToken), .connect]
        case (.idle, .cancel):
            state = .cancelledBeforeStart
            return []
        case (.cancelledBeforeStart, .start):
            return finish(.unreachable)
        case (.connecting(let timer), .connected):
            state = .reading(timer: timer, bytes: Data(), received: 0)
            return [.receive]
        case (.reading(let timer, var bytes, let received), .received(let data, let complete, let failed)):
            bytes.append(data)
            let count = received + data.count
            // RFC 4253 permits greetings before identification; TCP can split
            // the identification line at any byte boundary.
            while let newline = bytes.firstIndex(of: 10) {
                let line = String(decoding: bytes[...newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                bytes.removeSubrange(...newline)
                if line.hasPrefix("SSH-"), FoundComputer.software(fromBanner: line) != nil {
                    return finish(.ssh(banner: line))
                }
            }
            guard !complete, !failed, count < 8192 else { return finish(.notSSH) }
            state = .reading(timer: timer, bytes: bytes, received: count)
            return [.receive]
        case (.connecting(let timer), .timeout(let token)),
            (.reading(let timer, _, _), .timeout(let token)):
            guard timer == token else { return [] }
            return finish(.unreachable)
        case (.connecting, .failed(let result)), (.reading, .failed(let result)):
            return finish(result)
        case (.connecting, .cancel), (.reading, .cancel):
            return finish(.unreachable)
        case (.idle, _), (.cancelledBeforeStart, _), (.finished, _),
            (.connecting, .start), (.connecting, .received),
            (.reading, .start), (.reading, .connected):
            return []
        }
    }

    private mutating func finish(_ result: SSHProbeResult) -> [Effect] {
        state = .finished
        return [.finish(result)]
    }
}
