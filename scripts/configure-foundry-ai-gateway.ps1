$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

function Assert-LastExitCode {
  param(
    [string]$Operation
  )

  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with exit code $LASTEXITCODE."
  }
}

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
Assert-LastExitCode "Reading APIM service '$apimName'"
if (-not $apim.identity -or [string]::IsNullOrWhiteSpace($apim.identity.principalId)) {
  Write-Host "Enabling APIM system-assigned identity"
    az resource update --ids $apimResourceId --set identity.type=SystemAssigned -o none
  Assert-LastExitCode "Enabling system-assigned identity on APIM '$apimName'"
    $apim = az apim show --resource-group $resourceGroup --name $apimName -o json | ConvertFrom-Json
  Assert-LastExitCode "Re-reading APIM service '$apimName' after identity enablement"
}

$principalId = $apim.identity.principalId
if (-not $principalId) {
    throw "Unable to resolve APIM managed identity principal ID for $apimName"
}

$existingRoleAssignment = az role assignment list --assignee-object-id $principalId --scope $foundryAccountResourceId --query "[?roleDefinitionName=='Cognitive Services User'] | [0].id" -o tsv
Assert-LastExitCode "Checking APIM role assignment on Foundry account"
if (-not $existingRoleAssignment) {
  Write-Host "Granting APIM managed identity access to Foundry account"
    az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Cognitive Services User" --scope $foundryAccountResourceId -o none
  Assert-LastExitCode "Creating APIM role assignment on Foundry account"
}

$apiPath = $foundryAccountName
$apiExists = az apim api show --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $apiExists) {
  Write-Host "Creating APIM Foundry gateway API"
    az apim api create --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --path $apiPath --display-name "Foundry OpenAI Gateway" --protocols https --service-url $backendUrl --subscription-required false -o none
  Assert-LastExitCode "Creating APIM API '$apimApiId'"
}
else {
  Write-Host "Updating APIM Foundry gateway API"
    az apim api update --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --set path=$apiPath serviceUrl=$backendUrl subscriptionRequired=false -o none
  Assert-LastExitCode "Updating APIM API '$apimApiId'"
}

$getOperationId = 'proxy-get'
$postOperationId = 'proxy-post'

$existingGetOperation = az apim api operation show --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --operation-id $getOperationId -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $existingGetOperation) {
    az apim api operation create --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --operation-id $getOperationId --display-name "Proxy OpenAI GET" --method GET --url-template "/*" -o none
  Assert-LastExitCode "Creating APIM GET proxy operation"
}

$existingPostOperation = az apim api operation show --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --operation-id $postOperationId -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $existingPostOperation) {
    az apim api operation create --resource-group $resourceGroup --service-name $apimName --api-id $apimApiId --operation-id $postOperationId --display-name "Proxy OpenAI POST" --method POST --url-template "/*" -o none
  Assert-LastExitCode "Creating APIM POST proxy operation"
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
[System.IO.File]::WriteAllText($policyPath, $policyXml, [System.Text.UTF8Encoding]::new($false))

$policyBodyPath = Join-Path ([System.IO.Path]::GetTempPath()) 'foundry-openai-gateway-policy.json'
$policyBodyJson = @{properties=@{format="rawxml"; value=$policyXml}} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($policyBodyPath, $policyBodyJson, [System.Text.UTF8Encoding]::new($false))
Write-Host "Updating APIM gateway policy"
$policyUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName/apis/$apimApiId/policies/policy?api-version=2024-05-01"
$ErrorActionPreference = 'Continue'
# az rest returns exit code 1 for non-JSON (XML) responses; capture output to detect real errors
$policyResult = az rest --method PUT --headers Content-Type=application/json --url $policyUrl --body "@$policyBodyPath" 2>&1
$ErrorActionPreference = 'Stop'
# Only fail if a real HTTP error (4xx/5xx) is present, not az CLI encoding bugs
$httpError = $policyResult | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Where-Object { $_.Exception.Message -match '(BadRequest|Unauthorized|Forbidden|NotFound|Conflict|InternalServerError|\b[45]\d{2}\b)' }
if ($httpError) { throw "Updating APIM policy for API '$apimApiId' failed: $httpError" }

$connectionUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.CognitiveServices/accounts/$foundryAccountName/projects/$projectName/connections/$connectionName?api-version=2025-04-01-preview"
$connectionPayload = @{
    properties = @{
    authType = 'ProjectManagedIdentity'
    audience = 'https://cognitiveservices.azure.com'
    category = 'ApiManagement'
    credentials = @{}
    isSharedToAll = $false
        target = $gatewayUrl
        metadata = @{
      deploymentInPath = 'true'
      displayName = 'APIM AI Gateway'
      inferenceAPIVersion = '2024-10-21'
        }
    }
}

$payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) 'foundry-apim-gateway-connection.json'
$connectionPayload | ConvertTo-Json -Depth 10 | ForEach-Object { [System.IO.File]::WriteAllText($payloadPath, $_, [System.Text.UTF8Encoding]::new($false)) }
Write-Host "Creating or updating Foundry APIM connection '$connectionName'"
$ErrorActionPreference = 'Continue'
$connResult = az rest --method put --headers Content-Type=application/json --url $connectionUrl --body "@$payloadPath" 2>&1
$ErrorActionPreference = 'Stop'
$realConnError = $connResult | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Where-Object { $_.Exception.Message -match '(BadRequest|Unauthorized|Forbidden|NotFound|Conflict|InternalServerError|\b[45]\d{2}\b)' }
if ($realConnError) { throw "Creating or updating Foundry APIM connection '$connectionName' failed: $realConnError" }

