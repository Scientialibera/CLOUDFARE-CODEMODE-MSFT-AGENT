param(
    [string]$ConfigPath = "$PSScriptRoot\deploy.config.toml"
)

# ===========================================================================
# Helpers
# ===========================================================================

function Write-Step([string]$Script, [string]$Message) {
    Write-Host "`n[$Script] $Message" -ForegroundColor Cyan
}

function Parse-Toml([string]$Path) {
    $config = @{}; $section = $null
    foreach ($line in Get-Content $Path) {
        $line = $line -replace '#.*$', '' | ForEach-Object { $_.Trim() }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1]; $config[$section] = @{}; continue
        }
        if ($line -match '^(\w+)\s*=\s*(.+)$') {
            $k = $Matches[1]; $v = $Matches[2].Trim().Trim('"').Trim("'")
            if ($v -match '^\[.*\]$') {
                $v = ($v.Trim('[',']') -split ',') | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ -ne '' }
            }
            if ($section) { $config[$section][$k] = $v } else { $config[$k] = $v }
        }
    }
    return $config
}

function Ensure-RoleAssignment {
    param([string]$PrincipalId, [string]$PrincipalType = "ServicePrincipal", [string]$Scope, [string]$Role)
    $existing = az role assignment list --assignee $PrincipalId --scope $Scope --role $Role --query "length(@)" -o tsv 2>$null
    if ($existing -eq "0" -or [string]::IsNullOrWhiteSpace($existing)) {
        az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type $PrincipalType --scope $Scope --role $Role | Out-Null
        Write-Output "    Assigned '$Role' to $PrincipalId"
    } else {
        Write-Output "    '$Role' already assigned"
    }
}

# ===========================================================================
# Load config
# ===========================================================================

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found: $ConfigPath. Copy deploy.config.example.toml to deploy.config.toml and edit it."
    exit 1
}

$config = Parse-Toml -Path $ConfigPath
$scriptName = "deploy"

$subscriptionId = $config.azure.subscription_id
if ([string]::IsNullOrWhiteSpace($subscriptionId)) { $subscriptionId = az account show --query id -o tsv }

$location = if ($config.azure.location) { $config.azure.location } else { "eastus" }
$rg       = if ($config.azure.resource_group) { $config.azure.resource_group } else { "rg-codemode-agent" }
$prefix   = if ($config.naming.prefix) { $config.naming.prefix.ToLower() } else { "codeagent" }

$storageAccountName = "${prefix}storage" -replace '[^a-z0-9]',''
$appServicePlanName = "plan-$prefix"
$storageApiAppName  = "app-${prefix}-storageapi"
$chatbotApiAppName  = "app-${prefix}-chatbot"

$openAiAccount   = $config.openai.account_name
$openAiRg        = if ($config.openai.resource_group) { $config.openai.resource_group } else { $rg }
$openAiDeployment = if ($config.openai.deployment_name) { $config.openai.deployment_name } else { "gpt-5-mini" }

$codemodeMcpUrl = if ($config.cloudflare.codemode_mcp_url) { $config.cloudflare.codemode_mcp_url } else { "http://localhost:8787/mcp" }

$containers = if ($config.storage.containers) { @($config.storage.containers) } else { @("data") }

Write-Step $scriptName "Configuration"
Write-Output "  Subscription:     $subscriptionId"
Write-Output "  Resource Group:   $rg"
Write-Output "  Location:         $location"
Write-Output "  Storage Account:  $storageAccountName"
Write-Output "  App Service Plan: $appServicePlanName"
Write-Output "  Storage API App:  $storageApiAppName"
Write-Output "  Chatbot API App:  $chatbotApiAppName"
Write-Output "  OpenAI Account:   $openAiAccount (in $openAiRg)"
Write-Output "  Codemode MCP URL: $codemodeMcpUrl"

az account set --subscription $subscriptionId

$executorObjectId = az ad signed-in-user show --query id -o tsv
if ([string]::IsNullOrWhiteSpace($executorObjectId)) { throw "Could not resolve signed-in user." }

