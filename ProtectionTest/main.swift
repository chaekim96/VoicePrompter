// Content-protection capture harness.
//
// Puts two identical overlay panels on screen:
//   PROTECTED (magenta)  sharingType = .none   <- what the teleprompter uses
//   CONTROL   (green)    sharingType = .readOnly (default)
// then captures the main display with every capture API we can reach and samples the
// pixels under each panel. A capture method "honors" protection when the control panel
// shows up and the protected one doesn't. If the control is missing, the result is invalid
// (e.g. no Screen Recording permission).

import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - Test windows

func makePanel(color: NSColor, x: CGFloat, protected: Bool) -> NSPanel {
    let size: CGFloat = 240
    let screen = NSScreen.screens[0]
    let frame = NSRect(x: screen.frame.minX + x, y: screen.frame.maxY - 200 - size, width: size, height: size)
    let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    // Same configuration as the real overlay.
    p.level = .screenSaver
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    p.isOpaque = false
    p.hasShadow = false
    p.backgroundColor = color
    p.sharingType = protected ? .none : .readOnly
    p.ignoresMouseEvents = true
    p.orderFrontRegardless()
    return p
}

// MARK: - Pixel sampling

struct RGB: CustomStringConvertible {
    var r = 0.0, g = 0.0, b = 0.0
    var description: String { String(format: "(%3.0f,%3.0f,%3.0f)", r, g, b) }
    var isMagenta: Bool { r > 180 && g < 90 && b > 180 }
    var isGreen: Bool { g > 180 && r < 120 && b < 120 }
}

/// Average sRGB color of a window's central 40x40pt area inside a full-display capture.
func sample(_ image: CGImage, window: NSWindow, displayID: CGDirectDisplayID) -> RGB {
    let bounds = CGDisplayBounds(displayID)
    let scale = CGFloat(image.width) / bounds.width
    let screenH = NSScreen.screens[0].frame.height
    let f = window.frame
    let cx = (f.midX - bounds.minX) * scale
    let cy = (screenH - f.midY - bounds.minY) * scale
    let half = 20 * scale
    let rect = CGRect(x: cx - half, y: cy - half, width: half * 2, height: half * 2).integral
    guard let crop = image.cropping(to: rect) else { return RGB() }
    let w = crop.width, h = crop.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
    var s = RGB()
    for i in stride(from: 0, to: buf.count, by: 4) {
        s.r += Double(buf[i]); s.g += Double(buf[i + 1]); s.b += Double(buf[i + 2])
    }
    let n = Double(w * h)
    return RGB(r: s.r / n, g: s.g / n, b: s.b / n)
}

let ciContext = CIContext()
func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
    let ci = CIImage(cvPixelBuffer: pixelBuffer)
    return ciContext.createCGImage(ci, from: ci.extent)
}

// MARK: - Capture methods

typealias CGWindowListCreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
typealias CGDisplayCreateImageFn = @convention(c) (UInt32) -> Unmanaged<CGImage>?
let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)

/// Legacy (pre-ScreenCaptureKit) whole-screen snapshot. Obsoleted in the macOS 15 SDK, so called via dlsym.
func captureCGWindowList(_ id: CGDirectDisplayID) -> CGImage? {
    guard let sym = dlsym(cg, "CGWindowListCreateImage") else { return nil }
    let fn = unsafeBitCast(sym, to: CGWindowListCreateImageFn.self)
    // kCGWindowListOptionOnScreenOnly = 1, kCGNullWindowID = 0, kCGWindowImageDefault = 0
    return fn(CGDisplayBounds(id), 1, 0, 0)?.takeRetainedValue()
}

func captureCGDisplayCreateImage(_ id: CGDirectDisplayID) -> CGImage? {
    guard let sym = dlsym(cg, "CGDisplayCreateImage") else { return nil }
    return unsafeBitCast(sym, to: CGDisplayCreateImageFn.self)(id)?.takeRetainedValue()
}

