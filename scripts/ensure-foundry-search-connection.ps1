$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$config = Get-Content .\config\azure_resources.json | ConvertFrom-Json
$subscriptionId = $config.subscription_id
$resourceGroup = $config.resource_group
$projectEndpoint = $config.foundry.project_endpoint.TrimEnd('/')
$projectName = ($projectEndpoint -split '/')[-1]
$accountName = $config.foundry.account_name
$connectionName = if ($config.foundry.search_connection_name) { $config.foundry.search_connection_name } else { 'aisearchpocmyaacoub' }
$searchEndpoint = $config.search.target_endpoint.TrimEnd('/') + '/'
$searchResourceId = $config.search.target_resource_id
$searchDisplayName = $config.search.target_service_name

$connectionUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.CognitiveServices/accounts/$accountName/projects/$projectName/connections/$connectionName?api-version=2025-06-01"

$searchKey = az search admin-key show --resource-group $resourceGroup --service-name $searchDisplayName --query primaryKey -o tsv
if (-not $searchKey) {
    throw "Unable to read admin key for $searchDisplayName"
}

$payload = @{
    properties = @{
        authType = 'ApiKey'
        category = 'CognitiveSearch'
        isDefault = $true
        isSharedToAll = $false
        metadata = @{
            ApiType = 'Azure'
            ApiVersion = '2024-05-01-preview'
            DeploymentApiVersion = '2023-11-01'
            ResourceId = $searchResourceId
            displayName = $searchDisplayName
            type = 'azure_ai_search'
        }
        target = $searchEndpoint
        useWorkspaceManagedIdentity = $false
        credentials = @{
            key = $searchKey
        }
    }
}

$payloadPath = Join-Path $env:TEMP 'foundry-search-connection.json'
$payload | ConvertTo-Json -Depth 20 | Set-Content -Path $payloadPath -Encoding UTF8

az rest --method put --headers Content-Type=application/json --url $connectionUrl --body "@$payloadPath" | Out-Null
Write-Host "Ensured Foundry Search connection: $connectionName"