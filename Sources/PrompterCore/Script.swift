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
    /// Paragraph number of each token (parallel to `tokens`). Paragraphs are separated by blank lines
    /// and numbered 0, 1, 2... counting only paragraphs that contain at least one spoken word.
    public let paragraphOfToken: [Int]
    /// Index of the first token of each paragraph.
    public let paragraphStarts: [Int]
    public var paragraphCount: Int { paragraphStarts.count }

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

        // Paragraph breaks: a newline, optional blank-ish lines, and another newline.
        let breaks = try! NSRegularExpression(pattern: "\\r?\\n([ \\t]*\\r?\\n)+")
            .matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range.location }
        var paragraphs: [Int] = [], starts: [Int] = []
        var rawOfPrevious = -1, dense = -1, b = 0
        for (i, t) in tokens.enumerated() {
            while b < breaks.count, breaks[b] < t.range.location { b += 1 }
            if b != rawOfPrevious { rawOfPrevious = b; dense += 1; starts.append(i) }
            paragraphs.append(dense)
        }
        self.paragraphOfToken = paragraphs
        self.paragraphStarts = starts
    }

    /// Paragraph the given token index (the last word read) is in, or nil before the start.
    public func paragraph(at position: Int) -> Int? {
        position >= 0 && position < paragraphOfToken.count ? paragraphOfToken[position] : nil
    }

    /// Token range [start, end) of a paragraph.
    public func tokenRange(ofParagraph p: Int) -> Range<Int> {
        guard p >= 0, p < paragraphStarts.count else { return 0..<0 }
        return paragraphStarts[p]..<(p + 1 < paragraphStarts.count ? paragraphStarts[p + 1] : tokens.count)
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
