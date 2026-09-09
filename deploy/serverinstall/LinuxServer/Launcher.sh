#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pwsh >/dev/null 2>&1; then
  printf '%s\n' 'PowerShell 7.4 or later (pwsh) is required.' >&2
  printf '%s\n' 'Install PowerShell for your Linux distribution, then run this launcher again.' >&2
  exit 1
fi

exec pwsh -NoLogo -NoProfile -File "${SCRIPT_DIR}/Start-Dashboard.ps1" "$@"
