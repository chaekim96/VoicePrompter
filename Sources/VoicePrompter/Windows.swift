import AppKit
import PrompterCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The app's main window: one place for controls, the script and every setting.
/// Opens from the Dock icon, the menu bar icon, the overlay's ⋯ button, or ⌃⌥O.
@MainActor
final class WindowManager {
    private let model: AppModel
    private let nav = NavigationState()
    private var window: NSWindow?

    init(model: AppModel) { self.model = model }

    func show(_ section: Pane? = nil) {
        if let section { nav.section = section }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "VoicePrompter"
            w.contentViewController = NSHostingController(rootView: MainView(model: model, nav: nav))
            w.setContentSize(NSSize(width: 820, height: 580))
            w.minSize = NSSize(width: 680, height: 460)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MainWindow")
            if !w.setFrameUsingName("MainWindow") { w.center() }
            window = w
        }
        let protect = model.settings.protectFromCapture && !model.launch.disableProtection
        window?.sharingType = protect ? .none : .readOnly
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func importScript() {
        guard let url = Self.chooseScriptFile(), let text = AppModel.readScriptFile(url) else { return }
        model.setScript(text)
    }

    static func chooseScriptFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText,
                                     UTType(filenameExtension: "markdown") ?? .plainText]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case home, script, appearance, voice, privacy, shortcuts, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Prompter"
        case .script: return "Script"
        case .appearance: return "Appearance"
        case .voice: return "Voice Tracking"
        case .privacy: return "Privacy"
        case .shortcuts: return "Shortcuts"
        case .general: return "General"
        }
    }
    var icon: String {
        switch self {
        case .home: return "play.rectangle"
        case .script: return "doc.text"
        case .appearance: return "textformat.size"
        case .voice: return "waveform"
        case .privacy: return "eye.slash"
        case .shortcuts: return "command"
        case .general: return "gearshape"
        }
    }
}

final class NavigationState: ObservableObject {
    @Published var section: Pane = .home
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: NavigationState

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { nav.section }, set: { if let s = $0 { nav.section = s } })) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                switch nav.section {
                case .home: HomePane(model: model, nav: nav)
                case .script: ScriptPane(model: model)
                case .appearance: AppearancePane(model: model)
                case .voice: VoicePane(model: model)
                case .privacy: PrivacyPane(model: model)
                case .shortcuts: ShortcutsPane()
                case .general: GeneralPane(model: model)
                }
            }
            .navigationTitle(nav.section.title)
        }
    }
}

// MARK: - Shared helpers

extension AppModel {
    func binding<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: kp] }, set: { self.settings[keyPath: kp] = $0 })
    }
    func colorBinding(_ kp: WritableKeyPath<AppSettings, RGBA>) -> Binding<Color> {
        Binding(get: { self.settings[keyPath: kp].color }, set: { self.settings[keyPath: kp] = RGBA($0) })
    }
}

struct PermissionRow: View {
    let name: String
    let granted: Bool
    let url: URL?
    var body: some View {
        LabeledContent(name) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Open Privacy Settings") { if let url { NSWorkspace.shared.open(url) } }
            }
        }
    }
}

// MARK: - Panes

