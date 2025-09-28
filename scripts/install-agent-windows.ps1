[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OrganizationUrl,
    [Parameter(Mandatory = $true)][string]$PoolName,
    [string]$AgentName = $env:COMPUTERNAME,
    [string]$AgentVersion = $(if ($env:AGENT_VERSION) { $env:AGENT_VERSION } else { '3.233.1' })
)

$ErrorActionPreference = 'Stop'

$AgentPackage = "vsts-agent-win-x64-$AgentVersion.zip"
$DownloadUrl = "https://vstsagentpackage.azureedge.net/agent/$AgentVersion/$AgentPackage"
$AgentHome = if ($env:AGENT_HOME) { $env:AGENT_HOME } else { Join-Path $env:USERPROFILE 'azdo\\windows-agent' }
$WorkDir = if ($env:WORK_DIR) { $env:WORK_DIR } else { '_work' }

if (-not (Test-Path $AgentHome)) {
    New-Item -ItemType Directory -Path $AgentHome | Out-Null
}

$pat = $env:AZDO_PAT
if (-not $pat) {
    $securePat = Read-Host -Prompt 'Enter Azure DevOps PAT (scope: Agent Pools (Read & manage))' -AsSecureString
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePat)
    try {
        $pat = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        if ($ptr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }
}

$zipPath = Join-Path $AgentHome $AgentPackage
if (-not (Test-Path $zipPath)) {
    Write-Host "Downloading agent $AgentVersion ..."
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipPath -UseBasicParsing
}

Write-Host 'Extracting agent payload ...'
Expand-Archive -Path $zipPath -DestinationPath $AgentHome -Force

$agentFolder = Join-Path $AgentHome "vsts-agent-win-x64-$AgentVersion"
Set-Location $agentFolder

if (Test-Path '.\\installdependencies.cmd') {
    Write-Host 'Installing agent runtime dependencies ...'
    .\\installdependencies.cmd
}

Write-Host 'Configuring agent ...'
$arguments = @(
    '--unattended',
    '--url', $OrganizationUrl,
    '--auth', 'pat',
    '--token', $pat,
    '--pool', $PoolName,
    '--agent', $AgentName,
    '--work', $WorkDir,
    '--runAsService',
    '--replace',
    '--acceptTeeEula'
)

& .\\config.cmd @arguments

Write-Host 'Installing Windows service ...'
& .\\svc install

Write-Host 'Starting service ...'
& .\\svc start

Write-Host "Agent $AgentName is running and connected to $PoolName."
