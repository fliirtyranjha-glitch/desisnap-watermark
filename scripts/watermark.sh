#!/usr/bin/env bash
# Generic watermark script.
#
# Inputs (env, supplied by the workflow):
#   SRC_URL    (required) presigned GET url of the source video
#   DST_URL    (required) presigned PUT url of the destination object
#   LOGO_URL   (optional) public url of a PNG/JPG/WebP image, overlaid
#   SITE_NAME  (optional) plain-ASCII text rendered with DejaVu
#   SRC_EXT    (optional) extension of the source file (default: mp4)
#   OUT_NAME   (optional) human readable label for logs
#   LOGO_POS   (optional) tl|tr|bl|br|c          (default tr)
#   LOGO_MOTION(optional) static|moving|spin      (default static)
#   TEXT_POS   (optional) tl|tr|bl|br|c          (default br)
#   TEXT_MOTION(optional) static|moving           (default static)
#   TEXT_STYLE (optional) light|dark              (default light)
#   TEXT_SIZE  (optional) s|m|l                   (default m)
#   OP         (optional) 0.20–1.00 opacity       (default 0.85)
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

# Style options may arrive as ONE pipe-packed string (the worker packs them
# because GitHub caps client_payload at 10 properties):
#   OPTS = "logoPos|logoMotion|textPos|textMotion|textStyle|textSize|op"
# Individual vars (LOGO_POS etc.) still work for local testing; OPTS wins.
if [ -n "${OPTS:-}" ]; then
  IFS='|' read -r LOGO_POS LOGO_MOTION TEXT_POS TEXT_MOTION TEXT_STYLE TEXT_SIZE OP <<< "$OPTS"
fi
LOGO_POS="${LOGO_POS:-tr}"
LOGO_MOTION="${LOGO_MOTION:-static}"
TEXT_POS="${TEXT_POS:-br}"
TEXT_MOTION="${TEXT_MOTION:-static}"
TEXT_STYLE="${TEXT_STYLE:-light}"
TEXT_SIZE="${TEXT_SIZE:-m}"
OP="${OP:-0.85}"

# Clamp opacity to 0.20–1.00 (awk float compare; falls back to 0.85 on junk).
OP=$(awk -v v="$OP" 'BEGIN { if (v+0 < 0.2) v=0.2; if (v+0 > 1) v=1; if (v+0 != v) v=0.85; printf "%.2f", v }' 2>/dev/null || echo 0.85)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "== Watermarking: $OUT_NAME =="
echo "   options: logo=$LOGO_POS/$LOGO_MOTION text=$TEXT_POS/$TEXT_MOTION/$TEXT_STYLE/$TEXT_SIZE op=$OP"

echo "-- downloading source..."
curl -fsSL --retry 3 --retry-delay 2 --max-time 900 -o "input.$SRC_EXT" "$SRC_URL"
IN_SIZE=$(stat -c%s "input.$SRC_EXT")
echo "   source bytes: $IN_SIZE"
[ "$IN_SIZE" -gt 1000 ] || { echo "source too small / empty"; exit 1; }

W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "input.$SRC_EXT" | head -1)
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "input.$SRC_EXT" | head -1)
W="${W:-1280}"; H="${H:-720}"
echo "   video: ${W}x${H}"

# Shared geometry: margin m scales with the video (min 8 px).
M=$(( H / 24 )); [ "$M" -ge 8 ] || M=8

# Static anchor expressions.
# OVERLAY filter vars: W/H = main video, w/h = overlay element.
pos_overlay() { # $1 = tl|tr|bl|br|c -> "x=..:y=.."
  case "$1" in
    tl) echo "x=${M}:y=${M}";;
    tr) echo "x=W-w-${M}:y=${M}";;
    bl) echo "x=${M}:y=H-h-${M}";;
    br) echo "x=W-w-${M}:y=H-h-${M}";;
    c)  echo "x=(W-w)/2:y=(H-h)/2";;
    *)  echo "x=W-w-${M}:y=${M}";;
  esac
}

# DRATEXT vars: w/h = video size, tw/th = text size.
pos_drawtext() { # $1 = tl|tr|bl|br|c -> "x=..:y=.."
  case "$1" in
    tl) echo "x=${M}:y=${M}";;
    tr) echo "x=w-tw-${M}:y=${M}";;
    bl) echo "x=${M}:y=h-th-${M}";;
    br) echo "x=w-tw-${M}:y=h-th-${M}";;
    c)  echo "x=(w-tw)/2:y=(h-th)/2";;
    *)  echo "x=w-tw-${M}:y=${M}";;
  esac
}

