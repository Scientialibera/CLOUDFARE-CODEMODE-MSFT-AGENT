param(
    [string]$EnvPath = "$PSScriptRoot\deploy-env.json"
)

function Write-Step([string]$Script, [string]$Message) {
    Write-Host "`n[$Script] $Message" -ForegroundColor Cyan
}

if (-not (Test-Path $EnvPath)) {
    Write-Error "deploy-env.json not found. Run deploy.ps1 first."
    exit 1
}

$env = Get-Content $EnvPath | ConvertFrom-Json
$rg = $env.resourceGroup
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$scriptName = "deploy-apps"

# ===================================================================
# 1. Deploy storage_api
# ===================================================================

Write-Step $scriptName "1. Packaging storage_api"
$storageApiDir = Join-Path $repoRoot "storage_api"
$storageApiZip = Join-Path $PSScriptRoot "storage_api.zip"

Push-Location $storageApiDir
if (Test-Path $storageApiZip) { Remove-Item $storageApiZip }
Compress-Archive -Path "app.py","requirements.txt" -DestinationPath $storageApiZip
Pop-Location

Write-Step $scriptName "1b. Deploying storage_api to '$($env.storageApiAppName)'"
az webapp deploy --resource-group $rg --name $env.storageApiAppName --src-path $storageApiZip --type zip | Out-Null
Write-Output "  Deployed: $($env.storageApiUrl)"

# ===================================================================
# 2. Deploy chatbot_api (agent_app)
# ===================================================================

Write-Step $scriptName "2. Packaging chatbot_api"
$agentAppDir = Join-Path $repoRoot "agent_app"
$chatbotZip = Join-Path $PSScriptRoot "chatbot_api.zip"

Push-Location $agentAppDir
if (Test-Path $chatbotZip) { Remove-Item $chatbotZip }
Compress-Archive -Path "chatbot_api.py","requirements.txt" -DestinationPath $chatbotZip
Pop-Location

Write-Step $scriptName "2b. Deploying chatbot_api to '$($env.chatbotApiAppName)'"
az webapp deploy --resource-group $rg --name $env.chatbotApiAppName --src-path $chatbotZip --type zip | Out-Null
Write-Output "  Deployed: $($env.chatbotApiUrl)"

# ===================================================================
# Cleanup
# ===================================================================

Remove-Item $storageApiZip -ErrorAction SilentlyContinue
Remove-Item $chatbotZip -ErrorAction SilentlyContinue

Write-Step $scriptName "APP DEPLOYMENT COMPLETE"
Write-Output ""
Write-Output "  Storage API:  $($env.storageApiUrl)/health"
Write-Output "  Chatbot API:  $($env.chatbotApiUrl)/health"
Write-Output "  Chatbot docs: $($env.chatbotApiUrl)/docs"
