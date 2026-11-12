$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'tools\AirspaceFiles.ps1')
function Check($condition,$message) { if (-not $condition) { throw $message } }
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public static class AirspaceSnapshotTest {
    public static Task ReleaseLater(FileStream stream) {
        return Task.Run(() => { Thread.Sleep(150); stream.Dispose(); });
    }
    public static Task ReadRepeatedly(string path, string first, string second) {
        return Task.Run(() => {
            int reads = 0;
            for (int i = 0; i < 300; i++) {
                try {
                    using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                        FileShare.ReadWrite | FileShare.Delete))
                    using (var reader = new StreamReader(stream)) {
                        string value = reader.ReadToEnd();
                        if (value != first && value != second)
                            throw new Exception("Reader saw a partial snapshot");
                        reads++;
                    }
                } catch (IOException error) {
                    int code = error.HResult & 0xffff;
                    // The UI retries on its next tick if a replacement is busy.
                    if (code != 2 && code != 32 && code != 33) throw;
                }
                Thread.Sleep(1);
            }
            if (reads == 0) throw new Exception("No concurrent snapshots were read");
        });
    }
}
'@
$directory = Join-Path $env:TEMP ('airspace-files-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$path = Join-Path $directory 'airspace-latest.json'
$first = '{"value":"' + ('A' * 4096) + '"}'
$second = '{"value":"' + ('B' * 4096) + '"}'
Write-AirspaceSnapshotFile $path { param($p) [IO.File]::WriteAllText($p,$first) }
$hold = [IO.File]::OpenRead($path)
$release = [AirspaceSnapshotTest]::ReleaseLater($hold)
Write-AirspaceSnapshotFile $path { param($p) [IO.File]::WriteAllText($p,$second) }
$release.GetAwaiter().GetResult()
Check ((Read-AirspaceSnapshotText $path) -eq $second) 'Transient lock did not recover'
$hold = [IO.File]::OpenRead($path)
$locked = $false
try {
    Write-AirspaceSnapshotFile $path { param($p) [IO.File]::WriteAllText($p,$first) }
} catch [IO.IOException] {
    $locked = ($_.Exception.GetBaseException().HResult -band 0xffff) -eq 32
} finally { $hold.Dispose() }
Check $locked 'Persistent sharing violation was not reported'
Check ((Read-AirspaceSnapshotText $path) -eq $second) 'Failed publish damaged the previous snapshot'
Check (@(Get-ChildItem -LiteralPath $directory -Filter '*.tmp').Count -eq 0) 'Temporary snapshot leaked'
$reader = [AirspaceSnapshotTest]::ReadRepeatedly($path,$first,$second)
for ($index = 0; $index -lt 100; $index++) {
    $value = if ($index % 2) { $first } else { $second }
    Write-AirspaceSnapshotFile $path { param($p) [IO.File]::WriteAllText($p,$value) }
}
$reader.GetAwaiter().GetResult()

# A locked desktop status file must not stop the normal worker entry point.
$hold = [IO.File]::OpenRead($path)
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'tools\Start-Airspace.ps1') -PreviewOnly -Once -DemoSeconds 0 -OutputDirectory $directory
    Check ($LASTEXITCODE -eq 0) 'A locked preview file terminated the worker'
} finally { $hold.Dispose() }
Check ((Read-AirspaceSnapshotText $path) -in @($first,$second)) 'Worker damaged a locked snapshot'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'tools\Start-Airspace.ps1') -PreviewOnly -Once -DemoSeconds 0 -OutputDirectory $directory
Check ($LASTEXITCODE -eq 0) 'Worker did not recover after the lock was released'
$meta = Read-AirspaceSnapshotText $path | ConvertFrom-Json
Check ($meta.mode -eq 'DEMO' -and $meta.displayed -gt 0) 'Worker did not publish valid metadata'
Write-Output 'PASS: atomic concurrent reads, transient lock retry, persistent lock cleanup, worker survival and recovery.'
