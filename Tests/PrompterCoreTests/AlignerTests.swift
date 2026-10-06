import XCTest
@testable import PrompterCore

final class AlignerTests: XCTestCase {
    let text = """
    Good morning everyone, and thank you for joining us today. We are here to talk about the future of our \
    product and where we want to take it over the next twelve months. First, let me share some numbers. \
    Revenue grew 40% last year, and customer retention reached an all-time high. Thank you all for making \
    that happen. Second, we are investing heavily in reliability, because our customers depend on us every \
    single day. Third, we will expand into two new markets in Europe and Asia. Finally, I want to say thank \
    you all for making that happen once again, and I am excited to answer your questions.
    """

    var script: Script { Script(text: text) }
    var words: [String] { script.tokens.map(\.word) }

    /// Feeds words one at a time as a growing partial transcript (how real recognizers behave).
    @discardableResult
    func speak(_ a: ScriptAligner, _ spoken: [String], segment: Int = 0, prefix: [String] = []) -> [String] {
        var said = prefix
        for w in spoken {
            said.append(w)
            a.ingest(segment: segment, text: said.joined(separator: " "))
        }
        return said
    }

    func testNormalization() {
        XCTAssertEqual(Normalizer.tokens(forText: "Revenue grew 40% in 2025!"),
                       ["revenue", "grew", "forty", "percent", "in", "two", "thousand", "twentyfive"].flatMap { $0 == "twentyfive" ? ["twenty", "five"] : [$0] })
        XCTAssertEqual(Normalizer.tokens(forText: "Don't stop—rock & roll, $5"), ["dont", "stop", "rock", "and", "roll", "five", "dollars"])
        XCTAssertEqual(Normalizer.tokens(forText: "well-known U.S. e.g."), ["well", "known", "us", "eg"])
    }

    func testHighlightRangesPointAtWords() {
        let s = Script(text: "Hello, world! 40% up.")
        let ns = s.text as NSString
        XCTAssertEqual(s.tokens.map { ns.substring(with: $0.range) }, ["Hello", "world", "40%", "40%", "up"])
    }

    func testSequentialReadingTracksEveryWord() {
        let a = ScriptAligner(script: script)
        var said: [String] = []
        for (i, w) in words.prefix(40).enumerated() {
            said.append(w)
            a.ingest(segment: 0, text: said.joined(separator: " "))
            XCTAssertEqual(a.position, i, "after word \(i) '\(w)'")
        }
    }

    func testToleratesMisrecognitionsAndAdLibs() {
        let a = ScriptAligner(script: script)
        var spoken = Array(words.prefix(30))
        spoken[5] = "thang"                                   // misrecognized "thank"
        spoken.insert(contentsOf: ["um", "you", "know"], at: 12) // ad-lib
        spoken[20] = "furniture"                              // wrong word entirely
        speak(a, spoken)
        XCTAssertEqual(a.position, 29)
    }

    func testAdLibAtTheEndDoesNotMoveCursor() {
        let a = ScriptAligner(script: script)
        let said = speak(a, Array(words.prefix(20)))
        speak(a, ["sorry", "let", "me", "grab", "some", "water"], prefix: said)
        XCTAssertEqual(a.position, 19)
        XCTAssertFalse(a.isLost == false && a.position != 19)
    }

    func testSkippedSentenceIsFollowed() {
        let a = ScriptAligner(script: script)
        let said = speak(a, Array(words.prefix(20)))
        // Skip ~14 words ahead and keep reading.
        speak(a, Array(words[34..<42]), prefix: said)
        XCTAssertEqual(a.position, 41)
    }

    func testRepeatedPhrasePrefersNearestOccurrence() {
        let a = ScriptAligner(script: script)
        // Read up to and including the first "thank you all for making that happen".
        let firstEnd = words.firstIndex(of: "happen")!
        speak(a, Array(words.prefix(firstEnd + 1)))
        XCTAssertEqual(a.position, firstEnd)
        // Repeating the phrase (re-reading) must not teleport to the second occurrence near the end.
        let phrase = ["thank", "you", "all", "for", "making", "that", "happen"]
        speak(a, phrase, segment: 1)
        XCTAssertLessThan(a.position, firstEnd + 5)
    }

    func testWeakEvidenceNeverJumpsFar() {
        let a = ScriptAligner(script: script)
        speak(a, Array(words.prefix(10)))
        // Words that exist much later in the script, but only one or two of them together.
        for junk in [["europe"], ["asia", "banana"], ["questions"], ["excited", "pizza"]] {
            speak(a, junk, segment: 7)
        }
        XCTAssertEqual(a.position, 9)
    }

    func testStrongEvidenceAllowsFarJumpAfterConfirmation() {
        let a = ScriptAligner(script: script)
        speak(a, Array(words.prefix(10)))
        let target = words.firstIndex(of: "europe")!
        // Speaker jumps way ahead and reads a distinctive passage.
        speak(a, Array(words[(target - 9)...(target + 2)]), segment: 1)
        XCTAssertEqual(a.position, target + 2)
    }

    func testBackwardJumpNeedsStrongEvidence() {
        let a = ScriptAligner(script: script)
        speak(a, Array(words.prefix(45)))
        // Speaker goes back to re-read a sentence from ~25 words earlier.
        speak(a, Array(words[18..<27]), segment: 1)
        XCTAssertEqual(a.position, 26)
    }

    func testPartialRevisionsDoNotJitterBackwards() {
        let a = ScriptAligner(script: script)
        let said = speak(a, Array(words.prefix(15)))
        // Recognizer revises the last word to something else, then back.
        var revised = said; revised[14] = "xyz"
        a.ingest(segment: 0, text: revised.joined(separator: " "))
        XCTAssertEqual(a.position, 14)
    }

    func testSegmentRotationKeepsContext() {
        let a = ScriptAligner(script: script)
        speak(a, Array(words.prefix(12)), segment: 0)
        speak(a, Array(words[12..<20]), segment: 1)
        XCTAssertEqual(a.position, 19)
    }

    func testManualResetDropsOldContext() {
        let a = ScriptAligner(script: script)
        let said = speak(a, Array(words.prefix(30)))
        a.reset(to: -1)
        speak(a, Array(words.prefix(3)), prefix: said)
        XCTAssertEqual(a.position, 2)
    }

    func testSimulatedEngineEndToEnd() {
        // Noisy simulated reading of the whole script should finish near the end.
        let a = ScriptAligner(script: script)
        var spoken: [String] = []
        var rng = SeededRNG(seed: 42)
        for w in words {
            let r = Double.random(in: 0..<1, using: &rng)
            if r < 0.05 { spoken.append("um") }
            if r > 0.95 { spoken.append(String(w.reversed())) } else { spoken.append(w) }
            a.ingest(segment: 0, text: spoken.joined(separator: " "))
        }
        XCTAssertGreaterThanOrEqual(a.position, words.count - 3)
    }

    func testAlignmentIsFastEnough() {
        // A ~10k word script. Local updates must stay far below the 300 ms budget (target < 2 ms).
        let big = Script(text: String(repeating: text + " ", count: 80))
        let a = ScriptAligner(script: big)
        let w = big.tokens.map(\.word)
        var said: [String] = []
        let start = Date()
        for x in w.prefix(500) { said.append(x); a.ingest(segment: 0, text: said.suffix(60).joined(separator: " ")) }
        let perUpdate = Date().timeIntervalSince(start) / 500 * 1000
        print("tokens=\(w.count) avg update=\(String(format: "%.3f", perUpdate)) ms")
        XCTAssertLessThan(perUpdate, 5)
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
