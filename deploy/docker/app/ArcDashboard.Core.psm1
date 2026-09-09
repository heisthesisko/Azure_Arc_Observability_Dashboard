<#
ArcDashboard.Core.psm1

Shared data-access, pagination, snapshot, and request-handling library for the
Azure Arc Observability Dashboard. This module is imported both by the main
server process (for setup/auth flows) and into the InitialSessionState of the
request-handling RunspacePool, so every function here must be self-contained:
no dependency on script-scope variables from server.ps1. All mutable state that
must be shared across runspaces is passed explicitly as a parameter (typically
a $SharedState hashtable created with [hashtable]::Synchronized()).

No external modules are used; everything here relies only on PowerShell 7 and
the .NET base class library that ships with it.
#>

$ErrorActionPreference = 'Stop'

# region Azure CLI and REST helpers
function Get-AzExecutable {
    $command = Get-Command az -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    return $null
}

function Update-AzureWorkloadIdentityLogin {
    param([Parameter(Mandatory)][string]$AzPath)

    if ($env:ARC_DASHBOARD_AZURE_AUTH_MODE -ne 'WorkloadIdentity') {
        return
    }
    $tokenPath = $env:AZURE_FEDERATED_TOKEN_FILE
    if (-not $tokenPath -or -not (Test-Path -LiteralPath $tokenPath)) {
        throw 'The projected Azure workload identity token is unavailable.'
    }
    if (-not $env:AZURE_CLIENT_ID -or -not $env:AZURE_TENANT_ID -or -not $env:AZURE_CONFIG_DIR) {
        throw 'Azure workload identity requires AZURE_CLIENT_ID, AZURE_TENANT_ID, and AZURE_CONFIG_DIR.'
    }

    $mutex = [Threading.Mutex]::new($false, 'ArcDashboard-WorkloadIdentityLogin')
    try {
        if (-not $mutex.WaitOne([TimeSpan]::FromMinutes(2))) {
            throw 'Timed out waiting to renew Azure workload identity authentication.'
        }
        try {
            $markerPath = Join-Path $env:AZURE_CONFIG_DIR '.arc-dashboard-federated-login'
            $renewLogin = -not (Test-Path -LiteralPath $markerPath) -or
                [IO.File]::GetLastWriteTimeUtc($markerPath) -lt [datetime]::UtcNow.AddMinutes(-45)
            if (-not $renewLogin) {
                return
            }
            $federatedToken = [IO.File]::ReadAllText($tokenPath).Trim()
            if (-not $federatedToken) {
                throw 'The projected Azure workload identity token is empty.'
            }
            $output = & $AzPath login --service-principal --username $env:AZURE_CLIENT_ID `
                --tenant $env:AZURE_TENANT_ID --federated-token $federatedToken `
                --allow-no-subscriptions --output none --only-show-errors 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ($output -join [Environment]::NewLine)
            }
            if ($env:AZURE_SUBSCRIPTION_ID) {
                $output = & $AzPath account set --subscription $env:AZURE_SUBSCRIPTION_ID `
                    --only-show-errors 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw ($output -join [Environment]::NewLine)
                }
            }
            [IO.File]::WriteAllText($markerPath, [datetime]::UtcNow.ToString('o'), [Text.UTF8Encoding]::new($false))
        }
        finally {
            $mutex.ReleaseMutex()
        }
    }
    finally {
        $mutex.Dispose()
    }
}

function Invoke-AzJson {
    param([string[]]$Arguments)

    $az = Get-AzExecutable
    if (-not $az) {
        throw 'Azure CLI is not installed or is not available on PATH. Open the dashboard setup page for Linux installation guidance.'
    }

    Update-AzureWorkloadIdentityLogin -AzPath $az
    $output = & $az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }
    if (-not $output) {
        return $null
    }
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Set-AzSubscriptionContext {
    param([Parameter(Mandatory)][string]$SubscriptionId)

    # Azure CLI stores its active account in one user-scoped profile. Serialize context
    # changes across runspaces, then let same-subscription REST requests run concurrently.
    $mutex = [Threading.Mutex]::new($false, 'ArcDashboard-AzureCliContext')
    try {
        if (-not $mutex.WaitOne([TimeSpan]::FromMinutes(2))) {
            throw 'Timed out waiting to select the Azure subscription context.'
        }
        try {
            $null = Invoke-AzJson @('account', 'set', '--subscription', $SubscriptionId, '--only-show-errors')
        }
        finally {
            $mutex.ReleaseMutex()
        }
    }
    finally {
        $mutex.Dispose()
    }
}

function Invoke-JsonRequest {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][hashtable]$Body,
        [string]$Resource,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    # az rest accepts @file syntax, avoiding quoting and command-line length issues for KQL bodies.
    $requestPath = [IO.Path]::GetTempFileName()
    try {
        $json = $Body | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($requestPath, $json, [Text.UTF8Encoding]::new($false))
        $arguments = @(
            'rest', '--method', 'post', '--url', $Url,
            '--subscription', $SubscriptionId,
            '--headers', 'Content-Type=application/json',
            '--body', "@$requestPath",
            '--output', 'json',
            '--only-show-errors'
        )
        if ($Resource) {
            $arguments += @('--resource', $Resource)
        }
        return Invoke-AzJson $arguments
    }
    finally {
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    }
}
# endregion Azure CLI and REST helpers

# region Azure Resource Graph pagination
function Invoke-ResourceGraphQueryAll {
    <#
    .SYNOPSIS
    Executes a Resource Graph query and follows the '$skipToken' response option until the
    result set is exhausted, guarding against repeated tokens and runaway pagination.

    .DESCRIPTION
    Enterprise inventories can exceed the single-page 1000-row limit many times over
    (50,000 Arc servers = 50+ pages). This helper preserves every row across pages while
    protecting the caller from an Azure-side bug or unexpected response shape that could
    otherwise cause an infinite request loop.
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Query,
        [ValidateRange(1, 1000)][int]$PageSize = 1000,
        # A safety ceiling, not an expected steady-state value: 300 pages * 1000 rows = 300,000
        # rows of headroom above the 50,000-server enterprise target for any single query.
        [ValidateRange(1, 5000)][int]$MaxPages = 300
    )

    # Establish the correct tenant token context once per complete page sequence. Calling
    # account set for every page would serialize and race concurrent workspace requests.
    Set-AzSubscriptionContext -SubscriptionId $SubscriptionId

    $allRows = [Collections.Generic.List[object]]::new()
    $seenTokens = [Collections.Generic.HashSet[string]]::new()
    $skipToken = $null
    $page = 0
    $totalRecords = $null

    do {
        $page++
        $options = [ordered]@{ '$top' = $PageSize }
        if ($skipToken) {
            $options['$skipToken'] = $skipToken
        }
        $body = @{
            subscriptions = @($SubscriptionId)
            query         = $Query
            options       = $options
        }
        $result = Invoke-JsonRequest -Url 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' `
            -SubscriptionId $SubscriptionId -Body $body

        foreach ($row in @($result.data)) {
            $allRows.Add($row)
        }
        if ($null -ne $result.totalRecords) {
            $totalRecords = $result.totalRecords
        }

        $nextToken = $result.'$skipToken'
        if ($nextToken) {
            if (-not $seenTokens.Add($nextToken)) {
                throw "Resource Graph returned a repeated skipToken after $page page(s); pagination cannot continue safely."
            }
            elseif ($page -ge $MaxPages) {
                throw "Resource Graph results exceeded the $MaxPages-page safety limit after $($allRows.Count) rows. No partial snapshot was published."
            }
        }
        $skipToken = $nextToken
    } while ($skipToken)

    return [pscustomobject]@{
        data         = $allRows.ToArray()
        count        = $allRows.Count
        totalRecords = $totalRecords
        pages        = $page
    }
}

function Invoke-ResourceGraphAggregate {
    <#
    Aggregation queries (count/summarize) return a small, bounded number of rows even across a
    50,000-server estate (typically one row per resource group or per classification). A modest
    page ceiling keeps these cheap while still tolerating an unusually high cardinality result.
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Query
    )
    return Invoke-ResourceGraphQueryAll -SubscriptionId $SubscriptionId -Query $Query -PageSize 1000 -MaxPages 10
}
# endregion Azure Resource Graph pagination

# region Log Analytics query conversion and bounded-concurrency execution
function Convert-LogAnalyticsTable {
    param($Result)

    if (-not $Result.tables -or $Result.tables.Count -eq 0) {
        return @()
    }

    $table = $Result.tables[0]
    $columnNames = @($table.columns | ForEach-Object name)
    return @($table.rows | ForEach-Object {
        $record = [ordered]@{}
        for ($index = 0; $index -lt $columnNames.Count; $index++) {
            $record[$columnNames[$index]] = $_[$index]
        }
        [pscustomobject]$record
    })
}

function Invoke-LogAnalyticsQuery {
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $result = Invoke-JsonRequest `
        -Url "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query" `
        -Resource 'https://api.loganalytics.io' `
        -SubscriptionId $SubscriptionId `
        -Body @{ query = $Query }

    return Convert-LogAnalyticsTable $result
}

function Test-MissingLogAnalyticsDatabase {
    param([Parameter(Mandatory)][string]$ErrorMessage)

    return $ErrorMessage -match "Entity ID '[^']+' of kind 'Database' was not found"
}

function Test-ThrottledLogAnalyticsError {
    param([Parameter(Mandatory)][string]$ErrorMessage)

    return $ErrorMessage -match '\b429\b' -or $ErrorMessage -match '(?i)too\s*many\s*requests' -or $ErrorMessage -match '(?i)TooManyRequests'
}

function Get-RetryAfterSeconds {
    param([Parameter(Mandatory)][string]$ErrorMessage, [Parameter(Mandatory)][int]$Attempt)

    if ($ErrorMessage -match '(?i)retry-after["'':\s]+(\d+)') {
        return [Math]::Min(30, [Math]::Max(1, [int]$Matches[1]))
    }
    return [Math]::Min(30, [Math]::Pow(2, $Attempt))
}

function Invoke-LogAnalyticsQueryWithRetry {
    <#
    Applies bounded retry with exponential backoff (honoring a Retry-After hint when present) to
    a single workspace query. Only HTTP 429 / throttling conditions are retried; every other
    failure -- including the known missing-database condition -- is surfaced to the caller
    immediately so it is never masked as a transient error.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [ValidateRange(0, 10)][int]$MaxRetries = 4
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Query $Query -SubscriptionId $SubscriptionId
        }
        catch {
            $message = $_.Exception.Message
            if ((Test-MissingLogAnalyticsDatabase -ErrorMessage $message) -or -not (Test-ThrottledLogAnalyticsError -ErrorMessage $message) -or $attempt -gt $MaxRetries) {
                throw
            }
            Start-Sleep -Seconds (Get-RetryAfterSeconds -ErrorMessage $message -Attempt $attempt)
        }
    }
}

function Invoke-LogAnalyticsQueryBounded {
    <#
    .SYNOPSIS
    Runs the same KQL query against many workspaces with a bounded number of workspaces in
    flight at once (default 4), instead of serially or unboundedly in parallel.

    .DESCRIPTION
    Uses a small dedicated RunspacePool (built-in .NET/PowerShell SDK facility, no external
    module) sized to -MaxConcurrency so a large workspace count cannot overwhelm the Log
    Analytics API or the local machine. One unavailable or slow workspace cannot fail the
    others: each workspace's error is captured independently, and only the known missing-
    database condition is treated as "not applicable" rather than a surfaced error.
    #>
    param(
        [Parameter(Mandatory)][array]$Workspaces,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [ValidateRange(1, 16)][int]$MaxConcurrency = 4
    )

    $results = [ordered]@{}
    $errors = [Collections.Generic.List[string]]::new()
    if (-not $Workspaces -or @($Workspaces).Count -eq 0) {
        return @{ Results = $results; Errors = @() }
    }

    # All workers target the configured subscription. Select its tenant context once before
    # fan-out; each az rest invocation still carries the explicit --subscription argument.
    Set-AzSubscriptionContext -SubscriptionId $SubscriptionId

    $modulePath = (Get-Command Invoke-LogAnalyticsQueryBounded).Module.Path
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule(@($modulePath))
    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $MaxConcurrency), $iss, $Host)
    $pool.Open()
    try {
        $jobs = foreach ($workspace in @($Workspaces)) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddCommand('Invoke-LogAnalyticsQueryWithRetry').
                AddParameter('WorkspaceId', $workspace.Id).
                AddParameter('Query', $Query).
                AddParameter('SubscriptionId', $SubscriptionId)
            [pscustomobject]@{ Workspace = $workspace; PowerShell = $ps; Handle = $ps.BeginInvoke() }
        }

        foreach ($job in $jobs) {
            try {
                $rows = $job.PowerShell.EndInvoke($job.Handle)
                if ($job.PowerShell.HadErrors) {
                    $firstError = $job.PowerShell.Streams.Error[0]
                    throw $firstError.Exception
                }
                $results[[string]$job.Workspace.Name] = @($rows)
            }
            catch {
                if (-not (Test-MissingLogAnalyticsDatabase -ErrorMessage $_.Exception.Message)) {
                    $errors.Add("$($job.Workspace.Name): $($_.Exception.Message)")
                }
            }
            finally {
                $job.PowerShell.Dispose()
            }
        }
    }
    finally {
        $pool.Close()
        $pool.Dispose()
    }

    return @{ Results = $results; Errors = @($errors) }
}
# endregion Log Analytics query conversion and bounded-concurrency execution

# region Inventory enrichment helpers
function Get-WindowsServerLifecycle {
    param(
        [string]$OsSku,
        [string]$OsVersion
    )

    if ($OsSku -notmatch '(?i)Windows Server') {
        return @{
            isWindowsServer   = $false
            windowsRelease    = $null
            lifecycleState    = 'not-applicable'
            supportEnd        = $null
            esuEnd            = $null
            recommendedTarget = $null
            lifecycleAction   = $null
        }
    }

    $release = if ($OsSku -match '(?i)Windows Server\s+(2008 R2|2008|2012 R2|2012|2016|2019|2022|2025)') {
        $Matches[1]
    }
    else {
        $build = if ($OsVersion -match '^\d+\.\d+\.(\d+)') { [int]$Matches[1] } else { 0 }
        switch ($build) {
            { $_ -le 7601 } { '2008 R2'; break }
            9200 { '2012'; break }
            9600 { '2012 R2'; break }
            14393 { '2016'; break }
            17763 { '2019'; break }
            20348 { '2022'; break }
            { $_ -ge 26100 } { '2025'; break }
            default { 'Unknown' }
        }
    }

    switch -Regex ($release) {
        '^2008' {
            return @{
                isWindowsServer   = $true
                windowsRelease    = "Windows Server $release"
                lifecycleState    = 'unsupported'
                supportEnd        = '2020-01-14'
                esuEnd            = '2024-01-09'
                recommendedTarget = 'Windows Server 2022 or 2025'
                lifecycleAction   = 'Upgrade immediately; ESU coverage has ended.'
            }
        }
        '^2012' {
            return @{
                isWindowsServer   = $true
                windowsRelease    = "Windows Server $release"
                lifecycleState    = 'esu-ending'
                supportEnd        = '2023-10-10'
                esuEnd            = '2026-10-13'
                recommendedTarget = 'Windows Server 2022 or 2025'
                lifecycleAction   = 'Upgrade before ESU Year 3 ends.'
            }
        }
        '^2016$' {
            return @{
                isWindowsServer   = $true
                windowsRelease    = 'Windows Server 2016'
                lifecycleState    = 'approaching-eol'
                supportEnd        = '2027-01-12'
                esuEnd            = 'January 2030 (up to 3 years)'
                recommendedTarget = 'Windows Server 2022 or 2025'
                lifecycleAction   = 'Plan upgrade before extended support ends.'
            }
        }
        '^2019$' {
            return @{
                isWindowsServer   = $true
                windowsRelease    = 'Windows Server 2019'
                lifecycleState    = 'supported'
                supportEnd        = '2029-01-09'
                esuEnd            = $null
                recommendedTarget = 'Windows Server 2025'
                lifecycleAction   = 'Supported; include in long-range upgrade planning.'
            }
        }
        '^2022$' {
            return @{
                isWindowsServer   = $true
                windowsRelease    = 'Windows Server 2022'
                lifecycleState    = 'supported'
                supportEnd        = '2031-10-14'
                esuEnd            = $null
                recommendedTarget = $null
                lifecycleAction   = 'Supported.'
            }
        }
        '^2025$' {
            return @{
                isWindowsServer   = $true
                windowsRelease    = 'Windows Server 2025'
                lifecycleState    = 'supported'
                supportEnd        = '2034-11-14'
                esuEnd            = $null
                recommendedTarget = $null
                lifecycleAction   = 'Supported.'
            }
        }
        default {
            return @{
                isWindowsServer   = $true
                windowsRelease    = $OsSku
                lifecycleState    = 'unknown'
                supportEnd        = $null
                esuEnd            = $null
                recommendedTarget = 'Review manually'
                lifecycleAction   = 'Lifecycle could not be determined from the reported SKU and build.'
            }
        }
    }
}

