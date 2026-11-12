param([string]$Port='COM4',[ValidateRange(1,20)][int]$Frames=3,[switch]$CheckDirtyUpdates)
$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if(-not ('AirspaceTransport' -as [type])){
    Add-Type -Path @((Join-Path $project 'tools\AirspaceTransport.cs'),(Join-Path $PSScriptRoot 'AirspaceTraceLink.cs')) -ReferencedAssemblies ([IO.Ports.SerialPort].Assembly.Location)
}
[byte[]]$saved=[IO.File]::ReadAllBytes((Join-Path $project 'previews\airspace-latest.ips'))
if($saved.Length -ne 115216 -or [Text.Encoding]::ASCII.GetString($saved,0,4) -ne 'IPS2'){
    throw 'Generate a new IPS2 preview first with Start-Airspace.ps1 -PreviewOnly -Once.'
}
$checkPort=[IO.Ports.SerialPort]::new($Port,115200)
$checkPort.DtrEnable=$true;$checkPort.RtsEnable=$false;$checkPort.WriteTimeout=15000
try{
    $checkPort.Open();Start-Sleep -Milliseconds 500
    if($CheckDirtyUpdates){
        Add-Type -AssemblyName System.Drawing
        if(-not ('AirspaceRenderer' -as [type])){Add-Type -Path (Join-Path $project 'tools\AirspaceRenderer.cs') -ReferencedAssemblies System.Drawing}
        [byte[]]$baseline=New-Object byte[] 115200
        [Buffer]::BlockCopy($saved,16,$baseline,0,115200)
        $link=[AirspaceTraceLink]::new($checkPort)
        # Baseline, duplicate, one tile, two adjacent tiles, two distant tiles,
        # restore, duplicate. Exercise the real C++ dirty-region implementation.
        $cases=@(
            @{Name='baseline';Pixel=-1;Pixels=-1;Windows=-1},
            @{Name='identical';Pixel=-1;Pixels=0;Windows=0},
            @{Name='one tile';Pixel=(30*240+1);Pixels=256;Windows=1},
            @{Name='adjacent tiles';Pixel=(30*240+17);Pixels=512;Windows=1},
            @{Name='distant tiles';Pixel=(100*240+33);Pixels=512;Windows=2},
            @{Name='restore';Pixel=-1;Pixels=256;Windows=1},
            @{Name='identical again';Pixel=-1;Pixels=0;Windows=0}
        )
        [uint32]$sequence=1
        foreach($case in $cases){
            [byte[]]$raw=$baseline.Clone()
            if($case.Pixel -ge 0){$at=2*$case.Pixel;$raw[$at]=$raw[$at] -bxor 255;$raw[$at+1]=$raw[$at+1] -bxor 255}
            [AirspaceTransport]::Send($link,[AirspaceRenderer]::Packet($raw,$sequence),$sequence,15000)
            if($link.DrawLines.Count -ne 1){throw 'Missing dirty-region diagnostics; upload the new firmware.'}
            $parts=$link.DrawLines[0].Split(' ')
            if($case.Pixels -ge 0 -and ([int]$parts[2] -ne $case.Pixels -or [int]$parts[3] -ne $case.Windows)){
                throw ('Dirty-region mismatch for '+$case.Name+': '+$link.DrawLines[0])
            }
            Write-Output ($case.Name+': '+$link.DrawLines[0]);$sequence++
        }
        # A CRC failure must leave the display cache untouched.
        [byte[]]$bad=[AirspaceRenderer]::Packet($baseline,$sequence)
        $bad[16+2*(30*240+1)]=$bad[16+2*(30*240+1)] -bxor 1
        $crcRejected=$false
        try{[AirspaceTransport]::Send($link,$bad,$sequence,15000)}catch{$crcRejected=$_.Exception.ToString().Contains('ERR CRC')}
        if(-not $crcRejected){throw 'Corrupted frame was not rejected'}
        $sequence++
        [AirspaceTransport]::Send($link,[AirspaceRenderer]::Packet($baseline,$sequence),$sequence,15000)
        $parts=$link.DrawLines[0].Split(' ')
        if([int]$parts[2] -ne 0 -or [int]$parts[3] -ne 0){throw 'Bad CRC changed the display cache'}
        Write-Output 'PASS: exact dirty regions, adjacent merge, identical-frame skip and CRC failure preserves display.'
        return
    }
    for([uint32]$sequence=1;$sequence -le $Frames;$sequence++){
        [byte[]]$sequenceBytes=[BitConverter]::GetBytes($sequence)
        [Buffer]::BlockCopy($sequenceBytes,0,$saved,8,4)
        $timer=[Diagnostics.Stopwatch]::StartNew()
        [AirspaceTransport]::Send($checkPort,$saved,$sequence)
        Write-Output ('Hardware ACK frame {0}: 115200 bytes verified and displayed in {1} ms' -f $sequence,$timer.ElapsedMilliseconds)
    }
}finally{$checkPort.Dispose()}
