import AppKit
import Combine
import PrompterCore
import SwiftUI

/// Borderless, non-activating, always-on-top panel. It never takes keyboard focus away from the
/// app you're presenting in, it floats over full-screen apps, and it follows you across Spaces.
final class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 260, height: 140)
        setFrameAutosaveName("OverlayPanel")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Container that shows the hover controls while the mouse is over the overlay.
final class OverlayContainerView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false); NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) {
        guard let window else { return }
        WindowDragger.cursor(at: event.locationInWindow, in: window).set()
    }
    // Clicks on empty space (below short scripts, padding) bubble up here.
    override func mouseDown(with event: NSEvent) { WindowDragger.track(event) }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class OverlayController {
    let panel: OverlayPanel
    private let model: AppModel
    private let textView = PrompterTextView.make()
    private let scrollView = NSScrollView()
    private let container = OverlayContainerView()
    private var controls: NSView!
    private var errorBanner: NSView!
    private var cancellables = Set<AnyCancellable>()
    private var lastStyleKey: PrompterTextView.Style?
    private var lastScriptText = ""
    var actions = OverlayActions()

    init(model: AppModel) {
        self.model = model
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(760, screen.width * 0.5), height: 300)
        panel = OverlayPanel(frame: NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 40,
                                           width: size.width, height: size.height))
        buildViews()
        bind()
        render(force: true)
    }

    private func buildViews() {
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        panel.contentView = container

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = textView
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        textView.onDoubleClickCharacter = { [weak self] idx in self?.jump(toCharacter: idx) }

        let controlsView = FirstMouseHostingView(rootView: HoverControls(model: model, actions: { [weak self] in self?.actions ?? OverlayActions() }))
        controlsView.frame = NSRect(x: container.bounds.width - 170, y: container.bounds.height - 40, width: 164, height: 34)
        controlsView.autoresizingMask = [.minXMargin, .minYMargin]
        controlsView.alphaValue = 0
        container.addSubview(controlsView)
        controls = controlsView

        let status = FirstMouseHostingView(rootView: StatusOverlay(model: model))
        status.frame = container.bounds
        status.autoresizingMask = [.width, .height]
        // The status layer only draws small badges, so all clicks pass through it to the text.
        let passthrough = PassthroughView(frame: container.bounds, hosted: status)
        passthrough.autoresizingMask = [.width, .height]
        container.addSubview(passthrough, positioned: .below, relativeTo: controlsView)

        let banner = FirstMouseHostingView(rootView: ErrorBanner(model: model))
        banner.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: 64)
        banner.autoresizingMask = [.width, .maxYMargin]
        banner.isHidden = true
        container.addSubview(banner)
        errorBanner = banner

        container.onHoverChange = { [weak self] inside in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; self.controls.animator().alphaValue = inside ? 1 : 0 }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutInsets() }
        }
        layoutInsets()
    }

    private func layoutInsets() {
        // Extra space below the text so the last lines can still reach the upper third.
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: scrollView.bounds.height * 0.6, right: 0)
        textView.scrollToCurrent(animated: false)
    }

    private func bind() {
        model.onPositionChange = { [weak self] p, animated in
            self?.textView.updatePosition(p)
            self?.textView.scrollToCurrent(animated: animated)
        }
        model.$settings.sink { [weak self] _ in DispatchQueue.main.async { self?.render(force: false) } }.store(in: &cancellables)
        model.$script.sink { [weak self] _ in DispatchQueue.main.async { self?.render(force: false) } }.store(in: &cancellables)
        model.$clickThrough.sink { [weak self] on in
            self?.panel.ignoresMouseEvents = on
            if on { self?.controls.alphaValue = 0 }
        }.store(in: &cancellables)
        model.$tracking.sink { [weak self] state in
            if case .error = state { self?.errorBanner.isHidden = false } else { self?.errorBanner.isHidden = true }
        }.store(in: &cancellables)
        model.$overlayVisible.sink { [weak self] visible in
            guard let self else { return }
            visible ? self.panel.orderFrontRegardless() : self.panel.orderOut(nil)
        }.store(in: &cancellables)
    }

    private func render(force: Bool) {
        let s = model.settings
        let style = PrompterTextView.Style(fontSize: s.fontSize, text: s.textColor.nsColor, highlight: s.highlightColor.nsColor,
                                           readOpacity: s.readTextOpacity, lineHeight: s.lineHeight)
        container.layer?.backgroundColor = s.backgroundColor.nsColor.withAlphaComponent(s.backgroundOpacity).cgColor
        panel.alphaValue = s.windowOpacity
        let protect = s.protectFromCapture && !model.launch.disableProtection
        for w in NSApp.windows { w.sharingType = protect ? .none : .readOnly }
        panel.sharingType = protect ? .none : .readOnly

        if force || style != lastStyleKey || model.script.text != lastScriptText {
            lastStyleKey = style
            lastScriptText = model.script.text
            textView.render(script: model.script, position: model.position, style: style)
            textView.scrollToCurrent(animated: false)
        }
    }

    /// Puts the prompter back at the top-center of the screen the mouse is on.
    func recenter() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        var f = panel.frame
        f.size.width = min(f.width, vf.width - 40)
        f.size.height = min(f.height, vf.height - 40)
        f.origin = NSPoint(x: vf.midX - f.width / 2, y: vf.maxY - f.height - 20)
        panel.setFrame(f, display: true, animate: true)
        panel.orderFrontRegardless()
    }

    /// Renders the overlay's current contents to a PNG, independent of the display.
    func writeSnapshot(to url: URL) {
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: - Navigation

    private func jump(toCharacter idx: Int) {
        let tokens = model.script.tokens
        guard let i = tokens.lastIndex(where: { $0.range.location <= idx }) else { model.setPosition(-1); return }
        model.setPosition(i)
    }

    /// Moves the position to the first word of the next or previous visual line.
    func nudge(lines: Int) {
        guard let lm = textView.layoutManager else { return }
        let tokens = model.script.tokens
        guard !tokens.isEmpty else { return }
        let lineY: (Int) -> CGFloat = { i in
            let g = lm.glyphRange(forCharacterRange: tokens[i].range, actualCharacterRange: nil)
            return lm.lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil).minY
        }
        let cur = max(0, model.position)
        let curY = lineY(cur)
        if lines > 0 {
            if let next = (cur..<tokens.count).first(where: { lineY($0) > curY + 1 }) { model.setPosition(next) }
        } else if let prevLast = (0..<cur).last(where: { lineY($0) < curY - 1 }) {
            let prevY = lineY(prevLast)
            let start = (0...prevLast).last(where: { lineY($0) < prevY - 1 }).map { $0 + 1 } ?? 0
            model.setPosition(start)
        } else {
            model.setPosition(-1)
        }
    }
}

