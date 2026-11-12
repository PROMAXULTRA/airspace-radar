param(
    [string]$ClientId = '',
    [string]$CredentialPath = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'XiaoAirspace\opensky.credential.xml')
)
$ErrorActionPreference='Stop'
if(-not $ClientId){$ClientId=Read-Host 'OpenSky client_id'}
if([string]::IsNullOrWhiteSpace($ClientId)){throw 'client_id is required.'}
$secret=Read-Host 'OpenSky client_secret (hidden)' -AsSecureString
if($secret.Length -eq 0){throw 'client_secret is required.'}
$credential=[PSCredential]::new($ClientId.Trim(),$secret)
$directory=Split-Path -Parent $CredentialPath
New-Item -ItemType Directory -Force -Path $directory | Out-Null
# On Windows Export-Clixml protects SecureString with DPAPI for this user.
# The plaintext secret is never put in arguments, source files or logs.
$credential | Export-Clixml -LiteralPath $CredentialPath -Force
Write-Output 'OpenSky credential saved with Windows DPAPI for the current user.'
