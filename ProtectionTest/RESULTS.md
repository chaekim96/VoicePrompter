# Content-protection test results

**Machine:** MacBook Pro M3 Pro, **macOS 15.7.4 (24G517)**, tested 2026-09-30.
**Harness:** `main.swift` in this folder (`make protection-test` from the repo root).

Method: two identical always-on-top `NSPanel`s are shown with the same configuration as the teleprompter
overlay (borderless, non-activating, `.screenSaver` level, `.canJoinAllSpaces + .fullScreenAuxiliary`).
One is magenta with `sharingType = .none` (protected), the other is green with the default
`sharingType = .readOnly` (control). Each capture API grabs the main display and the pixels under both
panels are averaged. A result counts only if the control panel is visible in the capture.

| Capture path | Used by | Result |
|---|---|---|
| `SCStream`, whole display | Zoom, Chrome/Google Meet, OBS "macOS Screen Capture", QuickTime and Cmd-Shift-5 recording on macOS 14+ | ✅ **Hidden** |
| `SCScreenshotManager`, whole display | Modern screenshot tools | ✅ **Hidden** |
| `screencapture -x` still (the Cmd-Shift-3/4 code path) | macOS screenshots | ✅ **Hidden** |
| `CGWindowListCreateImage` (legacy) | Older screenshot and sharing tools | ✅ **Hidden** |
| `CGDisplayCreateImage` (legacy) | Older screenshot tools | ✅ **Hidden** |
| SCK single-window capture of the overlay itself (someone picks it in a "share window" picker) | Any SCK app | ✅ **Blank**: fully transparent frame. The window *is* listed in `SCShareableContent`, so its name can show up in pickers. |
| `CGDisplayStream` (legacy stream, obsoleted in the macOS 15 SDK but still works at runtime) | OBS "Display Capture (deprecated)", older Zoom/WebRTC builds | ❌ **Leaks**: overlay is visible |
| `AVCaptureScreenInput` (legacy AVFoundation) | Older recorders and apps built on AVFoundation | ❌ **Leaks**: overlay is visible |
| `screencapture -v` (command-line video recording) | Scripts, some utilities | ❌ **Leaks**: overlay is visible |

Raw output (reproduced across 3 runs):

```
CGWindowListCreateImage (legacy)            (  3,255,  0) (255,255,255) HIDDEN - protection honored
CGDisplayCreateImage (legacy)               (  3,255,  0) (255,255,255) HIDDEN - protection honored
CGDisplayStream (legacy stream)             (  3,255,  0) (255,  0,255) LEAKS - overlay visible
AVCaptureScreenInput (legacy AVF)           (  0,255,  0) (255,  0,255) LEAKS - overlay visible
SCScreenshotManager display                 (117,251, 76) (255,255,255) HIDDEN - protection honored
SCStream display (Zoom/Meet/OBS/QuickTime)  (  3,255,  0) (255,255,255) HIDDEN - protection honored
screencapture still.png:  control (  3,255,  0) protected (255,255,255) -> HIDDEN
screencapture -v frame:   control (  1,254,  0) protected (252,  0,253) -> LEAKS
SCK single-window capture of PROTECTED panel: center pixel BGRA(0,0,0,0)
```

## What this means

* `sharingType = .none` is honored by the **ScreenCaptureKit** pipeline and the legacy **snapshot** APIs.
  Current Zoom, Google Meet in Chrome, OBS's default macOS source and macOS screenshots all use these.
* It is **not** honored by the legacy **streaming** APIs (`CGDisplayStream`, `AVCaptureScreenInput`).
  These read the composited framebuffer. Any app still recording through them will capture the
  overlay. No window flag fixes this. The only defense is not having the overlay on screen, so
  the app has a panic-hide hotkey (⌃⌥H).
* Electron's `setContentProtection(true)` and Tauri's `set_content_protected(true)` set the same
  `NSWindow.sharingType = .none`, so these gaps are identical on every stack. Protection is not a
  reason to pick one stack over another.

## Not verified automatically (check these by hand before relying on them)

These need an interactive session. Run `make protection-hold`. It shows the two panels for 60 s.
Then share the whole screen in each app and see whether the **magenta** square shows up:

1. Zoom → Share Screen → Desktop (a local meeting with yourself is enough). Check the preview and the
   recording. Zoom's own "Advanced capture options" can switch to a legacy path, so try each option.
2. Google Meet in Chrome → Present → Entire screen.
3. QuickTime Player → New Screen Recording, and Cmd-Shift-5 → Record Entire Screen. The
   `screencapture -v` result suggests at least one recording path may leak, so check this one.
4. OBS: "macOS Screen Capture" (expected hidden) vs "Display Capture (deprecated)" (expected to leak).

Protection is set by the window server, and Apple has changed this behavior between releases.
**Re-run `make protection-test` after every macOS update.**
