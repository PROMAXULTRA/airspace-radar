param([string]$PreviewPath='')
$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Add-Type -AssemblyName System.Drawing
if(-not ('AirspaceRenderer' -as [type])){Add-Type -Path (Join-Path $project 'tools\AirspaceRenderer.cs') -ReferencedAssemblies System.Drawing}
$assets=Get-Content -LiteralPath (Join-Path $project 'tools\data\airspace-assets.json') -Raw | ConvertFrom-Json
function Check($condition,$message){if(-not $condition){throw $message}}
function New-Target($east,$north,$altitude,$time,$identity='abc123',$callsign='TEST123'){
    $coordinate=[AirspaceRenderer]::Offset(113.803262,22.639474,$east,$north)
    $target=[AirspaceTarget]::new();$target.Identity=$identity;$target.Id=$callsign
    $target.Longitude=$coordinate[0];$target.Latitude=$coordinate[1];$target.Altitude=$altitude;$target.PositionTime=$time;$target.Track=90
    return $target
}
function New-Renderer {return [AirspaceRenderer]::new([byte[]]$assets.font,[uint16[]]$assets.planeMask,113.803262,22.639474,100)}
$history=[AirspaceTrailHistory]::new()
$old=New-Target -30 0 0 1000
$history.Observe([AirspaceTarget[]]@($old),1000)
Check (-not $old.HasPreviousPosition) 'First observation must not have a trail'
$current=New-Target 0 0 12000 1020 'abc123' 'RENAMED'
$history.Observe([AirspaceTarget[]]@($current),1020)
Check ($current.HasPreviousPosition -and $current.PreviousLongitude -eq $old.Longitude -and $current.PreviousAltitude -eq 0 -and $current.PreviousTrack -eq 90) 'Same ICAO address must connect with previous altitude and direction despite callsign change'
$renderer=New-Renderer;[void]$renderer.Add($current);$renderer.Finish('SZX','LIVE',0,1,100,3995)
Check ($renderer.TrailCount -eq 1) 'Latest segment was not rendered'
$raw=$renderer.Raw();$oldCenter=$renderer.Project($old.Longitude,$old.Latitude)
$start=[AirspaceRenderer]::TailPoint($oldCenter.X,$oldCenter.Y,$old.Track)
$end=[AirspaceRenderer]::TailPoint($current.X,$current.Y,$current.Track)
$x0=[int][Math]::Round($start.X);$y0=[int][Math]::Round($start.Y);$x1=[int][Math]::Round($end.X)
for($x=$x0;$x -le 100;$x++){
    $expectedAltitude=[int][Math]::Round(12000.0*($x-$x0)/($x1-$x0))
    Check ([BitConverter]::ToUInt16($raw,2*($y0*240+$x)) -eq [AirspaceRenderer]::AltitudeColor($expectedAltitude)) 'Trail does not follow altitude gradient from the old endpoint'
}
Check ([BitConverter]::ToUInt16($raw,2*([int][Math]::Round($end.Y)*240+$x1)) -eq [AirspaceRenderer]::AltitudeColor(12000)) 'Current tail endpoint must match current aircraft colour'
foreach($case in @(@(0,120,139),@(90,113,132),@(180,120,125),@(270,127,132))){
    $tail=[AirspaceRenderer]::TailPoint(120,132,$case[0])
    Check ([Math]::Abs($tail.X-$case[1]) -lt 0.01 -and [Math]::Abs($tail.Y-$case[2]) -lt 0.01) 'Tail anchor did not rotate with aircraft direction'
}
$cached=New-Target 0 0 12000 1020
$history.Observe([AirspaceTarget[]]@($cached),1030)
Check ($cached.HasPreviousPosition -and $cached.PreviousLongitude -eq $old.Longitude -and $cached.PreviousAltitude -eq 0) 'Duplicate API observations must retain the last segment'
$third=New-Target 3 0 9000 1040
$third.Track=180
$history.Observe([AirspaceTarget[]]@($third),1040)
Check ($third.HasPreviousPosition -and $third.PreviousLongitude -eq $current.Longitude -and $third.PreviousAltitude -eq 12000 -and $third.PreviousTrack -eq 90) 'New observations must retain old direction and replace the segment rather than accumulating history'
$other=New-Target 4 0 6000 1060 'different-icao' 'RENAMED'
$history.Observe([AirspaceTarget[]]@($other),1060)
Check (-not $other.HasPreviousPosition) 'Matching callsigns must not connect different aircraft'
$history.Observe([AirspaceTarget[]]@(),1080)
$returned=New-Target 6 0 6000 1100 'different-icao'
$history.Observe([AirspaceTarget[]]@($returned),1100)
Check (-not $returned.HasPreviousPosition) 'Reappearing aircraft must start without a trail'
$gap=New-Target 7 0 3000 1300 'different-icao'
$history.Observe([AirspaceTarget[]]@($gap),1300)
Check (-not $gap.HasPreviousPosition) 'Excessive source time gaps must break the trail'
$backward=New-Target 8 0 3000 1290 'different-icao'
$history.Observe([AirspaceTarget[]]@($backward),1300)
Check (-not $backward.HasPreviousPosition) 'Out-of-order positions must not create a backwards segment'

