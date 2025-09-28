#!/usr/bin/env bash
# Provision a Windows Server VM in Azure and bootstrap it as a self-hosted Azure DevOps agent.
#
# Usage:
#   provision-azure-windows-agent.sh <organization-url> <pool-name> <resource-group> <location> <vm-name> [agent-name]
#
# Required environment variables:
#   AZDO_PAT            Personal Access Token with Agent Pools (Read & manage).
#   WIN_ADMIN_PASSWORD  Password for the Windows administrator account (meets complexity rules).
#
# Optional environment variables:
#   AGENT_VERSION       Agent version to install (defaults to 3.233.1).
#   AGENT_HOME          Installation directory on the VM.
#   WORK_DIR            Working directory inside the agent folder (defaults to _work).
#   VM_SIZE             Azure VM size (defaults to Standard_D4s_v3).
#   VM_IMAGE            Azure image URN/alias (defaults to Win2022Datacenter).
#   ADMIN_USERNAME      Administrator username to create (defaults to azdoagent).
#   PUBLIC_IP           true/false to create a public IP (defaults to true).
#   VNET_NAME           Existing VNet to join (optional).
#   SUBNET_NAME         Existing subnet name (optional; requires VNET_NAME).
#   DATA_DISK_SIZE      Additional data disk size in GB (optional integer).
#   TAGS                Tag string to apply to the VM (defaults to "purpose=azdo-agent").
#
# Security: The PAT and administrator password are sent to Azure via the VM create / run-command APIs.
#           Rotate secrets after provisioning if your security policy requires it.

set -euo pipefail

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  sed -n '2,44p' "$0"
  exit 0
fi

