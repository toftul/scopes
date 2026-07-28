#!/usr/bin/env bash
# Drag a screen region, then immediately open a live vectorscope on it.
#
# Usage:
#   ./pick-and-scope.sh [screen_index] [scale]
#
#   screen_index  avfoundation device index for "Capture screen N" (default: auto-detect)
#   scale         Retina scale factor for the picker (default: 2; use 1 for non-Retina)
#
# Requires: ffmpeg, ffplay (brew install ffmpeg), python3 with tkinter (ships with macOS)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCALE="${2:-2}"

# --- 1. Resolve the avfoundation screen-capture device index ---
if [ -n "${1:-}" ]; then
  SCREEN_IDX="$1"
else
  SCREEN_IDX=$(
    ffmpeg -f avfoundation -list_devices true -i "" 2>&1 \
      | grep "Capture screen" \
      | head -n1 \
      | sed -E 's/.*\[([0-9]+)\].*/\1/'
  )
  if [ -z "$SCREEN_IDX" ]; then
    echo "Could not auto-detect a 'Capture screen' device. Pass the index manually:" >&2
    ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A5 "video devices" >&2
    exit 1
  fi
fi

echo "Using avfoundation screen index: $SCREEN_IDX"
echo "Drag a rectangle over the region you want to scope (Esc to cancel)..."

# --- 2. Run the picker, capture the crop=W:H:X:Y string ---
CROP=$(python3 "$SCRIPT_DIR/pick_region.py" "$SCALE") || {
  echo "Selection cancelled." >&2
  exit 1
}

echo "Selected: $CROP"

# --- 3. Launch the live vectorscope on that region ---
ffmpeg -f avfoundation -framerate 30 -i "${SCREEN_IDX}:none" \
  -vf "format=yuv420p,${CROP},vectorscope=m=color3:g=green" \
  -f nut - 2>/dev/null | ffplay -loglevel quiet -
