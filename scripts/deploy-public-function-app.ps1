<#
.SYNOPSIS
    Provision a PUBLICLY accessible Azure Function App (Data APIs + Swagger UI),
    sharing the existing dedicated B1 Linux App Service plan with the private edition.

.DESCRIPTION
    Reads every value from config/public_function_app_config.json (no hardcoded
    resource names). Provisions, in order:

      1. Storage account (own account; managed-identity auth, no shared keys)
      2. Reuse the existing dedicated App Service plan (East US)
      3. Linux Python Function App (Functions v4) with a system-assigned identity
      4. Grant the app's managed identity data-plane roles on the storage account and
         switch AzureWebJobsStorage to managed-identity auth
      5. Deploy the code (zip, remote build) from ../function-app-public

    Public network access is intentionally LEFT ENABLED so the APIs and the Swagger UI
    are reachable from the internet.

.PARAMETER SkipDeploy
    Provision infrastructure only; do not zip-deploy the function code.

.NOTES
    The shared plan is dedicated (B1), which supports multiple apps. Flex Consumption
    (FC1) plans, by contrast, host exactly one app and cannot be shared.
#>
[CmdletBinding()]
param(
    [switch]$SkipDeploy
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

# Safe resource-existence probe (Windows PowerShell 5.1 turns native-command stderr
# into a terminating error under ErrorActionPreference='Stop'; pwsh on Linux does not).
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

# Run a mutating az command that may print warnings to stderr. Tolerates stderr,
# throws only on a non-zero exit code.
function Invoke-AzWrite {
    param([Parameter(Mandatory)][scriptblock]$Cmd, [string]$What = 'az command')
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Cmd 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
    } finally { $ErrorActionPreference = $prev }
}

Write-Host '==> Loading configuration' -ForegroundColor Cyan
$cfg = Get-Content .\config\public_function_app_config.json -Raw | ConvertFrom-Json

$subscriptionId = $cfg.subscription_id
$resourceGroup  = $cfg.resource_group
$location       = $cfg.location

$funcName       = $cfg.function_app.name
$runtime        = $cfg.function_app.runtime
$runtimeVersion = $cfg.function_app.runtime_version
$funcVersion    = $cfg.function_app.functions_extension_version

$planName       = $cfg.hosting_plan.name

$stName         = $cfg.storage_account.name
$stSku          = $cfg.storage_account.sku
$stKind         = $cfg.storage_account.kind
$dataRoles      = $cfg.storage_account.data_plane_roles

az account set --subscription $subscriptionId | Out-Null

