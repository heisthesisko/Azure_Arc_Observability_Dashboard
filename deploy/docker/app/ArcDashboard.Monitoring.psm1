$ErrorActionPreference = 'Stop'

$script:MaximumMonitoringMinutes = 480
$script:MaximumMetricRows = 12000
$script:MaximumEventRows = 1000
$script:MaximumObservationRows = 480
$script:MonitoringRetentionHours = 24
$dataRoot = if ($env:ARC_DASHBOARD_DATA_ROOT) {
    [IO.Path]::GetFullPath($env:ARC_DASHBOARD_DATA_ROOT)
}
else {
    $PSScriptRoot
}
$script:LinuxMasterKeyPath = Join-Path (Join-Path $dataRoot '.secrets') 'master.key'
Import-Module (Join-Path $PSScriptRoot 'ArcDashboard.Security.psm1') -ErrorAction Stop

function Protect-MonitoringPayload {
    param([Parameter(Mandatory)][string]$PlainText)

    return Protect-LinuxDashboardPayload -PlainText $PlainText `
        -KeyPath $script:LinuxMasterKeyPath -Purpose 'monitoring'
}

function Unprotect-MonitoringPayload {
    param([Parameter(Mandatory)][string]$ProtectedText)

    return Unprotect-LinuxDashboardPayload -ProtectedText $ProtectedText `
        -KeyPath $script:LinuxMasterKeyPath -Purpose 'monitoring'
}

