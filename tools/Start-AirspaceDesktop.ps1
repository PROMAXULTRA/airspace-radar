param([string]$SmokeOutputDirectory)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AirspaceFiles.ps1')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Path (Join-Path $PSScriptRoot 'AirspaceWorker.cs')

$projectRoot = Split-Path -Parent $PSScriptRoot
$engine = (Get-Command powershell.exe).Source
$workerScript = Join-Path $PSScriptRoot 'Start-Airspace.ps1'
$dataRoot = if ($SmokeOutputDirectory) { $SmokeOutputDirectory } else { Join-Path $projectRoot '.local\airspace-desktop' }
$dataRoot = [IO.Path]::GetFullPath($dataRoot)
[void][IO.Directory]::CreateDirectory($dataRoot)
$settingsFile = Join-Path $dataRoot 'settings.json'
$sessionDir = Join-Path $dataRoot ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sessionDir)
$frameFile = Join-Path $sessionDir 'airspace-latest.png'
$packetFile = Join-Path $sessionDir 'airspace-latest.ips'
$metaFile = Join-Path $sessionDir 'airspace-latest.json'
$stdoutFile = Join-Path $sessionDir 'worker.log'
$stderrFile = Join-Path $sessionDir 'worker-error.log'
$culture = [Globalization.CultureInfo]::InvariantCulture

$window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'AirspaceDesktop.xaml')))
if ($SmokeOutputDirectory) {
    $window.ShowInTaskbar = $false
    $window.WindowStartupLocation = 'Manual'
    $window.Left = -2000
    $window.Top = 0
}
$ui = @{}
foreach ($name in @(
    'RunStatus','ApplyButton','StopButton','SettingsNote','AirportCode','AirportName','AirportCoords','ChooseAirport',
    'SpanBox','RunwaysBox','NavaidsBox','TrailsBox','TiltedBox','WaterLinesBox','LiveMode','DemoMode','PollBox','RenderBox','PollHint',
    'UsbBox','PortBox','RefreshPorts','MapHeading','FrameImage','FrameEmpty','AircraftValue','PollValue','QuotaValue',
    'RunDetail','LogBox','Picker','ClosePicker','AirportSearch','SearchCount','AirportResults','SelectAirport',
    'LatitudeBox','LongitudeBox','UseCoordinates','CoordError','SettingsContent'
)) { $ui[$name] = $window.FindName($name) }

$aliases = @{
    JFK='纽约 肯尼迪'; LGA='纽约 拉瓜迪亚'; EWR='纽约 纽瓦克'; LAX='洛杉矶'; SFO='旧金山'
    SZX='深圳 宝安'; CAN='广州 白云'; HKG='香港 赤鱲角'; PVG='上海 浦东'; SHA='上海 虹桥'
    PEK='北京 首都'; PKX='北京 大兴'; TFU='成都 天府'; CTU='成都 双流'; CKG='重庆 江北'
    HND='东京 羽田'; NRT='东京 成田'; SIN='新加坡 樟宜'; ICN='首尔 仁川'; TPE='台北 桃园'
    LHR='伦敦 希思罗'; CDG='巴黎 戴高乐'; DXB='迪拜'; ATL='亚特兰大'
}
$pinned = @('KJFK','ZGSZ','ZGGG','VHHH','ZSPD','ZBAA','RJTT','KLAX','EGLL')
$catalog = [Collections.Generic.List[object]]::new()
$byId = @{}
foreach ($line in [IO.File]::ReadLines((Join-Path $PSScriptRoot 'data\desktop-airports.tsv'))) {
    if ($line.StartsWith('#')) { continue }
    $fields = $line.Split([char]9)
    if ($fields.Length -lt 8) { continue }
    $code = if ($fields[1]) { $fields[1] } else { $fields[0] }
    $codes = if ($fields[1]) { "$code / $($fields[0])" } else { $code }
    $entry = [pscustomobject]@{
        Id=$fields[0]; Code=$code; Codes=$codes; Title=$fields[4]; Place="$($fields[5]) · $($fields[6])"
        Latitude=[double]$fields[2]; Longitude=[double]$fields[3]
        Search="$codes $($fields[4]) $($fields[5]) $($fields[6]) $($aliases[$code])"
    }
    $catalog.Add($entry)
    $byId[$entry.Id] = $entry
}