/// Legacy CGDisplayStream (old OBS "Display Capture", older Zoom/Meet builds).
func captureCGDisplayStream(_ id: CGDirectDisplayID) async -> CGImage? {
    let b = CGDisplayBounds(id)
    let scale = NSScreen.screens[0].backingScaleFactor
    return await withCheckedContinuation { cont in
        var done = false
        var stream: CGDisplayStream?
        let q = DispatchQueue(label: "cgds")
        stream = CGDisplayStream(dispatchQueueDisplay: id, outputWidth: Int(b.width * scale), outputHeight: Int(b.height * scale),
                                 pixelFormat: Int32(kCVPixelFormatType_32BGRA), properties: nil, queue: q) { status, _, surface, _ in
            guard !done, status == .frameComplete, let surface else { return }
            done = true
            let ci = CIImage(ioSurface: surface)
            let img = ciContext.createCGImage(ci, from: ci.extent)
            stream?.stop()
            cont.resume(returning: img)
        }
        if stream == nil || stream!.start() != .success { done = true; cont.resume(returning: nil); return }
        q.asyncAfter(deadline: .now() + 3) { if !done { done = true; stream?.stop(); cont.resume(returning: nil) } }
    }
}

/// AVCaptureScreenInput (legacy QuickTime / AVFoundation screen recording).
final class AVGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var cont: CheckedContinuation<CGImage?, Never>?
    var frames = 0
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        guard frames >= 5, let c = cont, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        cont = nil
        c.resume(returning: cgImage(from: pb))
    }
}

func captureAVScreenInput(_ id: CGDirectDisplayID) async -> CGImage? {
    guard let input = AVCaptureScreenInput(displayID: id) else { return nil }
    let session = AVCaptureSession()
    let out = AVCaptureVideoDataOutput()
    out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let g = AVGrabber()
    let q = DispatchQueue(label: "av")
    out.setSampleBufferDelegate(g, queue: q)
    guard session.canAddInput(input), session.canAddOutput(out) else { return nil }
    session.addInput(input); session.addOutput(out)
    let img: CGImage? = await withCheckedContinuation { c in
        q.sync { g.cont = c }
        session.startRunning()
        q.asyncAfter(deadline: .now() + 4) { if let c = g.cont { g.cont = nil; c.resume(returning: nil) } }
    }
    session.stopRunning()
    return img
}

/// ScreenCaptureKit video stream: what Zoom, Chrome/Meet, OBS and QuickTime use on macOS 13+.
final class SCGrabber: NSObject, SCStreamOutput {
    var cont: CheckedContinuation<CGImage?, Never>?
    var frames = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer else { return }
        frames += 1
        guard frames >= 3, let c = cont else { return }
        cont = nil
        c.resume(returning: cgImage(from: pb))
    }
}

func captureSCStream(_ display: SCDisplay, filter: SCContentFilter) async -> CGImage? {
    let cfg = SCStreamConfiguration()
    let scale = Int(NSScreen.screens[0].backingScaleFactor)
    cfg.width = display.width * scale
    cfg.height = display.height * scale
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    let g = SCGrabber()
    let q = DispatchQueue(label: "sc")
    let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
    do { try stream.addStreamOutput(g, type: .screen, sampleHandlerQueue: q) } catch { return nil }
    let img: CGImage? = await withCheckedContinuation { c in
        q.sync { g.cont = c }
        Task {
            do { try await stream.startCapture() } catch {
                print("   SCStream start error: \(error)")
                q.async { if let c = g.cont { g.cont = nil; c.resume(returning: nil) } }
            }
        }
        q.asyncAfter(deadline: .now() + 4) { if let c = g.cont { g.cont = nil; c.resume(returning: nil) } }
    }
    try? await stream.stopCapture()
    return img
}

func captureScreencaptureCLI() -> CGImage? {
    let path = NSTemporaryDirectory() + "prot-\(getpid()).png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-m", path] // -x no sound, -m main display (same path as Cmd-Shift-3)
    try? p.run(); p.waitUntilExit()
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// MARK: - Runner

