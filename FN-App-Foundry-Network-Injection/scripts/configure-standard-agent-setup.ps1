<#
.SYNOPSIS
    Stand up the Foundry STANDARD AGENT setup: bring-your-own (BYO) Storage + Cosmos DB +
    Azure AI Search, project connections, RBAC, and account/project capability hosts. This is
    the prerequisite that makes the network-injection PATCH (configure-foundry-network-injection.ps1)
    succeed.

.DESCRIPTION
    Reads config/network_injection_config.json -> standard_agent. Performs, idempotently:

      Stage 1  Create the 3 BYO resources (cost-effective low tiers):
                 - Cosmos DB for NoSQL  (SERVERLESS  -> pay-per-request, satisfies 3000 RU/s)
                 - Azure AI Search      (BASIC tier  -> lowest GA tier with agent vector stores)
                 - Storage account      (Standard_LRS StorageV2)
      Stage 2  Create the 3 project connections (CosmosDB / AzureStorageAccount / CognitiveSearch),
                 all AAD auth (no keys), via ARM control plane.
      Stage 3  Grant the PROJECT system-assigned managed identity the pre-capability-host roles:
                 - Cosmos DB Operator               (Cosmos account)
                 - Storage Blob Data Contributor    (Storage account)
                 - Search Index Data Contributor    (Search service)
                 - Search Service Contributor       (Search service)
      Stage 4  Create the account capability host (empty Agents) then the project capability host
                 (Agents + the 3 connections). Long-running; polls until Succeeded. Capability
                 hosts cannot be updated -> a Failed one is deleted and recreated.
      Stage 5  Grant the project SMI the post-capability-host data-plane roles (so the running
                 agent can read/write):
                 - Storage Blob Data Owner          (Storage account scope, covers both containers)
                 - Cosmos DB Built-in Data Contributor (Cosmos data plane, account scope)
      Stage 6  [optional -Lockdown] Add private endpoints for blob/file/queue/table + cosmos +
                 search into the private-endpoints subnet and disable public access on all three
                 BYO resources. OFF by default to keep provisioning simple and avoid per-endpoint
                 cost; run once the agent end-to-end path is verified.

    After this completes successfully, run scripts/configure-foundry-network-injection.ps1 to
    apply the networkInjections PATCH, then scripts/create_ni_function_agent.py.

.PARAMETER Lockdown
    Also run Stage 6 (private endpoints + disable public access on the BYO resources).

.PARAMETER SkipCapabilityHost
    Run stages 1-3 only (create resources + connections + pre-roles). Useful to validate the
    BYO resources before the long-running capability-host provisioning.

.NOTES
    Windows az gotchas handled: --body files written BOM-free; az rest response bodies routed to
    a temp file via --output-file to avoid the cp1252/BOM console crash. Capability-host PUT is a
    long-running operation (LRO) so we poll provisioningState on GET.
#>
[CmdletBinding()]
param(
    [switch]$Lockdown,
    [switch]$SkipCapabilityHost
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

# ---------------------------------------------------------------------------
# Helpers (mirror configure-foundry-network-injection.ps1)
# ---------------------------------------------------------------------------
function Invoke-AzProbe {
    param([Parameter(Mandatory)][scriptblock]$Probe)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Probe 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return ($out | Select-Object -First 1) }
        return $null
    } finally { $ErrorActionPreference = $prev }
}

function Invoke-AzWrite {
    param([Parameter(Mandatory)][scriptblock]$Cmd, [string]$What = 'az command')
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Cmd 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
    } finally { $ErrorActionPreference = $prev }
}

function Write-JsonNoBom {
    param([Parameter(Mandatory)][string]$Json)
    $f = New-TemporaryFile
    [System.IO.File]::WriteAllText($f.FullName, $Json, (New-Object System.Text.UTF8Encoding($false)))
    return $f.FullName
}

