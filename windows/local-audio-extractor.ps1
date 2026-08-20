[CmdletBinding()]
param(
    [string]$InputPath,
    [switch]$ProbeUi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    throw 'Local Audio Extractor UI requires an STA PowerShell host. Use powershell.exe -STA.'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$XamlPath = Join-Path $ScriptRoot 'ui\MainWindow.xaml'

if (-not (Test-Path -LiteralPath $XamlPath -PathType Leaf)) {
    throw "UI layout not found: $XamlPath"
}

[xml]$Xaml = Get-Content -LiteralPath $XamlPath -Raw -Encoding UTF8
$Reader = New-Object System.Xml.XmlNodeReader $Xaml
$Window = [Windows.Markup.XamlReader]::Load($Reader)

$NamedControls = @(
    'RuntimePill','RuntimeDot','RuntimeText',
    'DropZone','EmptyState','FileState','BrowseButton','ReplaceButton','ClearButton',
    'FileNameText','FileMetaText','SourceFooter',
    'ModeFast','ModeSubtitles','ModeSplit','SplitSettings','SegmentMinutes',
    'SummaryOutput','SummaryRate','SummaryFilename',
    'StartButton','HintText','StatusBox','StatusTitle','StatusValue','ProgressBar','StatusMessage',
    'OpenFolderButton'
)

$Controls = @{}
foreach ($Name in $NamedControls) {
    $Control = $Window.FindName($Name)
    if ($null -eq $Control) { throw "UI control missing: $Name" }
    $Controls[$Name] = $Control
}

if ($ProbeUi) {
    Write-Output 'PASS: Windows B UI XAML loaded and required controls resolved'
    exit 0
}

function New-Brush([string]$Color) {
    return (New-Object Windows.Media.BrushConverter).ConvertFromString($Color)
}

$AccentBrush = New-Brush '#68D8B8'
$AccentSoftBrush = New-Brush '#1A2929'
$Panel2Brush = New-Brush '#1B222D'
$LineBrush = New-Brush '#293341'
$LineStrongBrush = New-Brush '#354253'
$DangerBrush = New-Brush '#FF8F8F'
$WarningBrush = New-Brush '#F4C86B'

$State = [pscustomobject]@{
    InputPath = $null
    Mode = 'subtitles'
    Processing = $false
    Process = $null
    StdoutTask = $null
    StderrTask = $null
    LastOutputDirectory = $null
}

$ModeInfo = @{
    fast = @{
        Script = 'extract-fast.bat'
        Output = 'MKA - Original audio'
        Rate = 'Original audio'
        Suffix = '.audio.mka'
        Label = 'Fast Copy'
    }
    subtitles = @{
        Script = 'extract-for-subtitles.bat'
        Output = 'MP3 - Mono'
        Rate = '16 kHz - 64 kbps'
        Suffix = '.subtitles.mp3'
        Label = 'Subtitle Ready'
    }
    split = @{
        Script = 'extract-split.bat'
        Output = 'MP3 - Mono - Segmented'
        Rate = '16 kHz - 64 kbps'
        Suffix = '.part-001.mp3'
        Label = 'Split'
    }
}

function Format-Bytes([long]$Bytes) {
    $Units = @('B','KB','MB','GB','TB')
    $Value = [double]$Bytes
    $Index = 0
    while ($Value -ge 1024 -and $Index -lt ($Units.Count - 1)) {
        $Value /= 1024
        $Index++
    }
    if ($Index -eq 0) { return ('{0:0} {1}' -f $Value, $Units[$Index]) }
    if ($Value -ge 100) { return ('{0:0} {1}' -f $Value, $Units[$Index]) }
    if ($Value -ge 10) { return ('{0:0.0} {1}' -f $Value, $Units[$Index]) }
    return ('{0:0.00} {1}' -f $Value, $Units[$Index])
}

function Get-PredictedName {
    if (-not $State.InputPath) { return 'Waiting for video' }
    $Base = [IO.Path]::GetFileNameWithoutExtension($State.InputPath)
    if ($State.Mode -eq 'split') { return "$Base.part-001.mp3" }
    return "$Base$($ModeInfo[$State.Mode].Suffix)"
}

function Test-FfmpegReady {
    $Ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if (-not $Ffmpeg) { $Ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue }
    $Ffprobe = Get-Command ffprobe.exe -ErrorAction SilentlyContinue
    if (-not $Ffprobe) { $Ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue }
    return [bool]($Ffmpeg -and $Ffprobe)
}

$FfmpegReady = Test-FfmpegReady

function Update-RuntimeState {
    if ($FfmpegReady) {
        $Controls.RuntimePill.BorderBrush = New-Brush '#295044'
        $Controls.RuntimePill.Background = New-Brush '#11241E'
        $Controls.RuntimeDot.Fill = $AccentBrush
        $Controls.RuntimeText.Foreground = New-Brush '#91E5CC'
        $Controls.RuntimeText.Text = 'FFmpeg Ready'
    } else {
        $Controls.RuntimePill.BorderBrush = New-Brush '#4A4430'
        $Controls.RuntimePill.Background = New-Brush '#211D13'
        $Controls.RuntimeDot.Fill = $WarningBrush
        $Controls.RuntimeText.Foreground = New-Brush '#E8CC8C'
        $Controls.RuntimeText.Text = 'FFmpeg Missing'
    }
}

function Set-Status(
    [string]$Title,
    [string]$Message,
    [ValidateSet('normal','error','success')] [string]$Kind = 'normal',
    [bool]$Busy = $false
) {
    $Controls.StatusBox.Visibility = [Windows.Visibility]::Visible
    $Controls.StatusTitle.Text = $Title
    $Controls.StatusMessage.Text = $Message
    if ($Busy) { $Controls.StatusValue.Text = 'RUNNING' }
    elseif ($Kind -eq 'success') { $Controls.StatusValue.Text = 'DONE' }
    else { $Controls.StatusValue.Text = '' }
    $Controls.ProgressBar.IsIndeterminate = $Busy
    $Controls.ProgressBar.Visibility = if ($Busy) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Controls.StatusTitle.Foreground = if ($Kind -eq 'error') { $DangerBrush } else { [Windows.Media.Brushes]::White }
    $Controls.StatusBox.BorderBrush = if ($Kind -eq 'error') { $DangerBrush } else { $LineBrush }
}

function Clear-Status {
    if ($State.Processing) { return }
    $Controls.StatusBox.Visibility = [Windows.Visibility]::Collapsed
    $Controls.OpenFolderButton.Visibility = [Windows.Visibility]::Collapsed
}

function Update-Ui {
    $Info = $ModeInfo[$State.Mode]
    $Controls.SummaryOutput.Text = $Info.Output
    $Controls.SummaryRate.Text = $Info.Rate
    $Controls.SummaryFilename.Text = Get-PredictedName
    $Controls.SplitSettings.Visibility = if ($State.Mode -eq 'split') { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }

    foreach ($Entry in @(
        @($Controls.ModeFast, 'fast'),
        @($Controls.ModeSubtitles, 'subtitles'),
        @($Controls.ModeSplit, 'split')
    )) {
        $Button = $Entry[0]
        $Mode = $Entry[1]
        if ($State.Mode -eq $Mode) {
            $Button.Background = $AccentSoftBrush
            $Button.BorderBrush = $AccentBrush
            $Button.BorderThickness = '1.5'
        } else {
            $Button.Background = $Panel2Brush
            $Button.BorderBrush = $LineBrush
            $Button.BorderThickness = '1'
        }
        $Button.IsEnabled = -not $State.Processing
    }

    $HasFile = [bool]$State.InputPath
    $Controls.StartButton.IsEnabled = ($HasFile -and $FfmpegReady -and -not $State.Processing)
    $Controls.BrowseButton.IsEnabled = -not $State.Processing
    $Controls.ReplaceButton.IsEnabled = -not $State.Processing
    $Controls.ClearButton.IsEnabled = -not $State.Processing
    $Controls.SegmentMinutes.IsEnabled = -not $State.Processing

    if (-not $FfmpegReady) {
        $Controls.HintText.Text = 'Install FFmpeg first: winget install Gyan.FFmpeg'
    } elseif (-not $HasFile) {
        $Controls.HintText.Text = 'Choose or drop a video to begin'
    } elseif ($State.Processing) {
        $Controls.HintText.Text = 'Processing locally - no upload'
    } else {
        $Controls.HintText.Text = "$($Info.Label) - output stays beside the source video"
    }
}

function Set-Mode([string]$Mode) {
    if ($State.Processing -or -not $ModeInfo.ContainsKey($Mode)) { return }
    $State.Mode = $Mode
    Clear-Status
    Update-Ui
}

function Set-InputFile([string]$Path) {
    if ($State.Processing -or -not $Path) { return }
    try {
        $Item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($Item.PSIsContainer) { throw 'Select a video file, not a directory.' }
    } catch {
        Set-Status 'File unavailable' $_.Exception.Message 'error' $false
        return
    }

    $State.InputPath = $Item.FullName
    $State.LastOutputDirectory = $Item.DirectoryName
    $Controls.EmptyState.Visibility = [Windows.Visibility]::Collapsed
    $Controls.FileState.Visibility = [Windows.Visibility]::Visible
    $Controls.FileNameText.Text = $Item.Name
    $Ext = $Item.Extension.TrimStart('.').ToUpperInvariant()
    if (-not $Ext) { $Ext = 'VIDEO' }
    $Controls.FileMetaText.Text = "$Ext - $(Format-Bytes $Item.Length)"
    $Controls.SourceFooter.Text = 'Selected - local only - output stays beside the source video'
    Clear-Status
    Update-Ui
}

function Clear-InputFile {
    if ($State.Processing) { return }
    $State.InputPath = $null
    $State.LastOutputDirectory = $null
    $Controls.EmptyState.Visibility = [Windows.Visibility]::Visible
    $Controls.FileState.Visibility = [Windows.Visibility]::Collapsed
    $Controls.SourceFooter.Text = 'Waiting for video - output stays beside the source video'
    Clear-Status
    Update-Ui
}

function Select-InputFile {
    if ($State.Processing) { return }
    $Dialog = New-Object Microsoft.Win32.OpenFileDialog
    $Dialog.Title = 'Select video'
    $Dialog.Filter = 'Video files|*.mp4;*.mkv;*.mov;*.webm;*.avi;*.m4v;*.ts;*.mts;*.m2ts|All files|*.*'
    $Dialog.Multiselect = $false
    if ($Dialog.ShowDialog($Window)) { Set-InputFile $Dialog.FileName }
}

function Get-ProcessMessage([string]$Stdout, [string]$Stderr) {
    $Text = (($Stdout, $Stderr) -join "`r`n").Trim()
    if (-not $Text) { return 'FFmpeg returned no additional message.' }
    $Lines = @($Text -split "`r?`n" | Where-Object { $_.Trim() })
    $Important = @($Lines | Where-Object { $_ -match '^(ERROR:|No audio stream found\.|Success:|Output:|Output pattern:)' })
    if ($Important.Count -gt 0) { return ($Important[-1]).Trim() }
    return ($Lines[-1]).Trim()
}

function Start-Extraction {
    if ($State.Processing -or -not $State.InputPath) { return }
    if (-not $FfmpegReady) {
        Set-Status 'FFmpeg not found' 'Run: winget install Gyan.FFmpeg' 'error' $false
        return
    }

    $Segment = 30
    if ($State.Mode -eq 'split') {
        if (-not [int]::TryParse($Controls.SegmentMinutes.Text, [ref]$Segment) -or $Segment -lt 1 -or $Segment -gt 1440) {
            Set-Status 'Invalid split setting' 'Segment minutes must be an integer from 1 to 1440.' 'error' $false
            return
        }
    }

    $ScriptPath = Join-Path $ScriptRoot $ModeInfo[$State.Mode].Script
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        Set-Status 'Extraction script missing' $ScriptPath 'error' $false
        return
    }

    $Psi = New-Object System.Diagnostics.ProcessStartInfo
    $Psi.FileName = $env:ComSpec
    $Psi.UseShellExecute = $false
    $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardOutput = $true
    $Psi.RedirectStandardError = $true
    $Psi.WorkingDirectory = $RepoRoot
    $Psi.EnvironmentVariables['LAE_SCRIPT'] = $ScriptPath
    $Psi.EnvironmentVariables['LAE_INPUT'] = $State.InputPath
    if ($State.Mode -eq 'split') {
        $Psi.EnvironmentVariables['LAE_SEGMENT'] = [string]$Segment
        $Psi.Arguments = '/d /s /c call "%LAE_SCRIPT%" "%LAE_INPUT%" --segment-minutes %LAE_SEGMENT%'
    } else {
        $Psi.Arguments = '/d /s /c call "%LAE_SCRIPT%" "%LAE_INPUT%"'
    }

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $Psi

    try {
        if (-not $Process.Start()) { throw 'Could not start extraction process.' }
        $State.Process = $Process
        $State.StdoutTask = $Process.StandardOutput.ReadToEndAsync()
        $State.StderrTask = $Process.StandardError.ReadToEndAsync()
        $State.Processing = $true
        $State.LastOutputDirectory = [IO.Path]::GetDirectoryName($State.InputPath)
        $Controls.OpenFolderButton.Visibility = [Windows.Visibility]::Collapsed
        Set-Status 'Processing' "Running $($ModeInfo[$State.Mode].Label) locally" 'normal' $true
        Update-Ui
    } catch {
        $State.Process = $null
        $State.StdoutTask = $null
        $State.StderrTask = $null
        $State.Processing = $false
        Set-Status 'Could not start' $_.Exception.Message 'error' $false
        Update-Ui
    }
}

