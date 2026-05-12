$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

param(
    [string]$CostCenterConfigPath = '.\config\cost_center_config.json'
)

function Assert-LastExitCode {
    param(
        [string]$Operation
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path $CostCenterConfigPath)) {
    throw "Cost center config file not found: $CostCenterConfigPath"
}

$config = Get-Content .\config\azure_resources.json | ConvertFrom-Json
$costCenterConfig = Get-Content $CostCenterConfigPath | ConvertFrom-Json

$subscriptionId = $config.subscription_id
$resourceGroup = $config.resource_group
$apimName = ($config.apim.resource_id -split '/')[-1]
$apiId = $config.apim.backend_api_name
$uiUrl = $config.app_services.ui_url
$backendUrl = if ($env:API_BACKEND_URL) { $env:API_BACKEND_URL } else { $config.app_services.api_url }

$taxCostCenter = $costCenterConfig.use_case_cost_centers.tax_pdf_forms
$engCostCenter = $costCenterConfig.use_case_cost_centers.eng_design_ppt
$unknownCostCenter = if ($costCenterConfig.defaults.unknown_cost_center) { $costCenterConfig.defaults.unknown_cost_center } else { '00000' }

if ([string]::IsNullOrWhiteSpace($taxCostCenter) -or [string]::IsNullOrWhiteSpace($engCostCenter)) {
    throw "Both use case cost centers are required in $CostCenterConfigPath"
}

$clientMapPolicyBlocks = @()
foreach ($mapping in $costCenterConfig.client_cost_centers) {
    if ([string]::IsNullOrWhiteSpace($mapping.client_id) -or [string]::IsNullOrWhiteSpace($mapping.cost_center)) {
        continue
    }

    $clientIdEscaped = [System.Security.SecurityElement]::Escape([string]$mapping.client_id)
    $costCenterEscaped = [System.Security.SecurityElement]::Escape([string]$mapping.cost_center)
    $useCaseValue = if ([string]::IsNullOrWhiteSpace($mapping.use_case)) { '' } else { [string]$mapping.use_case }
    $useCaseEscaped = [System.Security.SecurityElement]::Escape($useCaseValue)

    $setUseCase = if ([string]::IsNullOrWhiteSpace($useCaseEscaped)) {
      ''
    }
    else {
      [string]::Format("`n        <set-variable name=""mappedUseCase"" value=""{0}"" />", $useCaseEscaped)
    }

    $clientMapPolicyBlocks += @"
      <when condition="@(((string)context.Variables[&quot;clientId&quot;]).Equals(&quot;$clientIdEscaped&quot;, StringComparison.OrdinalIgnoreCase))">$setUseCase
        <set-variable name="costCenter" value="$costCenterEscaped" />
        <set-variable name="costCenterSource" value="client-mapping" />
      </when>
"@
}

$clientMappingPolicy = if ($clientMapPolicyBlocks.Count -gt 0) {
    ($clientMapPolicyBlocks -join "`n")
}
else {
    ''
}

