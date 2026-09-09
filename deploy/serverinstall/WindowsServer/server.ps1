param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8766,

    [string]$SubscriptionId,

    [switch]$NoBrowser,

    # Enterprise-scale tuning. Defaults are sized for a single subscription with up to
    # roughly 50,000 Arc-enabled servers; all of it is bounded by PowerShell 7 / .NET
    # facilities that ship in the box -- no external modules are installed or required.
    [ValidateRange(1, 32)]
    [int]$MaxConcurrentRequests = 8,

    [ValidateRange(30, 3600)]
    [int]$RefreshIntervalSeconds = 300,

    [ValidateRange(1, 16)]
    [int]$LogAnalyticsConcurrency = 4
)

<#
Azure Arc Observability Dashboard application server.

This script hosts a loopback-only HTTP server, serves the static dashboard pages,
coordinates first-run Azure authentication/configuration, and retrieves live data
through Azure CLI, Azure Resource Graph, and Log Analytics. It intentionally has no
external PowerShell module dependencies.

Architecture (enterprise scale):
  - ArcDashboard.Core.psm1 contains every data-access, pagination, and aggregation
    function. It is imported both by this script's own runspace (for setup/auth
    flows) and into the InitialSessionState of a dedicated request-handling
    RunspacePool, so the exact same, tested code path serves both.
  - A single background runspace periodically rebuilds a complete, immutable
    "operations" snapshot (per-server inventory, summary aggregates, geography
    rollups), a complete "SQL" snapshot, and a complete "Kubernetes" snapshot
    (Arc-enabled connected cluster inventory, extension coverage, and summary
    aggregates), then atomically publishes each one. Azure calls never run on a
    thread that is also answering HTTP requests, so a long refresh cannot block
    already-cached API/page responses.
  - New bounded '/api/operations/*', '/api/platforms/*', '/api/deployment/*',
    '/api/sql/*', '/api/global/*', and '/api/kubernetes/*' routes are dispatched
    onto a small RunspacePool so concurrent page loads do not serialize behind
    one another, and so the very first (synchronous) snapshot build only blocks the single
    connection that triggered it.
  - Setup, sign-in, configuration, and logout remain on the main thread exactly
    as in the portable dashboard, since they are infrequent, already have their
    own async device-login flow, and touch local child-process state.
#>

$ErrorActionPreference = 'Stop'

# region Encrypted local configuration
# Dashboard scope contains Azure identifiers rather than credentials, but it is
# still protected at rest with Windows DPAPI for the current user and machine.
$configPath = Join-Path $PSScriptRoot 'dashboard.config.dat'
$legacyConfigPath = Join-Path $PSScriptRoot 'dashboard.config.json'
$configEntropy = [Text.Encoding]::UTF8.GetBytes('EnterpriseArcDashboard:v1')

