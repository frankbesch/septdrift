#!/bin/sh
# Run on a second Mac. Builds the CLI, runs every case in cases/ live (one unrecorded
# warm-up call first), verifies the recording, and leaves ONE file to send back:
# ~/Desktop/septdrift-recording-<host>-<stamp>.jsonl
# Plain sh: runs the same under `bash`, `zsh`, or `sh`.
set -e
cd "$(dirname "$0")/.."
echo "== macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) · $(sysctl -n machdep.cpu.brand_string)"
# A failed build must stop here; a stale binary from an earlier build must never run.
LOG=$(mktemp -t septdrift-build)
if ! swift build -c release >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -40
  echo "build failed; send back the lines above"
  exit 1
fi
grep -E "Build complete|warning: unre" "$LOG" || tail -3 "$LOG"
B=.build/release/septdrift
[ -x "$B" ] || { echo "build produced no binary; send back the lines above"; exit 1; }
# SEPTDRIFT_OUT_DIR overrides the Desktop.
OUT="${SEPTDRIFT_OUT_DIR:-$HOME/Desktop}/septdrift-recording-$(hostname -s)-$(date +%Y%m%d-%H%M).jsonl"
# Record under a .partial name and rename only after verify, so a file that is still being
# written (or a run that died) can never be picked up as the result: a run once came
# back with 16 of 62 results and no end trailer.
PART="$OUT.partial"
if ! "$B" run cases/ --backend system --out "$PART"; then
  rc=$?
  [ "$rc" -eq 2 ] && echo "model: UNAVAILABLE (Apple Intelligence off, still downloading, or unsupported region)"
  echo "run stopped early (exit $rc); the partial file stays at $PART"
  exit "$rc"
fi
"$B" verify "$PART" || { echo "verify failed; the file stays at $PART"; exit 1; }
mv "$PART" "$OUT"
echo "== done. Send this file back: $OUT"
