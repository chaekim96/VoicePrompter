#!/bin/bash
# End-to-end check of the real Apple Speech pipeline without a microphone:
# synthesizes a talk (with an ad-lib and a skipped sentence) using `say`, streams it into the app in
# real time, and reports speech→partial latency, partial→highlight time and final tracking position.
# The first run shows the macOS Speech Recognition permission prompt. Click Allow.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/voiceprompter-latency"; mkdir -p "$OUT"
cat > "$OUT/script.txt" <<'TXT'
Good morning everyone, and thank you for joining us today. We are here to talk about the future of our product and where we want to take it over the next twelve months. First, let me share some numbers. Revenue grew 40% last year, and customer retention reached an all-time high. Thank you all for making that happen. Second, we are investing heavily in reliability, because our customers depend on us every single day. Third, we will expand into two new markets in Europe and Asia. Finally, I want to say thank you all for making that happen once again, and I am excited to answer your questions.
TXT
cat > "$OUT/spoken.txt" <<'TXT'
Good morning everyone, and thank you for joining us today. We are here to talk about the future of our product and where we want to take it over the next twelve months. Okay so, before I forget, the coffee is in the back. First, let me share some numbers. Revenue grew 40% last year, and customer retention reached an all-time high. Second, we are investing heavily in reliability, because our customers depend on us every single day. Third, we will expand into two new markets in Europe and Asia. Finally, I want to say thank you all for making that happen once again, and I am excited to answer your questions.
TXT
say -r 165 -f "$OUT/spoken.txt" -o "$OUT/spoken.aiff"
[ -d build/VoicePrompter.app ] || ./scripts/build.sh
rm -f "$OUT/log.txt"
# `open` (not the raw binary) so macOS treats the app as the permission owner.
open -W -n --stdout "$OUT/log.txt" --stderr "$OUT/log.txt" build/VoicePrompter.app --args \
  --engine apple-speech --audio-file "$OUT/spoken.aiff" --script "$OUT/script.txt" --autostart --quit-after 50 --verbose
echo "Log: $OUT/log.txt"
/usr/bin/python3 - "$OUT/log.txt" <<'PY'
import re, sys, statistics
lines = [l for l in open(sys.argv[1]) if l.startswith("[track]")]
def values(pattern):
    found = [re.search(pattern, l) for l in lines]
    return [float(m.group(1)) for m in found if m]
onset = values(r"onset->partial=([\d.]+)ms")
pipe = values(r"pipeline=([\d.]+)ms")
pos = re.search(r"pos=(\S+)", lines[-1]).group(1) if lines else "?"
if onset: print("speech onset -> first partial: median %.0f ms, max %.0f ms (%d phrases)" % (statistics.median(onset), max(onset), len(onset)))
if pipe: print("partial -> highlight applied:  median %.2f ms, max %.2f ms" % (statistics.median(pipe), max(pipe)))
print("final position: %s tokens (last token index = total - 1)" % pos)
engine = [l.strip() for l in open(sys.argv[1]) if l.startswith("[engine]")]
if engine: print("engine events:\n  " + "\n  ".join(engine[-8:]))
if not lines: print("No tracking output. Check the log (permission denied?).")
PY
