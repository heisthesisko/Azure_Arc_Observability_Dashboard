# Azure Arc Observability Dashboard server deployment options

This directory contains self-contained packages for running the standalone
Azure Arc Observability Dashboard directly on a server without a container,
Kubernetes, or an external web server.

## Current packages

| Package | Supported host | Launcher | Configuration protection |
|---|---|---|---|
| [WindowsServer](WindowsServer/README.md) | Windows Server | `Launcher.cmd` | Windows DPAPI for configuration and AES-256-GCM monitoring data with a DPAPI-protected key |
| [LinuxServer](LinuxServer/README.md) | Ubuntu/Debian and Fedora/RHEL families | `Launcher.sh` | AES-256-GCM with a local Linux key protected by ownership and Unix permission modes |

The Linux package is one shared runtime for both distribution families.
Distribution-specific differences are limited to installing PowerShell and
Azure CLI through APT or DNF.

## Choose a deployment

### Windows Server

Use [WindowsServer](WindowsServer/README.md) when the dashboard will run under
a Windows user profile.

```powershell
Set-Location "C:\ArcDashboard"
.\Launcher.cmd
```

The Windows package requires PowerShell 7 and a local browser or approved
remote desktop session. Azure CLI can be installed from the setup page when
host policy permits.

Read:

- [Windows configuration and operations guide](WindowsServer/deploymentguide/dashboard-configuration-guide.md)
- [Windows Microsoft Foundry guide](WindowsServer/deploymentguide/standalone-foundry-setup.md)

### Linux Server

Use [LinuxServer](LinuxServer/README.md) for Ubuntu/Debian-family or
Fedora/RHEL-family hosts.

```bash
cd /opt/arc-dashboard
chmod u+x ./Launcher.sh
./Launcher.sh
```

The Linux package requires PowerShell 7.4 or later, Azure CLI, Bash, and a
filesystem that enforces Unix ownership and permission modes. The dashboard
does not invoke `sudo` or install packages from its web process.

Read:

- [Linux configuration and operations guide](LinuxServer/deploymentguide/dashboard-configuration-guide.md)
- [Linux Microsoft Foundry guide](LinuxServer/deploymentguide/standalone-foundry-setup.md)

## Common behavior

Both packages:

- Run the same standalone dashboard views and bounded APIs.
- Bind only to `localhost`/the loopback interface.
- Use Azure CLI device authentication for Arc data.
- Keep optional Microsoft Foundry authentication in an isolated Azure CLI
  profile.
- Support encrypted single-server and workload monitoring snapshots.
- Include complete configuration, security, monitoring, troubleshooting, and
  Foundry deployment guides.
- Are read-only and do not modify Azure resources.

Copy the complete platform folder to the destination host. Do not combine
files from the Windows and Linux packages.

## Runtime state

Runtime configuration, Azure authentication caches, encryption keys, and
monitoring snapshots are created after first-run setup. They are intentionally
not part of either reusable package.

Do not copy runtime state between operating systems, hosts, or operating-user
accounts. Deploy a clean package and repeat device authentication and
configuration on the destination host.

## Other deployment models

Container and Kubernetes deployment assets are maintained separately:

- [Docker](../docker/README.md)
- [Kubernetes](../kubernetes/README.md)
