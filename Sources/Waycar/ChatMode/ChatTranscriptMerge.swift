import Foundation

/// How a read of the Host's transcript lands in a list already kept: the one
/// rule the Chat view's list and the copy kept on this device both follow, so
/// neither shrinks what the other holds.
enum ChatTranscriptMerge {
    /// Keeps `known` messages in place (a changed one is replaced) and
    /// appends the unseen ids of `incoming` in order.
    static func appending(
        _ incoming: [ChatTranscriptMessage], to known: [ChatTranscriptMessage]
    ) -> [ChatTranscriptMessage] {
        guard !incoming.isEmpty else { return known }
        var positions = Dictionary(
            known.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = known
        for message in incoming {
            if let index = positions[message.id] {
                if merged[index] != message { merged[index] = message }
            } else {
                positions[message.id] = merged.count
                merged.append(message)
            }
        }
        return merged
    }

    /// The list to keep once a read answered with `incoming`.
    ///
    /// - A read of only the messages after an id (`isWholeList` false) is
    ///   appended; it never replaces anything.
    /// - A whole list that starts inside what is kept replaces from there on,
    ///   keeping the older messages the Host's reader no longer sends (its
    ///   message cap cut them, `truncated`) and any newer ones it has not
    ///   sent yet.
    /// - A whole list that overlaps what is kept only in part is appended.
    /// - A whole list that shares nothing with it is a different
    ///   conversation (a restart): it replaces the kept one, unless the
    ///   reader cut older messages, when it continues the kept list.
    /// - An empty answer keeps the list as it is.
    static func merged(
        cached: [ChatTranscriptMessage], incoming: [ChatTranscriptMessage],
        isWholeList: Bool, truncated: Bool
    ) -> [ChatTranscriptMessage] {
        guard let first = incoming.first else { return cached }
        guard !cached.isEmpty else { return incoming }
        guard isWholeList else { return appending(incoming, to: cached) }
        if let start = cached.firstIndex(where: { $0.id == first.id }) {
            var merged = Array(cached[..<start]) + incoming
            if let last = incoming.last,
                let end = cached.lastIndex(where: { $0.id == last.id }), end >= start
            {
                merged += cached[(end + 1)...]
            }
            return merged
        }
        let keptIDs = Set(cached.map(\.id))
        if incoming.contains(where: { keptIDs.contains($0.id) }) {
            return appending(incoming, to: cached)
        }
        return truncated ? cached + incoming : incoming
    }
}