function Protect-Configuration {
    param([Parameter(Mandatory)][string]$PlainText)

    $plainBytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $configEntropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Convert]::ToBase64String($protectedBytes)
    }
    finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Unprotect-Configuration {
    param([Parameter(Mandatory)][string]$ProtectedText)

    $protectedBytes = [Convert]::FromBase64String($ProtectedText)
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        $configEntropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    try {
        return [Text.Encoding]::UTF8.GetString($plainBytes)
    }
    finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Save-ProtectedConfiguration {
    param([Parameter(Mandatory)][object]$Configuration)

    $json = $Configuration | ConvertTo-Json -Depth 5 -Compress
    $protectedText = Protect-Configuration -PlainText $json
    $temporaryPath = "$configPath.tmp"
    [IO.File]::WriteAllText($temporaryPath, $protectedText, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $configPath -Force
    Remove-Item -LiteralPath $legacyConfigPath -Force -ErrorAction SilentlyContinue
}

# Load the encrypted configuration, or migrate the legacy plaintext JSON format once.
$SelectedResourceGroups = @()
$Workspaces = @()
$AiEndpoint = ''
$AiModel = ''
$AiTenantId = ''
$IsConfigured = $false
if (Test-Path -LiteralPath $configPath) {
    try {
        $config = Unprotect-Configuration (Get-Content -LiteralPath $configPath -Raw) | ConvertFrom-Json
    }
    catch {
        Write-Warning 'The saved dashboard configuration cannot be decrypted for this Windows user and machine. Setup is required again.'
        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
        $config = $null
    }
}
elseif (Test-Path -LiteralPath $legacyConfigPath) {
    $config = Get-Content -LiteralPath $legacyConfigPath -Raw | ConvertFrom-Json
    Save-ProtectedConfiguration -Configuration $config
}

if ($config) {
    if (-not $SubscriptionId) {
        $SubscriptionId = $config.subscriptionId
    }
    $SelectedResourceGroups = @($config.resourceGroups | ForEach-Object { [string]$_ })
    $Workspaces = @($config.workspaces | ForEach-Object {
        if ($_.name -and $_.id) {
            @{ Name = [string]$_.name; Id = [string]$_.id }
        }
    })
    if ($config.ai) {
        $AiEndpoint = [string]$config.ai.endpoint
        $AiModel = [string]$config.ai.model
        $AiTenantId = [string]$config.ai.tenantId
    }
    $IsConfigured = [bool]$SubscriptionId -and $SelectedResourceGroups.Count -gt 0
}
# endregion Encrypted local configuration

# Windows PowerShell relaunches the script in PowerShell 7 because the dashboard
# relies on modern .NET and PowerShell behavior.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        throw 'PowerShell 7 (pwsh) is required to run this dashboard.'
    }

    $arguments = @('-NoProfile', '-File', "`"$PSCommandPath`"", '-Port', $Port)
    if ($SubscriptionId) {
        $arguments += @('-SubscriptionId', $SubscriptionId)
    }
    if ($NoBrowser) {
        $arguments += '-NoBrowser'
    }
    Start-Process -FilePath $pwsh.Source -ArgumentList $arguments
    return
}

$modulePath = Join-Path $PSScriptRoot 'ArcDashboard.Core.psm1'
$aiModulePath = Join-Path $PSScriptRoot 'ArcDashboard.AI.psm1'
$monitoringModulePath = Join-Path $PSScriptRoot 'ArcDashboard.Monitoring.psm1'
$workloadMonitoringModulePath = Join-Path $PSScriptRoot 'ArcDashboard.WorkloadMonitoring.psm1'
Import-Module $modulePath -Force
Import-Module $aiModulePath -Force
Import-Module $monitoringModulePath -Force
Import-Module $workloadMonitoringModulePath -Force

# region Shared, thread-safe application state
# $SharedState is a [hashtable]::Synchronized() instance: every field is either read-only
# after construction or replaced wholesale with a brand-new value on change (snapshots,
# configuration), which keeps every read from any thread consistent without needing a lock
# around individual field reads. The three SemaphoreSlim gates prevent duplicate concurrent
# rebuilds of the same (expensive, 50,000-server-scale) snapshot.
$script:SharedState = [hashtable]::Synchronized(@{
    Config              = @{
        SubscriptionId  = $SubscriptionId
        ResourceGroups  = @($SelectedResourceGroups)
        Workspaces      = @($Workspaces)
        IsConfigured    = $IsConfigured
        Ai              = @{
            Endpoint     = $AiEndpoint
            Model        = $AiModel
            TenantId     = $AiTenantId
            IsConfigured = [bool]$AiEndpoint -and [bool]$AiModel -and [bool]$AiTenantId
        }
    }
    OperationsSnapshot   = $null
    SqlSnapshot          = $null
    KubernetesSnapshot   = $null
    BuildGate            = [Threading.SemaphoreSlim]::new(1, 1)
    SqlBuildGate         = [Threading.SemaphoreSlim]::new(1, 1)
    KubernetesBuildGate  = [Threading.SemaphoreSlim]::new(1, 1)
    VmSkuGate            = [Threading.SemaphoreSlim]::new(1, 1)
    VmSkuCache           = [hashtable]::Synchronized(@{})
    LastOperationsError  = $null
    LastSqlError         = $null
    LastKubernetesError  = $null
    MonitoringSnapshot   = $null
    MonitoringGate       = [Threading.SemaphoreSlim]::new(1, 1)
    MonitoringStateGate  = [Threading.SemaphoreSlim]::new(1, 1)
    MonitoringStorePath  = Join-Path $PSScriptRoot '.monitoring\session.dat'
    MonitoringCollectionRequested = $false
    MonitoringLastError  = $null
    MonitoringGeneration = [long]0
    WorkloadSnapshot     = $null
    WorkloadGate         = [Threading.SemaphoreSlim]::new(1, 1)
    WorkloadStateGate    = [Threading.SemaphoreSlim]::new(1, 1)
    WorkloadStorePath    = Join-Path $PSScriptRoot '.monitoring\workload.dat'
    WorkloadCollectionRequested = $false
    WorkloadLastError    = $null
    WorkloadGeneration   = [long]0
    ConfigVersion       = [long]0
    ForceRefresh        = $false
    ShutdownRequested   = $false
})
$script:SharedState.MonitoringSnapshot = Restore-MonitoringSnapshot -Path $script:SharedState.MonitoringStorePath
if ($script:SharedState.MonitoringSnapshot) {
    $script:SharedState.MonitoringGeneration = [long]$script:SharedState.MonitoringSnapshot.generation
}
$script:SharedState.WorkloadSnapshot = Restore-WorkloadMonitoringSnapshot -Path $script:SharedState.WorkloadStorePath
if ($script:SharedState.WorkloadSnapshot -and
    (Test-WorkloadMonitoringScope -Snapshot $script:SharedState.WorkloadSnapshot -Config $script:SharedState.Config)) {
    $script:SharedState.WorkloadGeneration = [long]$script:SharedState.WorkloadSnapshot.generation
}
elseif ($script:SharedState.WorkloadSnapshot) {
    Remove-WorkloadMonitoringSnapshot -SharedState $script:SharedState
}
# endregion Shared, thread-safe application state

# region Azure command helpers (setup/auth flows only; data access lives in the module)
function Get-TargetSubscriptionId {
    if (-not $script:SharedState.Config.IsConfigured) {
        throw 'The dashboard has not been configured yet. Complete setup first.'
    }
    return $script:SharedState.Config.SubscriptionId
}
# endregion Azure command helpers

# region Setup and authentication workflow
# Child-process output is stored only under the process-specific temporary folder
# and is removed during logout or server shutdown.
$workerDirectory = Join-Path $env:TEMP "EnterpriseArcDashboard-$PID"
$foundryAzureConfigDirectory = Join-Path $PSScriptRoot '.azure-foundry'
New-Item -ItemType Directory -Path $workerDirectory -Force | Out-Null
$script:InstallProcess = $null
$script:LoginProcess = $null
$script:FoundryLoginProcess = $null
$script:FoundryLoginTenantId = ''

function Get-WorkerOutput {
    param([string]$Prefix)

    $output = @()
    foreach ($suffix in @('out', 'err')) {
        $path = Join-Path $workerDirectory "$Prefix.$suffix.log"
        if (Test-Path -LiteralPath $path) {
            $output += Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
        }
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function Get-SetupStatus {
    $az = Get-AzExecutable
    $version = $null
    if ($az) {
        try {
            $versionResult = Invoke-AzJson @('version', '--output', 'json', '--only-show-errors')
            $version = $versionResult.'azure-cli'
        }
        catch {
            $version = 'Installed'
        }
    }

    $installState = 'idle'
    if ($script:InstallProcess) {
        $installState = if ($script:InstallProcess.HasExited) {
            if ($script:InstallProcess.ExitCode -eq 0 -and (Get-AzExecutable)) { 'completed' } else { 'failed' }
        } else {
            'running'
        }
    }

    $config = $script:SharedState.Config
    return @{
        cli = @{
            installed = [bool]$az
            path      = $az
            version   = $version
            installState = $installState
            installOutput = Get-WorkerOutput -Prefix 'install'
        }
        configured = $config.IsConfigured
        configuration = if ($config.IsConfigured) {
            @{
                subscriptionId = $config.SubscriptionId
                resourceGroups = @($config.ResourceGroups)
                workspaces     = @($config.Workspaces | ForEach-Object Name)
                ai             = @{
                    endpoint = $config.Ai.Endpoint
                    model = $config.Ai.Model
                    tenantId = $config.Ai.TenantId
                    configured = $config.Ai.IsConfigured
                }
            }
        } else {
            $null
        }
        subscriptions = @(Get-AvailableSubscriptionList)
    }
}

function Start-AzureCliInstall {
    if (Get-AzExecutable) {
        return @{ state = 'completed'; message = 'Azure CLI is already installed.' }
    }
    if ($script:InstallProcess -and -not $script:InstallProcess.HasExited) {
        return @{ state = 'running'; message = 'Azure CLI installation is already running.' }
    }

    $outputPath = Join-Path $workerDirectory 'install.out.log'
    $errorPath = Join-Path $workerDirectory 'install.err.log'
    Remove-Item -LiteralPath $outputPath, $errorPath -Force -ErrorAction SilentlyContinue
    $script:InstallProcess = Start-Process -FilePath (Get-Command pwsh).Source -PassThru `
        -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'Install-AzureCli.ps1')`"")
    return @{ state = 'running'; message = 'Azure CLI installation started. Approve the Windows elevation prompt if shown.' }
}

function Start-AzureDeviceLogin {
    param([string]$TenantId)

    $az = Get-AzExecutable
    if (-not $az) {
        throw 'Install Azure CLI before signing in.'
    }
    if ($TenantId) {
        $parsedTenant = [guid]::Empty
        if (-not [guid]::TryParse($TenantId, [ref]$parsedTenant)) {
            throw 'Tenant ID must be a valid GUID or left blank.'
        }
    }
    if ($script:LoginProcess -and -not $script:LoginProcess.HasExited) {
        throw 'An Azure sign-in is already in progress.'
    }

    $outputPath = Join-Path $workerDirectory 'login.out.log'
    $errorPath = Join-Path $workerDirectory 'login.err.log'
    Remove-Item -LiteralPath $outputPath, $errorPath -Force -ErrorAction SilentlyContinue
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'Azure-Login.ps1')`"",
        '-AzPath', "`"$az`""
    )
    if ($TenantId) {
        $arguments += @('-TenantId', $TenantId)
    }
    # Run device authentication asynchronously so the browser can poll for completion.
    $script:LoginProcess = Start-Process -FilePath (Get-Command pwsh).Source -PassThru `
        -WindowStyle Minimized `
        -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath -ArgumentList $arguments

    $deadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 250
        $output = Get-WorkerOutput -Prefix 'login'
    } while (-not $output -and -not $script:LoginProcess.HasExited -and (Get-Date) -lt $deadline)

    return Get-AzureLoginStatus
}

function Get-AzureLoginStatus {
    if (-not $script:LoginProcess) {
        return @{ state = 'idle'; output = ''; subscriptions = @(Get-AvailableSubscriptionList) }
    }

    $state = if ($script:LoginProcess.HasExited) {
        if ($script:LoginProcess.ExitCode -eq 0) { 'completed' } else { 'failed' }
    } else {
        'running'
    }
    return @{
        state = $state
        output = Get-WorkerOutput -Prefix 'login'
        subscriptions = if ($state -eq 'completed') { @(Get-AvailableSubscriptionList) } else { @() }
    }
}

function Start-FoundryDeviceLogin {
        param([Parameter(Mandatory)][string]$TenantId)

        $validatedTenantId = Get-ValidatedFoundryTenantId -TenantId $TenantId
        $az = Get-AzExecutable
        if (-not $az) {
            throw 'Install Azure CLI before signing in to the Foundry tenant.'
        }
        if ($script:LoginProcess -and -not $script:LoginProcess.HasExited) {
            throw 'Complete the Arc tenant sign-in before starting Foundry tenant sign-in.'
        }
        if ($script:FoundryLoginProcess -and -not $script:FoundryLoginProcess.HasExited) {
            throw 'A Foundry tenant sign-in is already in progress.'
        }

        $outputPath = Join-Path $workerDirectory 'foundry-login.out.log'
        $errorPath = Join-Path $workerDirectory 'foundry-login.err.log'
        Remove-Item -LiteralPath $outputPath, $errorPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $foundryAzureConfigDirectory -Recurse -Force -ErrorAction SilentlyContinue
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'Azure-Login.ps1')`"",
            '-AzPath', "`"$az`"",
            '-TenantId', $validatedTenantId,
            '-ConfigDirectory', "`"$foundryAzureConfigDirectory`"",
            '-AllowNoSubscriptions'
        )
        $script:FoundryLoginTenantId = $validatedTenantId
        $script:FoundryLoginProcess = Start-Process -FilePath (Get-Command pwsh).Source -PassThru `
            -WindowStyle Minimized `
            -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath -ArgumentList $arguments

        $deadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 250
            $output = Get-WorkerOutput -Prefix 'foundry-login'
        } while (-not $output -and -not $script:FoundryLoginProcess.HasExited -and (Get-Date) -lt $deadline)

        return Get-FoundryLoginStatus -TenantId $validatedTenantId
}

