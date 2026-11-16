import AppKit
import Combine
import PrompterCore
import SwiftUI

/// Borderless, non-activating, always-on-top panel. It never takes keyboard focus away from the
/// app you're presenting in, it floats over full-screen apps, and it follows you across Spaces.
final class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable, .miniaturizable],
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
        // Free-mode frames are saved by hand (see OverlayController) so snapping under the camera never overwrites them.
    }

    /// True in Under camera placement: the strip stays pinned and centered under the lens.
    var cameraLocked = false
    /// Called when the user drags the text in a locked strip (the controller switches to Free placement).
    var onPickedUp: (() -> Void)?
    /// Called with the new width after an edge drag resized the locked strip.
    var onStripResized: ((CGFloat) -> Void)?
    var maxWidthForStrip: CGFloat { (screen ?? NSScreen.main)?.frame.width.advanced(by: -40) ?? 1200 }

    /// Borderless panels are otherwise nudged below the menu bar. We position under the notch ourselves.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Container that shows the hover controls while the mouse is over the overlay.
final class OverlayContainerView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onLayout: (() -> Void)?
    override func resizeSubviews(withOldSize oldSize: NSSize) { super.resizeSubviews(withOldSize: oldSize); onLayout?() }
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

/// Where the strip sits relative to the camera. On a notched MacBook that is directly below the notch,
/// centered on it. Elsewhere it is the top-center of the main display, below the menu bar.
enum CameraGeometry {
    /// The built-in display (the one with a notch), else the main display.
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Horizontal center of the notch in global coordinates, or the screen's center if there is none.
    static func centerX(on screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            // The notch is the gap between the two usable top areas.
            return (l.maxX + r.minX) / 2
        }
        return screen.frame.midX
    }

    /// The y coordinate the strip's top edge sits at: the bottom edge of the notch, or the bottom of the
    /// menu bar on a display without one.
    /// Top edge of the strip: fully below the menu bar, and below the notch even when the menu bar auto-hides.
    static func stripTop(on screen: NSScreen) -> CGFloat {
        min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
    }
}

@MainActor
final class OverlayController {
    let panel: OverlayPanel
    private let model: AppModel
    private let textView = PrompterTextView.make()
    private let scrollView = NSScrollView()
    private let fadeHost = NSView()   // carries the fade mask; layer masks are unreliable directly on NSScrollView
    private let container = OverlayContainerView()
    private var controls: NSView!
    private var errorBanner: NSView!
    private var windowButtons: NSView!
    private var chrome: NSView!
    private let hover = HoverState()
    private var cancellables = Set<AnyCancellable>()
    private var lastStyleKey: PrompterTextView.Style?
    private var lastScriptText = ""
    private var lastPlacementKey = ""
    private var programmatic = false      // true while we set the frame ourselves (don't save it as the Free frame)
    private var keepCurrentFrameOnFree = false
    private let fadeMask = CAGradientLayer()
    var actions = OverlayActions()

    private static let footerHeight: CGFloat = 22
    private static let frameName = "OverlayPanel"

    private var isCamera: Bool { model.settings.placement == .underCamera }
    private var footer: CGFloat { (isCamera || model.settings.showProgressDetails) ? Self.footerHeight : 0 }

