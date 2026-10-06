import AppKit
import AVFoundation
import PrompterCore
import Speech

/// Every speech engine the app can use. To add one (whisper.cpp, Vosk, a cloud API...), implement
/// `SpeechEngine` from PrompterCore and add a descriptor here. It then shows up in Settings.
struct EngineDescriptor: Identifiable {
    let id: String
    let name: String
    let detail: String
    let make: (AppSettings, LaunchOptions) -> SpeechEngine
}

enum EngineRegistry {
    static let defaultID = "apple-speech"

    static let all: [EngineDescriptor] = [
        EngineDescriptor(id: "apple-speech", name: "Apple Speech",
                         detail: "On-device SFSpeechRecognizer. Streaming, low latency.") { settings, launch in
            AppleSpeechEngine(onDeviceOnly: settings.onDeviceOnly, audioFileURL: launch.audioFile)
        },
        EngineDescriptor(id: "simulated", name: "Simulated reader",
                         detail: "Reads the script aloud at a set pace with mistakes. No microphone.") { settings, _ in
            SimulatedEngine(wordsPerMinute: settings.simulatedWordsPerMinute)
        },
    ]

    static func descriptor(for id: String) -> EngineDescriptor { all.first { $0.id == id } ?? all[0] }

    static var supportedLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted {
            ($0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                < ($1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
        }
    }
}

/// Command-line switches for testing: `--audio-file <path>`, `--engine <id>`, `--script <path>`,
/// `--autostart`, `--no-protect`, `--snapshot <png>`, `--quit-after <seconds>`.
struct LaunchOptions {
    var audioFile: URL?
    var engineID: String?
    var autostart = false
    var disableProtection = false
    var scriptFile: URL?
    var snapshot: URL?          // --snapshot <png>: render the overlay to a file every second (for headless checks)
    var quitAfter: Double?      // --quit-after <seconds>

    static let current: LaunchOptions = {
        var o = LaunchOptions()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--audio-file": o.audioFile = args.next().map { URL(fileURLWithPath: $0) }
            case "--engine": o.engineID = args.next()
            case "--script": o.scriptFile = args.next().map { URL(fileURLWithPath: $0) }
            case "--snapshot": o.snapshot = args.next().map { URL(fileURLWithPath: $0) }
            case "--quit-after": o.quitAfter = args.next().flatMap(Double.init)
            case "--autostart": o.autostart = true
            case "--no-protect": o.disableProtection = true
            default: break
            }
        }
        return o
    }()
}

enum Permissions {
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    static let speechSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var speechStatus: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }
}
