#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP="$ROOT/tests/.tmp/smoke-$$"
rm -rf "$TMP"
mkdir -p "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
assert_file() { [ -f "$1" ] || fail "missing file: $1"; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1' ($3)"; }

command -v ffmpeg >/dev/null 2>&1 || fail 'ffmpeg not found'
command -v ffprobe >/dev/null 2>&1 || fail 'ffprobe not found'

AAC="$TMP/long-aac.mp4"
OPUS="$TMP/opus-source.mkv"
NO_AUDIO="$TMP/no-audio.mp4"
UNICODE_DIR="$TMP/space unicode 中文"
UNICODE_INPUT="$UNICODE_DIR/中文 video.mp4"
mkdir -p "$UNICODE_DIR"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'color=c=black:s=16x16:r=1:d=65' \
  -f lavfi -i 'sine=frequency=1000:sample_rate=48000:duration=65' \
  -map 0:v:0 -map 1:a:0 -c:v mpeg4 -q:v 31 -c:a aac -b:a 96k -ac 2 -shortest "$AAC"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'color=c=black:s=16x16:r=1:d=3' \
  -f lavfi -i 'sine=frequency=700:sample_rate=48000:duration=3' \
  -map 0:v:0 -map 1:a:0 -c:v mpeg4 -q:v 31 -c:a libopus -b:a 96k -shortest "$OPUS"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'color=c=black:s=16x16:r=1:d=2' \
  -c:v mpeg4 -q:v 31 "$NO_AUDIO"
cp "$AAC" "$UNICODE_INPUT"

# FAST: AAC source stays AAC and Opus source stays Opus; no video is produced.
bash "$ROOT/macos/extract-fast.command" "$AAC"
AAC_FAST="$TMP/long-aac.audio.mka"
assert_file "$AAC_FAST"
assert_eq "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$AAC_FAST")" 'aac' 'FAST AAC codec copy'
[ -z "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$AAC_FAST")" ] || fail 'FAST output unexpectedly contains video'

bash "$ROOT/macos/extract-fast.command" "$OPUS"
OPUS_FAST="$TMP/opus-source.audio.mka"
assert_file "$OPUS_FAST"
assert_eq "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$OPUS_FAST")" 'opus' 'FAST Opus codec copy'

# SUBTITLES: Unicode/space path, mono, 16 kHz, MP3, ~64 kbps.
bash "$ROOT/macos/extract-for-subtitles.command" "$UNICODE_INPUT"
SUB="$UNICODE_DIR/中文 video.subtitles.mp3"
assert_file "$SUB"
assert_eq "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$SUB")" 'mp3' 'subtitle codec'
assert_eq "$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$SUB")" '1' 'subtitle channels'
assert_eq "$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=noprint_wrappers=1:nokey=1 "$SUB")" '16000' 'subtitle sample rate'
BITRATE=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$SUB")
[ -n "$BITRATE" ] || fail 'subtitle bitrate missing'
[ "$BITRATE" -ge 60000 ] && [ "$BITRATE" -le 68000 ] || fail "subtitle bitrate outside ~64kbps class: $BITRATE"

# Existing output: preserve first file and choose -2.
FIRST_HASH=$(sha256sum "$SUB" | awk '{print $1}')
bash "$ROOT/macos/extract-for-subtitles.command" "$UNICODE_INPUT"
SUB2="$UNICODE_DIR/中文 video.subtitles-2.mp3"
assert_file "$SUB2"
assert_eq "$(sha256sum "$SUB" | awk '{print $1}')" "$FIRST_HASH" 'existing output preservation'

# No audio: exact message, non-zero, no final output.
set +e
NO_AUDIO_MESSAGE=$(bash "$ROOT/macos/extract-for-subtitles.command" "$NO_AUDIO" 2>&1)
NO_AUDIO_CODE=$?
set -e
[ "$NO_AUDIO_CODE" -ne 0 ] || fail 'no-audio input unexpectedly succeeded'
printf '%s\n' "$NO_AUDIO_MESSAGE" | grep -Fq 'No audio stream found.' || fail 'no-audio message missing'
[ ! -e "$TMP/no-audio.subtitles.mp3" ] || fail 'no-audio input created a final output'

# SPLIT: one-minute test override on a 65-second synthetic fixture creates 001 + 002.
bash "$ROOT/macos/extract-split.command" "$AAC" --segment-minutes 1
PART1="$TMP/long-aac.part-001.mp3"
PART2="$TMP/long-aac.part-002.mp3"
assert_file "$PART1"
assert_file "$PART2"
COUNT=$(find "$TMP" -maxdepth 1 -type f -name 'long-aac.part-*.mp3' | wc -l | tr -d ' ')
assert_eq "$COUNT" '2' 'split segment count'
for PART in "$PART1" "$PART2"; do
  assert_eq "$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$PART")" '1' 'split channels'
  assert_eq "$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=noprint_wrappers=1:nokey=1 "$PART")" '16000' 'split sample rate'
done

# A second split must choose a new group prefix instead of overwriting.
bash "$ROOT/macos/extract-split.command" "$AAC" --segment-minutes 1
assert_file "$TMP/long-aac.split-2.part-001.mp3"

if find "$TMP" -name '*.partial-*' -print -quit | grep -q .; then
  fail 'partial output remained after successful acceptance'
fi
if find "$TMP" -type d -name '.local-audio-extractor.*' -print -quit | grep -q .; then
  fail 'temporary split directory remained after successful acceptance'
fi

echo 'PASS: local-audio-extractor smoke acceptance'