    init(model: AppModel) {
        self.model = model
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(760, screen.width * 0.5), height: 300)
        panel = OverlayPanel(frame: NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 40,
                                           width: size.width, height: size.height))
        buildViews()
        bind()
        render(force: true)
        applyPlacement(restoreFree: true)
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
        fadeHost.wantsLayer = true
        fadeHost.frame = container.bounds
        scrollView.frame = fadeHost.bounds
        scrollView.autoresizingMask = [.width, .height]
        fadeHost.addSubview(scrollView)
        container.addSubview(fadeHost)
        textView.onDoubleClickCharacter = { [weak self] idx in self?.jump(toCharacter: idx) }

        let controlsView = FirstMouseHostingView(rootView: HoverControls(model: model, actions: { [weak self] in self?.actions ?? OverlayActions() }))
        controlsView.autoresizingMask = []
        controlsView.alphaValue = 0
        container.addSubview(controlsView)
        controls = controlsView

        let buttons = FirstMouseHostingView(rootView: WindowButtons(
            close: { [weak self] in self?.model.overlayVisible = false },
            minimize: { [weak self] in self?.minimize() }))
        buttons.autoresizingMask = []
        buttons.alphaValue = 0
        container.addSubview(buttons)
        windowButtons = buttons

        let status = FirstMouseHostingView(rootView: StatusOverlay(model: model, hover: hover))
        status.frame = container.bounds
        status.autoresizingMask = [.width, .height]
        // The status layer only draws small badges, so all clicks pass through it to the text.
        let passthrough = PassthroughView(frame: container.bounds, hosted: status)
        passthrough.autoresizingMask = [.width, .height]
        container.addSubview(passthrough, positioned: .below, relativeTo: controlsView)
        chrome = passthrough

        let banner = FirstMouseHostingView(rootView: ErrorBanner(model: model))
        banner.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: 64)
        banner.autoresizingMask = [.width, .maxYMargin]
        banner.isHidden = true
        container.addSubview(banner)
        errorBanner = banner

        container.onHoverChange = { [weak self] inside in
            guard let self else { return }
            self.hover.inside = inside
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.15
                self.controls.animator().alphaValue = inside ? 1 : 0
                self.windowButtons.animator().alphaValue = inside ? 1 : 0
            }
        }
        container.onLayout = { [weak self] in self?.layoutChrome() }
        layoutChrome()
    }

    /// Positions the scroll view and the hover controls. Under camera, the controls live in a footer band so
    /// they never cover the text; in Free mode they sit in the top corners as before.
    private func layoutChrome() {
        let b = container.bounds
        let footer = self.footer
        fadeHost.frame = NSRect(x: 0, y: footer, width: b.width, height: max(0, b.height - footer))
        scrollView.frame = fadeHost.bounds
        if isCamera {
            controls.frame = NSRect(x: b.width - 128 - 8, y: (footer - 22) / 2, width: 128, height: 22)
            windowButtons.frame = NSRect(x: 6, y: (footer - 22) / 2, width: 56, height: 22)
        } else {
            controls.frame = NSRect(x: b.width - 170, y: b.height - 40, width: 164, height: 34)
            windowButtons.frame = NSRect(x: 6, y: b.height - 30, width: 56, height: 26)
        }
        // Extra room below the text so the last lines can still reach the anchor line.
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: scrollView.bounds.height * (isCamera ? 0.95 : 0.6), right: 0)
        updateFadeMask()
        textView.scrollToCurrent(animated: false)
    }

    /// Camera strip: soft fade at the very top and a dimmer last line, so only the current line reads as bright.
    private func updateFadeMask() {
        guard isCamera, fadeHost.bounds.height > 0 else { fadeHost.layer?.mask = nil; return }
        let h = fadeHost.bounds.height
        let lineH = lineHeight()
        fadeMask.frame = fadeHost.bounds
        fadeMask.startPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 0)
        let a = min(0.2, 6 / h), b = max(a + 0.01, min(0.99, 1 - lineH * 0.9 / h))
        fadeMask.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.cgColor,
                           NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.3).cgColor]
        fadeMask.locations = [0, NSNumber(value: Double(a)), NSNumber(value: Double(b)), 1]
        fadeHost.layer?.mask = fadeMask
    }

    private func lineHeight() -> CGFloat {
        let s = model.settings
        let font = NSFont.systemFont(ofSize: s.fontSize, weight: .medium)
        return ceil(NSLayoutManager().defaultLineHeight(for: font) * CGFloat(s.lineHeight))
    }

    private func bind() {
        model.onPositionChange = { [weak self] p, animated in
            self?.textView.updatePosition(p)
            self?.textView.scrollToCurrent(animated: animated)
        }
        model.onSnapRequest = { [weak self] in self?.applyPlacement(restoreFree: false) }
        model.$settings.sink { [weak self] _ in DispatchQueue.main.async { self?.render(force: false) } }.store(in: &cancellables)
        model.$script.sink { [weak self] _ in DispatchQueue.main.async { self?.render(force: false) } }.store(in: &cancellables)
        model.$clickThrough.sink { [weak self] on in
            self?.panel.ignoresMouseEvents = on
            if on { self?.controls.alphaValue = 0; self?.windowButtons.alphaValue = 0; self?.hover.inside = false }
        }.store(in: &cancellables)
        model.$tracking.sink { [weak self] state in
            if case .error = state { self?.errorBanner.isHidden = false } else { self?.errorBanner.isHidden = true }
        }.store(in: &cancellables)
        model.$overlayVisible.sink { [weak self] visible in
            guard let self else { return }
            if visible {
                if self.panel.isMiniaturized { self.panel.deminiaturize(nil) }
                self.panel.orderFrontRegardless()
            } else {
                self.panel.orderOut(nil)
            }
        }.store(in: &cancellables)

        // Under-camera strip: picking it up switches to Free; edge drags set the width.
        panel.onPickedUp = { [weak self] in
            guard let self else { return }
            self.panel.cameraLocked = false
            self.keepCurrentFrameOnFree = true
            self.model.settings.placement = .free
        }
        panel.onStripResized = { [weak self] w in self?.model.settings.stripWidth = Double(w.rounded()) }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isCamera == true { self?.applyPlacement(restoreFree: false) } }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didResizeNotification] {
            nc.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveFreeFrameIfNeeded() }
            }
        }
    }

    // MARK: - Placement

    private func saveFreeFrameIfNeeded() {
        guard !programmatic, !isCamera, !panel.cameraLocked else { return }
        panel.saveFrame(usingName: Self.frameName)
    }

    /// The strip's frame under the camera, or nil when there is no screen.
    func cameraFrame() -> NSRect? {
        guard let screen = CameraGeometry.targetScreen() else { return nil }
        let s = model.settings
        let w = min(max(300, CGFloat(s.stripWidth)), screen.frame.width - 40)
        let h = ceil(8 + lineHeight() * CGFloat(max(1, s.stripLines)) + 2 + Self.footerHeight)
        let cx = CameraGeometry.centerX(on: screen)
        let x = min(max(screen.frame.minX + 8, cx - w / 2), screen.frame.maxX - w - 8)
        return NSRect(x: x, y: CameraGeometry.stripTop(on: screen) - h, width: w, height: h)
    }

    /// Applies the Placement setting: pins the strip under the camera, or restores the Free frame.
    private func applyPlacement(restoreFree: Bool) {
        programmatic = true
        defer { programmatic = false }
        panel.cameraLocked = isCamera
        container.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        if isCamera {
            panel.minSize = NSSize(width: 300, height: 60)
            if let f = cameraFrame() { panel.setFrame(f, display: true) }
        } else {
            panel.minSize = NSSize(width: 260, height: 140)
            if keepCurrentFrameOnFree {
                keepCurrentFrameOnFree = false
                panel.saveFrame(usingName: Self.frameName)
            } else if restoreFree {
                let before = panel.frame
                panel.setFrameUsingName(Self.frameName)
                if !NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) { panel.setFrame(before, display: true) }
            }
        }
        layoutChrome()
    }

    private func render(force: Bool) {
        let s = model.settings
        let style = PrompterTextView.Style(fontSize: s.fontSize, text: s.textColor.nsColor, highlight: s.highlightColor.nsColor,
                                           readOpacity: s.readTextOpacity, lineHeight: s.lineHeight,
                                           camera: s.placement == .underCamera)
        container.layer?.backgroundColor = s.backgroundColor.nsColor.withAlphaComponent(s.backgroundOpacity).cgColor
        panel.alphaValue = s.windowOpacity
        let protect = s.protectFromCapture && !model.launch.disableProtection
        for w in NSApp.windows { w.sharingType = protect ? .none : .readOnly }
        panel.sharingType = protect ? .none : .readOnly

        if force || style != lastStyleKey || model.script.text != lastScriptText {
            lastStyleKey = style
            lastScriptText = model.script.text
            textView.render(script: model.script, position: model.position, style: style)
        }
        let key = "\(s.placement.rawValue)|\(s.stripWidth)|\(s.stripLines)|\(s.fontSize)|\(s.lineHeight)|\(s.showProgressDetails)"
        if key != lastPlacementKey {
            let first = lastPlacementKey.isEmpty
            let placementChanged = !lastPlacementKey.hasPrefix(s.placement.rawValue + "|")
            lastPlacementKey = key
            if !first { applyPlacement(restoreFree: placementChanged) }
        }
        textView.scrollToCurrent(animated: false)
    }

    /// Minimizes to the Dock like any window. Without a Dock icon there's nowhere to minimize to, so it hides.
    func minimize() {
        if model.settings.showInDock {
            panel.miniaturize(nil)
        } else {
            model.overlayVisible = false
        }
    }

    /// Under camera: snaps back under the lens. Free: puts the prompter at the top-center of the screen the mouse is on.
    func recenter() {
        if isCamera { applyPlacement(restoreFree: false); panel.orderFrontRegardless(); return }
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
    private var compact: Bool { model.settings.placement == .underCamera }

    var body: some View {
        HStack(spacing: compact ? 0 : 2) {
            button(model.tracking.isActive ? "pause.fill" : "play.fill",
                   model.tracking.isActive ? "Pause tracking (⌃⌥Space)" : "Start tracking (⌃⌥Space)") { model.toggleTracking(source: "overlay button") }
            button("backward.end.fill", "Back to start (⌃⌥R)") { model.resetToStart() }
            button("eye.slash", "Hide (⌃⌥H)") { model.overlayVisible = false }
            button("slider.horizontal.3", "Open VoicePrompter: script & settings (⌃⌥O)") { actions().openMainWindow() }
        }
        .padding(.horizontal, compact ? 3 : 6)
        .frame(height: compact ? 22 : 30)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: compact ? 10 : 12, weight: .semibold))
                .frame(width: compact ? 30 : 32, height: compact ? 20 : 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .help(help)
    }
}

