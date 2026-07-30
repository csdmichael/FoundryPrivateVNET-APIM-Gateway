<#
.SYNOPSIS
    Configure private diagnostics and agent tracing for the network-injected Foundry project.

.DESCRIPTION
    Reads config/network_injection_config.json -> observability and performs idempotently:

      1. Create a dedicated Log Analytics workspace and workspace-based Application Insights.
      2. Create an Azure Monitor Private Link Scope (AMPLS) in PrivateOnly mode and add both
         monitoring resources to it.
      3. Create the AMPLS private endpoint, all five required private DNS zones, VNet links,
         and the private DNS zone group.
      4. Disable public ingestion and query access on Log Analytics and Application Insights.
      5. Add a Foundry account diagnostic setting for the configured platform-log categories.
      6. Connect Application Insights to the Foundry project to enable server-side agent traces.

    The Application Insights connection string is resolved at runtime and sent directly to the
    Foundry connection API. It is never printed or stored in source control.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

function Invoke-AzProbe {
    param([Parameter(Mandatory)][scriptblock]$Probe)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Probe 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) { return ($output | Select-Object -First 1) }
        return $null
    } finally { $ErrorActionPreference = $previous }
}

function Invoke-AzWrite {
    param([Parameter(Mandatory)][scriptblock]$Command, [string]$Description = 'az command')
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$Description failed (exit $LASTEXITCODE)" }
    } finally { $ErrorActionPreference = $previous }
}

function Write-JsonNoBom {
    param([Parameter(Mandatory)][string]$Json)
    $file = New-TemporaryFile
    [System.IO.File]::WriteAllText($file.FullName, $Json, (New-Object System.Text.UTF8Encoding($false)))
    return $file.FullName
}

function Invoke-AzRest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [string]$BodyJson
    )
    $responseFile = New-TemporaryFile
    $arguments = @('rest', '--method', $Method, '--url', $Url, '--output-file', $responseFile.FullName)
    $bodyFile = $null
    if ($BodyJson) {
        $bodyFile = Write-JsonNoBom -Json $BodyJson
        $arguments += @('--body', ("@" + $bodyFile), '--headers', 'Content-Type=application/json')
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    az @arguments 2>&1 | Out-Null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previous

    if ($bodyFile) { Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue }
    $body = $null
    if ((Test-Path $responseFile.FullName) -and (Get-Item $responseFile.FullName).Length -gt 0) {
        try { $body = Get-Content $responseFile.FullName -Raw | ConvertFrom-Json } catch { $body = $null }
    }
    Remove-Item $responseFile.FullName -Force -ErrorAction SilentlyContinue

    if ($exitCode -ne 0) {
        throw "az rest $Method $Url failed (exit $exitCode): $($body | ConvertTo-Json -Depth 10 -Compress)"
    }
    return $body
}

Write-Host '==> Loading configuration' -ForegroundColor Cyan
$cfg = Get-Content .\config\network_injection_config.json -Raw | ConvertFrom-Json
$obs = $cfg.observability
if (-not $obs) { throw 'Missing observability configuration.' }

$subscriptionId = $cfg.subscription_id
$resourceGroup = $cfg.resource_group
$location = $cfg.location
$accountId = $cfg.foundry.account_resource_id
$projectName = $cfg.foundry.project_name
$foundryApiVersion = $cfg.foundry.account_api_version
$vnetName = $cfg.networking.vnet_name
$privateEndpointSubnet = $cfg.networking.private_endpoint_subnet

$workspaceName = $obs.log_analytics_workspace_name
$appInsightsName = $obs.application_insights_name
$connectionName = $obs.application_insights_connection_name
$diagnosticSettingName = $obs.diagnostic_setting_name
$amplsName = $obs.private_link_scope_name
$privateEndpointName = $obs.private_endpoint_name
$privateEndpointConnectionName = $obs.private_endpoint_connection_name
$dnsZoneGroupName = $obs.dns_zone_group_name
$retentionDays = [int]$obs.retention_in_days

$managementBase = 'https://management.azure.com'
$workspaceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OperationalInsights/workspaces/$workspaceName"
$appInsightsId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Insights/components/$appInsightsName"
$amplsId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Insights/privateLinkScopes/$amplsName"
$projectId = "$accountId/projects/$projectName"

