import Foundation

/// Version-one hook document, shared with Host Tools' zellij-pane-state-v1 vector.
struct ZellijPaneState: Decodable, Sendable, Equatable {
    let pane: ZellijPaneID
    let kind: String?
    let status: AgentStatus?
    let seq: Int?
    let session: String?
    let transcript: String?
    let launch: String?
    let pid: Int?
    let updatedMs: Int64?

    enum CodingKeys: String, CodingKey {
        case version, pane, kind, status, seq, session, transcript, launch, pid
        case updatedMs = "updated_ms"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1,
            let pane = ZellijPaneID(try c.decode(String.self, forKey: .pane))
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath, debugDescription: "Unsupported Zellij state document"))
        }
        self.pane = pane
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        status = try c.decodeIfPresent(String.self, forKey: .status).flatMap(Self.status)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        launch = try c.decodeIfPresent(String.self, forKey: .launch)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        updatedMs = try c.decodeIfPresent(Int64.self, forKey: .updatedMs)
    }

    static func decode(_ data: Data) -> Self? { try? JSONDecoder().decode(Self.self, from: data) }

    static func status(_ word: String) -> AgentStatus? {
        switch word {
        case "working": .working
        case "blocked": .blocked
        case "done": .done
        case "idle": .idle
        default: nil
        }
    }
}
