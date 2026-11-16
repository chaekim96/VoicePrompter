import AppKit
import Combine
import PrompterCore

enum TrackingState: Equatable {
    case stopped
    case starting
    case listening
    case error(String, URL?)

    var isActive: Bool { self == .starting || self == .listening }
}

struct LatencyStats: Equatable {
    var onsetToPartialMs: Double?     // speech onset -> recognizer partial (engine-measured)
    var pipelineMs: Double?           // recognizer callback -> highlight applied
    var recentOnsetMs: [Double] = []
    var decision = ""

    var medianOnsetMs: Double? {
        guard !recentOnsetMs.isEmpty else { return nil }
        return recentOnsetMs.sorted()[recentOnsetMs.count / 2]
    }
}

/// Owns the script, the tracking pipeline (engine -> aligner -> overlay) and the user settings.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings { didSet { if settings != oldValue { settings.save() } } }
    @Published private(set) var scriptText: String
    @Published private(set) var script: Script
    @Published private(set) var position: Int
    @Published private(set) var tracking: TrackingState = .stopped
    @Published private(set) var isLost = false
    @Published var clickThrough = false
    @Published var overlayVisible = true
    @Published private(set) var stats = LatencyStats()

    /// Called right after the position changes, in the same run-loop turn (keeps latency minimal).
    var onPositionChange: ((_ position: Int, _ animated: Bool) -> Void)?
    var onRecenterRequest: (() -> Void)?
    var onSnapRequest: (() -> Void)?

    func requestOverlayRecenter() { overlayVisible = true; onRecenterRequest?() }

    /// Puts the prompter under the camera (switching to Under camera placement if needed).
    func snapUnderCamera() {
        overlayVisible = true
        if settings.placement != .underCamera { settings.placement = .underCamera } else { onSnapRequest?() }
    }

    // MARK: - Progress

    /// Measured speaking pace (words per minute), nil until enough speech has been heard.
    @Published private(set) var wordsPerMinute: Double?
    private var pace = PaceEstimator()

    var progressFraction: Double {
        script.tokens.isEmpty ? 0 : Double(position + 1) / Double(script.tokens.count)
    }
    var wordsRemaining: Int { max(0, script.tokens.count - (position + 1)) }
    /// Estimated seconds of speaking left at the current pace.
    var secondsRemaining: TimeInterval? { pace.secondsRemaining(wordsLeft: wordsRemaining) }
    var timeLeftText: String? { secondsRemaining.map { "~" + PaceEstimator.format(seconds: $0) + " left" } }
    /// Zero-based paragraph of the current word (0 before the start).
    var currentParagraph: Int { script.paragraph(at: position) ?? 0 }
    /// How far through the current paragraph, 0...1.
    var paragraphFraction: Double {
        guard let p = script.paragraph(at: position) else { return 0 }
        let r = script.tokenRange(ofParagraph: p)
        return r.isEmpty ? 0 : Double(position + 1 - r.lowerBound) / Double(r.count)
    }

    let launch = LaunchOptions.current
    private let aligner: ScriptAligner
    private var engine: SpeechEngine?

    init() {
        var settings = AppSettings.load()
        if let id = LaunchOptions.current.engineID { settings.engineID = id }
        if let placement = LaunchOptions.current.placement { settings.placement = placement }
        self.settings = settings
        var text = ScriptStore.loadScript() ?? ScriptStore.sample
        var position = ScriptStore.position
        if let url = LaunchOptions.current.scriptFile, let t = AppModel.readScriptFile(url) { text = t; position = -1 }
        let script = Script(text: text)
        self.scriptText = text
        self.script = script
        self.position = min(position, script.tokens.count - 1)
        self.aligner = ScriptAligner(script: script)
        aligner.reset(to: self.position)
    }

    // MARK: - Script

    func setScript(_ text: String) {
        let wasTracking = tracking.isActive
        stopTracking()
        scriptText = text
        script = Script(text: text)
        ScriptStore.saveScript(text)
        aligner.load(script: script)
        pace.reset(); wordsPerMinute = nil
        setPosition(-1, animated: false)
        if wasTracking { startTracking() }
    }

    static func readScriptFile(_ url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown" ? ScriptImporter.plainText(fromMarkdown: raw) : raw
    }

    // MARK: - Position

    func setPosition(_ p: Int, animated: Bool = true) {
        let clamped = max(-1, min(p, script.tokens.count - 1))
        aligner.reset(to: clamped)
        pace.breakContinuity() // manual moves aren't speech
        applyPosition(clamped, animated: animated)
    }

    func resetToStart() { setPosition(-1) }

    private func applyPosition(_ p: Int, animated: Bool) {
        position = p
        ScriptStore.position = p
        onPositionChange?(p, animated)
    }

    // MARK: - Tracking

    func toggleTracking(source: String = "toggle") { tracking.isActive ? stopTracking(reason: source) : startTracking() }

    func startTracking() {
        guard !tracking.isActive else { return }
        guard !script.isEmpty else { tracking = .error("The script is empty. Paste or import one first.", nil); return }
        tracking = .starting
        let descriptor = EngineRegistry.descriptor(for: settings.engineID)
        let engine = descriptor.make(settings, launch)
        self.engine = engine
        engine.onUpdate = { [weak self] update in
            DispatchQueue.main.async { self?.handle(update) }
        }
        engine.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.engine === engine else { return }
                switch state {
                case .listening: self.tracking = .listening
                case .failed(let msg): self.stats.decision = "engine error: \(msg)"
                case .idle, .starting: break
                }
            }
        }
        let context = RecognitionContext(script: script, localeIdentifier: settings.localeIdentifier)
        Task { @MainActor in
            do {
                try await engine.prepare()
                guard self.engine === engine else { return }
                try engine.start(context: context)
            } catch {
                guard self.engine === engine else { return }
                engine.stop()
                self.engine = nil
                let e = error as? EngineError
                self.tracking = .error(e?.message ?? error.localizedDescription, e?.settingsURL)
            }
        }
    }

    func stopTracking(reason: String = "stop") {
        if engine != nil, launch.audioFile != nil { print("[model] tracking stopped: \(reason)") }
        let e = engine
        engine = nil
        e?.onUpdate = nil
        e?.stop()
        if case .error = tracking { } else { tracking = .stopped }
        isLost = false
    }

    func dismissError() { if case .error = tracking { tracking = .stopped } }

    private func handle(_ update: RecognitionUpdate) {
        guard engine != nil else { return }
        let moved = aligner.ingest(segment: update.segment, text: update.text)
        if let p = moved {
            pace.record(position: p, at: ProcessInfo.processInfo.systemUptime)
            wordsPerMinute = pace.wordsPerMinute
            applyPosition(p, animated: true)
        }
        isLost = aligner.isLost

        var s = stats
        if moved != nil {
            s.pipelineMs = Double(DispatchTime.now().uptimeNanoseconds - update.producedAt) / 1e6
        }
        if let onset = update.onsetLatencyMs {
            s.onsetToPartialMs = onset
            s.recentOnsetMs = Array((s.recentOnsetMs + [onset]).suffix(25))
        }
        s.decision = aligner.lastDecision?.description ?? ""
        stats = s
        if launch.audioFile != nil {
            let pipeline = s.pipelineMs.map { String(format: "%.2f", $0) } ?? "-"
            let onset = update.onsetLatencyMs.map { String(format: "%.0f", $0) } ?? "-"
            print("[track] pos=\(position)/\(script.tokens.count) onset->partial=\(onset)ms pipeline=\(pipeline)ms \(s.decision) text=\"\(update.text.suffix(40))\"")
        }
    }
}
