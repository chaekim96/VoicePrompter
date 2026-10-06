# VoicePrompter

A macOS teleprompter overlay that listens to you read and scrolls the script to match your voice.
It floats above every app, including full-screen ones, and is hidden from screen sharing and
recordings that use ScreenCaptureKit. That covers Zoom, Google Meet, OBS, QuickTime and screenshots.
See [ProtectionTest/RESULTS.md](ProtectionTest/RESULTS.md) for what was tested and the known gaps.

## Requirements

- macOS 14 or later (tested on macOS 15.7.4, Apple Silicon)
- Xcode 15+ command-line tools (`xcode-select --install`), Swift 5.10+
- For on-device recognition: turn on Dictation once (System Settings → Keyboard → Dictation) so the
  speech model for your language gets downloaded.

## Build and run

```bash
make install      # builds, copies to /Applications, and opens it (then use Spotlight: "VoicePrompter")
make run          # builds build/VoicePrompter.app and opens it from the repo
```

Other targets:

```bash
make test             # unit tests for tokenizing and alignment
make simulate         # run with the simulated reader (no microphone)
make protection-test  # re-check screen-capture protection on this macOS version
make protection-hold  # show test squares for 60 s to check Zoom/Meet/QuickTime by hand
./scripts/latency-test.sh   # real Apple Speech pipeline fed with `say` audio; prints latency stats
```

After `make install` you can open it like any app: Spotlight, Launchpad, the Dock or the menu bar icon.
**General → Open at login** starts it automatically.

### Signing and permissions

The build script signs the app **ad-hoc** by default, so macOS may ask for microphone and speech
permission again after each rebuild. To keep the permissions, sign with a stable identity:

```bash
SIGN_ID="Apple Development: you@example.com (TEAMID)" make build
```

Launch the app from Finder or with `open`, not by running the binary inside the bundle from a terminal.
If you do that, macOS attributes the permission request to the terminal. If the terminal has no speech
usage description, macOS kills the app.

| Permission | Why | If denied |
|---|---|---|
| Microphone | hear you | The overlay shows a banner with an **Open Settings** button |
| Speech Recognition | transcription | Same |
| Accessibility | **not needed.** Hotkeys use Carbon `RegisterEventHotKey`, which works without it | – |
| Screen Recording | **not needed** | – |

## Using it

Everything lives in one **VoicePrompter window** with a sidebar. Open it by clicking the Dock icon,
pressing **⌃⌥O** from any app, choosing **Open VoicePrompter…** from the menu bar icon, or clicking ⋯ on the prompter.

| Sidebar | What's there |
|---|---|
| Prompter | Start/pause, status, progress through the script, show/hide, click-through, move the prompter back on screen, permission status |
| Script | Paste or edit your script, import `.txt`/`.md`, word count |
| Appearance | Font size, line height, colors, dimming of read text, background and overall opacity |
| Voice Tracking | Engine, language, on-device only, permissions, latency readout |
| Privacy | Hide from screen capture, plus what is and isn't covered |
| Shortcuts | All hotkeys and mouse gestures |
| General | Dock icon, open window at launch, open at login, quit |

The prompter itself stays clean. Hovering over it shows close (hides it; ⌃⌥H brings it back) and minimize
(to the Dock) at the top-left, and a small bar at the top-right: play/pause, back to start, hide, and ⋯ (open the window). Otherwise only a status dot shows (green = listening, gray = paused, orange = lost, red = error).

| Hotkey | Action |
|---|---|
| ⌃⌥Space | Start / pause tracking (pausing releases the mic) |
| ⌃⌥O | Open the VoicePrompter window |
| ⌃⌥H | Show / hide the prompter instantly |
| ⌃⌥C | Click-through on/off (clicks pass through to apps underneath) |
| ⌃⌥R | Back to the start |
| ⌃⌥↑ / ⌃⌥↓ | Move the position one line up/down |

On the prompter, drag the text to move it, drag an edge to resize, scroll to look ahead, and
**double-click a word** to set your position there.

Settings persist in `UserDefaults`. The script and position are kept in `~/Library/Application Support/VoicePrompter/`.

## Architecture

