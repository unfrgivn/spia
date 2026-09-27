#!/usr/bin/env bash
# Capture DEBUG fixture screens with scripts/screenshots.sh, or add --mac for a visible macOS window.
# Set SPIA_DERIVED_DATA and SPIA_SCREENSHOTS_DIR to override the temporary defaults.
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
screens=(garage overview references photos session settings)
appearances=(light dark)

if $mac; then
  # Its own bundle id, so window frames and saved state stay out of the owner's Spia preferences.
  xcodebuild -project "$project" -scheme "$scheme" -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
    PRODUCT_BUNDLE_IDENTIFIER="$bundle.screenshots" build >/dev/null
  app="$derived/Build/Products/Debug/Spia.app"
  screen=${SPIA_SCREEN:-session}
  appearance=${SPIA_APPEARANCE:-light}
  open -n "$app" --args \
    -ApplePersistenceIgnoreState YES -SpiaFixture demo -SpiaScreen "$screen" -SpiaAppearance "$appearance"
  pid=""
  for _ in {1..30}; do
    pid=$(pgrep -n -f "$app/Contents/MacOS/Spia" || true)
    [[ -n "$pid" ]] && break
    sleep 1
  done
  [[ -n "$pid" ]] || { echo "Spia didn't start" >&2; exit 1; }
  trap 'kill "$pid" 2>/dev/null || true' EXIT
  sleep 8
  window=$(swift - "$pid" <<'SWIFT'
import CoreGraphics
let pid = pid_t(CommandLine.arguments[1]) ?? 0
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
if let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }), let id = window[kCGWindowNumber as String] as? UInt32 { print(id) }
SWIFT
  )
  [[ -n "$window" ]] || { echo "No window for Spia (pid $pid)" >&2; exit 1; }
  screencapture -l "$window" -o "$root/mac-$screen-$appearance.png"
  echo "$root/mac-$screen-$appearance.png"
  exit 0
fi

xcodebuild -project "$project" -scheme "$scheme" -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build >/dev/null
app="$derived/Build/Products/Debug-iphonesimulator/Spia.app"

find_udid() {
  local name=$1
  xcrun simctl list devices available | grep -m1 "${name} (" | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/'
}

iphone_name=${SPIA_IPHONE_NAME:-"iPhone 17 Pro"}
ipad_name=${SPIA_IPAD_NAME:-"iPad Pro 13-inch (M5)"}
devices=("$iphone_name" "$ipad_name")
for name in "${devices[@]}"; do
  udid=$(find_udid "$name")
  [[ -n "$udid" ]] || { echo "Simulator not found: $name" >&2; exit 1; }
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
  xcrun simctl install "$udid" "$app"
  for screen in "${screens[@]}"; do
    for appearance in "${appearances[@]}"; do
      xcrun simctl launch "$udid" "$bundle" -SpiaFixture demo -SpiaScreen "$screen" -SpiaAppearance "$appearance" >/dev/null
      sleep 8
      output="$root/${name// /_}-$screen-$appearance.png"
      xcrun simctl io "$udid" screenshot "$output"
      xcrun simctl terminate "$udid" "$bundle"
    done
  done
done
echo "$root"
