import Foundation

/// Tracks the reader's position in a script from a stream of (partial) speech transcripts.
///
/// Every update aligns the last `tailLength` spoken words against a window of the script around the
/// current position. It uses a Smith-Waterman local alignment with fuzzy word similarity:
///  * ad-libs            -> gaps on the spoken side (cheap)
///  * skipped words      -> gaps on the script side (cheap)
///  * misrecognitions    -> substitutions, or fuzzy/homophone matches
///  * repeated phrases   -> a distance penalty prefers the nearest occurrence
/// Big moves need more evidence. Jumps past `smallJump` words, or backward jumps, need more matched
/// words and must be confirmed by two consecutive updates. A jump outside the window needs a strong,
/// unambiguous match anywhere in the script, and is only tried after several updates fail to match
/// locally.
public final class ScriptAligner {
    public struct Config: Sendable {
        public var tailLength = 8
        public var backWindow = 30
        public var forwardWindow = 60
        public var smallJump = 12
        public var matchReward = 2.0
        public var mismatchPenalty = -1.0
        public var adLibPenalty = -0.7       // spoken word not in the script
        public var skipPenalty = -0.6        // script word the reader skipped
        public var trailingPenalty = 0.5     // per spoken word after the alignment's end (fresh ad-lib)
        public var forwardCost = 0.03        // per token of forward distance
        public var backwardCost = 0.15       // per token of backward distance
        public var lostAfterMisses = 3
        public init() {}
    }

    public struct Decision: Sendable, CustomStringConvertible {
        public enum Kind: String, Sendable { case advanced, stayed, heldForConfirmation, rejected, globalJump, noInput }
        public let kind: Kind
        public let position: Int
        public let candidate: Int?
        public let matched: Int
        public var description: String {
            "\(kind.rawValue) pos=\(position) cand=\(candidate.map(String.init) ?? "-") matched=\(matched)"
        }
    }

    public private(set) var position: Int = -1   // index of the last token read; -1 = not started
    public private(set) var lastDecision: Decision?
    public var config: Config
    public var isLost: Bool { misses >= config.lostAfterMisses }

    private var words: [String]
    private var history: [String] = []           // tokens from earlier recognizer segments
    private var segment: Int = .min
    private var segmentTokens: [String] = []
    private var segmentSkip = 0                  // tokens of the current segment spoken before a manual reset
    private var pending: (target: Int, count: Int)?
    private var misses = 0
    private var simCache: [String: [String: Double]] = [:]

    private func similarity(_ spoken: String, _ word: String) -> Double {
        if spoken == word { return 1 }
        if let v = simCache[spoken]?[word] { return v }
        if simCache.count > 2000 { simCache.removeAll(keepingCapacity: true) }
        let v = WordSimilarity.score(spoken, word)
        simCache[spoken, default: [:]][word] = v
        return v
    }

    public init(script: Script, config: Config = Config()) {
        self.words = script.tokens.map(\.word)
        self.config = config
    }

    public func load(script: Script) {
        words = script.tokens.map(\.word)
        reset(to: -1)
    }

    /// Moves the cursor manually (reset, click-to-jump, nudge). Spoken context so far is dropped
    /// so it can't pull the cursor back.
    public func reset(to newPosition: Int) {
        position = max(-1, min(newPosition, words.count - 1))
        history = []
        segmentSkip = segmentTokens.count
        pending = nil
        misses = 0
    }

    /// Feeds the recognizer's current hypothesis for `segment` (the full text of that recognition task so far).
    /// Returns the new position if the cursor moved.
    @discardableResult
    public func ingest(segment newSegment: Int, text: String) -> Int? {
        if newSegment != segment {
            history = Array((history + segmentTokens.dropFirst(segmentSkip)).suffix(config.tailLength * 2))
            segment = newSegment
            segmentTokens = []
            segmentSkip = 0
        }
        let tokens = Normalizer.tokens(forText: text)
        guard tokens != segmentTokens else { return nil }
        segmentTokens = tokens
        segmentSkip = min(segmentSkip, tokens.count)
        let spoken = Array((history + tokens.dropFirst(segmentSkip)).suffix(config.tailLength))
        guard !spoken.isEmpty, !words.isEmpty else {
            lastDecision = Decision(kind: .noInput, position: position, candidate: nil, matched: 0)
            return nil
        }
        return decide(spoken: spoken)
    }

    // MARK: - Decision

