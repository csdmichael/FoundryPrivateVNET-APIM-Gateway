param(
    [switch]$SearchOnly,
    [switch]$AgentsOnly
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$pythonCommand = if ($env:PYTHON_BIN) { $env:PYTHON_BIN } else { 'python' }
$localCreateSearchScriptPath = Join-Path $PSScriptRoot 'create_cosmosdb_search_index.py'
$localCreateAgentScriptPath = Join-Path $PSScriptRoot 'create_foundry_agent.py'

function Assert-LastExitCode {
    param(
        [string]$Operation
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Get-CurrentAzurePrincipal {
    $account = az account show -o json | ConvertFrom-Json
    Assert-LastExitCode "Reading current Azure account context"

    $principalName = $account.user.name
    $principalKind = $account.user.type

    if (-not $principalName) {
        throw "Unable to resolve the current Azure principal from az account show."
    }

    if ($principalKind -eq 'servicePrincipal') {
        $principalId = az ad sp show --id $principalName --query id -o tsv
        Assert-LastExitCode "Resolving current service principal object ID"
        return @{
            Name = $principalName
            ObjectId = $principalId
            PrincipalType = 'ServicePrincipal'
        }
    }

    $principalId = az ad signed-in-user show --query id -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $principalId) {
        $principalId = az ad user show --id $principalName --query id -o tsv
        Assert-LastExitCode "Resolving current user object ID"
    }

    return @{
        Name = $principalName
        ObjectId = $principalId
        PrincipalType = 'User'
    }
}

function Ensure-RoleAssignment {
    param(
        [string]$RoleName,
        [string]$Scope,
        [hashtable]$Principal,
        [string]$Description
    )

    $existingAssignment = az role assignment list --assignee-object-id $Principal.ObjectId --scope $Scope --query "[?roleDefinitionName=='$RoleName'] | [0].id" -o tsv
    Assert-LastExitCode "Checking $Description"
    if (-not $existingAssignment) {
        Write-Host "Granting $RoleName to $($Principal.Name) on $Scope"
        az role assignment create --assignee-object-id $Principal.ObjectId --assignee-principal-type $Principal.PrincipalType --role $RoleName --scope $Scope -o none
        Assert-LastExitCode "Creating $Description"
    }
}

if (-not $SearchOnly -and -not $AgentsOnly) {
    $SearchOnly = $true
    $AgentsOnly = $true
}

$config = Get-Content .\config\azure_resources.json | ConvertFrom-Json

$searchAdminKey = az search admin-key show --service-name $config.search.target_service_name --resource-group $config.resource_group --query primaryKey -o tsv
Assert-LastExitCode "Retrieving Search admin key"
if (-not $searchAdminKey) {
    throw "Unable to retrieve Search admin key for $($config.search.target_service_name)."
}
$env:AZURE_AI_SEARCH_KEY = $searchAdminKey

if ($AgentsOnly) {
    $currentPrincipal = Get-CurrentAzurePrincipal
    Ensure-RoleAssignment -RoleName 'Azure AI User' -Scope $config.foundry.account_resource_id -Principal $currentPrincipal -Description 'Azure AI User role assignment on Foundry account'
    & "$PSScriptRoot\ensure-foundry-search-connection.ps1"
}

foreach ($useCase in @('tax_pdf_forms', 'eng_design_ppt')) {
    $env:USE_CASE = $useCase

    if ($SearchOnly) {
        & $pythonCommand $localCreateSearchScriptPath
        Assert-LastExitCode "Creating Search assets for use case '$useCase'"
    }

    if ($AgentsOnly) {
        $env:AZURE_AI_SEARCH_CONNECTION_NAME = $config.foundry.search_connection_name
        & $pythonCommand $localCreateAgentScriptPath
        Assert-LastExitCode "Creating Foundry agent for use case '$useCase'"
    }
}