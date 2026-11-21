import Foundation
import XCTest

@testable import TalaDB

/// deriveDocId, projection on find/watch, and engine error codes (0.2.3).
final class HotfixAPITests: DatabaseTestCase {
    // MARK: - deriveDocId

    /// The cross-language contract: these vectors are duplicated verbatim in
    /// the engine (`packages/core/src/document.rs`) and in the JavaScript
    /// client's `derive-id.test.ts`. If Swift disagreed, two clients would
    /// give the same row different ids — with no error anywhere.
    func testDeriveDocIdMatchesTheEngineByteForByte() {
        let vectors: [(String, String, String)] = [
            ("products", "sku-123", "56GC678DQYWW1Z98HPYJ90WVKH"),
            ("products", "1", "7Z6Y6H8NG96ZGN4PJVDP18CSY2"),
            ("orders", "1", "5VYD63GDV5KCDXV2A0SYRWSKVZ"),
            ("", "", "6J535PJ40THJQQH49BE174M53Z"),
            // Hashed over UTF-8 bytes, not UTF-16 code units or characters.
            ("products", "sku-ñ-💡", "5NZ0PGNM2CF0BTHN0AAX8CWPAA"),
        ]
        for (collection, key, expected) in vectors {
            XCTAssertEqual(deriveDocId(collection: collection, key: key), expected, "(\(collection), \(key))")
        }
    }

    /// Edge cases the shared vectors do not reach, with ids produced by the
    /// engine's Rust `derive_doc_id`. The hash is over UTF-8 bytes: a NUL is
    /// hashed rather than ending the string, and two canonically equal
    /// spellings of "é" (equal under Swift's `==`) give different ids.
    func testDeriveDocIdEdgeCasesMatchTheEngine() {
        let vectors: [(String, String, String)] = [
            ("", "\u{0}", "08G2A5PKXB3FMNN83K61AJEE25"),
            ("\u{E9}", "e\u{301}", "2S7GSMHVSWCJZPSTH3X3G444MH"),
            ("e\u{301}", "\u{E9}", "6MCHGNRRSWCJZPY0S48G08EMHS"),
            ("\u{10FFFF}", "\u{FEFF}", "76AC2ZZ635K3RCTM5XN24MM2SD"),
        ]
        for (collection, key, expected) in vectors {
            XCTAssertEqual(
                deriveDocId(collection: collection, key: key), expected,
                "(\(Array(collection.utf8)), \(Array(key.utf8)))")
        }
    }

    func testDeriveDocIdSeparatesCollectionFromKey() {
        XCTAssertNotEqual(deriveDocId(collection: "ab", key: "c"), deriveDocId(collection: "a", key: "bc"))
        XCTAssertNotEqual(deriveDocId(collection: "products", key: "1"), deriveDocId(collection: "orders", key: "1"))
    }

    func testADerivedIdIsAcceptedAsAnIdAndRefusedTwice() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let meta = db.collection("meta", as: Note.self)
        let id = deriveDocId(collection: "meta", key: "settings")

