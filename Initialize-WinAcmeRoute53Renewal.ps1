param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\settings.json",

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$RunRenewAndPush,

    [Parameter(Mandatory = $false)]
    [string]$RenewAndPushPath,

    [Parameter(Mandatory = $false)]
    [string]$AwsAccessKeyId,

    [Parameter(Mandatory = $false)]
    [string]$AwsSecretAccessKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Require-ConfigValue {
    param($Config, [string]$Name)

    $value = Get-ConfigValue -Config $Config -Name $Name
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        throw "Missing required config value: $Name"
    }
}

function ConvertFrom-SecureStringToPlainText {
    param([securestring]$SecureString)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
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
    $unprotected = Unprotect-DpapiString -ProtectedValue ([string]$protected)
    if (-not [string]::IsNullOrWhiteSpace([string]$unprotected)) {
        return $unprotected
    }

    return ConvertFrom-SecureStringToPlainText -SecureString (Read-Host 'PFX export password' -AsSecureString)
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

function Save-RenewalId {
    param(
        [string]$Path,
        [string]$RenewalId
    )

    if ([string]::IsNullOrWhiteSpace($RenewalId)) {
        throw 'Cannot save an empty win-acme renewal ID.'
    }

    $current = Get-Config -Path $Path

    if ($current.PSObject.Properties.Name -contains 'WinAcmeRenewalId') {
        $current.WinAcmeRenewalId = $RenewalId
    }
    else {
        $current | Add-Member -NotePropertyName 'WinAcmeRenewalId' -NotePropertyValue $RenewalId
    }

    if ($current.PSObject.Properties.Name -contains 'UseExistingWinAcmeRenewal') {
        $current.UseExistingWinAcmeRenewal = $true
    }
    else {
        $current | Add-Member -NotePropertyName 'UseExistingWinAcmeRenewal' -NotePropertyValue $true
    }

    $current | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

$config = Get-Config -Path $ConfigPath
foreach ($name in @('HorizonFqdn', 'LetsEncryptEmail', 'WinAcmePath', 'PfxPath')) {
    Require-ConfigValue -Config $config -Name $name
}

if (-not (Test-Path $config.WinAcmePath)) {
    throw "wacs.exe not found at $($config.WinAcmePath)"
}

if ([string]::IsNullOrWhiteSpace($AwsAccessKeyId)) {
    $AwsAccessKeyId = [Environment]::GetEnvironmentVariable('AWS_ACCESS_KEY_ID', 'Process')
}

if ([string]::IsNullOrWhiteSpace($AwsSecretAccessKey)) {
    $AwsSecretAccessKey = [Environment]::GetEnvironmentVariable('AWS_SECRET_ACCESS_KEY', 'Process')
}

if ([string]::IsNullOrWhiteSpace($AwsAccessKeyId)) {
    $AwsAccessKeyId = Read-Host 'AWS Route 53 access key ID'
}

if ([string]::IsNullOrWhiteSpace($AwsSecretAccessKey)) {
    $AwsSecretAccessKey = ConvertFrom-SecureStringToPlainText -SecureString (Read-Host 'AWS Route 53 secret access key' -AsSecureString)
}

$pfxPassword = Get-PfxPassword -Config $config

$args = New-Object System.Collections.Generic.List[string]
$args.Add('--target')
$args.Add('manual')
$args.Add('--host')
$args.Add([string]$config.HorizonFqdn)
$args.Add('--validation')
$args.Add('route53')
$args.Add('--route53accesskeyid')
$args.Add($AwsAccessKeyId)
$args.Add('--route53secretaccesskey')
$args.Add($AwsSecretAccessKey)
$args.Add('--source')
$args.Add('manual')
$args.Add('--installation')
$args.Add('none')
$args.Add('--store')
$args.Add('pfxfile')
$args.Add('--pfxfilepath')
$args.Add([string]$config.PfxPath)
$args.Add('--pfxpassword')
$args.Add($pfxPassword)
$args.Add('--accepttos')
$args.Add('--emailaddress')
$args.Add([string]$config.LetsEncryptEmail)

$baseUri = Get-ConfigValue -Config $config -Name 'WinAcmeBaseUri'
if (-not [string]::IsNullOrWhiteSpace([string]$baseUri)) {
    $args.Add('--baseuri')
    $args.Add([string]$baseUri)
}

if ($Force) {
    $args.Add('--force')
}

$setupStartedAt = Get-Date
Write-Host "Running: `"$($config.WinAcmePath)`" $(ConvertTo-DisplayArgument -Arguments $args.ToArray())"
$winAcmeArguments = [string[]]$args.ToArray()
& $config.WinAcmePath @winAcmeArguments
if ($LASTEXITCODE -ne 0) {
    throw "win-acme exited with code $LASTEXITCODE"
}

$renewalRoot = Join-Path $env:ProgramData 'win-acme'
$latestRenewal = Get-ChildItem -Path $renewalRoot -Filter '*.renewal.json' -Recurse |
    Where-Object { $_.LastWriteTime -ge $setupStartedAt } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $latestRenewal) {
    throw 'win-acme completed, but no new or updated renewal profile was found.'
}

$renewal = Get-Content -Raw -Path $latestRenewal.FullName | ConvertFrom-Json
Save-RenewalId -Path $ConfigPath -RenewalId ([string]$renewal.Id)
Write-Host "Latest renewal profile: $($latestRenewal.FullName)"
Write-Host "Saved WinAcmeRenewalId in ${ConfigPath}: $($renewal.Id)"
Write-Host 'UseExistingWinAcmeRenewal is now true for renew-and-push-uag.ps1.'

if ($RunRenewAndPush) {
    if ([string]::IsNullOrWhiteSpace($RenewAndPushPath)) {
        $scriptRoot = Split-Path -Parent $PSCommandPath
        if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
            $scriptRoot = (Get-Location).Path
        }

        $RenewAndPushPath = Join-Path $scriptRoot 'renew-and-push-uag.ps1'
    }

    if (-not (Test-Path $RenewAndPushPath)) {
        throw "renew-and-push-uag.ps1 not found at $RenewAndPushPath"
    }

    Write-Host "Running UAG upload with: $RenewAndPushPath"
    & $RenewAndPushPath -ConfigPath $ConfigPath -UploadOnly
}