# az rest helper that returns the parsed JSON object (response routed via --output-file).
function Invoke-AzRest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [string]$BodyJson,
        [switch]$AllowFail
    )
    $respFile = New-TemporaryFile
    $argsList = @('rest', '--method', $Method, '--url', $Url, '--output-file', $respFile.FullName)
    $bodyFile = $null
    if ($BodyJson) {
        $bodyFile = Write-JsonNoBom -Json $BodyJson
        $argsList += @('--body', ("@" + $bodyFile), '--headers', 'Content-Type=application/json')
    }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    az @argsList 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($bodyFile) { Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue }
    $obj = $null
    if ((Test-Path $respFile.FullName) -and (Get-Item $respFile.FullName).Length -gt 0) {
        try { $obj = Get-Content $respFile.FullName -Raw | ConvertFrom-Json } catch { $obj = $null }
    }
    Remove-Item $respFile.FullName -Force -ErrorAction SilentlyContinue
    if ($code -ne 0 -and -not $AllowFail) {
        throw "az rest $Method $Url failed (exit $code): $($obj | ConvertTo-Json -Depth 8 -Compress)"
    }
    return [pscustomobject]@{ ExitCode = $code; Body = $obj }
}

# Idempotent built-in role assignment to a principal at a scope.
function Grant-Role {
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Scope
    )
    $existing = Invoke-AzProbe { az role assignment list --assignee $PrincipalId --role $Role --scope $Scope --query "[0].id" -o tsv }
    if ($existing) {
        Write-Host "    role '$Role' already granted" -ForegroundColor Yellow
        return
    }
    Invoke-AzWrite { az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type ServicePrincipal --role $Role --scope $Scope } "grant '$Role'"
    Write-Host "    granted '$Role'" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
Write-Host '==> Loading configuration' -ForegroundColor Cyan
$cfg = Get-Content .\config\network_injection_config.json -Raw | ConvertFrom-Json

$subscriptionId = $cfg.subscription_id
$resourceGroup  = $cfg.resource_group
$location       = $cfg.location

$sa             = $cfg.standard_agent
$cosmosName     = $sa.cosmosdb.name
$threadDb       = $sa.cosmosdb.thread_database
$storeName      = $sa.storage.name
$searchName     = $sa.search.name
$searchSku      = $sa.search.sku
$accCapHost     = $sa.capability_hosts.account_capability_host_name
$projCapHost    = $sa.capability_hosts.project_capability_host_name

$fdry           = $cfg.foundry
$accountName    = $fdry.account_name
$accountId      = $fdry.account_resource_id
$projectName    = $fdry.project_name
$apiVersion     = $fdry.account_api_version

$projectFullName = "$accountName/$projectName"
$projectArmId    = "$accountId/projects/$projectName"

az account set --subscription $subscriptionId | Out-Null

# Resolve the PROJECT system-assigned managed identity (never hardcoded).
Write-Host "==> Resolving project managed identity ($projectFullName)" -ForegroundColor Cyan
$proj = Invoke-AzRest -Method GET -Url ("https://management.azure.com$projectArmId" + "?api-version=$apiVersion")
$projectPrincipalId = $proj.Body.identity.principalId
if (-not $projectPrincipalId) { throw "Could not resolve project managed identity principalId for $projectFullName" }
Write-Host "    project SMI principalId = $projectPrincipalId" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Stage 1 - BYO resources (low-tier, cost-effective)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 1: BYO resources (Cosmos serverless / Search basic / Storage Standard_LRS)" -ForegroundColor Cyan

# Cosmos DB for NoSQL - serverless
$cosmosId = Invoke-AzProbe { az cosmosdb show -g $resourceGroup -n $cosmosName --query id -o tsv }
if (-not $cosmosId) {
    Invoke-AzWrite { az cosmosdb create -g $resourceGroup -n $cosmosName --locations regionName=$location failoverPriority=0 isZoneRedundant=False --capabilities EnableServerless --default-consistency-level $sa.cosmosdb.default_consistency_level } "cosmos create"
    $cosmosId = az cosmosdb show -g $resourceGroup -n $cosmosName --query id -o tsv
    Write-Host "    created Cosmos DB '$cosmosName' (serverless)" -ForegroundColor Green
} else {
    Write-Host "    Cosmos DB '$cosmosName' exists" -ForegroundColor Yellow
}
$cosmosEndpoint = az cosmosdb show -g $resourceGroup -n $cosmosName --query documentEndpoint -o tsv
$cosmosLocation = az cosmosdb show -g $resourceGroup -n $cosmosName --query location -o tsv