FILTER=""
INPUTS=()

# ── Logo image ──────────────────────────────────────────────────────────────
# Width 18% of the video (min 24 px), alpha-scaled by OP. "moving" = smooth
# Lissajous wander across the frame; "spin" = slow rotation in place.
if [ -n "$LOGO_URL" ]; then
  echo "-- downloading logo..."
  if curl -fsSL --retry 2 --max-time 60 -o logo.bin "$LOGO_URL"; then
    LOGO_W=$(( W * 18 / 100 ))
    [ "$LOGO_W" -ge 24 ] || LOGO_W=24
    # spin needs a LOOPED logo stream: a single-frame input is filtered only
    # once (at t=0 → angle 0), so the rotation would never animate. -loop 1
    # turns the still into a timed stream; overlay shortest=1 then ends the
    # graph at the main video EOF (the looped stream never ends by itself).
    if [ "$LOGO_MOTION" = "spin" ]; then
      INPUTS=(-loop 1 -i logo.bin)
      OVERLAY_OPTS="eval=frame:shortest=1"
    else
      INPUTS=(-i logo.bin)
      OVERLAY_OPTS="eval=frame"
    fi
    LCHAIN="[1:v]scale=${LOGO_W}:-1,format=rgba,colorchannelmixer=aa=${OP}"
    case "$LOGO_MOTION" in
      spin)
        # ow/oh are evaluated ONCE at init (t unavailable) — use a static
        # square canvas sized to the logo diagonal so no rotation clips.
        # The comma inside hypot() must be escaped for the filtergraph.
        ANG="t*0.7"
        LCHAIN="${LCHAIN},rotate=${ANG}:c=none:ow=hypot(iw\,ih):oh=hypot(iw\,ih)"
        LPOS=$(pos_overlay "$LOGO_POS")
        ;;
      moving)
        LPOS="x=(W-w)/2+(W-w)/2*sin(t/9):y=(H-h)/2+(H-h)/2*sin(t/5.7)"
        ;;
      *)
        LPOS=$(pos_overlay "$LOGO_POS")
        ;;
    esac
    FILTER="${LCHAIN}[lg];[0:v][lg]overlay=${OVERLAY_OPTS}:${LPOS}"
    echo "   logo ok (width ${LOGO_W}px, $LOGO_MOTION)"
  else
    echo "   logo download failed — continuing without it"
  fi
fi

# ── Site name text ──────────────────────────────────────────────────────────
# Only plain-ASCII names so the runner's DejaVu font always covers the glyphs.
# textfile= avoids escaping entirely.
if [ -n "$SITE_NAME" ]; then
  if printf '%s' "$SITE_NAME" | LC_ALL=C grep -qE '^[ -~]{1,40}$'; then
    printf '%s' "$SITE_NAME" > site.txt
    FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
    [ -f "$FONT" ] || FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
    case "$TEXT_SIZE" in
      s) DIV=34;;
      l) DIV=18;;
      *) DIV=26;;
    esac
    FONTSIZE=$(( H / DIV )); [ "$FONTSIZE" -ge 12 ] || FONTSIZE=12
    [ "$FONTSIZE" -le 120 ] || FONTSIZE=120
    if [ "$TEXT_STYLE" = "dark" ]; then
      FCLR="black@${OP}"; BCLR="white@0.55"
    else
      FCLR="white@${OP}"; BCLR="black@0.40"
    fi
    case "$TEXT_MOTION" in
      moving)
        TPOS="x=(w-tw)/2+(w-tw)/2*sin(t/7.3+2.1):y=(h-th)/2+(h-th)/2*sin(t/4.1+1.0)"
        ;;
      *)
        TPOS=$(pos_drawtext "$TEXT_POS")
        ;;
    esac
    TEXT="drawtext=fontfile=${FONT}:textfile=site.txt:fontsize=${FONTSIZE}:fontcolor=${FCLR}:box=1:boxcolor=${BCLR}:boxborderw=12:${TPOS}"
    if [ -n "$FILTER" ]; then
      FILTER="${FILTER}[v1];[v1]${TEXT}"
    else
      FILTER="${TEXT}"
    fi
    echo "   site text ok: $SITE_NAME ($TEXT_STYLE/$TEXT_SIZE/$TEXT_MOTION)"
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
