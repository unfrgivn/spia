#!/usr/bin/env bash
# Capture DEBUG fixture screens on the iPhone and iPad simulators, or with --mac as visible Mac
# windows (each shows briefly on the desktop). Environment: SPIA_SCREENS, SPIA_APPEARANCES,
# SPIA_DEVICES ("|"-separated simulator names), SPIA_EXTRA_ARGS, SPIA_SUFFIX, SPIA_DERIVED_DATA,
# SPIA_SCREENSHOTS_DIR, and SPIA_WAIT (seconds before each shot, 8 by default; the fixture looks up
# the demo car's reference photos online, which can take longer).
set -euo pipefail

cd "$(dirname "$0")/.."
mac=false
if [[ ${1:-} == "--mac" ]]; then mac=true; shift; fi
timestamp=$(date +%Y%m%d-%H%M%S)
root=${SPIA_SCREENSHOTS_DIR:-"${TMPDIR:-/tmp}/spia-screenshots/$timestamp"}
derived=${SPIA_DERIVED_DATA:-"${TMPDIR:-/tmp}/spia-screenshots/DerivedData"}
mkdir -p "$root"

project=App/SpiaApp.xcodeproj
scheme=Spia
bundle=com.unfrgivn.spia
read -ra screens <<< "${SPIA_SCREENS:-garage overview references photos session settings}"
read -ra appearances <<< "${SPIA_APPEARANCES:-light dark}"
IFS='|' read -ra devices <<< "${SPIA_DEVICES:-iPhone 17 Pro|iPad Pro 13-inch (M5)}"
read -ra extra <<< "${SPIA_EXTRA_ARGS:-}"
suffix=${SPIA_SUFFIX:+-$SPIA_SUFFIX}
wait=${SPIA_WAIT:-8}

# The launch arguments for one shot. Bash 3.2 treats an empty array as unset under `set -u`.
fixture_args() {
  args=(-SpiaFixture demo -SpiaScreen "$1" -SpiaAppearance "$2")
  if ((${#extra[@]})); then args+=("${extra[@]}"); fi
}

capture_mac() {
  # Its own bundle id, so window frames and saved state stay out of the owner's Spia preferences.
  xcodebuild -project "$project" -scheme "$scheme" -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
    PRODUCT_BUNDLE_IDENTIFIER="$bundle.screenshots" build >/dev/null
  local app="$derived/Build/Products/Debug/Spia.app"
  for screen in "${screens[@]}"; do
    for appearance in "${appearances[@]}"; do
      fixture_args "$screen" "$appearance"
      open -n "$app" --args -ApplePersistenceIgnoreState YES "${args[@]}"
      # Not local: the EXIT trap reads it if the script stops before the kill below.
      pid=""
      for _ in {1..30}; do
        pid=$(pgrep -n -f "$app/Contents/MacOS/Spia" || true)
        [[ -n "$pid" ]] && break
        sleep 1
      done
      [[ -n "$pid" ]] || { echo "Spia didn't start" >&2; exit 1; }
      trap 'kill "$pid" 2>/dev/null || true' EXIT
      sleep "$wait"
      local window
      # The app's biggest window, on screen or not: when another Space is showing, the new
      # window opens off screen, and screencapture can still take it by its ID.
      window=$(swift - "$pid" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = pid_t(CommandLine.arguments[1]) ?? 0
let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
func area(_ window: [String: Any]) -> Double {
  let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
  return ((bounds["Width"] as? Double) ?? 0) * ((bounds["Height"] as? Double) ?? 0)
}
let own = windows.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
if let window = own.max(by: { area($0) < area($1) }), let id = window[kCGWindowNumber as String] as? UInt32 { print(id) }
SWIFT
      )
      [[ -n "$window" ]] || { echo "No window for Spia (pid $pid)" >&2; exit 1; }
      screencapture -l "$window" -o "$root/mac-$screen-$appearance$suffix.png"
      kill "$pid"
      trap - EXIT
      sleep 1
    done
  done
}

capture_simulators() {
  xcodebuild -project "$project" -scheme "$scheme" -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO build >/dev/null
  local app="$derived/Build/Products/Debug-iphonesimulator/Spia.app"
  for name in "${devices[@]}"; do
    local udid
    udid=$(xcrun simctl list devices available | grep -m1 "$name (" \
      | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/' || true)
    [[ -n "$udid" ]] || { echo "Simulator not found: $name" >&2; exit 1; }
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged \
      --batteryLevel 100 --cellularBars 4 --wifiBars 3
    xcrun simctl install "$udid" "$app"
    for screen in "${screens[@]}"; do
      for appearance in "${appearances[@]}"; do
        fixture_args "$screen" "$appearance"
        xcrun simctl launch "$udid" "$bundle" "${args[@]}" >/dev/null
        sleep "$wait"
        xcrun simctl io "$udid" screenshot "$root/${name// /_}-$screen-$appearance$suffix.png" \
          >/dev/null 2>&1
        xcrun simctl terminate "$udid" "$bundle"
      done
    done
  done
}

if $mac; then capture_mac; else capture_simulators; fi
echo "$root"
