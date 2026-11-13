/// Push authorization and APNs registration for one app launch. Queries and
/// permission requests share a generation: only the newest answer can publish.
/// A revoked token stays private until a current query restores authorization.
struct PushRegistrationMachine: StateMachine {
    /// Existing UI vocabulary; checking and permission requests keep the last
    /// presentation rather than adding a new label to Settings.
    enum DisplayState: Equatable, Sendable {
        case unknown
        case needsPermission
        case denied
        case waitingForToken
        case registered(APNSDeviceToken)
        case failed(String)
    }

    enum Status: Equatable, Sendable {
        case unknown(APNSDeviceToken?)
        case needsPermission(APNSDeviceToken?)
        case denied(APNSDeviceToken?)
        case waitingForToken(APNSDeviceToken?)
        case registered(APNSDeviceToken)
        case failed(String, APNSDeviceToken?)

        var retainedToken: APNSDeviceToken? {
            switch self {
            case .unknown(let token), .needsPermission(let token), .denied(let token),
                .waitingForToken(let token), .failed(_, let token):
                token
            case .registered(let token): token
            }
        }

        var display: DisplayState {
            switch self {
            case .unknown: .unknown
            case .needsPermission: .needsPermission
            case .denied: .denied
            case .waitingForToken: .waitingForToken
            case .registered(let token): .registered(token)
            case .failed(let message, _): .failed(message)
            }
        }
    }

    enum State: Equatable, Sendable {
        case ready(Status)
        case checking(UInt64, Status)
        case requestingPermission(UInt64, Status)

        var status: Status {
            switch self {
            case .ready(let status), .checking(_, let status), .requestingPermission(_, let status):
                status
            }
        }
    }

    enum Authorization: Equatable, Sendable { case allowed, denied, undetermined }
    enum Permission: Equatable, Sendable { case granted, denied, failed(String) }
    enum Event: Equatable, Sendable {
        case refresh
        case enable
        case authorizationFinished(UInt64, Authorization)
        case permissionFinished(UInt64, Permission)
        case deviceTokenArrived(APNSDeviceToken)
        case registrationFailed(String)
    }
    enum Effect: Equatable, Sendable {
        case checkAuthorization(UInt64)
        case requestPermission(UInt64)
        case register
    }

    private(set) var state: State = .ready(.unknown(nil))
    private var lastToken: UInt64 = 0

    var display: DisplayState { state.status.display }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .refresh):
            lastToken += 1
            state = .checking(lastToken, state.status)
            return [.checkAuthorization(lastToken)]
        case (_, .enable):
            lastToken += 1
            state = .requestingPermission(lastToken, state.status)
            return [.requestPermission(lastToken)]
        case (.checking(let current, let status), .authorizationFinished(let token, let answer))
            where current == token:
            switch answer {
            case .allowed:
                if let captured = status.retainedToken {
                    state = .ready(.registered(captured))
                    return []
                }
                state = .ready(.waitingForToken(nil))
                return [.register]
            case .denied:
                state = .ready(.denied(status.retainedToken))
            case .undetermined:
                state = .ready(.needsPermission(status.retainedToken))
            }
            return []
        case (.requestingPermission(let current, let status), .permissionFinished(let token, let answer))
            where current == token:
            switch answer {
            case .granted:
                state = .ready(.waitingForToken(status.retainedToken))
                return [.register]
            case .denied:
                state = .ready(.denied(status.retainedToken))
            case .failed(let message):
                state = .ready(.failed(message, status.retainedToken))
            }
            return []
        case (_, .deviceTokenArrived(let token)):
            // PUSH-01: APNs callbacks can arrive after permission was revoked.
            let status: Status
            if case .denied = state.status { status = .denied(token) }
            else { status = .registered(token) }
            replaceStatus(status)
            return []
        case (_, .registrationFailed(let message)):
            replaceStatus(.failed(message, state.status.retainedToken))
            return []
        case (_, .authorizationFinished), (_, .permissionFinished):
            return []
        }
    }

    /// An APNs callback does not complete an authorization query in flight.
    private mutating func replaceStatus(_ status: Status) {
        switch state {
        case .ready: state = .ready(status)
        case .checking(let token, _): state = .checking(token, status)
        case .requestingPermission(let token, _): state = .requestingPermission(token, status)
        }
    }
}