```
Sources/
  PrompterCore/            (pure Swift, unit-tested, no UI)
    Normalizer.swift       text → comparable tokens ("40%" → forty percent, "$5", hyphens, diacritics)
    Script.swift           script tokens mapped back to highlight ranges; Markdown import
    WordSimilarity.swift   fuzzy word match: exact, homophones, inflections, edit distance
    Aligner.swift          position tracking (see below)
    SpeechEngine.swift     pluggable recognizer protocol + RecognitionUpdate
    SimulatedEngine.swift  test engine (reads the script with errors)
  VoicePrompter/           (AppKit + SwiftUI app)
    AppleSpeechEngine.swift  SFSpeechRecognizer + AVAudioEngine, session rotation, onset latency meter
    Engines.swift            engine registry, launch flags, permission URLs
    AppModel.swift           state + pipeline: engine → aligner → overlay
    Overlay.swift            NSPanel (non-activating, .screenSaver level, all Spaces, sharingType=.none)
    PrompterTextView.swift   TextKit rendering, incremental highlighting, upper-third scrolling
    Hotkeys.swift            Carbon global hotkeys
    Windows.swift            main window: sidebar with Prompter, Script, Appearance, Voice, Privacy, Shortcuts, General
ProtectionTest/            capture-API test harness + results
```

**Pipeline.** Mic buffers go to `SFSpeechAudioBufferRecognitionRequest` (on-device, partial results).
Each partial goes to the aligner on the main thread. If the position moved, only the changed character
range is recolored, and the scroll animates if the line changed. The recognizer session restarts about
every 50 s, during a pause when possible, so hypotheses stay short and fast. The aligner keeps the tail
of the previous session so context carries across the restart.

**Alignment.** Each update runs a Smith-Waterman local alignment of the last 8 spoken words against the
script, from 30 words behind the cursor to 60 words ahead. Fuzzy word similarity makes misrecognitions
cheap. Spoken words missing from the script (ad-libs) and script words you skip are cheap gaps. A
distance penalty (backward costs 5× more than forward) resolves repeated phrases toward the nearest
occurrence. Guards against jumping on weak evidence:

- Moves of up to 12 words forward need 2 matched words, or 1 when the move is at most 2 words and ends on the word just spoken.
- Longer forward moves need 3 matched words, plus a second update that continues the same passage with
  a *newly spoken* word.
- Backward moves of 1–2 words are ignored (they're partial-result revisions). Bigger ones need 4 matches plus confirmation.
- Jumps outside the window are only considered after 3 straight failed updates. They need at least 5 of 8
  words matched (4 exact), a clear margin over any other region of the script, and confirmation.

An update takes about 0.3 ms on an 8,800-word script (release build).

### Adding a speech engine

Implement `SpeechEngine` (PrompterCore/SpeechEngine.swift): `prepare()` for permissions,
`start(context:)`, `stop()`, and call `onUpdate` with the *cumulative* text of the current session.
Bump `segment` whenever your session restarts. Then add an `EngineDescriptor` in `Engines.swift`.
A whisper.cpp or Vosk engine would wrap their streaming APIs the same way.

## Latency

End-to-end = recognizer latency + ~0.3 ms alignment + ≤1 display frame. The recognizer dominates.
Turn on **Settings → Show latency stats** to see live numbers on the overlay:
"speech→partial" is measured from the voice-activity onset to the first new partial result.
`./scripts/latency-test.sh` measures the same thing with synthesized speech.

## Known limitations

- Capture protection doesn't cover legacy `CGDisplayStream`/`AVCaptureScreenInput` recorders or
  `screencapture -v`. Use ⌃⌥H if you're unsure. Re-run `make protection-test` after macOS updates.
- The overlay window still appears by name in SCK "share a window" pickers. Its content captures as blank.
- Apple's recognizer revises partial results. Tiny backward revisions are ignored on purpose, so after
  a misread the highlight may stay one word ahead until you continue.
- Only one script at a time. Hotkeys can't be changed yet (Carbon registration makes this easy to add).
- With the Dock icon on, check that the prompter still floats over full-screen apps on your setup.
  If it doesn't, turn off **General → Show in Dock**; the menu bar icon and ⌃⌥O still work.
