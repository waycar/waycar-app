import Foundation
import os

/// The Apple Watch link's log, on both ends (the app's subsystem on the
/// iPhone, the watch app's on the watch; category `watch`). Requests,
/// replies, sessions, holds and timings go in by type, id, count and
/// duration only, which are `.public`; anything else is private, and
/// Agent text, transcripts and recordings never go in at all.
///
///     log stream --predicate 'subsystem BEGINSWITH "com.otreva.waycar" && category == "watch"'
enum WatchLog {
    #if os(watchOS)
        /// The watch app's log.
        static let logger = Logger(subsystem: "com.otreva.waycar.watchkitapp", category: "watch")
    #else
        /// The iPhone app's log.
        static let logger = Logger(subsystem: "com.otreva.waycar", category: "watch")
    #endif

    /// Whole milliseconds from `start` to now, for the log.
    static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        milliseconds(ContinuousClock.now - start)
    }

    /// Whole milliseconds in `duration`, for the log.
    static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }

    /// Background time left, for the log: "unlimited" in the foreground
    /// (where the system reports `.greatestFiniteMagnitude`), else seconds
    /// to one decimal.
    static func backgroundTime(_ remaining: TimeInterval) -> String {
        remaining >= .greatestFiniteMagnitude ? "unlimited" : String(format: "%.1f s", remaining)
    }
}

extension WatchRequest {
    /// The request's kind as the log names it.
    var logType: String {
        switch self {
        case .refresh: "refresh"
        case .latest: "latest"
        case .blockedPrompt: "blockedPrompt"
        case .answer: "answer"
        case .send: "send"
        case .voice: "voice"
        }
    }

    /// The message id a send or voice request carries, as the log shows it;
    /// "-" for the others.
    var logMessageID: String {
        switch self {
        case .send(let messageID, _, _), .voice(let messageID, _): messageID.uuidString
        case .refresh, .latest, .blockedPrompt, .answer: "-"
        }
    }
}

extension WatchReply {
    /// The reply's kind as the log names it.
    var logType: String {
        switch self {
        case .received: "received"
        case .state: "state"
        case .latest: "latest"
        case .blockedPrompt: "blockedPrompt"
        case .answerResult: "answerResult"
        case .failure: "failure"
        }
    }
}

extension WatchDelivery {
    /// The outcome's kind as the log names it.
    var logType: String {
        switch self {
        case .sent: "sent"
        case .notSent: "notSent"
        case .unknown: "unknown"
        case .keptAsDraft: "keptAsDraft"
        case .noWords: "noWords"
        }
    }
}
