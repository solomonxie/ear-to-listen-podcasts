#!/bin/sh
# Resizes iPhone screenshots into the App Store Connect slots, alpha stripped
# (App Store Connect rejects PNGs with an alpha channel).
#   6.9" -> 1320x2868   (the required slot)
#   6.5" -> 1284x2778   (optional; older listings still show it)
# Any portrait iPhone shot scales with no visible distortion — the two slots and every
# modern iPhone are within a percent of the same aspect ratio.
#
# Files are numbered in filename order, which is the order they'll be uploaded in, so
# name the inputs 1-home.png, 2-album.png, ...
#
# Usage: scripts/store-screenshots.sh <dir-of-shots> [out-dir]
set -e
IN=${1:?usage: $0 <input-dir> [out-dir]}
OUT=${2:-docs/release/screenshots}
mkdir -p "$OUT/6.9" "$OUT/6.5"

found=0
for f in "$IN"/*.png "$IN"/*.PNG "$IN"/*.jpg "$IN"/*.jpeg "$IN"/*.JPG "$IN"/*.HEIC; do
  [ -f "$f" ] || continue
  name=$(basename "${f%.*}")
  sips -s format jpeg -s formatOptions 95 -z 2868 1320 "$f" --out "$OUT/6.9/$name.jpg" >/dev/null
  sips -s format jpeg -s formatOptions 95 -z 2778 1284 "$f" --out "$OUT/6.5/$name.jpg" >/dev/null
  echo "$name"
  found=$((found + 1))
done

[ "$found" -gt 0 ] || { echo "no images in $IN" >&2; exit 1; }
echo "$found shot(s) -> $OUT/6.9 (required) and $OUT/6.5"
