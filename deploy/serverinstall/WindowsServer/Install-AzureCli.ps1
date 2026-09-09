param(
    [switch]$Elevated
)

<#
.SYNOPSIS
Installs the official Microsoft Azure CLI package when it is not already present.

.DESCRIPTION
Requests elevation only when required, downloads the current x64 MSI from
Microsoft, validates its Authenticode signature, and performs a quiet install.
The temporary installer is removed whether installation succeeds or fails.
#>

$ErrorActionPreference = 'Stop'

if (Get-Command az -ErrorAction SilentlyContinue) {
    Write-Output 'Azure CLI is already installed.'
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdministrator) {
    if ($Elevated) {
        throw 'Administrator elevation was requested but was not granted.'
    }

    # Relaunch only this narrow installer helper with administrative privileges.
    $process = Start-Process -FilePath (Get-Command pwsh).Source -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Elevated'
    )
    exit $process.ExitCode
}

$installerPath = Join-Path $env:TEMP "AzureCLI-$PID.msi"
try {
    Write-Output 'Downloading the signed Microsoft Azure CLI installer...'
    Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindowsx64' -OutFile $installerPath -UseBasicParsing

    $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
    # Do not execute the downloaded MSI unless Windows validates Microsoft as its signer.
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
        throw "Azure CLI installer signature validation failed: $($signature.Status)."
    }

    Write-Output 'Installing Azure CLI...'
    $installer = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -Wait -PassThru -ArgumentList @(
        '/i', "`"$installerPath`"", '/qn', '/norestart'
    )
    if ($installer.ExitCode -notin @(0, 3010)) {
        throw "Azure CLI installation failed with MSI exit code $($installer.ExitCode)."
    }

    Write-Output 'Azure CLI installation completed.'
}
finally {
    Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
}
