import Foundation

/// An error from TalaDB.
public enum TalaDBError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Reported by the engine: an invalid filter, a missing index, a duplicate
    /// `_id`, a wrong passphrase, a storage failure.
    ///
    /// `code` names the kind of failure — one of ``TalaDBErrorCode`` — so a
    /// caller can branch on it without parsing the message: `"Encryption"` for
    /// a wrong passphrase, `"DuplicateId"`, `"InvalidFilter"`. It is nil for
    /// failures the engine did not classify.
    ///
    /// Match the message alone with `case .engine(let message, _)`, or read
    /// ``code`` from any `TalaDBError`.
    case engine(String, code: String? = nil)
    /// The database was closed.
    case closed
    /// An argument this package rejected before calling the engine.
    case invalidArgument(String)
    /// A result could not be decoded as the requested type.
    case decoding(String)
    /// The bundled engine library and the header this package was built
    /// against disagree on the C ABI version — they come from different
    /// engine releases.
    case incompatibleEngine(header: UInt32, library: UInt32)

    /// The engine's error code for an ``engine(_:code:)`` error; nil for every
    /// other case and for failures the engine did not classify.
    public var code: String? {
        if case .engine(_, let code) = self { return code }
        return nil
    }

    public var description: String {
        switch self {
        case .engine(let message, _): return message
        case .closed: return "TalaDB database is closed"
        case .invalidArgument(let message): return message
        case .decoding(let message): return "TalaDB result could not be decoded: \(message)"
        case .incompatibleEngine(let header, let library):
            return "TalaDB engine library has C ABI version \(library), but this package was built for \(header)"
        }
    }
}

/// Options for `TalaDB.open`.
public struct TalaDBConfig: Sendable, CustomStringConvertible {
    /// Encrypts the database at rest. Opening an encrypted database requires
    /// the same passphrase; opening it without one, or with the wrong one,
    /// throws.
    public var passphrase: String?
    /// `true` (the default) syncs every write to disk, so an acknowledged
    /// write survives a crash. `false` batches commits for higher write
    /// throughput; call `flush()` to force a durable sync.
    public var flushEveryWrite: Bool

    public init(passphrase: String? = nil, flushEveryWrite: Bool = true) {
        self.passphrase = passphrase
        self.flushEveryWrite = flushEveryWrite
    }

    /// Never prints the passphrase, so a config can be logged safely.
    public var description: String {
        "TalaDBConfig(passphrase: \(passphrase == nil ? "nil" : "<redacted>"), flushEveryWrite: \(flushEveryWrite))"
    }

    func json() throws -> String {
        var object: [String: JSONValue] = ["durability": ["flush_every_write": .bool(flushEveryWrite)]]
        if let passphrase { object["passphrase"] = .string(passphrase) }
        return try jsonText(JSONValue.object(object))
    }
}

/// Similarity measure for a vector index. HNSW supports `cosine` and `euclidean`.
public enum VectorMetric: String, Sendable, Codable {
    case cosine
    case dot
    case euclidean
}

/// Vector compression inside an HNSW graph. `binary` requires `.cosine`.
public enum Quantization: String, Sendable, Codable {
    case unquantized = "none"
    case scalar
    case binary
}

/// Build a persistent HNSW graph instead of using exact search.
///
/// Exact search is faster at small sizes and always exact; reach for HNSW once
/// a collection holds tens of thousands of vectors. Requires `2 <= m <= 128`
/// and `m <= efConstruction <= 100000`.
public struct HnswOptions: Sendable, Codable, Equatable {
    public var m: Int
    public var efConstruction: Int
    public var quantization: Quantization

    public init(m: Int = 32, efConstruction: Int = 200, quantization: Quantization = .unquantized) {
        self.m = m
        self.efConstruction = efConstruction
        self.quantization = quantization
    }
}

