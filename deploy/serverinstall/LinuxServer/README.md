# Azure Arc Observability Dashboard for Linux Server

This folder is a self-contained Linux deployment package for the standalone
Azure Arc Observability Dashboard. One shared runtime supports Ubuntu/Debian-family and
Fedora/RHEL-family distributions; only prerequisite package installation
differs by distribution.

Copy the entire folder to the destination host. Do not copy individual
application files.

## Start here

Read the packaged guides before configuring the dashboard:

1. [Linux Dashboard Configuration and Operations Guide](deploymentguide/dashboard-configuration-guide.md) -
   host preparation, Azure permissions, first-run setup, monitoring, Linux
   encryption, security, troubleshooting, migration, and validation.
2. [Linux Microsoft Foundry Setup and Usage Guide](deploymentguide/standalone-foundry-setup.md) -
   optional Foundry resource, model deployment, role assignment, and AI
   Assistant configuration.

The configuration guide is the primary deployment document. The Foundry guide
is required only when the AI Assistant will be enabled.

## Supported Linux families

The runtime is designed for:

- Ubuntu and compatible Debian-family systems.
- Fedora, RHEL, Rocky Linux, AlmaLinux, and compatible RPM-family systems.

Validate the exact distribution release against the support requirements for
PowerShell 7 and Azure CLI. The dashboard uses the same application files on
both families.

## Package contents

```text
LinuxServer/
  README.md
  Launcher.sh
  Start-Dashboard.ps1
  server.ps1
  ArcDashboard.Security.psm1
  ArcDashboard.Core.psm1
  ArcDashboard.AI.psm1
  ArcDashboard.Monitoring.psm1
  ArcDashboard.WorkloadMonitoring.psm1
  Azure-Login.ps1
  Install-AzureCli.ps1
  *.html
  deploymentguide/
    dashboard-configuration-guide.md
    standalone-foundry-setup.md
```

`ArcDashboard.Security.psm1` provides the Linux encryption implementation.
The remaining PowerShell modules and HTML application retain the standalone
dashboard behavior used by the Windows release.

## Requirements

- A supported 64-bit Ubuntu/Debian- or Fedora/RHEL-family Linux host.
- PowerShell 7.4 or later available as `pwsh`.
- Azure CLI available as `az`.
- Bash for `Launcher.sh`.
- A local desktop browser and `xdg-open`, or an approved SSH local tunnel.
- Network access to Microsoft Entra ID and required Azure endpoints.
- Read permissions for the intended Arc subscription and resource groups.
- Log Analytics query permissions for monitoring data.
- Optional Microsoft Foundry resource and model permissions for the AI
  Assistant.
- A local or trusted filesystem that enforces Unix ownership and permission
  modes.

### Install prerequisites

Use the current official Microsoft instructions for the installed
distribution:

