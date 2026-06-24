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

# Run a mutating az command that may print warnings to stderr (which would abort the
# script under ErrorActionPreference='Stop'). Tolerates stderr, throws only on a
# non-zero exit code.
function Invoke-AzWrite {
    param([Parameter(Mandatory)][scriptblock]$Cmd, [string]$What = 'az command')
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Cmd 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
    } finally { $ErrorActionPreference = $prev }
}

# Probe that returns output or $null without throwing on a "not found" stderr write.
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
Invoke-AzWrite { az apim api import --resource-group $resourceGroup --service-name $apimName --path $apiPath --api-id $apiId --display-name $apiDisplay --specification-format OpenApiJson --specification-path $apiSpec --service-url $backendUrl } 'apim api import'

Invoke-AzWrite { az apim api update --resource-group $resourceGroup --service-name $apimName --api-id $apiId --subscription-required $subRequired.ToString().ToLower() } 'apim api update'

Write-Host "==> Applying API policy (backend rewrite + CORS + managed-identity auth)" -ForegroundColor Cyan

# Build the inbound auth block from config. When entra_auth is enabled the API requires
# a valid Entra ID token (validate-azure-ad-token) for any request that carries an
# Authorization header (the Foundry agent's managed identity), and falls back to an
# ip-filter allowlist for dev hosts that call without a token. Disabling entra_auth
# reverts to ip-filter only.
$entra = $cfg.apim.entra_auth
$ranges = $cfg.apim.ip_allowlist.ranges
$ipFilterXml = "<ip-filter action=`"allow`">`n" + (
    ($ranges | ForEach-Object { "          <address-range from=`"$($_.from)`" to=`"$($_.to)`" />" }) -join "`n"
) + "`n        </ip-filter>"

if ($entra -and $entra.enabled) {
    $oidValues = @($entra.allowed_object_ids.PSObject.Properties.Value | ForEach-Object { "              <value>$_</value>" }) -join "`n"
    $authBlock = @"
<choose>
          <when condition="@(context.Request.Headers.ContainsKey(&quot;Authorization&quot;))">
            <validate-azure-ad-token tenant-id="$($entra.tenant_id)" header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Invalid or missing Entra ID token.">
              <audiences>
                <audience>$($entra.audience)</audience>
                <audience>$($entra.app_client_id)</audience>
              </audiences>
              <required-claims>
                <claim name="oid" match="any">
$oidValues
                </claim>
              </required-claims>
            </validate-azure-ad-token>
          </when>
          <otherwise>
            $ipFilterXml
          </otherwise>
        </choose>
"@
} else {
    $authBlock = $ipFilterXml
}

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
    $authBlock
    <set-backend-service base-url="$backendUrl" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
"@

# Write the request body WITHOUT a BOM: az reads it as utf-8 and a BOM breaks it.
$policyBodyPath = Join-Path ([System.IO.Path]::GetTempPath()) 'func-apim-policy.json'
$policyJson = @{ properties = @{ format = 'xml'; value = $policyXml } } | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($policyBodyPath, $policyJson, (New-Object System.Text.UTF8Encoding($false)))
# az rest prints the response body to stdout; on Windows that crashes on the BOM in
# the returned policy XML (cp1252 codec). Route the response to a file with --output-file.
$policyRespPath = Join-Path ([System.IO.Path]::GetTempPath()) 'func-apim-policy-resp.json'
Invoke-AzWrite { az rest --method PUT --url "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName/apis/$apiId/policies/policy?api-version=2024-05-01" --body "@$policyBodyPath" --output-file $policyRespPath } 'apim api policy PUT'
Remove-Item $policyBodyPath, $policyRespPath -Force -ErrorAction SilentlyContinue

$existingProduct = Invoke-AzProbe { az apim product show --resource-group $resourceGroup --service-name $apimName --product-id $productId --query id -o tsv }
if ($existingProduct) {
    Write-Host "==> Adding API to product '$productId'" -ForegroundColor Cyan
    Invoke-AzWrite { az apim product api add --resource-group $resourceGroup --service-name $apimName --product-id $productId --api-id $apiId } 'apim product api add'
}

$gateway = $res.apim.gateway_url.TrimEnd('/')
Write-Host ""
Write-Host "==> Done. API available through APIM:" -ForegroundColor Cyan
Write-Host "    APIM base    : $gateway/$apiPath/api"
Write-Host "    APIM OpenAPI : $gateway/$apiPath/api/openapi.json"
Write-Host "    (Reachable only from inside the VNet - APIM public access is disabled.)"
