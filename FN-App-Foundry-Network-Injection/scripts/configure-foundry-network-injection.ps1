<#
.SYNOPSIS
    Wire the private Foundry account to use VIRTUAL NETWORK INJECTION into the new eastus2
    VNet so its agent compute runs inside the VNet and can reach the private Function App
    directly over private DNS.

.DESCRIPTION
    Reads config/network_injection_config.json. Performs, idempotently:

      1. Foundry private DNS zones (services.ai / cognitiveservices / openai) created and
         linked to the new eastus2 VNet, so private names resolve from inside it.
      2. A private endpoint for the Foundry account (groupId 'account') into the new VNet's
         private-endpoints subnet, with a DNS zone group covering the 3 zones above.
      3. PATCH the account properties.networkInjections to point the 'agent' scenario at the
         agents-injection subnet (delegated Microsoft.App/environments).

    PREREQUISITE — Standard Agent setup: Foundry network injection is only accepted when the
    account is configured as a Standard Agent (bring-your-own Storage + Azure AI Search +
    Cosmos DB, each privately networked, plus account/project capability hosts) AND public
    network access is Disabled. If those are missing, the networkInjections PATCH is rejected;
    this script reports that clearly instead of leaving partial state. Use the Microsoft sample
    '15-private-network-standard-agent-setup' to stand up the BYO resources + capability hosts
    first. See the folder README.md.

.PARAMETER WhatIfInjection
    Run stages 1-2 (DNS + private endpoint) but only PRINT the networkInjections PATCH body
    without applying it.

.NOTES
    Windows az gotchas handled: --body files written BOM-free; response bodies routed to a
    temp file via --output-file to avoid the cp1252/BOM console crash.