# Storage account
$storeId = Invoke-AzProbe { az storage account show -g $resourceGroup -n $storeName --query id -o tsv }
if (-not $storeId) {
    Invoke-AzWrite { az storage account create -g $resourceGroup -n $storeName -l $location --sku $sa.storage.sku --kind $sa.storage.kind --min-tls-version TLS1_2 --allow-blob-public-access false } "storage create"
    $storeId = az storage account show -g $resourceGroup -n $storeName --query id -o tsv
    Write-Host "    created Storage '$storeName'" -ForegroundColor Green
} else {
    Write-Host "    Storage '$storeName' exists" -ForegroundColor Yellow
}
$storeBlob = az storage account show -g $resourceGroup -n $storeName --query primaryEndpoints.blob -o tsv
$storeLocation = az storage account show -g $resourceGroup -n $storeName --query location -o tsv

# Azure AI Search - basic. Search capacity can be region-locked; honor a search-specific
# location from config (falls back to the global location) so the BYO search can sit in an
# adjacent region when eastus2 is capacity-exhausted. Standard Agent allows cross-region BYO.
$searchLoc = if ($sa.search.location) { $sa.search.location } else { $location }
$searchId = Invoke-AzProbe { az search service show -g $resourceGroup -n $searchName --query id -o tsv }
if (-not $searchId) {
    Invoke-AzWrite { az search service create -g $resourceGroup -n $searchName -l $searchLoc --sku $searchSku --partition-count $sa.search.partition_count --replica-count $sa.search.replica_count --auth-options aadOrApiKey --aad-auth-failure-mode http403 } "search create"
    $searchId = az search service show -g $resourceGroup -n $searchName --query id -o tsv
    Write-Host "    created Search '$searchName' ($searchSku, $searchLoc)" -ForegroundColor Green
} else {
    Write-Host "    Search '$searchName' exists" -ForegroundColor Yellow
}
$searchLocation = az search service show -g $resourceGroup -n $searchName --query location -o tsv
$searchTarget = "https://$searchName.search.windows.net"

# ---------------------------------------------------------------------------
# Stage 2 - Project connections (AAD auth, no keys)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 2: project connections (Cosmos / Storage / Search)" -ForegroundColor Cyan

function New-ProjectConnection {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$ResLocation
    )
    $url = "https://management.azure.com$projectArmId/connections/$Name`?api-version=$apiVersion"
    $exists = Invoke-AzRest -Method GET -Url $url -AllowFail
    if ($exists.ExitCode -eq 0 -and $exists.Body.name) {
        Write-Host "    connection '$Name' exists" -ForegroundColor Yellow
        return
    }
    $body = @{
        properties = @{
            category = $Category
            target   = $Target
            authType = 'AAD'
            isSharedToAll = $true
            metadata = @{
                ApiType    = 'Azure'
                ResourceId = $ResourceId
                location   = $ResLocation
            }
        }
    } | ConvertTo-Json -Depth 8
    Invoke-AzRest -Method PUT -Url $url -BodyJson $body | Out-Null
    Write-Host "    created connection '$Name' ($Category)" -ForegroundColor Green
}

New-ProjectConnection -Name $sa.cosmosdb.connection_name -Category $sa.cosmosdb.connection_category -Target $cosmosEndpoint -ResourceId $cosmosId -ResLocation $cosmosLocation
New-ProjectConnection -Name $sa.storage.connection_name  -Category $sa.storage.connection_category  -Target $storeBlob      -ResourceId $storeId  -ResLocation $storeLocation
New-ProjectConnection -Name $sa.search.connection_name   -Category $sa.search.connection_category   -Target $searchTarget   -ResourceId $searchId -ResLocation $searchLocation

# ---------------------------------------------------------------------------
# Stage 3 - Pre-capability-host RBAC (project SMI)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 3: pre-capability-host role assignments" -ForegroundColor Cyan
Grant-Role -PrincipalId $projectPrincipalId -Role 'Cosmos DB Operator'            -Scope $cosmosId
Grant-Role -PrincipalId $projectPrincipalId -Role 'Storage Blob Data Contributor' -Scope $storeId
Grant-Role -PrincipalId $projectPrincipalId -Role 'Search Index Data Contributor' -Scope $searchId
Grant-Role -PrincipalId $projectPrincipalId -Role 'Search Service Contributor'    -Scope $searchId

