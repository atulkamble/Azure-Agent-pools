#!/usr/bin/env bash
# Provision an Ubuntu VM in Azure and bootstrap it as a self-hosted Azure DevOps agent.
#
# Usage:
#   provision-azure-linux-agent.sh <organization-url> <pool-name> <resource-group> <location> <vm-name> [agent-name]
#
# Required environment variables:
#   AZDO_PAT         Personal Access Token with Agent Pools (Read & manage).
#
# Optional environment variables:
#   AGENT_VERSION    Agent version to install (defaults to 3.233.1).
#   AGENT_HOME       Installation directory on the VM.
#   WORK_DIR         Working directory name inside the agent folder (defaults to _work).
#   VM_SIZE          Azure VM size (defaults to Standard_D2s_v3).
#   VM_IMAGE         Azure image URN/alias (defaults to Ubuntu2204).
#   ADMIN_USERNAME   Admin user to create on the VM (defaults to azdoagent).
#   PUBLIC_IP        true/false to create a public IP (defaults to true).
#   VNET_NAME        Existing VNet to join (optional).
#   SUBNET_NAME      Existing subnet name (optional; requires VNET_NAME).
#   DATA_DISK_SIZE   Additional data disk size in GB (optional integer).
#   TAGS             Tag string to apply to the VM (defaults to "purpose=azdo-agent").
#
# Notes:
#   - You must be logged in with `az login` and have the azure-devops extension installed if you plan to
#     interact with Azure DevOps via CLI after provisioning.
#   - The PAT is echoed into the run-command payload; rotate it afterward if audit requirements demand.

set -euo pipefail

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  sed -n '2,40p' "$0"
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

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI (az) is required but not found on PATH." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LINUX_INSTALL_SCRIPT="$SCRIPT_DIR/install-agent-linux.sh"
if [[ ! -f "$LINUX_INSTALL_SCRIPT" ]]; then
  echo "Required script $LINUX_INSTALL_SCRIPT not found." >&2
  exit 1
fi

AGENT_VERSION="${AGENT_VERSION:-3.233.1}"
VM_SIZE="${VM_SIZE:-Standard_D2s_v3}"
VM_IMAGE="${VM_IMAGE:-Ubuntu2204}"
ADMIN_USERNAME="${ADMIN_USERNAME:-azdoagent}"
PUBLIC_IP="${PUBLIC_IP:-true}"
VNET_NAME="${VNET_NAME:-}"
SUBNET_NAME="${SUBNET_NAME:-}"
DATA_DISK_SIZE="${DATA_DISK_SIZE:-}"
TAGS="${TAGS:-purpose=azdo-agent}"
AGENT_HOME="${AGENT_HOME:-/home/${ADMIN_USERNAME}/azdo/linux-agent}"
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
  --authentication-type ssh
  --generate-ssh-keys
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

INSTALL_SCRIPT_B64=$(base64 < "$LINUX_INSTALL_SCRIPT" | tr -d '\n')

REMOTE_SCRIPT_TEMPLATE=$(cat <<'EOS'
set -euo pipefail
INSTALL_SCRIPT_B64="%%INSTALL_SCRIPT_B64%%"
echo "$INSTALL_SCRIPT_B64" | base64 -d > /tmp/install-agent-linux.sh
chmod +x /tmp/install-agent-linux.sh
export AZDO_PAT="%%AZDO_PAT%%"
export AGENT_VERSION="%%AGENT_VERSION%%"
export AGENT_HOME="%%AGENT_HOME%%"
export WORK_DIR="%%WORK_DIR%%"
/tmp/install-agent-linux.sh "%%ORG_URL%%" "%%POOL_NAME%%" "%%AGENT_NAME%%"
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
  --command-id RunShellScript \
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
  - Securely rotate the PAT if necessary; it was transferred to the VM via run-command.
  - Optionally lock down networking (NSG rules) and enable auto-shutdown/backups per your policy.
NOTE
