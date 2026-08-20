@echo off
setlocal

if "%~1"=="" (
  echo Usage: Drag a video file onto this script, or run:
  echo   extract-for-subtitles.bat "C:\path\video.mp4"
  exit /b 64
)

where ffmpeg >nul 2>nul
if errorlevel 1 (
  echo ERROR: FFmpeg was not found.
  echo Install it with: winget install Gyan.FFmpeg
  exit /b 127
)
where ffprobe >nul 2>nul
if errorlevel 1 (
  echo ERROR: ffprobe was not found. Reinstall FFmpeg with: winget install Gyan.FFmpeg
  exit /b 127
)

set "INPUT=%~f1"
if not exist "%INPUT%" (
  echo ERROR: Input file not found: %INPUT%
  exit /b 66
)

ffprobe -v error -show_entries format=filename -of default=noprint_wrappers=1:nokey=1 "%INPUT%" >nul 2>nul
if errorlevel 1 (
  echo ERROR: Could not inspect input media.
  exit /b 1
)
ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "%INPUT%" 2>nul | findstr /R /C:"^audio$" >nul
if errorlevel 1 (
  echo No audio stream found.
  exit /b 2
)

set "OUTPUT=%~dpn1.subtitles.mp3"
if not exist "%OUTPUT%" goto output_ready
for /L %%N in (2,1,9999) do (
  if not exist "%~dpn1.subtitles-%%N.mp3" (
    set "OUTPUT=%~dpn1.subtitles-%%N.mp3"
    goto output_ready
  )
)
echo ERROR: Could not choose a free output filename.
exit /b 3

:output_ready
set "PARTIAL=%OUTPUT%.partial-%RANDOM%-%RANDOM%.mp3"
echo Input:  %INPUT%
echo Output: %OUTPUT%

ffmpeg -hide_banner -loglevel error -nostdin -y -i "%INPUT%" -map 0:a:0 -vn -ac 1 -ar 16000 -c:a libmp3lame -b:a 64k "%PARTIAL%"
if errorlevel 1 (
  if exist "%PARTIAL%" del /q "%PARTIAL%" >nul 2>nul
  echo ERROR: Audio extraction failed.
  exit /b 1
)

move /y "%PARTIAL%" "%OUTPUT%" >nul
if errorlevel 1 (
  echo ERROR: Extraction succeeded but the final output could not be published.
  echo Partial file: %PARTIAL%
  exit /b 1
)

echo Success: %OUTPUT%
exit /b 0