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
        enum CodingKeys: String, CodingKey { case id = "_id", text, embedding }
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

    // MARK: - Error codes

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
