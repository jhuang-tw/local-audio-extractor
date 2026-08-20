#!/usr/bin/env bash
set -u

if [ "$#" -lt 1 ]; then
  echo 'Usage: extract-for-subtitles.command "/path/video.mp4"'
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
base="$dir/$stem"
output="$base.subtitles.mp3"
if [ -e "$output" ]; then
  n=2
  while [ "$n" -le 9999 ]; do
    candidate="$base.subtitles-$n.mp3"
    if [ ! -e "$candidate" ]; then
      output=$candidate
      break
    fi
    n=$((n + 1))
  done
fi
if [ -e "$output" ]; then
  echo 'ERROR: Could not choose a free output filename.'
  exit 3
fi

partial="$output.partial.$$.$RANDOM.mp3"
cleanup() { rm -f "$partial" >/dev/null 2>&1 || true; }
trap cleanup EXIT HUP INT TERM

echo "Input:  $input"
echo "Output: $output"
if ! ffmpeg -hide_banner -loglevel error -nostdin -y -i "$input" -map 0:a:0 -vn -ac 1 -ar 16000 -c:a libmp3lame -b:a 64k "$partial"; then
  echo 'ERROR: Audio extraction failed.'
  exit 1
fi
if ! mv "$partial" "$output"; then
  echo "ERROR: Extraction succeeded but the final output could not be published: $partial"
  exit 1
fi
trap - EXIT HUP INT TERM
echo "Success: $output"