Write-Host "Ensured Foundry AI gateway via APIM: $gatewayUrl"

# ── Foundry Agents API proxy ────────────────────────────────────────────────
# Proxies the Foundry project's Agents/Assistants REST API through APIM so
# agent CRUD (create, list, delete) also runs through the managed gateway.
$agentsApiId   = $config.apim.foundry_agents_api_name
$agentsApiPath = $config.apim.foundry_agents_api_path
$agentsBackend = "https://$foundryAccountName.services.ai.azure.com"
$agentsGatewayUrl = "$apimGatewayUrl/$agentsApiPath"

Write-Host "`nConfiguring Foundry Agents API proxy via APIM"

$ErrorActionPreference = 'Continue'
$agentsApiExists = az apim api show --resource-group $resourceGroup --service-name $apimName --api-id $agentsApiId -o json 2>$null
$agentsApiExitCode = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($agentsApiExitCode -ne 0 -or -not $agentsApiExists) {
    Write-Host "Creating APIM Foundry Agents API"
    az apim api create --resource-group $resourceGroup --service-name $apimName --api-id $agentsApiId --path $agentsApiPath --display-name "Foundry Agents Gateway" --protocols https --service-url $agentsBackend --subscription-required false -o none
    Assert-LastExitCode "Creating APIM API '$agentsApiId'"
}
else {
    Write-Host "Updating APIM Foundry Agents API"
    az apim api update --resource-group $resourceGroup --service-name $apimName --api-id $agentsApiId --set path=$agentsApiPath serviceUrl=$agentsBackend subscriptionRequired=false -o none
    Assert-LastExitCode "Updating APIM API '$agentsApiId'"
}

# Wildcard proxy operations for GET, POST, DELETE, PATCH
$agentsOps = @(
    @{ Id = 'agents-get';    Method = 'GET';    Display = 'Proxy Agents GET' },
    @{ Id = 'agents-post';   Method = 'POST';   Display = 'Proxy Agents POST' },
    @{ Id = 'agents-delete'; Method = 'DELETE'; Display = 'Proxy Agents DELETE' },
    @{ Id = 'agents-patch';  Method = 'PATCH';  Display = 'Proxy Agents PATCH' }
)
foreach ($op in $agentsOps) {
    $ErrorActionPreference = 'Continue'
    $existingOp = az apim api operation show --resource-group $resourceGroup --service-name $apimName --api-id $agentsApiId --operation-id $op.Id -o json 2>$null
    $opExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($opExitCode -ne 0 -or -not $existingOp) {
        az apim api operation create --resource-group $resourceGroup --service-name $apimName --api-id $agentsApiId --operation-id $op.Id --display-name $op.Display --method $op.Method --url-template "/*" -o none
        Assert-LastExitCode "Creating APIM $($op.Method) proxy operation for agents"
    }
}

# Policy: managed identity auth to Foundry services.ai.azure.com
$agentsPolicyXml = @"
<policies>
  <inbound>
    <base />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
    <set-header name="Host" exists-action="override">
      <value>$foundryAccountName.services.ai.azure.com</value>
    </set-header>
    <set-backend-service base-url="$agentsBackend" />
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

$agentsPolicyBodyPath = Join-Path ([System.IO.Path]::GetTempPath()) 'foundry-agents-gateway-policy.json'
$agentsPolicyBodyJson = @{properties=@{format="rawxml"; value=$agentsPolicyXml}} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($agentsPolicyBodyPath, $agentsPolicyBodyJson, [System.Text.UTF8Encoding]::new($false))
Write-Host "Updating APIM Agents gateway policy"
$agentsPolicyUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName/apis/$agentsApiId/policies/policy?api-version=2024-05-01"
$ErrorActionPreference = 'Continue'
$agentsPolicyResult = az rest --method PUT --headers Content-Type=application/json --url $agentsPolicyUrl --body "@$agentsPolicyBodyPath" 2>&1
$ErrorActionPreference = 'Stop'
$realAgentsError = $agentsPolicyResult | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Where-Object { $_.Exception.Message -match '(BadRequest|Unauthorized|Forbidden|NotFound|Conflict|InternalServerError|\b[45]\d{2}\b)' }
if ($realAgentsError) { throw "Updating APIM policy for agents API '$agentsApiId' failed: $realAgentsError" }

Write-Host "Ensured Foundry Agents API gateway via APIM: $agentsGatewayUrl"