#!/usr/bin/env bash
#
# Turn the rendered player ship into launcher icons.
#
#   android/make-icon.sh
#
# Regenerating is only needed if the sprite or the theme palette changes; the PNGs are
# tracked, so an ordinary build does not need SBCL or ImageMagick.
#
# The ship is 36x24 -- nine cells by four, at 4x6 pixels each -- so it is wide, short, and
# tiny. Two things follow.
#
# It is scaled by whole numbers only, with -filter point. Pixel art enlarged by 3.7x with
# any interpolating filter turns to mush, and even nearest-neighbour at a fractional
# factor gives some rows two pixels and others three, which reads as a wobble.
#
# And it is padded onto a square rather than stretched to one: 36x24 pulled to 1:1 would
# make the ship a third taller than the game draws it. So each density gets the largest
# integer scale that leaves a margin.
#
# The padding is black -- the same black the game clears its screen to -- so the icon is a
# crop of the game rather than a picture of it.
#
# Transparent padding was tried and looked worse: launchers composite a legacy icon onto
# their own background, so the ship ended up floating on whatever the user's wallpaper or
# theme happened to be, at odds with a game that is black by definition.
#
# Note it would have to be done this way round regardless -- filling the -extent margin,
# not keying black out of the finished image. The sprite has black cells inside its own
# bounding box, and keying would punch holes through the hull.

set -euo pipefail

here="${BASH_SOURCE[0]%/*}"
[[ "$here" == "${BASH_SOURCE[0]}" ]] && here="."
cd "$here"

command -v magick >/dev/null || { echo "Need ImageMagick." >&2; exit 1; }
command -v sbcl   >/dev/null || { echo "Need SBCL to render the sprite." >&2; exit 1; }

echo "== rendering the ship =="
sbcl --script make-icon.lisp

SRC="out/icon.ppm"
[[ -f "$SRC" ]] || { echo "make-icon.lisp produced no $SRC" >&2; exit 1; }

# density  canvas  scale   -> ship is 36*scale x 24*scale, centred
#
# hdpi is the awkward one: 2x makes the ship exactly as wide as the canvas, and 1x leaves
# it swimming in black. Full-bleed width wins, and hdpi is a density almost nothing has
# any more.
ICONS="
mdpi     48  1
hdpi     72  2
xhdpi    96  2
xxhdpi  144  3
xxxhdpi 192  4
"

echo "== building icons =="
while read -r density canvas scale; do
  [[ -z "$density" ]] && continue
  dir="res/mipmap-$density"
  mkdir -p "$dir"
  magick "$SRC" \
    -crop 36x24+0+0 +repage \
    -filter point -resize "$((36 * scale))x$((24 * scale))" \
    -background black -gravity center -extent "${canvas}x${canvas}" \
    "$dir/ic_launcher.png"
  printf '   %-8s %3dx%-3d  ship %dx%d\n' \
    "$density" "$canvas" "$canvas" "$((36 * scale))" "$((24 * scale))"
done <<< "$ICONS"

# A big one to look at, not shipped.
magick "$SRC" -crop 36x24+0+0 +repage -filter point -resize 1440x960 \
  -background black -gravity center -extent 1440x1440 out/icon-preview.png

echo
echo "   wrote res/mipmap-*/ic_launcher.png"
echo "   preview: android/out/icon-preview.png"
