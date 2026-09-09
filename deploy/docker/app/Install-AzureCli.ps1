<#
.SYNOPSIS
Displays Azure CLI installation guidance for the detected Linux distribution.

.DESCRIPTION
The dashboard does not invoke sudo or change Linux package repositories from
its web process. Run the appropriate Microsoft-documented installation steps
in an administrative terminal, then refresh the setup page.
#>

$ErrorActionPreference = 'Stop'

if (-not $IsLinux) {
    throw 'This installer guidance is for Linux only.'
}

if (Get-Command az -ErrorAction SilentlyContinue) {
    Write-Output 'Azure CLI is already installed.'
    exit 0
}

$release = @{}
if (Test-Path -LiteralPath '/etc/os-release') {
    foreach ($line in Get-Content -LiteralPath '/etc/os-release') {
        if ($line -match '^([A-Z_]+)=(.*)$') {
            $release[$matches[1]] = $matches[2].Trim().Trim('"')
        }
    }
}

$identity = "$($release.ID) $($release.ID_LIKE)".ToLowerInvariant()
Write-Output 'Azure CLI is not installed or is not available on PATH.'
Write-Output 'Install it in a separate terminal, then refresh this setup page.'
Write-Output ''

if ($identity -match 'ubuntu|debian') {
    Write-Output 'Detected an Ubuntu/Debian-family distribution.'
    Write-Output 'Follow: https://learn.microsoft.com/cli/azure/install-azure-cli-linux?pivots=apt'
}
elseif ($identity -match 'fedora|rhel|centos|rocky|almalinux') {
    Write-Output 'Detected a Fedora/RHEL-family distribution.'
    Write-Output 'Follow: https://learn.microsoft.com/cli/azure/install-azure-cli-linux?pivots=dnf'
}
else {
    Write-Output "Distribution '$($release.PRETTY_NAME)' was not recognized."
    Write-Output 'Choose the appropriate method at:'
    Write-Output 'https://learn.microsoft.com/cli/azure/install-azure-cli-linux'
}

Write-Output ''
Write-Output 'The dashboard intentionally does not run sudo or modify package repositories.'
