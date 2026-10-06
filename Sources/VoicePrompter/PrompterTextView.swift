import AppKit
import PrompterCore

/// Renders the script and applies read / current / upcoming styling incrementally.
/// Also handles drag-to-move (anywhere on the text) and double-click-to-jump.
final class PrompterTextView: NSTextView {
    var onDoubleClickCharacter: ((Int) -> Void)?

    private var script = Script(text: "")
    private var position = -1
    private var style = Style()

    struct Style: Equatable {
        var fontSize: CGFloat = 34
        var text: NSColor = .white
        var highlight: NSColor = .systemYellow
        var readOpacity: CGFloat = 0.35
        var lineHeight: CGFloat = 1.2
    }

    static func make() -> PrompterTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let tv = PrompterTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = false
        tv.isRichText = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 26, height: 22)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return tv
    }

    // MARK: - Rendering

    func render(script: Script, position: Int, style: Style) {
        self.script = script
        self.position = position
        self.style = style
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = style.lineHeight
        para.paragraphSpacing = style.fontSize * 0.45
        let font = NSFont.systemFont(ofSize: style.fontSize, weight: .medium)
        let attr = NSMutableAttributedString(string: script.text, attributes: [
            .font: font, .foregroundColor: style.text, .paragraphStyle: para,
        ])
        textStorage?.setAttributedString(attr)
        paint(from: 0, to: (script.text as NSString).length)
    }

    func updatePosition(_ new: Int) {
        let old = position
        position = new
        guard old != new else { return }
        let lo = min(readEnd(old), readEnd(new))
        let hi = max(currentEnd(old), currentEnd(new))
        paint(from: lo, to: hi)
    }

    private func readEnd(_ p: Int) -> Int { p >= 0 && p < script.tokens.count ? script.tokens[p].range.location : 0 }
    private func currentEnd(_ p: Int) -> Int { p >= 0 && p < script.tokens.count ? NSMaxRange(script.tokens[p].range) : 0 }

    /// Repaints [lo, hi): read text dimmed, current word highlighted, the rest normal.
    private func paint(from lo: Int, to hi: Int) {
        guard let ts = textStorage, hi > lo else { return }
        let len = ts.length
        let lo = max(0, lo), hi = min(len, hi)
        guard hi > lo else { return }
        ts.beginEditing()
        ts.addAttribute(.foregroundColor, value: style.text, range: NSRange(location: lo, length: hi - lo))
        let re = readEnd(position)
        if re > lo {
            ts.addAttribute(.foregroundColor, value: style.text.withAlphaComponent(style.readOpacity),
                            range: NSRange(location: lo, length: min(re, hi) - lo))
        }
        if position >= 0, position < script.tokens.count {
            let r = NSIntersectionRange(script.tokens[position].range, NSRange(location: lo, length: hi - lo))
            if r.length > 0 { ts.addAttribute(.foregroundColor, value: style.highlight, range: r) }
        }
        ts.endEditing()
    }

    // MARK: - Scrolling

    /// Scrolls so the current line sits in the upper third of the visible area.
    func scrollToCurrent(animated: Bool) {
        guard let scrollView = enclosingScrollView, let lm = layoutManager, let tc = textContainer else { return }
        let clip = scrollView.contentView
        var targetY: CGFloat = 0
        if position >= 0, position < script.tokens.count {
            lm.ensureLayout(for: tc)
            let glyphs = lm.glyphRange(forCharacterRange: script.tokens[position].range, actualCharacterRange: nil)
            let line = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let lineMidY = line.midY + textContainerOrigin.y
            targetY = max(0, lineMidY - clip.bounds.height / 3)
        }
        let maxY = max(0, frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
        targetY = min(targetY, maxY)
        guard abs(clip.bounds.origin.y - targetY) > 1 else { return }
        let target = NSPoint(x: 0, y: targetY)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let p = convert(event.locationInWindow, from: nil)
            onDoubleClickCharacter?(characterIndexForInsertion(at: p))
            return
        }
        WindowDragger.track(event)
    }

}

/// Moves a borderless window by dragging, or resizes it when the drag starts within a few points
/// of an edge. Borderless windows don't reliably resize from their edges on their own.
enum WindowDragger {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), bottom = Edges(rawValue: 4), top = Edges(rawValue: 8)
    }
    static let grip: CGFloat = 8

    static func edges(at p: NSPoint, in window: NSWindow) -> Edges {
        let size = window.frame.size
        var e: Edges = []
        if p.x < grip { e.insert(.left) }
        if p.x > size.width - grip { e.insert(.right) }
        if p.y < grip { e.insert(.bottom) }
        if p.y > size.height - grip { e.insert(.top) }
        return e
    }

    static func cursor(at p: NSPoint, in window: NSWindow) -> NSCursor {
        let e = edges(at: p, in: window)
        if e.isEmpty { return .arrow }
        if e == .left || e == .right { return .resizeLeftRight }
        if e == .top || e == .bottom { return .resizeUpDown }
        return .crosshair
    }

    static func track(_ event: NSEvent) {
        guard let window = event.window else { return }
        let grab = edges(at: event.locationInWindow, in: window)
        let startMouse = NSEvent.mouseLocation
        let start = window.frame
        let minSize = window.minSize
        var dragging = false
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type != .leftMouseUp {
            let m = NSEvent.mouseLocation
            let dx = m.x - startMouse.x, dy = m.y - startMouse.y
            if !dragging && hypot(dx, dy) < 3 { continue }
            dragging = true
            guard !grab.isEmpty else {
                window.setFrameOrigin(NSPoint(x: start.minX + dx, y: start.minY + dy))
                continue
            }
            var f = start
            if grab.contains(.right) { f.size.width = max(minSize.width, start.width + dx) }
            if grab.contains(.left) { f.size.width = max(minSize.width, start.width - dx); f.origin.x = start.maxX - f.width }
            if grab.contains(.top) { f.size.height = max(minSize.height, start.height + dy) }
            if grab.contains(.bottom) { f.size.height = max(minSize.height, start.height - dy); f.origin.y = start.maxY - f.height }
            window.setFrame(f, display: true)
        }
    }
}