$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(250)
$Timer.Add_Tick({
    if (-not $State.Processing -or $null -eq $State.Process) { return }
    if (-not $State.Process.HasExited) { return }

    $Timer.Stop()
    $State.StdoutTask.Wait(1500) | Out-Null
    $State.StderrTask.Wait(1500) | Out-Null
    $Stdout = if ($State.StdoutTask.IsCompleted) { [string]$State.StdoutTask.Result } else { '' }
    $Stderr = if ($State.StderrTask.IsCompleted) { [string]$State.StderrTask.Result } else { '' }
    $ExitCode = $State.Process.ExitCode
    $Message = Get-ProcessMessage $Stdout $Stderr

    try { $State.Process.Dispose() } catch {}
    $State.Process = $null
    $State.StdoutTask = $null
    $State.StderrTask = $null
    $State.Processing = $false

    if ($ExitCode -eq 0) {
        Set-Status 'Complete' $Message 'success' $false
        $Controls.OpenFolderButton.Visibility = [Windows.Visibility]::Visible
    } else {
        Set-Status 'Extraction failed' $Message 'error' $false
    }
    Update-Ui
})

$Controls.BrowseButton.Add_Click({ Select-InputFile })
$Controls.ReplaceButton.Add_Click({ Select-InputFile })
$Controls.ClearButton.Add_Click({ Clear-InputFile })
$Controls.ModeFast.Add_Click({ Set-Mode 'fast' })
$Controls.ModeSubtitles.Add_Click({ Set-Mode 'subtitles' })
$Controls.ModeSplit.Add_Click({ Set-Mode 'split' })
$Controls.StartButton.Add_Click({
    Start-Extraction
    if ($State.Processing) { $Timer.Start() }
})
$Controls.OpenFolderButton.Add_Click({
    if ($State.LastOutputDirectory -and (Test-Path -LiteralPath $State.LastOutputDirectory -PathType Container)) {
        Start-Process -FilePath explorer.exe -ArgumentList @($State.LastOutputDirectory)
    }
})

