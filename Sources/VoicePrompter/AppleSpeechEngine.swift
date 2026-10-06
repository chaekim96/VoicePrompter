import Accelerate
import AVFoundation
import PrompterCore
import Speech

/// Apple's Speech framework (`SFSpeechRecognizer`), streaming microphone audio on-device.
///
/// * The recognition session is restarted ("rotated") about every 50 s, preferably during a pause.
///   This keeps each hypothesis short, which keeps partial results fast, and avoids session time limits.
/// * A small energy-based voice detector timestamps speech onsets, so the first partial result after
///   an onset gives a real speech-to-text latency measurement.
/// * `audioFileURL` feeds a file in real time instead of the mic (for testing and latency measurement).
final class AppleSpeechEngine: SpeechEngine {
    var onUpdate: ((RecognitionUpdate) -> Void)?
    var onStateChange: ((EngineState) -> Void)?

    private let verbose = ProcessInfo.processInfo.environment["VP_VERBOSE"] != nil || CommandLine.arguments.contains("--verbose")
    private let onDeviceOnly: Bool
    private let audioFileURL: URL?

    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var segment = 0
    private var segmentStarted = Date()
    private var lastResultAt = Date()
    private var lastText = ""
    private var contextualStrings: [String] = []
    private var running = false

    private let audioEngine = AVAudioEngine()
    private var fileTimer: DispatchSourceTimer?
    private var rotationTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "AppleSpeechEngine")
    private var configObserver: NSObjectProtocol?

    // Voice activity: onset timestamps (host ns) for latency measurement.
    private var noiseFloor: Float = 0.003
    private var speaking = false
    private var silentFor: Double = 1
    private var pendingOnset: UInt64?

    init(onDeviceOnly: Bool, audioFileURL: URL? = nil) {
        self.onDeviceOnly = onDeviceOnly
        self.audioFileURL = audioFileURL
    }

    // MARK: - Permissions

    func prepare() async throws {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            throw EngineError("Speech Recognition access is turned off for VoicePrompter.",
                              settingsURL: Permissions.speechSettingsURL)
        }
        if audioFileURL == nil {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw EngineError("Microphone access is turned off for VoicePrompter.",
                                  settingsURL: Permissions.microphoneSettingsURL)
            }
        }
    }

    // MARK: - Lifecycle

    func start(context: RecognitionContext) throws {
        stop()
        onStateChange?(.starting)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: context.localeIdentifier)) else {
            throw EngineError("Speech recognition doesn't support \(context.localeIdentifier).")
        }
        guard recognizer.isAvailable else { throw EngineError("Speech recognition is unavailable right now.") }
        if onDeviceOnly && !recognizer.supportsOnDeviceRecognition {
            throw EngineError("On-device recognition isn't installed for \(context.localeIdentifier). Turn on Dictation in "
                              + "System Settings → Keyboard to download it, or allow server recognition in VoicePrompter Settings.",
                              settingsURL: Permissions.keyboardSettingsURL)
        }
        recognizer.defaultTaskHint = .dictation
        let callbackQueue = OperationQueue()
        callbackQueue.maxConcurrentOperationCount = 1
        recognizer.queue = callbackQueue
        self.recognizer = recognizer
        contextualStrings = context.script.contextualWords()
        running = true
        beginSegment()

        if let url = audioFileURL {
            try startFileFeed(url)
        } else {
            try startMicrophone()
        }
        startRotationTimer()
        onStateChange?(.listening)
    }

    func stop() {
        lock.lock()
        running = false
        let oldRequest = request, oldTask = task
        request = nil; task = nil
        lock.unlock()
        oldRequest?.endAudio()
        oldTask?.cancel()
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        fileTimer?.cancel(); fileTimer = nil
        rotationTimer?.cancel(); rotationTimer = nil
        onStateChange?(.idle)
    }

    // MARK: - Recognition segments

    /// Starts a new recognition session and retires the old one. Never call into Speech while holding
    /// `lock`: Speech delivers callbacks that take `lock`, so holding it across those calls deadlocks.
    private func beginSegment() {
        lock.lock()
        guard running, let recognizer else { lock.unlock(); return }
        let oldRequest = request, oldTask = task
        segment += 1
        let seg = segment
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = onDeviceOnly
        req.taskHint = .dictation
        req.contextualStrings = contextualStrings
        req.addsPunctuation = false
        request = req
        task = nil
        segmentStarted = Date()
        lastText = ""
        lock.unlock()

        oldRequest?.endAudio()
        oldTask?.finish()
        log("segment \(seg) started")
        let newTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.handle(result: result, error: error, segment: seg)
        }
        lock.lock()
        if seg == segment { task = newTask } else { newTask.cancel() }
        lock.unlock()
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, segment seg: Int) {
        lock.lock()
        let isCurrent = seg == segment && running
        var latency: Double?
        var text: String?
        if isCurrent, let result {
            let t = result.bestTranscription.formattedString
            if t != lastText {
                lastText = t
                text = t
                lastResultAt = Date()
                if let onset = pendingOnset {
                    latency = Double(DispatchTime.now().uptimeNanoseconds - onset) / 1e6
                    pendingOnset = nil
                }
            }
        }
        lock.unlock()
        if verbose {
            log("cb seg=\(seg) current=\(isCurrent) final=\(result?.isFinal ?? false) err=\((error as NSError?)?.code ?? 0) "
                + "text=\"\(result?.bestTranscription.formattedString.suffix(30) ?? "")\"")
        }
        guard isCurrent else { return }

        if let text, let result {
            onUpdate?(RecognitionUpdate(segment: seg, text: text, isFinal: result.isFinal, onsetLatencyMs: latency))
        }
        if result?.isFinal == true {
            log("segment \(seg) final")
            queue.async { self.beginSegment() }
        } else if let error {
            let ns = error as NSError
            log("segment \(seg) error \(ns.domain) \(ns.code): \(ns.localizedDescription)")
            // 1110 = no speech detected, 216/301 = canceled, 1101/1107 = transient local errors. All recoverable.
            if [1110, 216, 301, 1101, 1107].contains(ns.code) {
                queue.asyncAfter(deadline: .now() + 0.1) { self.beginSegment() }
            } else {
                onStateChange?(.failed(ns.localizedDescription))
                queue.asyncAfter(deadline: .now() + 1) { self.beginSegment() }
            }
        }
    }

    /// Rotates the session after ~50 s, at the next pause (or at 58 s regardless).
    private func startRotationTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let age = Date().timeIntervalSince(self.segmentStarted)
            let idle = Date().timeIntervalSince(self.lastResultAt)
            self.lock.unlock()
            if age > 58 || (age > 50 && idle > 0.6) { self.beginSegment() }
        }
        rotationTimer = t
        t.resume()
    }

    // MARK: - Audio input

    private func append(_ buffer: AVAudioPCMBuffer) {
        detectOnset(buffer)
        lock.lock()
        let req = request
        lock.unlock()
        req?.append(buffer)
    }

    /// Diagnostics go to stdout. They're only visible when launched with `open --stdout` (see scripts/latency-test.sh).
    private let t0 = Date()
    private func log(_ message: String) { print(String(format: "[engine] %6.2fs ", Date().timeIntervalSince(t0)) + message) }

    private func startMicrophone() throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw EngineError("No microphone found.")
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch { throw EngineError("Couldn't start the microphone: \(error.localizedDescription)") }

        // Headphones plugged in, input device switched, etc.: rebuild the tap with the new format.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil) { [weak self] _ in
            guard let self, self.running else { return }
            self.queue.async {
                self.audioEngine.stop()
                try? self.startMicrophone()
            }
        }
    }

    private func startFileFeed(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 1024
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: Double(chunk) / format.sampleRate, leeway: .milliseconds(1))
        var trailingSilence = Int(format.sampleRate * 2) / Int(chunk)
        var fed = 0.0
        t.setEventHandler { [weak self] in
            guard let self, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
            fed += Double(chunk) / format.sampleRate
            if self.verbose, Int(fed * 10) % 50 == 0 { self.log(String(format: "fed %.1fs of audio", fed)) }
            if (try? file.read(into: buf, frameCount: chunk)) == nil || buf.frameLength == 0 {
                buf.frameLength = chunk // silence after the file ends, so the recognizer flushes
                trailingSilence -= 1
                if trailingSilence <= 0 { self.fileTimer?.cancel() }
            }
            self.append(buf)
        }
        fileTimer = t
        t.resume()
    }

    private func detectOnset(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buffer.frameLength))
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let threshold = max(0.01, noiseFloor * 4)
        if rms > threshold {
            if !speaking && silentFor >= 0.2 {
                // Onset = start of this buffer.
                let now = DispatchTime.now().uptimeNanoseconds
                lock.lock(); pendingOnset = now - UInt64(duration * 1e9); lock.unlock()
            }
            speaking = true
            silentFor = 0
        } else {
            silentFor += duration
            if silentFor >= 0.2 { speaking = false }
            noiseFloor = noiseFloor * 0.995 + rms * 0.005
        }
    }
}
