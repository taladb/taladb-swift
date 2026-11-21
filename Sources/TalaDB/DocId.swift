import Foundation

/// A stable document `_id` for a row that already has an identity elsewhere:
/// the same `(collection, key)` always maps to the same id.
///
/// `insert` accepts an `_id`, but it must be a ULID — ids are 16 raw bytes on
/// disk — so `"sku-1"` or `"settings"` cannot be stored as one. Hashing the key
/// into a ULID bridges the two. Inserting a document under its derived id a
/// second time fails as a duplicate instead of minting another copy, which
/// makes syncing a row, or creating a singleton document, idempotent.
///
/// ```swift
/// let settingsID = deriveDocId(collection: "meta", key: "settings")
/// ```
///
/// The result is byte-identical to the engine's Rust `derive_doc_id` and to
/// `deriveDocId` in the JavaScript and Kotlin bindings (FNV-1a 128 over the
/// UTF-8 of `collection`, a 0x00 separator and `key`, encoded as Crockford
/// base32), so every client addresses the same row with the same id.
///
/// A derived id is a hash, so its ULID timestamp prefix is not chronological:
/// documents inserted with one do not come back in insertion order from an
/// unsorted `find`.
public func deriveDocId(collection: String, key: String) -> String {
    var hash = FNV1a128.offsetBasis
    for byte in collection.utf8 { hash.mix(byte) }
    // The separator keeps the preimage unambiguous: ("ab", "c") and ("a", "bc")
    // would otherwise hash identically.
    hash.mix(0)
    for byte in key.utf8 { hash.mix(byte) }
    return hash.ulid
}

/// A 128-bit FNV-1a state as two 64-bit halves.
private struct FNV1a128 {
    var high: UInt64
    var low: UInt64

    static let offsetBasis = FNV1a128(high: 0x6c62_272e_07bb_0142, low: 0x62b8_2175_6295_c58d)

    /// XOR in one byte, then multiply by the FNV prime 2^88 + 0x13B, modulo 2^128.
    mutating func mix(_ byte: UInt8) {
        low ^= UInt64(byte)
        // value × 0x13B: the low half's full 128-bit product, plus the high
        // half's product truncated to 64 bits.
        let (carry, lowProduct) = low.multipliedFullWidth(by: 0x13B)
        var newHigh = carry &+ high &* 0x13B
        // value × 2^88: only the low half survives the modulus, shifted into
        // the high half by 88 − 64 = 24 bits.
        newHigh = newHigh &+ (low << 24)
        high = newHigh
        low = lowProduct
    }

    /// 26 Crockford-base32 characters, most significant first. 26 × 5 = 130
    /// bits, so the first character carries only the top 3 bits.
    var ulid: String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var out = ""
        out.reserveCapacity(26)
        for index in stride(from: 25, through: 0, by: -1) {
            out.append(alphabet[Int(bits(at: index * 5))])
        }
        return out
    }

    /// The 5 bits starting at bit `offset` (0 = least significant).
    private func bits(at offset: Int) -> UInt64 {
        let value: UInt64
        if offset >= 64 {
            value = high >> UInt64(offset - 64)
        } else if offset + 5 <= 64 {
            value = low >> UInt64(offset)
        } else {
            value = (low >> UInt64(offset)) | (high << UInt64(64 - offset))
        }
        return value & 0x1F
    }
}
