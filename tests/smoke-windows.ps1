$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Tmp = Join-Path $PSScriptRoot ('.tmp-win-' + [Guid]::NewGuid().ToString('N'))
$Chinese = [string]([char]0x4E2D) + [string]([char]0x6587)
$UnicodeDir = Join-Path $Tmp ("space unicode $Chinese")
New-Item -ItemType Directory -Path $UnicodeDir -Force | Out-Null

function Fail([string]$Message) { throw "FAIL: $Message" }
function Assert-File([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "missing file: $Path" } }
function Assert-Equal([string]$Actual, [string]$Expected, [string]$Label) { if ($Actual -ne $Expected) { Fail "$Label expected '$Expected', got '$Actual'" } }
function Probe([string]$Path, [string]$Entry) {
    $values = @(& ffprobe -v error -select_streams a:0 -show_entries "stream=$Entry" -of default=noprint_wrappers=1:nokey=1 -- $Path 2>$null)
    $probeExit = $LASTEXITCODE
    if ($probeExit -ne 0) { Fail "ffprobe failed for $Path ($Entry), exit=$probeExit" }
    $value = $values | Select-Object -First 1
    return ([string]$value).Trim()
}
function Run-Batch([string]$Script, [string[]]$Arguments) {
    $text = (& $Script @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
}

try {
    foreach ($tool in @('ffmpeg', 'ffprobe')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "$tool not found" }
    }

    $Aac = Join-Path $Tmp 'long-aac.mp4'
    $Opus = Join-Path $Tmp 'opus-source.mkv'
    $NoAudio = Join-Path $Tmp 'no-audio.mp4'
    $UnicodeInput = Join-Path $UnicodeDir ("$Chinese video.mp4")

    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=black:s=16x16:r=1:d=65' -f lavfi -i 'sine=frequency=1000:sample_rate=48000:duration=65' -map 0:v:0 -map 1:a:0 -c:v mpeg4 -q:v 31 -c:a aac -b:a 96k -ac 2 -shortest -- $Aac
    if ($LASTEXITCODE -ne 0) { Fail 'AAC fixture generation failed' }
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=black:s=16x16:r=1:d=3' -f lavfi -i 'sine=frequency=700:sample_rate=48000:duration=3' -map 0:v:0 -map 1:a:0 -c:v mpeg4 -q:v 31 -c:a libopus -b:a 96k -shortest -- $Opus
    if ($LASTEXITCODE -ne 0) { Fail 'Opus fixture generation failed' }
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=black:s=16x16:r=1:d=2' -c:v mpeg4 -q:v 31 -- $NoAudio
    if ($LASTEXITCODE -ne 0) { Fail 'no-audio fixture generation failed' }
    Copy-Item -LiteralPath $Aac -Destination $UnicodeInput

    $Fast = Join-Path $Root 'windows\extract-fast.bat'
    $Subtitles = Join-Path $Root 'windows\extract-for-subtitles.bat'
    $Split = Join-Path $Root 'windows\extract-split.bat'

    $r = Run-Batch $Fast @($Aac)
    if ($r.Code -ne 0) { Fail "FAST AAC failed:`n$($r.Text)" }
    $AacFast = Join-Path $Tmp 'long-aac.audio.mka'
    Assert-File $AacFast
    Assert-Equal (Probe $AacFast 'codec_name') 'aac' 'FAST AAC codec copy'

    $r = Run-Batch $Fast @($Opus)
    if ($r.Code -ne 0) { Fail "FAST Opus failed:`n$($r.Text)" }
    $OpusFast = Join-Path $Tmp 'opus-source.audio.mka'
    Assert-File $OpusFast
    Assert-Equal (Probe $OpusFast 'codec_name') 'opus' 'FAST Opus codec copy'

    $r = Run-Batch $Subtitles @($UnicodeInput)
    if ($r.Code -ne 0) { Fail "SUBTITLES Unicode path failed:`n$($r.Text)" }
    $Sub = Join-Path $UnicodeDir ("$Chinese video.subtitles.mp3")
    Assert-File $Sub
    Assert-Equal (Probe $Sub 'codec_name') 'mp3' 'subtitle codec'
    Assert-Equal (Probe $Sub 'channels') '1' 'subtitle channels'
    Assert-Equal (Probe $Sub 'sample_rate') '16000' 'subtitle sample rate'
    $bitrate = [int](Probe $Sub 'bit_rate')
    if ($bitrate -lt 60000 -or $bitrate -gt 68000) { Fail "subtitle bitrate outside ~64kbps class: $bitrate" }

    $firstHash = (Get-FileHash -LiteralPath $Sub -Algorithm SHA256).Hash
    $r = Run-Batch $Subtitles @($UnicodeInput)
    if ($r.Code -ne 0) { Fail "SUBTITLES collision run failed:`n$($r.Text)" }
    $Sub2 = Join-Path $UnicodeDir ("$Chinese video.subtitles-2.mp3")
    Assert-File $Sub2
    Assert-Equal (Get-FileHash -LiteralPath $Sub -Algorithm SHA256).Hash $firstHash 'existing output preservation'

    $r = Run-Batch $Subtitles @($NoAudio)
    if ($r.Code -eq 0) { Fail 'no-audio input unexpectedly succeeded' }
    if ($r.Text -notmatch [regex]::Escape('No audio stream found.')) { Fail "no-audio message missing:`n$($r.Text)" }
    if (Test-Path -LiteralPath (Join-Path $Tmp 'no-audio.subtitles.mp3')) { Fail 'no-audio input created a final output' }

    $r = Run-Batch $Split @($Aac, '--segment-minutes', '1')
    if ($r.Code -ne 0) { Fail "SPLIT failed:`n$($r.Text)" }
    $Part1 = Join-Path $Tmp 'long-aac.part-001.mp3'
    $Part2 = Join-Path $Tmp 'long-aac.part-002.mp3'
    Assert-File $Part1
    Assert-File $Part2
    $parts = @(Get-ChildItem -LiteralPath $Tmp -File -Filter 'long-aac.part-*.mp3')
    Assert-Equal ([string]$parts.Count) '2' 'split segment count'
    foreach ($part in @($Part1, $Part2)) {
        Assert-Equal (Probe $part 'channels') '1' 'split channels'
        Assert-Equal (Probe $part 'sample_rate') '16000' 'split sample rate'
    }

    $r = Run-Batch $Split @($Aac, '--segment-minutes', '1')
    if ($r.Code -ne 0) { Fail "SPLIT collision run failed:`n$($r.Text)" }
    Assert-File (Join-Path $Tmp 'long-aac.split-2.part-001.mp3')

    $partials = @(Get-ChildItem -LiteralPath $Tmp -Recurse -Force | Where-Object { $_.Name -like '*.partial-*' -or $_.Name -like '.local-audio-extractor-*' })
    if ($partials.Count -ne 0) { Fail "temporary artifacts remained: $($partials.FullName -join ', ')" }

    Write-Output 'PASS: Windows local-audio-extractor smoke acceptance'
}
finally {
    if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Recurse -Force }
}