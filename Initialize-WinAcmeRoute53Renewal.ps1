param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\settings.json",

    [Parameter(Mandatory = $false)]
    [switch]$Force
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

$config = Get-Config -Path $ConfigPath
foreach ($name in @('HorizonFqdn', 'LetsEncryptEmail', 'WinAcmePath', 'PfxPath')) {
    Require-ConfigValue -Config $config -Name $name
}

if (-not (Test-Path $config.WinAcmePath)) {
    throw "wacs.exe not found at $($config.WinAcmePath)"
}

$awsAccessKeyId = Read-Host 'AWS Route 53 access key ID'
$awsSecretAccessKey = ConvertFrom-SecureStringToPlainText -SecureString (Read-Host 'AWS Route 53 secret access key' -AsSecureString)
$pfxPassword = Get-PfxPassword -Config $config

$args = New-Object System.Collections.Generic.List[string]
$args.Add('--target')
$args.Add('manual')
$args.Add('--host')
$args.Add([string]$config.HorizonFqdn)
$args.Add('--validation')
$args.Add('route53')
$args.Add('--route53accesskeyid')
$args.Add($awsAccessKeyId)
$args.Add('--route53secretaccesskey')
$args.Add($awsSecretAccessKey)
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

Write-Host "Running: `"$($config.WinAcmePath)`" $(ConvertTo-DisplayArgument -Arguments $args.ToArray())"
$winAcmeArguments = [string[]]$args.ToArray()
& $config.WinAcmePath @winAcmeArguments
if ($LASTEXITCODE -ne 0) {
    throw "win-acme exited with code $LASTEXITCODE"
}

$renewalRoot = Join-Path $env:ProgramData 'win-acme'
$latestRenewal = Get-ChildItem -Path $renewalRoot -Filter '*.renewal.json' -Recurse |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($latestRenewal) {
    $renewal = Get-Content -Raw -Path $latestRenewal.FullName | ConvertFrom-Json
    Write-Host "Latest renewal profile: $($latestRenewal.FullName)"
    Write-Host "Set WinAcmeRenewalId in settings.json to: $($renewal.Id)"
}
