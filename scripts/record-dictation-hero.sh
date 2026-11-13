#!/usr/bin/env bash
# Records the waycar.dev hero: the real app on iPhone with Dictate to Agent
# listening on the demo Checkout Agent, the red waveform scrolling across its
# listening card. It launches the DEBUG simulator demo fixture with
# --demo-screenshots --demo-dictation (the scripted DemoDictationEngine voice),
# records the screen, and crops a horizontal band at the bottom: from
# HERO_CROP_TOP_FRACTION of the capture height to the bottom, at full width.
# The band must contain the Agent's last terminal line, the listening card and
# the Toolbar, with none of the status bar.
#
# Only the waveform moves, but the h264 recording adds faint noise to every
# pixel of every frame, so img2webp would store most of the frame again each
# time. Instead every output frame is the first band frame (base.png) with
# just the box around the waveform taken from its own frame. That box is the
# union, over all frames, of the pixels that differ from base.png by more than
# HERO_MOTION_THRESHOLD, padded by 8 px. img2webp then stores only that strip
# per frame, roughly halving both files. The half-width set is scaled from
# the composited frames, not the raw ones.
#
# Outputs, in apps/web/src/assets/hero/:
#   dictation-hero.webp        animated, full capture width
#   dictation-hero-660.webp    animated, half width
#   dictation-hero-still.png   the first frame of the full-width crop
# The loop is exactly one period of the scripted voice level (3.0 s: 90
# frames whose durations add up to 3000 ms), so its last frame runs straight
# into its first. Never hand-edit those files.
#
# `make screenshots` runs this at the end of scripts/capture-screenshots.sh,
# whose UI-test run installs the Debug app recorded here and which holds the
# simulator slot with dark appearance and the 9:41 status bar. Run alone, the
# Debug app must already be installed on a simulator you hold (AGENTS.md,
# Simulators).
#
# Environment overrides:
#   HERO_CROP_TOP_FRACTION  top of the band, as a fraction of the capture
#                           height (default 0.66)
#   HERO_SETTLE_SECONDS     wait after launch for the Agent to open and the
#                           waveform to fill (default 8)
#   HERO_MOTION_THRESHOLD   how far a pixel must move from base.png, 0 to 254
#                           on the gray difference, to count as waveform
#                           (default 60, above the h264 noise)
#   HERO_QUALITY            img2webp lossy quality, 0 to 100 (default 70)
#   HERO_BOX_PAD_X          horizontal padding of the waveform box, in px
#                           (default 80, covers the 72 px fade-in at 3x)
#
# Needs ffmpeg, ffprobe and img2webp (brew install ffmpeg webp).
#
# Usage: scripts/record-dictation-hero.sh <iPhone simulator UDID>
set -euo pipefail

udid=${1:?iPhone simulator UDID required}
repo_root=$(cd "$(dirname "$0")/.." && pwd)
out_dir="$repo_root/apps/web/src/assets/hero"
bundle_id=com.otreva.waycar
crop_top=${HERO_CROP_TOP_FRACTION:-0.66}
settle=${HERO_SETTLE_SECONDS:-8}
motion_threshold=${HERO_MOTION_THRESHOLD:-60}
quality=${HERO_QUALITY:-70}
record_seconds=5
# Skips the recorder's own startup, then takes exactly one period of the
# scripted voice (DemoDictationEngine.period) at 30 fps: 90 frames.
skip=1.0
loop=3.0
fps=30
frames=90
# Margin around the moving pixels, so the waveform's soft edges stay inside
# the box. The waveform fades in over its leftmost 24 pt (72 px at 3x); those
# bars are too dim to pass the threshold, so without a wider horizontal pad
# they would fall outside the box and freeze on base.png.
motion_pad_x=${HERO_BOX_PAD_X:-80}
motion_pad_y=8

for tool in ffmpeg ffprobe img2webp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found; install it with: brew install ffmpeg webp" >&2
        exit 1
    fi
done
if ! [[ "$crop_top" =~ ^(0?\.[0-9]+|0)$ ]] || ! awk -v f="$crop_top" 'BEGIN { exit !(f + 0 > 0 && f + 0 < 1) }'; then
    echo "error: HERO_CROP_TOP_FRACTION must be a decimal number strictly between 0 and 1 (like 0.66), got '$crop_top'" >&2
    exit 1
