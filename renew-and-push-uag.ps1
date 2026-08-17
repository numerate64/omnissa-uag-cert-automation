param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\settings.json",

    [Parameter(Mandatory = $false)]
    [switch]$UploadOnly,

    [Parameter(Mandatory = $false)]
    [switch]$SkipUpload,

    [Parameter(Mandatory = $false)]
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StartedAt = Get-Date
$script:LogPath = $null

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
    param([string]$Path)

    $configDir = Split-Path -Parent $Path
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

function Get-ConfigValue {
    param(
        $Config,
        [string]$Name,
        $Default = $null
    )

    if ($Config.PSObject.Properties.Name -contains $Name) {
        return $Config.$Name
    }

    return $Default
}

function Protect-Secret {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    if ($Value.Length -le 6) {
        return '***'
    }

    return $Value.Substring(0, 3) + '***' + $Value.Substring($Value.Length - 3)
}

function ConvertTo-DisplayArgument {
    param([string[]]$Arguments)

    $secretNext = $false
    $secretFlags = @(
        '--route53secretaccesskey',
        '--pfxpassword'
    )

    $display = $Arguments | ForEach-Object {
        if ($secretNext) {
            $secretNext = $false
            '***'
        }
        elseif ($secretFlags -contains $_) {
            $secretNext = $true
            $_
        }
        elseif ($_ -match '\s') {
            '"' + $_ + '"'
        }
        else {
            $_
        }
    }

    return ($display -join ' ')
}

function Ensure-Directory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-ParentDirectory {
    param([string]$FilePath)

    $parent = Split-Path -Parent $FilePath
    Ensure-Directory -Path $parent
}

function Require-ConfigValue {
    param($Config, [string]$Name)

    $value = Get-ConfigValue -Config $Config -Name $Name
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        throw "Missing required config value: $Name"
    }
}

function Validate-Config {
    param($Config)

    $required = @(
        'HorizonFqdn',
        'LetsEncryptEmail',
        'WinAcmePath',
        'UagHosts',
        'UagUsername',
        'UagPassword',
        'UagCertificateTargets'
    )

    foreach ($name in $required) {
        Require-ConfigValue -Config $Config -Name $name
    }

    $uploadMode = Get-ConfigValue -Config $Config -Name 'UagUploadMode' -Default 'Pem'
    if ($uploadMode -notin @('Pem', 'Pfx')) {
        throw "UagUploadMode must be 'Pem' or 'Pfx'"
    }

    if ($uploadMode -eq 'Pem') {
        Require-ConfigValue -Config $Config -Name 'PemDirectory'
        Require-ConfigValue -Config $Config -Name 'FullChainPemPath'
        Require-ConfigValue -Config $Config -Name 'PrivateKeyPemPath'
        Ensure-Directory -Path $Config.PemDirectory
    }
    else {
        Require-ConfigValue -Config $Config -Name 'PfxPath'
        $hasPlainPfxPassword = -not [string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Config $Config -Name 'PfxPassword'))
        $hasEncryptedPfxPassword = -not [string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Config $Config -Name 'PfxPasswordProtected'))
        if (-not $hasPlainPfxPassword -and -not $hasEncryptedPfxPassword) {
            throw "Pfx mode requires PfxPassword or PfxPasswordProtected"
        }
        Ensure-ParentDirectory -FilePath $Config.PfxPath
    }

    if (-not (Test-Path $Config.WinAcmePath)) {
        throw "wacs.exe not found at $($Config.WinAcmePath)"
    }

    $useExistingRenewal = [bool](Get-ConfigValue -Config $Config -Name 'UseExistingWinAcmeRenewal' -Default $false)
    if ($useExistingRenewal) {
        Require-ConfigValue -Config $Config -Name 'WinAcmeRenewalId'
    }
    else {
        Require-ConfigValue -Config $Config -Name 'AwsAccessKeyId'
        Require-ConfigValue -Config $Config -Name 'AwsSecretAccessKey'
    }
}

