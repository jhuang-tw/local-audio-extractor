#!/usr/bin/env bash
set -u

if [ "$#" -lt 1 ]; then
  echo 'Usage: extract-split.command "/path/video.mp4" [--segment-minutes 30]'
  exit 64
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo 'ERROR: FFmpeg was not found.'
  echo 'Install it with: brew install ffmpeg'
  exit 127
fi
if ! command -v ffprobe >/dev/null 2>&1; then
  echo 'ERROR: ffprobe was not found. Reinstall FFmpeg with: brew install ffmpeg'
  exit 127
fi

input=$1
segment_minutes=30
if [ "$#" -gt 1 ]; then
  if [ "$2" != '--segment-minutes' ] || [ "$#" -lt 3 ]; then
    echo 'ERROR: Expected --segment-minutes followed by a positive integer.'
    exit 64
  fi
  segment_minutes=$3
fi
case "$segment_minutes" in
  ''|*[!0-9]*)
    echo 'ERROR: --segment-minutes requires a positive integer.'
    exit 64
    ;;
esac
if [ "$segment_minutes" -le 0 ]; then
  echo 'ERROR: --segment-minutes requires a positive integer.'
  exit 64
fi
segment_seconds=$((segment_minutes * 60))

if [ ! -f "$input" ]; then
  echo "ERROR: Input file not found: $input"
  exit 66
fi
if ! ffprobe -v error -show_entries format=filename -of default=noprint_wrappers=1:nokey=1 "$input" >/dev/null 2>&1; then
  echo 'ERROR: Could not inspect input media.'
  exit 1
fi
audio_type=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$input" 2>/dev/null) || {
  echo 'ERROR: Could not inspect input media.'
  exit 1
}
if [ -z "$audio_type" ]; then
  echo 'No audio stream found.'
  exit 2
fi

dir=$(dirname "$input")
name=$(basename "$input")
stem=${name%.*}
prefix=$stem
has_segments() {
  local candidate
  for candidate in "$dir/$1".part-*.mp3; do
    [ -e "$candidate" ] && return 0
  done
  return 1
}
if has_segments "$prefix"; then
  n=2
  while [ "$n" -le 9999 ]; do
    candidate_prefix="$stem.split-$n"
    if ! has_segments "$candidate_prefix"; then
      prefix=$candidate_prefix
      break
    fi
    n=$((n + 1))
  done
fi
if has_segments "$prefix"; then
  echo 'ERROR: Could not choose a free output prefix.'
  exit 3
fi

temp_dir=$(mktemp -d "$dir/.local-audio-extractor.XXXXXX") || {
  echo 'ERROR: Could not create a same-directory temporary folder.'
  exit 1
}
cleanup() { rm -rf "$temp_dir" >/dev/null 2>&1 || true; }
trap cleanup EXIT HUP INT TERM
pattern="$temp_dir/$prefix.part-%03d.mp3"

echo "Input:           $input"
echo "Output pattern:  $dir/$prefix.part-001.mp3"
echo "Segment minutes: $segment_minutes"
if ! ffmpeg -hide_banner -loglevel error -nostdin -y -i "$input" -map 0:a:0 -vn -ac 1 -ar 16000 -c:a libmp3lame -b:a 64k -f segment -segment_time "$segment_seconds" -segment_start_number 1 -reset_timestamps 1 "$pattern"; then
  echo 'ERROR: Audio extraction or splitting failed.'
  exit 1
fi

found=0
for segment in "$temp_dir"/*.mp3; do
  [ -e "$segment" ] || continue
  found=1
  target="$dir/$(basename "$segment")"
  if [ -e "$target" ]; then
    echo "ERROR: Refusing to overwrite existing output: $target"
    exit 1
  fi
done
if [ "$found" -ne 1 ]; then
  echo 'ERROR: FFmpeg returned success but no segments were produced.'
  exit 1
fi
for segment in "$temp_dir"/*.mp3; do
  [ -e "$segment" ] || continue
  if ! mv "$segment" "$dir/"; then
    echo "ERROR: Could not publish segment: $segment"
    exit 1
  fi
done
trap - EXIT HUP INT TERM
rmdir "$temp_dir" >/dev/null 2>&1 || true
echo "Success: $dir/$prefix.part-*.mp3"