function Get-LinuxLifecycle {
    <#
    Produces a directional lifecycle band from the distribution family and major release
    reported by the Arc agent. Dates represent generally published distribution lifecycle
    milestones; subscription entitlements, service packs, kernels, and vendor add-ons still
    require validation before this is used as a contractual support determination.
    #>
    param(
        [string]$OsType,
        [string]$OsName,
        [string]$OsSku,
        [string]$OsVersion,
        [datetime]$AsOfDate = (Get-Date).ToUniversalTime().Date
    )

    if ($OsType -ne 'linux') {
        return @{ isLinux = $false; distribution = $null; release = $null; lifecycleState = 'not-applicable'; supportEnd = $null; extendedSupportEnd = $null; lifecycleAction = $null }
    }

    $reported = "$OsSku $OsName $OsVersion".Trim()
    $distribution = 'Unknown Linux'
    $major = $null
    $standardEnd = $null
    $extendedEnd = $null
    $target = 'A currently vendor-supported distribution release'

    if ($reported -match '(?i)\bubuntu\b') {
        $distribution = 'Ubuntu'
        if ($reported -match '(?<!\d)(16\.04|18\.04|20\.04|22\.04|24\.04)(?!\d)') { $major = $Matches[1] }
        switch ($major) {
            '16.04' { $standardEnd = '2021-04-30'; $extendedEnd = '2026-04-30' }
            '18.04' { $standardEnd = '2023-05-31'; $extendedEnd = '2028-04-30' }
            '20.04' { $standardEnd = '2025-05-31'; $extendedEnd = '2030-04-30' }
            '22.04' { $standardEnd = '2027-05-31'; $extendedEnd = '2032-04-30' }
            '24.04' { $standardEnd = '2029-05-31'; $extendedEnd = '2034-04-30' }
        }
        $target = 'Ubuntu 24.04 LTS or a later approved LTS release'
    }
    elseif ($reported -match '(?i)(red hat enterprise linux|\brhel\b)') {
        $distribution = 'Red Hat Enterprise Linux'
        if ($reported -match '(?<!\d)(7|8|9|10)(?:\.\d+)?(?!\d)') { $major = $Matches[1] }
        switch ($major) {
            '7' { $standardEnd = '2024-06-30'; $extendedEnd = '2028-06-30' }
            '8' { $standardEnd = '2029-05-31'; $extendedEnd = '2032-05-31' }
            '9' { $standardEnd = '2032-05-31'; $extendedEnd = '2035-05-31' }
            '10' { $standardEnd = '2035-05-31'; $extendedEnd = '2038-05-31' }
        }
        $target = 'RHEL 9 or a later approved major release'
    }
    elseif ($reported -match '(?i)\bcentos\b') {
        $distribution = if ($reported -match '(?i)\bstream\b') { 'CentOS Stream' } else { 'CentOS Linux' }
        if ($reported -match '(?<!\d)(6|7|8|9|10)(?:\.\d+)?(?!\d)') { $major = $Matches[1] }
        if ($distribution -eq 'CentOS Stream') {
            switch ($major) {
                '8' { $standardEnd = '2024-05-31'; $extendedEnd = '2024-05-31' }
                '9' { $standardEnd = '2027-05-31'; $extendedEnd = '2027-05-31' }
                '10' { $standardEnd = '2030-01-31'; $extendedEnd = '2030-01-31' }
            }
        }
        else {
            switch ($major) {
                '6' { $standardEnd = '2020-11-30'; $extendedEnd = '2020-11-30' }
                '7' { $standardEnd = '2024-06-30'; $extendedEnd = '2024-06-30' }
                '8' { $standardEnd = '2021-12-31'; $extendedEnd = '2021-12-31' }
            }
        }
        $target = 'A supported RHEL-compatible distribution or approved CentOS Stream release'
    }
    elseif ($reported -match '(?i)\bdebian\b') {
        $distribution = 'Debian'
        if ($reported -match '(?<!\d)(9|10|11|12|13)(?:\.\d+)?(?!\d)') { $major = $Matches[1] }
        switch ($major) {
            '9' { $standardEnd = '2022-06-30'; $extendedEnd = '2027-06-30' }
            '10' { $standardEnd = '2024-06-30'; $extendedEnd = '2029-06-30' }
            '11' { $standardEnd = '2026-08-31'; $extendedEnd = '2031-06-30' }
            '12' { $standardEnd = '2028-06-30'; $extendedEnd = '2033-06-30' }
            '13' { $standardEnd = '2030-06-30'; $extendedEnd = '2035-06-30' }
        }
        $target = 'Debian 12 or a later approved stable release'
    }
    elseif ($reported -match '(?i)(oracle linux|\bol[ _-]?[789]\b)') {
        $distribution = 'Oracle Linux'
        if ($reported -match '(?<!\d)(7|8|9)(?:\.\d+)?(?!\d)') { $major = $Matches[1] }
        switch ($major) {
            '7' { $standardEnd = '2024-12-31'; $extendedEnd = '2028-12-31' }
            '8' { $standardEnd = '2029-07-31'; $extendedEnd = '2032-07-31' }
            '9' { $standardEnd = '2032-06-30'; $extendedEnd = '2035-06-30' }
        }
        $target = 'Oracle Linux 8/9 or another approved supported release'
    }
    elseif ($reported -match '(?i)\b(rocky|alma(?:linux)?)\b') {
        $distribution = if ($reported -match '(?i)\brocky\b') { 'Rocky Linux' } else { 'AlmaLinux' }
        if ($reported -match '(?<!\d)(8|9|10)(?:\.\d+)?(?!\d)') { $major = $Matches[1] }
        switch ($major) {
            '8' { $standardEnd = '2029-05-31'; $extendedEnd = '2029-05-31' }
            '9' { $standardEnd = '2032-05-31'; $extendedEnd = '2032-05-31' }
            '10' { $standardEnd = '2035-05-31'; $extendedEnd = '2035-05-31' }
        }
        $target = "$distribution 9 or a later approved major release"
    }
    elseif ($reported -match '(?i)(suse linux enterprise|\bsles\b)') {
        $distribution = 'SUSE Linux Enterprise Server'
        if ($reported -match '(?<!\d)(12|15)(?:\.\d+)?(?!\d)') { $major = $Matches[1] }
        switch ($major) {
            '12' { $standardEnd = '2024-10-31'; $extendedEnd = '2027-10-31' }
            '15' { $standardEnd = '2031-07-31'; $extendedEnd = '2034-07-31' }
        }
        $target = 'A currently supported SLES 15 service pack or later approved release'
    }
    elseif ($reported -match '(?i)(amazon linux 2023|\bal2023\b)') {
        $distribution = 'Amazon Linux'
        $major = '2023'
        $standardEnd = '2029-06-30'
        $extendedEnd = '2029-06-30'
        $target = 'A currently supported Amazon Linux release'
    }
    elseif ($reported -match '(?i)(amazon linux 2(?:\D|$)|\bamzn2\b)') {
        $distribution = 'Amazon Linux'
        $major = '2'
        $standardEnd = '2026-06-30'
        $extendedEnd = '2026-06-30'
        $target = 'Amazon Linux 2023 or another approved supported distribution'
    }

    if (-not $major -or -not $standardEnd) {
        return @{
            isLinux = $true; distribution = $distribution; release = if ($major) { "$distribution $major" } else { $reported }
            lifecycleState = 'unknown'; supportEnd = $null; extendedSupportEnd = $null
            recommendedTarget = 'Review the exact distribution, major release, service pack, and support entitlement'
            lifecycleAction = 'Lifecycle could not be determined reliably from the Arc-reported image and version.'
        }
    }

    $standardDate = [datetime]::ParseExact($standardEnd, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $extendedDate = [datetime]::ParseExact($extendedEnd, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $asOf = $AsOfDate.ToUniversalTime().Date
    $state = 'supported'
    $action = 'Supported; retain normal lifecycle planning.'
    if ($asOf -gt $extendedDate) {
        $state = 'unsupported'
        $action = "Upgrade or replace immediately; the reported release passed its final listed support milestone on $extendedEnd."
    }
    elseif ($asOf -ge $standardDate) {
        $state = 'extended-support'
        $action = "Validate the required paid or community extended-support entitlement and upgrade before $extendedEnd."
    }
    elseif ($standardDate -le $asOf.AddMonths(18)) {
        $state = 'approaching-eol'
        $action = "Plan and test an upgrade before standard support ends on $standardEnd."
    }

    return @{
        isLinux = $true
        distribution = $distribution
        release = "$distribution $major"
        lifecycleState = $state
        supportEnd = $standardEnd
        extendedSupportEnd = $extendedEnd
        recommendedTarget = $target
        lifecycleAction = $action
    }
}

function Get-PlatformInfo {
    param(
        [string]$CloudProvider,
        [string]$Manufacturer,
        [string]$Model,
        [string]$HypervisorType
    )

    $provider = if ($CloudProvider) { $CloudProvider.Trim() } else { '' }
    $maker = if ($Manufacturer) { $Manufacturer.Trim() } else { '' }
    $model = if ($Model) { $Model.Trim() } else { '' }
    $hypervisor = if ($HypervisorType) { $HypervisorType.Trim() } else { '' }

    if ($provider -eq 'AWS') {
        return @{ platform = 'AWS'; platformGroup = 'aws' }
    }

    if ($provider -eq 'Azure') {
        return @{ platform = 'Azure VM'; platformGroup = 'azure-vm' }
    }

    if ($provider -eq 'AzSHCI') {
        if ($model -eq 'Virtual Machine') {
            return @{ platform = 'Azure Local (VM)'; platformGroup = 'azure-local-vm' }
        }
        return @{ platform = 'Azure Local (physical node)'; platformGroup = 'azure-local-node' }
    }

    if ($maker -match '(?i)VMware') {
        return @{ platform = 'VMware'; platformGroup = 'vmware' }
    }

    if ($maker -eq 'Amazon EC2') {
        return @{ platform = 'AWS'; platformGroup = 'aws' }
    }

    if ($maker -eq 'Microsoft Corporation' -and $model -eq 'Virtual Machine') {
        if ($hypervisor -eq 'Hyper-V' -or -not $hypervisor) {
            return @{ platform = 'Hyper-V / Other virtual machine'; platformGroup = 'hyper-v' }
        }
    }

    if ($maker -or $model) {
        return @{ platform = 'Physical server'; platformGroup = 'physical' }
    }

    return @{ platform = 'Unknown'; platformGroup = 'unknown' }
}

function Get-ServerHealth {
    <#
    Server-side port of the health() function previously computed independently in the
    browser on every page. Computing it once per server at snapshot build time lets health
    become a normal, whitelisted, server-side filter/sort field at 50,000-server scale.
    #>
    param(
        [string]$ArcStatus,
        [int]$CriticalAlerts,
        [int]$ActiveAlerts,
        $LastHeartbeat
    )

    if ($ArcStatus -ne 'Connected') {
        return 'down'
    }
    if ($CriticalAlerts -gt 0) {
        return 'critical'
    }
    if (-not $LastHeartbeat) {
        return 'unknown'
    }
    $minutes = ((Get-Date).ToUniversalTime() - [datetime]$LastHeartbeat).TotalMinutes
    if ($minutes -le 5) {
        if ($ActiveAlerts -gt 0) { return 'warning' }
        return 'up'
    }
    if ($minutes -le 15) {
        return 'warning'
    }
    return 'down'
}

function ConvertTo-SafeUtcDateTime {
    <#
    Safely parses an Azure/Resource-Graph-reported date-time string (e.g. a
    tostring(datetime) value from KQL) without ever throwing. A single malformed,
    empty, or unexpected date value must never abort an entire snapshot build, sort,
    or summary aggregation -- it is simply treated as "no value" instead. Shared by
    Get-KubernetesClusterHealth, Get-KubernetesSummaryData, and the dynamically
    compiled date sort-key selectors in Select-OrderedKubernetesClusterList.
    #>
    param($Value)
    if (-not $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $parsed = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-KubernetesClusterHealth {
    <#
    Server-side, stable health classification for an Arc-enabled connected cluster.
    Precedence (checked in order, first match wins) mirrors Get-ServerHealth's
    connectivity-first design so both dashboards share one mental model:
      1. down      -- the control plane does not currently report the cluster as Connected
      2. critical  -- provisioning has failed, or the Arc agent is reporting active errors
      3. unknown   -- connected, but no last-connectivity timestamp has ever been recorded
                      (or the recorded value cannot be parsed as a date)
      4. down      -- connected, but the last-connectivity timestamp is badly stale (agent
                      heartbeat problem the control plane has not yet reflected)
      5. warning   -- connected, with a moderately stale heartbeat
      6. up        -- connected, with a recent heartbeat and no provisioning/agent errors
    #>
    param(
        [string]$ConnectivityStatus,
        [string]$ProvisioningState,
        [int]$AgentErrorCount,
        $LastConnectivityTime
    )

    if (([string]$ConnectivityStatus).ToLowerInvariant() -ne 'connected') {
        return 'down'
    }
    if ($ProvisioningState -and ([string]$ProvisioningState).ToLowerInvariant() -notin @('succeeded', 'provisioning', 'updating', 'accepted')) {
        return 'critical'
    }
    if ($AgentErrorCount -gt 0) {
        return 'critical'
    }
    $lastContact = ConvertTo-SafeUtcDateTime -Value $LastConnectivityTime
    if (-not $lastContact) {
        return 'unknown'
    }
    $minutes = ((Get-Date).ToUniversalTime() - $lastContact).TotalMinutes
    if ($minutes -gt 60) {
        return 'down'
    }
    if ($minutes -gt 15) {
        return 'warning'
    }
    return 'up'
}
# endregion Inventory enrichment helpers

# region Geography helpers (dynamic discovery only -- no fixed site/country tables)
function Resolve-CountryName {
    <#
    Ports the dashboard's existing dynamic country-name resolution (originally embedded in
    global.html) so it can run once per Azure region during snapshot aggregation instead of
    once per server in the browser. Country names come entirely from Azure's own location
    metadata (geography / geographyGroup / physicalLocation) -- there is no fixed per-tenant
    site or country table anywhere in this function.
    #>
    param(
        [string]$Geography,
        [string]$GeographyGroup,
        [string]$PhysicalLocation,
        [string]$DisplayName,
        [string]$Fallback
    )

    # A small set of generic Azure metadata label aliases/broad-geography groupings -- not
    # tenant-specific site names. These mirror Azure's own "Canary"/broad-geography labeling
    # quirks and apply identically for any subscription.
    $geographyAliases = @{ US = 'United States'; UK = 'United Kingdom' }
    $broadGeographies = @('Europe', 'Asia Pacific', 'Middle East', 'Africa')

    $geography = [string]$Geography
    $geographyGroup = [string]$GeographyGroup
    $physicalLocation = [string]$PhysicalLocation

    if ($geography -match '(?i)^canary\b') {
        if ($geographyAliases.ContainsKey($geographyGroup)) {
            return $geographyAliases[$geographyGroup]
        }
        if ($broadGeographies -contains $geographyGroup) {
            if ($physicalLocation) { return $physicalLocation }
            return $geographyGroup
        }
        if ($geographyGroup) { return $geographyGroup }
        if ($physicalLocation) { return $physicalLocation }
        return $geography
    }

    if ($broadGeographies -contains $geography) {
        if ($physicalLocation) { return $physicalLocation }
        return $geography
    }

    if ($geography) { return $geography }
    if ($physicalLocation) { return $physicalLocation }
    if ($DisplayName) { return $DisplayName.Trim() }
    return $Fallback
}

function Resolve-ContinentName {
    param(
        [double]$Latitude,
        [double]$Longitude,
        [string]$GeographyGroup
    )

    $group = ([string]$GeographyGroup).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ($group -eq 'middleeast') { return 'asia' }
    if ($group -eq 'africa') { return 'africa' }
    if ($Longitude -lt -30) {
        if ($Latitude -lt 15 -and $Longitude -gt -95) { return 'south-america' }
        return 'north-america'
    }
    if ($Longitude -ge 110 -and $Latitude -lt 0) { return 'oceania' }
    if ($Longitude -ge -25 -and $Longitude -le 45 -and $Latitude -ge 37) { return 'europe' }
    if ($Longitude -ge -25 -and $Longitude -lt 55 -and $Latitude -lt 37 -and -not ($Longitude -ge 45 -and $Latitude -ge 12)) { return 'africa' }
    return 'asia'
}
# endregion Geography helpers

# region Normalization and opaque cursor helpers
function ConvertTo-NormalizedResourceId {
    param([string]$Id)
    if (-not $Id) { return $Id }
    return $Id.Trim().ToLowerInvariant()
}

function New-ServerKey {
    <#
    Produces a short, URL-safe key for a normalized Azure resource ID so detail lookups never
    need to URL-encode a full resource ID path (which contains '/'). Collisions are not a
    practical concern at enterprise scale (64 bits of hash space for a 50,000-item set).
    #>
    param([Parameter(Mandatory)][string]$NormalizedId)
    $bytes = [Text.Encoding]::UTF8.GetBytes($NormalizedId)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return -join ($hash[0..7] | ForEach-Object { $_.ToString('x2') })
}

function Get-QuerySignature {
    <#
    A short deterministic fingerprint of the exact filter/sort/page-size combination in effect
    for a request. Cursors embed this signature so a cursor produced under one set of filters
    is rejected (as stale/invalid) if replayed against a different query.
    #>
    param([Parameter(Mandatory)][hashtable]$Parameters)
    $ordered = ($Parameters.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '&'
    $bytes = [Text.Encoding]::UTF8.GetBytes($ordered)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToBase64String($hash).Substring(0, 16)
}

function ConvertTo-Base64Url {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-Base64Url {
    param([Parameter(Mandatory)][string]$Text)
    $normalized = $Text.Replace('-', '+').Replace('_', '/')
    switch ($normalized.Length % 4) {
        2 { $normalized += '==' }
        3 { $normalized += '=' }
    }
    $bytes = [Convert]::FromBase64String($normalized)
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function New-OpaqueCursor {
    param(
        [Parameter(Mandatory)][string]$GenerationId,
        [Parameter(Mandatory)][string]$Signature,
        [Parameter(Mandatory)][int]$Offset
    )
    $payload = [ordered]@{ g = $GenerationId; s = $Signature; o = $Offset } | ConvertTo-Json -Compress
    return ConvertTo-Base64Url -Text $payload
}

function Resolve-OpaqueCursor {
    <#
    Because a snapshot generation is immutable for its entire lifetime, a simple
    (generationId, filter/sort signature, offset) tuple is a fully consistent pagination
    cursor: replaying it against the same generation and the same query always yields the
    same page. Any mismatch -- wrong generation, wrong filters/sort, corrupt payload, or a
    negative offset -- is treated as stale/invalid and rejected.
    #>
    param(
        [AllowEmptyString()][string]$Cursor,
        [Parameter(Mandatory)][string]$GenerationId,
        [Parameter(Mandatory)][string]$Signature
    )
    if (-not $Cursor) {
        return @{ Valid = $true; Offset = 0 }
    }
    try {
        $json = ConvertFrom-Base64Url -Text $Cursor
        $payload = $json | ConvertFrom-Json
        if ([string]$payload.g -ne $GenerationId -or [string]$payload.s -ne $Signature) {
            return @{ Valid = $false; Reason = 'stale' }
        }
        $offset = [int]$payload.o
        if ($offset -lt 0) {
            return @{ Valid = $false; Reason = 'invalid' }
        }
        return @{ Valid = $true; Offset = $offset }
    }
    catch {
        return @{ Valid = $false; Reason = 'invalid' }
    }
}
# endregion Normalization and opaque cursor helpers

# region Account, subscription, and resource-group discovery
function Get-ResourceGroupKqlFilter {
    param([string[]]$ResourceGroups)

    if (-not $ResourceGroups -or @($ResourceGroups).Count -eq 0) {
        return ''
    }
    $values = @($ResourceGroups | ForEach-Object { "'$($_.Replace("'", "''"))'" })
    return "| where resourceGroup in~ ($($values -join ', '))"
}

function Get-TargetAccountInfo {
    param([Parameter(Mandatory)][string]$SubscriptionId)

    return Invoke-AzJson @(
        'account', 'show', '--subscription', $SubscriptionId,
        '--query', '{subscriptionId:id,subscription:name,tenantId:tenantId,user:user.name}',
        '--output', 'json',
        '--only-show-errors'
    )
}

function Get-AzureLocationMetadataList {
    param([Parameter(Mandatory)][string]$SubscriptionId)

    Set-AzSubscriptionContext -SubscriptionId $SubscriptionId
    return @(Invoke-AzJson @(
        'account', 'list-locations',
        '--query', "[].{name:name,displayName:displayName,regionalDisplayName:regionalDisplayName,geography:metadata.geography,geographyGroup:metadata.geographyGroup,physicalLocation:metadata.physicalLocation,latitude:metadata.latitude,longitude:metadata.longitude}",
        '--output', 'json',
        '--only-show-errors'
    ))
}

function Get-AvailableSubscriptionList {
    param([switch]$Refresh)

    if (-not (Get-AzExecutable)) {
        return @()
    }
    try {
        $arguments = @(
            'account', 'list', '--all',
            '--query', "[?state=='Enabled'].{id:id,name:name,tenantId:tenantId,user:user.name}",
            '--output', 'json', '--only-show-errors'
        )
        if ($Refresh) {
            $arguments += '--refresh'
        }
        return @(Invoke-AzJson $arguments)
    }
    catch {
        return @()
    }
}

function Get-ArcResourceGroupList {
    <#
    Reports per-resource-group Arc server and Arc-enabled Kubernetes cluster counts using a
    single summarize aggregation instead of fetching per-machine/per-cluster inventory --
    efficient even against a 50,000-server subscription. A resource group is included when it
    contains either resource type, so a Kubernetes-only resource group (arcServers = 0) is
    still discoverable and selectable during setup.
    #>
    param([Parameter(Mandatory)][string]$SubscriptionId)

    if (-not (Get-AvailableSubscriptionList | Where-Object id -eq $SubscriptionId)) {
        throw 'The selected subscription is not available in the current Azure CLI sign-in.'
    }

    $query = @"
Resources
| where type in~ ('microsoft.hybridcompute/machines', 'microsoft.kubernetes/connectedclusters')
| summarize arcServers=countif(type =~ 'microsoft.hybridcompute/machines'),
            arcClusters=countif(type =~ 'microsoft.kubernetes/connectedclusters') by resourceGroup
| order by (arcServers + arcClusters) desc, resourceGroup asc
"@
    $result = Invoke-ResourceGraphAggregate -SubscriptionId $SubscriptionId -Query $query
    return @($result.data)
}

function Get-MonitoringWorkspaceList {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string[]]$ResourceGroups
    )

    $filter = Get-ResourceGroupKqlFilter -ResourceGroups $ResourceGroups
    $query = @"
Resources
| where type =~ 'microsoft.insights/datacollectionrules'
$filter
| mv-expand destination=properties.destinations.logAnalytics
| extend workspaceId=tostring(destination.workspaceId), workspaceResourceId=tostring(destination.workspaceResourceId)
| where isnotempty(workspaceId)
| project name=tostring(split(workspaceResourceId, '/')[-1]), id=workspaceId
"@
    $result = Invoke-ResourceGraphAggregate -SubscriptionId $SubscriptionId -Query $query
    # Fall back to all DCR destinations in the subscription when selected groups
    # contain machines but the DCR resources themselves live in shared groups.
    if (@($result.data).Count -eq 0) {
        $query = @"
Resources
| where type =~ 'microsoft.insights/datacollectionrules'
| mv-expand destination=properties.destinations.logAnalytics
| extend workspaceId=tostring(destination.workspaceId), workspaceResourceId=tostring(destination.workspaceResourceId)
| where isnotempty(workspaceId)
| project name=tostring(split(workspaceResourceId, '/')[-1]), id=workspaceId
"@
        $result = Invoke-ResourceGraphAggregate -SubscriptionId $SubscriptionId -Query $query
    }

    $candidates = @($result.data | Where-Object id | Group-Object id | ForEach-Object {
        @{ Name = [string]$_.Group[0].name; Id = [string]$_.Name }
    })
    # A workspace can remain provisioned while its Heartbeat table points to a deleted backend
    # database. Test the table required by Operations before saving it; a transient error (for
    # example a retried-out 429) intentionally keeps the workspace rather than excluding it --
    # only the known missing-database condition removes a workspace from the saved configuration.
    return @($candidates | Where-Object {
        try {
            $null = Invoke-LogAnalyticsQueryWithRetry -WorkspaceId $_.Id -Query 'Heartbeat | take 0' -SubscriptionId $SubscriptionId
            $true
        }
        catch {
            -not (Test-MissingLogAnalyticsDatabase -ErrorMessage $_.Exception.Message)
        }
    })
}
# endregion Account, subscription, and resource-group discovery

# region Operations snapshot builder
function Build-OperationsSnapshot {
    <#
    .SYNOPSIS
    Builds one complete, immutable operations snapshot: unified per-server inventory
    (merging what used to be two separate full-inventory Resource Graph queries),
    deployment/extension coverage, patch/alert posture, Log Analytics telemetry, Windows
    lifecycle status, platform classification, computed health, and pre-aggregated summary
    and geography rollups -- all computed once per refresh cycle rather than per request.

    .DESCRIPTION
    The caller is responsible for publishing the returned object atomically (a single
    assignment to a shared snapshot slot) only after this function returns successfully, so
    partially built state is never visible to request handlers.
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string[]]$ResourceGroups,
        [array]$Workspaces = @(),
        [int]$LogAnalyticsConcurrency = 4
    )

    $account = Get-TargetAccountInfo -SubscriptionId $SubscriptionId
    $resourceGroupFilter = Get-ResourceGroupKqlFilter -ResourceGroups $ResourceGroups

    # One inventory query now supplies every field previously split across the Operations and
    # Deployment queries, halving the number of full-inventory Resource Graph page sequences
    # needed per refresh at 50,000-server scale.
    $machinesQuery = @"
Resources
| where type =~ 'microsoft.hybridcompute/machines'
$resourceGroupFilter
| extend normalizedOsType=tolower(tostring(properties.osType)), osName=tostring(properties.osName)
| where normalizedOsType in ('windows', 'linux') or osName contains 'Windows' or osName contains 'Linux'
| extend osType=case(normalizedOsType in ('windows', 'linux'), normalizedOsType, osName contains 'Windows', 'windows', 'linux')
| project id=tolower(id), name, resourceGroup, arcStatus=tostring(properties.status), osType, osName,
          osSku=tostring(properties.osSku), osVersion=tostring(properties.osVersion), location,
          agentVersion=tostring(properties.agentVersion),
          cpuCores=toint(properties.detectedProperties.coreCount),
          logicalCpuCores=toint(properties.detectedProperties.logicalCoreCount),
          totalMemoryBytes=tolong(properties.detectedProperties.totalPhysicalMemoryInBytes),
          storageDisks=properties.storageProfile.disks,
          cloudProvider=tostring(properties.detectedProperties.cloudprovider),
          infraManufacturer=tostring(properties.detectedProperties.manufacturer),
          infraModel=tostring(properties.detectedProperties.model),
          hypervisorType=tostring(properties.detectedProperties.hypervisorType)
| order by name asc
"@

    $extensionsQuery = @"
Resources
| where type =~ 'microsoft.hybridcompute/machines/extensions'
$resourceGroupFilter
| extend machineId=tolower(substring(id, 0, indexof(id, '/extensions/')))
| project machineId, name, publisher=tostring(properties.publisher),
          extensionType=tostring(properties.type),
          version=tostring(properties.typeHandlerVersion),
          provisioningState=tostring(properties.provisioningState)
"@

    $assessmentQuery = @"
PatchAssessmentResources
| where type =~ 'microsoft.hybridcompute/machines/patchassessmentresults'
$resourceGroupFilter
| extend resourceId=tolower(substring(id, 0, indexof(id, '/patchAssessmentResults/')))
| extend critical=coalesce(toint(properties.availablePatchCountByClassification.critical), 0),
         security=coalesce(toint(properties.availablePatchCountByClassification.security), 0),
         updates=coalesce(toint(properties.availablePatchCountByClassification.updates), 0),
         rollups=coalesce(toint(properties.availablePatchCountByClassification.updateRollup), 0),
         features=coalesce(toint(properties.availablePatchCountByClassification.featurePack), 0),
         services=coalesce(toint(properties.availablePatchCountByClassification.servicePack), 0),
         definitions=coalesce(toint(properties.availablePatchCountByClassification.definition), 0),
         tools=coalesce(toint(properties.availablePatchCountByClassification.tools), 0),
         other=coalesce(toint(properties.availablePatchCountByClassification.other), 0)
| extend pendingUpdates=critical + security + updates + rollups + features + services + definitions + tools + other
| project resourceId, pendingUpdates, criticalUpdates=critical, securityUpdates=security,
          rebootPending=tobool(properties.rebootPending), lastAssessment=tostring(properties.lastModifiedDateTime)
"@

    $alertsQuery = @"
AlertsManagementResources
| where type =~ 'microsoft.alertsmanagement/alerts'
$resourceGroupFilter
| where tostring(properties.essentials.monitorCondition) =~ 'Fired'
| where tostring(properties.essentials.targetResourceType) =~ 'microsoft.hybridcompute/machines'
| where todatetime(properties.essentials.lastModifiedDateTime) > ago(1h)
| extend resourceId=tolower(tostring(properties.essentials.targetResource)),
         severity=tostring(properties.essentials.severity)
| summarize activeAlerts=count(),
            criticalAlerts=countif(severity in~ ('Sev0', 'Sev1')),
            warningAlerts=countif(severity == 'Sev2') by resourceId
"@

    $telemetryQuery = @"
let heartbeat = Heartbeat
| where TimeGenerated > ago(2h)
| summarize arg_max(TimeGenerated, _ResourceId, OSType, Version) by Computer
| extend machineKey=tolower(tostring(split(Computer, '.')[0]));
let cpuInsights = InsightsMetrics
| where TimeGenerated > ago(30m) and Namespace == 'Processor' and Name == 'UtilizationPercentage'
| summarize cpuInsights=avg(todouble(Val)) by machineKey=tolower(tostring(split(Computer, '.')[0]));
let memoryInsights = InsightsMetrics
| where TimeGenerated > ago(30m) and Namespace == 'Memory' and Name == 'AvailableMB'
| extend totalMB=todouble(parse_json(Tags)['vm.azm.ms/memorySizeMB'])
| where totalMB > 0
| extend usedPercent=100.0 * (1.0 - todouble(Val) / totalMB)
| summarize memoryInsights=avg(usedPercent) by machineKey=tolower(tostring(split(Computer, '.')[0]));
let diskInsights = InsightsMetrics
| where TimeGenerated > ago(30m) and Namespace == 'LogicalDisk' and Name == 'FreeSpacePercentage'
| summarize diskInsights=min(todouble(Val)) by machineKey=tolower(tostring(split(Computer, '.')[0]));
let networkInsights = InsightsMetrics
| where TimeGenerated > ago(30m) and Namespace == 'Network' and Name in ('ReadBytesPerSecond', 'WriteBytesPerSecond')
| summarize intervalBytes=sum(todouble(Val)) by machineKey=tolower(tostring(split(Computer, '.')[0])), bin(TimeGenerated, 5m)
| summarize networkInsights=avg(intervalBytes) by machineKey;
let diskIoInsights = InsightsMetrics
| where TimeGenerated > ago(30m) and Namespace == 'LogicalDisk'
| where Name in ('ReadOperationsPerSecond', 'ReadsPerSecond', 'WriteOperationsPerSecond', 'WritesPerSecond',
                 'ReadBytesPerSecond', 'WriteBytesPerSecond', 'AverageReadMilliseconds',
                 'AverageWriteMilliseconds', 'ReadLatencyMs', 'WriteLatencyMs',
                 'CurrentQueueLength', 'CurrentDiskQueueLength')
| extend mountId=tostring(parse_json(Tags)['vm.azm.ms/mountId'])
| where mountId !in ('_Total', '_total')
| extend machineKey=tolower(tostring(split(Computer, '.')[0]))
| summarize instanceValue=avg(todouble(Val)) by machineKey, Name, dimension=tostring(Tags), bin(TimeGenerated, 1m)
| summarize readIopsValue=sumif(instanceValue, Name in ('ReadOperationsPerSecond', 'ReadsPerSecond')),
            readIopsCount=countif(Name in ('ReadOperationsPerSecond', 'ReadsPerSecond')),
            writeIopsValue=sumif(instanceValue, Name in ('WriteOperationsPerSecond', 'WritesPerSecond')),
            writeIopsCount=countif(Name in ('WriteOperationsPerSecond', 'WritesPerSecond')),
            readBytesValue=sumif(instanceValue, Name == 'ReadBytesPerSecond'),
            readBytesCount=countif(Name == 'ReadBytesPerSecond'),
            writeBytesValue=sumif(instanceValue, Name == 'WriteBytesPerSecond'),
            writeBytesCount=countif(Name == 'WriteBytesPerSecond'),
            readLatencyValue=avgif(instanceValue, Name in ('AverageReadMilliseconds', 'ReadLatencyMs')),
            readLatencyCount=countif(Name in ('AverageReadMilliseconds', 'ReadLatencyMs')),
            writeLatencyValue=avgif(instanceValue, Name in ('AverageWriteMilliseconds', 'WriteLatencyMs')),
            writeLatencyCount=countif(Name in ('AverageWriteMilliseconds', 'WriteLatencyMs')),
            queueValue=sumif(instanceValue, Name in ('CurrentQueueLength', 'CurrentDiskQueueLength')),
            queueCount=countif(Name in ('CurrentQueueLength', 'CurrentDiskQueueLength'))
            by machineKey, TimeGenerated
| extend diskReadIops=iff(readIopsCount > 0, readIopsValue, real(null)),
         diskWriteIops=iff(writeIopsCount > 0, writeIopsValue, real(null)),
         diskReadBytesPerSec=iff(readBytesCount > 0, readBytesValue, real(null)),
         diskWriteBytesPerSec=iff(writeBytesCount > 0, writeBytesValue, real(null)),
         diskReadLatencyMs=iff(readLatencyCount > 0, readLatencyValue, real(null)),
         diskWriteLatencyMs=iff(writeLatencyCount > 0, writeLatencyValue, real(null)),
         diskQueueLength=iff(queueCount > 0, queueValue, real(null))
| summarize diskReadIopsInsights=avg(diskReadIops), diskWriteIopsInsights=avg(diskWriteIops),
            diskReadBytesPerSecInsights=avg(diskReadBytesPerSec), diskWriteBytesPerSecInsights=avg(diskWriteBytesPerSec),
            diskReadLatencyMsInsights=avg(diskReadLatencyMs), diskWriteLatencyMsInsights=avg(diskWriteLatencyMs),
            diskQueueLengthInsights=avg(diskQueueLength) by machineKey;
let cpuPerf = Perf
| where TimeGenerated > ago(30m) and CounterName == '% Processor Time' and ObjectName in ('Processor', 'Processor Information')
| summarize cpuPerf=avg(CounterValue) by machineKey=tolower(tostring(split(Computer, '.')[0]));
let memoryPerf = Perf
| where TimeGenerated > ago(30m) and CounterName == '% Committed Bytes In Use'
| summarize memoryPerf=avg(CounterValue) by machineKey=tolower(tostring(split(Computer, '.')[0]));
let diskPerf = Perf
| where TimeGenerated > ago(30m) and CounterName == '% Free Space' and InstanceName !in ('_Total', '_total')
| summarize diskPerf=min(CounterValue) by machineKey=tolower(tostring(split(Computer, '.')[0]));
let networkPerf = Perf
| where TimeGenerated > ago(30m) and CounterName == 'Bytes Total/sec' and ObjectName == 'Network Interface'
| summarize intervalBytes=sum(CounterValue) by machineKey=tolower(tostring(split(Computer, '.')[0])), bin(TimeGenerated, 5m)
| summarize networkPerf=avg(intervalBytes) by machineKey;
let diskIoPerf = Perf
| where TimeGenerated > ago(30m)
| where ObjectName in ('LogicalDisk', 'Logical Disk')
| where InstanceName !in ('_Total', '_total')
| where CounterName in ('Disk Reads/sec', 'Disk Writes/sec', 'Disk Read Bytes/sec', 'Disk Write Bytes/sec',
                        'Avg. Disk sec/Read', 'Avg. Disk sec/Write', 'Current Disk Queue Length')
| extend machineKey=tolower(tostring(split(Computer, '.')[0]))
| summarize instanceValue=avg(CounterValue) by machineKey, CounterName, InstanceName, bin(TimeGenerated, 1m)
| summarize readIopsValue=sumif(instanceValue, CounterName == 'Disk Reads/sec'),
            readIopsCount=countif(CounterName == 'Disk Reads/sec'),
            writeIopsValue=sumif(instanceValue, CounterName == 'Disk Writes/sec'),
            writeIopsCount=countif(CounterName == 'Disk Writes/sec'),
            readBytesValue=sumif(instanceValue, CounterName == 'Disk Read Bytes/sec'),
            readBytesCount=countif(CounterName == 'Disk Read Bytes/sec'),
            writeBytesValue=sumif(instanceValue, CounterName == 'Disk Write Bytes/sec'),
            writeBytesCount=countif(CounterName == 'Disk Write Bytes/sec'),
            readLatencyValue=avgif(instanceValue * 1000.0, CounterName == 'Avg. Disk sec/Read'),
            readLatencyCount=countif(CounterName == 'Avg. Disk sec/Read'),
            writeLatencyValue=avgif(instanceValue * 1000.0, CounterName == 'Avg. Disk sec/Write'),
            writeLatencyCount=countif(CounterName == 'Avg. Disk sec/Write'),
            queueValue=sumif(instanceValue, CounterName == 'Current Disk Queue Length'),
            queueCount=countif(CounterName == 'Current Disk Queue Length')
            by machineKey, TimeGenerated
| extend diskReadIops=iff(readIopsCount > 0, readIopsValue, real(null)),
         diskWriteIops=iff(writeIopsCount > 0, writeIopsValue, real(null)),
         diskReadBytesPerSec=iff(readBytesCount > 0, readBytesValue, real(null)),
         diskWriteBytesPerSec=iff(writeBytesCount > 0, writeBytesValue, real(null)),
         diskReadLatencyMs=iff(readLatencyCount > 0, readLatencyValue, real(null)),
         diskWriteLatencyMs=iff(writeLatencyCount > 0, writeLatencyValue, real(null)),
         diskQueueLength=iff(queueCount > 0, queueValue, real(null))
| summarize diskReadIopsPerf=avg(diskReadIops), diskWriteIopsPerf=avg(diskWriteIops),
            diskReadBytesPerSecPerf=avg(diskReadBytesPerSec), diskWriteBytesPerSecPerf=avg(diskWriteBytesPerSec),
            diskReadLatencyMsPerf=avg(diskReadLatencyMs), diskWriteLatencyMsPerf=avg(diskWriteLatencyMs),
            diskQueueLengthPerf=avg(diskQueueLength) by machineKey;
heartbeat
| join kind=leftouter cpuInsights on machineKey
| join kind=leftouter memoryInsights on machineKey
| join kind=leftouter diskInsights on machineKey
| join kind=leftouter networkInsights on machineKey
| join kind=leftouter diskIoInsights on machineKey
| join kind=leftouter cpuPerf on machineKey
| join kind=leftouter memoryPerf on machineKey
| join kind=leftouter diskPerf on machineKey
| join kind=leftouter networkPerf on machineKey
| join kind=leftouter diskIoPerf on machineKey
| extend diskReadIops=coalesce(diskReadIopsInsights, diskReadIopsPerf),
         diskWriteIops=coalesce(diskWriteIopsInsights, diskWriteIopsPerf),
         diskReadBytesPerSec=coalesce(diskReadBytesPerSecInsights, diskReadBytesPerSecPerf),
         diskWriteBytesPerSec=coalesce(diskWriteBytesPerSecInsights, diskWriteBytesPerSecPerf),
         diskReadLatencyMs=coalesce(diskReadLatencyMsInsights, diskReadLatencyMsPerf),
         diskWriteLatencyMs=coalesce(diskWriteLatencyMsInsights, diskWriteLatencyMsPerf),
         diskQueueLength=coalesce(diskQueueLengthInsights, diskQueueLengthPerf)
| extend diskIops=iff(isnull(diskReadIops) and isnull(diskWriteIops), real(null),
                      coalesce(diskReadIops, 0.0) + coalesce(diskWriteIops, 0.0)),
         diskBytesPerSec=iff(isnull(diskReadBytesPerSec) and isnull(diskWriteBytesPerSec), real(null),
                             coalesce(diskReadBytesPerSec, 0.0) + coalesce(diskWriteBytesPerSec, 0.0))
| project resourceId=tolower(_ResourceId), computer=Computer, lastHeartbeat=TimeGenerated,
          monitorAgentVersion=Version, cpuPercent=coalesce(cpuInsights, cpuPerf),
          memoryPercent=coalesce(memoryInsights, memoryPerf),
          diskFreePercent=coalesce(diskInsights, diskPerf),
          networkBytesPerSec=coalesce(networkInsights, networkPerf),
          diskIops, diskBytesPerSec, diskReadIops, diskWriteIops,
          diskReadBytesPerSec, diskWriteBytesPerSec, diskReadLatencyMs, diskWriteLatencyMs, diskQueueLength
"@

    $machines = Invoke-ResourceGraphQueryAll -SubscriptionId $account.subscriptionId -Query $machinesQuery
    $extensions = Invoke-ResourceGraphQueryAll -SubscriptionId $account.subscriptionId -Query $extensionsQuery -MaxPages 1000
    $assessments = Invoke-ResourceGraphQueryAll -SubscriptionId $account.subscriptionId -Query $assessmentQuery
    $alerts = Invoke-ResourceGraphQueryAll -SubscriptionId $account.subscriptionId -Query $alertsQuery
    $locations = Get-AzureLocationMetadataList -SubscriptionId $account.subscriptionId

    $assessmentMap = @{}
    foreach ($item in @($assessments.data)) { $assessmentMap[[string]$item.resourceId] = $item }

    $alertMap = @{}
    foreach ($item in @($alerts.data)) { $alertMap[[string]$item.resourceId] = $item }

    # Arc extensions use OS-specific names; normalize to stable product categories.
    $emptyExtensionSet = {
        @{
            azureMonitorAgent = @(); dependencyAgent = @(); changeTracking = @(); guestConfiguration = @()
            defenderForServers = @(); updateManager = @(); customScript = @(); sqlServer = @(); adminCenter = @()
            allExtensions = @()
        }
    }
    $extensionMap = @{}
    foreach ($extension in @($extensions.data)) {
        $key = [string]$extension.machineId
        if (-not $extensionMap.ContainsKey($key)) {
            $extensionMap[$key] = & $emptyExtensionSet
        }
        $identity = "$($extension.name) $($extension.publisher) $($extension.extensionType)".ToLowerInvariant()
        $category = switch -Regex ($identity) {
            'azuremonitorwindowsagent|azuremonitorlinuxagent|azuremonitoragent' { 'azureMonitorAgent'; break }
            'dependencyagent' { 'dependencyAgent'; break }
            'changetracking' { 'changeTracking'; break }
            'azurepolicyforwindows|azurepolicyforlinux|guestconfiguration' { 'guestConfiguration'; break }
            'azuredefenderforservers|mde\.windows|mde\.linux|defenderforendpoint' { 'defenderForServers'; break }
            'windowsosupdateextension|linuxosupdateextension|windowspatchextension|linuxpatchextension|softwareupdatemanagement' { 'updateManager'; break }
            'customscript' { 'customScript'; break }
            'windowsagent\.sqlserver|linuxagent\.sqlserver|azureextensionforsqlserver' { 'sqlServer'; break }
            'windowsadmincenter|admincenter' { 'adminCenter'; break }
            default { $null }
        }
        $detail = @{
            name = $extension.name; publisher = $extension.publisher; extensionType = $extension.extensionType
            version = $extension.version; provisioningState = $extension.provisioningState
            installed = ([string]$extension.provisioningState -eq 'Succeeded')
        }
        $extensionMap[$key].allExtensions += $detail
        if ($category) { $extensionMap[$key][$category] += $detail }
    }

    # A server may report to more than one workspace. Preserve the newest heartbeat while
    # filling missing metrics from another workspace when possible. Workspaces are queried
    # with bounded concurrency so a single slow or unavailable workspace cannot delay or fail
    # every other workspace's telemetry.
    $telemetryMap = @{}
    $workspaceErrors = @()
    if (@($Workspaces).Count -gt 0) {
        $bounded = Invoke-LogAnalyticsQueryBounded -Workspaces $Workspaces -Query $telemetryQuery -SubscriptionId $account.subscriptionId -MaxConcurrency $LogAnalyticsConcurrency
        $workspaceErrors = @($bounded.Errors)
        foreach ($workspaceName in $bounded.Results.Keys) {
            foreach ($item in @($bounded.Results[$workspaceName])) {
                if (-not $item.resourceId) { continue }
                $key = ([string]$item.resourceId).ToLowerInvariant()
                if (-not $telemetryMap.ContainsKey($key)) {
                    $telemetryMap[$key] = $item
                    continue
                }
                $existing = $telemetryMap[$key]
                if ([datetime]$item.lastHeartbeat -gt [datetime]$existing.lastHeartbeat) {
                    foreach ($property in @(
                        'cpuPercent', 'memoryPercent', 'diskFreePercent', 'networkBytesPerSec', 'diskIops', 'diskBytesPerSec',
                        'diskReadIops', 'diskWriteIops', 'diskReadBytesPerSec', 'diskWriteBytesPerSec',
                        'diskReadLatencyMs', 'diskWriteLatencyMs', 'diskQueueLength'
                    )) {
                        if ($null -eq $item.$property -and $null -ne $existing.$property) { $item.$property = $existing.$property }
                    }
                    $telemetryMap[$key] = $item
                }
                else {
                    foreach ($property in @(
                        'cpuPercent', 'memoryPercent', 'diskFreePercent', 'networkBytesPerSec', 'diskIops', 'diskBytesPerSec',
                        'diskReadIops', 'diskWriteIops', 'diskReadBytesPerSec', 'diskWriteBytesPerSec',
                        'diskReadLatencyMs', 'diskWriteLatencyMs', 'diskQueueLength'
                    )) {
                        if ($null -eq $existing.$property -and $null -ne $item.$property) { $existing.$property = $item.$property }
                    }
                }
            }
        }
    }

    $servers = [ordered]@{}
    $keyToId = @{}
    foreach ($machine in @($machines.data)) {
        $id = [string]$machine.id
        $assessment = $assessmentMap[$id]
        $alert = $alertMap[$id]
        $telemetry = $telemetryMap[$id]
        $machineExtensions = $extensionMap[$id]
        if (-not $machineExtensions) { $machineExtensions = & $emptyExtensionSet }
        $lifecycle = Get-WindowsServerLifecycle -OsSku $machine.osSku -OsVersion $machine.osVersion
        $linuxLifecycle = Get-LinuxLifecycle -OsType $machine.osType -OsName $machine.osName -OsSku $machine.osSku -OsVersion $machine.osVersion
        $platform = Get-PlatformInfo -CloudProvider $machine.cloudProvider -Manufacturer $machine.infraManufacturer -Model $machine.infraModel -HypervisorType $machine.hypervisorType

        $diskSizes = @($machine.storageDisks | ForEach-Object { if ($null -ne $_.maxSizeInBytes) { [long]$_.maxSizeInBytes } })
        $totalStorageBytes = if ($diskSizes.Count) { ($diskSizes | Measure-Object -Sum).Sum } else { $null }

        $reportedOsVersion = [string]$machine.osVersion
        $osVersion = if ($reportedOsVersion) { $reportedOsVersion } else { 'Not reported by Arc agent' }
        $osBuildNumber = $reportedOsVersion
        if ([string]$machine.osType -eq 'windows' -and $reportedOsVersion -match '^\d+\.\d+\.(.+)$') {
            $osBuildNumber = $Matches[1]
        }
        if (-not $osBuildNumber) { $osBuildNumber = 'Not reported by Arc agent' }

        $activeAlerts = if ($alert) { [int]$alert.activeAlerts } else { 0 }
        $criticalAlerts = if ($alert) { [int]$alert.criticalAlerts } else { 0 }
        $lastHeartbeat = if ($telemetry) { $telemetry.lastHeartbeat } else { $null }
        $health = Get-ServerHealth -ArcStatus ([string]$machine.arcStatus) -CriticalAlerts $criticalAlerts -ActiveAlerts $activeAlerts -LastHeartbeat $lastHeartbeat

        $key = New-ServerKey -NormalizedId $id
        $keyToId[$key] = $id

        $servers[$id] = [pscustomobject][ordered]@{
            id                 = $id
            key                = $key
            name               = $machine.name
            resourceGroup      = $machine.resourceGroup
            location           = $machine.location
            arcStatus          = $machine.arcStatus
            osType             = $machine.osType
            osName             = $machine.osName
            osSku              = $machine.osSku
            osVersion          = $osVersion
            osBuildNumber      = $osBuildNumber
            agentVersion       = $machine.agentVersion
            cpuCores           = $machine.cpuCores
            logicalCpuCores    = $machine.logicalCpuCores
            totalMemoryBytes   = $machine.totalMemoryBytes
            totalStorageBytes  = $totalStorageBytes
            storageDiskCount   = $diskSizes.Count
            cloudProvider      = $machine.cloudProvider
            infraManufacturer  = $machine.infraManufacturer
            infraModel         = $machine.infraModel
            hypervisorType     = $machine.hypervisorType
            platform           = $platform.platform
            platformGroup      = $platform.platformGroup
            health             = $health
            pendingUpdates     = if ($assessment) { $assessment.pendingUpdates } else { 0 }
            criticalUpdates    = if ($assessment) { $assessment.criticalUpdates } else { 0 }
            securityUpdates    = if ($assessment) { $assessment.securityUpdates } else { 0 }
            rebootPending      = if ($assessment) { [bool]$assessment.rebootPending } else { $false }
            lastAssessment     = if ($assessment) { $assessment.lastAssessment } else { $null }
            activeAlerts       = $activeAlerts
            criticalAlerts     = $criticalAlerts
            warningAlerts      = if ($alert) { [int]$alert.warningAlerts } else { 0 }
            computer           = if ($telemetry) { $telemetry.computer } else { $machine.name }
            lastHeartbeat      = $lastHeartbeat
            monitorAgentVersion = if ($telemetry) { $telemetry.monitorAgentVersion } else { $null }
            cpuPercent         = if ($telemetry) { $telemetry.cpuPercent } else { $null }
            memoryPercent      = if ($telemetry) { $telemetry.memoryPercent } else { $null }
            diskFreePercent    = if ($telemetry) { $telemetry.diskFreePercent } else { $null }
            networkBytesPerSec = if ($telemetry) { $telemetry.networkBytesPerSec } else { $null }
            diskIops           = if ($telemetry) { $telemetry.diskIops } else { $null }
            diskBytesPerSec    = if ($telemetry) { $telemetry.diskBytesPerSec } else { $null }
            diskReadIops       = if ($telemetry) { $telemetry.diskReadIops } else { $null }
            diskWriteIops      = if ($telemetry) { $telemetry.diskWriteIops } else { $null }
            diskReadBytesPerSec = if ($telemetry) { $telemetry.diskReadBytesPerSec } else { $null }
            diskWriteBytesPerSec = if ($telemetry) { $telemetry.diskWriteBytesPerSec } else { $null }
            diskReadLatencyMs  = if ($telemetry) { $telemetry.diskReadLatencyMs } else { $null }
            diskWriteLatencyMs = if ($telemetry) { $telemetry.diskWriteLatencyMs } else { $null }
            diskQueueLength    = if ($telemetry) { $telemetry.diskQueueLength } else { $null }
            isWindowsServer    = $lifecycle.isWindowsServer
            windowsRelease     = $lifecycle.windowsRelease
            lifecycleState     = $lifecycle.lifecycleState
            supportEnd         = $lifecycle.supportEnd
            esuEnd             = $lifecycle.esuEnd
            recommendedTarget  = $lifecycle.recommendedTarget
            lifecycleAction    = $lifecycle.lifecycleAction
            isLinux             = $linuxLifecycle.isLinux
            linuxDistribution  = $linuxLifecycle.distribution
            linuxRelease       = $linuxLifecycle.release
            linuxLifecycleState = $linuxLifecycle.lifecycleState
            linuxSupportEnd    = $linuxLifecycle.supportEnd
            linuxExtendedSupportEnd = $linuxLifecycle.extendedSupportEnd
            linuxRecommendedTarget = $linuxLifecycle.recommendedTarget
            linuxLifecycleAction = $linuxLifecycle.lifecycleAction
            azureMonitorAgent  = @($machineExtensions.azureMonitorAgent | Where-Object installed).Count -gt 0
            dependencyAgent    = @($machineExtensions.dependencyAgent | Where-Object installed).Count -gt 0
            changeTracking     = @($machineExtensions.changeTracking | Where-Object installed).Count -gt 0
            guestConfiguration = @($machineExtensions.guestConfiguration | Where-Object installed).Count -gt 0
            defenderForServers = @($machineExtensions.defenderForServers | Where-Object installed).Count -gt 0
            updateManager      = @($machineExtensions.updateManager | Where-Object installed).Count -gt 0
            customScript       = @($machineExtensions.customScript | Where-Object installed).Count -gt 0
            sqlServer          = @($machineExtensions.sqlServer | Where-Object installed).Count -gt 0
            adminCenter        = @($machineExtensions.adminCenter | Where-Object installed).Count -gt 0
            extensions         = @($machineExtensions.allExtensions)
        }
    }

    $generationId = [guid]::NewGuid().ToString('n')
    $generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    $serverArray = @($servers.Values)

    $summary = Get-OperationsSummaryData -Servers $serverArray
    $geography = Build-GeographySummary -Servers $serverArray -Locations $locations

    return [pscustomobject]@{
        generationId    = $generationId
        generatedAt     = $generatedAt
        account         = $account
        servers         = $servers
        keyToId         = $keyToId
        serverArray     = $serverArray
        locations       = @($locations)
        workspaces      = @($Workspaces | ForEach-Object Name)
        workspaceErrors = $workspaceErrors
        summary         = $summary
        geography       = $geography
    }
}
# endregion Operations snapshot builder

# region Summary and geography aggregation (computed once per refresh, not per request)
function Get-OperationsSummaryData {
    <#
    Single-pass aggregation over the full server array producing every fleet-wide total, the
    ranked "attention" panels, lifecycle band counts, platform/deployment coverage, and the
    distinct-value facets the frontend needs to populate filter dropdowns -- all without ever
    sending the underlying 50,000 records to the browser.
    #>
    param([Parameter(Mandatory)][array]$Servers)

    $total = $Servers.Count
    $healthCounts = @{ up = 0; warning = 0; down = 0; critical = 0; unknown = 0 }
    $alertTotal = 0L
    $updateTotal = 0L
    $securityUpdateTotal = 0L
    $criticalUpdateTotal = 0L
    $serversWithSecurityUpdates = 0
    $serversWithCriticalUpdates = 0
    $coreTotal = 0L
    $memoryTotal = 0L
    $storageTotal = 0L
    $cpuSum = 0.0; $cpuCount = 0
    $memorySum = 0.0; $memoryCount = 0
    $lifecycleCounts = @{ unsupported = 0; 'esu-ending' = 0; 'approaching-eol' = 0; supported = 0; unknown = 0 }
    $linuxLifecycleCounts = @{ unsupported = 0; 'extended-support' = 0; 'approaching-eol' = 0; supported = 0; unknown = 0 }
    $osImageCounts = @{}
    $platformCounts = @{}
    $capabilities = @('azureMonitorAgent', 'dependencyAgent', 'changeTracking', 'guestConfiguration', 'defenderForServers', 'updateManager', 'customScript', 'sqlServer', 'adminCenter')
    $capabilityInstalled = @{}
    $capabilityApplicable = @{}
    foreach ($capability in $capabilities) { $capabilityInstalled[$capability] = 0; $capabilityApplicable[$capability] = 0 }
    $resourceGroups = [Collections.Generic.HashSet[string]]::new()
    $locations = [Collections.Generic.HashSet[string]]::new()

    foreach ($server in $Servers) {
        if ($healthCounts.ContainsKey($server.health)) { $healthCounts[$server.health]++ }
        $alertTotal += [int64]$server.activeAlerts
        $updateTotal += [int64]$server.pendingUpdates
        $securityUpdateTotal += [int64]$server.securityUpdates
        $criticalUpdateTotal += [int64]$server.criticalUpdates
        if ([int64]$server.securityUpdates -gt 0) { $serversWithSecurityUpdates++ }
        if ([int64]$server.criticalUpdates -gt 0) { $serversWithCriticalUpdates++ }
        if ($null -ne $server.cpuCores) { $coreTotal += [int64]$server.cpuCores }
        if ($null -ne $server.totalMemoryBytes) { $memoryTotal += [int64]$server.totalMemoryBytes }
        if ($null -ne $server.totalStorageBytes) { $storageTotal += [int64]$server.totalStorageBytes }
        if ($null -ne $server.cpuPercent) { $cpuSum += [double]$server.cpuPercent; $cpuCount++ }
        if ($null -ne $server.memoryPercent) { $memorySum += [double]$server.memoryPercent; $memoryCount++ }
        if ($server.isWindowsServer -and $lifecycleCounts.ContainsKey($server.lifecycleState)) { $lifecycleCounts[$server.lifecycleState]++ }
        if ($server.isLinux -and $linuxLifecycleCounts.ContainsKey($server.linuxLifecycleState)) { $linuxLifecycleCounts[$server.linuxLifecycleState]++ }

        $osImage = if ($server.osSku -and [string]$server.osSku -ne 'Not reported by Arc agent') {
            [string]$server.osSku
        }
        elseif ($server.osName) { [string]$server.osName }
        elseif ($server.osType) { "$($server.osType) - image not reported" }
        else { 'Unknown OS image' }
        if (-not $osImageCounts.ContainsKey($osImage)) { $osImageCounts[$osImage] = 0 }
        $osImageCounts[$osImage]++

        $group = if ($server.platformGroup) { [string]$server.platformGroup } else { 'unknown' }
        if (-not $platformCounts.ContainsKey($group)) { $platformCounts[$group] = @{ platform = $server.platform; count = 0 } }
        $platformCounts[$group].count++

        foreach ($capability in $capabilities) {
            $applicable = ($capability -ne 'adminCenter') -or ([string]$server.osType -eq 'windows')
            if ($applicable) {
                $capabilityApplicable[$capability]++
                if ($server.$capability) { $capabilityInstalled[$capability]++ }
            }
        }

        if ($server.resourceGroup) { [void]$resourceGroups.Add([string]$server.resourceGroup) }
        if ($server.location) { [void]$locations.Add([string]$server.location) }
    }

    function Get-TopServers {
        # Runs once per (already Azure-I/O-bound) snapshot refresh, not per request, so
        # Sort-Object's reflection-based comparisons are an acceptable, simple choice here.
        param([array]$Servers, [string]$Property, [int]$Take = 5, [switch]$Ascending)
        $withValue = @($Servers | Where-Object { $null -ne $_.$Property })
        $ordered = if ($Ascending) { $withValue | Sort-Object -Property $Property } else { $withValue | Sort-Object -Property $Property -Descending }
        return @($ordered | Select-Object -First $Take | ForEach-Object { @{ name = $_.name; value = $_.$Property } })
    }

    $allOsImages = @($osImageCounts.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object {
        @{ name = $_.Key; count = $_.Value }
    })
    $osImages = @($allOsImages | Select-Object -First 25)
    if ($allOsImages.Count -gt 25) {
        $otherImageCount = [int](($allOsImages | Select-Object -Skip 25 | Measure-Object -Property count -Sum).Sum)
        $osImages += @{ name = "Other images ($($allOsImages.Count - 25) distinct)"; count = $otherImageCount }
    }

    return @{
        total              = $total
        up                 = $healthCounts.up
        warning            = $healthCounts.warning
        down               = $healthCounts.down + $healthCounts.critical
        critical           = $healthCounts.critical
        unknown            = $healthCounts.unknown
        activeAlerts       = $alertTotal
        pendingUpdates     = $updateTotal
        securityUpdates    = $securityUpdateTotal
        criticalUpdates    = $criticalUpdateTotal
        serversWithSecurityUpdates = $serversWithSecurityUpdates
        serversWithCriticalUpdates = $serversWithCriticalUpdates
        averageCpuPercent  = if ($cpuCount) { [Math]::Round($cpuSum / $cpuCount, 1) } else { $null }
        averageMemoryPercent = if ($memoryCount) { [Math]::Round($memorySum / $memoryCount, 1) } else { $null }
        totalCpuCores      = $coreTotal
        totalMemoryBytes   = $memoryTotal
        totalStorageBytes  = $storageTotal
        lifecycle          = $lifecycleCounts
        linuxLifecycle     = $linuxLifecycleCounts
        osImages           = $osImages
        osImageCount       = $allOsImages.Count
        platforms          = @($platformCounts.GetEnumerator() | ForEach-Object { @{ platformGroup = $_.Key; platform = $_.Value.platform; count = $_.Value.count } } | Sort-Object -Property count -Descending)
        deployment         = @($capabilities | ForEach-Object {
            @{ capability = $_; installed = $capabilityInstalled[$_]; applicable = $capabilityApplicable[$_] }
        })
        topCpu             = Get-TopServers -Servers $Servers -Property 'cpuPercent'
        topMemory          = Get-TopServers -Servers $Servers -Property 'memoryPercent'
        lowDisk            = Get-TopServers -Servers $Servers -Property 'diskFreePercent' -Ascending
        topAlerts          = Get-TopServers -Servers $Servers -Property 'activeAlerts'
        facets             = @{
            resourceGroups = @($resourceGroups | Sort-Object)
            locations      = @($locations | Sort-Object)
        }
    }
}

function Build-GeographySummary {
    <#
    Aggregates Arc servers and Arc-enabled Kubernetes clusters into country- and site-level
    rollups so the Global view renders from a small aggregate rather than raw inventories.
    Country and continent classification is entirely data-driven from Azure location metadata.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Servers,
        [AllowEmptyCollection()][array]$Clusters = @(),
        [Parameter(Mandatory)][array]$Locations
    )

    $virtualGroups = @('azure-vm', 'azure-local-vm', 'vmware', 'aws', 'hyper-v')
    $coordinateNumberStyles = [Globalization.NumberStyles]::Float
    $invariantCulture = [Globalization.CultureInfo]::InvariantCulture
    $locationMap = @{}
    foreach ($location in $Locations) {
        $key = ([string]$location.name).ToLowerInvariant()
        if ($key) { $locationMap[$key] = $location }
    }

    $countries = [ordered]@{}
    foreach ($server in $Servers) {
        $locationKey = ([string]$server.location).ToLowerInvariant()
        $location = $locationMap[$locationKey]
        $latitude = $null; $longitude = $null; $continent = 'other'
        if ($location) {
            $countryName = Resolve-CountryName -Geography $location.geography -GeographyGroup $location.geographyGroup `
                -PhysicalLocation $location.physicalLocation -DisplayName $location.displayName -Fallback $server.location
            $parsedLatitude = 0.0; $parsedLongitude = 0.0
            if ([double]::TryParse([string]$location.latitude, $coordinateNumberStyles, $invariantCulture, [ref]$parsedLatitude) -and
                [double]::TryParse([string]$location.longitude, $coordinateNumberStyles, $invariantCulture, [ref]$parsedLongitude)) {
                $latitude = $parsedLatitude
                $longitude = $parsedLongitude
                $continent = Resolve-ContinentName -Latitude $latitude -Longitude $longitude -GeographyGroup $location.geographyGroup
            }
        }
        else {
            $countryName = "Unclassified ($(if ($server.location) { $server.location } else { 'no region' }))"
        }
        if (-not $countryName) { $countryName = "Unclassified ($(if ($server.location) { $server.location } else { 'no region' }))" }

        if (-not $countries.Contains($countryName)) {
            $countries[$countryName] = [ordered]@{
                name = $countryName; continent = $continent; latitude = $latitude; longitude = $longitude
                coordinateCount = 0; latitudeTotal = 0.0; longitudeTotal = 0.0
                nodes = 0; servers = 0; clusters = 0; hosts = 0; vms = 0; connected = 0; alerts = 0
                sites = [ordered]@{}
            }
        }
        $country = $countries[$countryName]
        $country.nodes++
        $country.servers++
        $isVirtual = $virtualGroups -contains $server.platformGroup
        if ($isVirtual) { $country.vms++ } else { $country.hosts++ }
        if (([string]$server.arcStatus).ToLowerInvariant() -eq 'connected') { $country.connected++ }
        $country.alerts += [int]$server.activeAlerts
        if ($null -ne $latitude -and $null -ne $longitude) {
            $country.latitudeTotal += $latitude
            $country.longitudeTotal += $longitude
            $country.coordinateCount++
        }

        $siteName = if ($server.resourceGroup) { $server.resourceGroup } else { 'Unassigned' }
        $siteKey = "$siteName|$($server.location)"
        if (-not $country.sites.Contains($siteKey)) {
            $country.sites[$siteKey] = [ordered]@{
                country = $countryName; site = $siteName; region = $server.location
                nodes = 0; servers = 0; clusters = 0; hosts = 0; vms = 0; connected = 0; alerts = 0
            }
        }
        $site = $country.sites[$siteKey]
        $site.nodes++
        $site.servers++
        if ($isVirtual) { $site.vms++ } else { $site.hosts++ }
        if (([string]$server.arcStatus).ToLowerInvariant() -eq 'connected') { $site.connected++ }
        $site.alerts += [int]$server.activeAlerts
    }

    foreach ($cluster in $Clusters) {
        $locationKey = ([string]$cluster.location).ToLowerInvariant()
        $location = $locationMap[$locationKey]
        $latitude = $null; $longitude = $null; $continent = 'other'
        if ($location) {
            $countryName = Resolve-CountryName -Geography $location.geography -GeographyGroup $location.geographyGroup `
                -PhysicalLocation $location.physicalLocation -DisplayName $location.displayName -Fallback $cluster.location
            $parsedLatitude = 0.0; $parsedLongitude = 0.0
            if ([double]::TryParse([string]$location.latitude, $coordinateNumberStyles, $invariantCulture, [ref]$parsedLatitude) -and
                [double]::TryParse([string]$location.longitude, $coordinateNumberStyles, $invariantCulture, [ref]$parsedLongitude)) {
                $latitude = $parsedLatitude
                $longitude = $parsedLongitude
                $continent = Resolve-ContinentName -Latitude $latitude -Longitude $longitude -GeographyGroup $location.geographyGroup
            }
        }
        else {
            $countryName = "Unclassified ($(if ($cluster.location) { $cluster.location } else { 'no region' }))"
        }
        if (-not $countryName) { $countryName = "Unclassified ($(if ($cluster.location) { $cluster.location } else { 'no region' }))" }

        if (-not $countries.Contains($countryName)) {
            $countries[$countryName] = [ordered]@{
                name = $countryName; continent = $continent; latitude = $latitude; longitude = $longitude
                coordinateCount = 0; latitudeTotal = 0.0; longitudeTotal = 0.0
                nodes = 0; servers = 0; clusters = 0; hosts = 0; vms = 0; connected = 0; alerts = 0
                sites = [ordered]@{}
            }
        }
        $country = $countries[$countryName]
        $country.nodes++
        $country.clusters++
        if (([string]$cluster.connectivityStatus).ToLowerInvariant() -eq 'connected') { $country.connected++ }
        if ($null -ne $latitude -and $null -ne $longitude) {
            $country.latitudeTotal += $latitude
            $country.longitudeTotal += $longitude
            $country.coordinateCount++
        }

        $siteName = if ($cluster.resourceGroup) { $cluster.resourceGroup } else { 'Unassigned' }
        $siteKey = "$siteName|$($cluster.location)"
        if (-not $country.sites.Contains($siteKey)) {
            $country.sites[$siteKey] = [ordered]@{
                country = $countryName; site = $siteName; region = $cluster.location
                nodes = 0; servers = 0; clusters = 0; hosts = 0; vms = 0; connected = 0; alerts = 0
            }
        }
        $site = $country.sites[$siteKey]
        $site.nodes++
        $site.clusters++
        if (([string]$cluster.connectivityStatus).ToLowerInvariant() -eq 'connected') { $site.connected++ }
    }

    $countryList = foreach ($country in $countries.Values) {
        [pscustomobject][ordered]@{
            name       = $country.name
            continent  = $country.continent
            latitude   = if ($country.coordinateCount) { $country.latitudeTotal / $country.coordinateCount } else { $null }
            longitude  = if ($country.coordinateCount) { $country.longitudeTotal / $country.coordinateCount } else { $null }
            nodes      = $country.nodes
            servers    = $country.servers
            clusters   = $country.clusters
            hosts      = $country.hosts
            vms        = $country.vms
            connected  = $country.connected
            alerts     = $country.alerts
            sites      = @($country.sites.Values)
        }
    }

    return @{
        countries = @($countryList | Sort-Object -Property nodes -Descending)
        totals    = @{
            countries = $countries.Count
            nodes     = $Servers.Count + $Clusters.Count
            servers   = $Servers.Count
            clusters  = $Clusters.Count
            hosts     = [int]($countryList | Measure-Object -Property hosts -Sum).Sum
            vms       = [int]($countryList | Measure-Object -Property vms -Sum).Sum
            alerts    = [int]($countryList | Measure-Object -Property alerts -Sum).Sum
        }
    }
}

function Merge-GeographySummaries {
    param(
        [Parameter(Mandatory)][object]$ServerGeography,
        [Parameter(Mandatory)][object]$KubernetesGeography
    )

    $countries = [ordered]@{}
    foreach ($sourceCountry in @($ServerGeography.countries) + @($KubernetesGeography.countries)) {
        $countryName = [string]$sourceCountry.name
        if (-not $countries.Contains($countryName)) {
            $countries[$countryName] = [ordered]@{
                name = $countryName; continent = $sourceCountry.continent
                latitudeTotal = 0.0; longitudeTotal = 0.0; coordinateCount = 0
                nodes = 0; servers = 0; clusters = 0; hosts = 0; vms = 0; connected = 0; alerts = 0
                sites = [ordered]@{}
            }
        }
        $country = $countries[$countryName]
        $weight = [int]$sourceCountry.nodes
        if ($null -ne $sourceCountry.latitude -and $null -ne $sourceCountry.longitude -and $weight -gt 0) {
            $country.latitudeTotal += [double]$sourceCountry.latitude * $weight
            $country.longitudeTotal += [double]$sourceCountry.longitude * $weight
            $country.coordinateCount += $weight
        }
        foreach ($property in @('nodes', 'servers', 'clusters', 'hosts', 'vms', 'connected', 'alerts')) {
            $country[$property] += [int]$sourceCountry.$property
        }
        foreach ($sourceSite in @($sourceCountry.sites)) {
            $siteKey = "$($sourceSite.site)|$($sourceSite.region)"
            if (-not $country.sites.Contains($siteKey)) {
                $country.sites[$siteKey] = [ordered]@{
                    country = $countryName; site = $sourceSite.site; region = $sourceSite.region
                    nodes = 0; servers = 0; clusters = 0; hosts = 0; vms = 0; connected = 0; alerts = 0
                }
            }
            $site = $country.sites[$siteKey]
            foreach ($property in @('nodes', 'servers', 'clusters', 'hosts', 'vms', 'connected', 'alerts')) {
                $site[$property] += [int]$sourceSite.$property
            }
        }
    }

    $countryList = foreach ($country in $countries.Values) {
        [pscustomobject][ordered]@{
            name = $country.name; continent = $country.continent
            latitude = if ($country.coordinateCount) { $country.latitudeTotal / $country.coordinateCount } else { $null }
            longitude = if ($country.coordinateCount) { $country.longitudeTotal / $country.coordinateCount } else { $null }
            nodes = $country.nodes; servers = $country.servers; clusters = $country.clusters
            hosts = $country.hosts; vms = $country.vms; connected = $country.connected; alerts = $country.alerts
            sites = @($country.sites.Values)
        }
    }
    return @{
        countries = @($countryList | Sort-Object -Property nodes -Descending)
        totals = @{
            countries = $countries.Count
            nodes = [int]$ServerGeography.totals.nodes + [int]$KubernetesGeography.totals.nodes
            servers = [int]$ServerGeography.totals.servers
            clusters = [int]$KubernetesGeography.totals.clusters
            hosts = [int]$ServerGeography.totals.hosts
            vms = [int]$ServerGeography.totals.vms
            alerts = [int]$ServerGeography.totals.alerts
        }
    }
}
# endregion Summary and geography aggregation

# region Paginated, filtered, sorted server queries
$script:ServerSortKeys = @(
    'name', 'health', 'osType', 'cpuPercent', 'memoryPercent', 'diskFreePercent', 'diskIops', 'diskBytesPerSec', 'networkBytesPerSec',
    'activeAlerts', 'pendingUpdates', 'lastHeartbeat', 'resourceGroup', 'location', 'platform', 'osSku',
    'infraManufacturer', 'infraModel', 'hypervisorType', 'arcStatus', 'agentVersion',
    'azureMonitorAgent', 'dependencyAgent', 'changeTracking', 'guestConfiguration', 'defenderForServers',
    'updateManager', 'customScript', 'sqlServer', 'adminCenter'
)
$script:HealthRank = @{ critical = 0; down = 1; warning = 2; unknown = 3; up = 4 }
# lastHeartbeat and the telemetry percentages can be genuinely absent (no monitoring data yet);
# every other sort key always has a value, so only these need the null-goes-last partitioning.
$script:NullableNumericSortKeys = @('cpuPercent', 'memoryPercent', 'diskFreePercent', 'diskIops', 'diskBytesPerSec', 'networkBytesPerSec', 'lastHeartbeat')
$script:AlwaysNumericSortKeys = @(
    'health', 'activeAlerts', 'pendingUpdates', 'azureMonitorAgent', 'dependencyAgent', 'changeTracking',
    'guestConfiguration', 'defenderForServers', 'updateManager', 'customScript', 'sqlServer', 'adminCenter'
)

function Get-ServerSortValue {
    <#
    Single-item sort-value extraction, used for detail/debugging purposes. Select-OrderedServerList uses
    its own specialized, per-call-compiled key selectors instead of calling this per comparison,
    because invoking a generic switch-based function for every one of the O(n log n) comparisons
    in a 50,000-row sort is measurably slow (multiple seconds); calling it at most once per row
    up front, then letting .NET's native LINQ/Array sort do the O(n log n) comparisons, is not.
    #>
    param($Server, [Parameter(Mandatory)][string]$Key)

    switch ($Key) {
        'health' { return $script:HealthRank[[string]$Server.health] }
        'lastHeartbeat' {
            if ($Server.lastHeartbeat) { return ([datetime]$Server.lastHeartbeat).Ticks }
            return $null
        }
        { $_ -in @('cpuPercent', 'memoryPercent', 'diskFreePercent', 'diskIops', 'diskBytesPerSec', 'networkBytesPerSec', 'activeAlerts', 'pendingUpdates') } {
            return $Server.$Key
        }
        { $_ -in @('azureMonitorAgent', 'dependencyAgent', 'changeTracking', 'guestConfiguration', 'defenderForServers', 'updateManager', 'customScript', 'sqlServer', 'adminCenter') } {
            if ($Server.$Key) { return 1 }
            return 0
        }
        default { return ([string]$Server.$Key).ToLowerInvariant() }
    }
}

function Select-OrderedServerList {
    <#
    .SYNOPSIS
    Sorts the (already filtered) server list ascending or descending by a whitelisted key, with
    a name tie-break, at 50,000-row scale in well under a second.

    .DESCRIPTION
    Every sort key is resolved to a small, self-contained key-selector scriptblock compiled once
    per call (not once per comparison) and executed through native .NET LINQ ordering, so the
    O(n log n) comparison work happens entirely in .NET rather than repeatedly re-entering the
    PowerShell interpreter. $Sort is validated against a fixed whitelist by the caller before
    this function ever embeds it into generated script text, so only known-safe literal property
    names are ever used -- never arbitrary request input.
    #>
    param(
        [Parameter(Mandatory)][Collections.Generic.List[object]]$Servers,
        [Parameter(Mandatory)][string]$Sort,
        [Parameter(Mandatory)][ValidateSet('ascending', 'descending')][string]$Direction
    )

    $ascending = $Direction -eq 'ascending'
    $nameSelector = [Func[object, string]]{ param($s) ([string]$s.name).ToLowerInvariant() }

    if ($script:NullableNumericSortKeys -contains $Sort) {
        $hasValueSelector = [Func[object, bool]][scriptblock]::Create("param(`$s) `$null -ne `$s.$Sort")
        $noValueSelector = [Func[object, bool]][scriptblock]::Create("param(`$s) `$null -eq `$s.$Sort")
        $keySelector = [Func[object, object]][scriptblock]::Create("param(`$s) `$s.$Sort")

        $withValue = [Linq.Enumerable]::Where($Servers, $hasValueSelector)
        $withoutValue = [Linq.Enumerable]::Where($Servers, $noValueSelector)
        $ordered = [Linq.Enumerable]::OrderBy($withValue, $keySelector)
        $ordered = [Linq.Enumerable]::ThenBy($ordered, $nameSelector, [StringComparer]::OrdinalIgnoreCase)
        if (-not $ascending) { $ordered = [Linq.Enumerable]::Reverse($ordered) }
        # Null values always sort last, independent of ascending/descending, matching the
        # dashboard's established "unavailable telemetry sorts to the bottom" convention.
        $resultArray = [Linq.Enumerable]::ToArray([Linq.Enumerable]::Concat($ordered, $withoutValue))
    }
    elseif ($script:AlwaysNumericSortKeys -contains $Sort) {
        $keyText = switch ($Sort) {
            'health' { 'param($s) switch ([string]$s.health) { "critical" { 0.0 } "down" { 1.0 } "warning" { 2.0 } "unknown" { 3.0 } "up" { 4.0 } default { 3.0 } }' }
            { $_ -in @('activeAlerts', 'pendingUpdates') } { "param(`$s) [double]`$s.$Sort" }
            default { "param(`$s) if (`$s.$Sort) { 1.0 } else { 0.0 }" }
        }
        $keySelector = [Func[object, double]][scriptblock]::Create($keyText)
        $ordered = [Linq.Enumerable]::OrderBy($Servers, $keySelector)
        $ordered = [Linq.Enumerable]::ThenBy($ordered, $nameSelector, [StringComparer]::OrdinalIgnoreCase)
        if (-not $ascending) { $ordered = [Linq.Enumerable]::Reverse($ordered) }
        $resultArray = [Linq.Enumerable]::ToArray($ordered)
    }
    else {
        $keySelector = [Func[object, string]][scriptblock]::Create("param(`$s) ([string]`$s.$Sort).ToLowerInvariant()")
        $ordered = [Linq.Enumerable]::OrderBy($Servers, $keySelector, [StringComparer]::OrdinalIgnoreCase)
        $ordered = [Linq.Enumerable]::ThenBy($ordered, $nameSelector, [StringComparer]::OrdinalIgnoreCase)
        if (-not $ascending) { $ordered = [Linq.Enumerable]::Reverse($ordered) }
        $resultArray = [Linq.Enumerable]::ToArray($ordered)
    }

    return , [Collections.Generic.List[object]]::new($resultArray)
}


function Select-ServerPage {
    <#
    .SYNOPSIS
    Applies whitelisted filters and sort to the immutable per-generation server array, then
    returns one bounded page using an opaque, generation- and query-bound cursor.

    .DESCRIPTION
    All filtering and sorting happens entirely in memory against already-fetched snapshot
    data -- no request input is ever interpolated into a KQL query, and every sort key,
    direction, and enum filter value is validated against a fixed whitelist before use.
    #>
    param(
        [Parameter(Mandatory)][array]$Servers,
        [Parameter(Mandatory)][string]$GenerationId,
        [string]$Sort = 'name',
        [string]$Direction = 'ascending',
        [string]$Search = '',
        [string]$ResourceGroup = '',
        [string]$Location = '',
        [string]$Health = '',
        [string]$ArcStatus = '',
        [string]$PlatformGroup = '',
        [string]$OsType = '',
        [string]$LifecycleState = '',
        [string]$Cursor = '',
        [int]$PageSize = 100
    )

    if ($Sort -notin $script:ServerSortKeys) {
        throw [ArgumentException]::new("Unsupported sort key '$Sort'.")
    }
    if ($Direction -notin @('ascending', 'descending')) {
        throw [ArgumentException]::new("Unsupported sort direction '$Direction'.")
    }
    if ($Health -and $Health -notin @('critical', 'down', 'warning', 'up', 'unknown')) {
        throw [ArgumentException]::new("Unsupported health filter '$Health'.")
    }
    if ($ArcStatus -and $ArcStatus -notin @('Connected', 'Disconnected')) {
        throw [ArgumentException]::new("Unsupported Arc status filter '$ArcStatus'.")
    }
    if ($OsType -and $OsType -notin @('windows', 'linux')) {
        throw [ArgumentException]::new("Unsupported osType filter '$OsType'.")
    }
    if ($LifecycleState -and $LifecycleState -notin @('unsupported', 'esu-ending', 'approaching-eol', 'supported', 'unknown', 'not-applicable', 'at-risk')) {
        throw [ArgumentException]::new("Unsupported lifecycle filter '$LifecycleState'.")
    }
    $PageSize = [Math]::Max(1, [Math]::Min(250, $PageSize))

    $searchLower = $Search.Trim().ToLowerInvariant()
    $filtered = [Collections.Generic.List[object]]::new()
    foreach ($server in $Servers) {
        if ($searchLower -and -not ([string]$server.name).ToLowerInvariant().Contains($searchLower)) { continue }
        if ($ResourceGroup -and [string]$server.resourceGroup -ne $ResourceGroup) { continue }
        if ($Location -and [string]$server.location -ne $Location) { continue }
        if ($Health -and [string]$server.health -ne $Health) { continue }
        if ($ArcStatus -and [string]$server.arcStatus -ne $ArcStatus) { continue }
        if ($PlatformGroup -and [string]$server.platformGroup -ne $PlatformGroup) { continue }
        if ($OsType -and [string]$server.osType -ne $OsType) { continue }
        if ($LifecycleState) {
            if ($LifecycleState -eq 'at-risk') {
                if ([string]$server.lifecycleState -notin @('unsupported', 'esu-ending', 'approaching-eol', 'unknown')) { continue }
            }
            elseif ([string]$server.lifecycleState -ne $LifecycleState) { continue }
        }
        $filtered.Add($server)
    }

    $sorted = Select-OrderedServerList -Servers $filtered -Sort $Sort -Direction $Direction

    $signature = Get-QuerySignature -Parameters @{
        sort = $Sort; dir = $Direction; search = $searchLower; rg = $ResourceGroup; loc = $Location
        health = $Health; arcStatus = $ArcStatus; platform = $PlatformGroup; os = $OsType; lifecycle = $LifecycleState; size = $PageSize
    }
    $cursorResult = Resolve-OpaqueCursor -Cursor $Cursor -GenerationId $GenerationId -Signature $signature
    if (-not $cursorResult.Valid) {
        return @{ Error = $cursorResult.Reason }
    }

    $offset = $cursorResult.Offset
    $total = $sorted.Count
    if ($offset -gt $total) { $offset = $total }
    $endExclusive = [Math]::Min($total, $offset + $PageSize)
    $pageItems = if ($offset -lt $endExclusive) { $sorted.GetRange($offset, $endExclusive - $offset) } else { [Collections.Generic.List[object]]::new() }
    $returned = $pageItems.Count
    $hasNext = ($offset + $returned) -lt $total
    $hasPrevious = $offset -gt 0

    return @{
        Error          = $null
        Items          = @($pageItems)
        Total          = $total
        Offset         = $offset
        Returned       = $returned
        PageSize       = $PageSize
        HasNext        = $hasNext
        HasPrevious    = $hasPrevious
        NextCursor     = if ($hasNext) { New-OpaqueCursor -GenerationId $GenerationId -Signature $signature -Offset ($offset + $PageSize) } else { $null }
        PreviousCursor = if ($hasPrevious) { New-OpaqueCursor -GenerationId $GenerationId -Signature $signature -Offset ([Math]::Max(0, $offset - $PageSize)) } else { $null }
    }
}

function ConvertTo-ServerListRow {
    <#
    List rows omit the verbose per-extension detail array (available on demand from the
    detail endpoint) to keep each bounded page response small regardless of fleet size.
    #>
    param($Server)

    $clone = $Server | Select-Object -Property * -ExcludeProperty extensions
    return $clone
}
# endregion Paginated, filtered, sorted server queries

# region Single-server Azure VM SKU assessment
function ConvertTo-NullableInvariantDouble {
    param($Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return $null }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function ConvertTo-AzureVmSkuCandidate {
    param(
        [Parameter(Mandatory)]$Sku,
        [Parameter(Mandatory)][string]$Location
    )

    foreach ($restriction in @($Sku.restrictions)) {
        if ([string]$restriction.type -eq 'Location' -and
            @($restriction.values | ForEach-Object { ([string]$_).ToLowerInvariant() }) -contains $Location.ToLowerInvariant()) {
            return $null
        }
    }

    $capabilities = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($capability in @($Sku.capabilities)) {
        $name = [string]$capability.name
        if ($name) { $capabilities[$name] = [string]$capability.value }
    }
    $getCapability = {
        param([string]$Name)
        if ($capabilities.ContainsKey($Name)) { return $capabilities[$Name] }
        return $null
    }

    $vCpus = ConvertTo-NullableInvariantDouble (& $getCapability 'vCPUs')
    $availableVCpus = ConvertTo-NullableInvariantDouble (& $getCapability 'vCPUsAvailable')
    if ($null -eq $vCpus) { $vCpus = $availableVCpus }
    $memoryGb = ConvertTo-NullableInvariantDouble (& $getCapability 'MemoryGB')
    if ($null -eq $vCpus -or $null -eq $memoryGb -or $vCpus -le 0 -or $memoryGb -le 0) { return $null }
    if ($null -ne $availableVCpus -and $availableVCpus -lt $vCpus) { return $null }

    $gpuCount = ConvertTo-NullableInvariantDouble (& $getCapability 'GPUs')
    $architecture = [string](& $getCapability 'CpuArchitectureType')
    if (($null -ne $gpuCount -and $gpuCount -gt 0) -or $architecture -match '(?i)arm' -or
        [string]$Sku.name -match '(?i)^Standard_(N|H[BCR]?|FX|EC|DC)') {
        return $null
    }

    $maxDataDisks = ConvertTo-NullableInvariantDouble (& $getCapability 'MaxDataDiskCount')
    $networkMbps = ConvertTo-NullableInvariantDouble (& $getCapability 'MaxNetworkBandwidthMbps')
    if ($null -eq $networkMbps) { $networkMbps = ConvertTo-NullableInvariantDouble (& $getCapability 'ExpectedNetworkBandwidth') }

    return [pscustomobject][ordered]@{
        name                   = [string]$Sku.name
        family                 = [string]$Sku.family
        vCpus                  = [int][Math]::Ceiling($vCpus)
        memoryGb               = [Math]::Round($memoryGb, 2)
        maxDataDisks           = if ($null -ne $maxDataDisks) { [int]$maxDataDisks } else { $null }
        maxNetworkMbps         = if ($null -ne $networkMbps) { [Math]::Round($networkMbps, 0) } else { $null }
        premiumIo              = ([string](& $getCapability 'PremiumIO')).ToLowerInvariant() -eq 'true'
        acceleratedNetworking  = ([string](& $getCapability 'AcceleratedNetworkingEnabled')).ToLowerInvariant() -eq 'true'
        architecture           = if ($architecture) { $architecture } else { 'Unknown' }
    }
}

function Get-AzureVmSkuCandidates {
    param(
        [Parameter(Mandatory)][hashtable]$SharedState,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location
    )

    $cacheKey = "$($SubscriptionId.ToLowerInvariant())|$($Location.ToLowerInvariant())"
    $cached = $SharedState.VmSkuCache[$cacheKey]
    if ($cached -and ([datetime]$cached.expiresAt) -gt (Get-Date).ToUniversalTime()) {
        return @($cached.skus)
    }

    $SharedState.VmSkuGate.Wait()
    try {
        $cached = $SharedState.VmSkuCache[$cacheKey]
        if ($cached -and ([datetime]$cached.expiresAt) -gt (Get-Date).ToUniversalTime()) {
            return @($cached.skus)
        }

        Set-AzSubscriptionContext -SubscriptionId $SubscriptionId
        $rawSkus = @(Invoke-AzJson @(
            'vm', 'list-skus',
            '--subscription', $SubscriptionId,
            '--location', $Location,
            '--resource-type', 'virtualMachines',
            '--all',
            '--query', '[].{name:name,family:family,restrictions:restrictions[].{type:type,values:values,reasonCode:reasonCode},capabilities:capabilities[].{name:name,value:value}}',
            '--output', 'json',
            '--only-show-errors'
        ))
        $candidates = @($rawSkus | ForEach-Object {
            ConvertTo-AzureVmSkuCandidate -Sku $_ -Location $Location
        } | Where-Object { $null -ne $_ })
        $SharedState.VmSkuCache[$cacheKey] = [pscustomobject]@{
            expiresAt = (Get-Date).ToUniversalTime().AddHours(24)
            skus      = $candidates
        }
        return $candidates
    }
    finally {
        [void]$SharedState.VmSkuGate.Release()
    }
}

function Get-VmSkuAssessment {
    param(
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Skus,
        [Parameter(Mandatory)][string]$TargetLocation,
        [ValidateRange(10, 100)][int]$HeadroomPercent = 35
    )

    $bytesPerGb = 1GB
    $sourceCores = if ($Server.logicalCpuCores -and [double]$Server.logicalCpuCores -gt 0) {
        [double]$Server.logicalCpuCores
    }
    elseif ($Server.cpuCores -and [double]$Server.cpuCores -gt 0) {
        [double]$Server.cpuCores
    }
    else { $null }
    $sourceMemoryGb = if ($Server.totalMemoryBytes -and [double]$Server.totalMemoryBytes -gt 0) {
        [double]$Server.totalMemoryBytes / $bytesPerGb
    }
    else { $null }
    $sourceStorageGb = if ($Server.totalStorageBytes -and [double]$Server.totalStorageBytes -gt 0) {
        [double]$Server.totalStorageBytes / $bytesPerGb
    }
    else { $null }

    $cpuPercent = ConvertTo-NullableInvariantDouble $Server.cpuPercent
    $memoryPercent = ConvertTo-NullableInvariantDouble $Server.memoryPercent
    $diskFreePercent = ConvertTo-NullableInvariantDouble $Server.diskFreePercent
    $networkBytesPerSec = ConvertTo-NullableInvariantDouble $Server.networkBytesPerSec

    $observedCpuCores = if ($null -ne $sourceCores -and $null -ne $cpuPercent) {
        [Math]::Max(0.25, $sourceCores * [Math]::Max(0, [Math]::Min(100, $cpuPercent)) / 100.0)
    }
    elseif ($null -ne $sourceCores) { $sourceCores }
    else { 2.0 }
    $observedMemoryGb = if ($null -ne $sourceMemoryGb -and $null -ne $memoryPercent) {
        [Math]::Max(1.0, $sourceMemoryGb * [Math]::Max(0, [Math]::Min(100, $memoryPercent)) / 100.0)
    }
    elseif ($null -ne $sourceMemoryGb) { $sourceMemoryGb }
    else { 4.0 }
    $observedStorageGb = if ($null -ne $sourceStorageGb -and $null -ne $diskFreePercent) {
        [Math]::Max(1.0, $sourceStorageGb * (1.0 - [Math]::Max(0, [Math]::Min(100, $diskFreePercent)) / 100.0))
    }
    elseif ($null -ne $sourceStorageGb) { $sourceStorageGb }
    else { $null }
    $observedNetworkMbps = if ($null -ne $networkBytesPerSec) {
        [Math]::Max(0, $networkBytesPerSec * 8.0 / 1000000.0)
    }
    else { $null }
    $diskCount = if ($Server.storageDiskCount) { [int]$Server.storageDiskCount } else { 0 }

    $missingTelemetry = [Collections.Generic.List[string]]::new()
    if ($null -eq $cpuPercent) { $missingTelemetry.Add('CPU utilization') }
    if ($null -eq $memoryPercent) { $missingTelemetry.Add('Memory utilization') }
    if ($null -eq $diskFreePercent -or $null -eq $sourceStorageGb) { $missingTelemetry.Add('Storage utilization or capacity') }
    if ($null -eq $networkBytesPerSec) { $missingTelemetry.Add('Network throughput') }
    if ($null -eq $sourceCores) { $missingTelemetry.Add('Detected CPU core count') }
    if ($null -eq $sourceMemoryGb) { $missingTelemetry.Add('Detected physical memory') }

    $heartbeatRecent = $false
    if ($Server.lastHeartbeat) {
        $parsedHeartbeat = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Server.lastHeartbeat, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsedHeartbeat)) {
            $heartbeatRecent = $parsedHeartbeat.ToUniversalTime() -gt (Get-Date).ToUniversalTime().AddHours(-2)
        }
    }
    $confidence = if ($missingTelemetry.Count -eq 0 -and $heartbeatRecent) {
        'high'
    }
    elseif ($null -ne $sourceCores -and $null -ne $sourceMemoryGb -and $null -ne $cpuPercent -and $null -ne $memoryPercent) {
        'medium'
    }
    else { 'low' }

    $profiles = @(
        @{ key = 'cost'; label = 'Cost optimized'; factor = 1.20; purpose = 'Smallest observed-demand fit with 20% operating headroom.' },
        @{ key = 'balanced'; label = 'Balanced'; factor = 1.0 + ($HeadroomPercent / 100.0); purpose = "Observed-demand fit with the selected $HeadroomPercent% production headroom." },
        @{ key = 'performance'; label = 'Performance buffered'; factor = 1.0 + ([Math]::Max(75, $HeadroomPercent + 35) / 100.0); purpose = 'Larger fit for growth, peaks, and incomplete short-window telemetry.' }
    )

    $recommendations = foreach ($profile in $profiles) {
        $requiredCores = [Math]::Max(1, [Math]::Ceiling($observedCpuCores * $profile.factor))
        $requiredMemoryGb = [Math]::Max(1, [Math]::Ceiling($observedMemoryGb * $profile.factor))
        $requiredNetworkMbps = if ($null -ne $observedNetworkMbps) { $observedNetworkMbps * $profile.factor } else { $null }
        $eligible = @($Skus | Where-Object {
            $burstableSuitable = [string]$_.name -notmatch '(?i)^Standard_B' -or ($confidence -eq 'high' -and $cpuPercent -lt 20)
            $_.vCpus -ge $requiredCores -and $_.memoryGb -ge $requiredMemoryGb -and
            $burstableSuitable -and
            ($diskCount -eq 0 -or $null -eq $_.maxDataDisks -or $_.maxDataDisks -ge $diskCount) -and
            ($null -eq $requiredNetworkMbps -or $null -eq $_.maxNetworkMbps -or $_.maxNetworkMbps -ge $requiredNetworkMbps)
        } | Sort-Object -Property @(
            @{ Expression = { ([double]$_.vCpus / $requiredCores) + ([double]$_.memoryGb / $requiredMemoryGb) }; Ascending = $true },
            @{ Expression = { [double]$_.vCpus + ([double]$_.memoryGb / 4.0) }; Ascending = $true },
            @{ Expression = { [string]$_.name }; Ascending = $true }
        ))
        $selected = $eligible | Select-Object -First 1
        if (-not $selected) {
            [pscustomobject][ordered]@{
                profile = $profile.key; label = $profile.label; purpose = $profile.purpose
                requiredVCpus = [int]$requiredCores; requiredMemoryGb = [int]$requiredMemoryGb
                sku = $null; message = 'No discovered SKU satisfies the calculated requirements in this region.'
            }
            continue
        }
        [pscustomobject][ordered]@{
            profile = $profile.key
            label = $profile.label
            purpose = $profile.purpose
            requiredVCpus = [int]$requiredCores
            requiredMemoryGb = [int]$requiredMemoryGb
            sku = $selected
            cpuCapacityMargin = [Math]::Round(100.0 * ($selected.vCpus - $requiredCores) / $requiredCores, 0)
            memoryCapacityMargin = [Math]::Round(100.0 * ($selected.memoryGb - $requiredMemoryGb) / $requiredMemoryGb, 0)
            message = $null
        }
    }

    $storageRequirementGb = if ($null -ne $observedStorageGb) {
        [Math]::Ceiling($observedStorageGb * (1.0 + $HeadroomPercent / 100.0))
    }
    else { $null }

    return [pscustomobject][ordered]@{
        server = @{
            name = $Server.name; osType = $Server.osType; sourceCores = $sourceCores
            sourceMemoryGb = if ($null -ne $sourceMemoryGb) { [Math]::Round($sourceMemoryGb, 1) } else { $null }
            sourceStorageGb = if ($null -ne $sourceStorageGb) { [Math]::Round($sourceStorageGb, 1) } else { $null }
        }
        targetLocation = $TargetLocation
        headroomPercent = $HeadroomPercent
        confidence = $confidence
        observationWindow = 'Average utilization over the latest 30-minute telemetry window'
        observed = @{
            cpuPercent = $cpuPercent
            cpuCores = [Math]::Round($observedCpuCores, 2)
            memoryPercent = $memoryPercent
            memoryGb = [Math]::Round($observedMemoryGb, 2)
            diskFreePercent = $diskFreePercent
            storageUsedGb = if ($null -ne $observedStorageGb) { [Math]::Round($observedStorageGb, 1) } else { $null }
            networkMbps = if ($null -ne $observedNetworkMbps) { [Math]::Round($observedNetworkMbps, 2) } else { $null }
            diskCount = $diskCount
        }
        storagePlanning = @{
            requiredCapacityGb = $storageRequirementGb
            note = 'Managed disk capacity, performance tier, IOPS, and throughput must be sized separately from the VM SKU.'
        }
        missingTelemetry = @($missingTelemetry)
        assumptions = @(
            'This is a preliminary recommendation based on a short observation window, not a migration-grade assessment.',
            'Average utilization may hide peak, seasonal, NUMA-sensitive, GPU, licensing, or application-specific requirements.',
            'Burstable B-series is considered only when current telemetry is complete and CPU utilization is below 20%.',
            'The Arc resource location is used only as the default target; choose the intended Azure deployment region.',
            'Relative fit is based on compute capacity, not live Azure pricing, reservations, savings plans, or licensing benefits.'
        )
        recommendations = @($recommendations)
        skuCountEvaluated = $Skus.Count
        documentationUrl = 'https://learn.microsoft.com/azure/virtual-machines/sizes/overview'
    }
}
# endregion Single-server Azure VM SKU assessment

# region SQL snapshot builder
function Build-SqlSnapshot {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string[]]$ResourceGroups
    )

    $account = Get-TargetAccountInfo -SubscriptionId $SubscriptionId
    $resourceGroupFilter = Get-ResourceGroupKqlFilter -ResourceGroups $ResourceGroups

    $instancesQuery = @"
Resources
| where type =~ 'microsoft.azurearcdata/sqlserverinstances'
$resourceGroupFilter
| extend containerResourceId=tostring(properties.containerResourceId)
| project id=tolower(id), name, instanceName=tostring(properties.instanceName),
          hostName=extract(@'(?i)/machines/([^/]+)$', 1, containerResourceId),
          containerResourceId=tolower(containerResourceId), resourceGroup, location,
          status=tostring(properties.status), provisioningState=tostring(properties.provisioningState),
          serviceType=tostring(properties.serviceType), version=tostring(properties.version),
          edition=tostring(properties.edition), currentVersion=tostring(properties.currentVersion),
          patchLevel=tostring(properties.patchLevel), licenseType=tostring(properties.licenseType),
          cores=toint(properties.cores), vCores=toint(properties.vCore),
          defenderStatus=tostring(properties.azureDefenderStatus),
          monitoringEnabled=tobool(properties.monitoring.enabled),
          migrationAssessmentEnabled=tobool(properties.migration.assessment.enabled),
          migrationMiStatus=tostring(properties.migration.assessment.skuRecommendationResults.azureSqlManagedInstance.recommendationStatus),
          migrationVmStatus=tostring(properties.migration.assessment.skuRecommendationResults.azureSqlVirtualMachine.recommendationStatus),
          migrationMiMonthlyCost=todouble(properties.migration.assessment.skuRecommendationResults.azureSqlManagedInstance.monthlyCost.totalCost),
          migrationVmMonthlyCost=todouble(properties.migration.assessment.skuRecommendationResults.azureSqlVirtualMachine.monthlyCost.totalCost),
          migrationTargetLocation=tostring(properties.migration.assessment.settings.targetLocation),
          hadrEnabled=tobool(properties.isHadrEnabled),
          lastInventoryUpload=tostring(properties.lastInventoryUploadTime),
          lastUsageUpload=tostring(properties.lastUsageUploadTime)
| order by name asc
"@

    $databasesQuery = @"
Resources
| where type =~ 'microsoft.azurearcdata/sqlserverinstances/databases'
$resourceGroupFilter
| extend normalizedId=tolower(id)
| project id=normalizedId, name,
          instanceId=substring(normalizedId, 0, indexof(normalizedId, '/databases/')),
          resourceGroup, state=tostring(properties.state),
          recoveryMode=tostring(properties.recoveryMode),
          compatibilityLevel=toint(properties.compatibilityLevel),
          sizeMB=todouble(properties.sizeMB),
          dataFileSizeMB=todouble(properties.dataFileSizeMB),
          logFileSizeMB=todouble(properties.logFileSizeMB),
          spaceAvailableMB=todouble(properties.spaceAvailableMB),
          isReadOnly=tobool(properties.isReadOnly),
          lastUpload=tostring(properties.lastDatabaseUploadTime),
          lastFullBackup=tostring(properties.backupInformation.lastFullBackup),
          lastLogBackup=tostring(properties.backupInformation.lastLogBackup)
| order by name asc
"@

    $patchQuery = @"
PatchAssessmentResources
| where type =~ 'microsoft.hybridcompute/machines/patchassessmentresults'
$resourceGroupFilter
| extend normalizedId=tolower(id)
| extend hostId=substring(normalizedId, 0, indexof(normalizedId, '/patchassessmentresults/'))
| extend critical=coalesce(toint(properties.availablePatchCountByClassification.critical), 0),
         security=coalesce(toint(properties.availablePatchCountByClassification.security), 0),
         updates=coalesce(toint(properties.availablePatchCountByClassification.updates), 0),
         rollups=coalesce(toint(properties.availablePatchCountByClassification.updateRollup), 0),
         features=coalesce(toint(properties.availablePatchCountByClassification.featurePack), 0),
         services=coalesce(toint(properties.availablePatchCountByClassification.servicePack), 0),
         definitions=coalesce(toint(properties.availablePatchCountByClassification.definition), 0),
         tools=coalesce(toint(properties.availablePatchCountByClassification.tools), 0),
         other=coalesce(toint(properties.availablePatchCountByClassification.other), 0)
| extend pendingUpdates=critical + security + updates + rollups + features + services + definitions + tools + other
| project hostId, pendingUpdates, criticalUpdates=critical, securityUpdates=security,
          rebootPending=tobool(properties.rebootPending),
          lastAssessment=tostring(properties.lastModifiedDateTime)
"@

    $recommendationsQuery = @"
SecurityResources
| where type =~ 'microsoft.security/assessments'
$resourceGroupFilter
| extend targetId=tolower(tostring(properties.resourceDetails.Id)),
         status=tostring(properties.status.code),
         severity=tostring(properties.metadata.severity)
| where status =~ 'Unhealthy' and severity in~ ('High', 'Medium')
| where targetId contains '/providers/microsoft.hybridcompute/machines/'
| project targetId, severity, recommendation=tostring(properties.displayName),
          description=tostring(properties.metadata.description), assessmentKey=name
| order by severity asc, recommendation asc
"@

    $instances = Invoke-ResourceGraphQueryAll -SubscriptionId $account.subscriptionId -Query $instancesQuery
    $databases = Invoke-ResourceGraphQueryAll -SubscriptionId $account.subscriptionId -Query $databasesQuery -MaxPages 2000
    $patchAssessments = Invoke-ResourceGraphQueryAll -SubscriptionId $account.subscriptionId -Query $patchQuery
    $recommendations = Invoke-ResourceGraphQueryAll -SubscriptionId $account.subscriptionId -Query $recommendationsQuery -MaxPages 1000

    $databaseArray = @($databases.data | Where-Object { $null -ne $_ })
    $databasesByInstance = @{}
    foreach ($database in $databaseArray) {
        $instanceId = [string]$database.instanceId
        if (-not $databasesByInstance.ContainsKey($instanceId)) { $databasesByInstance[$instanceId] = [Collections.Generic.List[object]]::new() }
        $databasesByInstance[$instanceId].Add($database)
    }
    $patchByHost = @{}
    foreach ($patch in @($patchAssessments.data)) { $patchByHost[[string]$patch.hostId] = $patch }

    $instanceMap = [ordered]@{}
    $keyToInstanceId = @{}
    foreach ($instance in @($instances.data)) {
        $id = [string]$instance.id
        $key = New-ServerKey -NormalizedId $id
        $keyToInstanceId[$key] = $id
        $databaseCount = if ($databasesByInstance.ContainsKey($id)) { $databasesByInstance[$id].Count } else { 0 }
        $enriched = $instance | Select-Object -Property *
        $enriched | Add-Member -NotePropertyName key -NotePropertyValue $key -Force
        $enriched | Add-Member -NotePropertyName databaseCount -NotePropertyValue $databaseCount -Force
        $instanceMap[$id] = $enriched
    }

    $generationId = [guid]::NewGuid().ToString('n')
    $instanceArray = @($instanceMap.Values)
    $summary = Get-SqlSummaryData -Instances $instanceArray -Databases $databaseArray

    return [pscustomobject]@{
        generationId       = $generationId
        generatedAt        = (Get-Date).ToUniversalTime().ToString('o')
        account            = $account
        instances          = $instanceMap
        keyToInstanceId    = $keyToInstanceId
        instanceArray      = $instanceArray
        databasesByInstance = $databasesByInstance
        patchByHost        = $patchByHost
        recommendations    = @($recommendations.data)
        summary            = $summary
    }
}

