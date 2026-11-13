import Foundation

/// list-clients' whitespace table (RUNNING_COMMAND is the unsplit remainder, including N/A).
struct ZellijClient: Sendable, Equatable {
    let id: Int
    let pane: String
    var command: String = "N/A"
}

enum ZellijClients {
    static func parse(_ text: String) -> [ZellijClient] {
        var seen = Set<Int>()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count >= 2, let id = Int(fields[0]), id >= 0,
                fields[1].hasPrefix("terminal_") || fields[1].hasPrefix("plugin_") || fields[1] == "N/A",
                seen.insert(id).inserted
            else { return nil }
            return ZellijClient(
                id: id, pane: String(fields[1]),
                command: fields.count == 3 ? String(fields[2]).trimmingCharacters(in: .whitespaces) : "N/A")
        }
    }

    static func navigation(_ output: String) -> (before: [ZellijClient], after: [ZellijClient])? {
        guard let before = output.range(of: ZellijCommand.clientsBefore + "\n"),
            let after = output.range(
                of: ZellijCommand.clientsAfter + "\n", range: before.upperBound..<output.endIndex),
            let end = output.range(of: ZellijCommand.clientsEnd, range: after.upperBound..<output.endIndex)
        else { return nil }
        return (
            parse(String(output[before.upperBound..<after.lowerBound])),
            parse(String(output[after.upperBound..<end.lowerBound]))
        )
    }
}
