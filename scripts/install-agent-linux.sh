#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == "-h" || ${1:-} == "--help" || $# -lt 2 ]]; then
  echo "Usage: $0 <organization-url> <pool-name> [agent-name]"
  echo "Example: $0 https://dev.azure.com/contoso BuildPool build-agent-01"
  exit 1
fi

ORG_URL="$1"
POOL_NAME="$2"
AGENT_NAME="${3:-$(hostname)}"
AGENT_VERSION="${AGENT_VERSION:-3.233.1}"
AGENT_PACKAGE="vsts-agent-linux-x64-${AGENT_VERSION}.tar.gz"
DOWNLOAD_URL="https://vstsagentpackage.azureedge.net/agent/${AGENT_VERSION}/${AGENT_PACKAGE}"
AGENT_HOME="${AGENT_HOME:-$HOME/azdo/linux-agent}"
WORK_DIR="${WORK_DIR:-_work}"

PAT_TOKEN="${AZDO_PAT:-}"
if [[ -z "${PAT_TOKEN}" ]]; then
  read -rsp "Enter Azure DevOps PAT (scope: Agent Pools (Read & manage)): " PAT_TOKEN
  echo
fi

mkdir -p "${AGENT_HOME}"
cd "${AGENT_HOME}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required but was not found on PATH." >&2
  echo "Install curl via your package manager (e.g. sudo apt-get install curl) and rerun." >&2
  exit 1
fi

if [[ ! -f "${AGENT_PACKAGE}" ]]; then
  echo "Downloading agent ${AGENT_VERSION} ..."
  curl -fsSL "${DOWNLOAD_URL}" -o "${AGENT_PACKAGE}"
fi

tar -xzf "${AGENT_PACKAGE}"

pushd "vsts-agent-linux-x64-${AGENT_VERSION}" >/dev/null
trap 'popd >/dev/null' EXIT

if [[ -x ./bin/installdependencies.sh ]]; then
  echo "Installing agent runtime dependencies ..."
  sudo ./bin/installdependencies.sh
fi

echo "Configuring agent ..."
./config.sh \
  --unattended \
  --url "${ORG_URL}" \
  --auth pat \
  --token "${PAT_TOKEN}" \
  --pool "${POOL_NAME}" \
  --agent "${AGENT_NAME}" \
  --work "${WORK_DIR}" \
  --runAsService \
  --replace \
  --acceptTeeEula

echo "Installing service ..."
sudo ./svc.sh install

echo "Starting service ..."
sudo ./svc.sh start

echo "Agent ${AGENT_NAME} is running and connected to ${POOL_NAME}."
