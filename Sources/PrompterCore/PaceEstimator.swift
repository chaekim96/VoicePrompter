import Foundation

/// Measures the reader's speaking pace from how fast the position advances, so the UI can show
/// an honest "time left". Timestamps are injected, so it is deterministic and unit-testable.
///
/// Only intervals between two consecutive position updates count. An interval is ignored when it is
/// a pause (longer than `pauseGap`), a backward move, or a jump (more than `maxStep` words at once),
/// so pauses, re-reads and manual repositioning don't distort the pace.
public struct PaceEstimator: Sendable {
    public var windowSeconds: TimeInterval = 25
    public var pauseGap: TimeInterval = 3
    public var maxStep = 25
    public var minActiveSeconds: TimeInterval = 3
    public var minWords = 5

    private struct Interval { let end: TimeInterval; let dt: TimeInterval; let words: Int }
    private var intervals: [Interval] = []
    private var last: (position: Int, time: TimeInterval)?

    /// Latest estimate. Kept (not cleared) while paused so "time left" stays visible.
    public private(set) var wordsPerMinute: Double?

    public init() {}

    /// Records a new reading position at `time` (seconds, any monotonic clock).
    public mutating func record(position: Int, at time: TimeInterval) {
        defer { last = (position, time) }
        guard let prev = last, time > prev.time else { return }
        let dt = time - prev.time, words = position - prev.position
        if dt <= pauseGap, words > 0, words <= maxStep {
            intervals.append(Interval(end: time, dt: dt, words: words))
        }
        intervals.removeAll { $0.end < time - windowSeconds }
        let active = intervals.reduce(0) { $0 + $1.dt }
        let total = intervals.reduce(0) { $0 + $1.words }
        if active >= minActiveSeconds, total >= minWords { wordsPerMinute = Double(total) / active * 60 }
    }

    /// Call after a manual move (reset, nudge, double-click) so it doesn't count as speech.
    public mutating func breakContinuity() { last = nil }

    /// Forgets everything, e.g. when the script changes.
    public mutating func reset() { intervals = []; last = nil; wordsPerMinute = nil }

    public func secondsRemaining(wordsLeft: Int) -> TimeInterval? {
        guard let wpm = wordsPerMinute, wpm > 0 else { return nil }
        return Double(max(0, wordsLeft)) / wpm * 60
    }

    /// "1:20" style (m:ss), or "0:05".
    public static func format(seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