function Get-FoundryLoginStatus {
        param([string]$TenantId)

        if ($script:FoundryLoginProcess -and $script:FoundryLoginTenantId -and $TenantId -and
            (Get-ValidatedFoundryTenantId -TenantId $TenantId) -ne $script:FoundryLoginTenantId) {
            throw 'The requested tenant differs from the Foundry sign-in currently in progress.'
        }
        $targetTenantId = if ($TenantId) {
            Get-ValidatedFoundryTenantId -TenantId $TenantId
        }
        elseif ($script:FoundryLoginTenantId) {
            $script:FoundryLoginTenantId
        }
        else {
            [string]$script:SharedState.Config.Ai.TenantId
        }

        if ($script:FoundryLoginProcess) {
            $state = if ($script:FoundryLoginProcess.HasExited) {
                if ($script:FoundryLoginProcess.ExitCode -eq 0) { 'completed' } else { 'failed' }
            }
            else {
                'running'
            }
            $authenticated = $false
            $authenticationError = ''
            if ($state -eq 'completed' -and $targetTenantId) {
                $authentication = Get-FoundryAuthenticationStatus -TenantId $targetTenantId
                $authenticated = $authentication.Authenticated
                $authenticationError = $authentication.Error
                if (-not $authenticated) { $state = 'failed' }
            }
            return @{
                state = $state
                authenticated = $authenticated
                tenantId = $targetTenantId
                output = Get-WorkerOutput -Prefix 'foundry-login'
                error = $authenticationError
            }
        }

        $authentication = if ($targetTenantId) {
            Get-FoundryAuthenticationStatus -TenantId $targetTenantId
        }
        else {
            @{ Authenticated = $false; Error = '' }
        }
        $authenticated = $authentication.Authenticated
        return @{
            state = if ($authenticated) { 'completed' } else { 'idle' }
            authenticated = $authenticated
            tenantId = $targetTenantId
            output = ''
            error = $authentication.Error
        }
}

