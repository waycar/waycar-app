import Foundation
import Testing

@testable import Waycar

/// The same id/file/document cases Rust consumes; no Swift-only copy of the contract.
@Suite("Zellij pane state vectors")
struct ZellijPaneStateVectorTests {
    struct Vectors: Decodable, Sendable {
        struct IDCase: Decodable, Sendable {
            struct Expected: Decodable, Sendable {
                let session: String
                let pane: Int
            }
            let id: String
            let expected: Expected?
        }
        struct FileCase: Decodable, Sendable {
            let id: String
            let file: String
        }
        struct DocumentCase: Decodable, Sendable {
            struct Expected: Decodable, Sendable, Equatable {
                let pane: String
                let kind: String?
                let status: String?
                let seq: Int?
                let session: String?
                let transcript: String?
                let launch: String?
                let updatedMs: Int64?
            }
            let name: String
            let document: JSONValue
            let expected: Expected?
        }
        let paneIds: [IDCase]
        let fileNames: [FileCase]
        let documents: [DocumentCase]
    }

    static let vectors: Vectors = {
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle(for: BundleLocator.self)
        #endif
        guard let url = bundle.url(forResource: "zellij-pane-state-v1", withExtension: "json") else {
            fatalError("Missing Zellij shared vectors")
        }
        do { return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)) } catch {
            fatalError("Invalid Zellij shared vectors: \(error)")
        }
    }()
    private final class BundleLocator {}

    @Test(arguments: vectors.paneIds)
    func paneIDs(_ vector: Vectors.IDCase) {
        let id = ZellijPaneID(vector.id)
        #expect(id?.session == vector.expected?.session)
        #expect(id?.pane == vector.expected?.pane)
        if id != nil { #expect(id?.description == vector.id) }
    }

    @Test(arguments: vectors.fileNames)
    func fileNames(_ vector: Vectors.FileCase) { #expect(ZellijPaneID(vector.id)?.fileName == vector.file) }

    @Test(arguments: vectors.documents)
    func documents(_ vector: Vectors.DocumentCase) throws {
        let state = ZellijPaneState.decode(try JSONEncoder().encode(vector.document))
        guard let expected = vector.expected else {
            #expect(state == nil)
            return
        }
        let actual = try #require(state)
        #expect(actual.pane.description == expected.pane)
        #expect(actual.kind == expected.kind)
        #expect(actual.status?.rawValue == expected.status)
        #expect(actual.seq == expected.seq)
        #expect(actual.session == expected.session)
        #expect(actual.transcript == expected.transcript)
        #expect(actual.launch == expected.launch)
        #expect(actual.updatedMs == expected.updatedMs)
    }
}