function Get-SqlSummaryData {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Instances,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Databases
    )

    $engines = @($Instances | Where-Object { ([string]$_.serviceType).ToLowerInvariant() -eq 'engine' })
    $connected = @($Instances | Where-Object { ([string]$_.status).ToLowerInvariant() -eq 'connected' }).Count
    $protectedCount = @($Instances | Where-Object { ([string]$_.defenderStatus).ToLowerInvariant() -eq 'protected' }).Count
    $monitored = @($engines | Where-Object monitoringEnabled).Count
    $assessed = @($engines | Where-Object migrationAssessmentEnabled).Count
    $cores = ($engines | Measure-Object -Property cores -Sum).Sum
    $hosts = ($Instances | Select-Object -ExpandProperty containerResourceId -Unique | Where-Object { $_ }).Count
    $footprint = ($Databases | Measure-Object -Property sizeMB -Sum).Sum

    function Get-Distribution {
        param([array]$Items, [string]$Property)
        $groups = @{}
        foreach ($item in $Items) {
            $value = if ($item.$Property) { [string]$item.$Property } else { 'Unknown' }
            if (-not $groups.ContainsKey($value)) { $groups[$value] = 0 }
            $groups[$value]++
        }
        return , @($groups.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object { @{ name = $_.Key; count = $_.Value } })
    }

    return @{
        instanceTotal   = $Instances.Count
        connectedTotal  = $connected
        engineTotal     = $engines.Count
        coreTotal       = if ($cores) { $cores } else { 0 }
        hostTotal       = $hosts
        databaseTotal   = $Databases.Count
        footprintMB     = if ($footprint) { $footprint } else { 0 }
        protectedTotal  = $protectedCount
        assessedTotal   = $assessed
        monitoredTotal  = $monitored
        distributions   = @{
            versions = Get-Distribution -Items $Instances -Property 'version'
            editions = Get-Distribution -Items $Instances -Property 'edition'
            licenses = Get-Distribution -Items $Instances -Property 'licenseType'
            services = Get-Distribution -Items $Instances -Property 'serviceType'
        }
        facets          = @{
            serviceTypes    = @($Instances | Select-Object -ExpandProperty serviceType -Unique | Where-Object { $_ } | Sort-Object)
            defenderStatuses = @($Instances | Select-Object -ExpandProperty defenderStatus -Unique | Where-Object { $_ } | Sort-Object)
        }
    }
}

