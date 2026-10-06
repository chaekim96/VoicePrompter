import Foundation

/// A script prepared for tracking: display text plus normalized tokens that point back into it.
public struct Script: Sendable {
    public struct Token: Sendable, Equatable {
        public let word: String
        /// UTF-16 range in `text` to highlight for this token. Several tokens can share one range
        /// (e.g. "2025" -> "two thousand twenty five").
        public let range: NSRange
    }

    public let text: String
    public let tokens: [Token]

    public init(text: String) {
        self.text = text
        var tokens: [Token] = []
        let ns = text as NSString
        // Chunks are runs of non-whitespace. The highlight range is trimmed of surrounding punctuation.
        let regex = try! NSRegularExpression(pattern: "\\S+")
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let chunk = ns.substring(with: m.range)
            let words = Normalizer.tokens(forChunk: chunk)
            guard !words.isEmpty else { continue }
            let range = Script.trimPunctuation(m.range, in: ns)
            tokens.append(contentsOf: words.map { Token(word: $0, range: range) })
        }
        self.tokens = tokens
    }

    public var isEmpty: Bool { tokens.isEmpty }

    /// Words worth passing to the recognizer as contextual hints: names, jargon and long words.
    public func contextualWords(limit: Int = 100) -> [String] {
        let ns = text as NSString
        var seen = Set<String>(), out: [String] = []
        for t in tokens {
            let original = ns.substring(with: t.range)
            let isProper = original.first?.isUppercase == true
            guard (isProper || original.count >= 8), seen.insert(original.lowercased()).inserted else { continue }
            out.append(original)
            if out.count >= limit { break }
        }
        return out
    }

    private static func trimPunctuation(_ r: NSRange, in s: NSString) -> NSRange {
        var start = r.location, end = r.location + r.length
        let isWordChar: (unichar) -> Bool = { c in
            guard let u = UnicodeScalar(c) else { return true }
            return CharacterSet.alphanumerics.contains(u) || c == 0x24 /* $ */ || c == 0x25 /* % */
        }
        while start < end, !isWordChar(s.character(at: start)) { start += 1 }
        while end > start, !isWordChar(s.character(at: end - 1)) { end -= 1 }
        return start < end ? NSRange(location: start, length: end - start) : r
    }
}

/// Light Markdown-to-plain-text conversion so imported .md scripts read naturally.
public enum ScriptImporter {
    public static func plainText(fromMarkdown md: String) -> String {
        var lines: [String] = []
        var inCodeFence = false
        for raw in md.components(separatedBy: .newlines) {
            var line = raw
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCodeFence.toggle(); continue }
            if inCodeFence { lines.append(line); continue }
            line = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*([-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*([-*_]\s*){3,}$"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(\*\*|__|\*|_|~~|`)(.+?)\1"#, with: "$2", options: .regularExpression)
            line = line.replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: .regularExpression)
            lines.append(line)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