# ---------------------------------------------------------------------------
# Stage 1 - Storage account (managed-identity auth, no shared keys)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 1: storage account '$stName'" -ForegroundColor Cyan
$stExists = Invoke-AzProbe { az storage account show -g $resourceGroup -n $stName --query id -o tsv }
if (-not $stExists) {
    Invoke-AzWrite { az storage account create -g $resourceGroup -n $stName -l $location `
        --sku $stSku --kind $stKind --min-tls-version TLS1_2 --allow-blob-public-access false } 'storage create'
    Write-Host "    created" -ForegroundColor Green
} else {
    Write-Host "    exists, reusing" -ForegroundColor Yellow
}
$stId = az storage account show -g $resourceGroup -n $stName --query id -o tsv

# ---------------------------------------------------------------------------
# Stage 2 - Reuse the existing dedicated App Service plan (East US)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 2: hosting plan '$planName'" -ForegroundColor Cyan
$planLoc = az appservice plan show -g $resourceGroup -n $planName --query location -o tsv
if (-not $planLoc) { throw "Plan '$planName' not found in '$resourceGroup'." }
Write-Host "    reusing existing plan '$planName' ($planLoc)" -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# Stage 3 - Function App (system-assigned identity)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 3: function app '$funcName'" -ForegroundColor Cyan
$funcExists = Invoke-AzProbe { az functionapp show -g $resourceGroup -n $funcName --query id -o tsv }
if (-not $funcExists) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    az functionapp create -g $resourceGroup -n $funcName `
        --plan $planName --storage-account $stName `
        --runtime $runtime --runtime-version $runtimeVersion `
        --functions-version ($funcVersion -replace '~','') `
        --os-type Linux --assign-identity '[system]' 2>&1 | Out-Null
    $createExit = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($createExit -ne 0) { throw "az functionapp create failed (exit $createExit)" }
    Write-Host "    created" -ForegroundColor Green
} else {
    Write-Host "    exists, reusing" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Stage 4 - Managed-identity storage auth + roles
# ---------------------------------------------------------------------------
Write-Host "==> Stage 4: managed-identity storage auth" -ForegroundColor Cyan
$principalId = az functionapp show -g $resourceGroup -n $funcName --query identity.principalId -o tsv
Write-Host "    app identity principalId = $principalId" -ForegroundColor Gray
foreach ($role in $dataRoles) {
    $assigned = Invoke-AzProbe { az role assignment list --assignee $principalId --scope $stId --role $role --query "[0].id" -o tsv }
    if (-not $assigned) {
        Invoke-AzWrite { az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role $role --scope $stId } "role '$role'"
        Write-Host "    granted '$role'" -ForegroundColor Green
    } else {
        Write-Host "    '$role' already granted" -ForegroundColor Yellow
    }
}

Write-Host "    applying app settings (managed-identity AzureWebJobsStorage)" -ForegroundColor Gray
$settings = @(
    "FUNCTIONS_EXTENSION_VERSION=$funcVersion",
    "FUNCTIONS_WORKER_RUNTIME=$runtime",
    "SCM_DO_BUILD_DURING_DEPLOYMENT=true",
    "ENABLE_ORYX_BUILD=true",
    "AzureWebJobsStorage__accountName=$stName",
    "AzureWebJobsStorage__credential=managedidentity"
)
Invoke-AzWrite { az functionapp config appsettings set -g $resourceGroup -n $funcName --settings $settings } 'appsettings set'
# Remove the key-based connection string that create added so the host uses the MI.
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
az functionapp config appsettings delete -g $resourceGroup -n $funcName --setting-names AzureWebJobsStorage 2>&1 | Out-Null
$ErrorActionPreference = $prev
Invoke-AzWrite { az functionapp update -g $resourceGroup -n $funcName --set httpsOnly=true } 'httpsOnly'
# Make sure public access stays enabled (this is the public edition).
Invoke-AzWrite { az resource update --ids (az functionapp show -g $resourceGroup -n $funcName --query id -o tsv) --set properties.publicNetworkAccess=Enabled --api-version 2023-12-01 } 'public access enable'

# ---------------------------------------------------------------------------
# Stage 5 - Deploy code
# ---------------------------------------------------------------------------
if (-not $SkipDeploy) {
    Write-Host "==> Stage 5: deploy function code" -ForegroundColor Cyan
    $tempRoot = [System.IO.Path]::GetTempPath()
    $stage = Join-Path $tempRoot "func-public-$(Get-Random)"
    $zipPath = Join-Path $tempRoot "func-public-app.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Copy-Item -Recurse -Force .\function-app-public $stage
    Get-ChildItem -Recurse -Path $stage -Include __pycache__,*.pyc,local.settings.json -Force |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
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
    Invoke-AzWrite { az functionapp deployment source config-zip -g $resourceGroup -n $funcName --src $zipPath --build-remote true } 'zip deploy'
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "    deployed $zipPath" -ForegroundColor Green
} else {
    Write-Host "==> Stage 5: skipped (-SkipDeploy)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$hostName = az functionapp show -g $resourceGroup -n $funcName --query defaultHostName -o tsv
Write-Host ""
Write-Host "==> Done. Public Function App provisioned." -ForegroundColor Cyan
Write-Host "    Function host : https://$hostName"
Write-Host "    Swagger UI    : https://$hostName/api/swagger"
Write-Host "    OpenAPI       : https://$hostName/api/openapi.json"
Write-Host "    Health        : https://$hostName/api/health"