function Save-DashboardConfiguration {
    param(
        [Parameter(Mandatory)][string]$TargetSubscriptionId,
        [Parameter(Mandatory)][string[]]$ResourceGroups
    )

    $ResourceGroups = @($ResourceGroups | Where-Object { $_ } | Sort-Object -Unique)
    if ($ResourceGroups.Count -eq 0) {
        throw 'Select at least one resource group containing Arc-enabled servers or Arc-enabled Kubernetes clusters.'
    }

    # Revalidate browser input against live Resource Graph results before persisting it.
    $availableGroups = @(Get-ArcResourceGroupList -SubscriptionId $TargetSubscriptionId)
    $availableNames = @($availableGroups | ForEach-Object resourceGroup)
    $invalidGroups = @($ResourceGroups | Where-Object { $_ -notin $availableNames })
    if ($invalidGroups.Count) {
        throw "These resource groups do not contain accessible Arc servers or clusters: $($invalidGroups -join ', ')."
    }

    $discoveredWorkspaces = @(Get-MonitoringWorkspaceList -SubscriptionId $TargetSubscriptionId -ResourceGroups $ResourceGroups)
    $configuration = [ordered]@{
        subscriptionId = $TargetSubscriptionId
        resourceGroups = $ResourceGroups
        workspaces = @($discoveredWorkspaces | ForEach-Object {
            [ordered]@{ name = $_.Name; id = $_.Id }
        })
        ai = [ordered]@{
            endpoint = $script:SharedState.Config.Ai.Endpoint
            model = $script:SharedState.Config.Ai.Model
            tenantId = $script:SharedState.Config.Ai.TenantId
        }
        configuredAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Save-ProtectedConfiguration -Configuration $configuration

    # A brand-new Config object is assigned as a single reference so every thread reading
    # $SharedState.Config sees either the fully-old or fully-new configuration, never a mix.
    $script:SharedState.Config = @{
        SubscriptionId = $TargetSubscriptionId
        ResourceGroups = $ResourceGroups
        Workspaces     = $discoveredWorkspaces
        IsConfigured   = $true
        Ai            = $script:SharedState.Config.Ai
    }
    Reset-DashboardSnapshots -SharedState $script:SharedState
    Remove-MonitoringSnapshot -SharedState $script:SharedState
    Remove-WorkloadMonitoringSnapshot -SharedState $script:SharedState

    return @{
        subscriptionId = $TargetSubscriptionId
        resourceGroups = $ResourceGroups
        workspaces = @($discoveredWorkspaces | ForEach-Object Name)
    }
}

function Save-AiConfiguration {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Model
    )

    if (-not $script:SharedState.Config.IsConfigured) {
        throw 'Complete Azure dashboard setup before configuring AI.'
    }
    $validatedTenantId = Get-ValidatedFoundryTenantId -TenantId $TenantId
    $authentication = Get-FoundryAuthenticationStatus -TenantId $validatedTenantId
    if (-not $authentication.Authenticated) {
        throw "Complete Foundry device sign-in for tenant '$validatedTenantId' before saving AI configuration. $($authentication.Error)"
    }
    $normalizedEndpoint = Get-NormalizedFoundryEndpoint -Endpoint $Endpoint
    $validatedModel = Get-ValidatedFoundryModel -Model $Model
    $config = $script:SharedState.Config
    $ai = @{
        Endpoint = $normalizedEndpoint
        Model = $validatedModel
        TenantId = $validatedTenantId
        IsConfigured = $true
    }
    $configuration = [ordered]@{
        subscriptionId = $config.SubscriptionId
        resourceGroups = @($config.ResourceGroups)
        workspaces = @($config.Workspaces | ForEach-Object {
            [ordered]@{ name = $_.Name; id = $_.Id }
        })
        ai = [ordered]@{
            endpoint = $normalizedEndpoint
            model = $validatedModel
            tenantId = $validatedTenantId
        }
        configuredAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Save-ProtectedConfiguration -Configuration $configuration
    $script:SharedState.Config = @{
        SubscriptionId = $config.SubscriptionId
        ResourceGroups = @($config.ResourceGroups)
        Workspaces = @($config.Workspaces)
        IsConfigured = $true
        Ai = $ai
    }
    return @{
        configured = $true
        endpoint = $normalizedEndpoint
        model = $validatedModel
        tenantId = $validatedTenantId
        authentication = 'Isolated Azure CLI Microsoft Entra ID'
    }
}

function Get-AiConfigurationStatus {
    $config = $script:SharedState.Config
    return @{
        dashboardConfigured = $config.IsConfigured
        configured = [bool]$config.Ai.IsConfigured
        endpoint = [string]$config.Ai.Endpoint
        model = [string]$config.Ai.Model
        tenantId = [string]$config.Ai.TenantId
        authentication = 'Isolated Azure CLI Microsoft Entra ID'
        subscriptionId = [string]$config.SubscriptionId
        resourceGroups = @($config.ResourceGroups)
    }
}

function Invoke-SecureLogout {
    # Logout is deliberately destructive: revoke Azure CLI state, remove the
    # encrypted scope, clear in-memory data, and request server shutdown.
    if ($script:LoginProcess -and -not $script:LoginProcess.HasExited) {
        Stop-Process -Id $script:LoginProcess.Id -ErrorAction Stop
        $script:LoginProcess.WaitForExit()
    }
    if ($script:FoundryLoginProcess -and -not $script:FoundryLoginProcess.HasExited) {
        try {
            $script:FoundryLoginProcess.Kill($true)
        }
        catch [InvalidOperationException] {
            # The login process exited between the state check and termination.
        }
        $script:FoundryLoginProcess.WaitForExit()
    }

    $az = Get-AzExecutable
    if ($az) {
        $output = & $az account list --all --output json --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ($output -join [Environment]::NewLine)
        }
        $accounts = ($output -join [Environment]::NewLine) | ConvertFrom-Json
        if (@($accounts).Count -gt 0) {
            $output = & $az logout --only-show-errors 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ($output -join [Environment]::NewLine)
            }
        }
        $output = & $az account clear --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ($output -join [Environment]::NewLine)
        }
    }

    Remove-Item -LiteralPath $configPath, $legacyConfigPath -Force -ErrorAction SilentlyContinue
    foreach ($prefix in @('login', 'foundry-login', 'install')) {
        Remove-Item -LiteralPath (Join-Path $workerDirectory "$prefix.out.log"), (Join-Path $workerDirectory "$prefix.err.log") -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $foundryAzureConfigDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-MonitoringSnapshot -SharedState $script:SharedState
    Remove-WorkloadMonitoringSnapshot -SharedState $script:SharedState

    $script:SharedState.Config = @{
        SubscriptionId = $null
        ResourceGroups = @()
        Workspaces     = @()
        IsConfigured   = $false
        Ai              = @{ Endpoint = ''; Model = ''; TenantId = ''; IsConfigured = $false }
    }
    Reset-DashboardSnapshots -SharedState $script:SharedState
    $script:LoginProcess = $null
    $script:FoundryLoginProcess = $null
    $script:FoundryLoginTenantId = ''
    $script:SharedState.ShutdownRequested = $true

    return @{ loggedOut = $true; serverStopping = $true }
}
# endregion Setup and authentication workflow

