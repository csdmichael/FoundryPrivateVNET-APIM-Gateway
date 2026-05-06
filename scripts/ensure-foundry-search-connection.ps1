$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

function Assert-LastExitCode {
    param(
        [string]$Operation
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

$config = Get-Content .\config\azure_resources.json | ConvertFrom-Json
$subscriptionId = $config.subscription_id
$resourceGroup = $config.resource_group
$projectEndpoint = $config.foundry.project_endpoint.TrimEnd('/')
$projectName = ($projectEndpoint -split '/')[-1]
$accountName = $config.foundry.account_name
$connectionName = if ($config.foundry.search_connection_name) { $config.foundry.search_connection_name } else { 'aisearchpocmyaacoub' }
$searchEndpoint = $config.search.target_endpoint.TrimEnd('/')
$searchResourceId = $config.search.target_resource_id
$searchDisplayName = $config.search.target_service_name

$searchKey = az search admin-key show --resource-group $resourceGroup --service-name $searchDisplayName --query primaryKey -o tsv
Assert-LastExitCode "Retrieving Search admin key"
if (-not $searchKey) {
    throw "Unable to read admin key for $searchDisplayName"
}

$templatePath = Join-Path ([System.IO.Path]::GetTempPath()) 'foundry-search-connection.bicep'
$parametersPath = Join-Path ([System.IO.Path]::GetTempPath()) 'foundry-search-connection.parameters.json'

$template = @"
param accountName string
param projectName string
param connectionName string
param searchEndpoint string
param searchResourceId string
param location string

@secure()
param searchKey string

resource aiAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
    name: accountName

    resource aiProject 'projects' existing = {
        name: projectName
    }
}

resource searchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
    name: connectionName
    parent: aiAccount::aiProject
    properties: {
        category: 'CognitiveSearch'
        target: searchEndpoint
        authType: 'ApiKey'
        isSharedToAll: false
        credentials: {
            key: searchKey
        }
        metadata: {
            ApiType: 'Azure'
            ResourceId: searchResourceId
            location: location
            type: 'azure_ai_search'
        }
    }
}
"@

$parameters = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = @{
                accountName = @{ value = $accountName }
                projectName = @{ value = $projectName }
                connectionName = @{ value = $connectionName }
                searchEndpoint = @{ value = $searchEndpoint }
                searchResourceId = @{ value = $searchResourceId }
                location = @{ value = $config.location }
                searchKey = @{ value = $searchKey }
        }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($templatePath, $template, $utf8NoBom)
[System.IO.File]::WriteAllText($parametersPath, ($parameters | ConvertTo-Json -Depth 20), $utf8NoBom)

az deployment group create --resource-group $resourceGroup --name "foundry-search-connection-$connectionName" --template-file $templatePath --parameters "@$parametersPath" -o none | Out-Null
Assert-LastExitCode "Ensuring Foundry Search connection '$connectionName'"
Write-Host "Ensured Foundry Search connection: $connectionName"