if [[ $# -lt 5 ]]; then
  echo "Usage: $0 <organization-url> <pool-name> <resource-group> <location> <vm-name> [agent-name]" >&2
  exit 1
fi

ORG_URL="$1"
POOL_NAME="$2"
RESOURCE_GROUP="$3"
LOCATION="$4"
VM_NAME="$5"
AGENT_NAME="${6:-$VM_NAME}"

if [[ -z "${AZDO_PAT:-}" ]]; then
  echo "AZDO_PAT environment variable must be set." >&2
  exit 1
fi

if [[ -z "${WIN_ADMIN_PASSWORD:-}" ]]; then
  echo "WIN_ADMIN_PASSWORD environment variable must be set." >&2
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI (az) is required but not found on PATH." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WINDOWS_INSTALL_SCRIPT="$SCRIPT_DIR/install-agent-windows.ps1"
if [[ ! -f "$WINDOWS_INSTALL_SCRIPT" ]]; then
  echo "Required script $WINDOWS_INSTALL_SCRIPT not found." >&2
  exit 1
fi

AGENT_VERSION="${AGENT_VERSION:-3.233.1}"
VM_SIZE="${VM_SIZE:-Standard_D4s_v3}"
VM_IMAGE="${VM_IMAGE:-Win2022Datacenter}"
ADMIN_USERNAME="${ADMIN_USERNAME:-azdoagent}"
PUBLIC_IP="${PUBLIC_IP:-true}"
VNET_NAME="${VNET_NAME:-}"
SUBNET_NAME="${SUBNET_NAME:-}"
DATA_DISK_SIZE="${DATA_DISK_SIZE:-}"
TAGS="${TAGS:-purpose=azdo-agent}"
AGENT_HOME="${AGENT_HOME:-C:/azdo/windows-agent}"
WORK_DIR="${WORK_DIR:-_work}"

if [[ "$PUBLIC_IP" != "true" && "$PUBLIC_IP" != "false" ]]; then
  echo "PUBLIC_IP must be 'true' or 'false'." >&2
  exit 1
fi

if [[ -n "$SUBNET_NAME" && -z "$VNET_NAME" ]]; then
  echo "SUBNET_NAME requires VNET_NAME to be set." >&2
  exit 1
fi

echo "Creating resource group $RESOURCE_GROUP in $LOCATION ..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --tags "$TAGS" --output none

CREATE_ARGS=(
  az vm create
  --resource-group "$RESOURCE_GROUP"
  --name "$VM_NAME"
  --image "$VM_IMAGE"
  --size "$VM_SIZE"
  --admin-username "$ADMIN_USERNAME"
  --admin-password "$WIN_ADMIN_PASSWORD"
  --authentication-type password
  --tags "$TAGS"
  --public-ip-sku Standard
  --output json
)

if [[ "$PUBLIC_IP" == "false" ]]; then
  CREATE_ARGS+=(--public-ip-address "")
fi

if [[ -n "$VNET_NAME" ]]; then
  CREATE_ARGS+=(--vnet-name "$VNET_NAME")
fi

if [[ -n "$SUBNET_NAME" ]]; then
  CREATE_ARGS+=(--subnet "$SUBNET_NAME")
fi

if [[ -n "$DATA_DISK_SIZE" ]]; then
  CREATE_ARGS+=(--data-disk-sizes-gb "$DATA_DISK_SIZE")
fi

echo "Creating VM $VM_NAME (image: $VM_IMAGE, size: $VM_SIZE) ..."
VM_CREATE_OUTPUT="$(${CREATE_ARGS[@]})"

PUBLIC_IP_ADDRESS=$(echo "$VM_CREATE_OUTPUT" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("publicIpAddress",""))' 2>/dev/null || true)
PRIVATE_IP_ADDRESS=$(echo "$VM_CREATE_OUTPUT" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("privateIpAddress",""))' 2>/dev/null || true)

az vm wait --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --created --output none

INSTALL_SCRIPT_B64=$(base64 < "$WINDOWS_INSTALL_SCRIPT" | tr -d '\n')

REMOTE_SCRIPT_TEMPLATE=$(cat <<'EOS'
$ErrorActionPreference = 'Stop'
$scriptBytes = [Convert]::FromBase64String("%%INSTALL_SCRIPT_B64%%")
$scriptPath = "C:\\azdo\\install-agent-windows.ps1"
$scriptDir = Split-Path $scriptPath
if (-not (Test-Path $scriptDir)) {
    New-Item -ItemType Directory -Path $scriptDir | Out-Null
}
[System.IO.File]::WriteAllBytes($scriptPath, $scriptBytes)
$env:AZDO_PAT = "%%AZDO_PAT%%"
$env:AGENT_VERSION = "%%AGENT_VERSION%%"
$env:AGENT_HOME = "%%AGENT_HOME%%"
$env:WORK_DIR = "%%WORK_DIR%%"
& $scriptPath -OrganizationUrl "%%ORG_URL%%" -PoolName "%%POOL_NAME%%" -AgentName "%%AGENT_NAME%%"
EOS
)

REMOTE_SCRIPT=${REMOTE_SCRIPT_TEMPLATE//%%INSTALL_SCRIPT_B64%%/$INSTALL_SCRIPT_B64}
REMOTE_SCRIPT=${REMOTE_SCRIPT//%%AZDO_PAT%%/$AZDO_PAT}
REMOTE_SCRIPT=${REMOTE_SCRIPT//%%AGENT_VERSION%%/$AGENT_VERSION}
REMOTE_SCRIPT=${REMOTE_SCRIPT//%%AGENT_HOME%%/$AGENT_HOME}
REMOTE_SCRIPT=${REMOTE_SCRIPT//%%WORK_DIR%%/$WORK_DIR}
REMOTE_SCRIPT=${REMOTE_SCRIPT//%%ORG_URL%%/$ORG_URL}
REMOTE_SCRIPT=${REMOTE_SCRIPT//%%POOL_NAME%%/$POOL_NAME}
REMOTE_SCRIPT=${REMOTE_SCRIPT//%%AGENT_NAME%%/$AGENT_NAME}

printf '\nBootstrapping Azure DevOps agent on %s ...\n' "$VM_NAME"
RUN_OUTPUT=$(az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "$REMOTE_SCRIPT" \
  --query 'value[0].message' -o tsv)

echo "$RUN_OUTPUT"

echo "\nProvisioning complete. Connection details:"
if [[ -n "$PUBLIC_IP_ADDRESS" ]]; then
  printf '  Public IP : %s\n' "$PUBLIC_IP_ADDRESS"
fi
if [[ -n "$PRIVATE_IP_ADDRESS" ]]; then
  printf '  Private IP: %s\n' "$PRIVATE_IP_ADDRESS"
fi
printf '  Admin user: %s\n' "$ADMIN_USERNAME"

cat <<NOTE
\nNext steps:
  - Verify the agent is online: az pipelines agent list --pool-name "$POOL_NAME"
  - Reset/rotate the admin password and PAT per your security policy.
  - Harden the VM (NSG rules, Just-In-Time access, Defender, etc.) before production use.
NOTE
