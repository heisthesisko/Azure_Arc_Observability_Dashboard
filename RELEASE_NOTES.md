# Azure Arc Observability Dashboard release notes

## v1.0.1 - 2026-09-08

This patch release adds the dashboard version to the user interface so operators can
identify the deployed build while viewing any dashboard page.

### Changed

- Every HTML page now displays a compact `v1.0.1` badge in the lower-right corner.
- The badge is injected by the runtime response layer, keeping the displayed version
  consistent across dashboard, setup, and signed-out pages.
- The badge includes an accessible label for assistive technology.
- Windows Server, Linux Server, Docker, AKS, and OpenShift deployment packages are
  republished for this version.

### Release assets

| Archive | Intended target |
|---|---|
| `Azure-Arc-Observability-Dashboard-WindowsServer-v1.0.1.zip` | Windows workstation or Windows Server |
| `Azure-Arc-Observability-Dashboard-LinuxServer-v1.0.1.zip` | Ubuntu, Debian, Fedora, or RHEL-family Linux |
| `Azure-Arc-Observability-Dashboard-Docker-v1.0.1.zip` | Local Docker Engine or Docker Desktop |
| `Azure-Arc-Observability-Dashboard-AKS-v1.0.1.zip` | Azure Kubernetes Service |
| `Azure-Arc-Observability-Dashboard-OpenShift-v1.0.1.zip` | Red Hat OpenShift |

Use the accompanying `SHA256SUMS.txt` file to verify archive integrity.

### Upgrade notes

No configuration or persistent-state migration is required from `v1.0.0`.

- Windows and Linux users should stop the existing process, preserve the documented
  encrypted configuration and monitoring state, and replace the application files with
  the `v1.0.1` package.
- Docker users should rebuild the image from the `v1.0.1` Docker package while preserving
  the existing named data volume.
- AKS and OpenShift users should build and deploy the `v1.0.1` dashboard image, then apply
  the corresponding chart package using the documented singleton upgrade procedure.

## v1.0.0 - 2026-09-08

This is the initial public release of the Azure Arc Observability Dashboard. It provides
read-only observability for Azure Arc-enabled servers, Arc-enabled SQL Server, and
Arc-enabled Kubernetes across local, container, and shared Kubernetes deployment models.

### Release assets

Choose the archive that matches the target deployment:

| Archive | Intended target | User model |
|---|---|---|
| `Azure-Arc-Observability-Dashboard-WindowsServer-v1.0.0.zip` | Windows workstation or Windows Server with a desktop browser | Single user |
| `Azure-Arc-Observability-Dashboard-LinuxServer-v1.0.0.zip` | Ubuntu, Debian, Fedora, or RHEL-family Linux with a desktop browser | Single user |
| `Azure-Arc-Observability-Dashboard-Docker-v1.0.0.zip` | Local Docker Engine or Docker Desktop | Single user |
| `Azure-Arc-Observability-Dashboard-AKS-v1.0.0.zip` | Azure Kubernetes Service | Multiple authenticated users |
| `Azure-Arc-Observability-Dashboard-OpenShift-v1.0.0.zip` | Red Hat OpenShift | Multiple authenticated users |

Each archive contains the runtime, configuration templates, README, and deployment guides
for that target. GitHub also generates source-code ZIP and TAR archives containing every
public deployment option. Use `SHA256SUMS.txt` from the release assets to verify archive
integrity after download.

### Included capabilities

- Global Arc estate totals, health, alerts, updates, geography, and risk indicators.
- Searchable Arc-enabled server inventory and operating-system lifecycle analysis.
- Arc-enabled SQL inventory, licensing, patching, Defender, and migration posture.
- Arc-enabled Kubernetes inventory, version, distribution, extension, capacity, and
  certificate-health views.
- Azure Monitor Agent, Dependency Agent, extension, and monitoring coverage.
- Time-bounded single-server CPU, memory, disk, network, event, Syslog, and heartbeat
  observations.
- Comparative workload monitoring for 1-10 servers with rolling encrypted baselines.
- Read-only Azure VM SKU assessment based on observed utilization and configurable
  headroom.
- Printable executive summary and directional readiness reporting.
- Optional Microsoft Foundry assistant grounded in bounded dashboard snapshots and tools.

### Deployment models

**Windows Server and Linux Server** run locally for one interactive user. The dashboard
listener is restricted to loopback, and the user's Azure CLI sessions provide Arc and
optional Foundry access.

**Docker** packages the same single-user experience in a non-root, read-only Linux
container and publishes the service only on host loopback.

**AKS and OpenShift** provide a shared multi-user experience through Microsoft Entra ID and
`oauth2-proxy`. A central workload identity owns the shared Arc snapshot. Foundry tokens,
monitoring selections, and rolling baselines remain isolated per authenticated user.

All deployment models intentionally run one dashboard instance for each configured Azure
scope. AKS and OpenShift use one replica with a `Recreate` strategy to prevent duplicate
Azure Resource Graph and Log Analytics query workloads.

### Authentication and security

- Azure data access is read-only and limited by the signed-in identity's Azure RBAC scope.
- No Azure passwords, API keys, bearer tokens, or tenant-specific credentials are included
  in the release.
- Local Arc and Foundry Azure CLI profiles remain separate.
- Windows configuration and monitoring state use Windows DPAPI.
- Linux and container state use AES-256-GCM with a locally protected master key.
- Runtime configuration, Azure profiles, monitoring stores, encryption keys, and generated
  deployment values are excluded from Git and container build contexts.
- Local HTTP servers validate the `Host` header and reject non-loopback hosts.
- Kubernetes deployments expose only the authenticated proxy and keep the dashboard
  listener behind the pod-local proxy boundary.
- Foundry inference uses the `https://ai.azure.com/.default` delegated scope and retains
  delegated access tokens only in memory for shared deployments.

### Prerequisites

Common requirements include:

- Network access to Microsoft Entra ID, Azure Resource Manager, Azure Resource Graph,
  Azure Monitor, Log Analytics, and optional Microsoft Foundry endpoints.
- An Azure identity with Reader-equivalent access to the selected subscriptions or
  resource groups.
- Additional read permissions for Log Analytics, Defender, alerts, or updates when those
  data sets are required.

Platform-specific requirements and setup commands are documented inside each release
archive.

### Known operational constraints

- The dashboard is observational and does not remediate, patch, restart, deploy, or modify
  Azure resources.
- Results reflect the Azure scopes and permissions visible to the configured identity.
- Monitoring views require Azure Monitor and Log Analytics data for the selected servers.
- Optional AI features require a separately configured Microsoft Foundry model deployment
  and appropriate Foundry RBAC.
- Multi-replica, autoscaled, canary, and overlapping blue/green deployments are not
  supported.

### Upgrade and rollback

This is the first public release, so no earlier public configuration migration is required.
For future upgrades:

1. Read the target version's release notes.
2. Back up configuration and encrypted state as described in the package guide.
3. Deploy the complete replacement package rather than mixing files between versions.
4. Preserve only the documented persistent data directory or volume.
5. Retain the previous release archive until the replacement is confirmed operational.

To reproduce this release, check out Git tag `v1.0.0`.
