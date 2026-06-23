<#
.SYNOPSIS
    Provision a fully private Azure Function App (Data APIs) for a Foundry agent tool.

.DESCRIPTION
    Reads every value from config/function_app_config.json and config/azure_resources.json
    (no hardcoded resource names). Provisions, in order:

      1. Storage account (for the Function App content + runtime)
      2. App Service plan in East US (reused only if config.hosting_plan.reuse_existing = true)
      3. Linux Python Function App (Functions v4)
      4. Regional VNet integration (appsvc-integration subnet)
      5. Code deployment (zip) of ../function-app
      6. Private endpoints for storage (blob + file) and the Function App, with DNS zone groups
      7. Public network access DISABLED on both storage and the Function App

    Stages run in this order so the code deploys while the SCM site is still reachable,
    BEFORE public access is locked down.

.PARAMETER SkipDeploy
    Provision infrastructure only; do not zip-deploy the function code.

.PARAMETER KeepPublicAccess
    Skip the final lockdown stage (leave public access enabled) for debugging.

.NOTES
    Microsoft Learn references are listed in function-app/README.md.
#>
[CmdletBinding()]
param(
    [switch]$SkipDeploy,
    [switch]$KeepPublicAccess
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

Write-Host '==> Loading configuration' -ForegroundColor Cyan
$cfg = Get-Content .\config\function_app_config.json -Raw | ConvertFrom-Json

$subscriptionId = $cfg.subscription_id
$resourceGroup  = $cfg.resource_group
$location       = $cfg.location

$funcName       = $cfg.function_app.name
$runtime        = $cfg.function_app.runtime
$runtimeVersion = $cfg.function_app.runtime_version
$funcVersion    = $cfg.function_app.functions_extension_version

$planName       = $cfg.hosting_plan.name
$planSku        = $cfg.hosting_plan.sku
$reusePlan      = [bool]$cfg.hosting_plan.reuse_existing
$reusePlanName  = $cfg.hosting_plan.reuse_plan_name

$stName         = $cfg.storage_account.name
$stSku          = $cfg.storage_account.sku
$privateStorage = [bool]$cfg.storage_account.private_storage
$contentOverVnet= [bool]$cfg.storage_account.content_over_vnet

$vnetName       = $cfg.networking.vnet_name
$intSubnet      = $cfg.networking.integration_subnet
$peSubnet       = $cfg.networking.private_endpoint_subnet
$webDnsZone     = $cfg.networking.private_dns_zone
$peName         = $cfg.networking.private_endpoint_name
$zoneGroupName  = $cfg.networking.dns_zone_group_name
$blobDnsZone    = $cfg.storage_account.private_dns_zones.blob
$fileDnsZone    = $cfg.storage_account.private_dns_zones.file

az account set --subscription $subscriptionId | Out-Null

# ---------------------------------------------------------------------------
# Stage 1 - Storage account
# ---------------------------------------------------------------------------
Write-Host "==> Stage 1: storage account '$stName'" -ForegroundColor Cyan
$stExists = az storage account show -g $resourceGroup -n $stName --query id -o tsv 2>$null
if (-not $stExists) {
    az storage account create -g $resourceGroup -n $stName -l $location `
        --sku $stSku --kind $cfg.storage_account.kind `
        --min-tls-version TLS1_2 --allow-blob-public-access false | Out-Null
    Write-Host "    created" -ForegroundColor Green
} else {
    Write-Host "    exists, reusing" -ForegroundColor Yellow
}
$stId = az storage account show -g $resourceGroup -n $stName --query id -o tsv

# ---------------------------------------------------------------------------
# Stage 2 - App Service plan (East US)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 2: hosting plan" -ForegroundColor Cyan
if ($reusePlan -and $reusePlanName) {
    $planResolved = $reusePlanName
    $planLoc = az appservice plan show -g $resourceGroup -n $planResolved --query location -o tsv
    Write-Host "    reusing existing plan '$planResolved' ($planLoc)" -ForegroundColor Yellow
    if ($planLoc -replace '\s','' -ne ($location -replace '\s','')) {
        throw "Reuse plan '$planResolved' is in '$planLoc' but private VNet integration requires '$location'. Set hosting_plan.reuse_existing=false to create a new plan."
    }
} else {
    $planResolved = $planName
    $planExists = az appservice plan show -g $resourceGroup -n $planResolved --query id -o tsv 2>$null
    if (-not $planExists) {
        az appservice plan create -g $resourceGroup -n $planResolved -l $location `
            --sku $planSku --is-linux | Out-Null
        Write-Host "    created Linux plan '$planResolved' ($planSku) in $location" -ForegroundColor Green
    } else {
        Write-Host "    plan '$planResolved' exists, reusing" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Stage 3 - Function App
# ---------------------------------------------------------------------------
Write-Host "==> Stage 3: function app '$funcName'" -ForegroundColor Cyan
$funcExists = az functionapp show -g $resourceGroup -n $funcName --query id -o tsv 2>$null
if (-not $funcExists) {
    az functionapp create -g $resourceGroup -n $funcName `
        --plan $planResolved --storage-account $stName `
        --runtime $runtime --runtime-version $runtimeVersion `
        --functions-version ($funcVersion -replace '~','') `
        --os-type Linux --assign-identity '[system]' | Out-Null
    Write-Host "    created" -ForegroundColor Green
} else {
    Write-Host "    exists, reusing" -ForegroundColor Yellow
}

Write-Host "    applying app settings" -ForegroundColor Gray
$settings = @(
    "FUNCTIONS_EXTENSION_VERSION=$funcVersion",
    "SCM_DO_BUILD_DURING_DEPLOYMENT=true",
    "ENABLE_ORYX_BUILD=true"
)
if ($contentOverVnet) { $settings += "WEBSITE_CONTENTOVERVNET=1" }
az functionapp config appsettings set -g $resourceGroup -n $funcName --settings $settings | Out-Null
az functionapp update -g $resourceGroup -n $funcName --set httpsOnly=true | Out-Null
# Route all outbound app traffic through the VNet so it can reach private storage.
az functionapp config set -g $resourceGroup -n $funcName --vnet-route-all-enabled true | Out-Null

# ---------------------------------------------------------------------------
# Stage 4 - Regional VNet integration
# ---------------------------------------------------------------------------
Write-Host "==> Stage 4: VNet integration ($intSubnet)" -ForegroundColor Cyan
$intSubnetId = az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $intSubnet --query id -o tsv
az functionapp vnet-integration add -g $resourceGroup -n $funcName --vnet $vnetName --subnet $intSubnet | Out-Null
Write-Host "    integrated with $intSubnetId" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Stage 5 - Deploy code (while SCM is still public)
# ---------------------------------------------------------------------------
if (-not $SkipDeploy) {
    Write-Host "==> Stage 5: deploy function code" -ForegroundColor Cyan
    $tempRoot = [System.IO.Path]::GetTempPath()
    $stage = Join-Path $tempRoot "func-data-$(Get-Random)"
    $zipPath = Join-Path $tempRoot "func-data-app.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Copy-Item -Recurse -Force .\function-app $stage
    Get-ChildItem -Recurse -Path $stage -Include __pycache__,*.pyc,local.settings.json -Force |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    # Build a Linux-friendly (POSIX path) zip with Python (python on Windows, python3 on Linux CI).
    $pythonExe = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
    $py = @"
import os, zipfile
stage = r'''$stage'''
out = r'''$zipPath'''
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
    for dp, _, fs in os.walk(stage):
        for f in fs:
            fp = os.path.join(dp, f)
            zf.write(fp, os.path.relpath(fp, stage).replace('\\', '/'))
print(out)
"@
    $py | & $pythonExe -
    az functionapp deployment source config-zip -g $resourceGroup -n $funcName --src $zipPath --build-remote true | Out-Null
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "    deployed $zipPath" -ForegroundColor Green
} else {
    Write-Host "==> Stage 5: skipped (-SkipDeploy)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Stage 6 - Private endpoints
# ---------------------------------------------------------------------------
Write-Host "==> Stage 6: private endpoints" -ForegroundColor Cyan
$peSubnetId = az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $peSubnet --query id -o tsv
$funcId = az functionapp show -g $resourceGroup -n $funcName --query id -o tsv

function New-PrivateEndpoint {
    param($Name, $ResourceId, $GroupId, $DnsZone)
    $exists = az network private-endpoint show -g $resourceGroup -n $Name --query id -o tsv 2>$null
    if (-not $exists) {
        az network private-endpoint create -g $resourceGroup -n $Name -l $location `
            --subnet $peSubnetId --private-connection-resource-id $ResourceId `
            --group-id $GroupId --connection-name "$Name-conn" | Out-Null
        Write-Host "    created PE '$Name' ($GroupId)" -ForegroundColor Green
    } else {
        Write-Host "    PE '$Name' exists" -ForegroundColor Yellow
    }
    $zoneId = az network private-dns zone show -g $resourceGroup -n $DnsZone --query id -o tsv 2>$null
    if (-not $zoneId) {
        az network private-dns zone create -g $resourceGroup -n $DnsZone | Out-Null
        az network private-dns link vnet create -g $resourceGroup -z $DnsZone `
            -n "$($DnsZone -replace '\.','-')-link" --virtual-network $vnetName --registration-enabled false | Out-Null
        $zoneId = az network private-dns zone show -g $resourceGroup -n $DnsZone --query id -o tsv
        Write-Host "    created + linked DNS zone '$DnsZone'" -ForegroundColor Green
    }
    az network private-endpoint dns-zone-group create -g $resourceGroup `
        --endpoint-name $Name -n $zoneGroupName `
        --private-dns-zone $zoneId --zone-name ($DnsZone -replace '\.','-') 2>$null | Out-Null
}

if ($privateStorage) {
    New-PrivateEndpoint -Name "pe-$stName-blob" -ResourceId $stId -GroupId "blob" -DnsZone $blobDnsZone
    New-PrivateEndpoint -Name "pe-$stName-file" -ResourceId $stId -GroupId "file" -DnsZone $fileDnsZone
}
New-PrivateEndpoint -Name $peName -ResourceId $funcId -GroupId "sites" -DnsZone $webDnsZone

# ---------------------------------------------------------------------------
# Stage 7 - Disable public network access
# ---------------------------------------------------------------------------
if (-not $KeepPublicAccess) {
    Write-Host "==> Stage 7: disable public network access" -ForegroundColor Cyan
    if ($privateStorage) {
        az storage account update -g $resourceGroup -n $stName --public-network-access Disabled --default-action Deny | Out-Null
        Write-Host "    storage public access disabled" -ForegroundColor Green
    }
    az resource update --ids $funcId --set properties.publicNetworkAccess=Disabled --api-version 2023-12-01 | Out-Null
    az functionapp config access-restriction set -g $resourceGroup -n $funcName --use-same-restrictions-for-scm-site true 2>$null | Out-Null
    Write-Host "    function app public access disabled" -ForegroundColor Green
} else {
    Write-Host "==> Stage 7: skipped (-KeepPublicAccess)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$hostName = az functionapp show -g $resourceGroup -n $funcName --query defaultHostName -o tsv
Write-Host ""
Write-Host "==> Done. Function App provisioned (private)." -ForegroundColor Cyan
Write-Host "    Function host : https://$hostName"
Write-Host "    Swagger UI    : https://$hostName/api/swagger   (reachable only inside the VNet)"
Write-Host "    OpenAPI       : https://$hostName/api/openapi.json"
Write-Host "    Next          : scripts/configure-function-apim.ps1  then  scripts/create_function_agent.py"
