#!/usr/bin/env bash
# Build the Android launcher icons from the single master under design/.
#
#   scripts/make_icons.sh [master.png] [output-res-dir]
#
# Defaults:
#   master  design/imagyn-icon-1024.png
#   output  platform/android/app/src/main/res
#
# The output directory is an overlay source, not a real Flutter resource tree:
# scripts/scaffold_platforms.py copies it over the generated android/ folder.
# Re-run this script whenever the master changes, then commit the result.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=${1:-"$ROOT/design/imagyn-icon-1024.png"}
OUT=${2:-"$ROOT/platform/android/app/src/main/res"}
MAGICK=${MAGICK:-$(command -v magick || command -v convert || true)}

[ -n "$MAGICK" ] || { echo "ImageMagick is required (magick or convert)" >&2; exit 1; }
[ -f "$SRC" ] || { echo "master not found: $SRC" >&2; exit 1; }

W=$("$MAGICK" "$SRC" -format '%w' info:)
H=$("$MAGICK" "$SRC" -format '%h' info:)
[ "$W" = "$H" ] || { echo "the master must be square, got ${W}x${H}" >&2; exit 1; }

# Sampled from the artwork so the shape reproduces its gradient instead of
# hard-coding colours that drift when the icon is redrawn.
GRADIENT_TOP=$("$MAGICK" "$SRC" -format '%[hex:p{1,1}]' info:)
GRADIENT_BOTTOM=$("$MAGICK" "$SRC" -format "%[hex:p{1,$((H - 2))}]" info:)

# An adaptive icon layer is 108dp, but only the central 66dp circle is
# guaranteed to survive whatever mask the launcher applies. Work in radii, not
# diameters: the mark's bounding circle may reach at most 33/108 of the layer.
# 33/108 is the radius a launcher guarantees to show; stay a hair inside it so
# the anti-aliased edge of the mark does not poke past the mask.
SAFE_RADIUS_RATIO=$(awk 'BEGIN { printf "%.6f", 33 / 108 * 0.98 }')
# Legacy icons carry their own rounded corners (the adaptive ones are masked by
# the launcher, so they must stay square).
CORNER_RATIO=0.22

# The mark sits off-centre in the master by design (the sparkles lean
# up-and-right), so the radius that has to clear the safe circle is the distance
# from the *canvas centre* to the farthest corner of the bounding box — not the
# box's own half-diagonal, which would ignore the offset and let the star tips
# escape. The whole canvas is then scaled, which keeps the composition the
# artwork was drawn with.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The artwork is a flat off-white mark on a violet gradient, so selecting by
# luminance separates them cleanly: the background sits at 29-47% luminance, the
# mark at ~96%. The ramp keeps the anti-aliased edges soft.
"$MAGICK" "$SRC" \( +clone -colorspace gray -level 55%,85% \) \
  -alpha off -compose CopyOpacity -composite "$WORK/mark.png"

# Measured from the mark's own alpha rather than a luminance threshold on the
# master: the soft edge keeps visible pixels a few pixels further out than a hard
# cut does, and sizing against the smaller number lets them escape the circle.
BBOX=$("$MAGICK" "$WORK/mark.png" -format '%@' info:)
read -r BW BH BX BY _ <<<"$(echo "$BBOX" | tr 'x+' ' ')"
[ -n "${BW:-}" ] || { echo "could not find the light mark in $SRC" >&2; exit 1; }

# The mark sits off-centre by design (the sparkles lean up-and-right), so the
# radius that has to clear the safe circle is the distance from the *canvas
# centre* to the farthest corner of that box — not the box's own half-diagonal,
# which would ignore the offset. The whole canvas is then scaled, which keeps
# the composition the artwork was drawn with.
MARK_RADIUS=$(awk -v w="$BW" -v h="$BH" -v x="$BX" -v y="$BY" -v n="$W" 'BEGIN {
  c = n / 2;
  dx = (x + w - c > c - x) ? x + w - c : c - x;
  dy = (y + h - c > c - y) ? y + h - c : c - y;
  printf "%.6f", sqrt(dx * dx + dy * dy) / n;
}')
SCALE=$(awk -v r="$MARK_RADIUS" -v s="$SAFE_RADIUS_RATIO" 'BEGIN { printf "%.6f", s / r }')

echo "master ${W}x${H}; mark box ${BBOX}; farthest corner ${MARK_RADIUS} of the canvas from centre"
echo "scaling the artwork to ${SCALE} of an adaptive layer; legacy corner radius ${CORNER_RATIO}"