function New-WinAcmeArguments {
    param($Config)

    $uploadMode = Get-ConfigValue -Config $Config -Name 'UagUploadMode' -Default 'Pem'
    $useExistingRenewal = [bool](Get-ConfigValue -Config $Config -Name 'UseExistingWinAcmeRenewal' -Default $false)
    $args = New-Object System.Collections.Generic.List[string]

    if ($useExistingRenewal) {
        $args.Add('--renew')
        $args.Add('--id')
        $args.Add([string]$Config.WinAcmeRenewalId)

        $baseUri = Get-ConfigValue -Config $Config -Name 'WinAcmeBaseUri'
        if (-not [string]::IsNullOrWhiteSpace([string]$baseUri)) {
            $args.Add('--baseuri')
            $args.Add([string]$baseUri)
        }

        $extraArgs = Get-ConfigValue -Config $Config -Name 'WacsAdditionalArguments' -Default @()
        foreach ($a in $extraArgs) {
            $args.Add([string]$a)
        }

        return [string[]]$args.ToArray()
    }

    $baseArgs = Get-ConfigValue -Config $Config -Name 'WacsBaseArguments' -Default @()
    foreach ($a in $baseArgs) {
        $args.Add([string]$a)
    }

    if ($baseArgs -notcontains '--target') {
        $args.Add('--target')
        $args.Add('manual')
    }

    if ($baseArgs -notcontains '--host') {
        $args.Add('--host')
        $args.Add([string]$Config.HorizonFqdn)
    }

    if ($baseArgs -notcontains '--validation') {
        $args.Add('--validation')
        $args.Add('route53')
    }

    if ($baseArgs -notcontains '--accepttos') {
        $args.Add('--accepttos')
    }

    if ($baseArgs -notcontains '--emailaddress') {
        $args.Add('--emailaddress')
        $args.Add([string]$Config.LetsEncryptEmail)
    }

    $args.Add('--route53accesskeyid')
    $args.Add([string]$Config.AwsAccessKeyId)
    $args.Add('--route53secretaccesskey')
    $args.Add([string]$Config.AwsSecretAccessKey)

    if ($uploadMode -eq 'Pem') {
        if ($baseArgs -notcontains '--store') {
            $args.Add('--store')
            $args.Add('pemfiles')
        }
        $args.Add('--pemfilespath')
        $args.Add([string]$Config.PemDirectory)
        if ($baseArgs -notcontains '--pemfilesname') {
            $args.Add('--pemfilesname')
            $args.Add([string]$Config.HorizonFqdn)
        }
    }
    else {
        if ($baseArgs -notcontains '--store') {
            $args.Add('--store')
            $args.Add('pfxfile')
        }
        $args.Add('--pfxfilepath')
        $args.Add([string]$Config.PfxPath)
        $args.Add('--pfxpassword')
        $args.Add([string]$Config.PfxPassword)
    }

    $extraArgs = Get-ConfigValue -Config $Config -Name 'WacsAdditionalArguments' -Default @()
    foreach ($a in $extraArgs) {
        $args.Add([string]$a)
    }

    return [string[]]$args.ToArray()
}

