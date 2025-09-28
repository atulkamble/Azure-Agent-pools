# Azure Agent Pools Setup Guide

This repo provides cross-platform tooling to provision Azure DevOps self-hosted agent pools on macOS, Linux, and Windows hosts—either on hardware you control or remotely on Azure virtual machines. Each section walks you through creating the agent pool, generating the Personal Access Token (PAT), and running the provided automation.

## Prerequisites
- Azure subscription and Azure DevOps organization (e.g. `https://dev.azure.com/<org>`)
- Personal Access Token (PAT) with **Agent Pools (Read & manage)** scope (Azure DevOps → **User settings → Personal Access Tokens**)
- Azure CLI 2.50+ with the `azure-devops` extension (`az extension add --name azure-devops`)
- For local/manual installs: `curl`/`tar` on Unix-like systems, PowerShell 5.1+ (or PowerShell 7) on Windows
- Optional but recommended: access to an Azure Key Vault for storing PATs and admin credentials when automating from Azure

Before running any script, export your PAT so the automation can pick it up:

```bash
export AZDO_PAT="<your_pat>"
```

In PowerShell use:

```powershell
$env:AZDO_PAT = '<your_pat>'
```

You can override the agent version with `AGENT_VERSION` (defaults to `3.233.1`), the installation directory with `AGENT_HOME`, and the working directory with `WORK_DIR`.

## 1. Create (or Reuse) an Agent Pool via Azure CLI

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

Replace `<org>` and `<project>` with your Azure DevOps organization and project names. If the pool already exists, skip pool creation and move on to agent provisioning.

## 2. Provision Azure-Hosted Agents (Remote)

Use these automation scripts when you want Azure VMs to host the agents. Both scripts assume you are running them from a workstation with the Azure CLI authenticated to your subscription.

### 2.1 Linux VM (Ubuntu)

Script: `scripts/provision-azure-linux-agent.sh`

```bash
export AZDO_PAT='<pat>'
# Optional tweaks
export VM_SIZE=Standard_D2s_v3
export ADMIN_USERNAME=azdoagent

scripts/provision-azure-linux-agent.sh \
  https://dev.azure.com/contoso \
  SelfHostedPool \
  rg-azdo-linux \
  eastus \
  vm-azdo-linux-01 \
  linux-agent-01
```

What the script does:
- Creates (or reuses) the specified resource group and an Ubuntu VM (defaults to `Ubuntu2204`)
- Generates SSH keys if needed, optionally attaches to an existing VNet/subnet, and tags the VM
- Pushes `install-agent-linux.sh` to the VM via `az vm run-command` and runs it in unattended mode
- Returns the VM IP information so you can secure it (NSG rules, Bastion, etc.) afterwards

Security considerations:
- The PAT is embedded in the run-command payload; rotate it after the VM is configured or store it in an Azure Key Vault and pull it during the run-command step
- Lock down inbound access (NSG / Azure Firewall) and enable auto-shutdown or backups based on your policy

Additional environment variables you can set before invocation:
- `VM_IMAGE` (e.g. `Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest`), `PUBLIC_IP` (`true|false`), `VNET_NAME`, `SUBNET_NAME`, `DATA_DISK_SIZE`
- `AGENT_HOME`, `WORK_DIR` for custom installation paths, `TAGS` for governance

### 2.2 Windows VM (Windows Server)

Script: `scripts/provision-azure-windows-agent.sh`

```bash
export AZDO_PAT='<pat>'
export WIN_ADMIN_PASSWORD='F@br1c@M0d!123'  # must satisfy Azure complexity rules
# Optional tweaks
export VM_SIZE=Standard_D4s_v3
export ADMIN_USERNAME=azdoadmin

scripts/provision-azure-windows-agent.sh \
  https://dev.azure.com/contoso \
  SelfHostedPool \
  rg-azdo-windows \
  eastus \
  vm-azdo-win-01 \
  win-agent-01
```

What the script does:
- Creates (or reuses) the resource group and a Windows Server VM (defaults to `Win2022Datacenter`)
- Applies your admin credentials, optional VNet/subnet tags, and desired VM size
- Uploads `install-agent-windows.ps1` using `az vm run-command` and configures the agent as a Windows service
- Prints the VM IP information so you can finalize access controls (NSG, Just-In-Time, etc.)

Security considerations:
- Store `WIN_ADMIN_PASSWORD` in a secure secret store (Key Vault, password manager) and rotate it after provisioning
- The PAT is transferred via run-command; rotate it or move to a managed secret solution after setup

Environment variables you can set before invocation mirror the Linux script (`VM_IMAGE`, `PUBLIC_IP`, `VNET_NAME`, `SUBNET_NAME`, `DATA_DISK_SIZE`, `AGENT_HOME`, `WORK_DIR`, `TAGS`). Use Windows-style paths (`C:/...`) when overriding `AGENT_HOME`.

## 3. macOS Agent Installation (Manual/Local)

Script: `scripts/install-agent-macos.sh`

```bash
chmod +x scripts/install-agent-macos.sh
scripts/install-agent-macos.sh <organization-url> <pool-name> [agent-name]
```

Example:

```bash
scripts/install-agent-macos.sh https://dev.azure.com/contoso SelfHostedPool mac-builder-01
```