for spec in "mdpi 48 108" "hdpi 72 162" "xhdpi 96 216" "xxhdpi 144 324" "xxxhdpi 192 432"; do
  # shellcheck disable=SC2086
  set -- $spec
  density=$1 legacy=$2 layer=$3
  mkdir -p "$OUT/mipmap-$density"

  corner=$(awk -v s="$legacy" -v f="$CORNER_RATIO" 'BEGIN { printf "%d", s * f + 0.5 }')
  "$MAGICK" "$SRC" -filter Lanczos -resize "${legacy}x${legacy}" \
    \( -size "${legacy}x${legacy}" xc:black -fill white \
       -draw "roundrectangle 0,0 $((legacy - 1)),$((legacy - 1)) ${corner},${corner}" \) \
    -alpha off -compose CopyOpacity -composite -strip \
    "$OUT/mipmap-$density/ic_launcher.png"

  "$MAGICK" "$SRC" -filter Lanczos -resize "${legacy}x${legacy}" \
    \( -size "${legacy}x${legacy}" xc:black -fill white \
       -draw "circle $((legacy / 2)),$((legacy / 2)) $((legacy / 2)),1" \) \
    -alpha off -compose CopyOpacity -composite -strip \
    "$OUT/mipmap-$density/ic_launcher_round.png"

  content=$(awk -v s="$layer" -v f="$SCALE" 'BEGIN { printf "%d", s * f + 0.5 }')
  "$MAGICK" "$WORK/mark.png" -filter Lanczos -resize "${content}x${content}" \
    -background none -gravity center -extent "${layer}x${layer}" -strip \
    "$OUT/mipmap-$density/ic_launcher_foreground.png"

  echo "  mipmap-$density: legacy ${legacy}px (corner ${corner}px), foreground ${layer}px (mark ${content}px)"
done

mkdir -p "$OUT/mipmap-anydpi-v26" "$OUT/drawable"

cat > "$OUT/drawable/ic_launcher_background.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by scripts/make_icons.sh from design/imagyn-icon-1024.png. -->
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <gradient
        android:type="linear"
        android:angle="270"
        android:startColor="#FF${GRADIENT_TOP#\#}"
        android:endColor="#FF${GRADIENT_BOTTOM#\#}" />
</shape>
XML

for name in ic_launcher ic_launcher_round; do
  cat > "$OUT/mipmap-anydpi-v26/$name.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by scripts/make_icons.sh. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <!-- Themed icons (Android 13+) recolour the alpha channel of this layer. -->
    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
XML
done

# --- desktop icons ------------------------------------------------------------
# Windows wants a multi-size .ico, Linux a set of PNGs for the hicolor theme.
# They carry the same rounded corners as the legacy Android icon; the adaptive
# one is shaped by the launcher instead. Windows and Linux packages copy from
# here, so the packagers need no image tooling of their own. macOS builds its
# .icns from these PNGs with iconutil, which only exists on macOS.
DESKTOP="$ROOT/platform/icons"
mkdir -p "$DESKTOP/png"
for size in 16 24 32 48 64 128 256 512 1024; do
  corner=$(awk -v s="$size" -v f="$CORNER_RATIO" 'BEGIN { printf "%d", s * f + 0.5 }')
  "$MAGICK" "$SRC" -filter Lanczos -resize "${size}x${size}" \
    \( -size "${size}x${size}" xc:black -fill white \
       -draw "roundrectangle 0,0 $((size - 1)),$((size - 1)) ${corner},${corner}" \) \
    -alpha off -compose CopyOpacity -composite -strip "$DESKTOP/png/${size}.png"
done
"$MAGICK" "$DESKTOP/png/16.png" "$DESKTOP/png/24.png" "$DESKTOP/png/32.png" \
  "$DESKTOP/png/48.png" "$DESKTOP/png/64.png" "$DESKTOP/png/128.png" \
  "$DESKTOP/png/256.png" -strip "$DESKTOP/imagyn.ico"

# Flutter's Windows runner compiles windows/runner/resources/app_icon.ico into
# the executable, so the taskbar and the shortcut icons come from there rather
# than from the installer. Ship the same file through the platform overlay.
WINDOWS_ICON="$ROOT/platform/windows/runner/resources"
mkdir -p "$WINDOWS_ICON"
cp "$DESKTOP/imagyn.ico" "$WINDOWS_ICON/app_icon.ico"
echo "  desktop: platform/icons/png/{16..1024}.png, platform/icons/imagyn.ico"
echo "  windows: platform/windows/runner/resources/app_icon.ico"

echo "wrote $OUT"