# Lines from outside the map must retain the correct gradient position, while
# all top-bar and legend pixels remain identical to a frame without the line.
foreach($offset in @(@(-120,0),@(120,120),@(0,-120))){
    $clipped=New-Target 0 0 12000 2000
    $previous=[AirspaceRenderer]::Offset(113.803262,22.639474,$offset[0],$offset[1])
    $clipped.HasPreviousPosition=$true;$clipped.PreviousLongitude=$previous[0];$clipped.PreviousLatitude=$previous[1];$clipped.PreviousAltitude=0;$clipped.PreviousTrack=90
    $clippedRenderer=New-Renderer;[void]$clippedRenderer.Add($clipped);$clippedRenderer.Finish('SZX','LIVE',0,1,100)
    Check ($clippedRenderer.TrailCount -eq 1) 'Off-screen starting point was not clipped'
    $clippedRaw=$clippedRenderer.Raw()
    $baseline=New-Renderer;$control=New-Target 0 0 12000 2000;[void]$baseline.Add($control);$baseline.Finish('SZX','LIVE',0,1,100);$baseRaw=$baseline.Raw()
    for($y=0;$y -lt 240;$y++){for($x=0;$x -lt 240;$x++){
        if($y -lt 24 -or $x -gt [AirspaceRenderer]::MapRight){
            $at=2*($y*240+$x)
            Check ([BitConverter]::ToUInt16($clippedRaw,$at) -eq [BitConverter]::ToUInt16($baseRaw,$at)) 'Trail overwrote header or altitude legend'
        }
    }}
    if($offset[0] -eq -120){
        $point=$clippedRenderer.Project($previous[0],$previous[1]);$point=[AirspaceRenderer]::TailPoint($point.X,$point.Y,90);$fraction=(0-$point.X)/(113-$point.X)
        $expected=[AirspaceRenderer]::AltitudeColor([int][Math]::Round(12000*$fraction))
        Check ([BitConverter]::ToUInt16($clippedRaw,2*(132*240)) -eq $expected) 'Clipping restarted the gradient instead of preserving its altitude'
    }
}
$unknown=New-Target 0 0 6000 2000
$unknown.HasPreviousPosition=$true;$unknown.PreviousLongitude=$old.Longitude;$unknown.PreviousLatitude=$old.Latitude
$unknown.PreviousTrack=90
$unknownRenderer=New-Renderer;[void]$unknownRenderer.Add($unknown);$unknownRenderer.Finish('SZX','LIVE',0,1,100)
Check ([BitConverter]::ToUInt16($unknownRenderer.Raw(),2*($y0*240+$x0)) -eq 0xAD55) 'Unknown altitude endpoint must be grey'

# A climb can change the visible altitude even if the two ground positions match.
$climb=New-Target 0 0 12000 2020 'climb-test' 'CLIMB'
$climb.Track=0; $climb.PreviousTrack=0; $climb.PreviousAltitude=0
$climb.HasPreviousPosition=$true; $climb.PreviousLongitude=$climb.Longitude; $climb.PreviousLatitude=$climb.Latitude
$tiltRenderer=New-Renderer; $tiltRenderer.TiltedView=$true
[void]$tiltRenderer.Add($climb); $tiltRenderer.Finish('SZX','LIVE',0,1,100)
Check ($tiltRenderer.TrailCount -eq 1) '3D rendering lost a vertical trail'
$tailGeo=[AirspaceRenderer]::Offset($climb.Longitude,$climb.Latitude,0,-7/2.32)
$climbRaw=$tiltRenderer.Raw()
foreach($altitude in @(0,12000)){
    $tail=$tiltRenderer.ProjectOnDisplay($tailGeo[0],$tailGeo[1],$altitude)
    $at=2*([int][Math]::Round($tail.Y)*240+[int][Math]::Round($tail.X))
    Check ([BitConverter]::ToUInt16($climbRaw,$at) -eq [AirspaceRenderer]::AltitudeColor($altitude)) '3D trail missed a tail endpoint or its altitude colour'
}