        let stored = try await meta.insert(Note(id: id, title: "settings"))
        XCTAssertEqual(stored, id)
        let found = try await meta.findOne(["_id": .string(id)])
        XCTAssertEqual(found?.title, "settings")
        await assertThrowsAsync(try await meta.insert(Note(id: id, title: "again"))) {
            ($0 as? TalaDBError)?.code == TalaDBErrorCode.duplicateId
        }
    }

    // MARK: - Projection

    /// A document whose embedding is optional, so a projection can leave it out.
    struct Embedded: Codable, Sendable, Equatable {
        var id: String?
        var text: String?
        var embedding: [Float]?
        enum CodingKeys: String, CodingKey {
            case id = "_id"
            case text, embedding
        }
    }

    func testFindLeavesOutExcludedFieldsAndKeepsOnlyListedOnes() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Embedded.self)
        let id = try await notes.insert(Embedded(text: "Read aloud", embedding: [0.25, 0.5]))

        let without = try await notes.find([:], options: .exclude(["embedding"]))
        XCTAssertEqual(without, [Embedded(id: id, text: "Read aloud", embedding: nil)])

        let only = try await notes.find([:], options: .fields(["embedding"]))
        XCTAssertEqual(only, [Embedded(id: id, text: nil, embedding: [0.25, 0.5])])

        let everything = try await notes.find([:])
        XCTAssertEqual(everything, [Embedded(id: id, text: "Read aloud", embedding: [0.25, 0.5])])
    }

    func testWatchProjectsTheInitialStateAndEveryUpdate() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Embedded.self)
        try await notes.insert(Embedded(text: "first", embedding: [1, 0]))

        var iterator = notes.watch([:], options: .exclude(["embedding"])).makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.map(\.text), ["first"])
        XCTAssertEqual(initial?.compactMap(\.embedding), [])

        try await notes.insert(Embedded(text: "second", embedding: [0, 1]))
        let updated = try await iterator.next()
        XCTAssertEqual(Set(updated?.compactMap(\.text) ?? []), ["first", "second"])
        XCTAssertEqual(updated?.compactMap(\.embedding), [], "an update must be projected like the first snapshot")
    }

    func testAProjectionNamingAMissingFieldIsHarmless() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)
        try await notes.insert(Note(title: "plain"))
        let found = try await notes.find(["title": "plain"], options: .exclude(["embedding"]))
        XCTAssertEqual(found.map(\.title), ["plain"])
    }

    /// The engine's projection contract: `_id` always survives, names are
    /// top-level keys (a dotted name is not a nested path), and an empty
    /// `FindOptions` changes nothing.
    func testProjectionKeepsIdAndOnlyTopLevelFields() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let docs = db.collection("docs")
        let id = try await docs.insert(["a": 1, "meta": ["title": "t"]])

        let onlyId = try await docs.find([:], options: .fields([]))
        XCTAssertEqual(onlyId, [["_id": .string(id)]])
        let excludeId = try await docs.find([:], options: .exclude(["_id"]))
        XCTAssertEqual(excludeId.first?["_id"], .string(id))
        let dotted = try await docs.find([:], options: .fields(["meta.title"]))
        XCTAssertEqual(dotted, [["_id": .string(id)]])
        let plain = try await docs.find()
        let empty = try await docs.find([:], options: FindOptions())
        XCTAssertEqual(empty, plain)
    }

    // MARK: - Error codes

    /// Codes come from the direct native entry points too, not only from
    /// `taladb_call`.
    func testCodesSurfaceFromDirectNativeCallsToo() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let docs = db.collection("docs", as: Doc.self)
        await assertThrowsAsync(try await docs.dropIndex("missing")) {
            ($0 as? TalaDBError)?.code == TalaDBErrorCode.indexNotFound
        }
        await assertThrowsAsync(try await docs.findNearest("embedding", vector: [1, 0], topK: 1)) {
            ($0 as? TalaDBError)?.code == TalaDBErrorCode.vectorIndexNotFound
        }
    }

    func testAnInvalidFilterCarriesItsCode() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        await assertThrowsAsync(try await db.collection("books").find(["n": ["$frobnicate": 1]])) { error in
            guard case TalaDBError.engine(let message, let code) = error else { return false }
            return code == TalaDBErrorCode.invalidFilter && message.hasPrefix("invalid filter")
        }
    }

    func testAWrongPassphraseIsAnEncryptionError() async throws {
        let url = file()
        let db = try await TalaDB.open(at: url, config: TalaDBConfig(passphrase: "right"))
        try await db.collection("notes", as: Note.self).insert(Note(title: "secret"))
        db.close()

        await assertThrowsAsync(try await TalaDB.open(at: url, config: TalaDBConfig(passphrase: "wrong"))) {
            ($0 as? TalaDBError)?.code == TalaDBErrorCode.encryption
        }
    }

    func testErrorsThatAreNotFromTheEngineHaveNoCode() {
        XCTAssertNil(TalaDBError.closed.code)
        XCTAssertNil(TalaDBError.invalidArgument("x").code)
        // Constructing an engine error without a code still works, and its
        // description is the message alone.
        XCTAssertNil(TalaDBError.engine("boom").code)
        XCTAssertEqual(TalaDBError.engine("boom", code: "Storage").description, "boom")
    }
}
