import Foundation

/// Reads the script back at a set pace with injected recognition errors, ad-libs and skips.
/// Use it to try the overlay without a microphone, or to demo the tracking.
public final class SimulatedEngine: SpeechEngine {
    public var onUpdate: ((RecognitionUpdate) -> Void)?
    public var onStateChange: ((EngineState) -> Void)?

    public var wordsPerMinute: Double
    public var errorRate: Double
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "SimulatedEngine")

    public init(wordsPerMinute: Double = 150, errorRate: Double = 0.08) {
        self.wordsPerMinute = wordsPerMinute
        self.errorRate = errorRate
    }

    public func prepare() async throws {}

    public func start(context: RecognitionContext) throws {
        stop()
        let words = context.script.tokens.map(\.word)
        var rng = SystemRandomNumberGenerator()
        var i = 0, segment = 0, spoken: [String] = []
        let fillers = ["um", "so", "you know", "basically", "uh"]
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 60 / wordsPerMinute)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard i < words.count else { self.onStateChange?(.idle); self.timer?.cancel(); return }
            let r = Double.random(in: 0..<1, using: &rng)
            if r < self.errorRate * 0.4 {
                spoken.append(fillers.randomElement(using: &rng)!)              // ad-lib
            } else if r < self.errorRate * 0.6 {
                i += 1                                                          // skipped word
            } else if r < self.errorRate {
                spoken.append(String(words[i].reversed())); i += 1              // misrecognition
            } else {
                spoken.append(words[i]); i += 1
            }
            if spoken.count > 40 { segment += 1; spoken = Array(spoken.suffix(1)) } // mimic session rotation
            self.onUpdate?(RecognitionUpdate(segment: segment, text: spoken.joined(separator: " "), isFinal: false))
        }
        timer = t
        onStateChange?(.listening)
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        onStateChange?(.idle)
    }
}
