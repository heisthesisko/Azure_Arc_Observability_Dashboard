param(
    [string]$TenantId,
    [Parameter(Mandatory)]
    [string]$AzPath,
    [string]$ConfigDirectory,
    [switch]$AllowNoSubscriptions
)

<#
.SYNOPSIS
Runs Azure CLI device-code authentication for the setup workflow.

.DESCRIPTION
This helper executes in a child process so server.ps1 can continue serving the
setup page while Azure CLI waits for the user to authenticate in a browser.
Output is intentionally suppressed to avoid persisting account details; the
device-code prompt is written by Azure CLI to the redirected error stream.
#>

$ErrorActionPreference = 'Stop'
if ($ConfigDirectory) {
    New-Item -ItemType Directory -Path $ConfigDirectory -Force | Out-Null
    if ($IsLinux) {
        [IO.File]::SetUnixFileMode(
            $ConfigDirectory,
            [IO.UnixFileMode]::UserRead -bor
            [IO.UnixFileMode]::UserWrite -bor
            [IO.UnixFileMode]::UserExecute
        )
    }
    $env:AZURE_CONFIG_DIR = $ConfigDirectory
}
$arguments = @('login', '--use-device-code', '--output', 'none')
if ($TenantId) {
    $arguments += @('--tenant', $TenantId)
}
if ($AllowNoSubscriptions) {
    $arguments += '--allow-no-subscriptions'
}

& $AzPath @arguments
exit $LASTEXITCODE
