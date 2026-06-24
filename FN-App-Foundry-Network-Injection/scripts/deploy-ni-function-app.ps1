<#
.SYNOPSIS
    Provision a fully private Azure Function App (Data APIs) in a NEW eastus2 VNet for
    consumption by an Azure AI Foundry agent over virtual network injection.

.DESCRIPTION
    Reads every value from config/network_injection_config.json (no hardcoded names).
    Provisions, in order:

      1. eastus2 VNet + subnets (private-endpoints, appsvc-integration, agents-injection /27)
      2. Storage account (Function App content + runtime)
      3. App Service plan in eastus2
      4. Linux Python Function App (Functions v4) with regional VNet integration
      5. Code deployment (zip) of ./function-app  (while SCM is still reachable)
      6. Private endpoints for storage (blob + file) and the Function App + DNS zone groups
      7. Public network access DISABLED on storage and the Function App (no selected networks)

    The agents-injection subnet (delegated Microsoft.App/environments) is created here so the
    companion script scripts/configure-foundry-network-injection.ps1 can point the Foundry
    account's network injection at it.

.PARAMETER SkipDeploy
    Provision infrastructure only; do not zip-deploy the function code.

.PARAMETER KeepPublicAccess
    Skip the final lockdown stage (leave public access enabled) for debugging.

.NOTES
    Microsoft Learn references are listed in the folder README.md.
