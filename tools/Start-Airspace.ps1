param(
    [string]$Port = 'auto',
    [ValidateSet('Demo','Live')][string]$Mode = 'Demo',
    [ValidateSet('Airport','City','Nearby','Guangzhou','Baiyun','Shenzhen','NewYork','JFK')][string]$Region = 'NewYork',
    [ValidateRange(0,1000)][int]$SpanKm = 0,
    [ValidateRange(0,3600)][int]$PollSeconds = 0,
    [ValidateRange(1,60)][int]$RenderSeconds = 2,
    # Older command lines may still pass this argument. All targets are drawn.
    [Parameter(DontShow=$true)][int]$MaxAircraft,
    [double]$DemoSeconds = -1,
    [switch]$PreviewOnly,
    [switch]$Once,
    [string]$FixturePath = '',
    [string]$CredentialPath = '',
    [string]$OutputDirectory = '',
    [ValidatePattern('^[A-Za-z0-9_-]{1,16}$')][string]$AirportIdent,
    [ValidateRange(-90,90)][double]$CenterLatitude,
    [ValidateRange(-180,180)][double]$CenterLongitude,
    [ValidatePattern('^[A-Za-z0-9]{1,4}$')][string]$MapLabel = 'MAP',
    [switch]$HideRunways,
    [switch]$HideNavaids,
    [switch]$HideTrails,
    [switch]$TopDown,
    [switch]$HideWaterLines
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot '..\previews' }
. (Join-Path $PSScriptRoot 'AirspaceFiles.ps1')
. (Join-Path $PSScriptRoot 'OpenSkyCredentials.ps1')
Add-Type -AssemblyName System.Drawing
if (-not ('AirspaceRenderer' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'AirspaceRenderer.cs') -ReferencedAssemblies System.Drawing
}
if (-not ('AirspaceTransport' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'AirspaceTransport.cs') -ReferencedAssemblies ([IO.Ports.SerialPort].Assembly.Location)
}
$assets = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'data\airspace-assets.json') -Raw | ConvertFrom-Json
$newYorkReference = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'data\new-york-reference.json') -Raw | ConvertFrom-Json
$assets.runways = @($assets.runways) + @($newYorkReference.runways)
$assets.navaids = @($assets.navaids) + @($newYorkReference.navaids)
$regions = @{
    Airport = @{ Name='PVG'; Lon=121.805; Lat=31.1434; Span=20; Offsets=@(@(-6.7,5.5),@(6,5.8),@(-6,-5),@(6,-5),@(0,7.6)) }
    City = @{ Name='SHANGHAI'; Lon=121.58; Lat=31.18; Span=100; Offsets=@(@(-32,28),@(29,30),@(-29,-29),@(32,-22),@(0,5),@(0,-34)) }
    Nearby = @{ Name='NEARBY'; Lon=121.76; Lat=31.18; Span=50; Offsets=@(@(-15,13),@(16,16),@(-13,-13),@(16,-13),@(0,4),@(2,-17)) }
    Guangzhou = @{ Name='CAN'; Lon=113.299004; Lat=23.392401; Span=100; Offsets=@(@(-32,28),@(29,30),@(-29,-29),@(32,-22),@(0,5),@(0,-34)) }
    Baiyun = @{ Name='CAN'; Lon=113.299004; Lat=23.392401; Span=20; Offsets=@(@(-6.7,5.5),@(6,5.8),@(-6,-5),@(6,-5),@(0,7.6)) }
    Shenzhen = @{ Name='SZX'; Lon=113.803262; Lat=22.639474; Span=100; Offsets=@(@(-32,28),@(29,30),@(-29,-29),@(32,-22),@(0,5),@(0,-34)) }
    NewYork = @{ Name='JFK'; Lon=-73.779317; Lat=40.639447; Span=100; Offsets=@(@(-32,28),@(29,30),@(-29,-29),@(32,-22),@(0,5),@(0,-34)) }
}
$regions.JFK = $regions.NewYork
$view = $regions[$Region]
$hasLatitude = $PSBoundParameters.ContainsKey('CenterLatitude')
$hasLongitude = $PSBoundParameters.ContainsKey('CenterLongitude')
if ($hasLatitude -ne $hasLongitude -or ($AirportIdent -and $hasLatitude)) {
    throw 'Specify an airport, or both center coordinates.'
}
if ($AirportIdent -or $hasLatitude) {
    $view = $regions.NewYork.Clone()
    if ($AirportIdent) {
        $AirportIdent = $AirportIdent.ToUpperInvariant()
        $airportFile = Join-Path $PSScriptRoot 'data\desktop-airports.tsv'
        $match = Select-String -LiteralPath $airportFile -Encoding UTF8 -Pattern ('^' + [regex]::Escape($AirportIdent) + '\t') -List
        if (-not $match) { throw "Unknown airport: $AirportIdent" }
        $airport = $match.Line.Split([char]9)
        $view.Lat = [double]$airport[2]
        $view.Lon = [double]$airport[3]
        $view.Name = if ($airport[1]) { $airport[1] } else { $airport[0] }
        if ($airport[7]) {
            $assets.runways = @($assets.runways | Where-Object { $_.airport -ne $AirportIdent })
            foreach ($encoded in $airport[7].Split(';')) {
                $ends = $encoded.Split(',')
                $assets.runways += [pscustomobject]@{
                    lon1 = [double]$ends[0]; lat1 = [double]$ends[1]
                    lon2 = [double]$ends[2]; lat2 = [double]$ends[3]
                }
            }
        }
    } else {
        $view.Lat = $CenterLatitude
        $view.Lon = $CenterLongitude
        $view.Name = $MapLabel.ToUpperInvariant()
    }
}
if ($SpanKm -eq 0) { $SpanKm = $view.Span }
if ($SpanKm -lt 5) { throw 'SpanKm must be 0 (preset) or between 5 and 1000.' }
[double[][]]$waterLines = @()
if (-not $HideWaterLines) {
    [string[]]$mapFiles = @(
        (Join-Path $PSScriptRoot 'data\airspace-coast.gz'),
        (Join-Path $PSScriptRoot 'data\airspace-inland.gz')
    )
    $waterLines = [AirspaceRenderer]::LoadWaterLines($mapFiles,$view.Lon,$view.Lat,$SpanKm)
}
$demo = @(
    @{Id='CES5101';Alt=4200;Gs=238;Track=145;Vs=-350},
    @{Id='CCA1835';Alt=6100;Gs=302;Track=210;Vs=-600},
    @{Id='CSN3531';Alt=3400;Gs=221;Track=42;Vs=720},
    @{Id='DKH1267';Alt=7500;Gs=350;Track=80;Vs=0},
    @{Id='CES2298';Alt=8600;Gs=386;Track=18;Vs=900},
    @{Id='CSH9321';Alt=9800;Gs=420;Track=120;Vs=0}
)
$clientId = [Environment]::GetEnvironmentVariable('OPENSKY_CLIENT_ID')
$clientSecret = [Environment]::GetEnvironmentVariable('OPENSKY_CLIENT_SECRET')
if ([bool]$clientId -ne [bool]$clientSecret) { throw 'Set both OPENSKY_CLIENT_ID and OPENSKY_CLIENT_SECRET, or neither.' }
$credentialSource = if($clientId){'environment'}else{'none'}
if ($Mode -eq 'Live' -and -not $FixturePath -and -not $clientId) {
    $CredentialPath=Resolve-OpenSkyCredentialPath -RequestedPath $CredentialPath -ProjectRoot (Split-Path -Parent $PSScriptRoot)
    if($CredentialPath){
        $savedCredential=Import-OpenSkyClientCredential -Path $CredentialPath
        $clientId=$savedCredential.UserName
        $clientSecret=$savedCredential.GetNetworkCredential().Password
        $credentialSource=if([IO.Path]::GetExtension($CredentialPath) -ieq '.json'){'JSON file'}else{'saved XML file'}
    }
}
$authenticated = [bool]$clientId
if ($PollSeconds -eq 0) { $PollSeconds = 10 }
if ($Mode -eq 'Live') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Output "OpenSky live polling: every $PollSeconds seconds; authenticated=$authenticated"
    Write-Output "OpenSky credential source: $credentialSource"
    if($credentialSource -eq 'JSON file' -or $credentialSource -eq 'saved XML file'){Write-Output "OpenSky credential file: $CredentialPath"}
    if (-not $authenticated) {
        if(-not $FixturePath){Write-Warning 'No OpenSky credentials found. Use -CredentialPath .\airspace_usb\credentials.json, or run tools\Set-OpenSkyCredential.ps1 to save an encrypted XML file.'}
        $estimatedMinutes = [int][Math]::Floor(400 * $PollSeconds / 60)
        Write-Output "Anonymous quota: 400 small-area requests/day per public IP; a full quota lasts about $estimatedMinutes minutes at this interval. HTTP 429 triggers backoff."
    }
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$previewPath = Join-Path $OutputDirectory 'airspace-latest.png'
$packetPath = Join-Path $OutputDirectory 'airspace-latest.ips'
$script:token = $null
$script:tokenExpiry = [DateTimeOffset]::MinValue
$culture = [Globalization.CultureInfo]::InvariantCulture
$script:remainingCredits = -1

