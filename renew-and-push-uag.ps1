param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\settings.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StartedAt = Get-Date

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Host $line
    if ($script:LogPath) {
        Add-Content -Path $script:LogPath -Value $line
    }
}

function Initialize-LogFile {
    param([string]$ConfigPath)
    $configDir = Split-Path -Parent $ConfigPath
    if ([string]::IsNullOrWhiteSpace($configDir)) {
        $configDir = (Get-Location).Path
    }
    $logDir = Join-Path $configDir 'logs'
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $script:LogPath = Join-Path $logDir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-renew-and-push-uag.log')
    New-Item -ItemType File -Path $script:LogPath -Force | Out-Null
}

function Get-Config {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Config file not found: $Path"
    }
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Ensure-ParentDirectory {
    param([string]$FilePath)
    $parent = Split-Path -Parent $FilePath
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Validate-Config {
    param($Config)

    $required = @(
        'HorizonFqdn',
        'LetsEncryptEmail',
        'WinAcmePath',
        'PfxPath',
        'PfxPassword',
        'AwsAccessKeyId',
        'AwsSecretAccessKey',
        'UagHost',
        'UagUsername',
        'UagPassword'
    )

    foreach ($name in $required) {
        $value = $Config.$name
        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            throw "Missing required config value: $name"
        }
    }

    Ensure-ParentDirectory -FilePath $Config.PfxPath
}

function Invoke-WinAcmeRenewal {
    param($Config)

    if (-not (Test-Path $Config.WinAcmePath)) {
        throw "wacs.exe not found at $($Config.WinAcmePath)"
    }

    $args = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Config.WacsBaseArguments) { $args.Add([string]$a) }
    $args.Add('--route53accesskeyid')
    $args.Add([string]$Config.AwsAccessKeyId)
    $args.Add('--route53secretaccesskey')
    $args.Add([string]$Config.AwsSecretAccessKey)
    $args.Add('--pfxfilepath')
    $args.Add([string]$Config.PfxPath)
    $args.Add('--pfxpassword')
    $args.Add([string]$Config.PfxPassword)
    $args.Add('--verbose')

    $commandLine = '"' + $Config.WinAcmePath + '" ' + (($args | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' ')

    $winAcmeLogPath = [System.IO.Path]::ChangeExtension($script:LogPath, '.win-acme.log')

    Write-Log "Requesting/renewing certificate with win-acme for $($Config.HorizonFqdn)"
    Write-Log "win-acme log: $winAcmeLogPath"
    Write-Log "Running: $commandLine"

    $output = & $Config.WinAcmePath @args 2>&1
    $exitCode = $LASTEXITCODE

    if ($output) {
        $output | Tee-Object -FilePath $winAcmeLogPath -Append | ForEach-Object {
            Write-Log "[wacs] $_"
        }
    }

    if ($exitCode -ne 0) {
        throw "win-acme exited with code $exitCode. See $winAcmeLogPath"
    }

    if (-not (Test-Path $Config.PfxPath)) {
        throw "Expected PFX not found at $($Config.PfxPath)"
    }

    Write-Log "PFX created at $($Config.PfxPath)"
}

function New-UagAuthHeader {
    param($Config)

    $loginUri = "https://$($Config.UagHost):9443/rest/v1/jwt/login"
    $body = @{
        username = [string]$Config.UagUsername
        password = [string]$Config.UagPassword
        refreshTokenExpiryInHours = 24
    } | ConvertTo-Json

    Write-Log "Authenticating to UAG API at $loginUri"

    if (-not $Config.UagVerifyTls) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@ -ErrorAction SilentlyContinue
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }

    $response = Invoke-RestMethod -Method Post -Uri $loginUri -Body $body -ContentType 'application/json' -Headers @{Accept='application/json'}
    if (-not $response.accessToken) {
        throw "UAG login succeeded but no accessToken was returned"
    }

    return @{ Authorization = "Bearer $($response.accessToken)"; Accept = 'application/json' }
}

function Invoke-UagCertificateUpload {
    param($Config, [hashtable]$Headers)

    $pfxBytes = [System.IO.File]::ReadAllBytes([string]$Config.PfxPath)
    $pfxBase64 = [System.Convert]::ToBase64String($pfxBytes)

    # NOTE:
    # The exact endpoint/payload may vary by UAG version.
    # Adjust the URI/body below to match your appliance's API reference.
    $uri = "https://$($Config.UagHost):9443/rest/v1/config/certificates/server"
    $bodyObject = @{
        format = 'PFX'
        password = [string]$Config.PfxPassword
        certificateScope = [string]$Config.UagCertificateScope
        content = $pfxBase64
    }
    $body = $bodyObject | ConvertTo-Json -Depth 5

    Write-Log "Uploading certificate to UAG endpoint $uri"
    try {
        $result = Invoke-RestMethod -Method Put -Uri $uri -Headers $Headers -Body $body -ContentType 'application/json'
        Write-Log "UAG API response: $(($result | ConvertTo-Json -Depth 8 -Compress))"
    }
    catch {
        Write-Warning "Upload to $uri failed. Your UAG may use a different endpoint or payload. Error: $($_.Exception.Message)"
        throw
    }
}

function Test-CertificateExpiry {
    param([string]$PfxPath, [string]$Password)
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    $cert.Import($PfxPath, $Password, 'Exportable,PersistKeySet')
    Write-Log "Certificate subject: $($cert.Subject)"
    Write-Log "Certificate expires: $($cert.NotAfter.ToString('u'))"
}

function Write-RunSummary {
    param($Config)
    $elapsed = (Get-Date) - $script:StartedAt
    Write-Log "Target host: $($Config.HorizonFqdn)"
    Write-Log "UAG host: $($Config.UagHost)"
    Write-Log "Session log: $script:LogPath"
    Write-Log ("Elapsed: {0:n1} seconds" -f $elapsed.TotalSeconds)
}

Initialize-LogFile -ConfigPath $ConfigPath
Write-Log "Starting run with config: $ConfigPath"
$config = Get-Config -Path $ConfigPath
Validate-Config -Config $config
Invoke-WinAcmeRenewal -Config $config
Test-CertificateExpiry -PfxPath $config.PfxPath -Password $config.PfxPassword
$headers = New-UagAuthHeader -Config $config
Invoke-UagCertificateUpload -Config $config -Headers $headers
Write-RunSummary -Config $config
Write-Log 'Completed.'
