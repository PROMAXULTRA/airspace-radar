$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Add-Type -AssemblyName System.Drawing
if(-not ('AirspaceRenderer' -as [type])){Add-Type -Path (Join-Path $project 'tools\AirspaceRenderer.cs') -ReferencedAssemblies System.Drawing}
if(-not ('AirspaceTransportTests' -as [type])){
    Add-Type -Path @((Join-Path $project 'tools\AirspaceTransport.cs'),(Join-Path $PSScriptRoot 'Test-AirspaceTransport.cs')) -ReferencedAssemblies ([IO.Ports.SerialPort].Assembly.Location)
}
function Check($condition,$message){if(-not $condition){throw $message}}
Check ([AirspaceRenderer]::Color565(255,0,0) -eq 0xF800) 'Red channel packing failed'
Check ([AirspaceRenderer]::Color565(0,255,0) -eq 0x07E0) 'Green channel packing failed'
Check ([AirspaceRenderer]::Color565(0,0,255) -eq 0x001F) 'Blue channel packing failed'
Check ([AirspaceRenderer]::Color565(255,255,255) -eq 0xFFFF) 'White channel packing failed'
Check ([AirspaceRenderer]::Crc32([Text.Encoding]::ASCII.GetBytes('123456789')) -eq [uint32]3421780262) 'CRC-32 known vector failed'
$testDir=Join-Path $env:TEMP ('airspace-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
$assets=Get-Content -LiteralPath (Join-Path $project 'tools\data\airspace-assets.json') -Raw | ConvertFrom-Json
Check (@($assets.runways | Where-Object {$_.airport -eq 'ZGGG'}).Count -eq 5) 'Guangzhou runway reference missing'
Check (@($assets.runways | Where-Object {$_.airport -eq 'ZGSZ'}).Count -eq 3) 'Shenzhen runway reference missing'
$newYorkReference=Get-Content -LiteralPath (Join-Path $project 'tools\data\new-york-reference.json') -Raw | ConvertFrom-Json
Check (@($newYorkReference.runways | Where-Object {$_.airport -eq 'KJFK'}).Count -eq 4) 'JFK runway reference missing'
Check (@($newYorkReference.runways | Where-Object {$_.airport -eq 'KLGA'}).Count -eq 2) 'LaGuardia runway reference missing'
Check (@($newYorkReference.runways | Where-Object {$_.airport -eq 'KEWR'}).Count -eq 3) 'Newark runway reference missing'
$renderer=[AirspaceRenderer]::new([byte[]]$assets.font,[uint16[]]$assets.planeMask,121.805,31.1434,20)
$center=$renderer.Project(121.805,31.1434)
Check ([Math]::Abs($center.X-120) -lt 0.01 -and [Math]::Abs($center.Y-132) -lt 0.01) 'Projection center failed'
$north=[AirspaceRenderer]::Offset(121.805,31.1434,0,1)
$p=$renderer.Project($north[0],$north[1])
Check ([Math]::Abs($p.Y-(132-11.6)) -lt 0.02) 'One-kilometre map scale failed'

# Keep labels attached when the previous position still fits, despite altitude
# and callsign changes; identity comes from the ICAO address.
$layout=[AirspaceLabelLayout]::new()
$first=[AirspaceRenderer]::new([byte[]]$assets.font,[uint16[]]$assets.planeMask,121.805,31.1434,100,$layout)
$flight=[AirspaceTarget]::new();$flight.Id='TEST123';$flight.Identity='abc123';$flight.Longitude=121.805;$flight.Latitude=31.1434;$flight.Altitude=990;$flight.Track=0
[void]$first.Add($flight);$first.Finish('TEST','DEMO',0,1,100)
Check ($flight.Lines.Count -eq 1 -and $flight.Lines[0] -eq 'TEST123') 'Labels must only contain the callsign'
$dx=$flight.LabelX-[int][Math]::Round($flight.X);$dy=$flight.LabelY-[int][Math]::Round($flight.Y)
$raw=$first.Raw();$color=[AirspaceRenderer]::AltitudeColor(990)
foreach($box in @(@(110,122,20,20),@($flight.LabelX,$flight.LabelY,50,8))){
    $lit=0
    for($y=$box[1];$y -lt $box[1]+$box[3];$y++){for($x=$box[0];$x -lt $box[0]+$box[2];$x++){
        $word=[BitConverter]::ToUInt16($raw,2*($y*240+$x))
        if($word -ne 0){Check ($word -eq $color) 'Aircraft and callsign must share altitude colour';$lit++}
    }}
    Check ($lit -gt 0) 'Aircraft or label line was not drawn'
}
# Every bar row must encode the same height colour as an aircraft, increasing
# from 0 m at the bottom to 12,000 m at the top, without gaps or overlays.
for($y=48;$y -le 216;$y++){
    $altitude=[int][Math]::Round((216-$y)*12000.0/168)
    for($x=232;$x -le 237;$x++){
        Check ([BitConverter]::ToUInt16($raw,2*($y*240+$x)) -eq [AirspaceRenderer]::AltitudeColor($altitude)) 'Legend gradient differs from aircraft colours'
    }
    for($x=218;$x -le 231;$x++){
        Check ([BitConverter]::ToUInt16($raw,2*($y*240+$x)) -eq 0) 'Legend must not have intermediate labels or tick marks'
    }
}

# At headings whose centerline reflects the pixel grid onto itself, the icon
# must mirror across the same axis used for the trail's tail anchor.
foreach($heading in @(0,45,90,135)){
    $icon=[AirspaceRenderer]::new([byte[]]$assets.font,[uint16[]]$assets.planeMask,121.805,31.1434,100)
    $target=[AirspaceTarget]::new();$target.Id='TEST123';$target.Longitude=121.805;$target.Latitude=31.1434;$target.Track=$heading
    [void]$icon.Add($target);$icon.Finish('TEST','DEMO',0,1,100)
    $pixels=$icon.Raw();$cx=[int]$target.X;$cy=[int]$target.Y
    for($y=-12;$y -le 12;$y++){for($x=-12;$x -le 12;$x++){
        switch($heading){
            0   {$mx=-$x;$my=$y}
            45  {$mx=-$y;$my=-$x}
            90  {$mx=$x;$my=-$y}
            135 {$mx=$y;$my=$x}
        }
        $left=[BitConverter]::ToUInt16($pixels,2*(($cy+$y)*240+$cx+$x))
        $right=[BitConverter]::ToUInt16($pixels,2*(($cy+$my)*240+$cx+$mx))
        Check ($left -eq $right) "2D aircraft is asymmetric at heading $heading"
    }}
}
$hidden=[AirspaceTarget]::new();$hidden.Id='HIDDEN';$position=[AirspaceRenderer]::Offset(121.805,31.1434,40,0);$hidden.Longitude=$position[0];$hidden.Latitude=$position[1]
Check (-not $first.IsVisible($hidden.Longitude,$hidden.Latitude) -and -not $first.Add($hidden)) 'Aircraft underneath the legend must not be counted or drawn'
$second=[AirspaceRenderer]::new([byte[]]$assets.font,[uint16[]]$assets.planeMask,121.805,31.1434,100,$layout)
$moved=[AirspaceTarget]::new();$moved.Id='NEW12345';$moved.Identity='abc123';$moved.Altitude=10000
$position=[AirspaceRenderer]::Offset(121.805,31.1434,2,1);$moved.Longitude=$position[0];$moved.Latitude=$position[1]
$neighbour=[AirspaceTarget]::new();$neighbour.Id='NEAR123';$neighbour.Longitude=121.805;$neighbour.Latitude=31.33;$neighbour.Altitude=6000
[void]$second.Add($neighbour);[void]$second.Add($moved);$second.Finish('TEST','DEMO',10,2,100)
Check (($moved.LabelX-[int][Math]::Round($moved.X)) -eq $dx -and ($moved.LabelY-[int][Math]::Round($moved.Y)) -eq $dy) 'Existing label changed its anchor between frames'
Check ($moved.Lines.Count -eq 1 -and $moved.Lines[0] -eq 'NEW12345' -and $moved.Color -ne $flight.Color) 'Aircraft update did not update callsign and colour'
Check ([AirspaceRenderer]::AltitudeColor(0) -eq [AirspaceRenderer]::Color565(255,152,0)) 'Low altitude colour failed'
Check ([AirspaceRenderer]::AltitudeColor(6000) -eq [AirspaceRenderer]::Color565(0,223,217)) 'Mid altitude colour failed'
Check ([AirspaceRenderer]::AltitudeColor(12000) -eq [AirspaceRenderer]::AltitudeColor(20000)) 'High altitude colour must clamp'
Check ([AirspaceRenderer]::AltitudeColor(-100) -eq [AirspaceRenderer]::AltitudeColor(0)) 'Below-sea-level colour must clamp'
Check ([AirspaceRenderer]::AltitudeColor(500) -ne [AirspaceRenderer]::AltitudeColor(0) -and [AirspaceRenderer]::AltitudeColor(500) -ne [AirspaceRenderer]::AltitudeColor(1000)) 'Altitude colour must interpolate'
Check ([AirspaceRenderer]::AltitudeColor([int]::MinValue) -eq 0xAD55) 'Unknown altitude must be neutral grey'

# Check the actual quota glyphs in the transmitted pixels, including unknown
# and zero, without depending on a live API or exposing credentials.
foreach($quota in @(-1,0,3998)){
    $quotaRenderer=[AirspaceRenderer]::new([byte[]]$assets.font,[uint16[]]$assets.planeMask,121.805,31.1434,100)
    $quotaRenderer.Finish('TEST','LIVE',5,0,100,$quota);$quotaRaw=$quotaRenderer.Raw()
    $quotaLabel=if($quota -lt 0){'Q--'}else{'Q'+$quota}
    $quotaColour=if($quota -eq 0){[AirspaceRenderer]::AltitudeColor(0)}else{0xAD55}
    for($index=0;$index -lt $quotaLabel.Length;$index++){
        for($col=0;$col -lt 5;$col++){for($row=0;$row -lt 8;$row++){
            $expected=if(([int]$assets.font[[int][char]$quotaLabel[$index]*5+$col] -band (1 -shl $row)) -ne 0){$quotaColour}else{0}
            $word=[BitConverter]::ToUInt16($quotaRaw,2*((8+$row)*240+180+$index*6+$col))
            Check ($word -eq $expected) 'Quota text differs from response credit count'
        }}
    }
}

# Exercise Windows PowerShell 5.1, the intended no-install runtime.
$sender=Join-Path $project 'tools\Start-Airspace.ps1'
$parseTokens=$null;$parseErrors=$null
$senderAst=[Management.Automation.Language.Parser]::ParseFile($sender,[ref]$parseTokens,[ref]$parseErrors)
Check ($parseErrors.Count -eq 0) 'Sender PowerShell syntax failed'
$quotaFunction=$senderAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-OpenSkyRemainingCredits'},$true)
. ([scriptblock]::Create($quotaFunction.Extent.Text))
Check ((Get-OpenSkyRemainingCredits @{'X-Rate-Limit-Remaining'='3998'}) -eq 3998) 'Quota response header was not parsed'
Check ((Get-OpenSkyRemainingCredits @{'X-Rate-Limit-Remaining'='0'}) -eq 0) 'Exhausted quota must remain zero'
foreach($headers in @(@{},@{'X-Rate-Limit-Remaining'='invalid'},@{'X-Rate-Limit-Remaining'='-1'})){
    Check ((Get-OpenSkyRemainingCredits $headers) -eq -1) 'Missing or invalid quota must be unknown'
}
foreach($region in @('Airport','City','Nearby','Guangzhou','Baiyun','Shenzhen','NewYork','JFK')){
    $out=Join-Path $testDir $region
    & powershell -NoProfile -ExecutionPolicy Bypass -File $sender -PreviewOnly -Once -DemoSeconds 0 -Region $region -OutputDirectory $out
    Check ($LASTEXITCODE -eq 0) "$region demo failed"
    $meta=Get-Content -LiteralPath (Join-Path $out 'airspace-latest.json') -Raw | ConvertFrom-Json
    Check ($meta.mode -eq 'DEMO' -and $meta.tiltedView -and $meta.displayed -gt 0 -and $meta.trailCount -gt 0) '3D demo did not show the aircraft and their trails'
    $labels=@($meta.labels)
    for($i=0;$i -lt $labels.Count;$i++){
        $a=$labels[$i]
        Check ($a.x -ge 0 -and $a.y -ge 24 -and ($a.x+$a.width) -le [AirspaceRenderer]::MapRight -and ($a.y+$a.height) -le 240 -and $a.height -eq 8) 'Single-line label clipped or overlaps the legend'
        for($j=$i+1;$j -lt $labels.Count;$j++){
            $b=$labels[$j]
            $w=[Math]::Min($a.x+$a.width,$b.x+$b.width)-[Math]::Max($a.x,$b.x)
            $h=[Math]::Min($a.y+$a.height,$b.y+$b.height)-[Math]::Max($a.y,$b.y)
            Check (-not ($w -gt 0 -and $h -gt 0)) "$region labels overlap"
        }
    }
}
[byte[]]$packet=[IO.File]::ReadAllBytes((Join-Path $testDir 'Airport\airspace-latest.ips'))
Check ($packet.Length -eq 115216) 'Wrong frame size'
Check ([Text.Encoding]::ASCII.GetString($packet,0,4) -eq 'IPS2') 'Wrong packet magic'
Check ([BitConverter]::ToUInt32($packet,4) -eq 115200) 'Wrong payload length'
[AirspaceTransportTests]::Run($packet)
[byte[]]$payload=$packet[16..($packet.Length-1)]
Check ([AirspaceRenderer]::Crc32($payload) -eq [BitConverter]::ToUInt32($packet,12)) 'Packet CRC mismatch'
$payload[5000]=$payload[5000] -bxor 1
Check ([AirspaceRenderer]::Crc32($payload) -ne [BitConverter]::ToUInt32($packet,12)) 'Corruption was not detected'
$bitmap=[Drawing.Bitmap]::new((Join-Path $testDir 'Airport\airspace-latest.png'))
try{
    # Decode EVERY transmitted word independently and compare with the PNG.
    for($y=0;$y -lt 240;$y++){for($x=0;$x -lt 240;$x++){
        $at=16+2*($y*240+$x);$word=[int]$packet[$at] -bor ([int]$packet[$at+1] -shl 8)
        $r=($word -shr 11) -band 31;$g=($word -shr 5) -band 63;$b=$word -band 31
        $pixel=$bitmap.GetPixel($x,$y)
        if($pixel.R -ne (($r -shl 3) -bor ($r -shr 2)) -or $pixel.G -ne (($g -shl 2) -bor ($g -shr 4)) -or $pixel.B -ne (($b -shl 3) -bor ($b -shr 2))){throw 'PNG differs from transmitted pixels'}
    }}
}finally{$bitmap.Dispose()}

$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$row=@('abc123','TEST123 ','China',$now,$now,121.805,31.1434,4200,$false,120,145,-2,$null,4300)
$missing=@('abc124','MISS123 ','China',$now,$now,121.815,31.1634,$null,$false,120,$null,$null,$null,$null)
$old=@('abc125','OLD123  ','China',($now-120),$now,121.805,31.1434,4200,$false,120,145,-2,$null,4300)
$ground=@('abc126','GND123  ','China',$now,$now,121.805,31.1434,10,$true,0,145,0,$null,10)
$fixture=Join-Path $testDir 'live-fixture.json'
@{time=$now;states=@($row,$missing,$old,$ground)}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $fixture -Encoding utf8
$out=Join-Path $testDir 'Live'
& powershell -NoProfile -ExecutionPolicy Bypass -File $sender -Mode Live -Region Airport -PreviewOnly -Once -FixturePath $fixture -OutputDirectory $out
Check ($LASTEXITCODE -eq 0) 'Live fixture failed'
$meta=Get-Content -LiteralPath (Join-Path $out 'airspace-latest.json') -Raw|ConvertFrom-Json
Check ($meta.mode -eq 'LIVE' -and $meta.displayed -eq 2) 'Missing values, old fixes or ground aircraft parsed incorrectly'
@{time=$now;states=$null}|ConvertTo-Json|Set-Content -LiteralPath $fixture -Encoding utf8
& powershell -NoProfile -ExecutionPolicy Bypass -File $sender -Mode Live -Region Airport -PreviewOnly -Once -FixturePath $fixture -OutputDirectory $out
Check ($LASTEXITCODE -eq 0) 'Empty live response failed'
$meta=Get-Content -LiteralPath (Join-Path $out 'airspace-latest.json') -Raw|ConvertFrom-Json
Check ($meta.mode -eq 'LIVE' -and $meta.displayed -eq 0) 'Empty response became fake aircraft'
$row[5]=113.299004;$row[6]=23.392401;$row[1]='CSNTEST '
@{time=$now;states=@(,$row)}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $fixture -Encoding utf8
& powershell -NoProfile -ExecutionPolicy Bypass -File $sender -Mode Live -Region Guangzhou -PreviewOnly -Once -FixturePath $fixture -OutputDirectory $out
Check ($LASTEXITCODE -eq 0) 'Guangzhou live fixture failed'
$meta=Get-Content -LiteralPath (Join-Path $out 'airspace-latest.json') -Raw|ConvertFrom-Json
Check ($meta.mode -eq 'LIVE' -and $meta.displayed -eq 1 -and $meta.region -eq 'Guangzhou') 'Guangzhou region queried or projected incorrectly'
$row[5]=113.803262;$row[6]=22.639474
@{time=$now;states=@(,$row)}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $fixture -Encoding utf8
& powershell -NoProfile -ExecutionPolicy Bypass -File $sender -Mode Live -Region Shenzhen -PreviewOnly -Once -FixturePath $fixture -OutputDirectory $out
Check ($LASTEXITCODE -eq 0) 'Shenzhen live fixture failed'
$meta=Get-Content -LiteralPath (Join-Path $out 'airspace-latest.json') -Raw|ConvertFrom-Json
Check ($meta.mode -eq 'LIVE' -and $meta.displayed -eq 1 -and $meta.region -eq 'Shenzhen' -and $meta.spanKm -eq 100) 'Shenzhen airport region queried or projected incorrectly'
$row[5]=-73.779317;$row[6]=40.639447;$row[1]='JBU123 '
@{time=$now;states=@(,$row)}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $fixture -Encoding utf8
# The default must also use New York when no explicit region is supplied.
& powershell -NoProfile -ExecutionPolicy Bypass -File $sender -Mode Live -PreviewOnly -Once -FixturePath $fixture -OutputDirectory $out
Check ($LASTEXITCODE -eq 0) 'New York default live fixture failed'
$meta=Get-Content -LiteralPath (Join-Path $out 'airspace-latest.json') -Raw|ConvertFrom-Json
Check ($meta.mode -eq 'LIVE' -and $meta.displayed -eq 1 -and $meta.region -eq 'NewYork' -and $meta.spanKm -eq 100) 'New York default region queried or projected incorrectly'

# Dense traffic must retain all aircraft, even with an old cap argument.
$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$centers=[Collections.Generic.List[Drawing.Point]]::new()
$dense=@(
    for($y=48;$y -le 204;$y+=26){
        for($x=22;$x -le 190;$x+=24){
            $position=[AirspaceRenderer]::Offset(121.805,31.1434,($x-120)/11.6,(132-$y)/11.6)
            $id=$centers.Count
            $centers.Add([Drawing.Point]::new($x,$y))
            ,@($id.ToString('x6'),('DENSE'+$id),'China',$now,$now,$position[0],$position[1],4200,$false,120,0,0,$null,4200)
        }
    }
)
@{time=$now;states=$dense}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $fixture -Encoding utf8
& powershell -NoProfile -ExecutionPolicy Bypass -File $sender -Mode Live -Region Airport -PreviewOnly -Once -TopDown -MaxAircraft 3 -FixturePath $fixture -OutputDirectory $out
Check ($LASTEXITCODE -eq 0) 'Dense live fixture failed'
$meta=Get-Content -LiteralPath (Join-Path $out 'airspace-latest.json') -Raw|ConvertFrom-Json
Check ($meta.displayed -eq $centers.Count -and $meta.available -eq $centers.Count) 'Dense traffic was capped'
Check ($meta.labels.Count -lt $meta.displayed) 'Crowded callsigns should yield space to aircraft'
$densePacket=[IO.File]::ReadAllBytes((Join-Path $out 'airspace-latest.ips'))
foreach($point in $centers){
    $at=16+2*($point.Y*240+$point.X)
    Check ([BitConverter]::ToUInt16($densePacket,$at) -eq [AirspaceRenderer]::AltitudeColor(4200)) 'An in-view aircraft icon is missing from the output frame'
}
& powershell -NoProfile -ExecutionPolicy Bypass -File $sender -Mode Live -Region Airport -PreviewOnly -Once -MaxAircraft 3 -FixturePath $fixture -OutputDirectory $out
Check ($LASTEXITCODE -eq 0) 'Dense 3D live fixture failed'
$meta=Get-Content -LiteralPath (Join-Path $out 'airspace-latest.json') -Raw|ConvertFrom-Json
Check ($meta.tiltedView -and $meta.displayed -eq $centers.Count) 'The tilted camera dropped in-view aircraft'

# Exercise the actual binary metadata used by the new USB display. Include
# enough aircraft to cross the negotiated USB block boundary.
[AirspaceTarget[]]$sceneTargets=@(
    foreach($row in $dense){
        $target=[AirspaceTarget]::new()
        $target.Identity=$row[0]; $target.Id=$row[1]; $target.Longitude=$row[5]; $target.Latitude=$row[6]
        $target.Altitude=$row[7]; $target.Track=90
        $target
    }
)
$sceneTargets[0].HasPreviousPosition=$true
$sceneTargets[0].PreviousLongitude=121.75; $sceneTargets[0].PreviousLatitude=31.12
$sceneTargets[0].PreviousTrack=85; $sceneTargets[0].PreviousAltitude=3950
[double[][]]$sceneRunways=@(,([double[]]@(121.8,31.1,121.81,31.2)))
[AirspaceSceneNavaid[]]$sceneNavaids=@([AirspaceSceneNavaid]::new('PDL',121.77,31.13))
[byte[]]$scene=[AirspaceRenderer]::ScenePacket(42,'PVG',121.805,31.1434,20,'LIVE',5500,$true,24,$true,$sceneRunways,$sceneNavaids,$sceneTargets)
Check ([Text.Encoding]::ASCII.GetString($scene,0,4) -eq 'IPS4') 'Wrong scene magic'
Check ($scene.Length -eq (16+32+16+12+36*$sceneTargets.Count)) 'Scene length is not determined by record counts'
Check ([BitConverter]::ToUInt32($scene,4) -eq ($scene.Length-16)) 'Wrong scene payload size'
Check ([BitConverter]::ToUInt32($scene,12) -eq [AirspaceRenderer]::Crc32($scene[16..($scene.Length-1)])) 'Scene CRC does not cover metadata'
Check ($scene[30] -eq 1 -and $scene[31] -eq 3 -and [BitConverter]::ToInt32($scene,32) -eq 5500) 'Local clock state was not encoded'
Check ([BitConverter]::ToUInt32($scene,44) -eq $sceneTargets.Count) 'Scene aircraft count changed'
$first=16+32+16+12
Check ([Text.Encoding]::ASCII.GetString($scene,$first+4,6) -eq 'DENSE0') 'Callsign missing from metadata'
Check ([BitConverter]::ToInt16($scene,$first+20) -eq 4200 -and [BitConverter]::ToInt16($scene,$first+22) -eq 90) 'Altitude or heading missing from metadata'
Check ([BitConverter]::ToInt32($scene,$first+24) -eq 121750000 -and [BitConverter]::ToInt16($scene,$first+34) -eq 85) 'Previous position missing from metadata'
Check ([BitConverter]::ToInt16($scene,$first+36+34) -eq -2) 'No-history flag was not encoded'
[AirspaceTransportTests]::RunScene($scene)
$coast = [AirspaceRenderer]::LoadCoastlines((Join-Path $project 'tools\data\airspace-coast.gz'),-73.779317,40.639447,100)
Check ($coast.Count -gt 0 -and $coast.Count -le 384) 'JFK needs a bounded coastline layer'
$coastPath = Join-Path $project 'tools\data\airspace-coast.gz'
$inlandPath = Join-Path $project 'tools\data\airspace-inland.gz'
$munichCoast = [AirspaceRenderer]::LoadCoastlines($coastPath,11.7861,48.353802,100)
$munichWater = [AirspaceRenderer]::LoadWaterLines([string[]]@($coastPath,$inlandPath),11.7861,48.353802,100)
Check ($munichCoast.Count -eq 0 -and $munichWater.Count -gt 0 -and $munichWater.Count -le 384) 'Inland Munich should show inland water lines without a coast'
$tilt = [AirspaceRenderer]::new([byte[]]$assets.font,[uint16[]]$assets.planeMask,-73.779317,40.639447,100)
$tilt.TiltedView = $true
$ground = $tilt.ProjectOnDisplay(-73.779317,40.639447,0)
$cruise = $tilt.ProjectOnDisplay(-73.779317,40.639447,12000)
$unknown = $tilt.ProjectOnDisplay(-73.779317,40.639447,[int]::MinValue)
Check ($ground.X -eq $cruise.X -and [Math]::Abs($ground.Y-$cruise.Y-42) -lt 0.001 -and $ground -eq $unknown) 'Aircraft altitude should change lift, with unknowns left on the ground plane'
[byte[]]$tiltedScene=[AirspaceRenderer]::ScenePacket(42,'JFK',-73.779317,40.639447,100,'LIVE',5500,$false,24,$true,$sceneRunways,$sceneNavaids,$sceneTargets,$true,$coast)
Check ($tiltedScene[31] -eq 5 -and [BitConverter]::ToUInt16($tiltedScene,$scene.Length) -eq $coast.Count -and $tiltedScene.Length -eq ($scene.Length+2+16*$coast.Count)) 'Tilt or coastline records were not encoded'
Check ([BitConverter]::ToUInt32($tiltedScene,12) -eq [AirspaceRenderer]::Crc32($tiltedScene[16..($tiltedScene.Length-1)])) 'Tilted scene CRC did not cover coastline records'
[AirspaceTransportTests]::RunScene($tiltedScene)
[byte[]]$topDownWater=[AirspaceRenderer]::ScenePacket(42,'MUC',11.7861,48.353802,100,'LIVE',5500,$false,24,$true,$sceneRunways,$sceneNavaids,$sceneTargets,$false,$munichWater)
Check ($topDownWater[31] -eq 9 -and [BitConverter]::ToUInt16($topDownWater,$scene.Length) -eq $munichWater.Count -and $topDownWater.Length -eq ($scene.Length+2+16*$munichWater.Count)) '2D water records changed the camera or were omitted'
[AirspaceTransportTests]::RunScene($topDownWater)

$waterOn=Join-Path $testDir 'Munich-water-on'
$waterOff=Join-Path $testDir 'Munich-water-off'
& powershell -NoProfile -ExecutionPolicy Bypass -File $sender -AirportIdent EDDM -TopDown -PreviewOnly -Once -DemoSeconds 0 -OutputDirectory $waterOn
Check ($LASTEXITCODE -eq 0) '2D with water lines failed'
& powershell -NoProfile -ExecutionPolicy Bypass -File $sender -AirportIdent EDDM -TopDown -HideWaterLines -PreviewOnly -Once -DemoSeconds 0 -OutputDirectory $waterOff
Check ($LASTEXITCODE -eq 0) '2D without water lines failed'
$onMeta=Get-Content -LiteralPath (Join-Path $waterOn 'airspace-latest.json') -Raw | ConvertFrom-Json
$offMeta=Get-Content -LiteralPath (Join-Path $waterOff 'airspace-latest.json') -Raw | ConvertFrom-Json
Check (-not $onMeta.tiltedView -and -not $offMeta.tiltedView -and $onMeta.waterLineCount -gt 0 -and $offMeta.waterLineCount -eq 0) 'Water layer did not toggle independently of 2D view'
$onPixels=[IO.File]::ReadAllBytes((Join-Path $waterOn 'airspace-latest.ips'))
$offPixels=[IO.File]::ReadAllBytes((Join-Path $waterOff 'airspace-latest.ips'))
$visibleWater=0
for($at=16;$at -lt $onPixels.Length;$at+=2){
    $on=[BitConverter]::ToUInt16($onPixels,$at); $off=[BitConverter]::ToUInt16($offPixels,$at)
    if($on -ne $off){Check ($on -eq 0x2925 -and $off -eq 0) 'Water toggle modified something other than the base map'; $visibleWater++}
}
Check ($visibleWater -gt 0) '2D map should draw inland water'
Write-Output 'PASS: independent 2D water layer, altitude lift, scene metadata, all in-view aircraft, callsigns, quota, USB flow control, RGB565, CRC and live parsing.'
