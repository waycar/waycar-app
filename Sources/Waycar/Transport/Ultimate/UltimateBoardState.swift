import Foundation

struct UltimateBoardSubscription: Encodable {
    let conversation: Int
    let docs = ["board"]
    let view = false
}

/// Only the root board's user-facing questions contribute to attention counts.
/// Subscription events prefix their JSON with the numeric subscription id.
struct UltimateBoardState: Sendable {
    private var value: JSONValue = .object([:])

    var openQuestions: Int { openMessages.count }

    var openQuestionsByConversation: [Int: Int] {
        var counts: [Int: Int] = [:]
        for message in openMessages {
            guard case .number(let number) = message["from"], let id = Int(exactly: number), id > 0 else { continue }
            counts[id, default: 0] += 1
        }
        return counts
    }

    private var openMessages: [JSONValue] {
        guard case .array(let messages) = value["messages"] else { return [] }
        return messages.filter { message in
            guard message["to"]?.stringValue == "user" else { return false }
            let asks: Bool
            if case .array(let questions) = message["questions"] { asks = !questions.isEmpty }
            else { asks = false }
            guard message["reply"] == .bool(true) || asks else { return false }
            // Delivered is the board's open state. All terminal states,
            // including dismissals and failures, are settled.
            return message["state"]?.stringValue == "delivered"
        }
    }

    mutating func receive(_ event: UltimateServerEvent) throws -> Bool {
        guard event.name == "doc" || event.name == "docOps",
              let newline = event.data.firstIndex(of: "\n"),
              Int(event.data[..<newline]) == 0 else { return false }
        let data = try JSONDecoder().decode(JSONValue.self, from: Data(event.data[event.data.index(after: newline)...].utf8))
        guard data["kind"]?.stringValue == "board" else { return false }
        if event.name == "doc" {
            value = data["value"] ?? .object([:])
        } else if case .array(let ops) = data["ops"] {
            for op in ops { try Self.apply(op, to: &value) }
        }
        return true
    }

    private static var invalidPatch: TransportError {
        .channelFailed(detail: "Ultimate sent an invalid board update.")
    }

    private static func integer(_ value: JSONValue) throws -> Int {
        guard case .number(let n) = value, let result = Int(exactly: n), result >= 0 else { throw invalidPatch }
        return result
    }

    private static func apply(_ op: JSONValue, to value: inout JSONValue) throws {
        guard case .array(let fields) = op, let kind = fields.first?.stringValue else { throw invalidPatch }
        if kind == "r", fields.count == 2 { value = fields[1]; return }
        guard fields.count >= 2, case .array(let path) = fields[1] else { throw invalidPatch }
        try update(&value, path: ArraySlice(path)) { target in
            switch kind {
            case "s" where fields.count == 3: target = fields[2]
            case "d": target = nil
            case "a" where fields.count == 3:
                guard !path.isEmpty, case .string(let text) = target,
                      let appended = fields[2].stringValue else { throw invalidPatch }
                target = .string(text + appended)
            case "t" where fields.count == 3:
                guard !path.isEmpty, case .string(let text) = target else { throw invalidPatch }
                // Chord uses JS String.slice(count): drop UTF-16 units
                // from the front, saturating at the string's length.
                let count = try integer(fields[2])
                target = .string(String(decoding: text.utf16.dropFirst(count), as: UTF16.self))
            case "p" where fields.count == 5:
                guard case .array(var array) = target, case .array(let inserted) = fields[4] else { throw invalidPatch }
                let index = try integer(fields[2]), remove = try integer(fields[3])
                guard index <= array.count, remove <= array.count - index else { throw invalidPatch }
                array.replaceSubrange(index..<(index + remove), with: inserted)
                target = .array(array)
            case "m" where fields.count == 3:
                guard case .array(let array) = target, case .array(let indices) = fields[2] else { throw invalidPatch }
                let order = try indices.map(integer)
                guard order.sorted() == Array(array.indices) else { throw invalidPatch }
                target = .array(order.map { array[$0] })
            default: throw invalidPatch
            }
        }
    }

    private static func update(
        _ value: inout JSONValue, path: ArraySlice<JSONValue>, mutation: (inout JSONValue?) throws -> Void
    ) throws {
        guard let key = path.first else {
            var target: JSONValue? = value
            try mutation(&target)
            value = target ?? .null
            return
        }
        switch value {
        case .object(var object):
            guard let key = key.stringValue else { throw invalidPatch }
            if path.count == 1 {
                var target = object[key]
                try mutation(&target)
                object[key] = target
            } else {
                guard var child = object[key] else { throw invalidPatch }
                try update(&child, path: path.dropFirst(), mutation: mutation)
                object[key] = child
            }
            value = .object(object)
        case .array(var array):
            let index = try integer(key)
            guard index < array.count else { throw invalidPatch }
            if path.count == 1 {
                var target: JSONValue? = array[index]
                try mutation(&target)
                if let target { array[index] = target } else { array.remove(at: index) }
            } else {
                try update(&array[index], path: path.dropFirst(), mutation: mutation)
            }
            value = .array(array)
        default: throw invalidPatch
        }
    }
}