    private func decide(spoken: [String]) -> Int? {
        let lo = max(0, position - config.backWindow)
        let hi = min(words.count - 1, max(position, 0) + config.forwardWindow)
        let local = bestCandidates(spoken: spoken, lo: lo, hi: hi).first

        if let c = local, c.matched >= 1 {
            let delta = c.end - position
            let accepted: Bool
            var needsConfirm = false
            if delta == 0 {
                misses = 0; pending = nil
                return record(.stayed, c, moved: false)
            } else if delta > 0 && delta <= config.smallJump {
                // Normal reading. One matched word is enough only right next to the cursor.
                accepted = c.matched >= 2 || (delta <= 2 && c.endsAtLatestWord)
            } else if delta > 0 {
                accepted = c.matched >= 3; needsConfirm = true
            } else if delta >= -2 {
                // Tiny backward moves are almost always partial-result revisions. Ignore them.
                pending = nil
                return record(.stayed, c, moved: false)
            } else {
                accepted = c.matched >= 4; needsConfirm = true
            }
            if accepted {
                if needsConfirm && !confirm(c) { return record(.heldForConfirmation, c, moved: false) }
                misses = 0; pending = nil
                position = c.end
                return record(.advanced, c, moved: true)
            }
        }

        misses += 1
        if misses >= config.lostAfterMisses, let g = globalCandidate(spoken: spoken) {
            if confirm(g) {
                misses = 0; pending = nil
                position = g.end
                return record(.globalJump, g, moved: true)
            }
            return record(.heldForConfirmation, g, moved: false)
        }
        lastDecision = Decision(kind: .rejected, position: position, candidate: local?.end, matched: local?.matched ?? 0)
        return nil
    }

    /// Big jumps need two consecutive updates that agree, and each must end on a freshly spoken
    /// matching word. Re-aligning the same stale words doesn't count as new evidence.
    private func confirm(_ c: Candidate) -> Bool {
        guard c.endsAtLatestWord else { return false }
        if let p = pending, c.end > p.target, c.end - p.target <= 3 {
            pending = (c.end, p.count + 1)
            return p.count + 1 >= 2
        }
        pending = (c.end, 1)
        return false
    }

    private func record(_ kind: Decision.Kind, _ c: Candidate, moved: Bool) -> Int? {
        lastDecision = Decision(kind: kind, position: position, candidate: c.end, matched: c.matched)
        return moved ? position : nil
    }

    /// Far jumps anywhere in the script. Needs most of the tail to match, and the best match
    /// must clearly beat any other region (repeated boilerplate is ambiguous, so we stay put).
    private func globalCandidate(spoken: [String]) -> Candidate? {
        guard spoken.count >= 5 else { return nil }
        let all = bestCandidates(spoken: spoken, lo: 0, hi: words.count - 1, distanceCost: false)
        guard let best = all.first, best.matched >= min(5, spoken.count - 1), best.exact >= 4 else { return nil }
        let rival = all.dropFirst().first { abs($0.end - best.end) > 10 }
        if let rival, best.score - rival.score < 2.0 { return nil }
        return best
    }

    // MARK: - Local alignment

    struct Candidate {
        var end: Int            // script token index of the alignment's last matched word
        var score: Double       // alignment score after trailing/distance penalties
        var matched: Int
        var exact: Int
        var endsAtLatestWord: Bool
    }

    /// Smith-Waterman over spoken x script[lo...hi]. Returns one candidate per end column, best first.
    func bestCandidates(spoken: [String], lo: Int, hi: Int, distanceCost: Bool = true) -> [Candidate] {
        guard lo <= hi else { return [] }
        let cfg = config
        let m = spoken.count, n = hi - lo + 1
        var H = [Double](repeating: 0, count: (m + 1) * (n + 1))
        var M = [Int](repeating: 0, count: (m + 1) * (n + 1))
        var E = [Int](repeating: 0, count: (m + 1) * (n + 1))
        var best = [Int: Candidate]()
        let idx = { (i: Int, j: Int) in i * (n + 1) + j }

        for i in 1...m {
            let sw = spoken[i - 1]
            for j in 1...n {
                let sim = similarity(sw, words[lo + j - 1])
                let d = idx(i - 1, j - 1)
                var h = 0.0, mm = 0, ee = 0, isMatch = false
                if sim >= WordSimilarity.matchThreshold {
                    h = H[d] + cfg.matchReward * sim; mm = M[d] + 1; ee = E[d] + (sim == 1 ? 1 : 0); isMatch = true
                } else if H[d] + cfg.mismatchPenalty > 0 {
                    h = H[d] + cfg.mismatchPenalty; mm = M[d]; ee = E[d]
                }
                let up = idx(i - 1, j), left = idx(i, j - 1)
                if H[up] + cfg.adLibPenalty > h { h = H[up] + cfg.adLibPenalty; mm = M[up]; ee = E[up]; isMatch = false }
                if H[left] + cfg.skipPenalty > h { h = H[left] + cfg.skipPenalty; mm = M[left]; ee = E[left]; isMatch = false }
                let c = idx(i, j)
                H[c] = h; M[c] = mm; E[c] = ee

                guard isMatch else { continue }
                let end = lo + j - 1
                var score = h - cfg.trailingPenalty * Double(m - i)
                if distanceCost {
                    let delta = end - position
                    score -= delta >= 0 ? cfg.forwardCost * Double(delta) : cfg.backwardCost * Double(-delta)
                }
                if best[end].map({ score > $0.score }) ?? true {
                    best[end] = Candidate(end: end, score: score, matched: mm, exact: ee, endsAtLatestWord: i == m)
                }
            }
        }
        return best.values.sorted { $0.score > $1.score }
    }
}
