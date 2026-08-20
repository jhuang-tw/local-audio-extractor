@echo off
setlocal

if "%~1"=="" (
  echo Usage: Drag a video file onto this script for 30-minute segments, or run:
  echo   extract-split.bat "C:\path\video.mp4" --segment-minutes 60
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

set "SEGMENT_MINUTES=30"
if not "%~2"=="" (
  if /I not "%~2"=="--segment-minutes" (
    echo ERROR: Unknown option: %~2
    exit /b 64
  )
  if "%~3"=="" (
    echo ERROR: --segment-minutes requires a positive integer.
    exit /b 64
  )
  set "SEGMENT_MINUTES=%~3"
)
set /a SEGMENT_SECONDS=SEGMENT_MINUTES*60 >nul 2>nul
if errorlevel 1 (
  echo ERROR: --segment-minutes requires a positive integer.
  exit /b 64
)
if %SEGMENT_SECONDS% LEQ 0 (
  echo ERROR: --segment-minutes requires a positive integer.
  exit /b 64
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

set "FINAL_BASENAME=%~n1"
if not exist "%~dp1%FINAL_BASENAME%.part-*.mp3" goto prefix_ready
for /L %%N in (2,1,9999) do (
  if not exist "%~dp1%~n1.split-%%N.part-*.mp3" (
    set "FINAL_BASENAME=%~n1.split-%%N"
    goto prefix_ready
  )
)
echo ERROR: Could not choose a free output prefix.
exit /b 3

:prefix_ready
set "TEMP_DIR=%~dp1.local-audio-extractor-%RANDOM%-%RANDOM%"
if exist "%TEMP_DIR%" (
  echo ERROR: Temporary directory collision. Run the script again.
  exit /b 3
)
mkdir "%TEMP_DIR%" >nul 2>nul
if errorlevel 1 (
  echo ERROR: Could not create temporary directory: %TEMP_DIR%
  exit /b 1
)

set "OUTPUT_PATTERN=%TEMP_DIR%\%FINAL_BASENAME%.part-%%03d.mp3"
echo Input:           %INPUT%
echo Output pattern:  %~dp1%FINAL_BASENAME%.part-001.mp3
 echo Segment minutes: %SEGMENT_MINUTES%

ffmpeg -hide_banner -loglevel error -nostdin -y -i "%INPUT%" -map 0:a:0 -vn -ac 1 -ar 16000 -c:a libmp3lame -b:a 64k -f segment -segment_time %SEGMENT_SECONDS% -segment_start_number 1 -reset_timestamps 1 "%OUTPUT_PATTERN%"
if errorlevel 1 (
  rmdir /s /q "%TEMP_DIR%" >nul 2>nul
  echo ERROR: Audio extraction or splitting failed.
  exit /b 1
)

dir /b /a-d "%TEMP_DIR%\*.mp3" >nul 2>nul
if errorlevel 1 (
  rmdir /s /q "%TEMP_DIR%" >nul 2>nul
  echo ERROR: FFmpeg returned success but no segments were produced.
  exit /b 1
)

move /y "%TEMP_DIR%\*.mp3" "%~dp1" >nul
if errorlevel 1 (
  echo ERROR: Segments were created but could not all be published.
  echo Temporary directory retained: %TEMP_DIR%
  exit /b 1
)
rmdir "%TEMP_DIR%" >nul 2>nul

echo Success: %~dp1%FINAL_BASENAME%.part-*.mp3
exit /b 0