az account set --subscription $subscriptionId | Out-Null

# ---------------------------------------------------------------------------
# Stage 1 - Dedicated workspace and Application Insights
# ---------------------------------------------------------------------------
Write-Host '==> Stage 1: Log Analytics + Application Insights' -ForegroundColor Cyan
$workspaceExists = Invoke-AzProbe { az monitor log-analytics workspace show -g $resourceGroup -n $workspaceName --query id -o tsv }
if (-not $workspaceExists) {
    Invoke-AzWrite { az monitor log-analytics workspace create -g $resourceGroup -n $workspaceName -l $location --sku PerGB2018 --retention-time $retentionDays } "create Log Analytics '$workspaceName'"
    Write-Host "    created Log Analytics '$workspaceName'" -ForegroundColor Green
} else {
    Write-Host "    Log Analytics '$workspaceName' exists" -ForegroundColor Yellow
}

$appInsightsUrl = "$managementBase$appInsightsId`?api-version=2020-02-02"
$appInsights = Invoke-AzProbe { az resource show --ids $appInsightsId --query id -o tsv }
if (-not $appInsights) {
    $appInsightsBody = @{
        location = $location
        kind = 'web'
        properties = @{
            Application_Type = 'web'
            Flow_Type = 'Bluefield'
            Request_Source = 'rest'
            WorkspaceResourceId = $workspaceId
            publicNetworkAccessForIngestion = 'Enabled'
            publicNetworkAccessForQuery = 'Enabled'
        }
    } | ConvertTo-Json -Depth 8
    Invoke-AzRest -Method PUT -Url $appInsightsUrl -BodyJson $appInsightsBody | Out-Null
    Write-Host "    created Application Insights '$appInsightsName'" -ForegroundColor Green
} else {
    Write-Host "    Application Insights '$appInsightsName' exists" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Stage 2 - AMPLS and scoped resources
# ---------------------------------------------------------------------------
Write-Host '==> Stage 2: Azure Monitor Private Link Scope' -ForegroundColor Cyan
$amplsUrl = "$managementBase$amplsId`?api-version=2023-06-01-preview"
$amplsExists = Invoke-AzProbe { az resource show --ids $amplsId --query id -o tsv }
if (-not $amplsExists) {
    $amplsBody = @{
        location = 'global'
        properties = @{
            accessModeSettings = @{
                ingestionAccessMode = 'PrivateOnly'
                queryAccessMode = 'PrivateOnly'
            }
        }
    } | ConvertTo-Json -Depth 8
    Invoke-AzRest -Method PUT -Url $amplsUrl -BodyJson $amplsBody | Out-Null
    Write-Host "    created AMPLS '$amplsName' (PrivateOnly)" -ForegroundColor Green
} else {
    Write-Host "    AMPLS '$amplsName' exists" -ForegroundColor Yellow
}

foreach ($scopedResource in @(
    @{ Name = 'log-analytics'; ResourceId = $workspaceId },
    @{ Name = 'application-insights'; ResourceId = $appInsightsId }
)) {
    $scopedId = "$amplsId/scopedResources/$($scopedResource.Name)"
    $scopedExists = Invoke-AzProbe { az resource show --ids $scopedId --api-version 2023-06-01-preview --query id -o tsv }
    if (-not $scopedExists) {
        $scopedBody = @{
            properties = @{
                kind = 'Resource'
                linkedResourceId = $scopedResource.ResourceId
            }
        } | ConvertTo-Json -Depth 6
        $scopedUrl = "$managementBase$scopedId`?api-version=2023-06-01-preview"
        Invoke-AzRest -Method PUT -Url $scopedUrl -BodyJson $scopedBody | Out-Null
        Write-Host "    added $($scopedResource.Name) to AMPLS" -ForegroundColor Green
    } else {
        Write-Host "    $($scopedResource.Name) already in AMPLS" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Stage 3 - Private DNS and AMPLS private endpoint
# ---------------------------------------------------------------------------
Write-Host '==> Stage 3: AMPLS private endpoint + DNS' -ForegroundColor Cyan
foreach ($zone in $obs.private_dns_zones) {
    $zoneExists = Invoke-AzProbe { az network private-dns zone show -g $resourceGroup -n $zone --query id -o tsv }
    if (-not $zoneExists) {
        Invoke-AzWrite { az network private-dns zone create -g $resourceGroup -n $zone } "create DNS zone '$zone'"
        Write-Host "    created DNS zone '$zone'" -ForegroundColor Green
    }
    $linkName = ($zone -replace '\.', '-') + '-ni-link'
    $linkExists = Invoke-AzProbe { az network private-dns link vnet show -g $resourceGroup -z $zone -n $linkName --query id -o tsv }
    if (-not $linkExists) {
        Invoke-AzWrite { az network private-dns link vnet create -g $resourceGroup -z $zone -n $linkName --virtual-network $vnetName --registration-enabled false } "link DNS zone '$zone'"
        Write-Host "    linked '$zone' to $vnetName" -ForegroundColor Green
    }
}

$subnetId = az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $privateEndpointSubnet --query id -o tsv
$privateEndpointExists = Invoke-AzProbe { az network private-endpoint show -g $resourceGroup -n $privateEndpointName --query id -o tsv }
if (-not $privateEndpointExists) {
    Invoke-AzWrite { az network private-endpoint create -g $resourceGroup -n $privateEndpointName -l $location --subnet $subnetId --private-connection-resource-id $amplsId --group-id $obs.private_endpoint_group_id --connection-name $privateEndpointConnectionName } "create AMPLS private endpoint '$privateEndpointName'"
    Write-Host "    created private endpoint '$privateEndpointName'" -ForegroundColor Green
} else {
    Write-Host "    private endpoint '$privateEndpointName' exists" -ForegroundColor Yellow
}

$zoneGroupExists = Invoke-AzProbe { az network private-endpoint dns-zone-group show -g $resourceGroup --endpoint-name $privateEndpointName -n $dnsZoneGroupName --query id -o tsv }
if (-not $zoneGroupExists) {
    $zoneIndex = 0
    foreach ($zone in $obs.private_dns_zones) {
        $zoneId = az network private-dns zone show -g $resourceGroup -n $zone --query id -o tsv
        $zoneConfigName = $zone -replace '\.', '-'
        if ($zoneIndex -eq 0) {
            Invoke-AzWrite { az network private-endpoint dns-zone-group create -g $resourceGroup --endpoint-name $privateEndpointName -n $dnsZoneGroupName --private-dns-zone $zoneId --zone-name $zoneConfigName } 'create AMPLS DNS zone group'
        } else {
            Invoke-AzWrite { az network private-endpoint dns-zone-group add -g $resourceGroup --endpoint-name $privateEndpointName -n $dnsZoneGroupName --private-dns-zone $zoneId --zone-name $zoneConfigName } "add '$zone' to AMPLS DNS zone group"
        }
        $zoneIndex++
    }
    Write-Host "    DNS zone group covers $($obs.private_dns_zones.Count) zones" -ForegroundColor Green
} else {
    Write-Host '    DNS zone group exists' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Stage 4 - Disable public monitoring ingestion and query
# ---------------------------------------------------------------------------
Write-Host '==> Stage 4: disable public monitoring access' -ForegroundColor Cyan
$workspaceUrl = "$managementBase$workspaceId`?api-version=2025-07-01"
$workspaceBody = @{
    properties = @{
        publicNetworkAccessForIngestion = $obs.public_network_access_for_ingestion
        publicNetworkAccessForQuery = $obs.public_network_access_for_query
    }
} | ConvertTo-Json -Depth 6
Invoke-AzRest -Method PATCH -Url $workspaceUrl -BodyJson $workspaceBody | Out-Null

$appInsightsNetworkBody = @{
    properties = @{
        publicNetworkAccessForIngestion = $obs.public_network_access_for_ingestion
        publicNetworkAccessForQuery = $obs.public_network_access_for_query
    }
} | ConvertTo-Json -Depth 6
Invoke-AzRest -Method PATCH -Url $appInsightsUrl -BodyJson $appInsightsNetworkBody | Out-Null
Write-Host '    public ingestion and query access disabled' -ForegroundColor Green

# ---------------------------------------------------------------------------
# Stage 5 - Foundry account diagnostic setting
# ---------------------------------------------------------------------------
Write-Host '==> Stage 5: Foundry account diagnostic setting' -ForegroundColor Cyan
$supportedCategories = @(az monitor diagnostic-settings categories list --resource $accountId --query "value[?categoryType=='Logs'].name" -o tsv)
foreach ($category in $obs.diagnostic_log_categories) {
    if ($category -notin $supportedCategories) { throw "Foundry diagnostic category '$category' is not supported by $accountId" }
}
$diagnosticLogs = @($obs.diagnostic_log_categories | ForEach-Object { @{ category = $_; enabled = $true } })
$diagnosticBody = @{
    properties = @{
        workspaceId = $workspaceId
        logAnalyticsDestinationType = 'Dedicated'
        logs = $diagnosticLogs
    }
} | ConvertTo-Json -Depth 10
$diagnosticUrl = "$managementBase$accountId/providers/Microsoft.Insights/diagnosticSettings/$diagnosticSettingName`?api-version=2021-05-01-preview"
Invoke-AzRest -Method PUT -Url $diagnosticUrl -BodyJson $diagnosticBody | Out-Null
Write-Host "    diagnostic setting '$diagnosticSettingName' enabled" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Stage 6 - Foundry project connection for server-side traces
# ---------------------------------------------------------------------------
Write-Host '==> Stage 6: connect Application Insights to Foundry project' -ForegroundColor Cyan
$appInsightsResource = Invoke-AzRest -Method GET -Url $appInsightsUrl
$connectionString = $appInsightsResource.properties.ConnectionString
if (-not $connectionString) { throw "Application Insights '$appInsightsName' did not return a connection string." }

$connectionBody = @{
    properties = @{
        category = 'AppInsights'
        target = $appInsightsId
        authType = 'ApiKey'
        credentials = @{ key = $connectionString }
        isSharedToAll = $true
        metadata = @{
            ApiType = 'Azure'
            ResourceId = $appInsightsId
            location = $location
        }
    }
} | ConvertTo-Json -Depth 10
$connectionUrl = "$managementBase$projectId/connections/$connectionName`?api-version=$foundryApiVersion"
Invoke-AzRest -Method PUT -Url $connectionUrl -BodyJson $connectionBody | Out-Null
$connectionString = $null
[System.GC]::Collect()
Write-Host "    connected '$appInsightsName' to project '$projectName'" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
Write-Host '==> Verification' -ForegroundColor Cyan
$workspace = az monitor log-analytics workspace show -g $resourceGroup -n $workspaceName -o json | ConvertFrom-Json
$appInsightsResource = Invoke-AzRest -Method GET -Url $appInsightsUrl
$diagnostic = az monitor diagnostic-settings show --resource $accountId -n $diagnosticSettingName -o json | ConvertFrom-Json
$connection = Invoke-AzRest -Method GET -Url $connectionUrl
$privateEndpoint = az network private-endpoint show -g $resourceGroup -n $privateEndpointName -o json | ConvertFrom-Json

if ($workspace.publicNetworkAccessForIngestion -ne 'Disabled' -or $workspace.publicNetworkAccessForQuery -ne 'Disabled') {
    throw 'Log Analytics public network access is not fully disabled.'
}
if ($appInsightsResource.properties.publicNetworkAccessForIngestion -ne 'Disabled' -or $appInsightsResource.properties.publicNetworkAccessForQuery -ne 'Disabled') {
    throw 'Application Insights public network access is not fully disabled.'
}
if ($diagnostic.workspaceId -ne $workspaceId) { throw 'Diagnostic setting does not target the dedicated workspace.' }
if ($connection.properties.category -ne 'AppInsights') { throw 'Foundry project App Insights connection was not created.' }
if ($privateEndpoint.privateLinkServiceConnections[0].privateLinkServiceConnectionState.status -ne 'Approved') {
    throw 'AMPLS private endpoint connection is not approved.'
}

Write-Host ''
Write-Host '==> Private observability is configured.' -ForegroundColor Cyan
Write-Host "    Log Analytics:       $workspaceName (public ingestion/query Disabled)"
Write-Host "    Application Insights: $appInsightsName (public ingestion/query Disabled)"
Write-Host "    AMPLS:                $amplsName / $privateEndpointName"
Write-Host "    Diagnostic setting:   $diagnosticSettingName"
Write-Host "    Foundry connection:   $connectionName"
Write-Host '    Generate a new agent run, wait a few minutes, then validate traces from a VNet-connected client.'