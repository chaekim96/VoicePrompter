import Foundation

/// Turns written or recognized text into comparable lowercase word tokens.
/// Script and transcript go through the same function, so "2025", "$5", "50%" and "rock & roll"
/// line up no matter which form the recognizer picks.
public enum Normalizer {
    private static let spellOut: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// Normalizes one whitespace-delimited chunk into zero or more tokens.
    public static func tokens(forChunk chunk: String) -> [String] {
        var s = chunk.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        s = s.replacingOccurrences(of: "’", with: "'")
        var out: [String] = []
        // Split on hyphens and slashes, which join separate spoken words ("well-known", "and/or").
        for piece in s.split(whereSeparator: { "-–—/".contains($0) }) {
            var p = String(piece)
            var suffix: [String] = []
            if p.hasPrefix("$") { p.removeFirst(); suffix.append("dollars") }
            if p.hasSuffix("%") { p.removeLast(); suffix.append("percent") }
            p = p.replacingOccurrences(of: "&", with: " and ")
            p = p.replacingOccurrences(of: "'", with: "")
            for word in p.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "," }) {
                out.append(contentsOf: normalizeWord(String(word)))
            }
            out.append(contentsOf: suffix)
        }
        return out
    }

    public static func tokens(forText text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).flatMap { tokens(forChunk: String($0)) }
    }

    private static func normalizeWord(_ w: String) -> [String] {
        let trimmed = w.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        guard !trimmed.isEmpty else { return [] }
        let digitsOnly = trimmed.replacingOccurrences(of: ",", with: "")
        if digitsOnly.allSatisfy(\.isNumber), let n = Double(digitsOnly), n < 1e12,
           let spelled = spellOut.string(from: NSNumber(value: n)) {
            return tokens(forText: spelled.replacingOccurrences(of: "-", with: " "))
        }
        // Words with internal periods or commas ("e.g", "U.S") collapse into one token.
        let letters = trimmed.filter { $0.isLetter || $0.isNumber }
        return letters.isEmpty ? [] : [letters]
    }
}