final class HoverState: ObservableObject {
    @Published var inside = false
}

/// Close and minimize buttons in the familiar macOS style, shown while hovering over the prompter.
struct WindowButtons: View {
    let close: () -> Void
    let minimize: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            light(Color(red: 1, green: 0.37, blue: 0.34), symbol: "xmark", help: "Hide prompter (⌃⌥H to show again)", action: close)
            light(Color(red: 1, green: 0.74, blue: 0.18), symbol: "minus", help: "Minimize to the Dock", action: minimize)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color).overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 0.5))
                Image(systemName: symbol).font(.system(size: 7, weight: .black))
                    .foregroundStyle(Color.black.opacity(0.6)).opacity(hovering ? 1 : 0)
            }
            .frame(width: 12, height: 12)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Display-only layer over the text: the progress rail along the top edge (the side nearest the camera),
/// the status dot, and a footer with section dots and the time left. Nothing here covers the text.
struct StatusOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hover: HoverState

    private var camera: Bool { model.settings.placement == .underCamera }
    private var tint: Color { model.settings.highlightColor.color }
    private var active: Bool { model.tracking.isActive }
    private var lostNow: Bool { model.isLost && model.tracking == .listening }
    private var showFooter: Bool { model.settings.showProgressDetails || lostNow }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                        .shadow(color: dotColor.opacity(0.8), radius: model.tracking == .listening ? 3 : 0)
                    if model.clickThrough {
                        Image(systemName: "cursorarrow.rays").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.leading, 10).padding(.top, 11)
                .opacity(hover.inside && !camera ? 0 : 1) // free mode: make room for the close/minimize buttons
                .help(statusHelp)
                Spacer(minLength: 0)
                if model.settings.showLatencyStats, !isError {
                    Text(statsLine).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 8).padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            ProgressRail(fraction: model.progressFraction, ticks: tickFractions, tint: tint, active: active)
                .frame(height: 4)

            VStack {
                Spacer(minLength: 0)
                if showFooter {
                    footer.frame(height: 22)
                        .opacity(hover.inside && camera ? 0 : 1) // hover controls take over the footer
                        .animation(.easeOut(duration: 0.15), value: hover.inside)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if lostNow {
                Text("Lost your place: keep reading or double-click a word")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange.opacity(0.9)).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                SectionDots(count: model.script.paragraphCount, current: model.currentParagraph,
                            started: model.position >= 0, fraction: model.paragraphFraction,
                            tint: tint, active: active)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.script.paragraphCount > 0 {
                    Text(progressLabel).font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(active ? 0.75 : 0.45)).lineLimit(1).fixedSize()
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private var progressLabel: String {
        var parts = ["\(model.currentParagraph + 1)/\(model.script.paragraphCount)"]
        if let left = model.timeLeftText { parts.append(left) }
        return parts.joined(separator: "  ·  ")
    }

    /// Where each paragraph after the first starts, as a fraction of the script, for the rail's notches.
    private var tickFractions: [Double] {
        let n = Double(max(1, model.script.tokens.count))
        return model.script.paragraphStarts.dropFirst().map { Double($0) / n }
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

/// A 4pt bar along the top edge that fills left to right as you read. Dimmer while paused.
struct ProgressRail: View {
    let fraction: Double
    let ticks: [Double]
    let tint: Color
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.10))
                Rectangle().fill(tint.opacity(active ? 1 : 0.45))
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))))
                    .shadow(color: tint.opacity(active ? 0.7 : 0), radius: 3, y: 1)
                    .animation(.easeOut(duration: 0.3), value: fraction)
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, t in
                    Rectangle().fill(Color.black.opacity(0.55)).frame(width: 1.5)
                        .offset(x: geo.size.width * CGFloat(t) - 0.75)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// One dot per paragraph: read ones are filled, the current one is a larger ring that fills as you
