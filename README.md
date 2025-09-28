# Azure Agent Pools Setup Guide

This repo provides cross-platform scripts and documentation for provisioning Azure DevOps self-hosted agent pools on macOS, Linux, and Windows hosts. Each section walks you through creating the agent pool, generating the Personal Access Token (PAT), and running the automation scripts.

## Prerequisites
- Azure subscription and Azure DevOps organization (e.g. `https://dev.azure.com/<org>`).
- Personal Access Token (PAT) with **Agent Pools (Read & manage)** scope. You can generate it in Azure DevOps under **User settings → Personal Access Tokens**.
- `curl`/`tar` on Unix-like systems, `PowerShell 5.1+` (or PowerShell 7) on Windows.
- For Azure CLI automation: `az` CLI 2.50+ with the `azure-devops` extension.

Store your PAT in an environment variable before running the scripts to avoid prompt input:

```bash
export AZDO_PAT="<your_pat>"
```

In PowerShell use:

```powershell
$env:AZDO_PAT = '<your_pat>'
```

You can override the agent version with `AGENT_VERSION` (defaults to `3.233.1`), output directory with `AGENT_HOME`, and working directory with `WORK_DIR`.

## 1. Create (or reuse) an Agent Pool via Azure CLI

```bash
az login
az extension add --name azure-devops
az devops configure --defaults organization=https://dev.azure.com/<org> project=<project>

# Create a dedicated pool for self-hosted agents
az pipelines pool create \
  --name SelfHostedPool \
  --pool-type none

# Capture the pool identifier for reuse
POOL_ID=$(az pipelines pool list --query "[?name=='SelfHostedPool'].id" -o tsv)

# Create a project-scoped queue that points to the pool
az pipelines queue create \
  --name SelfHostedQueue \
  --pool-id $POOL_ID \
  --project <project>
```

Replace `<org>` and `<project>` with your Azure DevOps organization and project names. If the pool already exists, skip pool creation and move on to agent installation.

## 2. macOS Agent Installation

Script: `scripts/install-agent-macos.sh`

```bash
# Grant execute permissions (first run only)
chmod +x scripts/install-agent-macos.sh

# Usage
scripts/install-agent-macos.sh <organization-url> <pool-name> [agent-name]
```

Example:

```bash
scripts/install-agent-macos.sh https://dev.azure.com/contoso BuildPool mac-builder-01
```

The script will:
- Download the specified Azure Pipelines agent build for macOS.
- Configure the agent in unattended mode using your PAT.
- Install and start the launchd service so the agent persists after reboots.

## 3. Linux Agent Installation

Script: `scripts/install-agent-linux.sh`

```bash
chmod +x scripts/install-agent-linux.sh
scripts/install-agent-linux.sh <organization-url> <pool-name> [agent-name]
```

Example:

```bash
scripts/install-agent-linux.sh https://dev.azure.com/contoso BuildPool build-agent-ubuntu
```

What the script handles:
- Downloads the Linux x64 agent payload for the requested version.
- Installs required runtime dependencies via `installdependencies.sh`.
- Configures the agent with PAT authentication and registers it to the agent pool.
- Installs and starts the system service (via `svc.sh`) so the agent runs on boot.

> **Note:** On distros without `sudo`, run the script as root or adjust privilege escalation to suit your environment.

## 4. Windows Agent Installation

Script: `scripts/install-agent-windows.ps1`

```powershell
# From an elevated PowerShell prompt
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process

# Usage
.\scripts\install-agent-windows.ps1 -OrganizationUrl <url> -PoolName <pool> [-AgentName <name>] [-AgentVersion <version>]
```

Example:

```powershell
.\scripts\install-agent-windows.ps1 -OrganizationUrl https://dev.azure.com/contoso -PoolName BuildPool -AgentName win-builder-01
```

The script performs the following steps:
- Downloads the Windows x64 agent ZIP for the selected version.
- Installs any runtime dependencies via `installdependencies.cmd` when available.
- Runs an unattended `config.cmd` with PAT authorization and registers the agent as a Windows service.
- Starts the Windows service so jobs can queue immediately.

## 5. Validate the Agent

After running any installer script, confirm registration in Azure DevOps:

```bash
ez pipelines agent list --pool-name <pool-name>
```

You should see the agent name with status `online`. You can also queue a simple build pipeline to verify communication end-to-end.

## 6. Updating or Removing Agents

- To upgrade the agent, set `AGENT_VERSION` to the desired build number, rerun the script, and allow it to replace the existing installation.
- To stop and remove the service manually:
  - **macOS/Linux:** run `./svc.sh stop` then `./svc.sh uninstall` inside the agent folder.
  - **Windows:** run `.\svc stop` then `.\svc uninstall` from the agent directory (same pattern as `svc install` / `svc start`).

## 7. Troubleshooting

- **PAT rejected:** Ensure the PAT includes the Agent Pools scope and has not expired.
- **Dependency failures on Linux:** manually install `libssl`, `libicu`, `libkrb5`, and `curl` using your system's package manager, then rerun the script.
- **Service fails to start:** review the `_diag` directory in the agent folder for logs. Re-run the script after removing the existing agent directory to force a fresh configuration.
- **Firewall/proxy issues:** confirm outbound HTTPS access to `*.dev.azure.com`, `*.visualstudio.com`, and `vstsagentpackage.azureedge.net`.

## Directory Layout

```
.
├── README.md
└── scripts
    ├── install-agent-linux.sh
    ├── install-agent-macos.sh
    └── install-agent-windows.ps1
```

Feel free to adapt the scripts for advanced scenarios such as ephemeral agents, Kubernetes- or VM-scale sets, or key vault–backed secret retrieval.
