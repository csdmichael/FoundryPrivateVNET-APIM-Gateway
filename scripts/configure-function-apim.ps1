<#
.SYNOPSIS
    Import the private Data Function API into the private APIM AI gateway.

.DESCRIPTION
    Reads config/function_app_config.json and config/azure_resources.json (no hardcoding).
    Imports function-app/openapi.json into APIM under the configured path, points the
    backend at the Function App's private hostname, disables the subscription-key
    requirement (access is enforced by the private network + APIM policy), and adds
    the API to the existing product.

    NOTE: For APIM to reach the Function App over its private endpoint, the APIM
    instance must have outbound VNet integration (StandardV2) into a subnet that can
    resolve privatelink.azurewebsites.net. See function-app/README.md.
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

$apiId          = $cfg.apim.api_id
$apiPath        = $cfg.apim.api_path
$apiDisplay     = $cfg.apim.api_display_name
$productId      = $cfg.apim.product_name
$subRequired    = [bool]$cfg.apim.subscription_required

$funcName       = $cfg.function_app.name
$backendUrl     = if ($env:FUNCTION_BACKEND_URL) { $env:FUNCTION_BACKEND_URL } else { "https://$funcName.azurewebsites.net" }
$apiSpec        = Resolve-Path .\function-app\openapi.json

az account set --subscription $subscriptionId | Out-Null

Write-Host "==> Importing '$apiDisplay' into APIM '$apimName' at /$apiPath" -ForegroundColor Cyan
az apim api import --resource-group $resourceGroup --service-name $apimName `
    --path $apiPath --api-id $apiId --display-name $apiDisplay `
    --specification-format OpenApiJson --specification-path $apiSpec `
    --service-url $backendUrl | Out-Null

az apim api update --resource-group $resourceGroup --service-name $apimName `
    --api-id $apiId --subscription-required $subRequired.ToString().ToLower() | Out-Null

Write-Host "==> Applying API policy (backend rewrite + CORS)" -ForegroundColor Cyan
$policyXml = @"
<policies>
  <inbound>
    <base />
    <cors allow-credentials="false">
      <allowed-origins>
        <origin>*</origin>
      </allowed-origins>
      <allowed-methods>
        <method>GET</method>
        <method>OPTIONS</method>
      </allowed-methods>
      <allowed-headers>
        <header>*</header>
      </allowed-headers>
    </cors>
    <set-backend-service base-url="$backendUrl" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
"@

$policyBodyPath = Join-Path ([System.IO.Path]::GetTempPath()) 'func-apim-policy.json'
@{ properties = @{ format = 'xml'; value = $policyXml } } | ConvertTo-Json -Depth 6 | Set-Content -Path $policyBodyPath -Encoding UTF8
az rest --method PUT `
    --url "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName/apis/$apiId/policies/policy?api-version=2024-05-01" `
    --body "@$policyBodyPath" | Out-Null
Remove-Item $policyBodyPath -Force -ErrorAction SilentlyContinue

$existingProduct = az apim product show --resource-group $resourceGroup --service-name $apimName --product-id $productId 2>$null
if ($existingProduct) {
    Write-Host "==> Adding API to product '$productId'" -ForegroundColor Cyan
    az apim product api add --resource-group $resourceGroup --service-name $apimName --product-id $productId --api-id $apiId | Out-Null
}

$gateway = $res.apim.gateway_url.TrimEnd('/')
Write-Host ""
Write-Host "==> Done. API available through APIM:" -ForegroundColor Cyan
Write-Host "    APIM base    : $gateway/$apiPath/api"
Write-Host "    APIM OpenAPI : $gateway/$apiPath/api/openapi.json"
Write-Host "    (Reachable only from inside the VNet - APIM public access is disabled.)"