# A short callsign leaves blank space inside its layout box. A trail through
# that space must stay visible all the way through the box.
$labelOld=New-Target 0 20 9000 2000 'label-test' 'DOT';$labelOld.Track=180
$labelCurrent=New-Target 0 0 9000 2020 'label-test' 'DOT';$labelCurrent.Track=180
$labelHistory=[AirspaceTrailHistory]::new()
$labelHistory.Observe([AirspaceTarget[]]@($labelOld),2000)
$labelHistory.Observe([AirspaceTarget[]]@($labelCurrent),2020)
$labelRenderer=New-Renderer
[void]$labelRenderer.Add($labelCurrent)
$labelRenderer.Finish('SZX','LIVE',0,1,100)
$labelBox=$labelRenderer.LabelBounds[0]
$trailX=[int][Math]::Round($labelCurrent.X)
Check ($trailX -ge $labelBox.Left + 19 -and $trailX -lt $labelBox.Right) 'Fixture must put the trail in the empty part of the callsign box'
$labelRaw=$labelRenderer.Raw()
for($y=$labelBox.Top;$y -lt $labelBox.Bottom;$y++){
    Check ([BitConverter]::ToUInt16($labelRaw,2*($y*240+$trailX)) -eq [AirspaceRenderer]::AltitudeColor(9000)) 'Callsign background erased part of the trail'
}

# Turning geometry must leave the old tail in its old travel direction and
# approach the new tail in the current direction, rather than simply bowing
# a straight chord without respecting the reported tracks.
$curveOld=New-Target -30 20 0 3000 'turn-icao' 'TURN123'
$curveCurrent=New-Target 12 -12 12000 3020 'turn-icao' 'TURN123';$curveCurrent.Track=180
$turnHistory=[AirspaceTrailHistory]::new();$turnHistory.Observe([AirspaceTarget[]]@($curveOld),3000);$turnHistory.Observe([AirspaceTarget[]]@($curveCurrent),3020)
$curveRenderer=New-Renderer;[void]$curveRenderer.Add($curveCurrent);$curveRenderer.Finish('SZX','LIVE',0,1,100,3995)
$oldPoint=$curveRenderer.Project($curveOld.Longitude,$curveOld.Latitude)
$tailStart=[AirspaceRenderer]::TailPoint($oldPoint.X,$oldPoint.Y,90)
$tailEnd=[AirspaceRenderer]::TailPoint($curveCurrent.X,$curveCurrent.Y,180)
$points=[AirspaceRenderer]::TrailCurve($tailStart,$tailEnd,90,180)
Check ($points.Length -gt 2 -and $points.Length -le 129) 'Turning segment must use a bounded sampled curve'
Check ($points[0].X -eq $tailStart.X -and $points[0].Y -eq $tailStart.Y -and $points[-1].X -eq $tailEnd.X -and $points[-1].Y -eq $tailEnd.Y) 'Curve endpoints must stay on the tail anchors'
$firstDx=$points[1].X-$points[0].X;$firstDy=$points[1].Y-$points[0].Y
$lastDx=$points[-1].X-$points[-2].X;$lastDy=$points[-1].Y-$points[-2].Y
Check ($firstDx -gt 0 -and [Math]::Abs($firstDy) -lt $firstDx*0.1) 'Curve must leave the old tail towards the east'
Check ($lastDy -gt 0 -and [Math]::Abs($lastDx) -lt $lastDy*0.1) 'Curve must approach the current tail towards the south'
$middleIndex=[int][Math]::Floor($points.Length/2);$middle=$points[$middleIndex]
$chordDx=$tailEnd.X-$tailStart.X;$chordDy=$tailEnd.Y-$tailStart.Y
$deviation=[Math]::Abs(($middle.X-$tailStart.X)*$chordDy-($middle.Y-$tailStart.Y)*$chordDx)/[Math]::Sqrt($chordDx*$chordDx+$chordDy*$chordDy)
Check ($deviation -gt 8 -and $curveRenderer.TrailCount -eq 1) 'Turn must visibly curve away from the straight chord'
$curveRaw=$curveRenderer.Raw()
foreach($endpoint in @(@($tailStart,0),@($tailEnd,12000))){
    $at=2*([int][Math]::Round($endpoint[0].Y)*240+[int][Math]::Round($endpoint[0].X))
    Check ([BitConverter]::ToUInt16($curveRaw,$at) -eq [AirspaceRenderer]::AltitudeColor($endpoint[1])) 'Curved trail endpoint has the wrong altitude colour'
}
$totalLength=0.0;$middleLength=0.0
for($i=1;$i -lt $points.Length;$i++){
    $dx=$points[$i].X-$points[$i-1].X;$dy=$points[$i].Y-$points[$i-1].Y;$totalLength += [Math]::Sqrt($dx*$dx+$dy*$dy)
    if($i -eq $middleIndex){$middleLength=$totalLength}
}
$expectedMiddle=[AirspaceRenderer]::AltitudeColor([int][Math]::Round(12000*$middleLength/$totalLength))
$actualMiddle=[BitConverter]::ToUInt16($curveRaw,2*([int][Math]::Round($middle.Y)*240+[int][Math]::Round($middle.X)))
Check ($actualMiddle -ne 0) 'Curved section was not rasterized'
foreach($channel in @(@(11,31),@(5,63),@(0,31))){
    $difference=(($actualMiddle -shr $channel[0]) -band $channel[1])-(($expectedMiddle -shr $channel[0]) -band $channel[1])
    Check ([Math]::Abs($difference) -le 2) 'Curve gradient must follow distance along the curve'
}
$lineStart=[Drawing.PointF]::new(40,100);$lineEnd=[Drawing.PointF]::new(120,100)
Check ([AirspaceRenderer]::TrailCurve($lineStart,$lineEnd,90,90).Length -eq 2) 'Straight flight must remain a straight line'
Check ([AirspaceRenderer]::TrailCurve($lineStart,$lineEnd,-1,90).Length -eq 2) 'Unknown old track must fall back to a line'
Check ([AirspaceRenderer]::TrailCurve($lineStart,$lineEnd,90,-1).Length -eq 2) 'Unknown current track must fall back to a line'
$wrapped=[AirspaceRenderer]::TrailCurve([Drawing.PointF]::new(120,190),[Drawing.PointF]::new(120,70),350,10)
foreach($point in $wrapped){Check ([Math]::Abs($point.X-120) -lt 20 -and $point.Y -ge 70 -and $point.Y -le 190) 'North-crossing tracks must not create a large rotation or loop'}

