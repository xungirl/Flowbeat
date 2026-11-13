#!/usr/bin/env bash
# Proves the v1 promise "no network, no backend" at the binary level.
#
#   scripts/verify_release_offline.sh [derived-data-dir]
#
# 1. Builds the watch app (scheme Flowbeat) in Debug and Release for the watchOS simulator, unsigned.
# 2. Release: FLOWBEAT_AI must not be an active compilation condition, and the app binary must not
#    contain any backend marker (URL, port, endpoints, token header, HTTP client type, label store).
# 3. Debug: the same markers MUST be present. Otherwise the scan proves nothing (e.g. wrong binary).
# Exits non-zero on any failure. CI runs it on every push.
set -euo pipefail
cd "$(dirname "$0")/.."
DD=${1:-build/dd}
DEST=${DEST:-"generic/platform=watchOS Simulator"}

# Every marker must be present in a Debug *simulator* build, so the scan is known to work.
# (Not used: "YOUR-MAC.local" exists only in device builds; the token header string is
#  not emitted while AIConfig.token is nil.)
MARKERS=(
  "localhost:8765"      # AIConfig.baseURL (simulator)
  "/v1/judge"           # endpoints
  "/v1/review"
  "HTTPJudgeTransport"  # the HTTP client type
  "AIConfig"            # backend config type
  "labeledExamples"     # few-shot label store key (UserDefaults)
)

[ -d Flowbeat.xcodeproj ] || xcodegen generate >/dev/null

fail=0
for config in Debug Release; do
  xcodebuild build -project Flowbeat.xcodeproj -scheme Flowbeat -configuration "$config" \
    -destination "$DEST" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO -quiet
  conds=$(xcodebuild -project Flowbeat.xcodeproj -target Flowbeat -configuration "$config" -showBuildSettings 2>/dev/null \
          | awk -F' = ' '/ SWIFT_ACTIVE_COMPILATION_CONDITIONS /{print $2}')
  app="$DD/Build/Products/$config-watchsimulator/Flowbeat.app"
  # Debug builds put the code in Flowbeat.debug.dylib; scan every Mach-O in the bundle
  # (macOS `strings` must be given files, not stdin, to scan every Mach-O section)
  dump=$(mktemp)
  find "$app" -type f \( -name Flowbeat -o -name '*.dylib' \) -exec strings -a {} \; > "$dump"
  found=()
  for m in "${MARKERS[@]}"; do
    if grep -qF -- "$m" "$dump"; then found+=("$m"); fi
  done
  rm -f "$dump"
  echo "[$config] conditions: ${conds:-<none>}"
  echo "[$config] markers found: ${#found[@]}/${#MARKERS[@]} ${found[*]:-}"
  if [ "$config" = Release ]; then
    if [[ " $conds " == *" FLOWBEAT_AI "* ]]; then echo "FAIL: Release compiles FLOWBEAT_AI"; fail=1; fi
    if [ ${#found[@]} -ne 0 ]; then echo "FAIL: Release binary contains backend code"; fail=1; fi
  else
    if [[ " $conds " != *" FLOWBEAT_AI "* ]]; then echo "FAIL: Debug lost FLOWBEAT_AI"; fail=1; fi
    if [ ${#found[@]} -ne ${#MARKERS[@]} ]; then echo "FAIL: Debug is missing markers, so the scan is not trustworthy"; fail=1; fi
  fi
done

if [ $fail -eq 0 ]; then echo "OK: Release (AI off) contains no backend/network code; Debug (AI on) does."; fi
exit $fail