$script:SqlInstanceSortKeys = @('name', 'hostName', 'serviceType', 'status', 'version', 'edition', 'licenseType', 'defenderStatus', 'monitoringEnabled', 'databaseCount', 'resourceGroup', 'location')

function Get-SqlInstanceSortValue {
    param($Instance, [Parameter(Mandatory)][string]$Key)
    switch ($Key) {
        'databaseCount' { return [double]$Instance.databaseCount }
        'monitoringEnabled' {
            if ($Instance.monitoringEnabled) { return 1.0 }
            return 0.0
        }
        default { return ([string]$Instance.$Key).ToLowerInvariant() }
    }
}
$script:SqlInstanceNumericSortKeys = @('databaseCount', 'monitoringEnabled')

function Select-OrderedSqlInstanceList {
    <#
    Same native-LINQ, compile-the-key-selector-once approach as Select-OrderedServerList, and for the
    same reason: calling a generic per-item sort-value function from inside an O(n log n)
    comparison is measurably slow at scale, while calling it (or an inlined equivalent) once
    per row and letting .NET's LINQ ordering do the O(n log n) comparisons natively is not.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Instances,
        [Parameter(Mandatory)][string]$Sort,
        [Parameter(Mandatory)][ValidateSet('ascending', 'descending')][string]$Direction
    )

    $ascending = $Direction -eq 'ascending'
    $nameSelector = [Func[object, string]]{ param($s) ([string]$s.name).ToLowerInvariant() }

    if ($script:SqlInstanceNumericSortKeys -contains $Sort) {
        $keyText = if ($Sort -eq 'databaseCount') { 'param($s) [double]$s.databaseCount' } else { 'param($s) if ($s.monitoringEnabled) { 1.0 } else { 0.0 }' }
        $keySelector = [Func[object, double]][scriptblock]::Create($keyText)
        $ordered = [Linq.Enumerable]::OrderBy($Instances, $keySelector)
    }
    else {
        $keySelector = [Func[object, string]][scriptblock]::Create("param(`$s) ([string]`$s.$Sort).ToLowerInvariant()")
        $ordered = [Linq.Enumerable]::OrderBy($Instances, $keySelector, [StringComparer]::OrdinalIgnoreCase)
    }
    $ordered = [Linq.Enumerable]::ThenBy($ordered, $nameSelector, [StringComparer]::OrdinalIgnoreCase)
    if (-not $ascending) { $ordered = [Linq.Enumerable]::Reverse($ordered) }
    return , [Collections.Generic.List[object]]::new([Linq.Enumerable]::ToArray($ordered))
}

