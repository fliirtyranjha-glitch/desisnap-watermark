#!/usr/bin/env bash
# Generic watermark script.
#
# Inputs (env, supplied by the workflow):
#   SRC_URL   (required) presigned GET url of the source video
#   DST_URL   (required) presigned PUT url of the destination object
#   LOGO_URL  (optional) public url of a PNG logo, overlaid top-right
#   SITE_NAME (optional) plain-ASCII site name rendered bottom-right
#   SRC_EXT   (optional) extension of the source file (default: mp4)
#   OUT_NAME  (optional) human readable label for logs
#
# This repository holds no credentials on purpose: the caller signs both
# URLs, so a leak of this repo exposes nothing but an ffmpeg command.
set -euo pipefail

: "${SRC_URL:?SRC_URL required}"
: "${DST_URL:?DST_URL required}"
LOGO_URL="${LOGO_URL:-}"
SITE_NAME="${SITE_NAME:-}"
SRC_EXT="${SRC_EXT:-mp4}"
OUT_NAME="${OUT_NAME:-watermarked}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "== Watermarking: $OUT_NAME =="

echo "-- downloading source..."
curl -fsSL --retry 3 --retry-delay 2 --max-time 900 -o "input.$SRC_EXT" "$SRC_URL"
IN_SIZE=$(stat -c%s "input.$SRC_EXT")
echo "   source bytes: $IN_SIZE"
[ "$IN_SIZE" -gt 1000 ] || { echo "source too small / empty"; exit 1; }

W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "input.$SRC_EXT" | head -1)
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "input.$SRC_EXT" | head -1)
W="${W:-1280}"; H="${H:-720}"
echo "   video: ${W}x${H}"

FILTER=""
INPUTS=()
if [ -n "$LOGO_URL" ]; then
  echo "-- downloading logo..."
  if curl -fsSL --retry 2 --max-time 60 -o logo.bin "$LOGO_URL"; then
    LOGO_W=$(( W * 18 / 100 ))
    [ "$LOGO_W" -ge 24 ] || LOGO_W=24
    INPUTS=(-i logo.bin)
    FILTER="[1:v]scale=${LOGO_W}:-1[lg];[0:v][lg]overlay=W-w-H/20:H/20"
    echo "   logo ok (width ${LOGO_W}px)"
  else
    echo "   logo download failed — continuing without it"
  fi
fi

# Site name text bottom-right. Only applied for plain ASCII names so the
# runner's DejaVu font always covers the glyphs. textfile= avoids escaping.
if [ -n "$SITE_NAME" ]; then
  if printf '%s' "$SITE_NAME" | LC_ALL=C grep -qE '^[ -~]{1,40}$'; then
    printf '%s' "$SITE_NAME" > site.txt
    FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
    [ -f "$FONT" ] || FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
    FONTSIZE=$(( H / 26 )); [ "$FONTSIZE" -ge 12 ] || FONTSIZE=12
    TEXT="drawtext=fontfile=${FONT}:textfile=site.txt:fontsize=${FONTSIZE}:fontcolor=white@0.85:box=1:boxcolor=black@0.35:boxborderw=12:x=w-tw-w/28:y=h-th-h/28"
    if [ -n "$FILTER" ]; then FILTER="$FILTER,$TEXT"; else FILTER="$TEXT"; fi
    echo "   site text ok: $SITE_NAME"
  else
    echo "   site name skipped (non-ascii)"
  fi
fi

if [ -n "$FILTER" ]; then
  FARGS=(-filter_complex "${FILTER}[v]" -map "[v]" -map "0:a?")
else
  echo "no overlay inputs — re-encoding without filters"
  FARGS=()
fi

echo "-- encoding (attempt 1: copy audio)..."
if ! ffmpeg -y -hide_banner -loglevel error -i "input.$SRC_EXT" "${INPUTS[@]}" \
     "${FARGS[@]}" \
     -c:v libx264 -preset ultrafast -crf 25 -pix_fmt yuv420p \
     -c:a copy -movflags +faststart out.mp4; then
  echo "-- audio copy failed, retrying with AAC..."
  ffmpeg -y -hide_banner -loglevel error -i "input.$SRC_EXT" "${INPUTS[@]}" \
     "${FARGS[@]}" \
     -c:v libx264 -preset ultrafast -crf 25 -pix_fmt yuv420p \
     -c:a aac -b:a 160k -movflags +faststart out.mp4
fi

OUT_SIZE=$(stat -c%s out.mp4)
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 out.mp4 | head -1)
echo "   output bytes: $OUT_SIZE  duration: ${DUR}s"
[ "$OUT_SIZE" -gt 1000 ] || { echo "output invalid (size)"; exit 1; }
awk -v d="$DUR" 'BEGIN { exit !(d > 0.5) }' || { echo "output invalid (duration)"; exit 1; }

echo "-- uploading watermarked file..."
curl -fsS --retry 3 --retry-delay 2 --max-time 1800 \
     -X PUT -H "Content-Type: video/mp4" --upload-file out.mp4 "$DST_URL"

echo "Done: $OUT_NAME"