# Exercise two successful fixture queries with intervening cached renders in
# the actual sender, without network access, credentials or USB hardware.
$integrationRoot=Join-Path $env:TEMP ('airspace-trail-loop-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $integrationRoot | Out-Null
$fixture=Join-Path $integrationRoot 'response.json';$metaPath=Join-Path $integrationRoot 'airspace-latest.json'
$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$state=@('abc123','TEST123','China',$now,$now,$old.Longitude,$old.Latitude,0,$false,120,90,0,$null,0)
@{time=$now;states=@(,$state)}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $fixture -Encoding utf8
$startInfo=[Diagnostics.ProcessStartInfo]::new();$startInfo.FileName='powershell.exe'
$startInfo.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $project 'tools\Start-Airspace.ps1')+'" -Mode Live -Region Shenzhen -PreviewOnly -PollSeconds 3 -RenderSeconds 1 -FixturePath "'+$fixture+'" -OutputDirectory "'+$integrationRoot+'"'
$startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true;$startInfo.RedirectStandardOutput=$true;$startInfo.RedirectStandardError=$true
$startInfo.EnvironmentVariables.Remove('OPENSKY_CLIENT_ID');$startInfo.EnvironmentVariables.Remove('OPENSKY_CLIENT_SECRET')
$process=[Diagnostics.Process]::Start($startInfo)
try {
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(15);$changed=$false;$observedSecond=$false;$observedCached=$false
    while([DateTimeOffset]::UtcNow -lt $deadline -and -not $process.HasExited){
        $meta=$null
        try{if(Test-Path -LiteralPath $metaPath){$meta=Get-Content -LiteralPath $metaPath -Raw|ConvertFrom-Json}}catch{}
        if($meta -and -not $changed){
            Check ($meta.successfulQueries -eq 1 -and $meta.trailCount -eq 0) 'First sender frame must not show a trail'
            $state[3]=$now+1;$state[4]=$now+1;$state[5]=$current.Longitude;$state[6]=$current.Latitude;$state[7]=12000
            @{time=($now+1);states=@(,$state)}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $fixture -Encoding utf8
            $changed=$true
        }
        if($meta -and $meta.successfulQueries -eq 2){
            Check ($meta.trailCount -eq 1) 'Successful source update did not create a trail in the sender'
            if($observedSecond -and $meta.sequence -gt $secondSequence){$observedCached=$true;break}
            $secondSequence=$meta.sequence;$observedSecond=$true
        }
        Start-Sleep -Milliseconds 100
    }
    Check $observedCached 'Cached renders did not preserve the latest source segment'
} finally {if(-not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}
if($PreviewPath){$curveRenderer.SavePng([IO.Path]::GetFullPath($PreviewPath))}
Write-Output 'PASS: direction-matched curves, tail anchors, arc-length altitude gradient, straight/unknown tracks, clipping, source updates and cached renders, ICAO tracking and time gaps.'
