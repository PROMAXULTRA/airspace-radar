# Publish complete files so a reader sees either the old or the new snapshot.
function Write-AirspaceSnapshotFile {
    param([string]$Path, [scriptblock]$Write)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        & $Write $temporary
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) {
                    [IO.File]::Replace($temporary,$Path,[NullString]::Value)
                } else {
                    [IO.File]::Move($temporary,$Path)
                }
                return
            } catch [IO.IOException] {
                $code = $_.Exception.GetBaseException().HResult -band 0xffff
                if ($code -notin @(32,33) -or $attempt -eq 9) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Read-AirspaceSnapshotText {
    param([string]$Path)
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $reader = [IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}
