import Foundation

/// Small, dependency-free text helpers shared by retrieval, prompting and the
/// zero-model extractive engine.
public enum TextUtil {

    /// Sentence-ish split that keeps abbreviations from shattering the text.
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 3 { out.append(trimmed) }
            current = ""
        }

        for scalar in text {
            current.append(scalar)
            guard ".!?".contains(scalar) else { continue }
            // Only break when the sentence looks finished: next char whitespace + capital,
            // and the tail is not a known abbreviation.
            let tail = current.trimmingCharacters(in: .whitespaces)
            let lastWord = tail.split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(String.init)?.lowercased() ?? ""
            let abbreviations: Set<String> = ["e.g.", "i.e.", "etc.", "cf.", "vs.", "fig.", "no.", "dr.", "mr.", "mrs.", "st.", "approx.", "ca."]
            if abbreviations.contains(lastWord) { continue }
            if lastWord.count <= 2 && lastWord.hasSuffix(".") && lastWord.first?.isLetter == true {
                // single-letter initialism like "J." — keep going
                if lastWord != "a." { continue }
            }
            flush()
        }
        flush()
        return out
    }

    /// Lowercased word tokens: letters, digits and internal apostrophes/hyphens.
    public static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if ch == "'" || ch == "-" || ch == "_" {
                if !current.isEmpty { current.append(ch) }
            } else {
                if !current.isEmpty {
                    out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'-_")))
                    current = ""
                }
            }
        }
        if !current.isEmpty {
            out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'-_")))
        }
        return out.filter { !$0.isEmpty }
    }

    /// Rough token estimate used for budgeting prompt space (~4 chars/token for English).
    public static func estimatedTokens(_ text: String) -> Int {
        max(1, Int((Double(text.count) / 4.0).rounded(.up)))
    }

    /// Collapse runs of whitespace and strip control characters.
    public static func normalizeWhitespace(_ text: String) -> String {
        var cleaned = String()
        cleaned.reserveCapacity(text.count)
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" {
                if !lastWasSpace { cleaned.unicodeScalars.append(" ") }
                lastWasSpace = true
            } else if scalar.value < 0x20 {
                continue
            } else {
                cleaned.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trim to a character budget on a word boundary.
    public static func truncate(_ text: String, maxCharacters: Int, ellipsis: String = "…") -> String {
        guard text.count > maxCharacters else { return text }
        let cut = text.prefix(maxCharacters)
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]).trimmingCharacters(in: .whitespaces) + ellipsis
        }
        return String(cut) + ellipsis
    }
}
