#!/usr/bin/env bash
# Render every *.svg in this folder to a 2x PNG with headless Chrome.
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for f in "${@:-*.svg}"; do
  for svg in $f; do
    w=$(grep -o 'width="[0-9]*"' "$svg" | head -1 | tr -dc 0-9)
    h=$(grep -o 'height="[0-9]*"' "$svg" | head -1 | tr -dc 0-9)
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
      --window-size="$w,$h" --virtual-time-budget=5000 --screenshot="$PWD/${svg%.svg}.png" "file://$PWD/$svg" 2>/dev/null
    echo "rendered ${svg%.svg}.png"
  done
done