function Save-MonitoringSnapshot {
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Set-LinuxPrivateDirectoryPermissions -Path $directory
    $plainText = $Snapshot | ConvertTo-Json -Depth 15 -Compress
    $protectedText = Protect-MonitoringPayload -PlainText $plainText
    $temporaryPath = Join-Path $directory ([IO.Path]::GetRandomFileName())
    try {
        Write-LinuxPrivateTextFile -Path $temporaryPath -Text $protectedText
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
    Set-LinuxPrivateFilePermissions -Path $Path
}

function Restore-MonitoringSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $plainText = Unprotect-MonitoringPayload -ProtectedText ([IO.File]::ReadAllText($Path))
        $snapshot = $plainText | ConvertFrom-Json -AsHashtable
        if (-not $snapshot.sessionId -or -not $snapshot.server -or -not $snapshot.startedAt) {
            throw [IO.InvalidDataException]::new('The monitoring snapshot is incomplete.')
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
        if ($retentionAnchor.ToUniversalTime() -lt (Get-Date).ToUniversalTime().AddHours(-$script:MonitoringRetentionHours)) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            return $null
        }
        return $snapshot
    }
    catch {
        Write-Warning "Encrypted monitoring snapshot could not be restored and was removed: $($_.Exception.Message)"
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Remove-MonitoringSnapshot {
    param([Parameter(Mandatory)][hashtable]$SharedState)

    $SharedState.MonitoringStateGate.Wait()
    try {
        $SharedState.MonitoringGeneration = [long]$SharedState.MonitoringGeneration + 1
        $SharedState.MonitoringSnapshot = $null
        $SharedState.MonitoringCollectionRequested = $false
        $SharedState.MonitoringLastError = $null
        Remove-Item -LiteralPath $SharedState.MonitoringStorePath -Force -ErrorAction SilentlyContinue
        $directory = Split-Path -Parent $SharedState.MonitoringStorePath
        if ((Test-Path -LiteralPath $directory) -and -not (Get-ChildItem -LiteralPath $directory -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        [void]$SharedState.MonitoringStateGate.Release()
    }
}

function Protect-MonitoringEventMessage {
    param([AllowEmptyString()][string]$Message)

    $value = ($Message -replace '[\u0000-\u0008\u000B\u000C\u000E-\u001F]', ' ').Trim()
    $value = $value -replace '(?i)\bauthorization\s*:\s*(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+', 'Authorization: [REDACTED]'
    $value = $value -replace '(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer [REDACTED]'
    $value = $value -replace "(?i)\b(password|passwd|pwd|secret|clientsecret|token|api[-_]?key|accesskey|sharedaccesssignature|sig|connectionstring)\s*[:=]\s*(?:`"[^`"]*`"|'[^']*'|[^\s;,]+)", '$1=[REDACTED]'
    if ($value.Length -gt 500) { return $value.Substring(0, 500) }
    return $value
}

function Get-MonitoringQuery {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][ValidateRange(15, 480)][int]$WindowMinutes
    )

    $escapedResourceId = $ResourceId.Replace("'", "''")
    return @"
let targetResourceId = '$escapedResourceId';
union isfuzzy=true
(
    Heartbeat
    | where TimeGenerated >= ago(${WindowMinutes}m) and _ResourceId =~ targetResourceId
    | order by TimeGenerated desc
    | take 480
    | project timestamp=TimeGenerated, recordType='event', metric='', value=real(null), unit='',
              severity='Information', category='connectivity', source='Heartbeat',
              message=strcat('Heartbeat received from ', Computer)
),
(
    Perf
    | where TimeGenerated >= ago(${WindowMinutes}m) and _ResourceId =~ targetResourceId
    | where CounterName in (
        '% Processor Time', '% Committed Bytes In Use', '% Free Space', 'Bytes Total/sec',
        'Disk Reads/sec', 'Disk Writes/sec', 'Disk Read Bytes/sec', 'Disk Write Bytes/sec',
        'Avg. Disk sec/Read', 'Avg. Disk sec/Write', 'Current Disk Queue Length')
    | where CounterName in ('% Processor Time', '% Committed Bytes In Use', 'Bytes Total/sec')
        or ObjectName in ('LogicalDisk', 'Logical Disk')
    | where InstanceName !in ('_Total', '_total')
        or CounterName !in (
            '% Free Space', 'Bytes Total/sec', 'Disk Reads/sec', 'Disk Writes/sec',
            'Disk Read Bytes/sec', 'Disk Write Bytes/sec', 'Avg. Disk sec/Read',
            'Avg. Disk sec/Write', 'Current Disk Queue Length')
    | summarize instanceValue=avg(CounterValue) by bin(TimeGenerated, 1m), CounterName, InstanceName
    | summarize averageValue=avg(instanceValue), totalValue=sum(instanceValue) by TimeGenerated, CounterName
    | order by TimeGenerated desc
    | take 6000
    | extend metric=case(
        CounterName == '% Processor Time', 'cpuPercent',
        CounterName == '% Committed Bytes In Use', 'memoryPercent',
        CounterName == '% Free Space', 'diskFreePercent',
        CounterName == 'Bytes Total/sec', 'networkBytesPerSec',
        CounterName == 'Disk Reads/sec', 'diskReadIops',
        CounterName == 'Disk Writes/sec', 'diskWriteIops',
        CounterName == 'Disk Read Bytes/sec', 'diskReadBytesPerSec',
        CounterName == 'Disk Write Bytes/sec', 'diskWriteBytesPerSec',
        CounterName == 'Avg. Disk sec/Read', 'diskReadLatencyMs',
        CounterName == 'Avg. Disk sec/Write', 'diskWriteLatencyMs',
        'diskQueueLength')
    | extend value=case(
        metric in ('networkBytesPerSec', 'diskReadIops', 'diskWriteIops', 'diskReadBytesPerSec',
                   'diskWriteBytesPerSec', 'diskQueueLength'), totalValue,
        metric in ('diskReadLatencyMs', 'diskWriteLatencyMs'), averageValue * 1000.0,
        averageValue)
    | extend unit=case(
        metric in ('cpuPercent', 'memoryPercent', 'diskFreePercent'), 'percent',
        metric in ('diskReadIops', 'diskWriteIops'), 'operationsPerSecond',
        metric in ('diskReadLatencyMs', 'diskWriteLatencyMs'), 'milliseconds',
        metric == 'diskQueueLength', 'count',
        'bytesPerSecond')
    | project timestamp=TimeGenerated, recordType='metric', metric, value=todouble(value), unit,
              severity='', category='performance', source='Perf', message=''
),
(
    InsightsMetrics
    | where TimeGenerated >= ago(${WindowMinutes}m) and _ResourceId =~ targetResourceId
    | where (Namespace == 'Processor' and Name == 'UtilizationPercentage')
        or (Namespace == 'Memory' and Name == 'AvailableMB')
        or (Namespace == 'LogicalDisk' and Name == 'FreeSpacePercentage')
        or (Namespace == 'LogicalDisk' and Name in (
            'ReadOperationsPerSecond', 'ReadsPerSecond', 'WriteOperationsPerSecond', 'WritesPerSecond',
            'ReadBytesPerSecond', 'WriteBytesPerSecond', 'AverageReadMilliseconds',
            'AverageWriteMilliseconds', 'ReadLatencyMs', 'WriteLatencyMs',
            'CurrentQueueLength', 'CurrentDiskQueueLength'))
        or (Namespace == 'Network' and Name in ('ReadBytesPerSecond', 'WriteBytesPerSecond'))
    | extend diskMountId=tostring(parse_json(Tags)['vm.azm.ms/mountId'])
    | where Namespace != 'LogicalDisk' or diskMountId !in ('_Total', '_total')
    | extend metric=case(
        Namespace == 'Processor', 'cpuPercent',
        Namespace == 'Memory', 'memoryAvailableMB',
        Namespace == 'LogicalDisk' and Name == 'FreeSpacePercentage', 'diskFreePercent',
        Name in ('ReadOperationsPerSecond', 'ReadsPerSecond'), 'diskReadIops',
        Name in ('WriteOperationsPerSecond', 'WritesPerSecond'), 'diskWriteIops',
        Namespace == 'LogicalDisk' and Name == 'ReadBytesPerSecond', 'diskReadBytesPerSec',
        Namespace == 'LogicalDisk' and Name == 'WriteBytesPerSecond', 'diskWriteBytesPerSec',
        Name in ('AverageReadMilliseconds', 'ReadLatencyMs'), 'diskReadLatencyMs',
        Name in ('AverageWriteMilliseconds', 'WriteLatencyMs'), 'diskWriteLatencyMs',
        Name in ('CurrentQueueLength', 'CurrentDiskQueueLength'), 'diskQueueLength',
        Name in ('ReadBytesPerSecond', 'WriteBytesPerSecond'), 'networkBytesPerSec',
        Name)
    | extend unit=case(
        metric in ('cpuPercent', 'diskFreePercent'), 'percent',
        metric == 'memoryAvailableMB', 'megabytes',
        metric in ('diskReadIops', 'diskWriteIops'), 'operationsPerSecond',
        metric in ('diskReadLatencyMs', 'diskWriteLatencyMs'), 'milliseconds',
        metric == 'diskQueueLength', 'count',
        'bytesPerSecond')
    | summarize instanceValue=avg(todouble(Val)) by bin(TimeGenerated, 1m), metric, unit, Name, dimension=tostring(Tags)
    | summarize averageValue=avg(instanceValue), totalValue=sum(instanceValue) by TimeGenerated, metric, unit
    | extend value=iff(
        metric in ('networkBytesPerSec', 'diskReadIops', 'diskWriteIops', 'diskReadBytesPerSec',
                   'diskWriteBytesPerSec', 'diskQueueLength'),
        totalValue, averageValue)
    | order by TimeGenerated desc
    | take 6000
    | project timestamp=TimeGenerated, recordType='metric', metric, value, unit,
              severity='', category='performance', source='InsightsMetrics', message=''
),
(
    Event
    | where TimeGenerated >= ago(${WindowMinutes}m) and _ResourceId =~ targetResourceId
    | order by TimeGenerated desc
    | take 1000
    | project timestamp=TimeGenerated, recordType='event', metric='', value=real(null), unit='',
              severity=coalesce(EventLevelName, 'Information'), category='windowsEvent',
              source=coalesce(Source, 'Windows Event'), message=substring(RenderedDescription, 0, 500)
),
(
    Syslog
    | where TimeGenerated >= ago(${WindowMinutes}m) and _ResourceId =~ targetResourceId
    | order by TimeGenerated desc
    | take 1000
    | project timestamp=TimeGenerated, recordType='event', metric='', value=real(null), unit='',
              severity=coalesce(SeverityLevel, 'Information'), category='syslog',
              source=coalesce(Facility, 'Syslog'), message=substring(SyslogMessage, 0, 500)
)
| order by timestamp desc
| take 15000
"@
}

function Get-MonitoringBaseline {
    param(
        [AllowEmptyCollection()][array]$Metrics,
        [AllowEmptyCollection()][array]$Events,
        [AllowEmptyCollection()][array]$Observations
    )

    $metricSummaries = @($Metrics | Group-Object { "$($_.metric)|$($_.unit)|$($_.source)" } | ForEach-Object {
        $values = @($_.Group | ForEach-Object { [double]$_.value } | Sort-Object)
        if (-not $values.Count) { return }
        $percentileIndex = [Math]::Min($values.Count - 1, [Math]::Ceiling($values.Count * 0.95) - 1)
        [ordered]@{
            metric = [string]$_.Group[0].metric
            samples = $values.Count
            minimum = [Math]::Round([double]$values[0], 2)
            average = [Math]::Round([double](($values | Measure-Object -Average).Average), 2)
            p95 = [Math]::Round([double]$values[$percentileIndex], 2)
            maximum = [Math]::Round([double]$values[-1], 2)
            unit = [string]$_.Group[0].unit
            source = [string]$_.Group[0].source
        }
    })
    $latest = @($Observations | Sort-Object time | Select-Object -Last 1)
    return [ordered]@{
        metrics = $metricSummaries
        eventCounts = @($Events | Group-Object category | ForEach-Object {
            [ordered]@{ category = [string]$_.Name; count = $_.Count }
        })
        severityCounts = @($Events | Group-Object severity | ForEach-Object {
            [ordered]@{ severity = [string]$_.Name; count = $_.Count }
        })
        latestObservation = if ($latest.Count) { $latest[0] } else { $null }
    }
}

function Merge-MonitoringMetrics {
    param([AllowEmptyCollection()][array]$Metrics)

    return @($Metrics | Group-Object { "$($_.time)|$($_.metric)|$($_.unit)|$($_.source)" } | ForEach-Object {
        $first = $_.Group[0]
        [ordered]@{
            time = [string]$first.time
            metric = [string]$first.metric
            value = [double](($_.Group | Measure-Object -Property value -Average).Average)
            unit = [string]$first.unit
            source = [string]$first.source
        }
    } | Sort-Object time -Descending | Select-Object -First $script:MaximumMetricRows | Sort-Object time)
}

function Get-MonitoringObservation {
    param(
        [Parameter(Mandatory)][object]$Server,
        [AllowEmptyString()][string]$ObservedAt
    )

    return [ordered]@{
        time = if ($ObservedAt) { ([datetime]$ObservedAt).ToUniversalTime().ToString('o') } else { (Get-Date).ToUniversalTime().ToString('o') }
        health = [string]$Server.health
        arcStatus = [string]$Server.arcStatus
        lastHeartbeat = $Server.lastHeartbeat
        cpuPercent = $Server.cpuPercent
        memoryPercent = $Server.memoryPercent
        diskFreePercent = $Server.diskFreePercent
        networkBytesPerSec = $Server.networkBytesPerSec
        diskIops = $Server.diskIops
        diskBytesPerSec = $Server.diskBytesPerSec
        diskReadIops = $Server.diskReadIops
        diskWriteIops = $Server.diskWriteIops
        diskReadBytesPerSec = $Server.diskReadBytesPerSec
        diskWriteBytesPerSec = $Server.diskWriteBytesPerSec
        diskReadLatencyMs = $Server.diskReadLatencyMs
        diskWriteLatencyMs = $Server.diskWriteLatencyMs
        diskQueueLength = $Server.diskQueueLength
        activeAlerts = [int]$Server.activeAlerts
        criticalAlerts = [int]$Server.criticalAlerts
        warningAlerts = [int]$Server.warningAlerts
        pendingUpdates = [int]$Server.pendingUpdates
        criticalUpdates = [int]$Server.criticalUpdates
        securityUpdates = [int]$Server.securityUpdates
        rebootPending = [bool]$Server.rebootPending
        lastAssessment = $Server.lastAssessment
    }
}

function New-ServerMonitoringSession {
    param(
        [Parameter(Mandatory)][hashtable]$SharedState,
        [Parameter(Mandatory)][string]$ServerKey,
        [ValidateRange(15, 480)][int]$DurationMinutes = 120
    )

    if ($ServerKey -notmatch '^[a-f0-9]{16}$') {
        throw [ArgumentException]::new('Select a valid Arc server before starting monitoring.')
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
    $resourceId = $snapshotResult.Snapshot.keyToId[$ServerKey]
    if (-not $resourceId) {
        $exception = [ArgumentException]::new('The selected server is not in the current dashboard scope.')
        $exception.Data['StatusCode'] = 404
        throw $exception
    }
    $server = $snapshotResult.Snapshot.servers[$resourceId]
    $now = (Get-Date).ToUniversalTime()
    $monitoringSnapshot = [ordered]@{
        version = 1
        sessionId = [guid]::NewGuid().ToString()
        state = 'active'
        server = [ordered]@{
            key = [string]$server.key
            resourceId = [string]$server.id
            subscriptionId = [string]$SharedState.Config.SubscriptionId
            name = [string]$server.name
            resourceGroup = [string]$server.resourceGroup
            location = [string]$server.location
            osType = [string]$server.osType
        }
        startedAt = $now.ToString('o')
        activeUntil = $now.AddMinutes($DurationMinutes).ToString('o')
        completedAt = $null
        windowMinutes = $DurationMinutes
        lastCollectedAt = $null
        lastError = $null
        workspaceErrors = @()
        metrics = @()
        events = @()
        observations = @((Get-MonitoringObservation -Server $server -ObservedAt ([string]$snapshotResult.Snapshot.generatedAt)))
        baseline = $null
    }
    $monitoringSnapshot.baseline = Get-MonitoringBaseline -Metrics @() -Events @() -Observations $monitoringSnapshot.observations
    $SharedState.MonitoringStateGate.Wait()
    try {
        $SharedState.MonitoringGeneration = [long]$SharedState.MonitoringGeneration + 1
        $monitoringSnapshot.generation = [long]$SharedState.MonitoringGeneration
        $SharedState.MonitoringSnapshot = $monitoringSnapshot
        $SharedState.MonitoringCollectionRequested = $true
        $SharedState.MonitoringLastError = $null
        Save-MonitoringSnapshot -Snapshot $monitoringSnapshot -Path $SharedState.MonitoringStorePath
    }
    finally {
        [void]$SharedState.MonitoringStateGate.Release()
    }
    return $monitoringSnapshot
}

function Update-ServerMonitoringSession {
    param([Parameter(Mandatory)][hashtable]$SharedState)

    if (-not $SharedState.MonitoringGate.Wait(0)) { return }
    $current = $null
    $generation = [long]-1
    try {
        $current = $SharedState.MonitoringSnapshot
        if (-not $current -or [string]$current.state -ne 'active') { return }
        $generation = [long]$current.generation
        $SharedState.MonitoringCollectionRequested = $false
        $now = (Get-Date).ToUniversalTime()
        if (([datetime]$current.activeUntil).ToUniversalTime() -le $now) {
            $completed = $current | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
            $completed.state = 'completed'
            $completed.completedAt = ([datetime]$current.activeUntil).ToUniversalTime().ToString('o')
            Publish-MonitoringSnapshot -SharedState $SharedState -Snapshot $completed -ExpectedGeneration $generation
            return
        }

        $operationsResult = Get-OperationsSnapshotOrBuild -SharedState $SharedState
        if ($operationsResult.Building) {
            $deferred = $current | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
            $deferred.nextAttemptAt = $now.AddSeconds(10).ToString('o')
            Publish-MonitoringSnapshot -SharedState $SharedState -Snapshot $deferred -ExpectedGeneration $generation
            return
        }
        if ($operationsResult.Error -or -not $operationsResult.Snapshot) {
            throw [InvalidOperationException]::new([string]$operationsResult.Error)
        }
        $operations = $operationsResult.Snapshot
        $resourceId = $operations.keyToId[[string]$current.server.key]
        if (-not $resourceId) {
            throw [InvalidOperationException]::new('The monitored server is no longer in the configured dashboard scope.')
        }
        $server = $operations.servers[$resourceId]
        $query = Get-MonitoringQuery -ResourceId ([string]$server.id) -WindowMinutes ([int]$current.windowMinutes)
        $workspaces = @($SharedState.Config.Workspaces)
        $bounded = if ($workspaces.Count) {
            Invoke-LogAnalyticsQueryBounded -Workspaces $workspaces -Query $query `
                -SubscriptionId ([string]$SharedState.Config.SubscriptionId) -MaxConcurrency 4
        }
        else {
            @{ Results = [ordered]@{}; Errors = @('No Log Analytics workspaces are configured for the dashboard scope.') }
        }

        $metrics = [Collections.Generic.List[object]]::new()
        $events = [Collections.Generic.List[object]]::new()
        foreach ($workspaceName in $bounded.Results.Keys) {
            foreach ($row in @($bounded.Results[$workspaceName])) {
                if ([string]$row.recordType -eq 'metric') {
                    $number = 0.0
                    if ([double]::TryParse([string]$row.value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
                        $metrics.Add([ordered]@{
                            time = ([datetime]$row.timestamp).ToUniversalTime().ToString('o')
                            metric = [string]$row.metric
                            value = $number
                            unit = [string]$row.unit
                            source = [string]$row.source
                            workspace = [string]$workspaceName
                        })
                    }
                }
                else {
                    $message = Protect-MonitoringEventMessage -Message ([string]$row.message)
                    $events.Add([ordered]@{
                        time = ([datetime]$row.timestamp).ToUniversalTime().ToString('o')
                        category = [string]$row.category
                        severity = [string]$row.severity
                        source = [string]$row.source
                        message = $message
                        workspace = [string]$workspaceName
                    })
                }
            }
        }

        $metrics = Merge-MonitoringMetrics -Metrics @($metrics)
        $events = @($events | Group-Object { "$($_.time)|$($_.category)|$($_.source)|$($_.message)" } |
            ForEach-Object { $_.Group[0] } | Sort-Object time -Descending |
            Select-Object -First $script:MaximumEventRows | Sort-Object time)
        $next = $current | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
        $next.metrics = $metrics
        $next.events = $events
        $observation = Get-MonitoringObservation -Server $server -ObservedAt ([string]$operations.generatedAt)
        $existingObservationTimes = @($next.observations | ForEach-Object { [string]$_.time })
        if ([string]$observation.time -notin $existingObservationTimes) {
            $next.observations = @(@($next.observations) + $observation |
                Sort-Object time -Descending | Select-Object -First $script:MaximumObservationRows | Sort-Object time)
        }
        $next.lastCollectedAt = $now.ToString('o')
        $next.nextAttemptAt = $null
        $next.lastError = $null
        $next.workspaceErrors = @($bounded.Errors)
        $next.baseline = Get-MonitoringBaseline -Metrics $metrics -Events $events -Observations $next.observations
        if (Publish-MonitoringSnapshot -SharedState $SharedState -Snapshot $next -ExpectedGeneration $generation) {
            $SharedState.MonitoringLastError = $null
        }
    }
    catch {
        $SharedState.MonitoringLastError = $_.Exception.Message
        Write-Warning "Single-server monitoring collection failed: $($_.Exception.Message)"
        if ($current) {
            $failed = $current | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
            $failed.lastError = $_.Exception.Message
            $failed.nextAttemptAt = (Get-Date).ToUniversalTime().AddSeconds(60).ToString('o')
            Publish-MonitoringSnapshot -SharedState $SharedState -Snapshot $failed -ExpectedGeneration $generation
        }
    }
    finally {
        [void]$SharedState.MonitoringGate.Release()
    }
}

function Publish-MonitoringSnapshot {
    param(
        [Parameter(Mandatory)][hashtable]$SharedState,
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][long]$ExpectedGeneration
    )

    $SharedState.MonitoringStateGate.Wait()
    try {
        $current = $SharedState.MonitoringSnapshot
        if (-not $current -or [long]$SharedState.MonitoringGeneration -ne $ExpectedGeneration -or
            [string]$current.sessionId -ne [string]$Snapshot.sessionId) {
            return $false
        }
        $SharedState.MonitoringSnapshot = $Snapshot
        Save-MonitoringSnapshot -Snapshot $Snapshot -Path $SharedState.MonitoringStorePath
        return $true
    }
    finally {
        [void]$SharedState.MonitoringStateGate.Release()
    }
}

function Start-ServerMonitoringLoop {
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
                $session = $target.MonitoringSnapshot
                if ($session -and [string]$session.state -eq 'active') {
                    $now = (Get-Date).ToUniversalTime()
                    $retryDue = -not $session.nextAttemptAt -or ([datetime]$session.nextAttemptAt).ToUniversalTime() -le $now
                    $due = $retryDue -and (
                        $target.MonitoringCollectionRequested -or -not $session.lastCollectedAt -or
                        ([datetime]$session.lastCollectedAt).ToUniversalTime().AddSeconds($IntervalSeconds) -le $now
                    )
                    if ($due) {
                        Update-ServerMonitoringSession -SharedState $target
                    }
                }
            }
            catch {
                $target.MonitoringLastError = $_.Exception.Message
                Write-Warning "Single-server monitoring loop error: $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 2
    }
}

function ConvertTo-MonitoringStatus {
    param([object]$Snapshot, [string]$RuntimeError)

    if (-not $Snapshot) {
        return @{
            exists = $false
            state = 'none'
            lastError = if ($RuntimeError) { 'Monitoring collection failed. Review the dashboard console for details.' } else { $null }
        }
    }
    return [ordered]@{
        exists = $true
        sessionId = [string]$Snapshot.sessionId
        state = [string]$Snapshot.state
        server = [ordered]@{
            key = [string]$Snapshot.server.key
            name = [string]$Snapshot.server.name
            resourceGroup = [string]$Snapshot.server.resourceGroup
            location = [string]$Snapshot.server.location
            osType = [string]$Snapshot.server.osType
        }
        startedAt = [string]$Snapshot.startedAt
        activeUntil = [string]$Snapshot.activeUntil
        completedAt = [string]$Snapshot.completedAt
        windowMinutes = [int]$Snapshot.windowMinutes
        lastCollectedAt = [string]$Snapshot.lastCollectedAt
        lastError = if ($Snapshot.lastError -or $RuntimeError) { 'Monitoring collection failed. Review the dashboard console for details.' } else { $null }
        telemetryPartial = @($Snapshot.workspaceErrors).Count -gt 0
        workspaceErrorCount = @($Snapshot.workspaceErrors).Count
        metricSamples = @($Snapshot.metrics).Count
        eventSamples = @($Snapshot.events).Count
        observationSamples = @($Snapshot.observations).Count
        baseline = $Snapshot.baseline
    }
}

function ConvertTo-MonitoringDetail {
    param([object]$Snapshot, [string]$RuntimeError)

    $status = ConvertTo-MonitoringStatus -Snapshot $Snapshot -RuntimeError $RuntimeError
    if (-not $Snapshot) {
        return [ordered]@{
            status = [ordered]@{
                exists = $false
                state = 'none'
                telemetryPartial = [bool]$RuntimeError
                workspaceErrorCount = 0
            }
            metrics = @()
            events = @()
            observations = @()
        }
    }

    $detailStatus = [ordered]@{
        exists = $true
        sessionId = [string]$status.sessionId
        state = [string]$status.state
        server = $status.server
        startedAt = [string]$status.startedAt
        activeUntil = [string]$status.activeUntil
        completedAt = [string]$status.completedAt
        windowMinutes = [int]$status.windowMinutes
        lastCollectedAt = [string]$status.lastCollectedAt
        telemetryPartial = @($Snapshot.workspaceErrors).Count -gt 0 -or [bool]$status.lastError
        workspaceErrorCount = @($Snapshot.workspaceErrors).Count
        metricSamples = [int]$status.metricSamples
        eventSamples = [int]$status.eventSamples
        observationSamples = [int]$status.observationSamples
        baseline = $status.baseline
    }
    return [ordered]@{
        status = $detailStatus
        metrics = @($Snapshot.metrics | Group-Object { "$($_.metric)|$($_.source)" } | ForEach-Object {
            $_.Group | Sort-Object time -Descending | Select-Object -First 480
        } | Sort-Object time | ForEach-Object {
            [ordered]@{
                time = [string]$_.time
                metric = [string]$_.metric
                value = [double]$_.value
                unit = [string]$_.unit
                source = [string]$_.source
            }
        })
        events = @($Snapshot.events | Sort-Object time -Descending | Select-Object -First 100 | ForEach-Object {
            [ordered]@{
                time = [string]$_.time
                category = [string]$_.category
                severity = [string]$_.severity
                source = [string]$_.source
                message = Protect-MonitoringEventMessage -Message ([string]$_.message)
            }
        })
        observations = @($Snapshot.observations | Sort-Object time -Descending | Select-Object -First 480 | Sort-Object time | ForEach-Object {
            [ordered]@{
                time = [string]$_.time
                health = [string]$_.health
                arcStatus = [string]$_.arcStatus
                lastHeartbeat = [string]$_.lastHeartbeat
                cpuPercent = $_.cpuPercent
                memoryPercent = $_.memoryPercent
                diskFreePercent = $_.diskFreePercent
                networkBytesPerSec = $_.networkBytesPerSec
                diskIops = $_.diskIops
                diskBytesPerSec = $_.diskBytesPerSec
                diskReadIops = $_.diskReadIops
                diskWriteIops = $_.diskWriteIops
                diskReadBytesPerSec = $_.diskReadBytesPerSec
                diskWriteBytesPerSec = $_.diskWriteBytesPerSec
                diskReadLatencyMs = $_.diskReadLatencyMs
                diskWriteLatencyMs = $_.diskWriteLatencyMs
                diskQueueLength = $_.diskQueueLength
                activeAlerts = [int]$_.activeAlerts
                criticalAlerts = [int]$_.criticalAlerts
                warningAlerts = [int]$_.warningAlerts
                pendingUpdates = [int]$_.pendingUpdates
                criticalUpdates = [int]$_.criticalUpdates
                securityUpdates = [int]$_.securityUpdates
                rebootPending = [bool]$_.rebootPending
                lastAssessment = [string]$_.lastAssessment
            }
        })
    }
}

function Stop-ServerMonitoringSession {
    param([Parameter(Mandatory)][hashtable]$SharedState)

    $SharedState.MonitoringStateGate.Wait()
    try {
        if (-not $SharedState.MonitoringSnapshot) { return $null }
        $stopped = $SharedState.MonitoringSnapshot | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
        if ([string]$stopped.state -eq 'active') {
            $SharedState.MonitoringGeneration = [long]$SharedState.MonitoringGeneration + 1
            $stopped.generation = [long]$SharedState.MonitoringGeneration
            $stopped.state = 'stopped'
            $stopped.completedAt = (Get-Date).ToUniversalTime().ToString('o')
            $SharedState.MonitoringSnapshot = $stopped
            $SharedState.MonitoringCollectionRequested = $false
            Save-MonitoringSnapshot -Snapshot $stopped -Path $SharedState.MonitoringStorePath
        }
        return $stopped
    }
    finally {
        [void]$SharedState.MonitoringStateGate.Release()
    }
}

function Invoke-MonitoringApiRequest {
    param(
        [Parameter(Mandatory)][hashtable]$SharedState,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][IO.Stream]$Stream
    )

    try {
        switch ("$Method $Path") {
            'GET /api/monitoring/session' {
                Write-JsonResponseBytes -Stream $Stream -Value (ConvertTo-MonitoringStatus -Snapshot $SharedState.MonitoringSnapshot -RuntimeError $SharedState.MonitoringLastError)
                return
            }
            'GET /api/monitoring/session/detail' {
                Write-JsonResponseBytes -Stream $Stream -Value (ConvertTo-MonitoringDetail -Snapshot $SharedState.MonitoringSnapshot -RuntimeError $SharedState.MonitoringLastError)
                return
            }
            'POST /api/monitoring/session' {
                if (-not $Body) { throw [ArgumentException]::new('Request body is required.') }
                $request = $Body | ConvertFrom-Json
                $duration = 120
                if ($null -ne $request.durationMinutes -and
                    (-not [int]::TryParse([string]$request.durationMinutes, [ref]$duration) -or $duration -lt 15 -or $duration -gt 480)) {
                    throw [ArgumentException]::new('Monitoring duration must be between 15 and 480 minutes.')
                }
                $snapshot = New-ServerMonitoringSession -SharedState $SharedState -ServerKey ([string]$request.serverKey) -DurationMinutes $duration
                Write-JsonResponseBytes -Stream $Stream -Value (ConvertTo-MonitoringStatus -Snapshot $snapshot -RuntimeError $SharedState.MonitoringLastError) -StatusCode 201 -StatusText 'Created'
                return
            }
            'POST /api/monitoring/session/refresh' {
                if (-not $SharedState.MonitoringSnapshot) {
                    Write-JsonResponseBytes -Stream $Stream -Value @{ error = 'No monitoring session exists.' } -StatusCode 404 -StatusText 'Not Found'
                    return
                }
                $requestedAt = (Get-Date).ToUniversalTime().ToString('o')
                $SharedState.MonitoringCollectionRequested = $true
                $status = ConvertTo-MonitoringStatus -Snapshot $SharedState.MonitoringSnapshot -RuntimeError $SharedState.MonitoringLastError
                $status['collectionRequestedAt'] = $requestedAt
                Write-JsonResponseBytes -Stream $Stream -Value $status
                return
            }
            'POST /api/monitoring/session/stop' {
                $snapshot = Stop-ServerMonitoringSession -SharedState $SharedState
                Write-JsonResponseBytes -Stream $Stream -Value (ConvertTo-MonitoringStatus -Snapshot $snapshot -RuntimeError $SharedState.MonitoringLastError)
                return
            }
            'DELETE /api/monitoring/session' {
                Remove-MonitoringSnapshot -SharedState $SharedState
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
