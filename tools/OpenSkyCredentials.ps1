# Credential parsing deliberately never includes source text or secret values
# in errors. Existing OpenSky JSON downloads and Windows DPAPI XML both work.
function Resolve-OpenSkyCredentialPath {
    param([string]$RequestedPath, [string]$ProjectRoot)
    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
            throw "OpenSky credential file not found: $RequestedPath. Use -CredentialPath .\airspace_usb\credentials.json for an OpenSky JSON download."
        }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }
    $candidates = @(
        (Join-Path $ProjectRoot 'airspace_usb\credentials.json'),
        (Join-Path $ProjectRoot 'credentials.json'),
        (Join-Path $ProjectRoot '.local\opensky.credential.xml'),
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'XiaoAirspace\opensky.credential.xml')
    )
    if ($env:USERPROFILE) { $candidates += Join-Path $env:USERPROFILE 'AppData\Local\XiaoAirspace\opensky.credential.xml' }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    return $null
}

function Import-OpenSkyClientCredential {
    param([string]$Path)
    if ([IO.Path]::GetExtension($Path) -ieq '.json') {
        try { $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
        catch { throw 'Unable to read OpenSky credential JSON. Check that it is valid JSON; its contents were not logged.' }
        $id = $data.clientId
        if ($null -eq $id) { $id = $data.client_id }
        $secret = $data.clientSecret
        if ($null -eq $secret) { $secret = $data.client_secret }
        if (-not ($id -is [string]) -or -not ($secret -is [string]) -or [string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($secret)) {
            throw 'OpenSky credential JSON must contain non-empty clientId and clientSecret (or client_id and client_secret).'
        }
        return [PSCredential]::new($id.Trim(), (ConvertTo-SecureString -String $secret -AsPlainText -Force))
    }
    try {
        $credential = Import-Clixml -LiteralPath $Path
        if (-not ($credential -is [PSCredential]) -or [string]::IsNullOrWhiteSpace($credential.UserName) -or $credential.Password.Length -eq 0) { throw 'Invalid credential' }
        # Force decryption here so errors are reported before the viewer starts.
        if (-not $credential.GetNetworkCredential().Password) { throw 'Empty credential' }
        return $credential
    } catch {
        throw 'Unable to decrypt OpenSky XML for this Windows user. Use the original credentials.json or run tools\Set-OpenSkyCredential.ps1 again.'
    }
}
