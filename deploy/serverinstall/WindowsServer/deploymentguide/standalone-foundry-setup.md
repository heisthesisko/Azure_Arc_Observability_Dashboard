# Standalone Microsoft Foundry Setup and Usage Guide

This guide explains how to provision and configure Microsoft Foundry for the
standalone Azure Arc Observability Dashboard AI Assistant.

The dashboard uses:

- A Microsoft Foundry resource and project
- A chat-completions-compatible model deployment with tool calling
- Microsoft Entra authentication through a dedicated, isolated Azure CLI profile
- The `Cognitive Services OpenAI User` role for model inference

The dashboard does not store a model API key and does not require a separate
Foundry Agent.

## 1. Confirm Azure prerequisites

You need:

- An active Azure subscription.
- Permission to create Foundry resources, such as `Contributor`,
  `Foundry Account Owner`, or `Foundry Owner` on the target resource group or
  subscription.
- `Owner` or `User Access Administrator` if you must assign roles to other
  users.
- Azure CLI authentication to the tenant containing the Arc subscription.

Authenticate with Azure CLI:

```powershell
az login --use-device-code
az account show --output table
az account list --output table
```

If necessary, select the correct subscription:

```powershell
az account set --subscription "<subscription-name-or-ID>"
az account show --output table
```

The Arc and Foundry identities can be the same user, guest representations of
the same user, or different users. The dashboard keeps their tokens in separate
Azure CLI profiles.

## 2. Create a Foundry project

