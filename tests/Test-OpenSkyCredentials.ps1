$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $project 'tools\OpenSkyCredentials.ps1')
function Check($condition,$message){if(-not $condition){throw $message}}
$testRoot=Join-Path $env:TEMP ('opensky-credentials-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $testRoot 'airspace_usb') | Out-Null
$jsonPath=Join-Path $testRoot 'airspace_usb\credentials.json'
foreach($data in @(@{clientId='test-client';clientSecret='test-secret'},@{client_id='test-client';client_secret='test-secret'})){
    $data | ConvertTo-Json | Set-Content -LiteralPath $jsonPath -Encoding utf8
    $credential=Import-OpenSkyClientCredential -Path $jsonPath
    Check ($credential.UserName -eq 'test-client' -and $credential.GetNetworkCredential().Password -eq 'test-secret') 'JSON credential fields parsed incorrectly'
}
Check ((Resolve-OpenSkyCredentialPath -ProjectRoot $testRoot) -eq $jsonPath) 'Project JSON was not discovered automatically'
Check ((Resolve-OpenSkyCredentialPath -RequestedPath $jsonPath -ProjectRoot $testRoot) -eq $jsonPath) 'Explicit JSON path was not respected'
$xmlPath=Join-Path $testRoot 'encrypted.xml'
$credential | Export-Clixml -LiteralPath $xmlPath
$roundTrip=Import-OpenSkyClientCredential -Path $xmlPath
Check ($roundTrip.UserName -eq 'test-client' -and $roundTrip.GetNetworkCredential().Password -eq 'test-secret') 'Existing DPAPI XML support regressed'
foreach($invalid in @('{"clientId":"test-client","clientSecret":"do-not-log",', '{"clientId":"test-client"}', '{"clientId":"test-client","clientSecret":" "}')){
    Set-Content -LiteralPath $jsonPath -Value $invalid -Encoding utf8
    $rejected=$false
    try { $null=Import-OpenSkyClientCredential -Path $jsonPath }
    catch { $rejected=$true;Check (-not $_.Exception.Message.Contains('do-not-log')) 'Parser error leaked credential contents' }
    Check $rejected 'Invalid credential JSON was accepted'
}
$missing=Join-Path $testRoot 'missing.json'
$rejected=$false
try { $null=Resolve-OpenSkyCredentialPath -RequestedPath $missing -ProjectRoot $testRoot }
catch { $rejected=$true }
Check $rejected 'Explicit missing credential file must fail instead of selecting another credential'

# Verify the whole sender stops before anonymous polling, network or USB access.
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName='powershell.exe'
$start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $project 'tools\Start-Airspace.ps1')+'" -Mode Live -PreviewOnly -Once -CredentialPath "'+$missing+'"'
$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$start.EnvironmentVariables.Remove('OPENSKY_CLIENT_ID');$start.EnvironmentVariables.Remove('OPENSKY_CLIENT_SECRET')
$process=[Diagnostics.Process]::Start($start)
try {
    if(-not $process.WaitForExit(15000)){$process.Kill();throw 'Missing credential check did not stop promptly'}
    $stdout=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd()
    Check ($process.ExitCode -ne 0 -and $stderr.Contains('credential file not found')) 'Sender did not report missing explicit credential file'
    Check (-not $stdout.Contains('OpenSky live polling') -and -not $stdout.Contains('USB display connected')) 'Sender continued after missing explicit credentials'
} finally { $process.Dispose() }
Write-Output 'PASS: JSON formats, automatic file discovery, explicit paths, DPAPI XML, invalid JSON, secret-free errors and no anonymous fallback for missing files.'