function Get-OpenSkyRemainingCredits($headers) {
    $credits=0
    if($null -ne $headers -and [int]::TryParse([string]$headers['X-Rate-Limit-Remaining'],[ref]$credits) -and $credits -ge 0){return $credits}
    return -1
}

function Get-OpenSkyResponse {
    $headers = @{}
    if ($authenticated) {
        if (-not $script:token -or [DateTimeOffset]::UtcNow -ge $script:tokenExpiry) {
            $tokenResult = Invoke-RestMethod -Method Post -Uri 'https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token' -ContentType 'application/x-www-form-urlencoded' -Body @{
                grant_type='client_credentials';client_id=$clientId;client_secret=$clientSecret
            } -TimeoutSec 20
            $script:token = $tokenResult.access_token
            $script:tokenExpiry = [DateTimeOffset]::UtcNow.AddSeconds([Math]::Max(1, [int]$tokenResult.expires_in - 60))
        }
        $headers.Authorization = 'Bearer ' + $script:token
    }
    # Cover the map corners and split the request at the date line if needed.
    $rad = [Math]::PI / 180
    $radius = ($SpanKm * 0.72) / 6371.0088
    $deltaLat = $radius / $rad
    $south = [Math]::Max(-90, $view.Lat - $deltaLat)
    $north = [Math]::Min(90, $view.Lat + $deltaLat)
    if ($south -eq -90 -or $north -eq 90) {
        $longitudeRanges = @(,@(-180,180))
    } else {
        $deltaLon = [Math]::Asin([Math]::Sin($radius) / [Math]::Cos($view.Lat * $rad)) / $rad
        $west = $view.Lon - $deltaLon
        $east = $view.Lon + $deltaLon
        if ($west -lt -180) { $longitudeRanges = @(@(($west+360),180), @(-180,$east)) }
        elseif ($east -gt 180) { $longitudeRanges = @(@($west,180), @(-180,($east-360))) }
        else { $longitudeRanges = @(,@($west,$east)) }
    }
    $states = [Collections.Generic.List[object]]::new()
    $sourceTime = [long]::MaxValue
    foreach ($range in $longitudeRanges) {
        $uri = 'https://opensky-network.org/api/states/all?lamin={0}&lomin={1}&lamax={2}&lomax={3}' -f @(
            $south.ToString('F6',$culture), $range[0].ToString('F6',$culture),
            $north.ToString('F6',$culture), $range[1].ToString('F6',$culture)
        )
        $httpResponse = Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers $headers -TimeoutSec 20
        $script:remainingCredits = Get-OpenSkyRemainingCredits $httpResponse.Headers
        $data = $httpResponse.Content | ConvertFrom-Json
        if ($null -eq $data.time -or -not ($data.PSObject.Properties.Name -contains 'states')) { throw 'Invalid OpenSky response shape.' }
        $sourceTime = [Math]::Min($sourceTime, [long]$data.time)
        foreach ($state in $data.states) { if ($null -ne $state) { $states.Add($state) } }
    }
    return [pscustomobject]@{ time = $sourceTime; states = $states.ToArray() }
}