# ===================================================================
# 1. Resource Group
# ===================================================================

Write-Step $scriptName "1. Resource Group '$rg'"
$rgExists = az group exists --name $rg -o tsv
if ($rgExists -ne "true") { az group create --name $rg --location $location | Out-Null }

# ===================================================================
# 2. Storage Account + containers
# ===================================================================

Write-Step $scriptName "2. Storage Account '$storageAccountName'"
$storageExists = az storage account list --resource-group $rg --query "[?name=='$storageAccountName'] | length(@)" -o tsv
if ($storageExists -eq "0") {
    az storage account create `
        --resource-group $rg `
        --name $storageAccountName `
        --location $location `
        --sku Standard_LRS `
        --kind StorageV2 `
        --hns true `
        --min-tls-version TLS1_2 `
        --allow-blob-public-access false | Out-Null
}
$storageScope = az storage account show --resource-group $rg --name $storageAccountName --query id -o tsv
$storageAccountUrl = "https://$storageAccountName.blob.core.windows.net/"

Ensure-RoleAssignment -PrincipalId $executorObjectId -PrincipalType User -Scope $storageScope -Role "Storage Blob Data Contributor"

foreach ($c in $containers) {
    $exists = az storage container exists --account-name $storageAccountName --name $c --auth-mode login --query exists -o tsv 2>$null
    if ($exists -ne "true") {
        az storage container create --account-name $storageAccountName --name $c --auth-mode login | Out-Null
        Write-Output "    Created container: $c"
    } else {
        Write-Output "    Container exists: $c"
    }
}

# ===================================================================
# 3. App Service Plan (Linux, Python)
# ===================================================================

