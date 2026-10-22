import Foundation

/// Incremental UTF-8 decoder for token streams.
///
/// llama.cpp emits raw bytes per token; a single token can end in the middle of a
/// multi-byte scalar (CJK, emoji, combining accents). Decoding each piece with
/// `String(bytes:encoding:)` throws those bytes away and produces mojibake, so bytes
/// are buffered until a complete scalar is available.
public struct UTF8StreamDecoder {
    private var pending: [UInt8] = []

    public init() {}

    /// Bytes held back because they do not yet form a complete scalar.
    public var pendingByteCount: Int { pending.count }

    /// Feed a token's bytes, return whatever text is now decodable.
    public mutating func feed<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        pending.append(contentsOf: bytes)
        var cut = pending.count
        // Walk backwards over at most 3 continuation bytes to find a safe cut point.
        var i = pending.count - 1
        var looked = 0
        while i >= 0 && looked < 4 {
            let b = pending[i]
            if b & 0b1100_0000 == 0b1000_0000 {
                i -= 1
                looked += 1
                continue
            }
            let needed = Self.sequenceLength(lead: b)
            if needed == 0 { cut = i + 1 }              // invalid lead byte: pass it through
            else if i + needed <= pending.count { cut = i + needed }
            else { cut = i }                            // incomplete scalar at the tail
            break
        }
        if cut <= 0 { return "" }
        let slice = pending[0..<cut]
        pending.removeFirst(cut)
        return String(decoding: slice, as: UTF8.self)
    }

    /// Flush anything left (may contain replacement characters for truncated input).
    public mutating func flush() -> String {
        guard !pending.isEmpty else { return "" }
        let out = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: false)
        return out
    }

    static func sequenceLength(lead: UInt8) -> Int {
        switch lead {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return 0
        }
    }
}