$Controls.DropZone.Add_MouseLeftButtonUp({
    if (-not $State.Processing -and -not $State.InputPath) { Select-InputFile }
})
$Controls.DropZone.Add_DragOver({
    param($Sender, $EventArgs)
    if (-not $State.Processing -and $EventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        $EventArgs.Effects = [Windows.DragDropEffects]::Copy
        $Controls.DropZone.BorderBrush = $AccentBrush
    } else {
        $EventArgs.Effects = [Windows.DragDropEffects]::None
    }
    $EventArgs.Handled = $true
})
$Controls.DropZone.Add_DragLeave({
    if (-not $State.Processing) { $Controls.DropZone.BorderBrush = $LineStrongBrush }
})
$Controls.DropZone.Add_Drop({
    param($Sender, $EventArgs)
    $Controls.DropZone.BorderBrush = $LineStrongBrush
    if ($State.Processing -or -not $EventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { return }
    $Paths = @($EventArgs.Data.GetData([Windows.DataFormats]::FileDrop))
    if ($Paths.Count -gt 0) { Set-InputFile ([string]$Paths[0]) }
    $EventArgs.Handled = $true
})
$Window.Add_Drop({
    param($Sender, $EventArgs)
    if ($State.Processing -or -not $EventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { return }
    $Paths = @($EventArgs.Data.GetData([Windows.DataFormats]::FileDrop))
    if ($Paths.Count -gt 0) { Set-InputFile ([string]$Paths[0]) }
    $EventArgs.Handled = $true
})
$Window.Add_Closing({
    param($Sender, $EventArgs)
    if ($State.Processing -and $State.Process -and -not $State.Process.HasExited) {
        [Windows.MessageBox]::Show(
            $Window,
            'FFmpeg is still processing. Keep this window open until the current extraction completes.',
            'Extraction in progress',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Information
        ) | Out-Null
        $EventArgs.Cancel = $true
    }
})

Update-RuntimeState
Set-Mode 'subtitles'
if ($InputPath) { Set-InputFile $InputPath }

$null = $Window.ShowDialog()