function Get-LiveTargets($response) {
    $result = [System.Collections.Generic.List[AirspaceTarget]]::new()
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($row in $response.states) {
        if ($null -eq $row -or $row.Count -lt 14 -or $null -eq $row[3] -or $null -eq $row[5] -or $null -eq $row[6]) { continue }
        # Never turn a missing position or a very old position into a live target.
        if ($now - [long]$row[3] -gt 60 -or [bool]$row[8]) { continue }
        $target = [AirspaceTarget]::new()
        $target.Identity = [string]$row[0]
        $target.PositionTime = [long]$row[3]
        $target.Id = ([string]$row[1]).Trim() -replace '[^A-Za-z0-9-]', ''
        if (-not $target.Id) { $target.Id = [string]$row[0] }
        $target.Longitude = [double]$row[5]; $target.Latitude = [double]$row[6]
        if ($null -ne $row[7]) { $target.Altitude = [int]([Math]::Round([double]$row[7]/10)*10) }
        elseif ($null -ne $row[13]) { $target.Altitude = [int]([Math]::Round([double]$row[13]/10)*10) }
        if ($null -ne $row[10]) { $target.Track = ([int][Math]::Round([double]$row[10]) % 360 + 360) % 360 }
        if ([double]::IsNaN($target.Latitude) -or [double]::IsNaN($target.Longitude) -or [Math]::Abs($target.Latitude) -gt 90 -or [Math]::Abs($target.Longitude) -gt 180) { continue }
        $result.Add($target)
    }
    return ,$result
}