struct HomePane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: NavigationState

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Circle().fill(statusColor).frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).font(.title3.weight(.semibold))
                        Text(statusDetail).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.toggleTracking() } label: {
                        Label(model.tracking.isActive ? "Pause" : "Start Tracking",
                              systemImage: model.tracking.isActive ? "pause.fill" : "play.fill")
                            .frame(minWidth: 130)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])
                }
                .padding(.vertical, 6)
                if case .error(let message, let url) = model.tracking {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text(message).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let url { Button("Open Settings") { NSWorkspace.shared.open(url) } }
                    }
                }
            }
            Section("Position") {
                ProgressView(value: progress)
                Text(currentLine.isEmpty ? "Not started" : "“\(currentLine)”")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Button("Back to Start", systemImage: "backward.end.fill") { model.resetToStart() }
                    Spacer()
                    Text("Word \(max(0, model.position + 1)) of \(model.script.tokens.count)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Section("Prompter window") {
                Toggle("Show prompter", isOn: $model.overlayVisible)
                Toggle("Click-through (clicks go to the apps underneath)", isOn: $model.clickThrough)
                Button("Move prompter to the top of this screen") { model.requestOverlayRecenter() }
            }
            Section("Script") {
                LabeledContent("Current script", value: "\(model.script.tokens.count) words")
                HStack {
                    Button("Edit Script…") { nav.section = .script }
                    Button("Import .txt / .md…") {
                        if let url = WindowManager.chooseScriptFile(), let t = AppModel.readScriptFile(url) { model.setScript(t) }
                    }
                }
            }
            Section("Permissions") {
                PermissionRow(name: "Microphone", granted: Permissions.microphoneStatus == .authorized, url: Permissions.microphoneSettingsURL)
                PermissionRow(name: "Speech Recognition", granted: Permissions.speechStatus == .authorized, url: Permissions.speechSettingsURL)
            }
        }
        .formStyle(.grouped)
    }

    private var progress: Double {
        model.script.tokens.isEmpty ? 0 : Double(model.position + 1) / Double(model.script.tokens.count)
    }

    /// The script text around the current word, for a quick glance.
    private var currentLine: String {
        guard model.position >= 0, model.position < model.script.tokens.count else { return "" }
        let ns = model.script.text as NSString
        let r = model.script.tokens[model.position].range
        let lo = max(0, r.location - 40), hi = min(ns.length, NSMaxRange(r) + 40)
        return ns.substring(with: NSRange(location: lo, length: hi - lo))
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    private var statusColor: Color {
        switch model.tracking {
        case .listening: return model.isLost ? .orange : .green
        case .starting: return .yellow
        case .stopped: return .gray
        case .error: return .red
        }
    }
    private var statusTitle: String {
        switch model.tracking {
        case .listening: return model.isLost ? "Listening (lost your place)" : "Listening"
        case .starting: return "Starting…"
        case .stopped: return "Paused"
        case .error: return "Needs attention"
        }
    }
    private var statusDetail: String {
        switch model.tracking {
        case .listening: return "Read aloud. The prompter follows your voice."
        case .starting: return "Getting the microphone and recognizer ready."
        case .stopped: return "Press Start or ⌃⌥Space from any app."
        case .error: return "See the message below."
        }
    }
}

struct ScriptPane: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $draft)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            HStack {
                Button("Import .txt / .md…") {
                    if let url = WindowManager.chooseScriptFile(), let text = AppModel.readScriptFile(url) { draft = text }
                }
                Text("\(Normalizer.tokens(forText: draft).count) words").foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button("Revert") { draft = model.scriptText }.disabled(draft == model.scriptText)
                Button("Use This Script") { model.setScript(draft) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == model.scriptText || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Using a new script moves the prompter back to the start. Markdown formatting is stripped on import.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear { if !loaded { draft = model.scriptText; loaded = true } }
    }
}

