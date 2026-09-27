#!/usr/bin/env bash
# Renders the app artwork into macOS and iOS app icons. Needs rsvg-convert.
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

ios_name="icon_ios_1024x1024.png"
rsvg-convert -w 1024 -h 1024 design/icon/app-icon-ios.svg -o "$set_dir/$ios_name"
sips -s format jpeg -s formatOptions best "$set_dir/$ios_name" --out "$set_dir/icon_ios_tmp.jpg" >/dev/null
sips -s format png "$set_dir/icon_ios_tmp.jpg" --out "$set_dir/$ios_name" >/dev/null
rm "$set_dir/icon_ios_tmp.jpg"
images+=("    { \"filename\" : \"$ios_name\", \"idiom\" : \"universal\", \"platform\" : \"ios\", \"size\" : \"1024x1024\" }")

# The welcome screen's mark, at 112 pt.
mark_dir=App/Spia/Assets.xcassets/AppMark.imageset
for scale in 1 2 3; do
  pixels=$((112 * scale))
  rsvg-convert -w "$pixels" -h "$pixels" "$source" -o "$mark_dir/appmark_${pixels}.png"
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
