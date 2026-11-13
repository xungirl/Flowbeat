#!/usr/bin/env bash
# App Store watch screenshots from the Release (AI-off) build, in English and Simplified Chinese.
#
#   scripts/appstore_screenshots.sh            # all watch simulators listed in MODELS
#
# Uses demo mode (simulated sensors, simulator-only launch args), so the numbers on screen are
# not real measurements. History and widget shots use a fixed sample week (-demoHistory). The clock in the corner is the real time: `simctl status_bar override`
# has no effect on watchOS simulators (tried on watchOS 11.4). Output: docs/appstore/screenshots/<model>/<lang>-<n>-<name>.png
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE=com.xungirl.flowbeat.watchkitapp
OUT=docs/appstore/screenshots
DD=build/dd
MODELS=("Apple Watch Ultra 2 (49mm)" "Apple Watch Series 10 (46mm)")

xcodegen generate >/dev/null
xcodebuild build -project Flowbeat.xcodeproj -scheme Flowbeat -configuration Release \
  -destination "platform=watchOS Simulator,name=${MODELS[0]}" -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO -quiet
APP="$DD/Build/Products/Release-watchsimulator/Flowbeat.app"

udid_for() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for rt, devs in json.load(sys.stdin)["devices"].items():
    for d in devs:
        if d["name"] == name:
            print(d["udid"]); sys.exit()
sys.exit("no simulator named " + name)' "$1"
}

wait_s() { python3 -c "import time,sys; time.sleep(float(sys.argv[1]))" "$1"; }

for model in "${MODELS[@]}"; do
  udid=$(udid_for "$model")
  dir="$OUT/$(echo "$model" | tr -cd '[:alnum:]' )"
  mkdir -p "$dir"
  # fresh boot: a system permission alert left over from an earlier run survives an uninstall
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl uninstall "$udid" "$BUNDLE" 2>/dev/null || true
  xcrun simctl install "$udid" "$APP"

  for lang in en zh-Hans; do
    L=(-AppleLanguages "($lang)" -AppleLocale "$([ "$lang" = en ] && echo en_US || echo zh_CN)")
    shot() {  # shot <file> <seconds> <args...>
      local file=$1 secs=$2; shift 2
      xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
      xcrun simctl launch "$udid" "$BUNDLE" "${L[@]}" "$@" >/dev/null
      wait_s "$secs"
      xcrun simctl io "$udid" screenshot "$dir/$lang-$file.png" >/dev/null 2>&1
    }
    shot 1-focus     32 -demo                       # 10 s calibration + ~22 s into the "focused" phase
    shot 2-summary   80 -demo -demoStopAfter 70     # session ends at 70 s, summary screen
    shot 3-onboarding 4 -onboardingPage 0
    shot 4-disclaimer 4 -onboardingPage 1
    shot 5-ondevice   4 -onboardingPage 2
    # v1 additions. Pomodoro: pretend the timer started 25:00 − 20 s ago, so the break begins 20 s in
    shot 6-pomodoro  30 -demo -demoPomodoro -demoPomodoroOffset 1480
    # summary scrolled to the goal card; -goal.sessionMinutes sets the UserDefaults key via the argument domain
    shot 7-goal     108 -demo -demoStopAfter 100 -goal.sessionMinutes 1 -scrollToGoal
    # history from a fixed sample week (-demoHistory, in memory only), top and bottom
    shot 8-history    5 -demoHistory -openHistory
    shot 9-history-best 6 -demoHistory -openHistory -scrollBottom
    # widget views rendered inside the app (not a real watch face)
    shot 10-widgets   5 -demoHistory -widgetGallery
  done
done

for f in "$OUT"/*/*.png; do
  printf '%s  %s\n' "$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/{printf "%s ", $2}')" "$f"
done