/// Hosts a display-only SwiftUI view. Mouse events always go to the views underneath.
final class PassthroughView: NSView {
    private let hosted: NSView
    init(frame: NSRect, hosted: NSView) {
        self.hosted = hosted
        super.init(frame: frame)
        hosted.frame = bounds
        addSubview(hosted)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct OverlayActions {
    var openMainWindow: () -> Void = {}
}

// MARK: - SwiftUI chrome

struct HoverControls: View {
    @ObservedObject var model: AppModel
    let actions: () -> OverlayActions

    var body: some View {
        HStack(spacing: 2) {
            button(model.tracking.isActive ? "pause.fill" : "play.fill",
                   model.tracking.isActive ? "Pause tracking (⌃⌥Space)" : "Start tracking (⌃⌥Space)") { model.toggleTracking(source: "overlay button") }
            button("backward.end.fill", "Back to start (⌃⌥R)") { model.resetToStart() }
            button("eye.slash", "Hide (⌃⌥H)") { model.overlayVisible = false }
            button("slider.horizontal.3", "Open VoicePrompter: script & settings (⌃⌥O)") { actions().openMainWindow() }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 32, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .help(help)
    }
}

struct StatusOverlay: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                    .shadow(color: dotColor.opacity(0.8), radius: model.tracking == .listening ? 3 : 0)
                if model.clickThrough {
                    Image(systemName: "cursorarrow.rays").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                }
                if model.isLost && model.tracking == .listening {
                    Text("Lost your place: keep reading or double-click a word")
                        .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.8))
                }
            }
            .padding(.leading, 10).padding(.top, 9)
            .help(statusHelp)
            Spacer()
            if model.settings.showLatencyStats, !isError {
                Text(statsLine).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var isError: Bool { if case .error = model.tracking { return true } else { return false } }

    private var dotColor: Color {
        switch model.tracking {
        case .listening: return model.isLost ? .orange : .green
        case .starting: return .yellow
        case .stopped: return .gray.opacity(0.6)
        case .error: return .red
        }
    }

    private var statusHelp: String {
        switch model.tracking {
        case .listening: return "Listening"
        case .starting: return "Starting…"
        case .stopped: return "Paused. Press ⌃⌥Space to start."
        case .error(let m, _): return m
        }
    }

    private var statsLine: String {
        let s = model.stats
        let onset = s.onsetToPartialMs.map { String(format: "%.0f", $0) } ?? "–"
        let median = s.medianOnsetMs.map { String(format: "%.0f", $0) } ?? "–"
        let pipe = s.pipelineMs.map { String(format: "%.1f", $0) } ?? "–"
        return "speech→partial \(onset) ms (median \(median)) · partial→highlight \(pipe) ms · \(s.decision)"
    }
}

struct ErrorBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if case .error(let message, let url) = model.tracking {
            content(message, url)
        }
    }

    private func content(_ message: String, _ url: URL?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.system(size: 12)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let url {
                Button("Open Settings") { NSWorkspace.shared.open(url) }.controlSize(.small)
            }
            Button { model.dismissError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.75)))
        .padding(8)
    }
}
