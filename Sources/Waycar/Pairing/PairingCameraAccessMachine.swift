/// Camera authorization for a retained Scan to Pair sheet. Authorization
/// snapshots supersede an outstanding permission prompt; a late prompt answer
/// cannot replace a newer Settings decision. No camera or scene I/O lives here.
struct PairingCameraAccessMachine: StateMachine {
    enum Access: Equatable, Sendable {
        case undetermined
        case authorized
        case denied
    }

    enum State: Equatable, Sendable {
        case undetermined
        case requesting(UInt64)
        case authorized
        case denied
    }

    enum Event: Equatable, Sendable {
        case authorization(Access)
        case permissionReturned(UInt64, granted: Bool)
    }

    enum Effect: Equatable, Sendable {
        case requestPermission(UInt64)
    }

    private(set) var state: State = .undetermined
    private var lastToken: UInt64 = 0

    var access: Access {
        switch state {
        case .undetermined, .requesting: .undetermined
        case .authorized: .authorized
        case .denied: .denied
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .authorization(.authorized)):
            state = .authorized
            return []
        case (_, .authorization(.denied)):
            state = .denied
            return []
        case (.requesting, .authorization(.undetermined)):
            // The system prompt can itself make the scene active again.
            return []
        case (.undetermined, .authorization(.undetermined)),
            (.authorized, .authorization(.undetermined)), (.denied, .authorization(.undetermined)):
            lastToken += 1
            state = .requesting(lastToken)
            return [.requestPermission(lastToken)]
        case (.requesting(let current), .permissionReturned(let token, let granted))
            where current == token:
            state = granted ? .authorized : .denied
            return []
        case (.undetermined, .permissionReturned), (.requesting, .permissionReturned),
            (.authorized, .permissionReturned), (.denied, .permissionReturned):
            return []
        }
    }
}