if ($SkipCapabilityHost) {
    Write-Host "==> -SkipCapabilityHost set: stopping after BYO resources + connections + pre-roles." -ForegroundColor Cyan
    return
}

# ---------------------------------------------------------------------------
# Stage 4 - Capability hosts (account then project), long-running
# ---------------------------------------------------------------------------
Write-Host "==> Stage 4: capability hosts" -ForegroundColor Cyan

function Wait-CapHost {
    param([Parameter(Mandatory)][string]$Url, [int]$TimeoutSec = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-AzRest -Method GET -Url $Url -AllowFail
        $state = $r.Body.properties.provisioningState
        if ($state -eq 'Succeeded') { return 'Succeeded' }
        if ($state -in @('Failed', 'Canceled')) { return $state }
        Start-Sleep -Seconds 15
    }
    return 'Timeout'
}

function Set-CapHost {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$BodyJson,
        [Parameter(Mandatory)][string]$Label
    )
    $cur = Invoke-AzRest -Method GET -Url $Url -AllowFail
    if ($cur.ExitCode -eq 0 -and $cur.Body.name) {
        $state = $cur.Body.properties.provisioningState
        if ($state -eq 'Succeeded') { Write-Host "    $Label exists (Succeeded)" -ForegroundColor Yellow; return }
        if ($state -in @('Creating', 'Provisioning', 'Accepted', 'Updating')) {
            Write-Host "    $Label provisioning ($state) - waiting" -ForegroundColor Yellow
            $final = Wait-CapHost -Url $Url
            if ($final -ne 'Succeeded') { throw "$Label did not reach Succeeded (state=$final)" }
            Write-Host "    $Label Succeeded" -ForegroundColor Green; return
        }
        # Failed/Canceled -> caphosts cannot be updated, delete then recreate.
        Write-Host "    $Label in state '$state' - deleting to recreate" -ForegroundColor Yellow
        Invoke-AzRest -Method DELETE -Url $Url -AllowFail | Out-Null
        Start-Sleep -Seconds 10
    }
    Invoke-AzRest -Method PUT -Url $Url -BodyJson $BodyJson | Out-Null
    $final = Wait-CapHost -Url $Url
    if ($final -ne 'Succeeded') { throw "$Label did not reach Succeeded (state=$final)" }
    Write-Host "    $Label Succeeded" -ForegroundColor Green
}

# Account capability host - empty Agents body.
$accCapUrl = "https://management.azure.com$accountId/capabilityHosts/$accCapHost`?api-version=$apiVersion"
$accCapBody = @{ properties = @{ capabilityHostKind = 'Agents' } } | ConvertTo-Json -Depth 5
Set-CapHost -Url $accCapUrl -BodyJson $accCapBody -Label "account capability host '$accCapHost'"

# Project capability host - references the 3 BYO connections.
$projCapUrl = "https://management.azure.com$projectArmId/capabilityHosts/$projCapHost`?api-version=$apiVersion"
$projCapBody = @{
    properties = @{
        capabilityHostKind      = 'Agents'
        vectorStoreConnections  = @($sa.search.connection_name)
        storageConnections      = @($sa.storage.connection_name)
        threadStorageConnections = @($sa.cosmosdb.connection_name)
    }
} | ConvertTo-Json -Depth 6
Set-CapHost -Url $projCapUrl -BodyJson $projCapBody -Label "project capability host '$projCapHost'"

# ---------------------------------------------------------------------------
# Stage 5 - Post-capability-host data-plane RBAC (agent runtime)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 5: post-capability-host data-plane role assignments" -ForegroundColor Cyan
Grant-Role -PrincipalId $projectPrincipalId -Role 'Storage Blob Data Owner' -Scope $storeId