function Invoke-WinAcmeRenewal {
    param($Config)

    $args = New-WinAcmeArguments -Config $Config
    $displayArgs = ConvertTo-DisplayArgument -Arguments $args
    $winAcmeLogPath = [System.IO.Path]::ChangeExtension($script:LogPath, '.win-acme.log')

    Write-Log "Requesting/renewing certificate with win-acme for $($Config.HorizonFqdn)"
    Write-Log "win-acme log: $winAcmeLogPath"
    Write-Log "Running: `"$($Config.WinAcmePath)`" $displayArgs"

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
}

function Assert-CertificateFiles {
    param($Config)

    $uploadMode = Get-ConfigValue -Config $Config -Name 'UagUploadMode' -Default 'Pem'

    if ($uploadMode -eq 'Pem') {
        foreach ($path in @($Config.FullChainPemPath, $Config.PrivateKeyPemPath)) {
            if (-not (Test-Path $path)) {
                throw "Expected PEM file not found: $path"
            }
        }
    }
    else {
        if (-not (Test-Path $Config.PfxPath)) {
            throw "Expected PFX not found: $($Config.PfxPath)"
        }
    }
}

function Set-TlsPolicy {
    param($Config)

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    $verifyTls = [bool](Get-ConfigValue -Config $Config -Name 'UagVerifyTls' -Default $true)
    if ($verifyTls) {
        return
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Write-Log 'UagVerifyTls is false; PowerShell 7+ calls will use -SkipCertificateCheck.'
        return
    }

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
    Write-Log 'UagVerifyTls is false; Windows PowerShell certificate validation is disabled for this process.'
}

function Invoke-UagRestMethod {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Put')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $false)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [string]$Body,

        [Parameter(Mandatory = $false)]
        [string]$ContentType,

        [Parameter(Mandatory = $false)]
        [switch]$SkipCertificateCheck
    )

    $params = @{
        Method = $Method
        Uri = $Uri
    }

    if ($Headers) { $params.Headers = $Headers }
    if ($Body) { $params.Body = $Body }
    if ($ContentType) { $params.ContentType = $ContentType }
    if ($SkipCertificateCheck -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params.SkipCertificateCheck = $true
    }

    return Invoke-RestMethod @params
}

function New-UagAuthHeader {
    param($Config)

    $authMode = Get-ConfigValue -Config $Config -Name 'UagAuthMode' -Default 'Basic'

    if ($authMode -eq 'Basic') {
        $pair = "{0}:{1}" -f $Config.UagUsername, $Config.UagPassword
        $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
        return @{ Authorization = "Basic $encoded"; Accept = 'application/json' }
    }

    if ($authMode -ne 'Jwt') {
        throw "UagAuthMode must be 'Basic' or 'Jwt'"
    }

    $loginUri = "https://$($Config.UagHosts[0]):9443/rest/v1/jwt/login"
    $body = @{
        username = [string]$Config.UagUsername
        password = [string]$Config.UagPassword
        refreshTokenExpiryInHours = 24
    } | ConvertTo-Json

    Write-Log "Authenticating to UAG API at $loginUri as $($Config.UagUsername)"
    $skipCertCheck = -not [bool](Get-ConfigValue -Config $Config -Name 'UagVerifyTls' -Default $true)
    $response = Invoke-UagRestMethod -Method Post -Uri $loginUri -Body $body -ContentType 'application/json' -Headers @{Accept='application/json'} -SkipCertificateCheck:$skipCertCheck
    if (-not $response.accessToken) {
        throw "UAG JWT login succeeded but no accessToken was returned"
    }

    return @{ Authorization = "Bearer $($response.accessToken)"; Accept = 'application/json' }
}

function Get-PemText {
    param([string]$Path)

    return ((Get-Content -Path $Path) -join "`n") + "`n"
}

function Unprotect-DpapiString {
    param([string]$ProtectedValue)

    if ([string]::IsNullOrWhiteSpace($ProtectedValue)) {
        return $null
    }

    if (-not $ProtectedValue.StartsWith('enc-')) {
        return $ProtectedValue
    }

    Add-Type -AssemblyName System.Security
    $cipher = [Convert]::FromBase64String($ProtectedValue.Substring(4))
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $cipher,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )

    return [Text.Encoding]::UTF8.GetString($plainBytes).Trim([char]0)
}

function Get-PfxPassword {
    param($Config)

    $plain = Get-ConfigValue -Config $Config -Name 'PfxPassword'
    if (-not [string]::IsNullOrWhiteSpace([string]$plain)) {
        return [string]$plain
    }

    $protected = Get-ConfigValue -Config $Config -Name 'PfxPasswordProtected'
    return Unprotect-DpapiString -ProtectedValue ([string]$protected)
}

function Invoke-UagPemCertificateUpload {
    param(
        $Config,
        [string]$UagHost,
        [string]$Target,
        [hashtable]$Headers
    )

    $uri = "https://$($UagHost):9443/rest/v1/config/certs/ssl/$Target"
    $bodyObject = @{
        privateKeyPem = Get-PemText -Path $Config.PrivateKeyPemPath
        certChainPem = Get-PemText -Path $Config.FullChainPemPath
    }
    $body = ($bodyObject | ConvertTo-Json -Depth 4).Replace('\\n', '\n')
    $skipCertCheck = -not [bool](Get-ConfigValue -Config $Config -Name 'UagVerifyTls' -Default $true)

    Write-Log "Uploading PEM certificate to $UagHost target $Target"
    $result = Invoke-UagRestMethod -Method Put -Uri $uri -Headers $Headers -Body $body -ContentType 'application/json' -SkipCertificateCheck:$skipCertCheck
    if ($result) {
        Write-Log "UAG $UagHost/$Target response: $(($result | ConvertTo-Json -Depth 8 -Compress))"
    }
}

function Invoke-UagPfxCertificateUpload {
    param(
        $Config,
        [string]$UagHost,
        [string]$Target,
        [hashtable]$Headers
    )

    $template = Get-ConfigValue -Config $Config -Name 'UagPfxEndpointTemplate' -Default 'https://{0}:9443/rest/v1/config/certificates/server'
    $uri = $template -f $UagHost, $Target
    $pfxBytes = [System.IO.File]::ReadAllBytes([string]$Config.PfxPath)
    $pfxBase64 = [System.Convert]::ToBase64String($pfxBytes)
    $pfxPassword = Get-PfxPassword -Config $Config
    $bodyObject = @{
        format = 'PFX'
        password = $pfxPassword
        certificateScope = $Target
        content = $pfxBase64
    }
    $body = $bodyObject | ConvertTo-Json -Depth 5
    $skipCertCheck = -not [bool](Get-ConfigValue -Config $Config -Name 'UagVerifyTls' -Default $true)

    Write-Log "Uploading PFX certificate to $UagHost target $Target using $uri"
    $result = Invoke-UagRestMethod -Method Put -Uri $uri -Headers $Headers -Body $body -ContentType 'application/json' -SkipCertificateCheck:$skipCertCheck
    if ($result) {
        Write-Log "UAG $UagHost/$Target response: $(($result | ConvertTo-Json -Depth 8 -Compress))"
    }
}

function Invoke-UagCertificateUpload {
    param($Config, [hashtable]$Headers)

    $uploadMode = Get-ConfigValue -Config $Config -Name 'UagUploadMode' -Default 'Pem'

    foreach ($uagHost in $Config.UagHosts) {
        foreach ($target in $Config.UagCertificateTargets) {
            if ($target -notin @('END_USER', 'ADMIN')) {
                throw "Unsupported UAG certificate target '$target'. Use END_USER and/or ADMIN."
            }

            if ($uploadMode -eq 'Pem') {
                Invoke-UagPemCertificateUpload -Config $Config -UagHost $uagHost -Target $target -Headers $Headers
            }
            else {
                Invoke-UagPfxCertificateUpload -Config $Config -UagHost $uagHost -Target $target -Headers $Headers
            }
        }
    }
}

function Test-CertificateExpiry {
    param($Config)

    $uploadMode = Get-ConfigValue -Config $Config -Name 'UagUploadMode' -Default 'Pem'

    if ($uploadMode -eq 'Pfx') {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
        $cert.Import($Config.PfxPath, (Get-PfxPassword -Config $Config), 'Exportable,PersistKeySet')
        Write-Log "Certificate subject: $($cert.Subject)"
        Write-Log "Certificate expires: $($cert.NotAfter.ToString('u'))"
        return
    }

    $fullChain = Get-PemText -Path $Config.FullChainPemPath
    $match = [regex]::Match($fullChain, '-----BEGIN CERTIFICATE-----(?<body>.*?)-----END CERTIFICATE-----', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        throw "Could not find a certificate block in $($Config.FullChainPemPath)"
    }

    $certBytes = [Convert]::FromBase64String(($match.Groups['body'].Value -replace '\s', ''))
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
    Write-Log "Certificate subject: $($cert.Subject)"
    Write-Log "Certificate expires: $($cert.NotAfter.ToString('u'))"
}

function Write-RunSummary {
    param($Config)

    $elapsed = (Get-Date) - $script:StartedAt
    Write-Log "Target public FQDN: $($Config.HorizonFqdn)"
    Write-Log "Horizon URL: https://$($Config.HorizonFqdn):8443"
    Write-Log "UAG host(s): $($Config.UagHosts -join ', ')"
    Write-Log "UAG target(s): $($Config.UagCertificateTargets -join ', ')"
    if ($Config.PSObject.Properties.Name -contains 'AwsAccessKeyId') {
        Write-Log "AWS key: $(Protect-Secret -Value $Config.AwsAccessKeyId)"
    }
    Write-Log "Session log: $script:LogPath"
    Write-Log ("Elapsed: {0:n1} seconds" -f $elapsed.TotalSeconds)
}

Initialize-LogFile -Path $ConfigPath
Write-Log "Starting run with config: $ConfigPath"
$config = Get-Config -Path $ConfigPath
Validate-Config -Config $config
Set-TlsPolicy -Config $config

if ($ValidateOnly) {
    Write-Log 'Configuration validation completed.'
    Write-RunSummary -Config $config
    return
}

if (-not $UploadOnly) {
    Invoke-WinAcmeRenewal -Config $config
}
else {
    Write-Log 'UploadOnly requested; skipping win-acme renewal.'
}

Assert-CertificateFiles -Config $config
Test-CertificateExpiry -Config $config

if (-not $SkipUpload) {
    $headers = New-UagAuthHeader -Config $config
    Invoke-UagCertificateUpload -Config $config -Headers $headers
}
else {
    Write-Log 'SkipUpload requested; certificate was not uploaded to UAG.'
}

Write-RunSummary -Config $config
Write-Log 'Completed.'
