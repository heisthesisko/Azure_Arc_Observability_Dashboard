#!/usr/bin/env sh
set -eu

data_root="${ARC_DASHBOARD_DATA_ROOT:-/var/lib/arc-dashboard}"
bind_address="${ARC_DASHBOARD_BIND_ADDRESS:-0.0.0.0}"
port="${ARC_DASHBOARD_PORT:-8766}"
access_mode="${ARC_DASHBOARD_ACCESS_MODE:-LocalSingleUser}"
auth_mode="${ARC_DASHBOARD_AZURE_AUTH_MODE:-AzureCli}"

mkdir -p "$data_root"
chmod 700 "$data_root" 2>/dev/null || true

if [ "$auth_mode" = "WorkloadIdentity" ]; then
  : "${AZURE_CLIENT_ID:?AZURE_CLIENT_ID is required for workload identity}"
  : "${AZURE_TENANT_ID:?AZURE_TENANT_ID is required for workload identity}"
  token_file="${AZURE_FEDERATED_TOKEN_FILE:-/var/run/secrets/azure/tokens/azure-identity-token}"
  if [ ! -r "$token_file" ]; then
    echo "Federated identity token is not readable: $token_file" >&2
    exit 1
  fi
  az login --service-principal \
    --username "$AZURE_CLIENT_ID" \
    --tenant "$AZURE_TENANT_ID" \
    --federated-token "$(cat "$token_file")" \
    --allow-no-subscriptions \
    --output none
  if [ -n "${AZURE_SUBSCRIPTION_ID:-}" ]; then
    az account set --subscription "$AZURE_SUBSCRIPTION_ID"
  fi
fi

exec pwsh -NoLogo -NoProfile -File /opt/arc-dashboard/server.ps1 \
  -NoBrowser \
  -BindAddress "$bind_address" \
  -Port "$port" \
  -DataRoot "$data_root" \
  -AccessMode "$access_mode" \
  -AdministratorUsers "${ARC_DASHBOARD_ADMIN_USERS:-}"