fi
if ! [[ "$settle" =~ ^([0-9]+\.?[0-9]*|\.[0-9]+)$ ]] || ! awk -v s="$settle" 'BEGIN { exit !(s + 0 > 0) }'; then
    echo "error: HERO_SETTLE_SECONDS must be a positive number of seconds, got '$settle'" >&2
    exit 1
fi
if ! [[ "$motion_pad_x" =~ ^[0-9]+$ ]]; then
    echo "error: HERO_BOX_PAD_X must be a non-negative integer of pixels, got '$motion_pad_x'" >&2
    exit 1
fi
if ! [[ "$motion_threshold" =~ ^[0-9]+$ ]] || [ "$motion_threshold" -gt 254 ]; then
    echo "error: HERO_MOTION_THRESHOLD must be an integer from 0 to 254, got '$motion_threshold'" >&2
    exit 1
fi
if ! [[ "$quality" =~ ^[0-9]+$ ]] || [ "$quality" -gt 100 ]; then
    echo "error: HERO_QUALITY must be an integer from 0 to 100, got '$quality'" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dictation-hero.XXXXXX")
recorder=""
cleanup() {
    if [ -n "$recorder" ] && kill -0 "$recorder" 2>/dev/null; then
        kill -INT "$recorder" 2>/dev/null || true
        wait "$recorder" 2>/dev/null || true
    fi
    xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT

xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" \
    --demo-screenshots --demo-dictation >/dev/null
sleep "$settle"

# Unmasked, so the frames are rectangular like the screenshots.
xcrun simctl io "$udid" recordVideo --codec=h264 --mask=ignored --force "$tmp/raw.mov" \
    >"$tmp/record.log" 2>&1 &
recorder=$!
# Time the take from when simctl reports it is capturing, waiting at most 5 s
# in case a release words that differently.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if grep -q "Recording started" "$tmp/record.log"; then break; fi
    sleep 0.5
done
sleep "$record_seconds"
kill -INT "$recorder" 2>/dev/null || true
wait "$recorder" || true
recorder=""
if [ ! -s "$tmp/raw.mov" ]; then
    cat "$tmp/record.log" >&2
    echo "error: simctl recorded nothing" >&2
    exit 1
fi

duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp/raw.mov")
size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$tmp/raw.mov")
if ! awk -v d="$duration" -v a="$skip" -v b="$loop" 'BEGIN { exit !(d + 0 >= a + b) }'; then
    echo "error: the recording is ${duration}s; it needs at least ${skip}s + ${loop}s" >&2
    exit 1
fi

# Lists the frames ffmpeg actually wrote to directory $1 into `listed`, in
# name order, failing unless there are exactly $frames of them. ffmpeg's
# image2 muxer numbers them from 1 (001.png), so every image sequence read
# back below passes -start_number 1.
list_frames() {
    listed=("$1"/*.png)
    local count=${#listed[@]}
    [ -e "${listed[0]}" ] || count=0
    if [ "$count" -ne "$frames" ]; then
        echo "error: expected $frames $2 frames, got $count" >&2
        exit 1
    fi
}

mkdir -p "$tmp/band" "$tmp/full" "$tmp/half"
# RGB before cropping, so the band's top row is exact rather than rounded to
# the video's chroma grid.
ffmpeg -v error -ss "$skip" -i "$tmp/raw.mov" -t "$loop" -frames:v "$frames" \
    -vf "fps=$fps,format=rgb24,crop=iw:ih-round(ih*$crop_top):0:round(ih*$crop_top)" \
    "$tmp/band/%03d.png"
list_frames "$tmp/band" band
cp "${listed[0]}" "$tmp/base.png"

# Where the waveform moves: each frame's difference from base.png, cut to
# black or white at the threshold, eroded once so a lone pixel of h264 noise
# cannot stretch the box (one such pixel once grew it from 68 to 491 px tall;
# the waveform's bars are many pixels wide and survive), then bbox, which logs
# every frame's box of white pixels on stderr as "[Parsed_bbox_N @ 0x...] n:4
# pts:4 ... x1:N x2:N y1:N y2:N ..." (frames without any have no x1). The box
# is their union.
if ! ffmpeg -hide_banner -nostats -v info \
    -framerate "$fps" -start_number 1 -i "$tmp/band/%03d.png" \
    -loop 1 -framerate "$fps" -i "$tmp/base.png" \
    -filter_complex "[0:v][1:v]blend=all_mode=difference:shortest=1,format=gray,lut=y='if(gt(val,$motion_threshold),255,0)',erosion,bbox" \
    -f null - 2>"$tmp/bbox.log"; then
    cat "$tmp/bbox.log" >&2
    echo "error: ffmpeg could not compare the band frames with the first" >&2
    exit 1
fi
motion=$(awk '
    /Parsed_bbox/ && / x1:/ {
        for (i = 1; i <= NF; i++) {
            split($i, kv, ":")
            if (kv[1] == "x1") x1 = kv[2] + 0
            else if (kv[1] == "x2") x2 = kv[2] + 0
            else if (kv[1] == "y1") y1 = kv[2] + 0
            else if (kv[1] == "y2") y2 = kv[2] + 0
        }
        if (!found || x1 < left) left = x1
        if (!found || x2 > right) right = x2
        if (!found || y1 < top) top = y1
        if (!found || y2 > bottom) bottom = y2
        found = 1
    }
    END { if (found) print left, right, top, bottom }
' "$tmp/bbox.log")
if [ -z "$motion" ]; then
    echo "error: no pixel of the band moved more than $motion_threshold from the first frame;" \
        "check that Dictate to Agent was listening, or lower HERO_MOTION_THRESHOLD" >&2
    exit 1
fi
read -r x1 x2 y1 y2 <<<"$motion"
band_size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$tmp/base.png")
band_width=${band_size%x*}
band_height=${band_size#*x}
# Padded, and clamped to the band. bbox's x2 and y2 are inclusive.
box_x=$((x1 > motion_pad_x ? x1 - motion_pad_x : 0))
box_y=$((y1 > motion_pad_y ? y1 - motion_pad_y : 0))
box_right=$((x2 + motion_pad_x < band_width ? x2 + motion_pad_x : band_width - 1))
box_bottom=$((y2 + motion_pad_y < band_height ? y2 + motion_pad_y : band_height - 1))
box_w=$((box_right - box_x + 1))
box_h=$((box_bottom - box_y + 1))
box="${box_w}x${box_h} at ${box_x},${box_y}"
echo "waveform box: $box in the ${band_size} band"

# base.png with the box cut from each frame laid back in place. overlay works
# in RGB so nothing outside the box is resampled through YUV.
ffmpeg -v error \
    -loop 1 -framerate "$fps" -i "$tmp/base.png" \
    -framerate "$fps" -start_number 1 -i "$tmp/band/%03d.png" \
    -filter_complex "[1:v]crop=$box_w:$box_h:$box_x:$box_y[strip];[0:v][strip]overlay=$box_x:$box_y:format=rgb:shortest=1,format=rgb24" \
    -frames:v "$frames" "$tmp/full/%03d.png"
list_frames "$tmp/full" composited
full_frames=("${listed[@]}")
ffmpeg -v error -framerate "$fps" -start_number 1 -i "$tmp/full/%03d.png" \
    -vf "scale=iw/2:-1:flags=lanczos" "$tmp/half/%03d.png"
list_frames "$tmp/half" half-width
half_frames=("${listed[@]}")

# Encodes the frames after $1 into the animation $1. img2webp takes each
# frame's duration before its file: 33, 33 and 34 ms in every three frames,
# so the 90 frames last exactly 3000 ms.
encode_webp() {
    local output=$1 index=0 frame
    shift
    local args=(-loop 0 -lossy -q "$quality" -m 6)
    for frame in "$@"; do
        index=$((index + 1))
        if [ $((index % 3)) -eq 0 ]; then
            args+=(-d 34 "$frame")
        else
            args+=(-d 33 "$frame")
        fi
    done
    img2webp "${args[@]}" -o "$output"
}

mkdir -p "$out_dir"
encode_webp "$out_dir/dictation-hero.webp" "${full_frames[@]}"
encode_webp "$out_dir/dictation-hero-660.webp" "${half_frames[@]}"
cp "$tmp/base.png" "$out_dir/dictation-hero-still.png"

echo "recorded dictation hero from a ${size} capture, band from ${crop_top} of its height"
for file in dictation-hero.webp dictation-hero-660.webp dictation-hero-still.png; do
    printf '%s  %s bytes\n' "${out_dir#"$repo_root"/}/$file" "$(wc -c <"$out_dir/$file" | tr -d ' ')"
done
echo "frames: ${#full_frames[@]} per loop at $fps fps, quality $quality"