| Component | Ubuntu/Debian family | Fedora/RHEL family |
|---|---|---|
| PowerShell 7 | [Install PowerShell on Ubuntu](https://learn.microsoft.com/powershell/scripting/install/install-ubuntu) | [Install PowerShell on RHEL](https://learn.microsoft.com/powershell/scripting/install/install-rhel) |
| Azure CLI | [Install with APT](https://learn.microsoft.com/cli/azure/install-azure-cli-linux?pivots=apt) | [Install with DNF](https://learn.microsoft.com/cli/azure/install-azure-cli-linux?pivots=dnf) |

Confirm both commands before deployment:

```bash
pwsh --version
az version
```

The dashboard does not invoke `sudo` or modify Linux package repositories.
If Azure CLI is absent, **Show install steps** on the setup page displays the
appropriate Microsoft documentation link.

## Deploy to a Linux host

1. Copy the entire `LinuxServer` folder to a stable local directory, for
   example:

   ```text
   /opt/arc-dashboard
   ```

2. Assign the directory to the non-root Linux user that will operate the
   dashboard:

   ```bash
   sudo chown -R arc-dashboard:arc-dashboard /opt/arc-dashboard
   sudo chmod 0750 /opt/arc-dashboard
   ```

   Substitute the approved account and group names. That operating account
   needs write access because the dashboard creates encrypted configuration
   and monitoring files.

3. Make the launcher executable:

   ```bash
   sudo chmod 0750 /opt/arc-dashboard/Launcher.sh
   ```

4. Start a shell as the operating user and launch the dashboard:

   ```bash
   cd /opt/arc-dashboard
   ./Launcher.sh
   ```

5. Choose one of the three available loopback ports.

6. Complete first-run setup in a browser:
   - Confirm Azure CLI.
   - Complete Azure device authentication.
   - Select the Arc subscription.
   - Select resource groups containing Arc resources.
   - Wait for workspace discovery and the initial snapshot.

7. If required, open **AI Assistant** and follow the packaged
   [Foundry guide](deploymentguide/standalone-foundry-setup.md).

Keep the launcher terminal open while using the dashboard. Press `Ctrl+C` to
stop it.

## Browser access

The dashboard listens only on `127.0.0.1`/`localhost`. It does not open a
firewall port or accept direct connections from another computer. Each launch
also creates a random HttpOnly, SameSite session cookie that is required by
every API request. The cookie strengthens browser cross-site request
protection; it is not authentication against another local process or user
that can access the loopback listener and load a dashboard page. Use a
dedicated trusted host account and normal Linux process-isolation controls.

### Linux desktop session

Run:

```bash
./Launcher.sh
```

When `xdg-open` and a desktop session are available, the launcher opens the
selected localhost URL. Otherwise, open the URL printed in the terminal.

### Approved SSH local tunnel

Start the dashboard without automatic browser launch:

```bash
./Launcher.sh -Port 8766 -NoBrowser
```

From an authorized client, create a local tunnel:

```bash
ssh -L 8766:127.0.0.1:8766 <user>@<linux-host>
```

Keep the SSH session open and browse on the client to:

```text
http://localhost:8766/
```

Use only an approved SSH configuration and trusted client. Do not change the
dashboard to listen on `0.0.0.0` or expose it through an unauthenticated proxy.

## Alternative startup commands

Run the interactive port selector:

```bash
pwsh -NoProfile -File ./Start-Dashboard.ps1
```

Use a fixed available port:

```bash
pwsh -NoProfile -File ./Start-Dashboard.ps1 -Port 8766
```

Start without automatically opening a browser:

```bash
pwsh -NoProfile -File ./Start-Dashboard.ps1 -Port 8766 -NoBrowser
```

## Linux encryption and runtime state

The package uses AES-256-GCM authenticated encryption. It creates one random
32-byte local master key and protects access using Linux ownership and Unix
permission modes:

```text
.secrets/             mode 0700
.secrets/master.key   mode 0600
```

Configuration and monitoring files are set to mode `0600`. A new random nonce
and purpose-specific authenticated data are used for each encryption
operation.

| Path | Purpose |
|---|---|
| `$HOME/.azure/` | Shared normal Azure CLI authentication state used for Arc |
| `.secrets/master.key` | Local AES-256 key for protected dashboard files |
| `dashboard.config.dat` | Encrypted subscription, resource-group, workspace, and optional Foundry configuration |
| `.azure-foundry/` | Isolated Azure CLI authentication state for Foundry |
| `.monitoring/session.dat` | Encrypted single-server monitoring snapshot |
| `.monitoring/workload.dat` | Encrypted workload monitoring snapshot |

Any process that can read `.secrets/master.key` and the encrypted files can
decrypt them. Protect the operating account, deployment directory, filesystem,
and backups accordingly.

Do not commit, distribute, or include runtime state in a reusable deployment
archive. Losing `master.key` makes the encrypted files unrecoverable.

## SELinux, AppArmor, and filesystem policy

The dashboard requires:

- Read and execute access to its scripts and modules.
- Write access to its deployment directory.
- Local loopback socket access.
- Outbound HTTPS access to Azure endpoints.
- Child-process execution for `pwsh`, `az`, and optional `xdg-open`.
- Temporary-file access through the operating system temp directory.

Do not disable SELinux or AppArmor to make the dashboard run. Create a
least-privilege policy exception only after reviewing an actual denial. Avoid
NFS, CIFS, FAT, or other mounts that do not reliably enforce the expected Unix
permission bits for `.secrets` and encrypted state.

## Service operation

The initial Linux release is designed for interactive foreground operation.
It does not include a systemd unit because first-run device authentication,
browser interaction, and the shared Azure CLI profile are tied to an operating
user session.

Do not run it as `root`. If a future unattended service is required, use a
dedicated service identity, isolated Azure authentication design, protected
runtime directory, explicit network policy, and a separately reviewed systemd
unit.

## Updating an existing deployment

1. Stop the dashboard with `Ctrl+C`, or use **Logout** only when its Azure CLI
   and local-state cleanup behavior is intended.
2. Preserve separately maintained operational notes outside this directory.
3. Replace the application scripts, modules, HTML files, README, and
   `deploymentguide` directory with a complete newer package.
4. Preserve runtime state only when staying on the same host, path, Linux
   account, and trusted filesystem.
5. Restart and verify the expected views.

For a different host or account, deploy a clean package and complete setup
again. Do not transfer `.azure-foundry`, `.secrets`, or `.monitoring`.

> [!WARNING]
> Dashboard **Logout** runs `az logout` and `az account clear` against the
> Linux user's shared `$HOME/.azure` profile. It signs that user out of Azure
> CLI for other tools and terminals on the host, not only this dashboard.

## Remove the deployment

1. Use **Logout** if clearing the shared Azure CLI context and deleting local
   dashboard state is intended.
2. Otherwise, stop the dashboard and manage Azure CLI sign-out according to
   host policy.
3. Delete only the specific dashboard deployment directory after confirming
   it contains no separately maintained files.

Removing the local package does not delete or modify Azure resources.