function Select-SqlInstancePage {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Instances,
        [Parameter(Mandatory)][string]$GenerationId,
        [string]$Sort = 'name',
        [string]$Direction = 'ascending',
        [string]$Search = '',
        [string]$ServiceType = '',
        [string]$DefenderStatus = '',
        [string]$Cursor = '',
        [int]$PageSize = 100
    )

    if ($Sort -notin $script:SqlInstanceSortKeys) { throw [ArgumentException]::new("Unsupported sort key '$Sort'.") }
    if ($Direction -notin @('ascending', 'descending')) { throw [ArgumentException]::new("Unsupported sort direction '$Direction'.") }
    $PageSize = [Math]::Max(1, [Math]::Min(250, $PageSize))

    $searchLower = $Search.Trim().ToLowerInvariant()
    $filtered = [Collections.Generic.List[object]]::new()
    foreach ($instance in $Instances) {
        if ($searchLower) {
            $haystack = "$($instance.name) $($instance.hostName) $($instance.resourceGroup) $($instance.location) $($instance.version) $($instance.edition)".ToLowerInvariant()
            if (-not $haystack.Contains($searchLower)) { continue }
        }
        if ($ServiceType -and [string]$instance.serviceType -ne $ServiceType) { continue }
        if ($DefenderStatus -and [string]$instance.defenderStatus -ne $DefenderStatus) { continue }
        $filtered.Add($instance)
    }

    $filtered = Select-OrderedSqlInstanceList -Instances $filtered -Sort $Sort -Direction $Direction

    $signature = Get-QuerySignature -Parameters @{ sort = $Sort; dir = $Direction; search = $searchLower; service = $ServiceType; defender = $DefenderStatus; size = $PageSize }
    $cursorResult = Resolve-OpaqueCursor -Cursor $Cursor -GenerationId $GenerationId -Signature $signature
    if (-not $cursorResult.Valid) { return @{ Error = $cursorResult.Reason } }

    $offset = $cursorResult.Offset
    $total = $filtered.Count
    if ($offset -gt $total) { $offset = $total }
    $endExclusive = [Math]::Min($total, $offset + $PageSize)
    $pageItems = if ($offset -lt $endExclusive) { $filtered.GetRange($offset, $endExclusive - $offset) } else { [Collections.Generic.List[object]]::new() }
    $returned = $pageItems.Count
    $hasNext = ($offset + $returned) -lt $total
    $hasPrevious = $offset -gt 0

    return @{
        Error          = $null
        Items          = @($pageItems)
        Total          = $total
        Offset         = $offset
        Returned       = $returned
        PageSize       = $PageSize
        HasNext        = $hasNext
        HasPrevious    = $hasPrevious
        NextCursor     = if ($hasNext) { New-OpaqueCursor -GenerationId $GenerationId -Signature $signature -Offset ($offset + $PageSize) } else { $null }
        PreviousCursor = if ($hasPrevious) { New-OpaqueCursor -GenerationId $GenerationId -Signature $signature -Offset ([Math]::Max(0, $offset - $PageSize)) } else { $null }
    }
}
# endregion SQL snapshot builder

