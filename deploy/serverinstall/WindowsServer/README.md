# Azure Arc Observability Dashboard for Windows Server

This folder is a self-contained Windows Server deployment package for the
standalone Azure Arc Observability Dashboard. Copy the entire folder to the destination
server; do not copy individual application files.

## Start here

Read the packaged guides before configuring the dashboard:

1. [Dashboard Configuration and Operations Guide](deploymentguide/dashboard-configuration-guide.md) -
   complete Windows host preparation, Azure permissions, first-run setup,
   monitoring, security, troubleshooting, migration, and validation guidance.
2. [Microsoft Foundry Setup and Usage Guide](deploymentguide/standalone-foundry-setup.md) -
   optional Foundry resource, model deployment, role assignment, and AI
   Assistant configuration.

The configuration guide is the primary deployment document. The Foundry guide
is required only when the AI Assistant will be enabled.

## Package contents

```text
WindowsServer\
  README.md
  Launcher.cmd
  Start-Dashboard.ps1
  server.ps1
  ArcDashboard.Core.psm1
  ArcDashboard.AI.psm1
  ArcDashboard.Monitoring.psm1
  ArcDashboard.WorkloadMonitoring.psm1
  Azure-Login.ps1
  Install-AzureCli.ps1
  *.html
  deploymentguide\
    dashboard-configuration-guide.md
    standalone-foundry-setup.md
```

The PowerShell modules, startup scripts, and HTML application files are copied
from `development\standalone`. The `deploymentguide` directory contains the
configuration and optional Foundry instructions needed by the operator.

## Requirements

- A supported Windows Server host
- PowerShell 7 available as `pwsh`
- A local browser or an approved remote desktop session with a browser
- Azure CLI, or permission to install it from the setup page
- Network access to Microsoft Entra ID and the required Azure endpoints
- Read permissions for the intended Arc subscription and resource groups
- Log Analytics query permissions for monitoring data
- Optional Microsoft Foundry resource and model permissions for the AI
  Assistant

See the
[configuration guide prerequisites](deploymentguide/dashboard-configuration-guide.md#2-plan-identities-scope-and-permissions)
for the detailed Azure role and telemetry requirements.

## Deploy to a Windows Server

1. Copy this entire `WindowsServer` folder to a stable local path on the
   destination host, for example:

   ```text
   C:\ArcDashboard
   ```

2. Sign in to Windows as the user who will operate the dashboard. Saved
   configuration and monitoring keys are protected for that Windows user.

3. Open PowerShell and change to the deployment directory:

   ```powershell
   Set-Location "C:\ArcDashboard"
   ```

4. Confirm that PowerShell 7 is installed:

   ```powershell
   pwsh --version
   ```

5. Start the dashboard:

   ```powershell
   .\Launcher.cmd
   ```

6. Choose one of the three available loopback ports.

7. Complete first-run setup in the local browser:
   - Install or confirm Azure CLI.
   - Complete Azure device authentication.
   - Select the Arc subscription.
   - Select the resource groups containing the Arc resources.
   - Wait for workspace discovery and the initial snapshot.

8. If required, open **AI Assistant** and follow the packaged
   [Foundry guide](deploymentguide/standalone-foundry-setup.md).

Keep the launcher window open while using the dashboard. The server listens
only on the local loopback interface and is not directly reachable from
another computer.

## Alternative startup commands

Run the interactive port selector directly:

```powershell
pwsh -NoProfile -File .\Start-Dashboard.ps1
```

Use a fixed available port:

```powershell
pwsh -NoProfile -File .\Start-Dashboard.ps1 -Port 8766
```

Start without automatically opening a browser:

```powershell
pwsh -NoProfile -File .\Start-Dashboard.ps1 -Port 8766 -NoBrowser
```

Then open the following address in a browser on the same server:

```text
http://localhost:8766/
```

## Runtime files created after setup

The deployment package intentionally does not include machine-bound runtime
state. The dashboard creates these items on the destination server:

| Path | Purpose |
|---|---|
| `dashboard.config.dat` | DPAPI-protected subscription, resource-group, workspace, and optional Foundry configuration |
| `.azure-foundry\` | Isolated Azure CLI authentication state for Foundry |
| `.monitoring\session.dat` | Encrypted single-server monitoring snapshot |
| `.monitoring\workload.dat` | Encrypted workload monitoring snapshot |

Do not transfer these items between Windows users or computers. Configure each
deployment on its destination host because DPAPI-protected data is bound to
the Windows user profile.

Do not commit, distribute, or include runtime state in a reusable deployment
archive.

## Updating an existing deployment

Before replacing application files:

1. Stop the dashboard by closing its launcher window, or use **Logout** when
   the Azure CLI and local-state cleanup behavior is intended.
2. Back up only separately maintained operational notes. Do not use copied
   token caches or DPAPI-protected runtime files as portable backups.
3. Replace the application scripts, modules, HTML files, README, and
   `deploymentguide` directory with a complete newer package.
4. Start the dashboard and verify the expected version and views.

If runtime configuration compatibility changes or the package is moved to a
different Windows user or server, remove the old runtime state and complete
first-run configuration again.

> [!WARNING]
> Dashboard **Logout** runs `az logout` and `az account clear` against the
> Windows user's shared Azure CLI profile. It signs that user out of Azure CLI
> for other tools and terminals on the host, not only this dashboard. Review
> the configuration guide before using Logout on a shared administration or
> automation server.

## Remove the deployment

1. Use **Logout** if the shared Azure CLI cleanup described above is intended.
2. Otherwise, stop the dashboard and separately manage Azure CLI sign-out
   according to the server's operational policy.
3. Delete only the specific dashboard deployment directory after confirming
   it contains no separately maintained files.

Removing the local package does not delete or modify Azure resources.