/// The engine's error codes, as carried by ``TalaDBError/engine(_:code:)``.
///
/// They are a public contract shared with every TalaDB binding: new codes may
/// be added, and an existing one never changes meaning. Compare with them
/// rather than with error messages, which may be reworded.
public enum TalaDBErrorCode {
    /// A wrong passphrase, a passphrase for an unencrypted database, or none
    /// for an encrypted one.
    public static let encryption = "Encryption"
    public static let duplicateId = "DuplicateId"
    public static let invalidFilter = "InvalidFilter"
    public static let invalidDocumentId = "InvalidDocumentId"
    public static let invalidName = "InvalidName"
    public static let invalidOperation = "InvalidOperation"
    public static let indexExists = "IndexExists"
    public static let indexNotFound = "IndexNotFound"
    public static let vectorIndexNotFound = "VectorIndexNotFound"
    public static let vectorDimensionMismatch = "VectorDimensionMismatch"
    public static let compoundIndexMultipleArrays = "CompoundIndexMultipleArrays"
    public static let notFound = "NotFound"
    public static let typeError = "TypeError"
    public static let serialization = "Serialization"
    public static let storage = "Storage"
    public static let migration = "Migration"
    public static let config = "Config"
    public static let invalidSnapshot = "InvalidSnapshot"
    public static let queryTimeout = "QueryTimeout"
    public static let searchMemoryLimit = "SearchMemoryLimit"
    public static let changesetTooLarge = "ChangesetTooLarge"
    public static let watchBackpressure = "WatchBackpressure"
    public static let watchClosed = "WatchClosed"
}

/// Which fields `find` and `watch` return. Leaving out a large field a screen
/// does not show — an embedding — keeps every result, and every live-query
/// update, small.
///
/// `_id` is always returned. A document type read with a projection must
/// tolerate the missing fields, for example by declaring them optional.
public struct FindOptions: Sendable, Equatable {
    /// Return only these fields (plus `_id`); nil returns every field.
    public var fields: [String]?
    /// Leave these fields out.
    public var exclude: [String]?

    public init(fields: [String]? = nil, exclude: [String]? = nil) {
        self.fields = fields
        self.exclude = exclude
    }

    /// Only `fields`, plus `_id`.
    public static func fields(_ fields: [String]) -> FindOptions { FindOptions(fields: fields) }

    /// Every field except `fields`.
    public static func exclude(_ fields: [String]) -> FindOptions { FindOptions(exclude: fields) }

    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let fields { o["fields"] = .array(fields.map(JSONValue.string)) }
        if let exclude { o["exclude"] = .array(exclude.map(JSONValue.string)) }
        return .object(o)
    }
}

/// BM25 parameters for full-text and hybrid search. `nil` keeps the engine default.
public struct Bm25Options: Sendable, Equatable {
    public var k1: Double?
    public var b: Double?

    public init(k1: Double? = nil, b: Double? = nil) {
        self.k1 = k1
        self.b = b
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let k1 { o["k1"] = .double(k1) }
        if let b { o["b"] = .double(b) }
        return .object(o)
    }
}

/// Reciprocal rank fusion parameters for `hybridSearch`. `nil` keeps the engine default.
public struct HybridOptions: Sendable, Equatable {
    public var rrfK: Double?
    public var textWeight: Double?
    public var vectorWeight: Double?
    /// How many results each of the text and vector searches contributes before fusion.
    public var candidates: Int?
    public var bm25: Bm25Options

    public init(
        rrfK: Double? = nil,
        textWeight: Double? = nil,
        vectorWeight: Double? = nil,
        candidates: Int? = nil,
        bm25: Bm25Options = Bm25Options()
    ) {
        self.rrfK = rrfK
        self.textWeight = textWeight
        self.vectorWeight = vectorWeight
        self.candidates = candidates
        self.bm25 = bm25
    }

    var json: JSONValue {
        guard case .object(var o) = bm25.json else { return .object([:]) }
        if let rrfK { o["rrfK"] = .double(rrfK) }
        if let textWeight { o["textWeight"] = .double(textWeight) }
        if let vectorWeight { o["vectorWeight"] = .double(vectorWeight) }
        if let candidates { o["candidates"] = .int(Int64(candidates)) }
        return .object(o)
    }
}

/// A document with its similarity or relevance score. Higher is closer.
public struct ScoredDocument<Document: Decodable & Sendable>: Decodable, Sendable {
    public let document: Document
    public let score: Double
}

/// A `hybridSearch` result.
public struct HybridHit<Document: Decodable & Sendable>: Decodable, Sendable {
    public let document: Document
    /// The fused reciprocal-rank score: small by construction, and meaningful
    /// only for ordering within one result list.
    public let score: Double
    /// Zero-based position in the text ranking, or nil if the text search did
    /// not return this document.
    public let textRank: Int?
    /// Zero-based position in the vector ranking, or nil if the vector search
    /// did not return this document.
    public let vectorRank: Int?
}

/// The indexes on one collection, by field.
public struct IndexInfo: Decodable, Sendable, Equatable {
    public let btree: [String]
    public let fts: [String]
    public let vector: [String]
}