# region Kubernetes snapshot builder
function Build-KubernetesSnapshot {
    <#
    .SYNOPSIS
    Builds one complete, immutable snapshot of every Arc-enabled connected cluster in the
    selected resource groups, its Microsoft.KubernetesConfiguration extension inventory,
    computed health, and pre-aggregated summary/facet data -- all computed once per refresh
    cycle rather than per request.

    .DESCRIPTION
    The caller is responsible for publishing the returned object atomically (a single
    assignment to a shared snapshot slot) only after this function returns successfully, so
    partially built state is never visible to request handlers.
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ResourceGroups,
        [AllowEmptyCollection()][array]$Locations = @()
    )

    $account = Get-TargetAccountInfo -SubscriptionId $SubscriptionId
    if ($Locations.Count -eq 0) {
        $Locations = @(Get-AzureLocationMetadataList -SubscriptionId $account.subscriptionId)
    }
    $resourceGroupFilter = Get-ResourceGroupKqlFilter -ResourceGroups $ResourceGroups

    $clustersQuery = @"
Resources
| where type =~ 'microsoft.kubernetes/connectedclusters'
$resourceGroupFilter
| project id=tolower(id), name, resourceGroup, location,
          connectivityStatus=tostring(properties.connectivityStatus),
          provisioningState=tostring(properties.provisioningState),
          kubernetesVersion=tostring(properties.kubernetesVersion),
          distribution=tostring(properties.distribution),
          infrastructure=tostring(properties.infrastructure),
          agentVersion=tostring(properties.agentVersion),
          agentAutoUpgrade=tostring(properties.arcAgentProfile.agentAutoUpgrade),
          desiredAgentVersion=tostring(properties.arcAgentProfile.desiredAgentVersion),
          agentErrors=properties.arcAgentProfile.agentErrors,
          lastConnectivityTime=tostring(properties.lastConnectivityTime),
          identityCertificateExpiration=tostring(properties.managedIdentityCertificateExpirationTime),
          totalNodeCount=toint(properties.totalNodeCount),
          totalCoreCount=toint(properties.totalCoreCount),
          offering=tostring(properties.offering),
          privateLinkState=tostring(properties.privateLinkState),
          azureRbacEnabled=tobool(properties.aadProfile.enableAzureRBAC),
          oidcEnabled=tobool(properties.oidcIssuerProfile.enabled),
          workloadIdentityEnabled=tobool(properties.securityProfile.workloadIdentity.enabled),
          azureHybridBenefit=tostring(properties.azureHybridBenefit)
| order by name asc
"@

    # Extension resource IDs are child resources of a connected cluster
    # ('.../connectedClusters/{name}/providers/Microsoft.KubernetesConfiguration/extensions/{name}').
    # The whole ID is lowercased before splitting on the known lowercase literal so the
    # cluster-id relationship is resolved robustly regardless of the casing Resource Graph
    # returns for the type segments themselves.
    $extensionsQuery = @"
Resources
| where type =~ 'microsoft.kubernetesconfiguration/extensions'
$resourceGroupFilter
| extend normalizedId=tolower(id)
| where normalizedId contains '/providers/microsoft.kubernetes/connectedclusters/'
| extend clusterId=tolower(substring(normalizedId, 0, indexof(normalizedId, '/providers/microsoft.kubernetesconfiguration/extensions/')))
| project clusterId, name, extensionType=tostring(properties.extensionType),
          version=tostring(properties.currentVersion),
          provisioningState=tostring(properties.provisioningState),
          autoUpgradeMinorVersion=tobool(properties.autoUpgradeMinorVersionEnabled)
"@

    $clusters = Invoke-ResourceGraphQueryAll -SubscriptionId $account.subscriptionId -Query $clustersQuery
    # Extension counts can exceed the cluster count many times over (several extensions per
    # cluster); use a high, query-specific ceiling so a large estate is never silently
    # truncated -- reaching it fails the refresh instead of publishing a partial inventory.
    $extensions = Invoke-ResourceGraphQueryAll -SubscriptionId $account.subscriptionId -Query $extensionsQuery -MaxPages 2000

    $extensionsByCluster = @{}
    foreach ($extension in @($extensions.data)) {
        $clusterId = [string]$extension.clusterId
        if (-not $clusterId) { continue }
        if (-not $extensionsByCluster.ContainsKey($clusterId)) {
            $extensionsByCluster[$clusterId] = [Collections.Generic.List[object]]::new()
        }
        $extensionsByCluster[$clusterId].Add([pscustomobject][ordered]@{
            name                    = $extension.name
            extensionType           = $extension.extensionType
            version                 = $extension.version
            provisioningState       = $extension.provisioningState
            autoUpgradeMinorVersion = [bool]$extension.autoUpgradeMinorVersion
        })
    }

    $clusterMap = [ordered]@{}
    $keyToClusterId = @{}
    foreach ($cluster in @($clusters.data)) {
        $id = [string]$cluster.id
        $key = New-ServerKey -NormalizedId $id
        $keyToClusterId[$key] = $id
        $agentErrors = @(@($cluster.agentErrors) | Where-Object { $null -ne $_ })
        $clusterExtensions = @()
        if ($extensionsByCluster.ContainsKey($id)) {
            $clusterExtensions = @($extensionsByCluster[$id])
        }
        $health = Get-KubernetesClusterHealth -ConnectivityStatus $cluster.connectivityStatus `
            -ProvisioningState $cluster.provisioningState -AgentErrorCount $agentErrors.Count `
            -LastConnectivityTime $cluster.lastConnectivityTime

        $clusterMap[$id] = [pscustomobject][ordered]@{
            id                             = $id
            key                            = $key
            name                           = $cluster.name
            resourceGroup                  = $cluster.resourceGroup
            location                       = $cluster.location
            connectivityStatus             = $cluster.connectivityStatus
            provisioningState              = $cluster.provisioningState
            health                         = $health
            kubernetesVersion              = $cluster.kubernetesVersion
            distribution                   = $cluster.distribution
            infrastructure                 = $cluster.infrastructure
            agentVersion                   = $cluster.agentVersion
            agentAutoUpgrade               = $cluster.agentAutoUpgrade
            desiredAgentVersion            = $cluster.desiredAgentVersion
            agentErrors                    = $agentErrors
            lastConnectivityTime           = $cluster.lastConnectivityTime
            identityCertificateExpiration  = $cluster.identityCertificateExpiration
            totalNodeCount                 = $cluster.totalNodeCount
            totalCoreCount                 = $cluster.totalCoreCount
            offering                       = $cluster.offering
            privateLinkState               = $cluster.privateLinkState
            azureRbacEnabled               = [bool]$cluster.azureRbacEnabled
            oidcEnabled                    = [bool]$cluster.oidcEnabled
            workloadIdentityEnabled        = [bool]$cluster.workloadIdentityEnabled
            azureHybridBenefit             = $cluster.azureHybridBenefit
            extensionCount                 = $clusterExtensions.Count
            extensions                     = $clusterExtensions
        }
    }

    $generationId = [guid]::NewGuid().ToString('n')
    $clusterArray = @($clusterMap.Values)
    $summary = Get-KubernetesSummaryData -Clusters $clusterArray
    $geography = Build-GeographySummary -Servers @() -Clusters $clusterArray -Locations $Locations

    return [pscustomobject]@{
        generationId    = $generationId
        generatedAt     = (Get-Date).ToUniversalTime().ToString('o')
        account         = $account
        clusters        = $clusterMap
        keyToClusterId  = $keyToClusterId
        clusterArray    = $clusterArray
        summary         = $summary
        geography       = $geography
    }
}

function Get-KubernetesSummaryData {
    <#
    Single-pass aggregation over the full cluster array producing fleet-wide totals, coverage
    indicators, and the distinct-value facets the frontend needs to populate filter dropdowns
    -- all without ever sending the underlying cluster inventory to the browser.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Clusters)

    $total = $Clusters.Count
    $healthCounts = @{ up = 0; warning = 0; down = 0; critical = 0; unknown = 0 }
    $connected = 0; $disconnected = 0; $other = 0
    $totalNodes = 0L; $totalCores = 0L
    $withExtensions = 0
    $staleConnectivity = 0
    $expiringCertificates = 0
    $autoUpgradeEnabled = 0
    $versionSet = [Collections.Generic.HashSet[string]]::new()
    $resourceGroups = [Collections.Generic.HashSet[string]]::new()
    $locations = [Collections.Generic.HashSet[string]]::new()
    $distributionValues = [Collections.Generic.HashSet[string]]::new()
    $infrastructureValues = [Collections.Generic.HashSet[string]]::new()
    $connectivityStatusValues = [Collections.Generic.HashSet[string]]::new()
    $now = (Get-Date).ToUniversalTime()
    $certificateWarningWindow = [TimeSpan]::FromDays(30)

    foreach ($cluster in $Clusters) {
        if ($healthCounts.ContainsKey($cluster.health)) { $healthCounts[$cluster.health]++ }

        $status = ([string]$cluster.connectivityStatus).ToLowerInvariant()
        if ($status -eq 'connected') { $connected++ }
        elseif ($status -eq 'disconnected') { $disconnected++ }
        else { $other++ }

        if ($null -ne $cluster.totalNodeCount) { $totalNodes += [int64]$cluster.totalNodeCount }
        if ($null -ne $cluster.totalCoreCount) { $totalCores += [int64]$cluster.totalCoreCount }
        if ($cluster.extensionCount -gt 0) { $withExtensions++ }
        if (([string]$cluster.agentAutoUpgrade).ToLowerInvariant() -eq 'enabled') { $autoUpgradeEnabled++ }
        if ($cluster.kubernetesVersion) { [void]$versionSet.Add([string]$cluster.kubernetesVersion) }
        if ($cluster.resourceGroup) { [void]$resourceGroups.Add([string]$cluster.resourceGroup) }
        if ($cluster.location) { [void]$locations.Add([string]$cluster.location) }
        if ($cluster.distribution) { [void]$distributionValues.Add([string]$cluster.distribution) }
        if ($cluster.infrastructure) { [void]$infrastructureValues.Add([string]$cluster.infrastructure) }
        if ($cluster.connectivityStatus) { [void]$connectivityStatusValues.Add([string]$cluster.connectivityStatus) }

        # "Stale connectivity" flags a cluster the control plane still reports as Connected but
        # whose last-connectivity heartbeat is aging -- distinct from (and an earlier warning
        # sign than) the health field, which only turns down once the heartbeat is badly stale.
        # Dates are parsed defensively: a single malformed timestamp must never fail the whole
        # summary aggregation, so an unparsable value is simply treated as "no timestamp".
        if ($status -eq 'connected' -and $cluster.lastConnectivityTime) {
            $lastContact = ConvertTo-SafeUtcDateTime -Value $cluster.lastConnectivityTime
            if ($lastContact) {
                $minutesSinceContact = ($now - $lastContact).TotalMinutes
                if ($minutesSinceContact -gt 15) { $staleConnectivity++ }
            }
        }

        if ($cluster.identityCertificateExpiration) {
            $expiresAt = ConvertTo-SafeUtcDateTime -Value $cluster.identityCertificateExpiration
            if ($expiresAt -and $expiresAt -le ($now + $certificateWarningWindow)) { $expiringCertificates++ }
        }
    }

    function Get-KubernetesValueDistribution {
        param([array]$Items, [string]$Property)
        $groups = @{}
        foreach ($item in $Items) {
            $groupValue = if ($item.$Property) { [string]$item.$Property } else { 'Unknown' }
            if (-not $groups.ContainsKey($groupValue)) { $groups[$groupValue] = 0 }
            $groups[$groupValue]++
        }
        # The leading unary comma is required, not cosmetic: without it, PowerShell's function
        # return/pipeline capture collapses a single-element (or empty) array result into a
        # bare object (or $null) at the call site below, which then serializes to JSON as a
        # bare object -- or "null" for zero entries -- instead of a JSON array. The frontend
        # always expects an array here (0, 1, or many distribution rows), so this must hold for
        # every cluster-count scenario. Rows are plain objects (not dictionaries) for stable,
        # browser-friendly property access and predictable JSON key order.
        return , @($groups.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object { [pscustomobject][ordered]@{ name = $_.Key; count = $_.Value } })
    }

    return @{
        total                 = $total
        up                    = $healthCounts.up
        warning               = $healthCounts.warning
        down                  = $healthCounts.down + $healthCounts.critical
        critical              = $healthCounts.critical
        unknown               = $healthCounts.unknown
        connected             = $connected
        disconnected          = $disconnected
        other                 = $other
        totalNodes            = $totalNodes
        totalCores            = $totalCores
        versionCount          = $versionSet.Count
        withExtensions        = $withExtensions
        staleConnectivity     = $staleConnectivity
        expiringCertificates  = $expiringCertificates
        autoUpgradeEnabled    = $autoUpgradeEnabled
        distributions         = @{
            versions        = Get-KubernetesValueDistribution -Items $Clusters -Property 'kubernetesVersion'
            distributions   = Get-KubernetesValueDistribution -Items $Clusters -Property 'distribution'
            infrastructures = Get-KubernetesValueDistribution -Items $Clusters -Property 'infrastructure'
        }
        facets                = @{
            resourceGroups       = @($resourceGroups | Sort-Object)
            locations            = @($locations | Sort-Object)
            distributions        = @($distributionValues | Sort-Object)
            infrastructures      = @($infrastructureValues | Sort-Object)
            connectivityStatuses = @($connectivityStatusValues | Sort-Object)
        }
    }
}