# Cosmos DB Built-in Data Contributor (data plane) at account scope.
$cosmosDataRole = '00000000-0000-0000-0000-000000000002'
$existingCosmos = Invoke-AzProbe { az cosmosdb sql role assignment list -g $resourceGroup -a $cosmosName --query "[?principalId=='$projectPrincipalId' && roleDefinitionId.ends_with(@, '$cosmosDataRole')].id" -o tsv }
if ($existingCosmos) {
    Write-Host "    Cosmos data-plane role already granted" -ForegroundColor Yellow
} else {
    Invoke-AzWrite { az cosmosdb sql role assignment create -g $resourceGroup -a $cosmosName --role-definition-id $cosmosDataRole --principal-id $projectPrincipalId --scope "/" } "cosmos data-plane role"
    Write-Host "    granted Cosmos DB Built-in Data Contributor (data plane)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Stage 6 - Optional lockdown (private endpoints + disable public access)
# ---------------------------------------------------------------------------
if ($Lockdown) {
    Write-Host "==> Stage 6: lockdown (private endpoints + disable public access on BYO)" -ForegroundColor Cyan
    $net        = $cfg.networking
    $vnetName   = $net.vnet_name
    $peSubnet   = $net.private_endpoint_subnet
    $peSubnetId = az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $peSubnet --query id -o tsv

    function New-Pe {
        param([string]$Name, [string]$ResourceId, [string]$GroupId, [string]$Zone)
        $exists = Invoke-AzProbe { az network private-endpoint show -g $resourceGroup -n $Name --query id -o tsv }
        if (-not $exists) {
            Invoke-AzWrite { az network private-endpoint create -g $resourceGroup -n $Name -l $location --subnet $peSubnetId --private-connection-resource-id $ResourceId --group-id $GroupId --connection-name "$Name-conn" } "PE $Name"
            Write-Host "    created PE '$Name' ($GroupId)" -ForegroundColor Green
        } else {
            Write-Host "    PE '$Name' exists" -ForegroundColor Yellow
        }
        if ($Zone) {
            $zoneExists = Invoke-AzProbe { az network private-dns zone show -g $resourceGroup -n $Zone --query id -o tsv }
            if (-not $zoneExists) { Invoke-AzWrite { az network private-dns zone create -g $resourceGroup -n $Zone } "zone $Zone" }
            $linkName = ($Zone -replace '\.', '-') + '-ni-link'
            $linkExists = Invoke-AzProbe { az network private-dns link vnet show -g $resourceGroup -z $Zone -n $linkName --query id -o tsv }
            if (-not $linkExists) { Invoke-AzWrite { az network private-dns link vnet create -g $resourceGroup -z $Zone -n $linkName --virtual-network $vnetName --registration-enabled false } "link $Zone" }
            $zgExists = Invoke-AzProbe { az network private-endpoint dns-zone-group show -g $resourceGroup --endpoint-name $Name -n "$Name-zg" --query id -o tsv }
            if (-not $zgExists) { Invoke-AzWrite { az network private-endpoint dns-zone-group create -g $resourceGroup --endpoint-name $Name -n "$Name-zg" --private-dns-zone $Zone --zone-name ($Zone -replace '\.', '-') } "zone-group $Name" }
        }
    }

    foreach ($sub in @('blob', 'file', 'queue', 'table')) {
        New-Pe -Name "pe-$storeName-$sub" -ResourceId $storeId -GroupId $sub -Zone $cfg.storage_account.private_dns_zones.$sub
    }
    New-Pe -Name "pe-$cosmosName" -ResourceId $cosmosId -GroupId 'Sql'     -Zone $sa.lockdown.cosmos_private_dns_zone
    New-Pe -Name "pe-$searchName" -ResourceId $searchId -GroupId 'searchService' -Zone $sa.lockdown.search_private_dns_zone

    Invoke-AzWrite { az storage account update -g $resourceGroup -n $storeName --public-network-access Disabled --default-action Deny } "storage lockdown"
    Invoke-AzWrite { az cosmosdb update -g $resourceGroup -n $cosmosName --public-network-access Disabled } "cosmos lockdown"
    Invoke-AzWrite { az search service update -g $resourceGroup -n $searchName --public-access disabled } "search lockdown"
    Write-Host "    BYO resources locked down (public access disabled)" -ForegroundColor Green
}

Write-Host ""
Write-Host "==> Standard Agent setup complete for '$accountName/$projectName'." -ForegroundColor Cyan
Write-Host "    BYO: Cosmos '$cosmosName' (serverless), Search '$searchName' ($searchSku), Storage '$storeName'." -ForegroundColor Cyan
Write-Host "    Capability hosts: account '$accCapHost', project '$projCapHost' (Succeeded)." -ForegroundColor Cyan
Write-Host "    Next: scripts/configure-foundry-network-injection.ps1 (networkInjections PATCH)." -ForegroundColor Cyan
