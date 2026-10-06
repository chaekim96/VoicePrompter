import Foundation

/// One hypothesis from a recognizer.
public struct RecognitionUpdate: Sendable {
    /// Recognizers restart their session every so often, and the text resets when they do.
    /// `segment` increases on every restart. `text` is everything recognized so far in that segment.
    public let segment: Int
    public let text: String
    public let isFinal: Bool
    /// Host time when the engine produced this update (`DispatchTime.now().uptimeNanoseconds`).
    public let producedAt: UInt64
    /// Estimated delay from speech onset to this update, when the engine can measure it.
    public let onsetLatencyMs: Double?

    public init(segment: Int, text: String, isFinal: Bool, producedAt: UInt64 = DispatchTime.now().uptimeNanoseconds,
                onsetLatencyMs: Double? = nil) {
        self.segment = segment; self.text = text; self.isFinal = isFinal
        self.producedAt = producedAt; self.onsetLatencyMs = onsetLatencyMs
    }
}

public enum EngineState: Equatable, Sendable {
    case idle
    case starting
    case listening
    case failed(String)
}

public struct RecognitionContext: Sendable {
    public let script: Script
    public let localeIdentifier: String
    public init(script: Script, localeIdentifier: String) {
        self.script = script; self.localeIdentifier = localeIdentifier
    }
}

/// The interface every speech engine implements. Swap engines (Apple Speech, whisper.cpp, Vosk, a cloud API...)
/// by conforming to this and registering it in `EngineRegistry` in the app target.
///
/// Callbacks may arrive on any thread. The app hops to the main thread itself.
public protocol SpeechEngine: AnyObject {
    var onUpdate: ((RecognitionUpdate) -> Void)? { get set }
    var onStateChange: ((EngineState) -> Void)? { get set }
    /// Asks for whatever permissions the engine needs. Throws a user-presentable error if they're denied.
    func prepare() async throws
    func start(context: RecognitionContext) throws
    func stop()
}

public struct EngineError: LocalizedError, Sendable {
    public let message: String
    public let settingsURL: URL?
    public init(_ message: String, settingsURL: URL? = nil) { self.message = message; self.settingsURL = settingsURL }
    public var errorDescription: String? { message }
}
