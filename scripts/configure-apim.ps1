$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$config = Get-Content .\config\azure_resources.json | ConvertFrom-Json
$resourceGroup = $config.resource_group
$apimName = ($config.apim.resource_id -split '/')[-1]
$apiSpec = Resolve-Path .\openapi\foundry-privatevnet-app.openapi.json
$apiId = $config.apim.backend_api_name
$productId = $config.apim.product_name
$apiPath = $config.apim.api_path
$apiDisplayName = 'Foundry Private VNET App API'
$backendUrl = if ($env:API_BACKEND_URL) { $env:API_BACKEND_URL } else { $config.app_services.api_url }

az apim api import --resource-group $resourceGroup --service-name $apimName --path $apiPath --api-id $apiId --specification-format OpenApiJson --specification-path $apiSpec --service-url $backendUrl | Out-Null

# Allow Teams message extensions to call the API without a subscription key
az apim api update --resource-group $resourceGroup --service-name $apimName --api-id $apiId --subscription-required false | Out-Null

$subscriptionId = $config.subscription_id
$policyXml = @"
<policies>
  <inbound>
    <base />
    <set-backend-service base-url="$backendUrl" />
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
"@

$policyBodyPath = Join-Path $env:TEMP 'apim-policy-body.json'
@{properties=@{format="xml"; value=$policyXml}} | ConvertTo-Json -Depth 5 | Set-Content -Path $policyBodyPath -Encoding UTF8
$ErrorActionPreference = 'Continue'
az rest --method PUT --url "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName/apis/$apiId/policies/policy?api-version=2024-05-01" --body "@$policyBodyPath" 2>$null | Out-Null

$existingProduct = az apim product show --resource-group $resourceGroup --service-name $apimName --product-id $productId 2>$null
$ErrorActionPreference = 'Stop'
if (-not $existingProduct) {
    az apim product create --resource-group $resourceGroup --service-name $apimName --product-id $productId --product-name 'Foundry Private VNET Product' --subscription-required true --approval-required false --subscriptions-limit 10 --state published | Out-Null
}

az apim product api add --resource-group $resourceGroup --service-name $apimName --product-id $productId --api-id $apiId | Out-Null
