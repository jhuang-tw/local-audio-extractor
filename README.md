# Extract audio from huge videos locally.

Turn a multi-GB video into a small audio file for Gemini, Whisper, or subtitles — without uploading the video anywhere.

## Windows

1. Install FFmpeg:

   ```powershell
   winget install Gyan.FFmpeg
   ```

2. Double-click:

   `windows\launch-ui.vbs`

   This opens the B desktop UI without a console window. You can drag a video into the window, choose **Fast Copy**, **Subtitle Ready**, or **Split**, then start extraction. The UI calls the existing batch scripts locally; it does not run a server or upload the source video.

   If Windows Script Host is disabled, use the visible-console fallback:

   `windows\launch-ui.bat`

3. Prefer the original script-only flow? Drag a video directly onto:

   `windows\extract-for-subtitles.bat`

4. Get:

   `video.subtitles.mp3`

The output is created next to the source video. The extraction core still requires only FFmpeg/ffprobe. The optional Windows B UI uses built-in Windows PowerShell/WPF and adds no Node.js, Python, Electron, local server, account, telemetry, or cloud runtime.

### B desktop UI

The native Windows UI keeps the selected B layout while preserving the original product boundary:

- browse or drag-and-drop a local video;
- switch among all three extraction modes;
- configure split length from 1 to 1440 minutes;
- detect whether FFmpeg/ffprobe are available before enabling Start;
- keep the window responsive while the existing batch script runs in a hidden child process;
- surface script success/errors and open the output folder when complete;
- refuse to close the window while an extraction is still running, so the UI does not intentionally hard-kill FFmpeg and leave partial work.

`ui/index.html` remains a browser-safe design/reference build of B. Browsers cannot obtain the real local file path and launch FFmpeg safely, so the executable Windows path is the native WPF launcher above rather than a local HTTP bridge.
## Modes

| Mode | Use case | Re-encode | Output |
| --- | --- | --- | --- |
| FAST | Keep original audio | No | `.mka` |
| SUBTITLES | Gemini / Whisper | Audio only | `.mp3` |
| SPLIT | Very long videos | Audio only | segmented `.mp3` |

### FAST

Use `windows/extract-fast.bat` or `macos/extract-fast.command` when you only need the first source audio stream as quickly as possible.

FAST maps only the first audio track, disables video output, and copies the audio codec without re-encoding. The `.mka` container is used because it can safely hold a broad range of source audio codecs such as AAC and Opus.

Example:

```text
video.mp4
→ video.audio.mka
```

### SUBTITLES

Use `windows/extract-for-subtitles.bat` or `macos/extract-for-subtitles.command` for speech transcription.

The output is MP3, mono, 16 kHz, approximately 64 kbps. This favors speech clarity, small files, and broad transcription compatibility rather than maximum audio quality.

Example:

```text
video.mp4
→ video.subtitles.mp3
```

### SPLIT

Use `windows/extract-split.bat` or `macos/extract-split.command` for very long recordings. The default segment length is 30 minutes.

Windows drag-and-drop uses the 30-minute default. From a terminal you can choose another positive integer length:

```powershell
windows\extract-split.bat "C:\path\video.mp4" --segment-minutes 60
```

```bash
./macos/extract-split.command "/path/video.mp4" --segment-minutes 60
```

Example output:

```text
video.part-001.mp3
video.part-002.mp3
video.part-003.mp3
```

Every segment is MP3, mono, 16 kHz, approximately 64 kbps.

## macOS

Install FFmpeg:

```bash
brew install ffmpeg
```

Then run any mode directly:

```bash
./macos/extract-fast.command "/path/video.mp4"
./macos/extract-for-subtitles.command "/path/video.mp4"
./macos/extract-split.command "/path/video.mp4" --segment-minutes 30
```

Finder can also pass a dropped file path to a `.command` file after the executable bit is preserved by Git checkout.

## File behavior

- Paths with spaces and Unicode characters are supported.
- Common containers such as MP4, MOV, MKV, WebM, AVI, and M4V are handled by FFmpeg.
- Version 1 always uses the first audio stream (`0:a:0`). There is intentionally no track-selector GUI.
- If a valid input contains no audio stream, the scripts print `No audio stream found.` and do not create a final output file.
- Existing outputs are never silently overwritten. FAST and SUBTITLES add `-2`, `-3`, and so on. SPLIT selects a new group prefix such as `video.split-2.part-001.mp3` when any matching segment already exists.
- FAST never decodes or encodes video and never re-encodes audio.
- SUBTITLES and SPLIT decode/encode audio only. Video is never decoded for their output pipeline.
- Work is streamed by FFmpeg; the scripts do not read the whole source into RAM and do not create a second copy of the video.
- FAST and SUBTITLES write to a same-directory partial file and publish the final filename only after FFmpeg succeeds. SPLIT writes into a temporary same-directory folder and moves completed segments into place only after FFmpeg succeeds. A hard process kill may leave a clearly temporary partial file/folder, but it does not report success.

## Privacy

The extraction itself happens entirely on your computer.

If you upload the extracted audio to Gemini or another cloud service, that upload is subject to that provider's data/privacy policy.

## Generate subtitles with Gemini

After creating a subtitle-ready MP3, you can upload it to Gemini and use a prompt like this:

```text
請完整轉錄這個音訊並輸出標準 SRT。

要求：
- 使用繁體中文
- 時間碼格式 HH:MM:SS,mmm --> HH:MM:SS,mmm
- 不摘要
- 不改寫原意
- 依照語意自然斷句
- 每段字幕保持適合閱讀的長度
- 聽不清楚的地方標記 [聽不清]
- 不要 Markdown
- 只輸出 SRT
```

This is only a usage example. Local Audio Extractor does not call the Gemini API or any other AI service.

## SPLIT and SRT timestamps

A transcription service usually starts each uploaded split part at `00:00:00` again. With the default 30-minute split, offset later SRT files before combining them:

```text
part-001 → +00:00:00
part-002 → +00:30:00
part-003 → +01:00:00
```

Automatic SRT merge/offset is intentionally outside the MVP.

## Test

The repository contains focused smoke tests that generate tiny synthetic media with FFmpeg rather than storing binary fixtures:

```bash
bash tests/smoke.sh
```

On Windows:

```powershell
powershell -ExecutionPolicy Bypass -File tests\smoke-windows.ps1

# Optional B desktop UI / native bridge probe
powershell -ExecutionPolicy Bypass -File tests\ui-windows-probe.ps1
```

The tests cover AAC/MP4, Opus/MKV, no-audio input, spaces, Unicode paths, existing-output protection, FAST stream copy, subtitle audio properties, and segmented output.

## Requirements

Only FFmpeg (including `ffprobe`) is required at runtime.