function Send-Frame([byte[]]$packet, [uint32]$sequence) {
    [AirspaceTransport]::Send($serial,$packet,$sequence)
}

$serial = $null
$lastUsbRevision = $null
try {
    if (-not $PreviewOnly) {
        if ($Port -eq 'auto') {
            $ports = @([IO.Ports.SerialPort]::GetPortNames())
            if ($ports.Count -ne 1) { throw ('Specify -Port COMx. Available ports: ' + ($ports -join ', ')) }
            $Port = $ports[0]
        }
        $serial = [IO.Ports.SerialPort]::new($Port,115200)
        $serial.ReadTimeout=1000; $serial.WriteTimeout=15000; $serial.DtrEnable=$true; $serial.RtsEnable=$false
        $serial.Open()
        Start-Sleep -Milliseconds 500
        Write-Output "USB display connected on $Port"
        $supported = if (-not $TopDown) { [AirspaceTransport]::SupportsTilt($serial) }
            elseif ($waterLines.Length -gt 0) { [AirspaceTransport]::SupportsTopDownWater($serial) }
            else { [AirspaceTransport]::SupportsScene($serial) }
        if (-not $supported) {
            throw 'Display does not support IPS4 for the selected view and map layers. Upload the updated airspace_usb sketch with USB CDC On Boot enabled.'
        }
        Write-Output 'USB display renders geographic scene data locally (IPS4).'
        [double[][]]$sceneRunways = @(if (-not $HideRunways) {
            foreach ($r in $assets.runways) { ,([double[]]@($r.lon1,$r.lat1,$r.lon2,$r.lat2)) }
        })
        [AirspaceSceneNavaid[]]$sceneNavaids = @(if (-not $HideNavaids) {
            foreach ($n in $assets.navaids) { [AirspaceSceneNavaid]::new($n.id,$n.lon,$n.lat) }
        })
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $nextPoll = [DateTimeOffset]::MinValue
    $liveTargets = @(); $sourceTime = 0L; $lastFailure = $false; $everReceived = $false
    $successfulQueries=0; $rawCount=0
    [uint32]$sequence = 0
    $labelLayout = [AirspaceLabelLayout]::new()
    $trailHistory = [AirspaceTrailHistory]::new([Math]::Max(120,$PollSeconds*2))
    do {
        $started = [DateTimeOffset]::UtcNow
        $targets = @(); $sceneMode = 'DEMO'; $age=0
        if ($Mode -eq 'Demo') {
            $seconds = if ($DemoSeconds -ge 0) { $DemoSeconds } else { $clock.Elapsed.TotalSeconds }
            $age = [int][Math]::Floor($seconds)
            for ($index=0; $index -lt $view.Offsets.Count; $index++) {
                $f=$demo[$index]; $offset=$view.Offsets[$index]
                $distance=$f.Gs*1.852/3600*$seconds; $angle=$f.Track*[Math]::PI/180
                $zoom = $SpanKm / $view.Span
                $coord=[AirspaceRenderer]::Offset($view.Lon,$view.Lat,$offset[0]*$zoom+[Math]::Sin($angle)*$distance,$offset[1]*$zoom+[Math]::Cos($angle)*$distance)
                $target=[AirspaceTarget]::new();$target.Id=$f.Id;$target.Longitude=$coord[0];$target.Latitude=$coord[1]
                $demoAltitude = if ($TopDown) { $f.Alt } else { @(300,5400,2400,12000,8500,4200)[$index] }
                $target.Altitude=[int]([Math]::Round(($demoAltitude+$f.Vs*$seconds/60)/10)*10);$target.Track=$f.Track
                if (-not $TopDown -and -not $HideTrails) {
                    $lookback = [Math]::Min(85,$SpanKm*0.8)
                    $past = $distance - $f.Gs*1.852/3600*$lookback
                    $old = [AirspaceRenderer]::Offset($view.Lon,$view.Lat,$offset[0]*$zoom+[Math]::Sin($angle)*$past,$offset[1]*$zoom+[Math]::Cos($angle)*$past)
                    $target.HasPreviousPosition = $true
                    $target.PreviousLongitude = $old[0]; $target.PreviousLatitude = $old[1]
                    $target.PreviousAltitude = [int][Math]::Max(0,$target.Altitude-$f.Vs*$lookback/60)
                    $target.PreviousTrack = ($f.Track + 360 + @(22,-26,18,-35,31,-22)[$index]) % 360
                }
                $targets += $target
            }
            if ($TopDown) { $trailHistory.Observe([AirspaceTarget[]]$targets,[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }
        } else {
            if ($started -ge $nextPoll) {
                $nextPoll=$started.AddSeconds($PollSeconds)
                try {
                    $response = if ($FixturePath) { Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json } else { Get-OpenSkyResponse }
                    if ($null -eq $response.time -or -not ($response.PSObject.Properties.Name -contains 'states')) { throw 'Invalid OpenSky response shape.' }
                    $rawCount=@($response.states | Where-Object {$null -ne $_}).Count
                    $liveTargets=@((Get-LiveTargets $response).ToArray());$sourceTime=[long]$response.time
                    $trailHistory.Observe([AirspaceTarget[]]$liveTargets,$sourceTime)
                    $lastFailure=$false;$everReceived=$true
                    $successfulQueries++
                    $apiAge=[Math]::Max(0,[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-$sourceTime)
                    Write-Output ("OpenSky update #{0}: raw={1}, fresh airborne={2}, API age={3}s" -f $successfulQueries,$rawCount,$liveTargets.Count,$apiAge)
                } catch {
                    $lastFailure=$true
                    # Do not print response bodies or auth headers: they may contain credentials.
                    $status=0
                    if ($_.Exception.Response) { $status=[int]$_.Exception.Response.StatusCode }
                    if ($_.Exception.Response) { $script:remainingCredits=Get-OpenSkyRemainingCredits $_.Exception.Response.Headers }
                    Write-Warning "OpenSky request failed (HTTP $status). Keeping old data; no demo fallback."
                    if ($status -eq 401) { $script:token=$null }
                    if ($status -eq 429) {
                        $retry=300
                        $responseHeaders=$_.Exception.Response.Headers
                        foreach($headerName in @('X-Rate-Limit-Retry-After-Seconds','Retry-After')) {
                            $candidate=0
                            if([int]::TryParse([string]$responseHeaders[$headerName],[ref]$candidate)) { $retry=[Math]::Max($retry,$candidate) }
                        }
                        $nextPoll=[DateTimeOffset]::UtcNow.AddSeconds($retry)
                    }
                }
            }
            $age=if($everReceived){[int][Math]::Min(9999,[Math]::Max(0,[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-$sourceTime))}else{0}
            $sceneMode=if(-not $everReceived){'ERR'}elseif($lastFailure -or $age -gt 60){'OLD'}else{'LIVE'}
            $targets=@($liveTargets)
        }
        if (-not $PreviewOnly) {
            $usbRevision = "$successfulQueries|$lastFailure|$script:remainingCredits"
            if ($Mode -eq 'Demo' -or $usbRevision -ne $lastUsbRevision) {
                $ageMs = if ($Mode -eq 'Live' -and $everReceived) {
                    [int][Math]::Max(0,[Math]::Min(9999999,[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $sourceTime * 1000L))
                } else { [int][Math]::Min(9999999,1000L * $age) }
                [byte[]]$scene = [AirspaceRenderer]::ScenePacket(
                    $sequence,$view.Name,$view.Lon,$view.Lat,$SpanKm,$sceneMode,$ageMs,$lastFailure,$script:remainingCredits,
                    (-not $HideTrails),$sceneRunways,$sceneNavaids,[AirspaceTarget[]]$targets,(-not $TopDown),$waterLines
                )
                Send-Frame $scene $sequence
                $lastUsbRevision = $usbRevision
            }
        }
        # The desktop preview is independent of the USB display.
        $renderer=[AirspaceRenderer]::new([byte[]]$assets.font,[uint16[]]$assets.planeMask,$view.Lon,$view.Lat,$SpanKm,$labelLayout)
        $renderer.ShowTrails = -not $HideTrails
        $renderer.TiltedView = -not $TopDown
        foreach ($line in $waterLines) { $renderer.WaterLine($line[0],$line[1],$line[2],$line[3]) }
        if (-not $HideRunways) { foreach($r in $assets.runways){$renderer.Runway($r.lon1,$r.lat1,$r.lon2,$r.lat2)} }
        if (-not $HideNavaids) { foreach($n in $assets.navaids){$renderer.Navaid($n.id,$n.lon,$n.lat)} }
        # Add rejects positions outside the viewport. Every accepted aircraft is drawn.
        foreach($target in $targets){[void]$renderer.Add($target)}
        $visibleCount = $renderer.Targets.Count
        $renderer.Finish($view.Name,$sceneMode,$age,$visibleCount,$SpanKm,$script:remainingCredits)
        [byte[]]$packet=[AirspaceRenderer]::Packet($renderer.Raw(),$sequence)
        $nextPollSeconds=if($Mode -eq 'Live'){[int][Math]::Max(0,[Math]::Ceiling(($nextPoll-[DateTimeOffset]::UtcNow).TotalSeconds))}else{0}
        $summary=@{mode=$sceneMode;tiltedView=(-not $TopDown);waterLineCount=$waterLines.Length;authenticated=$authenticated;remainingCredits=$script:remainingCredits;region=$Region;mapLabel=$view.Name;spanKm=$SpanKm;ageSeconds=$age;displayed=$visibleCount;available=$visibleCount;trailCount=$renderer.TrailCount;sequence=$sequence;pollSeconds=$PollSeconds;nextPollSeconds=$nextPollSeconds;successfulQueries=$successfulQueries;rawCount=$rawCount;labels=@($renderer.LabelBounds | ForEach-Object {@{x=$_.X;y=$_.Y;width=$_.Width;height=$_.Height}})}
        $summaryJson = $summary | ConvertTo-Json -Depth 5
        try {
            Write-AirspaceSnapshotFile $previewPath { param($path) $renderer.SavePng($path) }
            Write-AirspaceSnapshotFile $packetPath { param($path) [IO.File]::WriteAllBytes($path,$packet) }
            # Publish metadata last, after the corresponding preview is complete.
            Write-AirspaceSnapshotFile (Join-Path $OutputDirectory 'airspace-latest.json') {
                param($path)
                [IO.File]::WriteAllText($path,$summaryJson,[Text.UTF8Encoding]::new($false))
            }
        } catch [IO.IOException] {
            if (($_.Exception.GetBaseException().HResult -band 0xffff) -notin @(32,33)) { throw }
            Write-Warning 'Desktop snapshot is still locked. Skipping this preview update; polling and USB updates continue.'
        }
        $statusLine="{0}: {1} targets, age={2}s, frame={3}" -f $sceneMode,$visibleCount,$age,$sequence
        if($Mode -eq 'Live'){$quotaText=if($script:remainingCredits -ge 0){[string]$script:remainingCredits}else{'unknown'};$statusLine += "; next query in $nextPollSeconds s; successful queries=$successfulQueries; credits=$quotaText"}
        Write-Output $statusLine
        $sequence=if($sequence -eq [uint32]::MaxValue){0}else{$sequence+1}
        if(-not $Once){$remaining=$RenderSeconds-([DateTimeOffset]::UtcNow-$started).TotalSeconds;if($remaining -gt 0){Start-Sleep -Milliseconds ([int]($remaining*1000))}}
    } while(-not $Once)
} finally {
    if($serial){if($serial.IsOpen){$serial.Close()};$serial.Dispose()}
}
