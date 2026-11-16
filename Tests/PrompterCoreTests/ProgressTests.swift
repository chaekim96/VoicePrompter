import XCTest
@testable import PrompterCore

final class ProgressTests: XCTestCase {
    func testParagraphsSplitOnBlankLines() {
        let s = Script(text: "One two three.\n\nFour five.\n   \n\nSix seven eight nine.\nStill six.")
        XCTAssertEqual(s.paragraphCount, 3)
        XCTAssertEqual(s.paragraphOfToken, [0, 0, 0, 1, 1, 2, 2, 2, 2, 2, 2])
        XCTAssertEqual(s.paragraphStarts, [0, 3, 5])
        XCTAssertEqual(s.tokenRange(ofParagraph: 1), 3..<5)
        XCTAssertEqual(s.tokenRange(ofParagraph: 2), 5..<11)
        XCTAssertNil(s.paragraph(at: -1))
        XCTAssertEqual(s.paragraph(at: 4), 1)
    }

    func testSingleNewlineIsNotAParagraphBreak() {
        let s = Script(text: "Line one\nline two\n\nNext")
        XCTAssertEqual(s.paragraphCount, 2)
        XCTAssertEqual(s.paragraphOfToken, [0, 0, 0, 0, 1])
    }

    func testLeadingBlankLinesAndEmptyScript() {
        XCTAssertEqual(Script(text: "\n\nHello there").paragraphCount, 1)
        XCTAssertEqual(Script(text: "\n\nHello there").paragraphOfToken, [0, 0])
        XCTAssertEqual(Script(text: "").paragraphCount, 0)
        XCTAssertEqual(Script(text: "A\r\n\r\nB").paragraphOfToken, [0, 1])
    }

    /// Reads 5 words every 2 s = 150 wpm.
    func testSteadyPace() {
        var p = PaceEstimator()
        var pos = 0, t = 0.0
        p.record(position: pos, at: t)
        for _ in 0..<8 { pos += 5; t += 2; p.record(position: pos, at: t) }
        XCTAssertEqual(p.wordsPerMinute ?? 0, 150, accuracy: 0.5)
        XCTAssertEqual(p.secondsRemaining(wordsLeft: 75) ?? 0, 30, accuracy: 0.5)
        XCTAssertEqual(PaceEstimator.format(seconds: 80), "1:20")
    }

    func testNoEstimateUntilEnoughData() {
        var p = PaceEstimator()
        p.record(position: 0, at: 0)
        p.record(position: 2, at: 1)
        XCTAssertNil(p.wordsPerMinute)
        XCTAssertNil(p.secondsRemaining(wordsLeft: 100))
    }

    func testPausesAreIgnored() {
        var p = PaceEstimator()
        var pos = 0, t = 0.0
        p.record(position: pos, at: t)
        for _ in 0..<5 { pos += 5; t += 2; p.record(position: pos, at: t) }
        let before = p.wordsPerMinute
        t += 12 // long pause, then resume
        pos += 5; p.record(position: pos, at: t)
        XCTAssertEqual(p.wordsPerMinute ?? 0, before ?? -1, accuracy: 0.5, "a pause must not drag the pace down")
        for _ in 0..<3 { pos += 5; t += 2; p.record(position: pos, at: t) }
        XCTAssertEqual(p.wordsPerMinute ?? 0, 150, accuracy: 0.5)
    }

    func testJumpsAndBackwardMovesAreIgnored() {
        var p = PaceEstimator()
        var pos = 0, t = 0.0
        p.record(position: pos, at: t)
        for _ in 0..<5 { pos += 5; t += 2; p.record(position: pos, at: t) }
        t += 1; pos += 200; p.record(position: pos, at: t)  // jump
        t += 1; pos -= 10; p.record(position: pos, at: t)   // back
        XCTAssertEqual(p.wordsPerMinute ?? 0, 150, accuracy: 0.5)
    }

    func testRollingWindowForgetsOldPace() {
        var p = PaceEstimator()
        var pos = 0, t = 0.0
        p.record(position: pos, at: t)
        for _ in 0..<10 { pos += 4; t += 2; p.record(position: pos, at: t) }   // 120 wpm
        XCTAssertEqual(p.wordsPerMinute ?? 0, 120, accuracy: 0.5)
        for _ in 0..<20 { pos += 6; t += 2; p.record(position: pos, at: t) }   // 180 wpm for 40 s
        XCTAssertEqual(p.wordsPerMinute ?? 0, 180, accuracy: 0.5)
    }

    func testBreakContinuityDropsManualMove() {
        var p = PaceEstimator()
        var pos = 0, t = 0.0
        p.record(position: pos, at: t)
        for _ in 0..<5 { pos += 5; t += 2; p.record(position: pos, at: t) }
        p.breakContinuity()
        pos += 15; t += 1; p.record(position: pos, at: t) // would be 15 words/s, but it's a baseline
        XCTAssertEqual(p.wordsPerMinute ?? 0, 150, accuracy: 0.5)
    }
}