# region Background refresh runspace
# Runs on a single dedicated runspace so Azure fetches for a 50,000-server subscription never
# share a thread with request handling. The main script does not wait on this; it only signals
# shutdown and gives it a short grace period to exit during cleanup.
$refreshSessionState = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$refreshSessionState.ImportPSModule(@($modulePath))
$script:RefreshRunspacePool = [runspacefactory]::CreateRunspacePool(1, 1, $refreshSessionState, $Host)
$script:RefreshRunspacePool.Open()
$script:RefreshPowerShell = [powershell]::Create()
$script:RefreshPowerShell.RunspacePool = $script:RefreshRunspacePool
[void]$script:RefreshPowerShell.AddCommand('Start-DashboardRefreshLoop').
    AddParameter('SharedState', $script:SharedState).
    AddParameter('IntervalSeconds', $RefreshIntervalSeconds)
$script:RefreshHandle = $script:RefreshPowerShell.BeginInvoke()

# A separate single-threaded runspace collects only the explicitly selected server every
# minute. It cannot block dashboard snapshot refreshes or HTTP request workers.
$monitoringSessionState = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$monitoringSessionState.ImportPSModule($modulePath)
$monitoringSessionState.ImportPSModule($monitoringModulePath)
$script:MonitoringRunspacePool = [runspacefactory]::CreateRunspacePool(1, 1, $monitoringSessionState, $Host)
$script:MonitoringRunspacePool.Open()
$script:MonitoringPowerShell = [powershell]::Create()
$script:MonitoringPowerShell.RunspacePool = $script:MonitoringRunspacePool
[void]$script:MonitoringPowerShell.AddCommand('Start-ServerMonitoringLoop').
    AddParameter('SharedState', $script:SharedState).
    AddParameter('IntervalSeconds', 60)
$script:MonitoringHandle = $script:MonitoringPowerShell.BeginInvoke()
if ($script:MonitoringHandle.AsyncWaitHandle.WaitOne(250)) {
    $failureMessage = ''
    try {
        $null = $script:MonitoringPowerShell.EndInvoke($script:MonitoringHandle)
    }
    catch {
        $failureMessage = $_.Exception.Message
    }
    if (-not $failureMessage -and $script:MonitoringPowerShell.Streams.Error.Count) {
        $failureMessage = [string]$script:MonitoringPowerShell.Streams.Error[0]
    }
    if (-not $failureMessage) {
        $failureMessage = [string]$script:MonitoringPowerShell.InvocationStateInfo.Reason
    }
    throw "The single-server monitoring worker failed to start. $failureMessage"
}

$workloadSessionState = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$workloadSessionState.ImportPSModule($modulePath)
$workloadSessionState.ImportPSModule($monitoringModulePath)
$workloadSessionState.ImportPSModule($workloadMonitoringModulePath)
$script:WorkloadRunspacePool = [runspacefactory]::CreateRunspacePool(1, 1, $workloadSessionState, $Host)
$script:WorkloadRunspacePool.Open()
$script:WorkloadPowerShell = [powershell]::Create()
$script:WorkloadPowerShell.RunspacePool = $script:WorkloadRunspacePool
[void]$script:WorkloadPowerShell.AddCommand('Start-WorkloadMonitoringLoop').
    AddParameter('SharedState', $script:SharedState).
    AddParameter('IntervalSeconds', 60)