@MainActor
func run() async {
    let protected = makePanel(color: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1), x: 200, protected: true)
    let control = makePanel(color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), x: 500, protected: false)
    try? await Task.sleep(for: .seconds(1)) // let the window server composite them

    let displayID = CGMainDisplayID()
    let args = CommandLine.arguments
    if args.count >= 3, args[1] == "analyze" {
        // Sample an externally produced screenshot while the panels are still up.
        let url = URL(fileURLWithPath: args[2])
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let c = sample(img, window: control, displayID: displayID), p = sample(img, window: protected, displayID: displayID)
            print("\(url.lastPathComponent): control \(c) protected \(p) ->", !c.isGreen ? "INVALID" : p.isMagenta ? "LEAKS" : "HIDDEN")
        }
        exit(0)
    }
    if args.count >= 3, args[1] == "hold" {
        print("panels up for \(args[2])s"); try? await Task.sleep(for: .seconds(Double(args[2]) ?? 10)); exit(0)
    }
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Screen Recording preflight: \(CGPreflightScreenCaptureAccess())\n")
    print(String(format: "%-44@ %-17@ %-17@ %@", "METHOD" as NSString, "CONTROL rgb" as NSString, "PROTECTED rgb" as NSString, "RESULT" as NSString))

    var rows: [(String, String)] = []
    func report(_ name: String, _ img: CGImage?) {
        guard let img else {
            print(String(format: "%-44@ %@", name as NSString, "capture failed / unavailable" as NSString))
            rows.append((name, "N/A")); return
        }
        let c = sample(img, window: control, displayID: displayID)
        let p = sample(img, window: protected, displayID: displayID)
        let verdict: String
        if !c.isGreen { verdict = "INVALID (control not captured)" }
        else if p.isMagenta { verdict = "LEAKS - overlay visible" }
        else { verdict = "HIDDEN - protection honored" }
        print(String(format: "%-44@ %-17@ %-17@ %@", name as NSString, c.description as NSString, p.description as NSString, verdict as NSString))
        rows.append((name, verdict))
    }

    report("CGWindowListCreateImage (legacy)", captureCGWindowList(displayID))
    report("CGDisplayCreateImage (legacy)", captureCGDisplayCreateImage(displayID))
    report("CGDisplayStream (legacy stream)", await captureCGDisplayStream(displayID))
    report("AVCaptureScreenInput (legacy AVF)", await captureAVScreenInput(displayID))

    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CocoaError(.featureUnsupported) }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = display.width * Int(NSScreen.screens[0].backingScaleFactor)
        cfg.height = display.height * Int(NSScreen.screens[0].backingScaleFactor)
        report("SCScreenshotManager display", try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg))
        report("SCStream display (Zoom/Meet/OBS/QuickTime)", await captureSCStream(display, filter: filter))
        // What a meeting app gets if the user explicitly picks the overlay in a "share a window" picker.
        if let scw = content.windows.first(where: { $0.windowID == CGWindowID(protected.windowNumber) }) {
            let wf = SCContentFilter(desktopIndependentWindow: scw)
            let wc = SCStreamConfiguration(); wc.width = 480; wc.height = 480
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: wf, configuration: wc) {
                let px = img.dataProvider.flatMap { CFDataGetBytePtr($0.data) }
                let bpr = img.bytesPerRow, mid = (img.height / 2) * bpr + (img.width / 2) * 4
                let s = px.map { "BGRA(\($0[mid]),\($0[mid+1]),\($0[mid+2]),\($0[mid+3]))" } ?? "?"
                print("\nSCK single-window capture of PROTECTED panel: \(img.width)x\(img.height), center pixel \(s)")
            } else { print("\nSCK single-window capture of PROTECTED panel: refused/failed") }
        }
        let visibleInList = content.windows.contains { $0.windowID == CGWindowID(protected.windowNumber) }
        print("\nProtected window listed in SCShareableContent.windows: \(visibleInList)")
    } catch {
        print("ScreenCaptureKit unavailable: \(error)")
    }

    protected.close(); control.close()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in await run() }
app.run()
