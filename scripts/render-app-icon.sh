#!/usr/bin/env bash
# Renders design/icon/app-icon.svg into every macOS app icon size. Needs rsvg-convert
# (brew install librsvg). Run after changing the SVG, then commit the PNGs.
set -euo pipefail
cd "$(dirname "$0")/.."
source=design/icon/app-icon.svg
set_dir=App/Spia/Assets.xcassets/AppIcon.appiconset
command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found: brew install librsvg" >&2; exit 1; }

images=()
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((size * scale))
    suffix=""
    if [ "$scale" = 2 ]; then suffix="@2x"; fi
    name="icon_${size}x${size}${suffix}.png"
    rsvg-convert -w "$pixels" -h "$pixels" "$source" -o "$set_dir/$name"
    images+=("    { \"filename\" : \"$name\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${size}x${size}\" }")
  done
done

{
  echo '{'
  echo '  "images" : ['
  (IFS=$'\n'; echo "${images[*]}") | sed '$!s/$/,/'
  echo '  ],'
  echo '  "info" : { "author" : "xcode", "version" : 1 }'
  echo '}'
} > "$set_dir/Contents.json"
echo "Rendered $source into $set_dir"
