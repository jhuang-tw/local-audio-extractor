$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Ui = Join-Path $Root 'windows\local-audio-extractor.ps1'
$Extractor = Join-Path $Root 'windows\extract-for-subtitles.bat'
$Tmp = Join-Path $PSScriptRoot ('.tmp-ui-win-' + [Guid]::NewGuid().ToString('N'))
$Chinese = [string]([char]0x4E2D) + [string]([char]0x6587)
$InputDir = Join-Path $Tmp ("space $Chinese")
$Input = Join-Path $InputDir ("$Chinese sample.mp4")
$Output = Join-Path $InputDir ("$Chinese sample.subtitles.mp3")

function Fail([string]$Message) { throw "FAIL: $Message" }

try {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Fail 'ffmpeg not found' }
    if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { Fail 'ffprobe not found' }

    $probe = (& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $Ui -ProbeUi 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $probe -notmatch 'PASS: Windows B UI') {
        Fail "WPF UI probe failed:`n$probe"
    }

    New-Item -ItemType Directory -Path $InputDir -Force | Out-Null
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=black:s=16x16:r=1:d=2' -f lavfi -i 'sine=frequency=800:sample_rate=48000:duration=2' -map 0:v:0 -map 1:a:0 -c:v mpeg4 -q:v 31 -c:a aac -b:a 96k -shortest -- $Input
    if ($LASTEXITCODE -ne 0) { Fail 'fixture generation failed' }

    $env:LAE_SCRIPT = $Extractor
    $env:LAE_INPUT = $Input
    $bridgeOutput = (& $env:ComSpec /d /s /c 'call "%LAE_SCRIPT%" "%LAE_INPUT%"' 2>&1 | Out-String)
    $bridgeExit = $LASTEXITCODE
    if ($bridgeExit -ne 0) { Fail "native bridge command failed, exit=$bridgeExit`n$bridgeOutput" }
    if (-not (Test-Path -LiteralPath $Output -PathType Leaf)) { Fail "bridge output missing: $Output" }

    $codec = (& ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 -- $Output 2>$null | Select-Object -First 1)
    if ([string]$codec.Trim() -ne 'mp3') { Fail "bridge output codec expected mp3, got '$codec'" }

    Write-Output 'PASS: Windows B UI probe + hidden bridge command'
}
finally {
    Remove-Item Env:LAE_SCRIPT -ErrorAction SilentlyContinue
    Remove-Item Env:LAE_INPUT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Recurse -Force }
}