1. Open [Microsoft Foundry](https://ai.azure.com).
2. Sign in with the Azure identity used to run the dashboard.
3. Make sure **New Foundry** is enabled.
4. Select the project name in the upper-left corner.
5. Select **Create new project**.
6. Enter a project name, such as:

   ```text
   arc-dashboard-standalone
   ```

7. Open **Advanced options** to control the Azure placement.
8. Select the Azure subscription that will contain the Foundry resources.
9. Select or create a resource group. A dedicated resource group is
   recommended, for example:

   ```text
   rg-arc-dashboard-ai
   ```

10. Select a region where the desired model is available.
11. Enter a globally unique Foundry resource name, for example:

    ```text
    arc-dashboard-ai-<unique-suffix>
    ```

12. Create the project and wait for provisioning to finish.

The project organizes model deployments, playgrounds, evaluations, and future
AI assets. The dashboard calls the model endpoint associated with the
underlying Foundry resource.

### Network access consideration

For the first standalone test, the Foundry endpoint must be reachable from the
Windows computer running the dashboard.

If the organization disables public access and requires private endpoints, the
computer must have connectivity through the associated virtual network, VPN,
ExpressRoute, or another approved private-access path. A desktop outside that
network cannot reach a private-only Foundry endpoint.

## 3. Deploy a model

The dashboard uses the Foundry v1 chat-completions API with function/tool
calling. Select a model that supports both chat completions and tool calling.

A reasonable starting model is:

```text
gpt-4.1-mini
```

If that model is unavailable in the selected region, use another
cost-efficient Azure OpenAI model that explicitly supports chat completions
and tools.

To deploy the model:

1. In Foundry, select **Discover**.
2. Select **Models**.
3. Search for the desired model.
4. Open its model card and review:
   - Tool/function-calling support
   - Region availability
   - Pricing
   - Context limits
   - Data-processing location
5. Select **Deploy**.
6. Select **Default settings** for a quick initial deployment or
   **Custom settings** for additional control.
7. Give the deployment a clear name, for example:

   ```text
   arc-dashboard-chat
   ```

   Record this exact value. The dashboard needs the deployment name, not
   merely the underlying model family name.

8. Select a deployment type:
   - **Global Standard** is the recommended starting point for general testing.
   - **Data Zone Standard** keeps processing within a US, EU, or APAC data
     zone.
   - **Standard** keeps processing in a specific Azure region when supported.
   - Avoid provisioned throughput for initial standalone testing unless
     reserved capacity is already required.
9. Start with a modest quota or capacity allocation suitable for interactive
   testing.
10. Retain the default Microsoft content-safety policy unless an approved
    governance requirement specifies another policy.
11. Select **Deploy**.
12. Wait until the deployment status is **Succeeded**.

Global Standard can process inference in any supported Azure region. If the
dashboard data is subject to geographic-processing requirements, select a
Data Zone or regional deployment instead.

## 4. Test the model in the Foundry playground

Before connecting the dashboard:

1. In Foundry, select **Build**.
2. Select **Models**.
3. Open the new deployment.
4. Open its playground.
5. Enter:

   ```text
   Respond with a one-sentence confirmation that the model is available.
   ```

6. Confirm that the model responds.
7. Open the deployment's **Code** or **Endpoint** section.
8. Verify that the deployment supports chat completions and tool/function
   calling.

Do not configure the dashboard until the deployment works in the Foundry
playground.

## 5. Assign model-inference permission

The dashboard obtains a Microsoft Entra token using the current Azure CLI
identity. That identity needs this role:

```text
Cognitive Services OpenAI User
```

Assign it at the Foundry resource scope.

### Assign the role in the Azure portal

1. Open the [Azure portal](https://portal.azure.com).
2. Find the Foundry or Azure AI Services resource created with the project.
3. Open **Access control (IAM)**.
4. Select **Add** > **Add role assignment**.
5. Search for:

   ```text
   Cognitive Services OpenAI User
   ```

6. Select **User, group, or service principal**.
7. Select the user who will complete the Foundry device sign-in in the
   dashboard.
8. Complete the assignment.

Even if the user created the Foundry resource, explicitly confirm this
inference role. Management-plane roles such as Contributor do not always
provide model data-plane inference access.

Allow several minutes for a new role assignment to propagate.

### Optional Azure CLI method

Get the signed-in user's object ID and the Foundry resource ID:

```powershell
$userObjectId = az ad signed-in-user show --query id --output tsv

$foundryResourceId = az cognitiveservices account show `
  --name "<foundry-resource-name>" `
  --resource-group "<resource-group-name>" `
  --query id `
  --output tsv
```

Create the role assignment:

```powershell
az role assignment create `
  --assignee-object-id $userObjectId `
  --assignee-principal-type User `
  --role "Cognitive Services OpenAI User" `
  --scope $foundryResourceId
```

Confirm the assignment:

```powershell
az role assignment list `
  --assignee $userObjectId `
  --scope $foundryResourceId `
  --query "[].roleDefinitionName" `
  --output table
```

## 6. Obtain the correct endpoint and deployment name

Open the model deployment or Foundry resource's **Endpoint** or **Code**
section. Locate a base URL resembling one of these:

```text
https://<resource-name>.openai.azure.com
```

```text
https://<resource-name>.services.ai.azure.com
```

The dashboard also accepts the v1 base form:

```text
https://<resource-name>.openai.azure.com/openai/v1
```

Do not paste:

- A project-management endpoint containing `/api/projects/`
- A URL containing `/chat/completions`
- A URL containing `/responses`
- A URL with query parameters
- An API key
- A connection string

The dashboard normalizes the resource URL and calls:

```text
/openai/v1/chat/completions
```

Record these two values:

| Dashboard field | Example |
|---|---|
| Foundry resource endpoint | `https://arc-dashboard-ai.openai.azure.com` |
| Model deployment name | `arc-dashboard-chat` |

## 7. Understand the two Azure authentication contexts

The standalone dashboard deliberately maintains two independent Azure CLI
profiles:

| Context | Profile | Purpose |
|---|---|---|
| Arc tenant | Normal Azure CLI user profile | Resource Graph, Log Analytics, Defender, and Arc inventory |
| Foundry tenant | `.azure-foundry` under the installed dashboard directory | Foundry model token and inference |

The Foundry token request explicitly selects the configured Foundry tenant and
does not use the Arc subscription ID. Signing in to Foundry therefore does not
replace the Arc tenant's cached Azure CLI context.

The `.azure-foundry` directory contains local Azure CLI authentication state.
It is excluded from Git and must never be copied into source control or a
deployment package. Dashboard logout removes both Azure contexts and deletes
this isolated profile.

## 8. Start and configure the standalone dashboard

From the installed Windows Server package:

```powershell
Set-Location "C:\ArcObservabilityDashboard"
.\Launcher.cmd
```

Alternatively:

```powershell
pwsh -NoProfile -File `
  "C:\ArcObservabilityDashboard\Start-Dashboard.ps1"
```

Complete the normal dashboard setup:

1. Sign in to Azure.
2. Select the subscription containing the Arc resources.
3. Select the desired resource groups.
4. Save the dashboard configuration.
5. Wait for the dashboard snapshots to load.

Then configure the AI Assistant:

1. Select **AI Assistant** in the dashboard navigation.
2. In **Foundry tenant ID**, enter the tenant GUID that owns the Foundry
   resource:

   ```text
   00000000-0000-0000-0000-000000000000
   ```

3. Select **Sign in to Foundry tenant**.
4. Open the displayed Microsoft device-sign-in URL.
5. Enter the displayed device code.
6. Authenticate with the user that has `Cognitive Services OpenAI User` on the
   Foundry resource.
7. Wait until the page reports that the Foundry tenant is authenticated.
8. In **Foundry resource endpoint**, enter:

   ```text
   https://<resource-name>.openai.azure.com
   ```

9. In **Model deployment name**, enter the exact deployment name:

   ```text
   arc-dashboard-chat
   ```

10. Select **Save AI configuration**.
11. Confirm the status changes to:

   ```text
   Configured: arc-dashboard-chat
   ```

The Foundry tenant ID, endpoint, and deployment name are stored inside the
existing DPAPI-protected configuration:

```text
dashboard.config.dat
```

No Foundry API key is stored.

## 9. Run the first dashboard tests

Begin with bounded current-state questions:

```text
Summarize the current Arc estate.
```

```text
Which Arc servers need the most immediate attention and why?
```

```text
Summarize SQL Defender and monitoring coverage.
```

```text
Which Kubernetes clusters have connectivity or health concerns?
```

```text
How many disconnected servers are in the Dallas resource group?
```

Each successful response should display:

- The model deployment used
- The bounded tools called
- An answer based on current dashboard snapshots
- Relevant snapshot timing or resource details

The assistant can use bounded tools for:

- `get_estate_summary`
- `search_servers`
- `search_sql`
- `search_kubernetes`
- `get_server_monitor_status`
- `get_server_baseline_summary`
- `get_server_metric_series`
- `search_server_events`
- `get_server_alert_timeline`
- `get_server_update_timeline`
- `get_server_connectivity_timeline`
- `get_workload_monitor_status`
- `get_workload_risk_timeline`

The model cannot execute arbitrary Azure CLI, PowerShell, KQL, or Resource
Graph queries.

### Monitor one server

On **Arc-enabled Servers**, select a server and choose **Monitor with Arc AI**,
or search for a connected server in the **Single-server monitoring** panel.
Leave the search blank and choose **Find** to list all connected servers. Choose a
30-minute, one-hour, two-hour, four-hour, or eight-hour rolling baseline and
start monitoring.

The first collection reads available history from the selected server's
configured Log Analytics workspace. While the session remains active, a
dedicated background worker refreshes the bounded dataset every minute. The
assistant can then answer questions about that server's performance metrics,
heartbeat/connectivity, current alert and update observations, Windows Event
records, and Linux Syslog records.

Azure Monitor Agent and appropriate Data Collection Rules must already collect
the desired tables and counters. Log Analytics is near-real-time and can have
ingestion latency. The available baselines support immediate troubleshooting
and same-shift comparisons but do not represent daily or weekly workload
patterns.

Only one monitoring session can exist at a time. **Stop** retains the encrypted
snapshot for AI questions, while **Delete snapshot**, scope reconfiguration,
or dashboard logout removes it. Fleet-wide historical trend questions and
windows longer than eight hours remain unsupported.

### Monitor a server workload

Use **Workload monitoring** when you need to compare a related application or
service tier containing up to 10 Arc-enabled servers:

1. Search for part of a server name, or leave the search blank and choose
   **Find** to list all connected servers. Only servers currently reporting an
   Arc status of **Connected** are returned.
2. Check one or more results and choose **Add checked servers**.
3. Repeat until the workload contains between 1 and 10 servers.
4. Select a 30-minute, one-hour, two-hour, four-hour, or eight-hour baseline.
5. Choose **Start workload monitoring**.

The workload monitor records summary health, Arc connectivity, current CPU,
memory, disk capacity, disk I/O, and network throughput, alerts, updates, reboot state, and lifecycle.
It does not collect Windows Event or Syslog records. Use the single-server
monitor when deep logs and Log Analytics performance history are required.
Disk I/O fields remain unavailable until the server's Azure Monitor data
collection rule sends the corresponding Logical Disk counters.

Workload data is stored independently in encrypted
`.monitoring\workload.dat`. **Collect now** requests an immediate summary
observation, **Stop** retains the encrypted workload snapshot for Arc AI, and
**Delete snapshot** permanently removes it. Arc AI can compare the selected
servers and summarize aggregate risk changes over the workload baseline.

## 10. Monitor usage, latency, and cost

During the standalone evaluation, record:

- Total response time
- Whether answers match the dashboard
- Which tools were selected
- Incorrect or unsupported claims
- HTTP `429` throttling
- Questions that need additional controlled tools
- Approximate tokens and cost per request
- Whether users understand current-state versus historical analysis

In the Azure portal, open the Foundry resource and inspect **Metrics**. Monitor
available metrics for:

- Requests
- Successful and failed calls
- Token usage
- Latency
- Throttled requests
- HTTP response codes

Use **Cost Management** to configure:

- A budget for the Foundry resource group
- Cost alerts
- A resource-group tag such as `Workload=ArcDashboard`
- A separate development/test budget before broader use

## 11. Troubleshooting

| Error | Likely cause | Resolution |
|---|---|---|
| Configuration rejects the endpoint | Full API URL, project endpoint, non-Azure hostname, or nonstandard port entered | Enter only the `.openai.azure.com` or `.services.ai.azure.com` resource endpoint |
| `401 Unauthorized` | The isolated Foundry CLI session expired or the wrong Foundry tenant was selected | Enter the Foundry tenant ID and repeat **Sign in to Foundry tenant** |
| `403 Forbidden` | Missing inference role or role assigned at the wrong resource | Assign `Cognitive Services OpenAI User` on the Foundry resource and wait for propagation |
| `404 Not Found` | Incorrect endpoint or deployment name | Copy the resource endpoint and exact deployment name from Foundry |
| `429 Too Many Requests` | Model quota or throughput exceeded | Wait and retry, reduce concurrent usage, or increase available model quota |
| `502 Bad Gateway` from the dashboard | Foundry call failed, configuration is wrong, or the model is incompatible | Check dashboard console output, role assignment, endpoint, deployment status, and playground |
| Model works in the playground but not the dashboard | The playground and isolated Foundry sign-in use different users or tenants | Repeat the Foundry device sign-in with the identity assigned to the resource |
| Public access is disabled | The desktop cannot reach a private endpoint | Connect through the required VNet, VPN, or private network |
| Tool-call failure | The model does not properly support chat-completions tool calling | Deploy a compatible Azure OpenAI model and use that deployment name |
| Snapshot-loading message | Initial Arc inventory is still building | Wait briefly and submit the question again |

## 12. Data and security considerations

The standalone assistant sends these items to the selected Foundry model as
needed:

- The user's question
- Current dashboard summary values
- Projected server, SQL, or Kubernetes fields returned by bounded tools
- Resource names, resource groups, health, lifecycle, version, update, and
  posture information
- Bounded, redacted metric and event results from an explicitly selected
  single-server monitoring snapshot

Search tools omit Azure resource IDs and cap returned rows at 25. Resource
names and operational posture can still be organizationally sensitive. Select
a deployment type and region consistent with the organization's
data-processing requirements.

The dashboard:

- Does not store a model API key
- Keeps Foundry authentication isolated from the Azure CLI profile used for
  Arc inventory
- Does not persist chat history
- Keeps conversation history only in the current browser tab
- Encrypts the separate single-server monitoring snapshot with AES-256-GCM
  using a Windows DPAPI CurrentUser-protected key
- Caps monitoring to one server, a maximum eight-hour rolling window, 12,000
  metric samples, 1,000 events, and fixed KQL templates
- Does not allow AI-triggered Azure changes
- Does not provide arbitrary query or command execution

## Official references

- [Create a Microsoft Foundry project](https://learn.microsoft.com/azure/foundry/how-to/create-projects)
- [Deploy Foundry models](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/deploy-foundry-models)
- [Foundry deployment types](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/deployment-types)
- [Azure OpenAI v1 API](https://learn.microsoft.com/azure/foundry/openai/api-version-lifecycle)
- [Foundry quotas and limits](https://learn.microsoft.com/azure/foundry/openai/quotas-limits)
- [Microsoft Foundry RBAC](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry)
