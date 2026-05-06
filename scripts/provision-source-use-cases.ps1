param(
    [switch]$SearchOnly,
    [switch]$AgentsOnly
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$pythonCommand = if ($env:PYTHON_BIN) { $env:PYTHON_BIN } else { 'python' }
$localCreateSearchScriptPath = Join-Path $PSScriptRoot 'create_cosmosdb_search_index.py'
$localCreateAgentScriptPath = Join-Path $PSScriptRoot 'create_foundry_agent.py'
$autoAssignFoundryRole = $env:AUTO_ASSIGN_FOUNDRY_ROLE -eq 'true'

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

function Assert-RoleAssignment {
    param(
        [string]$RoleName,
        [string]$Scope,
        [hashtable]$Principal,
        [string]$Description,
        [bool]$AllowCreate = $false
    )

    $existingAssignment = az role assignment list --assignee-object-id $Principal.ObjectId --scope $Scope --query "[?roleDefinitionName=='$RoleName'] | [0].id" -o tsv
    Assert-LastExitCode "Checking $Description"
    if (-not $existingAssignment) {
        $manualGrantCommand = "az role assignment create --assignee-object-id $($Principal.ObjectId) --assignee-principal-type $($Principal.PrincipalType) --role `"$RoleName`" --scope $Scope"

        if (-not $AllowCreate) {
            throw @"
Current deployment principal '$($Principal.Name)' (object id '$($Principal.ObjectId)') is missing '$RoleName' on '$Scope'.

Grant this role from an identity that has Owner or User Access Administrator on that scope, then rerun provisioning.

Recommended command:
$manualGrantCommand

If you want this script to attempt the role assignment automatically, rerun it with AUTO_ASSIGN_FOUNDRY_ROLE=true from an identity that can create role assignments.
"@
        }

        Write-Host "Granting $RoleName to $($Principal.Name) on $Scope"
        $assignmentOutput = az role assignment create --assignee-object-id $Principal.ObjectId --assignee-principal-type $Principal.PrincipalType --role $RoleName --scope $Scope -o none 2>&1
        if ($LASTEXITCODE -ne 0) {
            $assignmentMessage = ($assignmentOutput | Out-String).Trim()
            if ($assignmentMessage -match 'Microsoft.Authorization/roleAssignments/write|AuthorizationFailed') {
                throw @"
Current deployment principal '$($Principal.Name)' (object id '$($Principal.ObjectId)') is missing '$RoleName' on '$Scope', and it cannot self-assign that role because it lacks 'Microsoft.Authorization/roleAssignments/write'.

Grant '$RoleName' to this principal on the Foundry account scope from an identity that has Owner or User Access Administrator on that scope, then rerun provisioning.

Scope: $Scope
Principal type: $($Principal.PrincipalType)
Required role: $RoleName
Recommended command:
$manualGrantCommand
"@
            }

            throw "Creating $Description failed.`n$assignmentMessage"
        }
    }
}

if (-not $SearchOnly -and -not $AgentsOnly) {
    $SearchOnly = $true
    $AgentsOnly = $true
}

$config = Get-Content .\config\azure_resources.json | ConvertFrom-Json

if ($AgentsOnly) {
    $currentPrincipal = Get-CurrentAzurePrincipal
    Assert-RoleAssignment -RoleName 'Azure AI User' -Scope $config.foundry.account_resource_id -Principal $currentPrincipal -Description 'Azure AI User role assignment on Foundry account' -AllowCreate $autoAssignFoundryRole
}

$searchAdminKey = az search admin-key show --service-name $config.search.target_service_name --resource-group $config.resource_group --query primaryKey -o tsv
Assert-LastExitCode "Retrieving Search admin key"
if (-not $searchAdminKey) {
    throw "Unable to retrieve Search admin key for $($config.search.target_service_name)."
}
$env:AZURE_AI_SEARCH_KEY = $searchAdminKey

if ($AgentsOnly) {
    & "$PSScriptRoot\ensure-foundry-search-connection.ps1"
}

$useCaseKeys = @($config.use_cases.PSObject.Properties.Name)
foreach ($useCase in $useCaseKeys) {
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