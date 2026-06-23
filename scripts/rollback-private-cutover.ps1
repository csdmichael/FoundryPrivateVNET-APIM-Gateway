<#
.SYNOPSIS
    Rollback / teardown for the private-VNET cutover of the POC APIM + Foundry.

.DESCRIPTION
    On 2026-06-23 the following private-network cutover was applied to the POC:

      APIM  ai-gateway-apim-poc-my (RG ai-myaacoub, eastus)
        - SKU upgraded BasicV2 -> StandardV2 (REQUIRED: BasicV2 cannot host a private endpoint).
        - Inbound private endpoint  pe-apim-poc-eastus  in vnet-fdryvnetgw-eastus / subnet
          private-endpoints (sub-resource = Gateway), private IP 10.40.2.8.
        - Private DNS zone  privatelink.azure-api.net  (+ vnet link) created; A record
          ai-gateway-apim-poc-my -> 10.40.2.8.
        - publicNetworkAccess = Disabled  (internet calls now return HTTP 403).

      Foundry account  002-ai-poc-private  (Microsoft.CognitiveServices)
        - Added private DNS zones  privatelink.cognitiveservices.azure.com  and
          privatelink.openai.azure.com  (+ vnet links) and wired them into the existing
          private endpoint pe-fdryvnetgwfdry-eastus DNS zone group.
          (services.ai.azure.com was already wired.)
          A records: cognitiveservices 10.40.2.4, openai 10.40.2.5, services.ai 10.40.2.6.
        - publicNetworkAccess = Disabled.

.PARAMETER Mode
    ReEnablePublic (default) - the "one command" rollback: flips public access back ON for
                               BOTH APIM and Foundry. Leaves the private endpoints + DNS zones
                               in place (harmless; they just provide an extra private path).
    FullTeardown            - additionally removes the private endpoint, the azure-api.net DNS
                               zone, and the cognitiveservices/openai zones added for Foundry.

.NOTES
    The APIM SKU change BasicV2 -> StandardV2 is ONE-WAY. Azure does not support downgrading a
    v2 tier back to BasicV2, so this script does NOT attempt it. If you need BasicV2 back you
    must recreate the instance.

.EXAMPLE
    pwsh ./scripts/rollback-private-cutover.ps1
    pwsh ./scripts/rollback-private-cutover.ps1 -Mode FullTeardown
#>
[CmdletBinding()]
param(
    [ValidateSet('ReEnablePublic', 'FullTeardown')]
    [string]$Mode = 'ReEnablePublic',

    [string]$SubscriptionId = '86b37969-9445-49cf-b03f-d8866235171c',
    [string]$ResourceGroup  = 'ai-myaacoub',
    [string]$ApimName       = 'ai-gateway-apim-poc-my',
    [string]$FoundryName    = '002-ai-poc-private',
    [string]$ApimPeName     = 'pe-apim-poc-eastus',
    [string]$FoundryPeName  = 'pe-fdryvnetgwfdry-eastus'
)

$ErrorActionPreference = 'Stop'
$apimApi    = '2024-05-01'
$foundryApi = '2024-10-01'

function Set-PublicAccess {
    param([string]$ResourceId, [string]$ApiVersion, [string]$State)
    $bodyFile = Join-Path $env:TEMP ("pna-" + [guid]::NewGuid().ToString('N') + '.json')
    ('{"properties":{"publicNetworkAccess":"' + $State + '"}}') |
        Out-File -FilePath $bodyFile -Encoding ascii -NoNewline
    $url = 'https://management.azure.com' + $ResourceId + '?api-version=' + $ApiVersion
    az rest --method PATCH --url $url --body "@$bodyFile" --headers 'Content-Type=application/json' --query 'properties.publicNetworkAccess' -o tsv | Out-Null
    Remove-Item $bodyFile -ErrorAction SilentlyContinue
}

az account set --subscription $SubscriptionId | Out-Null

$apimId    = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$foundryId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$FoundryName"

Write-Host "Re-enabling PUBLIC network access on APIM '$ApimName'..." -ForegroundColor Cyan
Set-PublicAccess -ResourceId $apimId -ApiVersion $apimApi -State 'Enabled'

Write-Host "Re-enabling PUBLIC network access on Foundry '$FoundryName'..." -ForegroundColor Cyan
Set-PublicAccess -ResourceId $foundryId -ApiVersion $foundryApi -State 'Enabled'

Write-Host "Waiting for both resources to reach a stable state..." -ForegroundColor Cyan
az apim wait -g $ResourceGroup -n $ApimName --updated --interval 20 --timeout 1200 -o none
do {
    Start-Sleep -Seconds 10
    $fState = az cognitiveservices account show -g $ResourceGroup -n $FoundryName --query 'properties.provisioningState' -o tsv
    Write-Host "  Foundry provisioningState = $fState"
} while ($fState -ne 'Succeeded')

if ($Mode -eq 'FullTeardown') {
    Write-Host "FullTeardown: removing private endpoint + DNS artifacts..." -ForegroundColor Yellow

    # APIM private endpoint + its DNS zone
    az network private-endpoint delete -g $ResourceGroup -n $ApimPeName -o none 2>$null
    az network private-dns link vnet delete -g $ResourceGroup -z privatelink.azure-api.net -n link-vnet-fdryvnetgw-eastus --yes -o none 2>$null
    az network private-dns zone delete -g $ResourceGroup -n privatelink.azure-api.net --yes -o none 2>$null

    # Foundry: remove the zones added for this cutover from the PE DNS zone group, then the zones.
    # (services.ai.azure.com is left intact - it predates this cutover.)
    az network private-endpoint dns-zone-group remove -g $ResourceGroup --endpoint-name $FoundryPeName --name default --zone-name privatelink.cognitiveservices.azure.com -o none 2>$null
    az network private-endpoint dns-zone-group remove -g $ResourceGroup --endpoint-name $FoundryPeName --name default --zone-name privatelink.openai.azure.com -o none 2>$null
    foreach ($z in @('privatelink.cognitiveservices.azure.com', 'privatelink.openai.azure.com')) {
        az network private-dns link vnet delete -g $ResourceGroup -z $z -n link-vnet-fdryvnetgw-eastus --yes -o none 2>$null
        az network private-dns zone delete -g $ResourceGroup -n $z --yes -o none 2>$null
    }
    Write-Host "Teardown complete. NOTE: APIM remains StandardV2 (BasicV2 downgrade is not supported)." -ForegroundColor Yellow
}

Write-Host "`nFinal state:" -ForegroundColor Green
az apim show -g $ResourceGroup -n $ApimName --query "{sku:sku.name,publicNetworkAccess:publicNetworkAccess}" -o json
az cognitiveservices account show -g $ResourceGroup -n $FoundryName --query "{publicNetworkAccess:properties.publicNetworkAccess}" -o json