$state = @{
    Airport=$byId['KJFK']; Process=$null; Bootstrap=$false; Applied=$null
    LastSequence=$null; NextPoll=$null; UiReady=$false; LastLogKey=''; SmokeStep=0
}
if (-not $state.Airport) { throw 'Airport directory is missing JFK.' }

function Set-AirportDisplay {
    $airport = $state.Airport
    $ui.AirportCode.Text = $airport.Codes
    $ui.AirportName.Text = $airport.Title
    $ui.AirportCoords.Text = ('{0:F4}, {1:F4}' -f $airport.Latitude,$airport.Longitude)
}

function Set-PortChoices([string]$preferred) {
    $ports = @([IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
    $ui.PortBox.Items.Clear()
    [void]$ui.PortBox.Items.Add('Auto-detect')
    foreach ($portName in $ports) { [void]$ui.PortBox.Items.Add($portName) }
    if ($preferred -match '^COM[0-9]+$' -and $preferred -notin $ports) { [void]$ui.PortBox.Items.Add($preferred) }
    if ($preferred -and $ui.PortBox.Items.Contains($preferred)) { $ui.PortBox.SelectedItem = $preferred }
    elseif ($ports -contains 'COM4') { $ui.PortBox.SelectedItem = 'COM4' }
    elseif ($ports.Count -eq 1) { $ui.PortBox.SelectedItem = $ports[0] }
    else { $ui.PortBox.SelectedIndex = 0 }
}

function New-CustomCenter([double]$latitude,[double]$longitude) {
    return [pscustomobject]@{Id='';Code='MAP';Codes='MAP';Title='Custom center';Latitude=$latitude;Longitude=$longitude}
}

function Restore-Settings {
    $preferredPort = ''
    if (Test-Path -LiteralPath $settingsFile -PathType Leaf) {
        try {
            $saved = [IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json
            if ($saved.AirportId -and $byId.ContainsKey([string]$saved.AirportId)) {
                $state.Airport = $byId[[string]$saved.AirportId]
            } elseif ($saved.AirportId -eq '' -and $null -ne $saved.Latitude -and $null -ne $saved.Longitude -and
                [Math]::Abs([double]$saved.Latitude) -le 90 -and [Math]::Abs([double]$saved.Longitude) -le 180) {
                $state.Airport = New-CustomCenter $saved.Latitude $saved.Longitude
            }
            foreach ($pair in @(@('SpanBox','Span'),@('PollBox','Poll'),@('RenderBox','Render'))) {
                $value = $saved.($pair[1])
                if ($null -ne $value) { $ui[$pair[0]].Text = [string]$value }
            }
            if ($saved.Mode -eq 'Demo') { $ui.DemoMode.IsChecked = $true }
            if ($null -ne $saved.Usb) { $ui.UsbBox.IsChecked = [bool]$saved.Usb }
            foreach ($name in @('Runways','Navaids','Trails','Tilted','WaterLines')) {
                if ($null -ne $saved.$name) { $ui[$name+'Box'].IsChecked = [bool]$saved.$name }
            }
            $preferredPort = if ($saved.Port -eq 'auto') {'Auto-detect'} else {[string]$saved.Port}
        } catch {
            $ui.SettingsNote.Text = 'Could not read saved settings. Using defaults.'
        }
    }
    Set-PortChoices $preferredPort
    Set-AirportDisplay
}

function Set-Pending {
    $ui.PortBox.IsEnabled = [bool]$ui.UsbBox.IsChecked
    $ui.RefreshPorts.IsEnabled = [bool]$ui.UsbBox.IsChecked
    $ui.PollBox.IsEnabled = [bool]$ui.LiveMode.IsChecked
    $ui.PollHint.Text = if ($ui.LiveMode.IsChecked) { 'Fetches use OpenSky credits. Rendering uses the latest received data.' } else { 'The offline demo uses simulated aircraft.' }
    if ($state.UiReady) { $ui.SettingsNote.Text = 'You have unapplied changes.' }
}

function Read-Integer($box,[int]$minimum,[int]$maximum,[string]$label) {
    $value = 0
    if (-not [int]::TryParse($box.Text.Trim(),[ref]$value) -or $value -lt $minimum -or $value -gt $maximum) {
        [void]$box.Focus()
        throw "$label must be an integer from $minimum to $maximum."
    }
    return $value
}

function Read-Settings {
    $settings = @{
        AirportId=$state.Airport.Id; Latitude=$state.Airport.Latitude; Longitude=$state.Airport.Longitude; Code=$state.Airport.Code
        Span=(Read-Integer $ui.SpanBox 5 1000 'View width')
        Render=(Read-Integer $ui.RenderBox 1 60 'Render interval'); Mode=if ($ui.LiveMode.IsChecked) {'Live'} else {'Demo'}
        Usb=[bool]$ui.UsbBox.IsChecked; Port='auto'
        Runways=[bool]$ui.RunwaysBox.IsChecked; Navaids=[bool]$ui.NavaidsBox.IsChecked; Trails=[bool]$ui.TrailsBox.IsChecked
        Tilted=[bool]$ui.TiltedBox.IsChecked; WaterLines=[bool]$ui.WaterLinesBox.IsChecked
    }
    $settings.Poll = if ($settings.Mode -eq 'Live') { Read-Integer $ui.PollBox 5 3600 'Fetch interval' } else {
        $demoPoll = 20
        if ([int]::TryParse($ui.PollBox.Text,[ref]$demoPoll) -and $demoPoll -ge 5 -and $demoPoll -le 3600) { $demoPoll } else { 20 }
    }
    if ($settings.Mode -eq 'Live' -and $settings.Render -gt $settings.Poll) { throw 'The render interval must not exceed the fetch interval.' }
    if ([string]$ui.PortBox.SelectedItem -match '^COM[0-9]+$') { $settings.Port = [string]$ui.PortBox.SelectedItem }
    return $settings
}

function Save-Settings($settings) {
    $temporary = Join-Path $sessionDir 'settings-write.json'
    [IO.File]::WriteAllText($temporary,($settings | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($settingsFile)) { [IO.File]::Replace($temporary,$settingsFile,[NullString]::Value) }
    else { [IO.File]::Move($temporary,$settingsFile) }
}

function Stop-Worker {
    $process = $state.Process
    if (-not $process) { return }
    if (-not $process.HasExited) {
        $process.Kill()
        if (-not $process.WaitForExit(1500)) { throw 'The previous task is still exiting. Try again shortly.' }
    }
    $process.Dispose()
    $state.Process = $null
    $state.NextPoll = $null
    $ui.StopButton.IsEnabled = $false
    $ui.ApplyButton.Content = 'Apply and start'
}

function Start-Worker($settings,[switch]$Bootstrap) {
    Stop-Worker
    foreach ($oldFile in @($frameFile,$packetFile,$metaFile,$stdoutFile,$stderrFile)) {
        if ([IO.File]::Exists($oldFile)) { [IO.File]::Delete($oldFile) }
    }
    $state.LastSequence = $null
    $state.LastLogKey = ''
    $state.NextPoll = $null
    $state.Bootstrap = [bool]$Bootstrap
    $state.Applied = $settings
    $ui.FrameImage.Source = $null
    $ui.FrameEmpty.Visibility = 'Visible'
    $ui.FrameEmpty.Text = 'Preparing preview...'
    $ui.MapHeading.Text = "$($settings.Code)  ·  $($settings.Span) km"
    $ui.AircraftValue.Text = '—'
    $ui.PollValue.Text = '—'
    $ui.QuotaValue.Text = '—'
    $ui.LogBox.Clear()
    $ui.RunStatus.Text = if ($Bootstrap) {'Preparing preview'} else {'Starting'}
    $ui.RunDetail.Text = if ($Bootstrap) {'Loading an offline demo frame.'} elseif ($settings.Usb) {'Opening the serial port and rendering the scene.'} else {'Generating the desktop preview.'}
    $workerArgs = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $workerScript + '"'),
        '-Mode',$settings.Mode,'-Port',$settings.Port,'-SpanKm',$settings.Span,
        '-PollSeconds',$settings.Poll,'-RenderSeconds',$settings.Render,
        '-OutputDirectory',('"' + $sessionDir + '"')
    )
    if ($settings.AirportId) { $workerArgs += @('-AirportIdent',$settings.AirportId) }
    else {
        $workerArgs += @('-CenterLatitude',([double]$settings.Latitude).ToString('R',$culture),
            '-CenterLongitude',([double]$settings.Longitude).ToString('R',$culture),'-MapLabel',$settings.Code)
    }
    if (-not $settings.Usb) { $workerArgs += '-PreviewOnly' }
    if (-not $settings.Runways) { $workerArgs += '-HideRunways' }
    if (-not $settings.Navaids) { $workerArgs += '-HideNavaids' }
    if (-not $settings.Trails) { $workerArgs += '-HideTrails' }
    if (-not $settings.Tilted) { $workerArgs += '-TopDown' }
    if (-not $settings.WaterLines) { $workerArgs += '-HideWaterLines' }
    if ($Bootstrap) { $workerArgs += @('-Once','-DemoSeconds','0') }
    $state.Process = [AirspaceWorker]::new($engine, ($workerArgs -join ' '), $projectRoot, $stdoutFile, $stderrFile)
    $ui.StopButton.IsEnabled = -not $Bootstrap
    if (-not $Bootstrap) { $ui.ApplyButton.Content = 'Apply and restart' }
}

function Read-LogTail([string]$file) {
    if (-not [IO.File]::Exists($file)) { return '' }
    $stream = [IO.File]::Open($file,'Open','Read','ReadWrite')
    try {
        [void]$stream.Seek([Math]::Max(0,$stream.Length-5500),'Begin')
        $reader = [IO.StreamReader]::new($stream,[Console]::OutputEncoding)
        try { return $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Refresh-RunStatus {
    $process = $state.Process
    if (-not $process) { return }
    try {
        $logKey = "$((Get-Item -LiteralPath $stdoutFile -ErrorAction SilentlyContinue).Length):$((Get-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue).Length)"
        if ($logKey -ne $state.LastLogKey) {
            $ui.LogBox.Text = (@((Read-LogTail $stdoutFile),(Read-LogTail $stderrFile)) -join [Environment]::NewLine).Trim()
            $ui.LogBox.ScrollToEnd()
            $state.LastLogKey = $logKey
        }
        if ([IO.File]::Exists($metaFile) -and [IO.File]::Exists($frameFile)) {
            $meta = Read-AirspaceSnapshotText $metaFile | ConvertFrom-Json
            if ($null -ne $meta.sequence -and $state.LastSequence -ne $meta.sequence) {
                $stream = [IO.File]::Open($frameFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,
                    ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                try {
                    $image = [Windows.Media.Imaging.BitmapImage]::new()
                    $image.BeginInit()
                    $image.CacheOption = 'OnLoad'
                    $image.StreamSource = $stream
                    $image.EndInit()
                    $image.Freeze()
                } finally { $stream.Dispose() }
                $ui.FrameImage.Source = $image
                $ui.FrameEmpty.Visibility = 'Collapsed'
                $state.LastSequence = $meta.sequence
                $ui.AircraftValue.Text = [string]$meta.displayed
                $ui.QuotaValue.Text = if ($meta.remainingCredits -ge 0) { [string]$meta.remainingCredits } else { '—' }
                if ($state.Applied.Mode -eq 'Live') { $state.NextPoll = [DateTimeOffset]::Now.AddSeconds([int]$meta.nextPollSeconds) }
                $ui.RunStatus.Text = switch ($meta.mode) {
                    'DEMO' { if ($state.Bootstrap) {'Ready'} else {'Offline demo'} }
                    'LIVE' { if ($meta.authenticated) {'Live - authenticated'} else {'Live - anonymous'} }
                    'OLD' {'Live - stale data'}
                    default {'Live - fetch failed'}
                }
                $outputLabel = if ($state.Applied.Usb) { 'Desktop + USB display' } else { 'Desktop only' }
                $ui.RunDetail.Text = if ($state.Bootstrap) {'Offline demo preview. Apply settings to start.'}
                    elseif ($meta.mode -eq 'LIVE' -or $meta.mode -eq 'OLD') { "$outputLabel - Data age $($meta.ageSeconds) s" }
                    elseif ($meta.mode -eq 'ERR') { "$outputLabel - Waiting for OpenSky. Expand the run log for details." }
                    else { "$outputLabel - Simulated aircraft" }
            }
        }
    } catch {
        # The worker can be replacing the image or metadata during this tick.
    }
    if ($state.NextPoll) {
        $ui.PollValue.Text = [string][Math]::Max(0,[Math]::Ceiling(($state.NextPoll-[DateTimeOffset]::Now).TotalSeconds)) + ' s'
    }
    if ($process.HasExited) {
        $exitCode = $process.ExitCode
        Stop-Worker
        $ui.PollValue.Text = '—'
        if ($exitCode -ne 0) {
            $ui.RunStatus.Text = 'Task exited'
            $ui.FrameEmpty.Text = 'The task could not generate a frame'
            $ui.RunDetail.Text = if ($ui.LogBox.Text.Contains('does not support IPS4')) {
                'Update the display firmware by uploading airspace_usb.ino in Arduino IDE.'
            } else {
                'Expand the run log for details. Only one program can use the display serial port at a time.'
            }
        }
    }
}

function Find-Airports {
    $query = $ui.AirportSearch.Text.Trim()
    if (-not $query) {
        $items = @($pinned | ForEach-Object { $byId[$_] } | Where-Object { $_ })
        $ui.SearchCount.Text = "Popular airports - $($catalog.Count) airports available"
    } else {
        $ranked = @(
            foreach ($airport in $catalog) {
                if ($airport.Search.IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $rank = if ($airport.Id -eq $query -or $airport.Code -eq $query) {0}
                        elseif ($airport.Code.StartsWith($query,[StringComparison]::OrdinalIgnoreCase) -or
                            $airport.Id.StartsWith($query,[StringComparison]::OrdinalIgnoreCase)) {1}
                        else {2}
                    [pscustomobject]@{ Rank=$rank; Airport=$airport }
                }
            }
        )
        $items = @($ranked | Sort-Object Rank | Select-Object -First 50 | ForEach-Object { $_.Airport })
        $ui.SearchCount.Text = if ($ranked.Count -eq 0) { 'No matching airports. You can also enter coordinates.' }
            elseif ($ranked.Count -gt $items.Count) { "Found $($ranked.Count), showing the first $($items.Count)." }
            else { "Matches found - $($ranked.Count)" }
    }
    $ui.AirportResults.ItemsSource = $items
    $ui.AirportResults.SelectedIndex = if ($items.Count) {0} else {-1}
    $ui.SelectAirport.IsEnabled = ($items.Count -gt 0)
}

function Close-AirportPicker {
    $ui.Picker.Visibility = 'Collapsed'
    $ui.SettingsContent.IsEnabled = $true
    [void]$ui.ChooseAirport.Focus()
}

function Choose-Airport($airport) {
    if (-not $airport) { return }
    $state.Airport = $airport
    Set-AirportDisplay
    Set-Pending
    Close-AirportPicker
}

Restore-Settings
Set-Pending
$state.UiReady = $true

$ui.ChooseAirport.Add_Click({
    $ui.SettingsContent.IsEnabled = $false
    $ui.Picker.Visibility = 'Visible'
    $ui.AirportSearch.Text = ''
    $ui.LatitudeBox.Text = ([double]$state.Airport.Latitude).ToString('0.######',$culture)
    $ui.LongitudeBox.Text = ([double]$state.Airport.Longitude).ToString('0.######',$culture)
    $ui.CoordError.Text = ''
    Find-Airports
    [void]$ui.AirportSearch.Focus()
})
$ui.ClosePicker.Add_Click({ Close-AirportPicker })
$ui.AirportSearch.Add_TextChanged({ Find-Airports })
$ui.AirportSearch.Add_KeyDown({
    param($sender,$eventArgs)
    if ($eventArgs.Key -eq 'Enter') { Choose-Airport $ui.AirportResults.SelectedItem; $eventArgs.Handled=$true }
    if ($eventArgs.Key -eq 'Down' -and $ui.AirportResults.SelectedItem) {
        $item = $ui.AirportResults.ItemContainerGenerator.ContainerFromItem($ui.AirportResults.SelectedItem)
        if ($item) { [void]$item.Focus(); $eventArgs.Handled=$true }
    }
})
$ui.SelectAirport.Add_Click({ Choose-Airport $ui.AirportResults.SelectedItem })
$ui.AirportResults.Add_MouseDoubleClick({ Choose-Airport $ui.AirportResults.SelectedItem })
$ui.AirportResults.Add_KeyDown({ param($sender,$eventArgs) if ($eventArgs.Key -eq 'Enter') { Choose-Airport $ui.AirportResults.SelectedItem; $eventArgs.Handled=$true } })
$window.Add_PreviewKeyDown({ param($sender,$eventArgs) if ($eventArgs.Key -eq 'Escape' -and $ui.Picker.Visibility -eq 'Visible') { Close-AirportPicker; $eventArgs.Handled=$true } })
$ui.UseCoordinates.Add_Click({
    $latitude = 0.0; $longitude = 0.0
    $style = [Globalization.NumberStyles]::Float
    if (-not [double]::TryParse($ui.LatitudeBox.Text,$style,$culture,[ref]$latitude) -or [double]::IsNaN($latitude) -or [Math]::Abs($latitude) -gt 90 -or
        -not [double]::TryParse($ui.LongitudeBox.Text,$style,$culture,[ref]$longitude) -or [double]::IsNaN($longitude) -or [Math]::Abs($longitude) -gt 180) {
        $ui.CoordError.Text = 'Enter valid coordinates, for example 22.6394 and 113.8033.'
        return
    }
    Choose-Airport (New-CustomCenter $latitude $longitude)
})
foreach ($name in @('SpanBox','PollBox','RenderBox')) { $ui[$name].Add_TextChanged({ Set-Pending }) }
foreach ($name in @('RunwaysBox','NavaidsBox','TrailsBox','TiltedBox','WaterLinesBox','LiveMode','DemoMode','UsbBox')) {
    $ui[$name].Add_Checked({ Set-Pending }); $ui[$name].Add_Unchecked({ Set-Pending })
}
$ui.PortBox.Add_SelectionChanged({ Set-Pending })
$ui.RefreshPorts.Add_Click({ Set-PortChoices ([string]$ui.PortBox.SelectedItem) })
$ui.ApplyButton.Add_Click({
    try {
        $settings = Read-Settings
        Start-Worker $settings
        try { Save-Settings $settings; $ui.SettingsNote.Text = 'Settings applied and saved.' }
        catch { $ui.SettingsNote.Text = 'Settings applied. Could not save them locally.' }
    } catch { $ui.SettingsNote.Text = $_.Exception.Message }
})
$ui.StopButton.Add_Click({
    try {
        Stop-Worker
        $ui.RunStatus.Text = 'Stopped'
        $ui.RunDetail.Text = 'The last frame remains visible.'
        $ui.PollValue.Text = '—'
    } catch { $ui.SettingsNote.Text = $_.Exception.Message }
})

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(350)
function Save-SmokeScreenshot([string]$name) {
    $window.UpdateLayout()
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
        [int][Math]::Ceiling($window.ActualWidth),[int][Math]::Ceiling($window.ActualHeight),
        96,96,[Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($window)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create((Join-Path $dataRoot $name))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

$smokeDeadline = [DateTimeOffset]::Now.AddSeconds(25)
$timer.Add_Tick({
    Refresh-RunStatus
    if (-not $SmokeOutputDirectory) { return }
    try {
        if ([DateTimeOffset]::Now -gt $smokeDeadline) { throw ('Desktop smoke test timed out. ' + $ui.LogBox.Text) }
        if ($state.SmokeStep -eq 0 -and $ui.FrameImage.Source -and -not $state.Process) {
            if ($ui.RunStatus.Text -ne 'Ready') { throw ('Bootstrap status was incorrect. ' + $ui.LogBox.Text) }
            Save-SmokeScreenshot 'desktop.png'
            $ui.ChooseAirport.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $ui.AirportSearch.Text = 'Shenzhen'
            if ($ui.AirportResults.SelectedItem.Id -ne 'ZGSZ') { throw 'Airport search did not find Shenzhen.' }
            Save-SmokeScreenshot 'airport-picker.png'
            $ui.SelectAirport.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $ui.DemoMode.IsChecked = $true
            $ui.SpanBox.Text = '137'
            $ui.PollBox.Text = '37'
            $ui.RenderBox.Text = '1'
            $ui.TrailsBox.IsChecked = $false
            $ui.TiltedBox.IsChecked = $false
            $ui.ApplyButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $state.SmokeStep = 1
        } elseif ($state.SmokeStep -eq 1 -and $state.LastSequence -ge 1 -and $ui.FrameImage.Source) {
            $meta = Read-AirspaceSnapshotText $metaFile | ConvertFrom-Json
            if ($meta.mapLabel -ne 'SZX' -or $meta.spanKm -ne 137 -or $meta.pollSeconds -ne 37 -or $meta.displayed -ne 6 -or $meta.trailCount -ne 0 -or $meta.tiltedView -or $meta.waterLineCount -le 0) {
                throw 'Desktop settings did not reach the renderer.'
            }
            $ui.StopButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            if ($state.Process -or $ui.RunStatus.Text -ne 'Stopped') { throw 'Stop did not release the worker.' }
            Save-Settings (Read-Settings)
            [Console]::WriteLine('Desktop smoke passed: search, preview, apply, stop, save, and frame updates.')
            $state.SmokeStep = 2
            $window.Close()
        }
    } catch {
        $state.SmokeStep = -1
        [Console]::Error.WriteLine($_.ToString())
        $window.Close()
    }
})
$window.Add_ContentRendered({
    try {
        $snapshot = Read-Settings
        $snapshot.Mode = 'Demo'
        $snapshot.Usb = $false
        Start-Worker $snapshot -Bootstrap
    } catch { $ui.RunStatus.Text='Preview failed';$ui.RunDetail.Text=$_.Exception.Message }
    $timer.Start()
})
$window.Add_Closing({
    param($sender,$eventArgs)
    try { Stop-Worker } catch { $eventArgs.Cancel=$true; $ui.SettingsNote.Text=$_.Exception.Message; return }
    $timer.Stop()
})

try {
    [void]$window.ShowDialog()
} finally {
    Stop-Worker
    foreach ($file in @($frameFile,$packetFile,$metaFile,$stdoutFile,$stderrFile,(Join-Path $sessionDir 'settings-write.json'))) {
        if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
    }
    [IO.Directory]::Delete($sessionDir)
}
if ($SmokeOutputDirectory -and $state.SmokeStep -ne 2) { exit 1 }
