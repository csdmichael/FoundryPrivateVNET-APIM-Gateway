$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$config = Get-Content .\config\azure_resources.json | ConvertFrom-Json
$subscriptionId = $config.subscription_id
$resourceGroup = $config.resource_group
$apimResourceId = $config.apim.resource_id
$apimName = ($apimResourceId -split '/')[-1]
$apimApiId = $config.apim.foundry_api_name
$foundryAccountName = $config.foundry.account_name
$foundryAccountResourceId = $config.foundry.account_resource_id
$projectEndpoint = $config.foundry.project_endpoint.TrimEnd('/')
$projectName = ($projectEndpoint -split '/')[-1]
$foundryProjectResourceId = "$foundryAccountResourceId/projects/$projectName"
$apimGatewayUrl = $config.apim.gateway_url.TrimEnd('/')
$gatewayPath = "$foundryAccountName/openai"
$gatewayUrl = "$apimGatewayUrl/$gatewayPath"
$backendUrl = "https://$foundryAccountName.openai.azure.com"
$connectionName = $apimApiId

Write-Host "Ensuring APIM system-assigned identity for $apimName"
$apim = az apim show --resource-group $resourceGroup --name $apimName -o json | ConvertFrom-Json
if (-not $apim.identity -or [string]::IsNullOrWhiteSpace($apim.identity.principalId)) {
    az resource update --ids $apimResourceId --set identity.type=SystemAssigned -o none
    $apim = az apim show --resource-group $resourceGroup --name $apimName -o json | ConvertFrom-Json
}

$principalId = $apim.identity.principalId
if (-not $principalId) {
    throw "Unable to resolve APIM managed identity principal ID for $apimName"
}

$existingRoleAssignment = az role assignment list --assignee-object-id $principalId --scope $foundryAccountResourceId --query "[?roleDefinitionName=='Cognitive Services User'] | [0].id" -o tsv
if (-not $existingRoleAssignment) {
    az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Cognitive Services User" --scope $foundryAccountResourceId -o none
}

$apiPath = $foundryAccountName
$apiExists = az apim api show --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $apiExists) {
    az apim api create --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --path $apiPath --display-name "Foundry OpenAI Gateway" --protocols https --service-url $backendUrl --subscription-required false -o none
}
else {
    az apim api update --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --set path=$apiPath serviceUrl=$backendUrl subscriptionRequired=false -o none
}

$getOperationId = 'proxy-get'
$postOperationId = 'proxy-post'

$existingGetOperation = az apim api operation show --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --operation-id $getOperationId -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $existingGetOperation) {
    az apim api operation create --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --operation-id $getOperationId --display-name "Proxy OpenAI GET" --method GET --url-template "/*" -o none
}

$existingPostOperation = az apim api operation show --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --operation-id $postOperationId -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $existingPostOperation) {
    az apim api operation create --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --operation-id $postOperationId --display-name "Proxy OpenAI POST" --method POST --url-template "/*" -o none
}

$policyXml = @"
<policies>
  <inbound>
    <base />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
    <set-header name="Host" exists-action="override">
      <value>$foundryAccountName.openai.azure.com</value>
    </set-header>
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

$policyPath = Join-Path ([System.IO.Path]::GetTempPath()) 'foundry-openai-gateway-policy.xml'
$policyXml | Set-Content -Path $policyPath -Encoding UTF8
az apim api policy update --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --xml-file $policyPath -o none

$connectionUrl = "https://management.azure.com$foundryProjectResourceId/connections/$connectionName?api-version=2025-06-01"
$connectionPayload = @{
    properties = @{
        authType = 'None'
        category = 'AzureOpenAI'
        target = $gatewayUrl
        metadata = @{
            ApiType = 'Azure'
            ResourceId = $apimResourceId
            displayName = 'APIM AI Gateway'
        }
    }
}

$payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) 'foundry-apim-gateway-connection.json'
$connectionPayload | ConvertTo-Json -Depth 10 | Set-Content -Path $payloadPath -Encoding UTF8
az rest --method put --headers Content-Type=application/json --url $connectionUrl --body "@$payloadPath" | Out-Null

Write-Host "Ensured Foundry AI gateway via APIM: $gatewayUrl"