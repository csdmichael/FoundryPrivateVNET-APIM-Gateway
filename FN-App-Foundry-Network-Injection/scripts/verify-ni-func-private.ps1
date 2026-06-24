<#
.SYNOPSIS
    Verify the network-injection Function App is locked to private-only access and that the
    private DNS plumbing (privatelink.azurewebsites.net A record + NI VNet link) is in place.

.DESCRIPTION
    Reads the canonical values from config/network_injection_config.json and checks:
      1. Function App  properties.publicNetworkAccess == 'Disabled'   (read via ARM REST,
         because 'az functionapp show --query' returns blanks for this property on Flex apps).
      2. Private endpoint 'pe-func-data-ni-eastus2' provisioning/connection state.
      3. privatelink.azurewebsites.net zone is linked to the NI VNet.
      4. An A record for the Function App host exists in that zone.

.NOTES
    Microsoft Learn references are listed in the folder README.md.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $PSScriptRoot '..\config\network_injection_config.json'
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json

$rg       = $cfg.resource_group
$sub      = $cfg.subscription_id
$funcName = $cfg.function_app.name
$vnetName = $cfg.networking.vnet_name
$webZone  = $cfg.networking.private_dns_zone
$peName   = $cfg.networking.private_endpoint_name

Write-Host "==> Verifying private posture for '$funcName'" -ForegroundColor Cyan
Write-Host "    resource group : $rg"
Write-Host "    vnet           : $vnetName`n"

function Show-Result($label, $ok, $detail) {
    $icon = if ($ok) { '[PASS]' } else { '[FAIL]' }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0} {1}: {2}" -f $icon, $label, $detail) -ForegroundColor $color
}

# 1. Function public network access (ARM REST -- projection queries return blank on Flex)
$funcId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/sites/$funcName"
$funcJson = az rest --method get --url "https://management.azure.com$funcId`?api-version=2023-12-01" -o json | ConvertFrom-Json
$pna  = $funcJson.properties.publicNetworkAccess
$fqdn = $funcJson.properties.defaultHostName
Show-Result 'Function publicNetworkAccess' ($pna -eq 'Disabled') $pna
Write-Host "        host: $fqdn"

# 2. Private endpoint state
$peJson = az network private-endpoint show -g $rg -n $peName -o json 2>$null | ConvertFrom-Json
if ($peJson) {
    $conn = $peJson.privateLinkServiceConnections[0]
    $state = $conn.privateLinkServiceConnectionState.status
    $grp   = ($conn.groupIds -join ',')
    Show-Result 'Private endpoint' ($state -eq 'Approved') "$peName (group=$grp, state=$state)"
} else {
    Show-Result 'Private endpoint' $false "$peName NOT FOUND"
}

# 3. privatelink.azurewebsites.net zone linked to NI vnet
$links = az network private-dns link vnet list -g $rg -z $webZone -o json 2>$null | ConvertFrom-Json
$niLinked = $false
foreach ($l in $links) { if ($l.virtualNetwork.id -match [regex]::Escape("/$vnetName")) { $niLinked = $true; $linkName = $l.name } }
Show-Result 'DNS zone linked to NI vnet' $niLinked $(if ($niLinked) { "$webZone -> $linkName" } else { "$webZone NOT linked to $vnetName" })

# 4. A record for the function host
$shortHost = $funcName  # record set name is the leftmost label of the host
$records = az network private-dns record-set a list -g $rg -z $webZone -o json 2>$null | ConvertFrom-Json
$aRec = $records | Where-Object { $_.name -eq $shortHost -or $_.fqdn -match [regex]::Escape($funcName) }
if ($aRec) {
    $ips = ($aRec.aRecords.ipv4Address -join ',')
    Show-Result 'Private A record' $true "$($aRec[0].name) -> $ips"
} else {
    Show-Result 'Private A record' $false "no A record matching '$funcName' in $webZone"
}

Write-Host "`n==> Verification complete." -ForegroundColor Cyan
