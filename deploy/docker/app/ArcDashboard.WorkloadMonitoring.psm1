$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ArcDashboard.Monitoring.psm1') -ErrorAction Stop

$script:MaximumWorkloadServers = 10
$script:MaximumWorkloadMinutes = 480
$script:MaximumWorkloadObservations = 480
$script:WorkloadRetentionHours = 24

function Restore-WorkloadMonitoringSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $plainText = Unprotect-MonitoringPayload -ProtectedText ([IO.File]::ReadAllText($Path))
        $snapshot = $plainText | ConvertFrom-Json -AsHashtable
        if (-not $snapshot.sessionId -or [string]$snapshot.kind -ne 'workload' -or
            -not @($snapshot.serverKeys).Count -or -not $snapshot.startedAt) {
            throw [IO.InvalidDataException]::new('The workload monitoring snapshot is incomplete.')
        }
        $retentionAnchor = if ($snapshot.completedAt) {
            [datetime]$snapshot.completedAt
        }
        elseif ($snapshot.activeUntil) {
            [datetime]$snapshot.activeUntil
        }
        else {
            [datetime]$snapshot.startedAt
        }
        if ($retentionAnchor.ToUniversalTime() -lt (Get-Date).ToUniversalTime().AddHours(-$script:WorkloadRetentionHours)) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            return $null
        }
        return $snapshot
    }
    catch {
        Write-Warning "Encrypted workload monitoring snapshot could not be restored and was removed: $($_.Exception.Message)"
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function ConvertTo-WorkloadServerObservation {
    param([Parameter(Mandatory)][object]$Server)

    return [ordered]@{
        key = [string]$Server.key
        name = [string]$Server.name
        resourceGroup = [string]$Server.resourceGroup
        location = [string]$Server.location
        osType = [string]$Server.osType
        health = [string]$Server.health
        arcStatus = [string]$Server.arcStatus
        lastHeartbeat = [string]$Server.lastHeartbeat
        logicalCpuCores = $Server.logicalCpuCores
        cpuCores = $Server.cpuCores
        totalMemoryBytes = $Server.totalMemoryBytes
        totalStorageBytes = $Server.totalStorageBytes
        cpuPercent = $Server.cpuPercent
        memoryPercent = $Server.memoryPercent
        diskFreePercent = $Server.diskFreePercent
        diskIops = $Server.diskIops
        diskBytesPerSec = $Server.diskBytesPerSec
        networkBytesPerSec = $Server.networkBytesPerSec
        activeAlerts = [int]$Server.activeAlerts
        criticalAlerts = [int]$Server.criticalAlerts
        warningAlerts = [int]$Server.warningAlerts
        pendingUpdates = [int]$Server.pendingUpdates
        criticalUpdates = [int]$Server.criticalUpdates
        securityUpdates = [int]$Server.securityUpdates
        rebootPending = [bool]$Server.rebootPending
        lastAssessment = [string]$Server.lastAssessment
        lifecycleState = [string]$Server.lifecycleState
    }
}

function New-WorkloadObservation {
    param(
        [Parameter(Mandatory)][object]$OperationsSnapshot,
        [Parameter(Mandatory)][array]$ResourceIds
    )

    $servers = @($ResourceIds | ForEach-Object {
        $server = $OperationsSnapshot.servers[$_]
        if ($server) { ConvertTo-WorkloadServerObservation -Server $server }
    })
    return [ordered]@{
        time = if ($OperationsSnapshot.generatedAt) {
            ([datetime]$OperationsSnapshot.generatedAt).ToUniversalTime().ToString('o')
        } else {
            (Get-Date).ToUniversalTime().ToString('o')
        }
        servers = $servers
    }
}

function Get-WorkloadBaseline {
    param([AllowEmptyCollection()][array]$Observations)

    $rows = @($Observations | ForEach-Object { @($_.servers) })
    return [ordered]@{
        observationCount = @($Observations).Count
        serverCount = @($rows | ForEach-Object { [string]$_['key'] } | Select-Object -Unique).Count
        healthCounts = @($rows | Group-Object health | ForEach-Object {
            [ordered]@{ health = [string]$_.Name; count = $_.Count }
        })
        alertingServers = @($rows | Where-Object { [int]$_.activeAlerts -gt 0 } | ForEach-Object { [string]$_['key'] } | Select-Object -Unique).Count
        updatingServers = @($rows | Where-Object { [int]$_.pendingUpdates -gt 0 } | ForEach-Object { [string]$_['key'] } | Select-Object -Unique).Count
        rebootPendingServers = @($rows | Where-Object rebootPending | ForEach-Object { [string]$_['key'] } | Select-Object -Unique).Count
    }
}

function Remove-WorkloadMonitoringSnapshot {
    param([Parameter(Mandatory)][hashtable]$SharedState)

    $SharedState.WorkloadStateGate.Wait()
    try {
        $SharedState.WorkloadGeneration = [long]$SharedState.WorkloadGeneration + 1
        $SharedState.WorkloadSnapshot = $null
        $SharedState.WorkloadCollectionRequested = $false
        $SharedState.WorkloadLastError = $null
        Remove-Item -LiteralPath $SharedState.WorkloadStorePath -Force -ErrorAction SilentlyContinue
    }
    finally {
        [void]$SharedState.WorkloadStateGate.Release()
    }
}

function Test-WorkloadMonitoringScope {
    param(
        [object]$Snapshot,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if (-not $Snapshot -or [string]$Snapshot.subscriptionId -ne [string]$Config.SubscriptionId) {
        return $false
    }
    $latest = @($Snapshot.observations | Sort-Object time | Select-Object -Last 1)
    return -not $latest.Count -or -not @($latest[0].servers | Where-Object {
        [string]$_.resourceGroup -notin @($Config.ResourceGroups)
    }).Count
}

function Publish-WorkloadMonitoringSnapshot {
    param(
        [Parameter(Mandatory)][hashtable]$SharedState,
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][long]$ExpectedGeneration
    )

    $SharedState.WorkloadStateGate.Wait()
    try {
        $current = $SharedState.WorkloadSnapshot
        if (-not $current -or [long]$SharedState.WorkloadGeneration -ne $ExpectedGeneration -or
            [string]$current.sessionId -ne [string]$Snapshot.sessionId) {
            return $false
        }
        $SharedState.WorkloadSnapshot = $Snapshot
        Save-MonitoringSnapshot -Snapshot $Snapshot -Path $SharedState.WorkloadStorePath
        return $true
    }
    finally {
        [void]$SharedState.WorkloadStateGate.Release()
    }
}

function New-WorkloadMonitoringSession {
    param(
        [Parameter(Mandatory)][hashtable]$SharedState,
        [Parameter(Mandatory)][array]$ServerKeys,
        [ValidateRange(15, 480)][int]$DurationMinutes = 120
    )

    $configVersion = [long]$SharedState.ConfigVersion
    $expectedGeneration = [long]$SharedState.WorkloadGeneration
    $subscriptionId = [string]$SharedState.Config.SubscriptionId
    $resourceGroups = @($SharedState.Config.ResourceGroups)
    $keys = @($ServerKeys | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Select-Object -Unique)
    if ($keys.Count -lt 1 -or $keys.Count -gt $script:MaximumWorkloadServers -or
        @($keys | Where-Object { $_ -notmatch '^[a-f0-9]{16}$' }).Count) {
        throw [ArgumentException]::new('Select between 1 and 10 valid Arc servers before starting workload monitoring.')
    }

    $snapshotResult = Get-OperationsSnapshotOrBuild -SharedState $SharedState
    if ($snapshotResult.Building) {
        $exception = [InvalidOperationException]::new('Arc inventory is still loading. Retry shortly.')
        $exception.Data['StatusCode'] = 503
        throw $exception
    }
    if ($snapshotResult.Error -or -not $snapshotResult.Snapshot) {
        throw [InvalidOperationException]::new([string]$snapshotResult.Error)
    }

    $resourceIds = @($keys | ForEach-Object {
        $resourceId = $snapshotResult.Snapshot.keyToId[$_]
        if (-not $resourceId) {
            $exception = [ArgumentException]::new('One or more selected servers are outside the current dashboard scope.')
            $exception.Data['StatusCode'] = 404
            throw $exception
        }
        $server = $snapshotResult.Snapshot.servers[$resourceId]
        if (-not $server -or [string]$server.resourceGroup -notin $resourceGroups) {
            $exception = [ArgumentException]::new('One or more selected servers are outside the current dashboard scope.')
            $exception.Data['StatusCode'] = 404
            throw $exception
        }
        if ([string]$server.arcStatus -ne 'Connected') {
            $exception = [InvalidOperationException]::new("Server '$($server.name)' is not currently connected to Azure Arc.")
            $exception.Data['StatusCode'] = 409
            throw $exception
        }
        [string]$resourceId
    })
    $now = (Get-Date).ToUniversalTime()
    $observation = New-WorkloadObservation -OperationsSnapshot $snapshotResult.Snapshot -ResourceIds $resourceIds
    $snapshot = [ordered]@{
        version = 1
        kind = 'workload'
        sessionId = [guid]::NewGuid().ToString()
        state = 'active'
        subscriptionId = $subscriptionId
        serverKeys = $keys
        resourceIds = $resourceIds
        startedAt = $now.ToString('o')
        activeUntil = $now.AddMinutes($DurationMinutes).ToString('o')
        completedAt = $null
        windowMinutes = $DurationMinutes
        lastCollectedAt = $now.ToString('o')
        lastError = $null
        observations = @($observation)
        baseline = Get-WorkloadBaseline -Observations @($observation)
    }

    $SharedState.WorkloadStateGate.Wait()
    try {
        if ([long]$SharedState.ConfigVersion -ne $configVersion -or
            [long]$SharedState.WorkloadGeneration -ne $expectedGeneration -or
            [string]$SharedState.Config.SubscriptionId -ne $subscriptionId) {
            $exception = [InvalidOperationException]::new('Dashboard scope or workload session changed before monitoring could start. Retry with the current scope.')
            $exception.Data['StatusCode'] = 409
            throw $exception
        }
        $SharedState.WorkloadGeneration = [long]$SharedState.WorkloadGeneration + 1
        $snapshot.generation = [long]$SharedState.WorkloadGeneration
        $SharedState.WorkloadSnapshot = $snapshot
        $SharedState.WorkloadCollectionRequested = $false
        $SharedState.WorkloadLastError = $null
        Save-MonitoringSnapshot -Snapshot $snapshot -Path $SharedState.WorkloadStorePath
    }
    finally {
        [void]$SharedState.WorkloadStateGate.Release()
    }
    return $snapshot
}

function Update-WorkloadMonitoringSession {
    param([Parameter(Mandatory)][hashtable]$SharedState)

    if (-not $SharedState.WorkloadGate.Wait(0)) { return }
    $current = $null
    $generation = [long]-1
    try {
        $current = $SharedState.WorkloadSnapshot
        if (-not $current -or [string]$current.state -ne 'active') { return }
        $generation = [long]$current.generation
        $now = (Get-Date).ToUniversalTime()
        if (([datetime]$current.activeUntil).ToUniversalTime() -le $now) {
            $completed = $current | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
            $completed.state = 'completed'
            $completed.completedAt = ([datetime]$current.activeUntil).ToUniversalTime().ToString('o')
            $SharedState.WorkloadCollectionRequested = $false
            Publish-WorkloadMonitoringSnapshot -SharedState $SharedState -Snapshot $completed -ExpectedGeneration $generation
            return
        }

        $operationsResult = Get-OperationsSnapshotOrBuild -SharedState $SharedState
        if ($operationsResult.Building) {
            $deferred = $current | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
            $deferred.nextAttemptAt = $now.AddSeconds(10).ToString('o')
            Publish-WorkloadMonitoringSnapshot -SharedState $SharedState -Snapshot $deferred -ExpectedGeneration $generation
            return
        }
        if ($operationsResult.Error -or -not $operationsResult.Snapshot) {
            throw [InvalidOperationException]::new([string]$operationsResult.Error)
        }

        $resourceIds = @($current.serverKeys | ForEach-Object {
            $resourceId = $operationsResult.Snapshot.keyToId[[string]$_]
            if (-not $resourceId) {
                throw [InvalidOperationException]::new('A monitored workload server is no longer in the configured dashboard scope.')
            }
            [string]$resourceId
        })
        $observation = New-WorkloadObservation -OperationsSnapshot $operationsResult.Snapshot -ResourceIds $resourceIds
        $next = $current | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
        $existingTimes = @($next.observations | ForEach-Object { ([datetime]$_.time).ToUniversalTime().ToString('o') })
        $observationTime = ([datetime]$observation.time).ToUniversalTime().ToString('o')
        if ($observationTime -in $existingTimes) {
            if ($SharedState.RefreshSignal) {
                $SharedState.RefreshSignal.Requested = $true
            }
            else {
                $SharedState.ForceRefresh = $true
            }
            $next.nextAttemptAt = $now.AddSeconds(10).ToString('o')
            $next.lastCollectedAt = ([datetime]$current.lastCollectedAt).ToUniversalTime().ToString('o')
            $null = Publish-WorkloadMonitoringSnapshot -SharedState $SharedState -Snapshot $next -ExpectedGeneration $generation
            return
        }
        $next.observations = @(@($next.observations) + $observation |
            Sort-Object time -Descending | Select-Object -First $script:MaximumWorkloadObservations | Sort-Object time)
        $next.resourceIds = $resourceIds
        $next.lastCollectedAt = $now.ToString('o')
        $next.nextAttemptAt = $null
        $next.lastError = $null
        $next.baseline = Get-WorkloadBaseline -Observations @($next.observations)
        $SharedState.WorkloadCollectionRequested = $false
        if (Publish-WorkloadMonitoringSnapshot -SharedState $SharedState -Snapshot $next -ExpectedGeneration $generation) {
            $SharedState.WorkloadLastError = $null
        }
    }
    catch {
        $SharedState.WorkloadLastError = $_.Exception.Message
        Write-Warning "Workload monitoring collection failed: $($_.Exception.Message)"
        if ($current) {
            $failed = $current | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
            $failed.lastError = $_.Exception.Message
            $failed.nextAttemptAt = (Get-Date).ToUniversalTime().AddSeconds(60).ToString('o')
            Publish-WorkloadMonitoringSnapshot -SharedState $SharedState -Snapshot $failed -ExpectedGeneration $generation
        }
    }
    finally {
        [void]$SharedState.WorkloadGate.Release()
    }
}

function Start-WorkloadMonitoringLoop {
    param(
        [Parameter(Mandatory)][hashtable]$SharedState,
        [ValidateRange(30, 300)][int]$IntervalSeconds = 60
    )

    while (-not $SharedState.ShutdownRequested) {
        $targets = @($SharedState)
        if ($SharedState.UserStates -and $SharedState.UserStates.Count -gt 0) {
            [Threading.Monitor]::Enter($SharedState.UserStates.SyncRoot)
            try {
                $targets = @($SharedState.UserStates.Values)
            }
            finally {
                [Threading.Monitor]::Exit($SharedState.UserStates.SyncRoot)
            }
        }
        foreach ($target in $targets) {
            if ($target.Disabled) {
                continue
            }
            try {
                if ($target -ne $SharedState) {
                    $target.Config = $SharedState.Config
                    $target.ConfigVersion = $SharedState.ConfigVersion
                    $target.OperationsSnapshot = $SharedState.OperationsSnapshot
                }
                $session = $target.WorkloadSnapshot
                if ($session -and [string]$session.state -eq 'active') {
                    $now = (Get-Date).ToUniversalTime()
                    $retryDue = -not $session.nextAttemptAt -or ([datetime]$session.nextAttemptAt).ToUniversalTime() -le $now
                    $due = $retryDue -and (
                        $target.WorkloadCollectionRequested -or -not $session.lastCollectedAt -or
                        ([datetime]$session.lastCollectedAt).ToUniversalTime().AddSeconds($IntervalSeconds) -le $now
                    )
                    if ($due) { Update-WorkloadMonitoringSession -SharedState $target }
                }
            }
            catch {
                $target.WorkloadLastError = $_.Exception.Message
                Write-Warning "Workload monitoring loop error: $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 2
    }
}

function ConvertTo-WorkloadMonitoringStatus {
    param([object]$Snapshot, [string]$RuntimeError)

    if (-not $Snapshot) {
        return @{
            exists = $false
            state = 'none'
            lastError = if ($RuntimeError) { 'Workload collection failed. Review the dashboard console for details.' } else { $null }
        }
    }
    $latest = @($Snapshot.observations | Sort-Object time | Select-Object -Last 1)
    return [ordered]@{
        exists = $true
        sessionId = [string]$Snapshot.sessionId
        state = [string]$Snapshot.state
        startedAt = [string]$Snapshot.startedAt
        activeUntil = [string]$Snapshot.activeUntil
        completedAt = [string]$Snapshot.completedAt
        windowMinutes = [int]$Snapshot.windowMinutes
        lastCollectedAt = [string]$Snapshot.lastCollectedAt
        lastError = if ($Snapshot.lastError -or $RuntimeError) { 'Workload collection failed. Review the dashboard console for details.' } else { $null }
        serverCount = @($Snapshot.serverKeys).Count
        observationCount = @($Snapshot.observations).Count
        servers = if ($latest.Count) { @($latest[0].servers | ForEach-Object {
            [ordered]@{
                key = [string]$_.key
                name = [string]$_.name
                resourceGroup = [string]$_.resourceGroup
                location = [string]$_.location
                osType = [string]$_.osType
            }
        }) } else { @() }
        baseline = $Snapshot.baseline
    }
}

function ConvertTo-WorkloadMonitoringDetail {
    param([object]$Snapshot, [string]$RuntimeError)

    $status = ConvertTo-WorkloadMonitoringStatus -Snapshot $Snapshot -RuntimeError $RuntimeError
    if (-not $Snapshot) {
        return [ordered]@{ status = $status; observations = @() }
    }
    return [ordered]@{
        status = $status
        observations = @($Snapshot.observations | Sort-Object time -Descending |
            Select-Object -First $script:MaximumWorkloadObservations | Sort-Object time | ForEach-Object {
                [ordered]@{
                    time = [string]$_.time
                    servers = @($_.servers | ForEach-Object {
                        [ordered]@{
                            key = [string]$_.key
                            name = [string]$_.name
                            resourceGroup = [string]$_.resourceGroup
                            location = [string]$_.location
                            osType = [string]$_.osType
                            health = [string]$_.health
                            arcStatus = [string]$_.arcStatus
                            lastHeartbeat = [string]$_.lastHeartbeat
                            logicalCpuCores = $_.logicalCpuCores
                            cpuCores = $_.cpuCores
                            totalMemoryBytes = $_.totalMemoryBytes
                            totalStorageBytes = $_.totalStorageBytes
                            cpuPercent = $_.cpuPercent
                            memoryPercent = $_.memoryPercent
                            diskFreePercent = $_.diskFreePercent
                            diskIops = $_.diskIops
                            diskBytesPerSec = $_.diskBytesPerSec
                            networkBytesPerSec = $_.networkBytesPerSec
                            activeAlerts = [int]$_.activeAlerts
                            criticalAlerts = [int]$_.criticalAlerts
                            warningAlerts = [int]$_.warningAlerts
                            pendingUpdates = [int]$_.pendingUpdates
                            criticalUpdates = [int]$_.criticalUpdates
                            securityUpdates = [int]$_.securityUpdates
                            rebootPending = [bool]$_.rebootPending
                            lastAssessment = [string]$_.lastAssessment
                            lifecycleState = [string]$_.lifecycleState
                        }
                    })
                }
            })
    }
}

function Stop-WorkloadMonitoringSession {
    param([Parameter(Mandatory)][hashtable]$SharedState)

    $SharedState.WorkloadStateGate.Wait()
    try {
        if (-not $SharedState.WorkloadSnapshot) { return $null }
        $stopped = $SharedState.WorkloadSnapshot | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
        if ([string]$stopped.state -eq 'active') {
            $SharedState.WorkloadGeneration = [long]$SharedState.WorkloadGeneration + 1
            $stopped.generation = [long]$SharedState.WorkloadGeneration
            $stopped.state = 'stopped'
            $stopped.completedAt = (Get-Date).ToUniversalTime().ToString('o')
            $SharedState.WorkloadSnapshot = $stopped
            $SharedState.WorkloadCollectionRequested = $false
            Save-MonitoringSnapshot -Snapshot $stopped -Path $SharedState.WorkloadStorePath
        }
        return $stopped
    }
    finally {
        [void]$SharedState.WorkloadStateGate.Release()
    }
}

function Invoke-WorkloadMonitoringApiRequest {
    param(
        [Parameter(Mandatory)][hashtable]$SharedState,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][IO.Stream]$Stream
    )

    try {
        switch ("$Method $Path") {
            'GET /api/workload-monitoring/session' {
                $snapshot = if (Test-WorkloadMonitoringScope -Snapshot $SharedState.WorkloadSnapshot -Config $SharedState.Config) { $SharedState.WorkloadSnapshot } else { $null }
                Write-JsonResponseBytes -Stream $Stream -Value (ConvertTo-WorkloadMonitoringStatus -Snapshot $snapshot -RuntimeError $SharedState.WorkloadLastError)
                return
            }
            'GET /api/workload-monitoring/session/detail' {
                $snapshot = if (Test-WorkloadMonitoringScope -Snapshot $SharedState.WorkloadSnapshot -Config $SharedState.Config) { $SharedState.WorkloadSnapshot } else { $null }
                Write-JsonResponseBytes -Stream $Stream -Value (ConvertTo-WorkloadMonitoringDetail -Snapshot $snapshot -RuntimeError $SharedState.WorkloadLastError)
                return
            }
            'POST /api/workload-monitoring/session' {
                if (-not $Body) { throw [ArgumentException]::new('Request body is required.') }
                $request = $Body | ConvertFrom-Json
                $duration = 120
                if ($null -ne $request.durationMinutes -and
                    (-not [int]::TryParse([string]$request.durationMinutes, [ref]$duration) -or $duration -lt 15 -or $duration -gt 480)) {
                    throw [ArgumentException]::new('Workload monitoring duration must be between 15 and 480 minutes.')
                }
                $snapshot = New-WorkloadMonitoringSession -SharedState $SharedState -ServerKeys @($request.serverKeys) -DurationMinutes $duration
                Write-JsonResponseBytes -Stream $Stream -Value (ConvertTo-WorkloadMonitoringStatus -Snapshot $snapshot -RuntimeError $SharedState.WorkloadLastError) -StatusCode 201 -StatusText 'Created'
                return
            }
            'POST /api/workload-monitoring/session/refresh' {
                if (-not (Test-WorkloadMonitoringScope -Snapshot $SharedState.WorkloadSnapshot -Config $SharedState.Config)) {
                    Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'No workload monitoring session exists.' } -StatusCode 404 -StatusText 'Not Found'
                    return
                }
                $requestedAt = (Get-Date).ToUniversalTime().ToString('o')
                $SharedState.WorkloadCollectionRequested = $true
                if ($SharedState.RefreshSignal) {
                    $SharedState.RefreshSignal.Requested = $true
                }
                else {
                    $SharedState.ForceRefresh = $true
                }
                $status = ConvertTo-WorkloadMonitoringStatus -Snapshot $SharedState.WorkloadSnapshot -RuntimeError $SharedState.WorkloadLastError
                $status['collectionRequestedAt'] = $requestedAt
                Write-JsonResponseBytes -Stream $Stream -Value $status
                return
            }
            'POST /api/workload-monitoring/session/stop' {
                if (-not (Test-WorkloadMonitoringScope -Snapshot $SharedState.WorkloadSnapshot -Config $SharedState.Config)) {
                    Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'No workload monitoring session exists.' } -StatusCode 404 -StatusText 'Not Found'
                    return
                }
                $snapshot = Stop-WorkloadMonitoringSession -SharedState $SharedState
                Write-JsonResponseBytes -Stream $Stream -Value (ConvertTo-WorkloadMonitoringStatus -Snapshot $snapshot -RuntimeError $SharedState.WorkloadLastError)
                return
            }
            'DELETE /api/workload-monitoring/session' {
                Remove-WorkloadMonitoringSnapshot -SharedState $SharedState
                Write-JsonResponseBytes -Stream $Stream -Value @{ deleted = $true; exists = $false; state = 'none' }
                return
            }
            default {
                Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'Not found' } -StatusCode 404 -StatusText 'Not Found'
                return
            }
        }
    }
    catch {
        $statusCode = if ($_.Exception.Data['StatusCode']) { [int]$_.Exception.Data['StatusCode'] } elseif ($_.Exception -is [ArgumentException]) { 400 } else { 500 }
        $statusText = switch ($statusCode) { 400 { 'Bad Request' } 404 { 'Not Found' } 503 { 'Service Unavailable' } default { 'Internal Server Error' } }
        Write-JsonResponseBytes -Stream $Stream -Value @{ error = $_.Exception.Message } -StatusCode $statusCode -StatusText $statusText
    }
}

Export-ModuleMember -Function *