struct AppearancePane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Text") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: model.binding(\.fontSize), in: 16...96, step: 1)
                        Text("\(Int(model.settings.fontSize)) pt").monospacedDigit().frame(width: 48)
                    }
                }
                LabeledContent("Line height") { Slider(value: model.binding(\.lineHeight), in: 1...2) }
                ColorPicker("Text color", selection: model.colorBinding(\.textColor), supportsOpacity: false)
                ColorPicker("Current word", selection: model.colorBinding(\.highlightColor), supportsOpacity: false)
                LabeledContent("Already-read text") { Slider(value: model.binding(\.readTextOpacity), in: 0.05...1) }
            }
            Section("Window") {
                ColorPicker("Background", selection: model.colorBinding(\.backgroundColor), supportsOpacity: false)
                LabeledContent("Background opacity") { Slider(value: model.binding(\.backgroundOpacity), in: 0...1) }
                LabeledContent("Overall opacity") { Slider(value: model.binding(\.windowOpacity), in: 0.2...1) }
                Text("Move the prompter by dragging its text. Resize it by dragging its edges.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Default Appearance") {
                    let d = AppSettings()
                    var s = model.settings
                    s.fontSize = d.fontSize; s.lineHeight = d.lineHeight; s.textColor = d.textColor
                    s.highlightColor = d.highlightColor; s.readTextOpacity = d.readTextOpacity
                    s.backgroundColor = d.backgroundColor; s.backgroundOpacity = d.backgroundOpacity; s.windowOpacity = d.windowOpacity
                    model.settings = s
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct VoicePane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Recognizer") {
                Picker("Engine", selection: model.binding(\.engineID)) {
                    ForEach(EngineRegistry.all) { Text($0.name).tag($0.id) }
                }
                Text(EngineRegistry.descriptor(for: model.settings.engineID).detail).font(.caption).foregroundStyle(.secondary)
                if model.settings.engineID == "apple-speech" {
                    Picker("Language", selection: model.binding(\.localeIdentifier)) {
                        ForEach(EngineRegistry.supportedLocales, id: \.identifier) { l in
                            Text(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier)
                        }
                    }
                    Toggle("On-device only (audio never leaves your Mac)", isOn: model.binding(\.onDeviceOnly))
                } else {
                    LabeledContent("Reading pace") {
                        HStack {
                            Slider(value: model.binding(\.simulatedWordsPerMinute), in: 80...220, step: 10)
                            Text("\(Int(model.settings.simulatedWordsPerMinute)) wpm").monospacedDigit().frame(width: 64)
                        }
                    }
                }
                Text("Changes apply the next time tracking starts.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                PermissionRow(name: "Microphone", granted: Permissions.microphoneStatus == .authorized, url: Permissions.microphoneSettingsURL)
                PermissionRow(name: "Speech Recognition", granted: Permissions.speechStatus == .authorized, url: Permissions.speechSettingsURL)
            }
            Section("Diagnostics") {
                Toggle("Show latency stats on the prompter", isOn: model.binding(\.showLatencyStats))
                if let onset = model.stats.medianOnsetMs {
                    LabeledContent("Speech → recognized (median)", value: "\(Int(onset)) ms")
                }
                if let p = model.stats.pipelineMs {
                    LabeledContent("Recognized → highlighted", value: String(format: "%.1f ms", p))
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PrivacyPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Hide VoicePrompter from screen sharing and recordings", isOn: model.binding(\.protectFromCapture))
            }
            Section("Tested on macOS 15.7") {
                LabeledContent("Zoom, Google Meet, OBS (macOS Screen Capture)") { Label("Hidden", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                LabeledContent("QuickTime / ⌘⇧5 recording, screenshots") { Label("Hidden", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                LabeledContent("Legacy recorders, OBS “Display Capture (deprecated)”") { Label("Visible", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                Text("If you're not sure how an app captures the screen, press ⌃⌥H to hide the prompter instantly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutsPane: View {
    var body: some View {
        Form {
            Section("Work from any app, including full-screen ones") {
                row("Start / pause tracking", "⌃⌥Space")
                row("Open this window", "⌃⌥O")
                row("Show / hide the prompter", "⌃⌥H")
                row("Click-through on / off", "⌃⌥C")
                row("Back to start", "⌃⌥R")
                row("Previous / next line", "⌃⌥↑   ⌃⌥↓")
            }
            Section("On the prompter") {
                row("Move", "Drag the text")
                row("Resize", "Drag an edge")
                row("Jump to a word", "Double-click it")
            }
            if !HotkeyManager.shared.failed.isEmpty {
                Text("Already in use by another app: \(HotkeyManager.shared.failed.joined(separator: ", "))").foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ label: String, _ keys: String) -> some View {
        LabeledContent(label) { Text(keys).monospaced() }
    }
}

struct GeneralPane: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Access") {
                Toggle("Show in Dock", isOn: model.binding(\.showInDock))
                Text("The menu bar icon is always there. Turn the Dock icon off if the prompter doesn't float over full-screen apps.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open this window when VoicePrompter starts", isOn: model.binding(\.showWindowOnLaunch))
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = "Couldn't change this: \(error.localizedDescription). Move VoicePrompter to Applications first."
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
            Section {
                Button("Quit VoicePrompter") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }
}
