import AppKit
import SwiftUI

struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double = 1

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
    var color: Color { Color(nsColor: nsColor) }
}

struct AppSettings: Codable, Equatable {
    // Appearance
    var fontSize: Double = 34
    var textColor = RGBA(r: 1, g: 1, b: 1)
    var highlightColor = RGBA(r: 1, g: 0.8, b: 0.25)
    var backgroundColor = RGBA(r: 0.05, g: 0.05, b: 0.07)
    var backgroundOpacity: Double = 0.6
    var windowOpacity: Double = 1.0
    var readTextOpacity: Double = 0.35
    var lineHeight: Double = 1.2

    // Tracking
    var engineID = EngineRegistry.defaultID
    var localeIdentifier = "en-US"
    var onDeviceOnly = true
    var simulatedWordsPerMinute: Double = 150

    // Privacy & debugging
    var protectFromCapture = true
    var showLatencyStats = false

    // Access
    var showInDock = true
    var showWindowOnLaunch = true

    private static let key = "settings.v1"

    /// Loads saved settings and falls back to defaults for any missing field, so adding
    /// new settings never resets the user's existing ones.
    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let baseData = try? JSONEncoder().encode(AppSettings()),
              let base = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(stored) { $1 }),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: merged)
        else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Script text and reading position, stored in ~/Library/Application Support/VoicePrompter.
enum ScriptStore {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoicePrompter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var scriptURL: URL { directory.appendingPathComponent("script.txt") }

    static func loadScript() -> String? { try? String(contentsOf: scriptURL, encoding: .utf8) }
    static func saveScript(_ text: String) { try? text.write(to: scriptURL, atomically: true, encoding: .utf8) }

    static var position: Int {
        get { UserDefaults.standard.object(forKey: "position") as? Int ?? -1 }
        set { UserDefaults.standard.set(newValue, forKey: "position") }
    }

    static let sample = """
    Welcome to VoicePrompter. Press Control Option Space, or the play button that appears when you hover \
    over this window, and start reading this text out loud.

    As you speak, the current word lights up, the text you have already read fades out, and the script \
    scrolls so the line you are on stays in the upper third of the window.

    Feel free to ad-lib. Say something that isn't in the script, skip a sentence, or repeat a phrase. \
    The tracker waits for strong evidence before it jumps anywhere far away.

    Drag the window to move it and drag its edges to resize it. Control Option C makes it click-through, \
    so you can use the apps underneath. Control Option H hides it instantly. Control Option R jumps back \
    to the start, and Control Option Up and Down nudge the position one line at a time.

    Open Edit Script from the menu bar icon to paste your own text or import a .txt or .md file.
    """
}