#>
[CmdletBinding()]
param(
    [switch]$SkipDeploy,
    [switch]$KeepPublicAccess
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

# Safe resource-existence probe (Windows PS 5.1 turns native stderr into a terminating
# error under ErrorActionPreference='Stop'; pwsh on Linux does not).
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
$cfg = Get-Content .\config\network_injection_config.json -Raw | ConvertFrom-Json

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
$hostingModel   = if ($cfg.hosting_plan.model) { $cfg.hosting_plan.model } else { 'dedicated' }
$flexMemory     = $cfg.hosting_plan.flex_instance_memory_mb
$flexMaxInst    = $cfg.hosting_plan.flex_max_instance_count
$isFlex         = ($hostingModel -eq 'flexconsumption')

$stName         = $cfg.storage_account.name
$stSku          = $cfg.storage_account.sku
$privateStorage = [bool]$cfg.storage_account.private_storage
$contentOverVnet= [bool]$cfg.storage_account.content_over_vnet
$allowSharedKey = if ($null -ne $cfg.storage_account.allow_shared_key_access) { [bool]$cfg.storage_account.allow_shared_key_access } else { $true }
$deployIdName   = if ($cfg.storage_account.deployment_identity_name) { $cfg.storage_account.deployment_identity_name } else { "id-$funcName" }

$net            = $cfg.networking
$vnetName       = $net.vnet_name
$vnetPrefix     = $net.vnet_address_prefix
$intSubnet      = $net.integration_subnet
$intSubnetPfx   = $net.integration_subnet_prefix
$intDelegation  = if ($net.integration_subnet_delegation) { $net.integration_subnet_delegation } else { 'Microsoft.Web/serverFarms' }
$peSubnet       = $net.private_endpoint_subnet
$peSubnetPfx    = $net.private_endpoint_subnet_prefix
$agentSubnet    = $net.agents_injection_subnet
$agentSubnetPfx = $net.agents_injection_subnet_prefix
$agentDelegation= $net.agents_injection_delegation
$webDnsZone     = $net.private_dns_zone
$peName         = $net.private_endpoint_name
$zoneGroupName  = $net.dns_zone_group_name
$stSubresources = $cfg.storage_account.private_endpoint_subresources
$stDnsZones     = $cfg.storage_account.private_dns_zones

az account set --subscription $subscriptionId | Out-Null

# ---------------------------------------------------------------------------
# Stage 0 - eastus2 VNet + subnets (PE, integration, agents-injection)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 0: VNet '$vnetName' ($location)" -ForegroundColor Cyan
$vnetExists = Invoke-AzProbe { az network vnet show -g $resourceGroup -n $vnetName --query id -o tsv }
if (-not $vnetExists) {
    Invoke-AzWrite { az network vnet create -g $resourceGroup -n $vnetName -l $location --address-prefixes $vnetPrefix } "VNet $vnetName create"
    Write-Host "    created VNet ($vnetPrefix)" -ForegroundColor Green
} else {
    Write-Host "    exists, reusing" -ForegroundColor Yellow
}

function New-Subnet {
    param($Name, $Prefix, $Delegation, [switch]$DisablePePolicies)
    $exists = Invoke-AzProbe { az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $Name --query id -o tsv }
    if (-not $exists) {
        $azArgs = @('network','vnet','subnet','create','-g',$resourceGroup,'--vnet-name',$vnetName,'-n',$Name,'--address-prefixes',$Prefix)
        if ($Delegation) { $azArgs += @('--delegations',$Delegation) }
        if ($DisablePePolicies) { $azArgs += @('--private-endpoint-network-policies','Disabled') }
        Invoke-AzWrite { az @azArgs } "subnet $Name create"
        Write-Host "    created subnet '$Name' ($Prefix)$(if($Delegation){" deleg=$Delegation"})" -ForegroundColor Green
    } else {
        # Reconcile delegation on an existing subnet (e.g. created earlier with a different value).
        if ($Delegation) {
            $current = Invoke-AzProbe { az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $Name --query "delegations[0].serviceName" -o tsv }
            if ($current -ne $Delegation) {
                Invoke-AzWrite { az network vnet subnet update -g $resourceGroup --vnet-name $vnetName -n $Name --delegations $Delegation } "subnet $Name delegation"
                Write-Host "    subnet '$Name' delegation set to $Delegation (was '$current')" -ForegroundColor Green
            } else {
                Write-Host "    subnet '$Name' exists (deleg=$Delegation)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "    subnet '$Name' exists" -ForegroundColor Yellow
        }
    }
}

New-Subnet -Name $peSubnet    -Prefix $peSubnetPfx    -DisablePePolicies
New-Subnet -Name $intSubnet   -Prefix $intSubnetPfx   -Delegation $intDelegation
New-Subnet -Name $agentSubnet -Prefix $agentSubnetPfx -Delegation $agentDelegation

# ---------------------------------------------------------------------------
# Stage 1 - Storage account
# ---------------------------------------------------------------------------
Write-Host "==> Stage 1: storage account '$stName'" -ForegroundColor Cyan
$stExists = Invoke-AzProbe { az storage account show -g $resourceGroup -n $stName --query id -o tsv }
if (-not $stExists) {
    Invoke-AzWrite { az storage account create -g $resourceGroup -n $stName -l $location --sku $stSku --kind $cfg.storage_account.kind --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access $allowSharedKey.ToString().ToLower() } "storage create"
    Write-Host "    created (allowSharedKeyAccess=$($allowSharedKey.ToString().ToLower()))" -ForegroundColor Green
} else {
    Write-Host "    exists, reusing" -ForegroundColor Yellow
}
$stId = az storage account show -g $resourceGroup -n $stName --query id -o tsv

# ---------------------------------------------------------------------------
# Stage 1b - User-assigned managed identity for identity-based storage (Flex)
#   Azure Policy disables shared-key access on storage in this subscription, so the
#   Function App must reach BOTH its runtime storage and its deployment-storage
#   container with a managed identity. A user-assigned identity is used (vs system)
#   because it persists across app re-creates, making the deploy reproducible.
# ---------------------------------------------------------------------------
$uamiId = $null; $uamiClientId = $null; $uamiPrincipalId = $null
if ($isFlex) {
    Write-Host "==> Stage 1b: deployment identity '$deployIdName'" -ForegroundColor Cyan
    $uamiId = Invoke-AzProbe { az identity show -g $resourceGroup -n $deployIdName --query id -o tsv }
    if (-not $uamiId) {
        Invoke-AzWrite { az identity create -g $resourceGroup -n $deployIdName -l $location } "identity create"
        Write-Host "    created UAMI '$deployIdName'" -ForegroundColor Green
    } else {
        Write-Host "    UAMI '$deployIdName' exists, reusing" -ForegroundColor Yellow
    }
    $uamiId          = az identity show -g $resourceGroup -n $deployIdName --query id -o tsv
    $uamiClientId    = az identity show -g $resourceGroup -n $deployIdName --query clientId -o tsv
    $uamiPrincipalId = az identity show -g $resourceGroup -n $deployIdName --query principalId -o tsv
    foreach ($role in 'Storage Blob Data Owner','Storage Queue Data Contributor','Storage Table Data Contributor') {
        $have = Invoke-AzProbe { az role assignment list --assignee $uamiPrincipalId --scope $stId --role $role --query "[0].id" -o tsv }
        if (-not $have) {
            Invoke-AzWrite { az role assignment create --assignee-object-id $uamiPrincipalId --assignee-principal-type ServicePrincipal --role $role --scope $stId } "role $role"
            Write-Host "    granted '$role' to UAMI on storage" -ForegroundColor Green
        } else {
            Write-Host "    UAMI already has '$role'" -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------------------
# Stage 2 - App Service plan (eastus2)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 2: hosting plan" -ForegroundColor Cyan
if ($isFlex) {
    Write-Host "    model=flexconsumption: no App Service plan needed (serverless, no dedicated VM quota)" -ForegroundColor Yellow
}
elseif ($reusePlan -and $reusePlanName) {
    $planResolved = $reusePlanName
    $planLoc = az appservice plan show -g $resourceGroup -n $planResolved --query location -o tsv
    Write-Host "    reusing existing plan '$planResolved' ($planLoc)" -ForegroundColor Yellow
    if ($planLoc -replace '\s','' -ne ($location -replace '\s','')) {
        throw "Reuse plan '$planResolved' is in '$planLoc' but VNet integration requires '$location'. Set hosting_plan.reuse_existing=false."
    }
} else {
    $planResolved = $planName
    $planExists = Invoke-AzProbe { az appservice plan show -g $resourceGroup -n $planResolved --query id -o tsv }
    if (-not $planExists) {
        Invoke-AzWrite { az appservice plan create -g $resourceGroup -n $planResolved -l $location --sku $planSku --is-linux } "plan create"
        Write-Host "    created Linux plan '$planResolved' ($planSku) in $location" -ForegroundColor Green
    } else {
        Write-Host "    plan '$planResolved' exists, reusing" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Stage 3 - Function App (VNet-integrated at create time)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 3: function app '$funcName'" -ForegroundColor Cyan
$funcExists = Invoke-AzProbe { az functionapp show -g $resourceGroup -n $funcName --query id -o tsv }
if (-not $funcExists) {
    $intSubnetId = az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $intSubnet --query id -o tsv
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if ($isFlex) {
        az functionapp create -g $resourceGroup -n $funcName `
            --flexconsumption-location $location --storage-account $stName `
            --runtime $runtime --runtime-version $runtimeVersion `
            --instance-memory $flexMemory --maximum-instance-count $flexMaxInst `
            --vnet $intSubnetId --subnet $intSubnet `
            --assign-identity $uamiId `
            --deployment-storage-auth-type UserAssignedIdentity `
            --deployment-storage-auth-value $uamiId 2>&1 | Out-Null
    } else {
        az functionapp create -g $resourceGroup -n $funcName `
            --plan $planResolved --storage-account $stName `
            --runtime $runtime --runtime-version $runtimeVersion `
            --functions-version ($funcVersion -replace '~','') `
            --os-type Linux --assign-identity '[system]' `
            --subnet $intSubnetId 2>&1 | Out-Null
    }
    $createExit = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($createExit -ne 0) { throw "az functionapp create failed (exit $createExit)" }
    Write-Host "    created$(if($isFlex){' (Flex Consumption)'}else{" (VNet-integrated with $intSubnet)"})" -ForegroundColor Green
} else {
    Write-Host "    exists, reusing" -ForegroundColor Yellow
}

Write-Host "    applying app settings" -ForegroundColor Gray
if ($isFlex) {
    # Flex Consumption: runtime version + remote build are managed by the platform;
    # legacy FUNCTIONS_EXTENSION_VERSION / SCM_DO_BUILD / WEBSITE_CONTENTOVERVNET do not apply.
    # Storage is identity-based (shared key disabled): point AzureWebJobsStorage at the UAMI
    # and remove any key-based connection strings the platform may have added at create time.
    $idSettings = @(
        "AzureWebJobsStorage__accountName=$stName",
        "AzureWebJobsStorage__credential=managedidentity",
        "AzureWebJobsStorage__clientId=$uamiClientId",
        "AzureWebJobsStorage__blobServiceUri=https://$stName.blob.core.windows.net",
        "AzureWebJobsStorage__queueServiceUri=https://$stName.queue.core.windows.net",
        "AzureWebJobsStorage__tableServiceUri=https://$stName.table.core.windows.net"
    )
    az functionapp config appsettings set -g $resourceGroup -n $funcName --settings $idSettings | Out-Null
    foreach ($s in 'AzureWebJobsStorage','DEPLOYMENT_STORAGE_CONNECTION_STRING') {
        az functionapp config appsettings delete -g $resourceGroup -n $funcName --setting-names $s 2>&1 | Out-Null
    }
    az functionapp update -g $resourceGroup -n $funcName --set httpsOnly=true | Out-Null
    az functionapp restart -g $resourceGroup -n $funcName 2>&1 | Out-Null
} else {
    $settings = @(
        "FUNCTIONS_EXTENSION_VERSION=$funcVersion",
        "SCM_DO_BUILD_DURING_DEPLOYMENT=true",
        "ENABLE_ORYX_BUILD=true"
    )
    if ($contentOverVnet) { $settings += "WEBSITE_CONTENTOVERVNET=1" }
    az functionapp config appsettings set -g $resourceGroup -n $funcName --settings $settings | Out-Null
    az functionapp update -g $resourceGroup -n $funcName --set httpsOnly=true | Out-Null
    az functionapp config set -g $resourceGroup -n $funcName --vnet-route-all-enabled true | Out-Null
}

# ---------------------------------------------------------------------------
# Stage 4 - Regional VNet integration (idempotent)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 4: VNet integration ($intSubnet)" -ForegroundColor Cyan
$intSubnetId = az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $intSubnet --query id -o tsv
$currentVnet = Invoke-AzProbe { az functionapp show -g $resourceGroup -n $funcName --query virtualNetworkSubnetId -o tsv }
if ($currentVnet -and ($currentVnet -replace '\s','' -eq ($intSubnetId -replace '\s',''))) {
    Write-Host "    already integrated with $intSubnet" -ForegroundColor Yellow
} else {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    az functionapp vnet-integration add -g $resourceGroup -n $funcName --vnet $vnetName --subnet $intSubnet 2>&1 | Out-Null
    $vnetExit = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($vnetExit -ne 0) { throw "az functionapp vnet-integration add failed (exit $vnetExit)" }
    Write-Host "    integrated with $intSubnetId" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Stage 5 - Deploy code (while SCM is still public)
# ---------------------------------------------------------------------------
if (-not $SkipDeploy) {
    Write-Host "==> Stage 5: deploy function code" -ForegroundColor Cyan
    $funcPublic = Invoke-AzProbe { az functionapp show -g $resourceGroup -n $funcName --query publicNetworkAccess -o tsv }
    if ($funcPublic -eq 'Disabled') {
        Write-Host "    SKIPPED: '$funcName' has publicNetworkAccess=Disabled; its SCM endpoint is private." -ForegroundColor Yellow
        Write-Host "    Deploy code from a host inside $vnetName (self-hosted runner / jump box) or" -ForegroundColor Yellow
        Write-Host "    temporarily re-enable public access, push, then disable again." -ForegroundColor Yellow
    } else {
        $tempRoot = [System.IO.Path]::GetTempPath()
        $stage = Join-Path $tempRoot "func-data-ni-$(Get-Random)"
        $zipPath = Join-Path $tempRoot "func-data-ni-app.zip"
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Copy-Item -Recurse -Force .\function-app $stage
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
        # Python remote build via Oryx applies to both Flex and dedicated (per Functions docs).
        # NOTE: on Flex Consumption, `config-zip` returns a non-zero exit code even on SUCCESS
        # (a false-fail on the post-deploy health probe). Do not gate on the exit code — inspect
        # the response text and then verify the functions are registered.
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $deployOut = az functionapp deployment source config-zip -g $resourceGroup -n $funcName --src $zipPath --build-remote true 2>&1 | Out-String
        $ErrorActionPreference = $prevEap
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        if ($deployOut -match 'Deployment was successful' -or $deployOut -match 'Deployment successful') {
            Write-Host "    deployed $zipPath (Flex config-zip success)" -ForegroundColor Green
        } else {
            Start-Sleep -Seconds 5
            $fnCount = Invoke-AzProbe { az functionapp function list -g $resourceGroup -n $funcName --query "length(@)" -o tsv }
            if ($fnCount -and [int]$fnCount -gt 0) {
                Write-Host "    deployed $zipPath ($fnCount functions registered)" -ForegroundColor Green
            } else {
                Write-Host $deployOut
                throw "zip deploy did not report success and no functions are registered"
            }
        }
    }
} else {
    Write-Host "==> Stage 5: skipped (-SkipDeploy)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Stage 6 - Private endpoints + private DNS zones
# ---------------------------------------------------------------------------
Write-Host "==> Stage 6: private endpoints" -ForegroundColor Cyan
$peSubnetId = az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $peSubnet --query id -o tsv
$funcId = az functionapp show -g $resourceGroup -n $funcName --query id -o tsv

function New-PrivateEndpoint {
    param($Name, $ResourceId, $GroupId, $DnsZone)
    $exists = Invoke-AzProbe { az network private-endpoint show -g $resourceGroup -n $Name --query id -o tsv }
    if (-not $exists) {
        Invoke-AzWrite { az network private-endpoint create -g $resourceGroup -n $Name -l $location --subnet $peSubnetId --private-connection-resource-id $ResourceId --group-id $GroupId --connection-name "$Name-conn" } "PE $Name create"
        Write-Host "    created PE '$Name' ($GroupId)" -ForegroundColor Green
    } else {
        Write-Host "    PE '$Name' exists" -ForegroundColor Yellow
    }
    $zoneId = Invoke-AzProbe { az network private-dns zone show -g $resourceGroup -n $DnsZone --query id -o tsv }
    if (-not $zoneId) {
        Invoke-AzWrite { az network private-dns zone create -g $resourceGroup -n $DnsZone } "DNS zone $DnsZone create"
    }
    $linkName = ($DnsZone -replace '\.','-') + '-ni-link'
    $linkExists = Invoke-AzProbe { az network private-dns link vnet show -g $resourceGroup -z $DnsZone -n $linkName --query id -o tsv }
    if (-not $linkExists) {
        Invoke-AzWrite { az network private-dns link vnet create -g $resourceGroup -z $DnsZone -n $linkName --virtual-network $vnetName --registration-enabled false } "DNS link $DnsZone"
    }
    $zoneId = az network private-dns zone show -g $resourceGroup -n $DnsZone --query id -o tsv
    $zgExists = Invoke-AzProbe { az network private-endpoint dns-zone-group show -g $resourceGroup --endpoint-name $Name -n $zoneGroupName --query id -o tsv }
    if (-not $zgExists) {
        Invoke-AzWrite { az network private-endpoint dns-zone-group create -g $resourceGroup --endpoint-name $Name -n $zoneGroupName --private-dns-zone $zoneId --zone-name ($DnsZone -replace '\.','-') } "dns-zone-group $Name"
    }
}

if ($privateStorage) {
    foreach ($sub in $stSubresources) {
        $zone = $stDnsZones.$sub
        New-PrivateEndpoint -Name "pe-$stName-$sub" -ResourceId $stId -GroupId $sub -DnsZone $zone
    }
}
New-PrivateEndpoint -Name $peName -ResourceId $funcId -GroupId "sites" -DnsZone $webDnsZone

# ---------------------------------------------------------------------------
# Stage 7 - Disable public network access (no selected networks)
# ---------------------------------------------------------------------------
if (-not $KeepPublicAccess) {
    Write-Host "==> Stage 7: disable public network access" -ForegroundColor Cyan
    if ($privateStorage) {
        Invoke-AzWrite { az storage account update -g $resourceGroup -n $stName --public-network-access Disabled --default-action Deny } 'storage lockdown'
        Write-Host "    storage public access disabled" -ForegroundColor Green
    }
    Invoke-AzWrite { az resource update --ids $funcId --set properties.publicNetworkAccess=Disabled --api-version 2023-12-01 } 'function public access disable'
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    az functionapp config access-restriction set -g $resourceGroup -n $funcName --use-same-restrictions-for-scm-site true 2>&1 | Out-Null
    $ErrorActionPreference = $prevEap
    Write-Host "    function app public access disabled (no selected networks)" -ForegroundColor Green
} else {
    Write-Host "==> Stage 7: skipped (-KeepPublicAccess)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$hostName = az functionapp show -g $resourceGroup -n $funcName --query defaultHostName -o tsv
Write-Host ""
Write-Host "==> Done. Private Function App provisioned in $location." -ForegroundColor Cyan
Write-Host "    Function host : https://$hostName"
Write-Host "    API base      : https://$hostName/api   (reachable only inside $vnetName)"
Write-Host "    Agent subnet  : $agentSubnet ($agentSubnetPfx, deleg $agentDelegation)"
Write-Host "    Next          : scripts/configure-foundry-network-injection.ps1  then  scripts/create_ni_function_agent.py"