$policyXml = @"
<policies>
  <inbound>
    <base />
    <cors allow-credentials="false">
      <allowed-origins>
        <origin>$uiUrl</origin>
        <origin>http://localhost:4200</origin>
      </allowed-origins>
      <allowed-methods preflight-result-max-age="300">
        <method>GET</method>
        <method>POST</method>
        <method>OPTIONS</method>
      </allowed-methods>
      <allowed-headers>
        <header>Content-Type</header>
        <header>Accept</header>
        <header>Authorization</header>
        <header>x-client-id</header>
      </allowed-headers>
    </cors>

    <set-variable name="clientId" value="@{
      var explicitClientId = context.Request.Headers.GetValueOrDefault(&quot;x-client-id&quot;, &quot;&quot;);
      if (!string.IsNullOrWhiteSpace(explicitClientId)) {
        return explicitClientId.Trim();
      }

      var auth = context.Request.Headers.GetValueOrDefault(&quot;Authorization&quot;, &quot;&quot;);
      if (!string.IsNullOrWhiteSpace(auth) &amp;&amp; auth.StartsWith(&quot;Bearer &quot;, StringComparison.OrdinalIgnoreCase)) {
        try {
          var token = auth.Substring(7);
          var jwt = token.AsJwt();
          if (jwt != null) {
            if (jwt.Claims.ContainsKey(&quot;appid&quot;) &amp;&amp; !string.IsNullOrWhiteSpace(jwt.Claims[&quot;appid&quot;])) {
              return jwt.Claims[&quot;appid&quot;];
            }
            if (jwt.Claims.ContainsKey(&quot;azp&quot;) &amp;&amp; !string.IsNullOrWhiteSpace(jwt.Claims[&quot;azp&quot;])) {
              return jwt.Claims[&quot;azp&quot;];
            }
          }
        }
        catch {
          // Keep default when token parsing fails.
        }
      }

      return &quot;unknown-client&quot;;
    }" />

    <set-variable name="useCase" value="@{
      var fromQuery = context.Request.Url.Query.GetValueOrDefault(&quot;use_case&quot;, &quot;&quot;);
      if (!string.IsNullOrWhiteSpace(fromQuery)) {
        return fromQuery.Trim().ToLowerInvariant();
      }

      if (context.Request.Body != null) {
        var rawBody = context.Request.Body.As&lt;string&gt;(preserveContent: true);
        if (!string.IsNullOrWhiteSpace(rawBody)) {
          try {
            var body = Newtonsoft.Json.Linq.JObject.Parse(rawBody);
            var fromBody = (string)body[&quot;use_case&quot;];
            if (!string.IsNullOrWhiteSpace(fromBody)) {
              return fromBody.Trim().ToLowerInvariant();
            }
          }
          catch {
            // Keep default when body parsing fails.
          }
        }
      }

      return &quot;unknown_use_case&quot;;
    }" />

    <set-variable name="mappedUseCase" value="@((string)context.Variables[&quot;useCase&quot;])" />
    <set-variable name="costCenter" value="$unknownCostCenter" />
    <set-variable name="costCenterSource" value="default" />

    <choose>
$clientMappingPolicy
      <otherwise>
        <choose>
          <when condition="@(((string)context.Variables[&quot;mappedUseCase&quot;]).Equals(&quot;tax_pdf_forms&quot;, StringComparison.OrdinalIgnoreCase))">
            <set-variable name="costCenter" value="$taxCostCenter" />
            <set-variable name="costCenterSource" value="use-case" />
          </when>
          <when condition="@(((string)context.Variables[&quot;mappedUseCase&quot;]).Equals(&quot;eng_design_ppt&quot;, StringComparison.OrdinalIgnoreCase))">
            <set-variable name="costCenter" value="$engCostCenter" />
            <set-variable name="costCenterSource" value="use-case" />
          </when>
        </choose>
      </otherwise>
    </choose>

    <set-header name="x-client-id" exists-action="override">
      <value>@((string)context.Variables[&quot;clientId&quot;])</value>
    </set-header>
    <set-header name="x-use-case" exists-action="override">
      <value>@((string)context.Variables[&quot;mappedUseCase&quot;])</value>
    </set-header>
    <set-header name="x-cost-center" exists-action="override">
      <value>@((string)context.Variables[&quot;costCenter&quot;])</value>
    </set-header>
    <set-header name="x-cost-center-source" exists-action="override">
      <value>@((string)context.Variables[&quot;costCenterSource&quot;])</value>
    </set-header>

    <set-backend-service base-url="$backendUrl" />
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
    <set-header name="x-cost-center" exists-action="override">
      <value>@((string)context.Variables[&quot;costCenter&quot;])</value>
    </set-header>
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
"@

$policyBodyPath = Join-Path ([System.IO.Path]::GetTempPath()) 'apim-cost-center-policy-body.json'
@{ properties = @{ format = 'rawxml'; value = $policyXml } } | ConvertTo-Json -Depth 8 | Set-Content -Path $policyBodyPath -Encoding UTF8

$policyUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName/apis/$apiId/policies/policy?api-version=2024-05-01"
Write-Host "Applying APIM policy for API '$apiId' in APIM '$apimName'"
$ErrorActionPreference = 'Continue'
$policyResult = az rest --method PUT --headers Content-Type=application/json --url $policyUrl --body "@$policyBodyPath" 2>&1
$ErrorActionPreference = 'Stop'
$httpError = $policyResult | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Where-Object { $_.Exception.Message -match '(BadRequest|Unauthorized|Forbidden|NotFound|Conflict|InternalServerError|\b[45]\d{2}\b)' }
if ($httpError) {
    throw "Updating APIM policy for API '$apiId' failed: $httpError"
}

Write-Host "Applied APIM cost-center policy successfully."
Write-Host "Tax use case => cost center '$taxCostCenter'"
Write-Host "Engineering use case => cost center '$engCostCenter'"