$script:KubernetesClusterSortKeys = @(
    'name', 'health', 'connectivityStatus', 'provisioningState', 'kubernetesVersion', 'distribution',
    'infrastructure', 'agentVersion', 'agentAutoUpgrade', 'totalNodeCount', 'totalCoreCount',
    'lastConnectivityTime', 'identityCertificateExpiration', 'extensionCount', 'resourceGroup',
    'location', 'azureRbacEnabled', 'oidcEnabled', 'workloadIdentityEnabled'
)
$script:KubernetesNullableNumericSortKeys = @('totalNodeCount', 'totalCoreCount', 'lastConnectivityTime', 'identityCertificateExpiration')
$script:KubernetesAlwaysNumericSortKeys = @('health', 'extensionCount', 'agentAutoUpgrade', 'azureRbacEnabled', 'oidcEnabled', 'workloadIdentityEnabled')

function Select-OrderedKubernetesClusterList {
    <#
    Same native-LINQ, compile-the-key-selector-once approach as Select-OrderedServerList and for the
    same reason: calling a generic per-item sort-value function from inside an O(n log n)
    comparison is measurably slow at scale, while calling it (or an inlined equivalent) once
    per row and letting .NET's LINQ ordering do the O(n log n) comparisons natively is not.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Clusters,
        [Parameter(Mandatory)][string]$Sort,
        [Parameter(Mandatory)][ValidateSet('ascending', 'descending')][string]$Direction
    )

    $ascending = $Direction -eq 'ascending'
    $nameSelector = [Func[object, string]]{ param($s) ([string]$s.name).ToLowerInvariant() }

    if ($script:KubernetesNullableNumericSortKeys -contains $Sort) {
        # lastConnectivityTime/identityCertificateExpiration are date-valued and must be parsed
        # defensively (ConvertTo-SafeUtcDateTime never throws): a single malformed date string
        # must never fail the whole sort, and a value that fails to parse is treated exactly
        # like a genuinely missing value -- it sorts into the "no value" partition below rather
        # than crashing the comparison or mixing null/non-null types in one OrderBy call.
        if ($Sort -in @('lastConnectivityTime', 'identityCertificateExpiration')) {
            $keyText = "param(`$s) `$__parsed = ConvertTo-SafeUtcDateTime -Value `$s.$Sort; if (`$__parsed) { `$__parsed.Ticks } else { `$null }"
            $hasValueSelector = [Func[object, bool]][scriptblock]::Create("param(`$s) `$null -ne (ConvertTo-SafeUtcDateTime -Value `$s.$Sort)")
            $noValueSelector = [Func[object, bool]][scriptblock]::Create("param(`$s) `$null -eq (ConvertTo-SafeUtcDateTime -Value `$s.$Sort)")
        }
        else {
            $keyText = "param(`$s) `$s.$Sort"
            $hasValueSelector = [Func[object, bool]][scriptblock]::Create("param(`$s) `$null -ne `$s.$Sort")
            $noValueSelector = [Func[object, bool]][scriptblock]::Create("param(`$s) `$null -eq `$s.$Sort")
        }
        $keySelector = [Func[object, object]][scriptblock]::Create($keyText)

        $withValue = [Linq.Enumerable]::Where($Clusters, $hasValueSelector)
        $withoutValue = [Linq.Enumerable]::Where($Clusters, $noValueSelector)
        $ordered = [Linq.Enumerable]::OrderBy($withValue, $keySelector)
        $ordered = [Linq.Enumerable]::ThenBy($ordered, $nameSelector, [StringComparer]::OrdinalIgnoreCase)
        if (-not $ascending) { $ordered = [Linq.Enumerable]::Reverse($ordered) }
        # Null values always sort last, independent of ascending/descending, matching the
        # dashboard's established "unavailable telemetry sorts to the bottom" convention.
        $resultArray = [Linq.Enumerable]::ToArray([Linq.Enumerable]::Concat($ordered, $withoutValue))
    }
    elseif ($script:KubernetesAlwaysNumericSortKeys -contains $Sort) {
        $keyText = switch ($Sort) {
            'health' { 'param($s) switch ([string]$s.health) { "critical" { 0.0 } "down" { 1.0 } "warning" { 2.0 } "unknown" { 3.0 } "up" { 4.0 } default { 3.0 } }' }
            'extensionCount' { "param(`$s) [double]`$s.extensionCount" }
            'agentAutoUpgrade' { 'param($s) if (([string]$s.agentAutoUpgrade).ToLowerInvariant() -eq "enabled") { 1.0 } else { 0.0 }' }
            default { "param(`$s) if (`$s.$Sort) { 1.0 } else { 0.0 }" }
        }
        $keySelector = [Func[object, double]][scriptblock]::Create($keyText)
        $ordered = [Linq.Enumerable]::OrderBy($Clusters, $keySelector)
        $ordered = [Linq.Enumerable]::ThenBy($ordered, $nameSelector, [StringComparer]::OrdinalIgnoreCase)
        if (-not $ascending) { $ordered = [Linq.Enumerable]::Reverse($ordered) }
        $resultArray = [Linq.Enumerable]::ToArray($ordered)
    }
    else {
        $keySelector = [Func[object, string]][scriptblock]::Create("param(`$s) ([string]`$s.$Sort).ToLowerInvariant()")
        $ordered = [Linq.Enumerable]::OrderBy($Clusters, $keySelector, [StringComparer]::OrdinalIgnoreCase)
        $ordered = [Linq.Enumerable]::ThenBy($ordered, $nameSelector, [StringComparer]::OrdinalIgnoreCase)
        if (-not $ascending) { $ordered = [Linq.Enumerable]::Reverse($ordered) }
        $resultArray = [Linq.Enumerable]::ToArray($ordered)
    }

    return , [Collections.Generic.List[object]]::new($resultArray)
}

function Select-KubernetesClusterPage {
    <#
    .SYNOPSIS
    Applies whitelisted filters and sort to the immutable per-generation cluster array, then
    returns one bounded page using an opaque, generation- and query-bound cursor.

    .DESCRIPTION
    All filtering and sorting happens entirely in memory against already-fetched snapshot
    data -- no request input is ever interpolated into a KQL query. Sort key, direction, and
    the server-computed Health enum are validated against a fixed whitelist before use. Other
    filters (ResourceGroup, Location, Distribution, Infrastructure, ConnectivityStatus) are raw
    values reported by Azure itself rather than a value this codebase computes, so -- exactly
    like ResourceGroup/Location/Distribution/Infrastructure -- ConnectivityStatus is matched by
    plain equality instead of a hardcoded enum: Azure's connectivityStatus values are not fixed
    by this dashboard, and a real, future, or unanticipated status value must still be
    filterable (a non-matching value simply yields zero rows, never a thrown error).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Clusters,
        [Parameter(Mandatory)][string]$GenerationId,
        [string]$Sort = 'name',
        [string]$Direction = 'ascending',
        [string]$Search = '',
        [string]$ResourceGroup = '',
        [string]$Location = '',
        [string]$Health = '',
        [string]$ConnectivityStatus = '',
        [string]$Distribution = '',
        [string]$Infrastructure = '',
        [string]$Cursor = '',
        [int]$PageSize = 100
    )

    if ($Sort -notin $script:KubernetesClusterSortKeys) {
        throw [ArgumentException]::new("Unsupported sort key '$Sort'.")
    }
    if ($Direction -notin @('ascending', 'descending')) {
        throw [ArgumentException]::new("Unsupported sort direction '$Direction'.")
    }
    if ($Health -and $Health -notin @('critical', 'down', 'warning', 'up', 'unknown')) {
        throw [ArgumentException]::new("Unsupported health filter '$Health'.")
    }
    $PageSize = [Math]::Max(1, [Math]::Min(250, $PageSize))

    $searchLower = $Search.Trim().ToLowerInvariant()
    $filtered = [Collections.Generic.List[object]]::new()
    foreach ($cluster in $Clusters) {
        if ($searchLower) {
            $haystack = "$($cluster.name) $($cluster.resourceGroup) $($cluster.location) $($cluster.distribution) $($cluster.infrastructure)".ToLowerInvariant()
            if (-not $haystack.Contains($searchLower)) { continue }
        }
        if ($ResourceGroup -and [string]$cluster.resourceGroup -ne $ResourceGroup) { continue }
        if ($Location -and [string]$cluster.location -ne $Location) { continue }
        if ($Health -and [string]$cluster.health -ne $Health) { continue }
        if ($ConnectivityStatus -and [string]$cluster.connectivityStatus -ne $ConnectivityStatus) { continue }
        if ($Distribution -and [string]$cluster.distribution -ne $Distribution) { continue }
        if ($Infrastructure -and [string]$cluster.infrastructure -ne $Infrastructure) { continue }
        $filtered.Add($cluster)
    }

    $sorted = Select-OrderedKubernetesClusterList -Clusters $filtered -Sort $Sort -Direction $Direction

    $signature = Get-QuerySignature -Parameters @{
        sort = $Sort; dir = $Direction; search = $searchLower; rg = $ResourceGroup; loc = $Location
        health = $Health; connectivity = $ConnectivityStatus; distribution = $Distribution
        infrastructure = $Infrastructure; size = $PageSize
    }
    $cursorResult = Resolve-OpaqueCursor -Cursor $Cursor -GenerationId $GenerationId -Signature $signature
    if (-not $cursorResult.Valid) {
        return @{ Error = $cursorResult.Reason }
    }

    $offset = $cursorResult.Offset
    $total = $sorted.Count
    if ($offset -gt $total) { $offset = $total }
    $endExclusive = [Math]::Min($total, $offset + $PageSize)
    $pageItems = if ($offset -lt $endExclusive) { $sorted.GetRange($offset, $endExclusive - $offset) } else { [Collections.Generic.List[object]]::new() }
    $returned = $pageItems.Count
    $hasNext = ($offset + $returned) -lt $total
    $hasPrevious = $offset -gt 0

    return @{
        Error          = $null
        Items          = @($pageItems)
        Total          = $total
        Offset         = $offset
        Returned       = $returned
        PageSize       = $PageSize
        HasNext        = $hasNext
        HasPrevious    = $hasPrevious
        NextCursor     = if ($hasNext) { New-OpaqueCursor -GenerationId $GenerationId -Signature $signature -Offset ($offset + $PageSize) } else { $null }
        PreviousCursor = if ($hasPrevious) { New-OpaqueCursor -GenerationId $GenerationId -Signature $signature -Offset ([Math]::Max(0, $offset - $PageSize)) } else { $null }
    }
}

function ConvertTo-KubernetesClusterListRow {
    <#
    List rows omit the verbose extensions/agentErrors arrays (available on demand from the
    detail endpoint) to keep each bounded page response small regardless of estate size.
    #>
    param($Cluster)

    $clone = $Cluster | Select-Object -Property * -ExcludeProperty extensions, agentErrors
    return $clone
}
# endregion Kubernetes snapshot builder

# region Shared-state snapshot orchestration
function Update-OperationsSnapshot {
    <#
    Builds a complete replacement operations snapshot and only then atomically publishes it
    (a single reference assignment) into $SharedState. If the build fails, the prior snapshot
    -- if any -- is left completely untouched so requests keep being served from the last
    known-good data while the error is recorded for visibility.
    #>
    param([Parameter(Mandatory)][hashtable]$SharedState)

    $SharedState.BuildGate.Wait()
    try {
        $config = $SharedState.Config
        $configVersion = [long]$SharedState.ConfigVersion
        if (-not $config.IsConfigured) { return }
        $snapshot = Build-OperationsSnapshot -SubscriptionId $config.SubscriptionId -ResourceGroups $config.ResourceGroups -Workspaces $config.Workspaces
        if ($configVersion -ne [long]$SharedState.ConfigVersion) {
            return
        }
        $SharedState.OperationsSnapshot = $snapshot
        $SharedState.LastOperationsError = $null
    }
    catch {
        $SharedState.LastOperationsError = $_.Exception.Message
        Write-Warning "Operations snapshot refresh failed (prior snapshot, if any, remains in service): $($_.Exception.Message)"
    }
    finally {
        [void]$SharedState.BuildGate.Release()
    }
}

function Update-SqlSnapshot {
    param([Parameter(Mandatory)][hashtable]$SharedState)

    $SharedState.SqlBuildGate.Wait()
    try {
        $config = $SharedState.Config
        $configVersion = [long]$SharedState.ConfigVersion
        if (-not $config.IsConfigured) { return }
        $snapshot = Build-SqlSnapshot -SubscriptionId $config.SubscriptionId -ResourceGroups $config.ResourceGroups
        if ($configVersion -ne [long]$SharedState.ConfigVersion) {
            return
        }
        $SharedState.SqlSnapshot = $snapshot
        $SharedState.LastSqlError = $null
    }
    catch {
        $SharedState.LastSqlError = $_.Exception.Message
        Write-Warning "SQL snapshot refresh failed (prior snapshot, if any, remains in service): $($_.Exception.Message)"
    }
    finally {
        [void]$SharedState.SqlBuildGate.Release()
    }
}

function Update-KubernetesSnapshot {
    param([Parameter(Mandatory)][hashtable]$SharedState)

    $SharedState.KubernetesBuildGate.Wait()
    try {
        $config = $SharedState.Config
        $configVersion = [long]$SharedState.ConfigVersion
        if (-not $config.IsConfigured) { return }
        $locations = if ($SharedState.OperationsSnapshot) { @($SharedState.OperationsSnapshot.locations) } else { @() }
        $snapshot = Build-KubernetesSnapshot -SubscriptionId $config.SubscriptionId -ResourceGroups $config.ResourceGroups -Locations $locations
        if ($configVersion -ne [long]$SharedState.ConfigVersion) {
            return
        }
        $SharedState.KubernetesSnapshot = $snapshot
        $SharedState.LastKubernetesError = $null
    }
    catch {
        $SharedState.LastKubernetesError = $_.Exception.Message
        Write-Warning "Kubernetes snapshot refresh failed (prior snapshot, if any, remains in service): $($_.Exception.Message)"
    }
    finally {
        [void]$SharedState.KubernetesBuildGate.Release()
    }
}

function Get-OperationsSnapshotOrBuild {
    <#
    Serves the published snapshot when one exists. On the very first request after startup
    (no snapshot yet), this builds synchronously -- but only for the single caller that wins
    the build gate; every other concurrent caller is told a build is already in progress
    instead of triggering a redundant, expensive 50,000-server fetch of its own.
    #>
    param([Parameter(Mandatory)][hashtable]$SharedState)

    $existing = $SharedState.OperationsSnapshot
    if ($existing) { return @{ Snapshot = $existing; Building = $false; Error = $null } }

    $acquired = $SharedState.BuildGate.Wait(200)
    if (-not $acquired) {
        return @{ Snapshot = $null; Building = $true; Error = $null }
    }
    try {
        $current = $SharedState.OperationsSnapshot
        if ($current) { return @{ Snapshot = $current; Building = $false; Error = $null } }
        $config = $SharedState.Config
        $configVersion = [long]$SharedState.ConfigVersion
        if (-not $config.IsConfigured) { return @{ Snapshot = $null; Building = $false; Error = 'not-configured' } }
        try {
            $snapshot = Build-OperationsSnapshot -SubscriptionId $config.SubscriptionId -ResourceGroups $config.ResourceGroups -Workspaces $config.Workspaces
            if ($configVersion -ne [long]$SharedState.ConfigVersion) {
                return @{ Snapshot = $null; Building = $true; Error = $null }
            }
            $SharedState.OperationsSnapshot = $snapshot
            $SharedState.LastOperationsError = $null
            return @{ Snapshot = $snapshot; Building = $false; Error = $null }
        }
        catch {
            $SharedState.LastOperationsError = $_.Exception.Message
            return @{ Snapshot = $null; Building = $false; Error = $_.Exception.Message }
        }
    }
    finally {
        [void]$SharedState.BuildGate.Release()
    }
}

function Get-SqlSnapshotOrBuild {
    param([Parameter(Mandatory)][hashtable]$SharedState)

    $existing = $SharedState.SqlSnapshot
    if ($existing) { return @{ Snapshot = $existing; Building = $false; Error = $null } }

    $acquired = $SharedState.SqlBuildGate.Wait(200)
    if (-not $acquired) {
        return @{ Snapshot = $null; Building = $true; Error = $null }
    }
    try {
        $current = $SharedState.SqlSnapshot
        if ($current) { return @{ Snapshot = $current; Building = $false; Error = $null } }
        $config = $SharedState.Config
        $configVersion = [long]$SharedState.ConfigVersion
        if (-not $config.IsConfigured) { return @{ Snapshot = $null; Building = $false; Error = 'not-configured' } }
        try {
            $snapshot = Build-SqlSnapshot -SubscriptionId $config.SubscriptionId -ResourceGroups $config.ResourceGroups
            if ($configVersion -ne [long]$SharedState.ConfigVersion) {
                return @{ Snapshot = $null; Building = $true; Error = $null }
            }
            $SharedState.SqlSnapshot = $snapshot
            $SharedState.LastSqlError = $null
            return @{ Snapshot = $snapshot; Building = $false; Error = $null }
        }
        catch {
            $SharedState.LastSqlError = $_.Exception.Message
            return @{ Snapshot = $null; Building = $false; Error = $_.Exception.Message }
        }
    }
    finally {
        [void]$SharedState.SqlBuildGate.Release()
    }
}

function Get-KubernetesSnapshotOrBuild {
    param([Parameter(Mandatory)][hashtable]$SharedState)

    $existing = $SharedState.KubernetesSnapshot
    if ($existing) { return @{ Snapshot = $existing; Building = $false; Error = $null } }

    $acquired = $SharedState.KubernetesBuildGate.Wait(200)
    if (-not $acquired) {
        return @{ Snapshot = $null; Building = $true; Error = $null }
    }
    try {
        $current = $SharedState.KubernetesSnapshot
        if ($current) { return @{ Snapshot = $current; Building = $false; Error = $null } }
        $config = $SharedState.Config
        $configVersion = [long]$SharedState.ConfigVersion
        if (-not $config.IsConfigured) { return @{ Snapshot = $null; Building = $false; Error = 'not-configured' } }
        try {
            $locations = if ($SharedState.OperationsSnapshot) { @($SharedState.OperationsSnapshot.locations) } else { @() }
            $snapshot = Build-KubernetesSnapshot -SubscriptionId $config.SubscriptionId -ResourceGroups $config.ResourceGroups -Locations $locations
            if ($configVersion -ne [long]$SharedState.ConfigVersion) {
                return @{ Snapshot = $null; Building = $true; Error = $null }
            }
            $SharedState.KubernetesSnapshot = $snapshot
            $SharedState.LastKubernetesError = $null
            return @{ Snapshot = $snapshot; Building = $false; Error = $null }
        }
        catch {
            $SharedState.LastKubernetesError = $_.Exception.Message
            return @{ Snapshot = $null; Building = $false; Error = $_.Exception.Message }
        }
    }
    finally {
        [void]$SharedState.KubernetesBuildGate.Release()
    }
}

function Reset-DashboardSnapshots {
    <#
    Called on configure and logout so stale data can never be served under a new or cleared
    configuration. No retrieved Azure inventory or telemetry is ever written to disk, so
    clearing these in-memory references is also the entire at-rest cleanup needed.
    #>
    param([Parameter(Mandatory)][hashtable]$SharedState)
    $SharedState.ConfigVersion = [long]$SharedState.ConfigVersion + 1
    $SharedState.OperationsSnapshot = $null
    $SharedState.SqlSnapshot = $null
    $SharedState.KubernetesSnapshot = $null
    $SharedState.LastOperationsError = $null
    $SharedState.LastSqlError = $null
    $SharedState.LastKubernetesError = $null
    $SharedState.VmSkuCache = [hashtable]::Synchronized(@{})
    $SharedState.ForceRefresh = $true
}

function Start-DashboardRefreshLoop {
    <#
    Runs entirely on its own dedicated background runspace (see server.ps1). Azure fetches
    triggered from here never run on the request-handling thread pool or the connection-
    accept loop, so a long refresh cannot block already-cached API/page responses.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$SharedState,
        [ValidateRange(30, 3600)][int]$IntervalSeconds = 300
    )

    while (-not $SharedState.ShutdownRequested) {
        $config = $SharedState.Config
        if ($config.IsConfigured) {
            Update-OperationsSnapshot -SharedState $SharedState
            Update-SqlSnapshot -SharedState $SharedState
            Update-KubernetesSnapshot -SharedState $SharedState
        }
        $waited = 0
        while ($waited -lt $IntervalSeconds -and -not $SharedState.ShutdownRequested -and
            -not $SharedState.ForceRefresh -and -not $SharedState.RefreshSignal.Requested) {
            Start-Sleep -Seconds 2
            $waited += 2
        }
        if ($SharedState.ForceRefresh) {
            $SharedState.ForceRefresh = $false
        }
        if ($SharedState.RefreshSignal.Requested) {
            $SharedState.RefreshSignal.Requested = $false
        }
    }
}
# endregion Shared-state snapshot orchestration

# region HTTP plumbing shared by the request-handling pool
function ConvertFrom-QueryString {
    param([string]$Query)
    $values = @{}
    foreach ($part in @($Query.TrimStart('?') -split '&' | Where-Object { $_ })) {
        $pair = $part -split '=', 2
        $name = [Uri]::UnescapeDataString($pair[0].Replace('+', ' '))
        $value = if ($pair.Count -gt 1) { [Uri]::UnescapeDataString($pair[1].Replace('+', ' ')) } else { '' }
        $values[$name] = $value
    }
    return $values
}

function Write-HttpResponseBytes {
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$StatusText,
        [Parameter(Mandatory)][string]$ContentType,
        [Parameter(Mandatory)][byte[]]$Body,
        [hashtable]$ExtraHeaders
    )
    $headerText = "HTTP/1.1 $StatusCode $StatusText`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-store`r`nPragma: no-cache`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`nConnection: close`r`n"
    if ($ExtraHeaders) {
        foreach ($header in $ExtraHeaders.GetEnumerator()) {
            $headerText += "$($header.Key): $($header.Value)`r`n"
        }
    }
    $headerText += "`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($headerText)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($Body, 0, $Body.Length)
    $Stream.Flush()
}

function Write-JsonResponseBytes {
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][object]$Value,
        [int]$StatusCode = 200,
        [string]$StatusText = 'OK',
        [hashtable]$ExtraHeaders
    )
    $body = $Value | ConvertTo-Json -Depth 12 -Compress
    Write-HttpResponseBytes -Stream $Stream -StatusCode $StatusCode -StatusText $StatusText `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ExtraHeaders $ExtraHeaders
}
# endregion HTTP plumbing shared by the request-handling pool

# region Enterprise API request handling (runs inside the request-handling RunspacePool)
function Get-RequiredOperationsSnapshot {
    param([Parameter(Mandatory)][hashtable]$SharedState, [Parameter(Mandatory)][IO.Stream]$Stream)

    $result = Get-OperationsSnapshotOrBuild -SharedState $SharedState
    if ($result.Error -eq 'not-configured') {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'The dashboard is not configured yet. Complete setup first.' } -StatusCode 409 -StatusText 'Conflict'
        return $null
    }
    if ($result.Building) {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'Initial data load is in progress. Retry shortly.'; retryAfterSeconds = 2 } `
            -StatusCode 503 -StatusText 'Service Unavailable' -ExtraHeaders @{ 'Retry-After' = '2' }
        return $null
    }
    if ($result.Error) {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = $result.Error } -StatusCode 502 -StatusText 'Bad Gateway'
        return $null
    }
    return $result.Snapshot
}

