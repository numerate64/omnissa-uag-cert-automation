param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\settings.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] $Message"
}

function Get-Config {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Config file not found: $Path"
    }
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
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

    Write-Log "Requesting/renewing certificate with win-acme for $($Config.HorizonFqdn)"
    & $Config.WinAcmePath @args
    if ($LASTEXITCODE -ne 0) {
        throw "win-acme exited with code $LASTEXITCODE"
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

$config = Get-Config -Path $ConfigPath
Invoke-WinAcmeRenewal -Config $config
Test-CertificateExpiry -PfxPath $config.PfxPath -Password $config.PfxPassword
$headers = New-UagAuthHeader -Config $config
Invoke-UagCertificateUpload -Config $config -Headers $headers
Write-Log 'Completed.'
