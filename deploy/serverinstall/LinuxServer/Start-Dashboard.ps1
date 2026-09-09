param(
    [ValidateRange(1024, 65535)]
    [int]$Port,

    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version]'7.4' -or -not $IsLinux) {
    throw 'PowerShell 7.4 or later on Linux is required to start this dashboard package.'
}

<#
.SYNOPSIS
Starts the Azure Arc Observability Dashboard on a user-selected local port.

.DESCRIPTION
Discovers three available high-numbered loopback ports when no explicit port is
provided, prompts the operator to select one, and passes that port to server.ps1.
An explicit -Port is supported for unattended or scripted startup.
#>

function Test-AvailablePort {
    param([int]$Candidate)

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Candidate)
    try {
        $listener.Start()
        return $true
    }
    catch [Net.Sockets.SocketException] {
        return $false
    }
    finally {
        $listener.Stop()
    }
}

function Get-RandomAvailablePorts {
    param([ValidateRange(1, 20)][int]$Count = 3)

    # A HashSet guarantees that all choices presented to the user are unique.
    $ports = [Collections.Generic.HashSet[int]]::new()
    $attempts = 0
    while ($ports.Count -lt $Count -and $attempts -lt 500) {
        $attempts++
        $candidate = Get-Random -Minimum 10000 -Maximum 49152
        if (-not $ports.Contains($candidate) -and (Test-AvailablePort -Candidate $candidate)) {
            [void]$ports.Add($candidate)
        }
    }

    if ($ports.Count -lt $Count) {
        throw "Unable to find $Count available ports after $attempts attempts."
    }
    return @($ports)
}

if (-not $Port) {
    # Interactive startup offers only ports that successfully bind at selection time.
    $availablePorts = @(Get-RandomAvailablePorts)
    Write-Host ''
    Write-Host 'Azure Arc Observability Dashboard - Select a port' -ForegroundColor Cyan
    Write-Host 'Three currently available ports were found:'
    for ($index = 0; $index -lt $availablePorts.Count; $index++) {
        Write-Host "  $($index + 1). $($availablePorts[$index])"
    }

    while (-not $Port) {
        $selection = Read-Host 'Choose 1, 2, or 3 (press Enter for option 1)'
        if (-not $selection) {
            $selection = '1'
        }
        $choice = 0
        if ([int]::TryParse($selection, [ref]$choice) -and $choice -ge 1 -and $choice -le $availablePorts.Count) {
            $Port = $availablePorts[$choice - 1]
        }
        else {
            Write-Host 'Enter 1, 2, or 3.' -ForegroundColor Yellow
        }
    }
}
elseif (-not (Test-AvailablePort -Candidate $Port)) {
    throw "Port $Port is already in use. Run the launcher without -Port to choose from available ports."
}

# server.ps1 owns the HTTP listener and remains attached so closing this process stops the dashboard.
Write-Host "Starting Azure Arc Observability Dashboard at http://localhost:$Port/" -ForegroundColor Green
& (Join-Path $PSScriptRoot 'server.ps1') -Port $Port -NoBrowser:$NoBrowser