The script will download the macOS agent bundle, configure it using your PAT, and register a launchd service so the agent survives reboots.

## 4. Linux Agent Installation (Manual/Local)

Script: `scripts/install-agent-linux.sh`

```bash
chmod +x scripts/install-agent-linux.sh
scripts/install-agent-linux.sh <organization-url> <pool-name> [agent-name]
```

Example:

```bash
scripts/install-agent-linux.sh https://dev.azure.com/contoso SelfHostedPool build-agent-ubuntu
```

The script downloads the Linux x64 agent, installs runtime dependencies via `installdependencies.sh`, configures the agent with PAT authentication, and registers the systemd service (`svc.sh`).

> **Note:** On distros without `sudo`, run the script as root or replace the privilege escalation command.

## 5. Windows Agent Installation (Manual/Local)

Script: `scripts/install-agent-windows.ps1`

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process

.\scripts\install-agent-windows.ps1 `
  -OrganizationUrl https://dev.azure.com/contoso `
  -PoolName SelfHostedPool `
  -AgentName win-builder-01
```

The script downloads the Windows x64 agent archive, installs dependencies, runs an unattended `config.cmd` with PAT authorization, and registers the Windows service.

## 6. Validate the Agent

After running any installer (local or Azure-hosted), confirm registration in Azure DevOps:

```bash
ez pipelines agent list --pool-name <pool-name>
```

You should see the agent name with status `online`. Queue a simple build to confirm end-to-end connectivity.

## 7. Updating or Removing Agents

- To upgrade, set `AGENT_VERSION` to the desired build and rerun the relevant script; it will replace the existing installation
- To stop and remove the service manually:
  - **macOS/Linux:** run `./svc.sh stop` then `./svc.sh uninstall` inside the agent directory
  - **Windows:** run `.\svc stop` then `.\svc uninstall` from the agent directory (same pattern as `svc install` / `svc start`)
- For Azure-hosted VMs: use `az vm deallocate` or `az vm delete` when you no longer need the capacity, and clean up the resource group to avoid charges

## 8. Troubleshooting

- **PAT rejected:** Ensure the PAT includes the Agent Pools scope and has not expired
- **Dependency failures on Linux:** manually install `libssl`, `libicu`, `libkrb5`, and `curl`, then rerun the script
- **Service fails to start:** inspect the `_diag` folder inside the agent directory. Remove the agent folder and rerun the script for a clean configuration
- **Firewall/proxy issues:** verify outbound HTTPS access to `*.dev.azure.com`, `*.visualstudio.com`, and `vstsagentpackage.azureedge.net`
- **Azure VM provisioning issues:** run with `set -x` (bash) or inspect the `RunCommand` output via `az vm show --instance-view --query instanceView.extensions` to review errors

## Directory Layout

```
.
├── README.md
└── scripts
    ├── install-agent-linux.sh
    ├── install-agent-macos.sh
    ├── install-agent-windows.ps1
    ├── provision-azure-linux-agent.sh
    └── provision-azure-windows-agent.sh
```

Here’s a **basic guide with sample codes** to understand and use **Azure Pipelines agent pools** 👇

---

# 🔹 Azure Pipelines – Pool Basics

In Azure DevOps, **pools** define the group of agents where your pipeline jobs will run.
Every `pool` contains **agents** (Microsoft-hosted or Self-hosted).

---

## 1️⃣ Example – Using Microsoft-hosted agent

```yaml
# azure-pipelines.yml
pool:
  vmImage: 'ubuntu-latest'

steps:
- script: echo "Running on Microsoft-hosted agent (Ubuntu)"
```

✅ This runs on an **Ubuntu VM** provided by Azure DevOps.
Other available images: `windows-latest`, `macos-latest`.

---

## 2️⃣ Example – Using a Self-hosted agent pool

Suppose you created a pool in Azure DevOps called `MySelfHostedPool` and added an agent to it.

```yaml
# azure-pipelines.yml
pool:
  name: 'MySelfHostedPool'

steps:
- script: echo "Running on Self-hosted agent"
```

---

## 3️⃣ Example – Targeting a specific Agent by demand

You can filter jobs within a pool using **demands** (capabilities).

```yaml
pool:
  name: 'MySelfHostedPool'
  demands:
    - Agent.Name -equals MyLinuxAgent

steps:
- script: echo "This runs on MyLinuxAgent"
```

---

## 4️⃣ Example – Parallel jobs in a pool

```yaml
jobs:
- job: Build
  pool:
    vmImage: 'ubuntu-latest'
  steps:
  - script: echo "Building project"

- job: Test
  pool:
    vmImage: 'windows-latest'
  steps:
  - script: echo "Running tests on Windows"
```

Here, **jobs run in parallel** on different agents.

---

## 5️⃣ Example – Pipeline with matrix strategy

Useful for testing on multiple OS versions:

```yaml
jobs:
- job: TestMatrix
  strategy:
    matrix:
      linux:
        vmImage: 'ubuntu-latest'
      windows:
        vmImage: 'windows-latest'
  pool:
    vmImage: $(vmImage)
  steps:
  - script: echo "Running on $(vmImage)"
```

---

🔑 **Key Notes:**

* `pool: vmImage` → Microsoft-hosted
* `pool: name` → Self-hosted
* Use **demands** if multiple agents are in the pool.
* Each job runs on a separate agent.

---