#>
[CmdletBinding()]
param(
    [switch]$WhatIfInjection
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

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

# Write JSON to a BOM-free temp file (az reads a BOM literally -> InvalidRequestContent).
function Write-JsonNoBom {
    param([Parameter(Mandatory)][string]$Json)
    $f = New-TemporaryFile
    [System.IO.File]::WriteAllText($f.FullName, $Json, (New-Object System.Text.UTF8Encoding($false)))
    return $f.FullName
}

Write-Host '==> Loading configuration' -ForegroundColor Cyan
$cfg = Get-Content .\config\network_injection_config.json -Raw | ConvertFrom-Json

$subscriptionId = $cfg.subscription_id
$resourceGroup  = $cfg.resource_group
$location       = $cfg.location

$net            = $cfg.networking
$vnetName       = $net.vnet_name
$peSubnet       = $net.private_endpoint_subnet
$agentSubnet    = $net.agents_injection_subnet
$foundryZones   = $net.foundry_private_dns_zones

$fdry           = $cfg.foundry
$accountName    = $fdry.account_name
$accountId      = $fdry.account_resource_id
$apiVersion     = $fdry.account_api_version
$niScenario     = $fdry.network_injection.scenario
$niManaged      = [bool]$fdry.network_injection.use_microsoft_managed_network

az account set --subscription $subscriptionId | Out-Null

# ---------------------------------------------------------------------------
# Stage 1 - Foundry private DNS zones linked to the new VNet
# ---------------------------------------------------------------------------
Write-Host "==> Stage 1: Foundry private DNS zones -> $vnetName" -ForegroundColor Cyan
foreach ($zone in $foundryZones) {
    $zoneId = Invoke-AzProbe { az network private-dns zone show -g $resourceGroup -n $zone --query id -o tsv }
    if (-not $zoneId) {
        Invoke-AzWrite { az network private-dns zone create -g $resourceGroup -n $zone } "zone $zone"
        Write-Host "    created zone '$zone'" -ForegroundColor Green
    }
    $linkName = ($zone -replace '\.','-') + '-ni-link'
    $linkExists = Invoke-AzProbe { az network private-dns link vnet show -g $resourceGroup -z $zone -n $linkName --query id -o tsv }
    if (-not $linkExists) {
        Invoke-AzWrite { az network private-dns link vnet create -g $resourceGroup -z $zone -n $linkName --virtual-network $vnetName --registration-enabled false } "link $zone"
        Write-Host "    linked '$zone' to $vnetName" -ForegroundColor Green
    } else {
        Write-Host "    '$zone' already linked" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Stage 2 - Foundry account private endpoint into the new VNet
# ---------------------------------------------------------------------------
Write-Host "==> Stage 2: Foundry account private endpoint" -ForegroundColor Cyan
$peSubnetId = az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $peSubnet --query id -o tsv
$peName = "pe-$accountName-ni"
$peExists = Invoke-AzProbe { az network private-endpoint show -g $resourceGroup -n $peName --query id -o tsv }
if (-not $peExists) {
    Invoke-AzWrite { az network private-endpoint create -g $resourceGroup -n $peName -l $location --subnet $peSubnetId --private-connection-resource-id $accountId --group-id account --connection-name "$peName-conn" } "Foundry PE create"
    Write-Host "    created PE '$peName' (account)" -ForegroundColor Green
} else {
    Write-Host "    PE '$peName' exists" -ForegroundColor Yellow
}
# DNS zone group spanning all 3 Foundry zones.
$zgExists = Invoke-AzProbe { az network private-endpoint dns-zone-group show -g $resourceGroup --endpoint-name $peName -n 'foundry-ni-zone-group' --query id -o tsv }
if (-not $zgExists) {
    $i = 0
    foreach ($zone in $foundryZones) {
        $zoneId = az network private-dns zone show -g $resourceGroup -n $zone --query id -o tsv
        $zoneCfgName = ($zone -replace '\.','-')
        if ($i -eq 0) {
            Invoke-AzWrite { az network private-endpoint dns-zone-group create -g $resourceGroup --endpoint-name $peName -n 'foundry-ni-zone-group' --private-dns-zone $zoneId --zone-name $zoneCfgName } "zone-group create"
        } else {
            Invoke-AzWrite { az network private-endpoint dns-zone-group add -g $resourceGroup --endpoint-name $peName -n 'foundry-ni-zone-group' --private-dns-zone $zoneId --zone-name $zoneCfgName } "zone-group add $zone"
        }
        $i++
    }
    Write-Host "    DNS zone group covers $($foundryZones.Count) Foundry zones" -ForegroundColor Green
} else {
    Write-Host "    DNS zone group exists" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Stage 3 - Network injection PATCH (agent scenario -> agents-injection subnet)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 3: network injection (agent -> $agentSubnet)" -ForegroundColor Cyan
$agentSubnetId = az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $agentSubnet --query id -o tsv
$body = @{
    properties = @{
        networkInjections = @(
            @{
                scenario                  = $niScenario
                subnetArmId               = $agentSubnetId
                useMicrosoftManagedNetwork = $niManaged
            }
        )
    }
} | ConvertTo-Json -Depth 8

if ($WhatIfInjection) {
    Write-Host "    -WhatIfInjection: PATCH body (NOT applied):" -ForegroundColor Yellow
    Write-Host $body
    return
}

$bodyFile = Write-JsonNoBom -Json $body
$respFile = New-TemporaryFile
$url = 'https://management.azure.com' + $accountId + '?api-version=' + $apiVersion
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
az rest --method PATCH --url $url --body ("@" + $bodyFile) --headers "Content-Type=application/json" --output-file $respFile.FullName 2>&1 | Out-Null
$patchExit = $LASTEXITCODE
$ErrorActionPreference = $prev
Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue

if ($patchExit -ne 0) {
    Write-Host "    networkInjections PATCH FAILED (exit $patchExit)." -ForegroundColor Red
    Write-Host "    This usually means the account is NOT a Standard Agent setup yet." -ForegroundColor Red
    Write-Host "    Network injection requires BYO Storage + Azure AI Search + Cosmos DB (all private)" -ForegroundColor Red
    Write-Host "    plus account/project capability hosts. Stand those up first with the Microsoft sample" -ForegroundColor Red
    Write-Host "    '15-private-network-standard-agent-setup', then re-run this script." -ForegroundColor Red
    if (Test-Path $respFile.FullName) { Write-Host (Get-Content $respFile.FullName -Raw) -ForegroundColor DarkGray }
    Remove-Item $respFile.FullName -Force -ErrorAction SilentlyContinue
    throw "networkInjections PATCH failed"
}
Remove-Item $respFile.FullName -Force -ErrorAction SilentlyContinue

# Verify
$applied = az rest --method GET --url $url -o json | ConvertFrom-Json
$inj = $applied.properties.networkInjections
Write-Host "    network injection applied:" -ForegroundColor Green
$inj | ConvertTo-Json -Depth 8 | Write-Host

Write-Host ""
Write-Host "==> Done. Foundry account '$accountName' is injected into $vnetName/$agentSubnet." -ForegroundColor Cyan
Write-Host "    Next: scripts/create_ni_function_agent.py (agent tool -> private Function App)"