Write-Step $scriptName "3. App Service Plan '$appServicePlanName'"
$planExists = az appservice plan list --resource-group $rg --query "[?name=='$appServicePlanName'] | length(@)" -o tsv
if ($planExists -eq "0") {
    az appservice plan create `
        --resource-group $rg `
        --name $appServicePlanName `
        --location $location `
        --sku B1 `
        --is-linux | Out-Null
}

# ===================================================================
# 4. Storage API Web App
# ===================================================================

Write-Step $scriptName "4. Storage API Web App '$storageApiAppName'"
$storageAppExists = az webapp list --resource-group $rg --query "[?name=='$storageApiAppName'] | length(@)" -o tsv
if ($storageAppExists -eq "0") {
    az webapp create `
        --resource-group $rg `
        --plan $appServicePlanName `
        --name $storageApiAppName `
        --runtime "PYTHON:3.13" | Out-Null
}

az webapp identity assign --resource-group $rg --name $storageApiAppName | Out-Null
$storageApiPrincipalId = az webapp identity show --resource-group $rg --name $storageApiAppName --query principalId -o tsv

Write-Step $scriptName "4b. Storage API RBAC + Settings"
Ensure-RoleAssignment -PrincipalId $storageApiPrincipalId -Scope $storageScope -Role "Storage Blob Data Contributor"

az webapp config appsettings set --resource-group $rg --name $storageApiAppName --settings `
    "AZURE_STORAGE_ACCOUNT_URL=$storageAccountUrl" `
    "SCM_DO_BUILD_DURING_DEPLOYMENT=true" `
    "WEBSITE_STARTUP_COMMAND=gunicorn -w 2 -k uvicorn.workers.UvicornWorker app:app --bind 0.0.0.0:8000" | Out-Null

$storageApiFqdn = az webapp show --resource-group $rg --name $storageApiAppName --query defaultHostName -o tsv
$storageApiUrl = "https://$storageApiFqdn"
Write-Output "  Storage API URL: $storageApiUrl"

# ===================================================================
# 5. Chatbot API Web App
# ===================================================================

Write-Step $scriptName "5. Chatbot API Web App '$chatbotApiAppName'"
$chatbotAppExists = az webapp list --resource-group $rg --query "[?name=='$chatbotApiAppName'] | length(@)" -o tsv
if ($chatbotAppExists -eq "0") {
    az webapp create `
        --resource-group $rg `
        --plan $appServicePlanName `
        --name $chatbotApiAppName `
        --runtime "PYTHON:3.13" | Out-Null
}

az webapp identity assign --resource-group $rg --name $chatbotApiAppName | Out-Null
$chatbotPrincipalId = az webapp identity show --resource-group $rg --name $chatbotApiAppName --query principalId -o tsv

Write-Step $scriptName "5b. Chatbot API RBAC + Settings"
$aoaiScope = az cognitiveservices account show --resource-group $openAiRg --name $openAiAccount --query id -o tsv
$aoaiEndpoint = az cognitiveservices account show --resource-group $openAiRg --name $openAiAccount --query properties.endpoint -o tsv

Ensure-RoleAssignment -PrincipalId $chatbotPrincipalId -Scope $aoaiScope -Role "Cognitive Services OpenAI User"
Ensure-RoleAssignment -PrincipalId $chatbotPrincipalId -Scope $storageScope -Role "Storage Blob Data Reader"

az webapp config appsettings set --resource-group $rg --name $chatbotApiAppName --settings `
    "AZURE_OPENAI_ENDPOINT=$aoaiEndpoint" `
    "AZURE_OPENAI_RESPONSES_DEPLOYMENT_NAME=$openAiDeployment" `
    "CODEMODE_MCP_URL=$codemodeMcpUrl" `
    "SCM_DO_BUILD_DURING_DEPLOYMENT=true" `
    "WEBSITE_STARTUP_COMMAND=gunicorn -w 2 -k uvicorn.workers.UvicornWorker chatbot_api:app --bind 0.0.0.0:8000" | Out-Null

$chatbotFqdn = az webapp show --resource-group $rg --name $chatbotApiAppName --query defaultHostName -o tsv
$chatbotUrl = "https://$chatbotFqdn"
Write-Output "  Chatbot API URL: $chatbotUrl"

# ===================================================================
# 6. Save deploy-env.json
# ===================================================================

Write-Step $scriptName "6. Saving deploy-env.json"
$envFile = Join-Path $PSScriptRoot "deploy-env.json"
@{
    subscriptionId      = $subscriptionId
    resourceGroup       = $rg
    location            = $location
    storageAccountName  = $storageAccountName
    storageAccountUrl   = $storageAccountUrl
    appServicePlanName  = $appServicePlanName
    storageApiAppName   = $storageApiAppName
    storageApiUrl       = $storageApiUrl
    chatbotApiAppName   = $chatbotApiAppName
    chatbotApiUrl       = $chatbotUrl
    openAiAccount       = $openAiAccount
    openAiEndpoint      = $aoaiEndpoint
    openAiDeployment    = $openAiDeployment
    codemodeMcpUrl      = $codemodeMcpUrl
} | ConvertTo-Json -Depth 3 | Set-Content -Path $envFile -Encoding UTF8

# ===================================================================
# Summary
# ===================================================================

Write-Step $scriptName "INFRASTRUCTURE DEPLOYMENT COMPLETE"
Write-Output ""
Write-Output "  Resource Group:    $rg"
Write-Output "  Storage Account:   $storageAccountName ($storageAccountUrl)"
Write-Output "  App Service Plan:  $appServicePlanName"
Write-Output "  Storage API:       $storageApiAppName ($storageApiUrl)"
Write-Output "  Chatbot API:       $chatbotApiAppName ($chatbotUrl)"
Write-Output "  Azure OpenAI:      $openAiAccount ($aoaiEndpoint)"
Write-Output "  Codemode MCP URL:  $codemodeMcpUrl"
Write-Output ""
Write-Output "Next steps:"
Write-Output "  1. deploy\deploy-apps.ps1       - zip deploy code to both App Services"
Write-Output "  2. deploy\upload-dummy-data.ps1  - upload test PDFs to storage"