$script:WorkloadHandle = $script:WorkloadPowerShell.BeginInvoke()
if ($script:WorkloadHandle.AsyncWaitHandle.WaitOne(250)) {
    $failureMessage = ''
    try {
        $null = $script:WorkloadPowerShell.EndInvoke($script:WorkloadHandle)
    }
    catch {
        $failureMessage = $_.Exception.Message
    }
    if (-not $failureMessage -and $script:WorkloadPowerShell.Streams.Error.Count) {
        $failureMessage = [string]$script:WorkloadPowerShell.Streams.Error[0]
    }
    if (-not $failureMessage) {
        $failureMessage = [string]$script:WorkloadPowerShell.InvocationStateInfo.Reason
    }
    throw "The workload monitoring worker failed to start. $failureMessage"
}
# endregion Background refresh runspace

# region Request-handling RunspacePool
$requestSessionState = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$requestSessionState.ImportPSModule(@($modulePath))
$requestSessionState.ImportPSModule(@($aiModulePath))
$requestSessionState.ImportPSModule(@($monitoringModulePath))
$requestSessionState.ImportPSModule(@($workloadMonitoringModulePath))
$script:RequestRunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxConcurrentRequests, $requestSessionState, $Host)
$script:RequestRunspacePool.Open()
$script:PendingInvocations = [Collections.Generic.List[object]]::new()

# Executed inside a pool worker: writes the bounded API response directly to the client's
# stream and disposes the client once the response has been written.
$enterpriseRequestScript = @'
param($SharedState, $Method, $Path, $QueryValues, $Body, $Client)
try {
    $stream = $Client.GetStream()
    if ($Path -eq '/api/monitoring' -or $Path.StartsWith('/api/monitoring/')) {
        Invoke-MonitoringApiRequest -SharedState $SharedState -Method $Method -Path $Path -Body $Body -Stream $stream
    }
    elseif ($Path -eq '/api/workload-monitoring' -or $Path.StartsWith('/api/workload-monitoring/')) {
        Invoke-WorkloadMonitoringApiRequest -SharedState $SharedState -Method $Method -Path $Path -Body $Body -Stream $stream
    }
    elseif ($Path -eq '/api/ai/chat') {
        Invoke-StandaloneAiApiRequest -SharedState $SharedState -Method $Method -Path $Path -Body $Body -Stream $stream
    }
    else {
        Invoke-EnterpriseApiRequest -SharedState $SharedState -Method $Method -Path $Path -QueryValues $QueryValues -Stream $stream
    }
}
finally {
    $Client.Dispose()
}
'@

function Complete-PendingInvocations {
    # Reclaims PowerShell instances for connections whose pooled worker has already finished.
    # Called opportunistically from the accept loop rather than blocking on any one of them.
    $stillPending = [Collections.Generic.List[object]]::new()
    foreach ($pending in $script:PendingInvocations) {
        if ($pending.Handle.IsCompleted) {
            try {
                $null = $pending.PowerShell.EndInvoke($pending.Handle)
                foreach ($errorRecord in $pending.PowerShell.Streams.Error) {
                    Write-Warning "Request handler error: $errorRecord"
                }
            }
            catch {
                Write-Warning "Request handler failed: $($_.Exception.Message)"
            }
            finally {
                $pending.PowerShell.Dispose()
            }
        }
        else {
            $stillPending.Add($pending)
        }
    }
    $script:PendingInvocations = $stillPending
}

function Invoke-EnterpriseApiRequestAsync {
    param($Method, $Path, $QueryValues, $Body, $Client)

    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:RequestRunspacePool
    [void]$ps.AddScript($enterpriseRequestScript).AddParameters(@{
        SharedState = $script:SharedState
        Method      = $Method
        Path        = $Path
        QueryValues = $QueryValues
        Body        = $Body
        Client      = $Client
    })
    $handle = $ps.BeginInvoke()
    $script:PendingInvocations.Add(@{ PowerShell = $ps; Handle = $handle })
}
# endregion Request-handling RunspacePool

# region HTTP plumbing (main thread: pages, setup, logout)
function Write-HttpResponse {
    param(
        [Net.Sockets.NetworkStream]$Stream,
        [int]$StatusCode,
        [string]$StatusText,
        [string]$ContentType,
        [byte[]]$Body
    )

    # Security headers prevent browser caching and content-type guessing for Azure data.
    $headers = "HTTP/1.1 $StatusCode $StatusText`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-store`r`nPragma: no-cache`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`nConnection: close`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($Body, 0, $Body.Length)
    $Stream.Flush()
}

function Write-JsonResponse {
    param(
        [Net.Sockets.NetworkStream]$Stream,
        [object]$Value,
        [int]$StatusCode = 200,
        [string]$StatusText = 'OK'
    )

    $body = $Value | ConvertTo-Json -Depth 10
    Write-HttpResponse $Stream $StatusCode $StatusText 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($body))
}

$enterpriseApiPrefixes = @('/api/operations', '/api/platforms', '/api/deployment', '/api/sql', '/api/global', '/api/kubernetes', '/api/monitoring', '/api/workload-monitoring', '/api/ai/chat')

function Test-EnterpriseApiPath {
    param([string]$Path)
    foreach ($prefix in $enterpriseApiPrefixes) {
        if ($Path -eq $prefix -or $Path.StartsWith("$prefix/")) { return $true }
    }
    return $false
}