function Get-RequiredSqlSnapshot {
    param([Parameter(Mandatory)][hashtable]$SharedState, [Parameter(Mandatory)][IO.Stream]$Stream)

    $result = Get-SqlSnapshotOrBuild -SharedState $SharedState
    if ($result.Error -eq 'not-configured') {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'The dashboard is not configured yet. Complete setup first.' } -StatusCode 409 -StatusText 'Conflict'
        return $null
    }
    if ($result.Building) {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'Initial data load is in progress. Retry shortly.'; retryAfterSeconds = 2 } `
            -StatusCode 503 -StatusText 'Service Unavailable' -ExtraHeaders @{ 'Retry-After' = '2' }
        return $null
    }
    if ($result.Error) {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = $result.Error } -StatusCode 502 -StatusText 'Bad Gateway'
        return $null
    }
    return $result.Snapshot
}

function Get-RequiredKubernetesSnapshot {
    param([Parameter(Mandatory)][hashtable]$SharedState, [Parameter(Mandatory)][IO.Stream]$Stream)

    $result = Get-KubernetesSnapshotOrBuild -SharedState $SharedState
    if ($result.Error -eq 'not-configured') {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'The dashboard is not configured yet. Complete setup first.' } -StatusCode 409 -StatusText 'Conflict'
        return $null
    }
    if ($result.Building) {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'Initial data load is in progress. Retry shortly.'; retryAfterSeconds = 2 } `
            -StatusCode 503 -StatusText 'Service Unavailable' -ExtraHeaders @{ 'Retry-After' = '2' }
        return $null
    }
    if ($result.Error) {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = $result.Error } -StatusCode 502 -StatusText 'Bad Gateway'
        return $null
    }
    return $result.Snapshot
}

function Get-QueryValue {
    param([hashtable]$QueryValues, [Parameter(Mandatory)][string]$Name)
    if ($QueryValues.ContainsKey($Name)) { return [string]$QueryValues[$Name] }
    return ''
}

function Send-OperationsSummary {
    param([hashtable]$SharedState, [IO.Stream]$Stream)
    $snapshot = Get-RequiredOperationsSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }
    Write-JsonResponseBytes -Stream $Stream -Value @{
        generationId    = $snapshot.generationId
        generatedAt     = $snapshot.generatedAt
        account         = $snapshot.account
        workspaces      = $snapshot.workspaces
        workspaceErrors = $snapshot.workspaceErrors
        refreshError    = $SharedState.LastOperationsError
        summary         = $snapshot.summary
        targetRegions   = @($snapshot.locations | Where-Object name | ForEach-Object {
            @{ name = [string]$_.name; displayName = [string]$_.displayName }
        } | Sort-Object displayName)
    }
}

function Send-LegacyOperationsSummary {
    param([hashtable]$SharedState, [IO.Stream]$Stream)
    $snapshot = Get-RequiredOperationsSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }
    Write-JsonResponseBytes -Stream $Stream -Value @{
        deprecated      = $true
        message         = 'This route now returns a bounded summary instead of the full inventory. Use /api/operations/summary and /api/operations/servers for enterprise-scale data.'
        generationId    = $snapshot.generationId
        generatedAt     = $snapshot.generatedAt
        account         = $snapshot.account
        workspaces      = $snapshot.workspaces
        workspaceErrors = $snapshot.workspaceErrors
        refreshError    = $SharedState.LastOperationsError
        summary         = $snapshot.summary
    }
}

function Send-ServerPage {
    param([hashtable]$SharedState, [hashtable]$QueryValues, [IO.Stream]$Stream)
    $snapshot = Get-RequiredOperationsSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }

    try {
        $sortValue = Get-QueryValue $QueryValues 'sort'
        if (-not $sortValue) { $sortValue = 'name' }
        $directionValue = Get-QueryValue $QueryValues 'direction'
        if (-not $directionValue) { $directionValue = 'ascending' }
        $pageSizeValue = 100
        $rawPageSize = Get-QueryValue $QueryValues 'pageSize'
        if ($rawPageSize) { [void][int]::TryParse($rawPageSize, [ref]$pageSizeValue) }
        $searchValue = Get-QueryValue $QueryValues 'search'
        $resourceGroupValue = Get-QueryValue $QueryValues 'resourceGroup'
        $locationValue = Get-QueryValue $QueryValues 'location'
        $healthValue = Get-QueryValue $QueryValues 'health'
        $arcStatusValue = Get-QueryValue $QueryValues 'arcStatus'
        $platformGroupValue = Get-QueryValue $QueryValues 'platformGroup'
        $osTypeValue = Get-QueryValue $QueryValues 'osType'
        $lifecycleValue = Get-QueryValue $QueryValues 'lifecycleState'
        $cursorValue = Get-QueryValue $QueryValues 'cursor'

        $page = Select-ServerPage -Servers $snapshot.serverArray -GenerationId $snapshot.generationId `
            -Sort $sortValue -Direction $directionValue -Search $searchValue -ResourceGroup $resourceGroupValue `
            -Location $locationValue -Health $healthValue -ArcStatus $arcStatusValue -PlatformGroup $platformGroupValue -OsType $osTypeValue `
            -LifecycleState $lifecycleValue -Cursor $cursorValue -PageSize $pageSizeValue

        if ($page.Error) {
            Write-JsonResponseBytes -Stream $Stream -Value @{
                error   = "cursor_$($page.Error)"
                message = 'The page cursor is stale or invalid for the current data and filters. Restart from the first page.'
            } -StatusCode 409 -StatusText 'Conflict'
            return
        }

        $rows = @($page.Items | ForEach-Object { ConvertTo-ServerListRow -Server $_ })
        Write-JsonResponseBytes -Stream $Stream -Value @{
            generationId = $snapshot.generationId
            generatedAt  = $snapshot.generatedAt
            sort         = @{ key = $sortValue; direction = $directionValue }
            filters      = @{
                search = $searchValue; resourceGroup = $resourceGroupValue; location = $locationValue
                health = $healthValue; arcStatus = $arcStatusValue; platformGroup = $platformGroupValue; osType = $osTypeValue; lifecycleState = $lifecycleValue
            }
            page    = @{
                pageSize = $page.PageSize; offset = $page.Offset; returned = $page.Returned; total = $page.Total
                hasNext = $page.HasNext; hasPrevious = $page.HasPrevious; nextCursor = $page.NextCursor; previousCursor = $page.PreviousCursor
            }
            servers = $rows
        }
    }
    catch [ArgumentException] {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = $_.Exception.Message } -StatusCode 400 -StatusText 'Bad Request'
    }
}

function Send-ServerDetail {
    param([hashtable]$SharedState, [string]$Key, [IO.Stream]$Stream)
    $snapshot = Get-RequiredOperationsSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }

    $id = $snapshot.keyToId[$Key]
    if (-not $id -or -not $snapshot.servers.Contains($id)) {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'Server not found in the current snapshot.' } -StatusCode 404 -StatusText 'Not Found'
        return
    }
    Write-JsonResponseBytes -Stream $Stream -Value @{
        generationId = $snapshot.generationId
        generatedAt  = $snapshot.generatedAt
        server       = $snapshot.servers[$id]
    }
}

function Send-VmSkuAssessment {
    param([hashtable]$SharedState, [string]$Key, [hashtable]$QueryValues, [IO.Stream]$Stream)
    $snapshot = Get-RequiredOperationsSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }

    $id = $snapshot.keyToId[$Key]
    if (-not $id -or -not $snapshot.servers.Contains($id)) {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'Server not found in the current snapshot.' } -StatusCode 404 -StatusText 'Not Found'
        return
    }

    $location = (Get-QueryValue $QueryValues 'region').Trim().ToLowerInvariant()
    $locationRecord = @($snapshot.locations | Where-Object { ([string]$_.name).ToLowerInvariant() -eq $location }) | Select-Object -First 1
    if (-not $location -or -not $locationRecord) {
        Write-JsonResponseBytes -Stream $Stream -Value @{
            error = 'Select a valid target Azure region returned for the configured subscription.'
        } -StatusCode 400 -StatusText 'Bad Request'
        return
    }

    $headroom = 35
    $rawHeadroom = Get-QueryValue $QueryValues 'headroom'
    if ($rawHeadroom) {
        $parsedHeadroom = 0
        if (-not [int]::TryParse($rawHeadroom, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedHeadroom) -or
            $parsedHeadroom -lt 10 -or $parsedHeadroom -gt 100) {
            Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'Headroom must be a whole percentage from 10 through 100.' } -StatusCode 400 -StatusText 'Bad Request'
            return
        }
        $headroom = $parsedHeadroom
    }

    try {
        $skus = @(Get-AzureVmSkuCandidates -SharedState $SharedState -SubscriptionId $snapshot.account.subscriptionId -Location $location)
        $assessment = Get-VmSkuAssessment -Server $snapshot.servers[$id] -Skus $skus -TargetLocation $location -HeadroomPercent $headroom
        Write-JsonResponseBytes -Stream $Stream -Value @{
            generationId = $snapshot.generationId
            generatedAt = $snapshot.generatedAt
            targetRegion = @{ name = [string]$locationRecord.name; displayName = [string]$locationRecord.displayName }
            assessment = $assessment
        }
    }
    catch {
        Write-JsonResponseBytes -Stream $Stream -Value @{
            error = "Unable to discover or assess virtual machine SKUs for '$location': $($_.Exception.Message)"
        } -StatusCode 502 -StatusText 'Bad Gateway'
    }
}

function Send-PlatformsSummary {
    param([hashtable]$SharedState, [IO.Stream]$Stream)
    $snapshot = Get-RequiredOperationsSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }
    Write-JsonResponseBytes -Stream $Stream -Value @{
        generationId = $snapshot.generationId
        generatedAt  = $snapshot.generatedAt
        account      = $snapshot.account
        refreshError = $SharedState.LastOperationsError
        total        = $snapshot.summary.total
        platforms    = $snapshot.summary.platforms
        facets       = $snapshot.summary.facets
    }
}

function Send-DeploymentSummary {
    param([hashtable]$SharedState, [IO.Stream]$Stream, [switch]$Legacy)
    $snapshot = Get-RequiredOperationsSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }
    Write-JsonResponseBytes -Stream $Stream -Value @{
        deprecated   = [bool]$Legacy
        generationId = $snapshot.generationId
        generatedAt  = $snapshot.generatedAt
        account      = $snapshot.account
        refreshError = $SharedState.LastOperationsError
        total        = $snapshot.summary.total
        deployment   = $snapshot.summary.deployment
        facets       = $snapshot.summary.facets
    }
}

function Send-GlobalSummary {
    param([hashtable]$SharedState, [hashtable]$QueryValues, [IO.Stream]$Stream)

    $infrastructure = (Get-QueryValue $QueryValues 'infrastructure').ToLowerInvariant()
    if (-not $infrastructure) { $infrastructure = 'all' }
    if ($infrastructure -notin @('all', 'servers', 'kubernetes')) {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'Infrastructure must be all, servers, or kubernetes.' } -StatusCode 400 -StatusText 'Bad Request'
        return
    }

    $operationsSnapshot = $null
    $kubernetesSnapshot = $null
    if ($infrastructure -in @('all', 'servers')) {
        $operationsSnapshot = Get-RequiredOperationsSnapshot -SharedState $SharedState -Stream $Stream
        if (-not $operationsSnapshot) { return }
    }
    if ($infrastructure -in @('all', 'kubernetes')) {
        $kubernetesSnapshot = Get-RequiredKubernetesSnapshot -SharedState $SharedState -Stream $Stream
        if (-not $kubernetesSnapshot) { return }
    }

    $geography = switch ($infrastructure) {
        'servers' { $operationsSnapshot.geography }
        'kubernetes' { $kubernetesSnapshot.geography }
        default { Merge-GeographySummaries -ServerGeography $operationsSnapshot.geography -KubernetesGeography $kubernetesSnapshot.geography }
    }
    $account = if ($operationsSnapshot) { $operationsSnapshot.account } else { $kubernetesSnapshot.account }
    $generatedAt = if ($operationsSnapshot -and $kubernetesSnapshot) {
        @($operationsSnapshot.generatedAt, $kubernetesSnapshot.generatedAt) | Sort-Object -Descending | Select-Object -First 1
    }
    elseif ($operationsSnapshot) { $operationsSnapshot.generatedAt }
    else { $kubernetesSnapshot.generatedAt }
    $generationId = @(
        if ($operationsSnapshot) { $operationsSnapshot.generationId }
        if ($kubernetesSnapshot) { $kubernetesSnapshot.generationId }
    ) -join ':'
    $refreshError = @(
        if ($operationsSnapshot -and $SharedState.LastOperationsError) { $SharedState.LastOperationsError }
        if ($kubernetesSnapshot -and $SharedState.LastKubernetesError) { $SharedState.LastKubernetesError }
    ) -join '; '

    Write-JsonResponseBytes -Stream $Stream -Value @{
        generationId  = $generationId
        generatedAt   = $generatedAt
        account       = $account
        refreshError  = $refreshError
        infrastructure = $infrastructure
        geography     = $geography
    }
}

function Send-SqlSummary {
    param([hashtable]$SharedState, [IO.Stream]$Stream, [switch]$Legacy)
    $snapshot = Get-RequiredSqlSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }
    Write-JsonResponseBytes -Stream $Stream -Value @{
        deprecated   = [bool]$Legacy
        generationId = $snapshot.generationId
        generatedAt  = $snapshot.generatedAt
        account      = $snapshot.account
        refreshError = $SharedState.LastSqlError
        summary      = $snapshot.summary
    }
}

function Send-SqlInstancePage {
    param([hashtable]$SharedState, [hashtable]$QueryValues, [IO.Stream]$Stream)
    $snapshot = Get-RequiredSqlSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }

    try {
        $sortValue = Get-QueryValue $QueryValues 'sort'
        if (-not $sortValue) { $sortValue = 'name' }
        $directionValue = Get-QueryValue $QueryValues 'direction'
        if (-not $directionValue) { $directionValue = 'ascending' }
        $pageSizeValue = 100
        $rawPageSize = Get-QueryValue $QueryValues 'pageSize'
        if ($rawPageSize) { [void][int]::TryParse($rawPageSize, [ref]$pageSizeValue) }
        $searchValue = Get-QueryValue $QueryValues 'search'
        $serviceTypeValue = Get-QueryValue $QueryValues 'serviceType'
        $defenderStatusValue = Get-QueryValue $QueryValues 'defenderStatus'
        $cursorValue = Get-QueryValue $QueryValues 'cursor'

        $page = Select-SqlInstancePage -Instances $snapshot.instanceArray -GenerationId $snapshot.generationId `
            -Sort $sortValue -Direction $directionValue -Search $searchValue -ServiceType $serviceTypeValue `
            -DefenderStatus $defenderStatusValue -Cursor $cursorValue -PageSize $pageSizeValue

        if ($page.Error) {
            Write-JsonResponseBytes -Stream $Stream -Value @{
                error   = "cursor_$($page.Error)"
                message = 'The page cursor is stale or invalid for the current data and filters. Restart from the first page.'
            } -StatusCode 409 -StatusText 'Conflict'
            return
        }

        Write-JsonResponseBytes -Stream $Stream -Value @{
            generationId = $snapshot.generationId
            generatedAt  = $snapshot.generatedAt
            sort         = @{ key = $sortValue; direction = $directionValue }
            filters      = @{ search = $searchValue; serviceType = $serviceTypeValue; defenderStatus = $defenderStatusValue }
            page = @{
                pageSize = $page.PageSize; offset = $page.Offset; returned = $page.Returned; total = $page.Total
                hasNext = $page.HasNext; hasPrevious = $page.HasPrevious; nextCursor = $page.NextCursor; previousCursor = $page.PreviousCursor
            }
            instances = $page.Items
        }
    }
    catch [ArgumentException] {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = $_.Exception.Message } -StatusCode 400 -StatusText 'Bad Request'
    }
}

function Send-SqlInstanceDetail {
    param([hashtable]$SharedState, [string]$Key, [IO.Stream]$Stream)
    $snapshot = Get-RequiredSqlSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }

    $id = $snapshot.keyToInstanceId[$Key]
    if (-not $id -or -not $snapshot.instances.Contains($id)) {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'SQL instance not found in the current snapshot.' } -StatusCode 404 -StatusText 'Not Found'
        return
    }

    $instance = $snapshot.instances[$id]
    $databases = if ($snapshot.databasesByInstance.ContainsKey($id)) { @($snapshot.databasesByInstance[$id]) } else { @() }
    $patch = $snapshot.patchByHost[[string]$instance.containerResourceId]
    $hostIdLower = ([string]$instance.containerResourceId).ToLowerInvariant()
    $sqlEntityPrefix = "$hostIdLower/securityentitydata/sqlservers:$(([string]$instance.instanceName).ToLowerInvariant()):"
    $recommendations = @($snapshot.recommendations | Where-Object {
        $targetId = ([string]$_.targetId).ToLowerInvariant()
        $targetId -eq $hostIdLower -or $targetId.StartsWith($sqlEntityPrefix)
    })

    Write-JsonResponseBytes -Stream $Stream -Value @{
        generationId    = $snapshot.generationId
        generatedAt     = $snapshot.generatedAt
        instance        = $instance
        databases       = $databases
        patchAssessment = $patch
        recommendations = $recommendations
    }
}

function Send-KubernetesSummary {
    param([hashtable]$SharedState, [IO.Stream]$Stream)
    $snapshot = Get-RequiredKubernetesSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }
    Write-JsonResponseBytes -Stream $Stream -Value @{
        generationId = $snapshot.generationId
        generatedAt  = $snapshot.generatedAt
        account      = $snapshot.account
        refreshError = $SharedState.LastKubernetesError
        summary      = $snapshot.summary
    }
}

function Send-KubernetesClusterPage {
    param([hashtable]$SharedState, [hashtable]$QueryValues, [IO.Stream]$Stream)
    $snapshot = Get-RequiredKubernetesSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }

    try {
        $sortValue = Get-QueryValue $QueryValues 'sort'
        if (-not $sortValue) { $sortValue = 'name' }
        $directionValue = Get-QueryValue $QueryValues 'direction'
        if (-not $directionValue) { $directionValue = 'ascending' }
        $pageSizeValue = 100
        $rawPageSize = Get-QueryValue $QueryValues 'pageSize'
        if ($rawPageSize) {
            $parsedPageSize = 0
            if ([int]::TryParse($rawPageSize, [ref]$parsedPageSize)) { $pageSizeValue = $parsedPageSize }
        }
        $searchValue = Get-QueryValue $QueryValues 'search'
        $resourceGroupValue = Get-QueryValue $QueryValues 'resourceGroup'
        $locationValue = Get-QueryValue $QueryValues 'location'
        $healthValue = Get-QueryValue $QueryValues 'health'
        $connectivityStatusValue = Get-QueryValue $QueryValues 'connectivityStatus'
        $distributionValue = Get-QueryValue $QueryValues 'distribution'
        $infrastructureValue = Get-QueryValue $QueryValues 'infrastructure'
        $cursorValue = Get-QueryValue $QueryValues 'cursor'

        $page = Select-KubernetesClusterPage -Clusters $snapshot.clusterArray -GenerationId $snapshot.generationId `
            -Sort $sortValue -Direction $directionValue -Search $searchValue -ResourceGroup $resourceGroupValue `
            -Location $locationValue -Health $healthValue -ConnectivityStatus $connectivityStatusValue `
            -Distribution $distributionValue -Infrastructure $infrastructureValue -Cursor $cursorValue -PageSize $pageSizeValue

        if ($page.Error) {
            Write-JsonResponseBytes -Stream $Stream -Value @{
                error   = "cursor_$($page.Error)"
                message = 'The page cursor is stale or invalid for the current data and filters. Restart from the first page.'
            } -StatusCode 409 -StatusText 'Conflict'
            return
        }

        $rows = @($page.Items | ForEach-Object { ConvertTo-KubernetesClusterListRow -Cluster $_ })
        Write-JsonResponseBytes -Stream $Stream -Value @{
            generationId = $snapshot.generationId
            generatedAt  = $snapshot.generatedAt
            sort         = @{ key = $sortValue; direction = $directionValue }
            filters      = @{
                search = $searchValue; resourceGroup = $resourceGroupValue; location = $locationValue
                health = $healthValue; connectivityStatus = $connectivityStatusValue
                distribution = $distributionValue; infrastructure = $infrastructureValue
            }
            page = @{
                pageSize = $page.PageSize; offset = $page.Offset; returned = $page.Returned; total = $page.Total
                hasNext = $page.HasNext; hasPrevious = $page.HasPrevious; nextCursor = $page.NextCursor; previousCursor = $page.PreviousCursor
            }
            clusters = $rows
        }
    }
    catch [ArgumentException] {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = $_.Exception.Message } -StatusCode 400 -StatusText 'Bad Request'
    }
}

function Send-KubernetesClusterDetail {
    param([hashtable]$SharedState, [string]$Key, [IO.Stream]$Stream)
    $snapshot = Get-RequiredKubernetesSnapshot -SharedState $SharedState -Stream $Stream
    if (-not $snapshot) { return }

    $id = $snapshot.keyToClusterId[$Key]
    if (-not $id -or -not $snapshot.clusters.Contains($id)) {
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'Cluster not found in the current snapshot.' } -StatusCode 404 -StatusText 'Not Found'
        return
    }
    Write-JsonResponseBytes -Stream $Stream -Value @{
        generationId = $snapshot.generationId
        generatedAt  = $snapshot.generatedAt
        cluster      = $snapshot.clusters[$id]
    }
}

function Invoke-EnterpriseApiRequest {
    <#
    Top-level dispatcher for the bounded enterprise data APIs. Runs inside a request-handling
    RunspacePool worker (see server.ps1), so a slow or in-progress snapshot build here never
    blocks the connection-accept loop or any other in-flight request.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$SharedState,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$QueryValues,
        [Parameter(Mandatory)][IO.Stream]$Stream
    )

    try {
        if ($Method -ne 'GET') {
            Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'Method not allowed' } -StatusCode 405 -StatusText 'Method Not Allowed'
            return
        }

        switch -Regex ($Path) {
            '^/api/operations/summary$' { Send-OperationsSummary -SharedState $SharedState -Stream $Stream; return }
            '^/api/operations/servers$' { Send-ServerPage -SharedState $SharedState -QueryValues $QueryValues -Stream $Stream; return }
            '^/api/operations/servers/([a-f0-9]{16})/vm-assessment$' { Send-VmSkuAssessment -SharedState $SharedState -Key $Matches[1] -QueryValues $QueryValues -Stream $Stream; return }
            '^/api/operations/servers/([a-f0-9]{16})$' { Send-ServerDetail -SharedState $SharedState -Key $Matches[1] -Stream $Stream; return }
            '^/api/platforms/summary$' { Send-PlatformsSummary -SharedState $SharedState -Stream $Stream; return }
            '^/api/deployment/summary$' { Send-DeploymentSummary -SharedState $SharedState -Stream $Stream; return }
            '^/api/global/summary$' { Send-GlobalSummary -SharedState $SharedState -QueryValues $QueryValues -Stream $Stream; return }
            '^/api/sql/summary$' { Send-SqlSummary -SharedState $SharedState -Stream $Stream; return }
            '^/api/sql/instances$' { Send-SqlInstancePage -SharedState $SharedState -QueryValues $QueryValues -Stream $Stream; return }
            '^/api/sql/instances/([a-f0-9]{16})$' { Send-SqlInstanceDetail -SharedState $SharedState -Key $Matches[1] -Stream $Stream; return }
            '^/api/kubernetes/summary$' { Send-KubernetesSummary -SharedState $SharedState -Stream $Stream; return }
            '^/api/kubernetes/clusters$' { Send-KubernetesClusterPage -SharedState $SharedState -QueryValues $QueryValues -Stream $Stream; return }
            '^/api/kubernetes/clusters/([a-f0-9]{16})$' { Send-KubernetesClusterDetail -SharedState $SharedState -Key $Matches[1] -Stream $Stream; return }
            '^/api/operations$' { Send-LegacyOperationsSummary -SharedState $SharedState -Stream $Stream; return }
            '^/api/deployment$' { Send-DeploymentSummary -SharedState $SharedState -Stream $Stream -Legacy; return }
            '^/api/sql$' { Send-SqlSummary -SharedState $SharedState -Stream $Stream -Legacy; return }
            default {
                Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'Not found' } -StatusCode 404 -StatusText 'Not Found'
                return
            }
        }
    }
    catch {
        # Every unexpected failure is logged and returned with its real message -- never
        # silently swallowed -- so both the operator console and the API caller see the cause.
        Write-Warning "Enterprise API request failed for $Path`: $($_.Exception.Message)"
        try {
            Write-JsonResponseBytes -Stream $Stream -Value @{ error = $_.Exception.Message } -StatusCode 500 -StatusText 'Internal Server Error'
        }
        catch {
            Write-Warning "Failed to write error response for $Path`: $($_.Exception.Message)"
        }
    }
}
# endregion Enterprise API request handling

Export-ModuleMember -Function *
