import Foundation

/// Fuzzy similarity between two normalized tokens, in 0...1.
/// Tolerates common recognizer errors: homophones, inflections and near-miss spellings.
public enum WordSimilarity {
    /// Scores below this count as a mismatch.
    public static let matchThreshold = 0.72

    private static let homophoneGroups: [[String]] = [
        ["to", "too", "two"], ["there", "their", "theyre"], ["for", "four", "fore"], ["your", "youre"],
        ["know", "no"], ["right", "write", "rite"], ["by", "buy", "bye"], ["here", "hear"],
        ["one", "won"], ["whos", "whose"], ["then", "than"], ["weather", "whether"], ["new", "knew"],
        ["see", "sea"], ["be", "bee"], ["our", "hour"], ["ok", "okay"], ["alright", "allright"],
        ["gonna", "going"], ["wanna", "want"], ["were", "where"], ["whole", "hole"], ["week", "weak"],
    ]
    private static let canonical: [String: String] = {
        var m: [String: String] = [:]
        for g in homophoneGroups { for w in g { m[w] = g[0] } }
        return m
    }()

    public static func score(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if let ca = canonical[a], ca == canonical[b] { return 0.9 }
        let la = a.count, lb = b.count
        // Inflections: "run"/"running", "present"/"presentation" (prefix of at least 4 letters).
        if min(la, lb) >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return 0.8 }
        // Very short words must match exactly or as homophones. Edit distance is meaningless at length 1-3.
        if min(la, lb) <= 3 { return 0 }
        // Lengths too different to ever reach the threshold: skip the edit distance.
        if Double(abs(la - lb)) / Double(max(la, lb)) > 1 - matchThreshold { return 0 }
        let ratio = 1 - Double(levenshtein(a, b)) / Double(max(la, lb))
        return ratio >= matchThreshold ? ratio : 0
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf8), b = Array(b.utf8)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