function Test-AllowedHostHeader {
    param([hashtable]$Headers)

    if (-not $Headers.ContainsKey('host')) {
        return $false
    }
    return ([string]$Headers['host']).ToLowerInvariant() -in @(
        "localhost:$Port",
        "127.0.0.1:$Port"
    )
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
# Loopback binding intentionally prevents direct access from other computers.
$listener.Start()
$url = "http://localhost:$Port/"

Write-Host "Standalone Azure Arc Observability Dashboard running at $url"
Write-Host "Request concurrency: $MaxConcurrentRequests | Background refresh interval: ${RefreshIntervalSeconds}s | Log Analytics concurrency: $LogAnalyticsConcurrency"
Write-Host 'Press Ctrl+C to stop.'
if (-not $NoBrowser) {
    Start-Process $url
}

try {
    while (-not $script:SharedState.ShutdownRequested) {
        Complete-PendingInvocations
        $client = $listener.AcceptTcpClient()
        $dispatchedToPool = $false
        try {
            $stream = $client.GetStream()
            $headerBytes = [Collections.Generic.List[byte]]::new()
            $headerTerminator = [byte[]](13, 10, 13, 10)
            $matchedTerminatorBytes = 0
            while ($matchedTerminatorBytes -lt $headerTerminator.Length) {
                $nextByte = $stream.ReadByte()
                if ($nextByte -lt 0) {
                    throw [IO.IOException]::new('Client disconnected before sending complete HTTP headers.')
                }
                $headerBytes.Add([byte]$nextByte)
                if ($nextByte -eq $headerTerminator[$matchedTerminatorBytes]) {
                    $matchedTerminatorBytes++
                }
                else {
                    $matchedTerminatorBytes = if ($nextByte -eq $headerTerminator[0]) { 1 } else { 0 }
                }
                if ($headerBytes.Count -gt 16384) {
                    throw [IO.InvalidDataException]::new('HTTP headers cannot exceed 16 KB.')
                }
            }

            $headerText = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
            $headerLines = @($headerText.Substring(0, $headerText.Length - 4) -split "`r`n")
            $requestLine = $headerLines[0]
            $requestHeaders = @{}
            foreach ($headerLine in @($headerLines | Select-Object -Skip 1)) {
                $parts = $headerLine -split ':', 2
                if ($parts.Count -eq 2) {
                    $requestHeaders[$parts[0].Trim().ToLowerInvariant()] = $parts[1].Trim()
                }
            }
            if (-not (Test-AllowedHostHeader -Headers $requestHeaders)) {
                Write-JsonResponse $stream @{ error = 'The HTTP Host header is not allowed.' } 421 'Misdirected Request'
                continue
            }

            # Parse only the small subset of HTTP needed by this local application.
            $requestBody = ''
            $contentLength = 0
            if ($requestHeaders.ContainsKey('content-length') -and
                (-not [int]::TryParse($requestHeaders['content-length'], [ref]$contentLength) -or $contentLength -lt 0)) {
                Write-JsonResponse $stream @{ error = 'Content-Length must be a non-negative whole number.' } 400 'Bad Request'
                continue
            }
            if ($contentLength -gt 65536) {
                Write-JsonResponse $stream @{ error = 'Request body cannot exceed 64 KB.' } 413 'Content Too Large'
                continue
            }
            if ($contentLength -gt 0) {
                $buffer = [byte[]]::new($contentLength)
                $offset = 0
                while ($offset -lt $contentLength) {
                    $read = $stream.Read($buffer, $offset, $contentLength - $offset)
                    if ($read -le 0) {
                        throw [IO.IOException]::new('Client disconnected before sending the complete request body.')
                    }
                    $offset += $read
                }
                $requestBody = [Text.Encoding]::UTF8.GetString($buffer)
            }

            if ($requestLine -match '^([A-Z]+) ([^ ]+) ') {
                $method = $Matches[1]
                $requestTarget = $Matches[2]
            }
            else {
                $method = 'GET'
                $requestTarget = '/'
            }
            $requestUri = [Uri]::new("http://localhost$requestTarget")
            $path = $requestUri.AbsolutePath
            $queryValues = ConvertFrom-QueryString $requestUri.Query

            # A website in another origin must not be able to drive state-changing loopback
            # APIs through the operator's browser.
            if ($method -ne 'GET' -and $path.StartsWith('/api/') -and $requestHeaders.ContainsKey('origin')) {
                $allowedOrigins = @("http://localhost:$Port", "http://127.0.0.1:$Port")
                if ($requestHeaders['origin'] -notin $allowedOrigins) {
                    Write-JsonResponse $stream @{ error = 'Cross-origin API requests are not allowed.' } 403 'Forbidden'
                    continue
                }
            }

            if (Test-EnterpriseApiPath -Path $path) {
                # Handed off to the request-handling RunspacePool: this connection's response is
                # written and the client disposed entirely on a pool worker thread, so the accept
                # loop is immediately free to service the next connection.
                Invoke-EnterpriseApiRequestAsync -Method $method -Path $path -QueryValues $queryValues -Body $requestBody -Client $client
                $dispatchedToPool = $true
                continue
            }

            # Legacy/local routes: infrequent, and touch main-thread-only process state, so they
            # remain handled inline exactly as in the portable dashboard.
            if ($path -eq '/api/setup/status' -and $method -eq 'GET') {
                Write-JsonResponse $stream (Get-SetupStatus)
            }
            elseif ($path -eq '/api/ai/status' -and $method -eq 'GET') {
                Write-JsonResponse $stream (Get-AiConfigurationStatus)
            }
            elseif ($path -eq '/api/ai/login' -and $method -eq 'POST') {
                try {
                    $request = if ($requestBody) { $requestBody | ConvertFrom-Json } else { [pscustomobject]@{} }
                    Write-JsonResponse $stream (Start-FoundryDeviceLogin -TenantId ([string]$request.tenantId))
                }
                catch {
                    Write-JsonResponse $stream @{ error = $_.Exception.Message } 400 'Bad Request'
                }
            }
            elseif ($path -eq '/api/ai/login-status' -and $method -eq 'GET') {
                try {
                    Write-JsonResponse $stream (Get-FoundryLoginStatus -TenantId ([string]$queryValues.tenantId))
                }
                catch {
                    Write-JsonResponse $stream @{ error = $_.Exception.Message } 400 'Bad Request'
                }
            }
            elseif ($path -eq '/api/ai/configure' -and $method -eq 'POST') {
                try {
                    $request = if ($requestBody) { $requestBody | ConvertFrom-Json } else { [pscustomobject]@{} }
                    Write-JsonResponse $stream (Save-AiConfiguration -TenantId ([string]$request.tenantId) `
                        -Endpoint ([string]$request.endpoint) -Model ([string]$request.model))
                }
                catch {
                    Write-JsonResponse $stream @{ error = $_.Exception.Message } 400 'Bad Request'
                }
            }
            elseif ($path -eq '/api/setup/install-cli' -and $method -eq 'POST') {
                try {
                    Write-JsonResponse $stream (Start-AzureCliInstall)
                }
                catch {
                    Write-JsonResponse $stream @{ error = $_.Exception.Message } 500 'Internal Server Error'
                }
            }
            elseif ($path -eq '/api/setup/login' -and $method -eq 'POST') {
                try {
                    $request = if ($requestBody) { $requestBody | ConvertFrom-Json } else { [pscustomobject]@{} }
                    Write-JsonResponse $stream (Start-AzureDeviceLogin -TenantId ([string]$request.tenantId))
                }
                catch {
                    Write-JsonResponse $stream @{ error = $_.Exception.Message } 400 'Bad Request'
                }
            }
            elseif ($path -eq '/api/setup/login-status' -and $method -eq 'GET') {
                Write-JsonResponse $stream (Get-AzureLoginStatus)
            }
            elseif ($path -eq '/api/setup/resource-groups' -and $method -eq 'GET') {
                try {
                    Write-JsonResponse $stream @{
                        resourceGroups = @(Get-ArcResourceGroupList -SubscriptionId ([string]$queryValues.subscriptionId))
                    }
                }
                catch {
                    Write-JsonResponse $stream @{ error = $_.Exception.Message } 400 'Bad Request'
                }
            }
            elseif ($path -eq '/api/setup/configure' -and $method -eq 'POST') {
                try {
                    $request = $requestBody | ConvertFrom-Json
                    $result = Save-DashboardConfiguration `
                        -TargetSubscriptionId ([string]$request.subscriptionId) `
                        -ResourceGroups @($request.resourceGroups | ForEach-Object { [string]$_ })
                    Write-JsonResponse $stream $result
                }
                catch {
                    Write-JsonResponse $stream @{ error = $_.Exception.Message } 400 'Bad Request'
                }
            }
            elseif ($path -eq '/api/logout' -and $method -eq 'POST') {
                try {
                    Write-JsonResponse $stream (Invoke-SecureLogout)
                }
                catch {
                    Write-JsonResponse $stream @{ error = $_.Exception.Message } 500 'Internal Server Error'
                }
            }
            elseif ($path -eq '/') {
                $page = if ($script:SharedState.Config.IsConfigured) { 'global.html' } else { 'setup.html' }
                Write-HttpResponse $stream 200 'OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $page)))
            }
            elseif ($path -eq '/server.html') {
                Write-HttpResponse $stream 200 'OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'server.html')))
            }
            elseif ($path -eq '/summary.html') {
                Write-HttpResponse $stream 200 'OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'summary.html')))
            }
            elseif ($path -eq '/setup.html') {
                Write-HttpResponse $stream 200 'OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'setup.html')))
            }
            elseif ($path -eq '/platforms.html') {
                Write-HttpResponse $stream 200 'OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'platforms.html')))
            }
            elseif ($path -eq '/deployment.html') {
                Write-HttpResponse $stream 200 'OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'deployment.html')))
            }
            elseif ($path -eq '/sql.html') {
                Write-HttpResponse $stream 200 'OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'sql.html')))
            }
            elseif ($path -eq '/global.html') {
                Write-HttpResponse $stream 200 'OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'global.html')))
            }
            elseif ($path -eq '/kubernetes.html') {
                Write-HttpResponse $stream 200 'OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'kubernetes.html')))
            }
            elseif ($path -eq '/assistant.html') {
                Write-HttpResponse $stream 200 'OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'assistant.html')))
            }
            else {
                Write-HttpResponse $stream 404 'Not Found' 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('Not found'))
            }
        }
        catch [IO.IOException] {
            Write-Verbose "Client disconnected before the response completed: $($_.Exception.Message)"
        }
        catch [Net.Sockets.SocketException] {
            Write-Verbose "Client connection ended: $($_.Exception.Message)"
        }
        finally {
            if (-not $dispatchedToPool) {
                $client.Dispose()
            }
        }
    }
}
finally {
    $listener.Stop()
    $script:SharedState.ShutdownRequested = $true

    if ($script:RefreshHandle -and -not $script:RefreshHandle.IsCompleted) {
        $null = $script:RefreshHandle.AsyncWaitHandle.WaitOne(5000)
    }
    if ($script:MonitoringHandle -and -not $script:MonitoringHandle.IsCompleted) {
        $null = $script:MonitoringHandle.AsyncWaitHandle.WaitOne(5000)
    }
    if ($script:WorkloadHandle -and -not $script:WorkloadHandle.IsCompleted) {
        $null = $script:WorkloadHandle.AsyncWaitHandle.WaitOne(5000)
    }
    $script:RefreshPowerShell.Dispose()
    $script:RefreshRunspacePool.Close()
    $script:RefreshRunspacePool.Dispose()
    $script:MonitoringPowerShell.Dispose()
    $script:MonitoringRunspacePool.Close()
    $script:MonitoringRunspacePool.Dispose()
    $script:WorkloadPowerShell.Dispose()
    $script:WorkloadRunspacePool.Close()
    $script:WorkloadRunspacePool.Dispose()

    Complete-PendingInvocations
    foreach ($pending in $script:PendingInvocations) {
        try { $null = $pending.PowerShell.EndInvoke($pending.Handle) } catch { }
        finally { $pending.PowerShell.Dispose() }
    }
    $script:RequestRunspacePool.Close()
    $script:RequestRunspacePool.Dispose()

    if ($script:LoginProcess -and -not $script:LoginProcess.HasExited) {
        Stop-Process -Id $script:LoginProcess.Id -ErrorAction SilentlyContinue
    }
    if ($script:FoundryLoginProcess -and -not $script:FoundryLoginProcess.HasExited) {
        try {
            $script:FoundryLoginProcess.Kill($true)
        }
        catch [InvalidOperationException] {
            # The login process exited between the state check and termination.
        }
        $script:FoundryLoginProcess.WaitForExit()
    }
    Remove-Item -LiteralPath $workerDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
