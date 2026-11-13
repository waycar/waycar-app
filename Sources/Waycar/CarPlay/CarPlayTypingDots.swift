import Foundation

/// The CarPlay "Waiting for reply" image: three dots bouncing in turn, like
/// iMessage's typing indicator. Pure; the coordinator draws each frame.
enum CarPlayTypingDots {
    static let dotCount = 3
    /// One cycle: each dot up in turn, then two frames all down as the pause.
    static let raisedDotPerFrame: [Int?] = [0, 1, 2, nil, nil]
    /// Seconds per cycle.
    static let cycleDuration: TimeInterval = 1.2
}
