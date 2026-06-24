<#
.SYNOPSIS
    Move the APIM ip-filter from the global scope to per-API scope so the data-function
    API can use Entra ID (managed-identity) token auth without exposing the other APIs.

.DESCRIPTION
    The global ip-filter blocked every caller -- including the Foundry agent's
    Microsoft-managed egress IP, which is not in any allowlist. This script:

      1. Empties the global (service-scope) policy (removes the ip-filter).
      2. Re-applies the ip-filter at API scope on each API listed in
         config/function_app_config.json -> apim.ip_filter_apis.api_ids, using the
         ranges in apim.ip_allowlist.ranges. Existing API policy is preserved; the
         ip-filter is injected right after <base /> and the operation is idempotent.

    The data-function API itself is configured separately by configure-function-apim.ps1
    (Entra ID token OR ip-filter fallback), so it is intentionally not touched here.

    Run configure-function-apim.ps1 first (it imports the API and sets its auth policy),
    then this script to lock down the remaining APIs.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$cfg = Get-Content .\config\function_app_config.json -Raw | ConvertFrom-Json
$res = Get-Content .\config\azure_resources.json -Raw | ConvertFrom-Json

$subscriptionId = $cfg.subscription_id
$resourceGroup  = $cfg.resource_group
$apimName       = ($res.apim.resource_id -split '/')[-1]
$apiVer         = '2024-05-01'

$ranges  = $cfg.apim.ip_allowlist.ranges
$apiIds  = $cfg.apim.ip_filter_apis.api_ids

$tok  = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$hdr  = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }
$base = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName"

# ip-filter fragment from config (ip-filter requires explicit ranges, not CIDR).
$ipFilter = "<ip-filter action=`"allow`">`n" + (
    ($ranges | ForEach-Object { "            <address-range from=`"$($_.from)`" to=`"$($_.to)`" />" }) -join "`n"
) + "`n        </ip-filter>"

function Put-Policy([string]$url, [string]$xml) {
    $body = @{ properties = @{ format = 'rawxml'; value = $xml } } | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Method PUT -Uri $url -Headers $hdr -Body $body | Out-Null
}

# 1) Empty the global policy (NO <base/> is allowed at global scope).
Write-Host "==> Clearing global ip-filter (service scope)" -ForegroundColor Cyan
$globalXml = "<policies>`n    <inbound />`n    <backend>`n        <forward-request />`n    </backend>`n    <outbound />`n    <on-error />`n</policies>"
Put-Policy "$base/policies/policy?api-version=$apiVer" $globalXml

# 2) Inject ip-filter at API scope on each sensitive API (idempotent).
foreach ($apiId in $apiIds) {
    $url = "$base/apis/$apiId/policies/policy?format=rawxml&api-version=$apiVer"
    try {
        $cur = (Invoke-RestMethod -Method GET -Uri $url -Headers $hdr).properties.value
    } catch {
        $cur = "<policies>`n    <inbound>`n        <base />`n    </inbound>`n    <backend>`n        <base />`n    </backend>`n    <outbound>`n        <base />`n    </outbound>`n    <on-error>`n        <base />`n    </on-error>`n</policies>"
    }
    if ($cur -match '<ip-filter') {
        Write-Host "==> $apiId already has an ip-filter - skipping" -ForegroundColor DarkGray
        continue
    }
    # Insert the ip-filter right after the first <base /> (inside <inbound>).
    $new = [regex]::Replace($cur, '(<base\s*/>)', "`$1`n        $ipFilter", 1)
    Put-Policy ("$base/apis/$apiId/policies/policy?api-version=$apiVer") $new
    Write-Host "==> Applied ip-filter at API scope: $apiId" -ForegroundColor Green
}

Write-Host ""
Write-Host "==> Done. Global ip-filter removed; per-API ip-filter applied to: $($apiIds -join ', ')" -ForegroundColor Cyan
Write-Host "    The data-function API uses Entra ID token auth (see configure-function-apim.ps1)."