/// read it (and pulses while listening), upcoming ones are hollow.
struct SectionDots: View {
    let count: Int
    let current: Int
    let started: Bool
    let fraction: Double
    let tint: Color
    let active: Bool
    @State private var pulse = false

    private let slot: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let fit = max(3, Int(geo.size.width / slot))
            let first = count <= fit ? 0 : min(max(0, current - fit / 2), count - fit)
            let last = min(count, first + fit)
            HStack(spacing: 0) {
                ForEach(first..<max(first, last), id: \.self) { i in
                    dot(i).frame(width: slot, height: 14)
                        .scaleEffect((i == first && first > 0) || (i == last - 1 && last < count) ? 0.65 : 1)
                }
            }
            .frame(height: geo.size.height, alignment: .leading)
        }
        .frame(height: 14)
        .onAppear { pulse = true }
    }

    @ViewBuilder private func dot(_ i: Int) -> some View {
        if i == current {
            ZStack {
                Circle().stroke(tint.opacity(0.35), lineWidth: 1.5)
                Circle().trim(from: 0, to: started ? max(0.04, fraction) : 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).rotationEffect(.degrees(-90))
                Circle().fill(tint.opacity(active ? 1 : 0.6)).frame(width: 4, height: 4)
            }
            .frame(width: 10, height: 10)
            .scaleEffect(active && pulse ? 1.18 : 1)
            .animation(active ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            .animation(.easeOut(duration: 0.3), value: fraction)
        } else if i < current {
            Circle().fill(tint.opacity(active ? 0.9 : 0.5)).frame(width: 6, height: 6)
        } else {
            Circle().stroke(Color.white.opacity(0.45), lineWidth: 1).frame(width: 6, height: 6)
        }
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
