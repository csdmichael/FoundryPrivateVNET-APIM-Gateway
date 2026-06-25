<#
.SYNOPSIS
    Force a FULL redeploy of the injected agent managed network (data proxy) so it re-reads
    the current private DNS for the Function App's private endpoint.

.DESCRIPTION
    Symptom this targets: the network-injection agent's OpenAPI / Azure Functions tool call
    returns "HTTP 403 Ip Forbidden" with a rotating PUBLIC x-ms-forbidden-ip, meaning the
    single-tenant data proxy in the agents-injection subnet resolved the Function App hostname
    to its PUBLIC IP and egressed to the public front door (blocked once public access is
    disabled) instead of the private endpoint at 10.50.2.10.

    Recreating ONLY the PROJECT capability host (recreate-ni-project-caphost.ps1) does NOT fix
    this, because the managed agent ENVIRONMENT / outbound network is provisioned by the
    ACCOUNT capability host. Per the Foundry docs ("Changing or updating outbound networking...
    you must redeploy Foundry to add outbound networking"), the managed network only re-reads
    private DNS when the ACCOUNT capability host is rebuilt.

    Capability hosts are immutable and the project caphost depends on the account caphost, so
    this script performs, in order, idempotently:

      1. DELETE project capability host   (poll until 404)
      2. DELETE account capability host   (poll until 404)
      3. Re-assert the network injection PATCH (agent -> agents-injection subnet)
      4. CREATE account capability host   (poll until Succeeded)
      5. CREATE project capability host   (same BYO connections; poll until Succeeded)

    All names / connections / ids come from config/network_injection_config.json (no hardcoding).

    WARNING: this tears down and rebuilds the WHOLE injected agent environment for the account
    and project. Existing agents/threads are removed; re-run create_ni_function_agent.py after.
    Each caphost create is long-running (minutes). Total run can take 15-40 min.

.PARAMETER WhatIf
    Show the actions without deleting / recreating anything.

.PARAMETER SkipInjectionReassert
    Skip stage 3 (do not re-PATCH networkInjections); useful if the injection is already correct
    and you only want the caphost rebuild.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipInjectionReassert
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

# ---------------------------------------------------------------------------
# Load configuration (no hardcoding)
# ---------------------------------------------------------------------------
Write-Host '==> Loading configuration' -ForegroundColor Cyan
$cfg = Get-Content .\config\network_injection_config.json -Raw | ConvertFrom-Json

$subscriptionId = $cfg.subscription_id
$resourceGroup  = $cfg.resource_group

$net            = $cfg.networking
$vnetName       = $net.vnet_name
$agentSubnet    = $net.agents_injection_subnet

$fdry           = $cfg.foundry
$accountId      = $fdry.account_resource_id
$projectName    = $fdry.project_name
$apiVersion     = $fdry.account_api_version
$niScenario     = $fdry.network_injection.scenario
$niManaged      = [bool]$fdry.network_injection.use_microsoft_managed_network

$sa             = $cfg.standard_agent
$accCapHost     = $sa.capability_hosts.account_capability_host_name
$projCapHost    = $sa.capability_hosts.project_capability_host_name
$searchConn     = $sa.search.connection_name
$storageConn    = $sa.storage.connection_name
$cosmosConn     = $sa.cosmosdb.connection_name

$projectArmId   = "$accountId/projects/$projectName"
$accCapUrl      = "https://management.azure.com$accountId/capabilityHosts/$accCapHost`?api-version=$apiVersion"
$projCapUrl     = "https://management.azure.com$projectArmId/capabilityHosts/$projCapHost`?api-version=$apiVersion"
$accountUrl     = "https://management.azure.com$accountId`?api-version=$apiVersion"

Write-Host "    account caphost : $accCapHost" -ForegroundColor Gray
Write-Host "    project caphost : $projCapHost" -ForegroundColor Gray
Write-Host "    connections     : search=$searchConn storage=$storageConn cosmos=$cosmosConn" -ForegroundColor Gray

az account set --subscription $subscriptionId | Out-Null

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-CapHostState {
    param([string]$Url)
    $tmp = New-TemporaryFile
    # az writes the 404 body to stderr; under ErrorActionPreference=Stop that aborts the script,
    # so run the probe under 'Continue' and treat non-zero exit as "absent".
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        az rest --method get --url $Url --output-file $tmp.FullName 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }  # 404 / not found
        $body = Get-Content $tmp.FullName -Raw | ConvertFrom-Json
        return $body.properties.provisioningState
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prev
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

function Remove-CapHost {
    param([string]$Url, [string]$Label)
    $state = Get-CapHostState -Url $Url
    if ($null -eq $state) {
        Write-Host "==> $Label not present - nothing to delete" -ForegroundColor Yellow
        return
    }
    Write-Host "==> $Label current state: $state" -ForegroundColor Cyan
    if (-not $PSCmdlet.ShouldProcess($Label, 'DELETE capability host')) { return }
    Write-Host "    deleting..." -ForegroundColor Yellow
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    az rest --method delete --url $Url 2>$null | Out-Null
    $ErrorActionPreference = $prev
    $deadline = (Get-Date).AddSeconds(1200)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $s = Get-CapHostState -Url $Url
        if ($null -eq $s) { Write-Host "    deleted." -ForegroundColor Green; return }
        Write-Host "    still deleting (state=$s)..." -ForegroundColor Gray
    }
    throw "$Label did not finish deleting within timeout."
}

function New-CapHost {
    param([string]$Url, [string]$BodyJson, [string]$Label)
    if (-not $PSCmdlet.ShouldProcess($Label, 'PUT (create) capability host')) { return }
    Write-Host "==> Creating $Label" -ForegroundColor Cyan
    $bodyFile = New-TemporaryFile
    [System.IO.File]::WriteAllText($bodyFile.FullName, $BodyJson, (New-Object System.Text.UTF8Encoding($false)))
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    az rest --method put --url $Url --headers "Content-Type=application/json" --body "@$($bodyFile.FullName)" 2>$null | Out-Null
    $putExit = $LASTEXITCODE
    $ErrorActionPreference = $prev
    Remove-Item $bodyFile.FullName -ErrorAction SilentlyContinue
    if ($putExit -ne 0) { throw "$Label PUT failed (exit $putExit)" }

    $deadline = (Get-Date).AddSeconds(1800)
    $final = 'Timeout'
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $s = Get-CapHostState -Url $Url
        if ($s -eq 'Succeeded') { $final = 'Succeeded'; break }
        if ($s -in @('Failed', 'Canceled')) { $final = $s; break }
        Write-Host "    provisioning (state=$s)..." -ForegroundColor Gray
    }
    if ($final -ne 'Succeeded') { throw "$Label did not reach Succeeded (state=$final)" }
    Write-Host "==> $Label Succeeded" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Stage 1 - Delete project capability host (must go before account)
# ---------------------------------------------------------------------------
Remove-CapHost -Url $projCapUrl -Label "project capability host '$projCapHost'"

# ---------------------------------------------------------------------------
# Stage 2 - Delete account capability host (rebuilds the managed agent network)
# ---------------------------------------------------------------------------
Remove-CapHost -Url $accCapUrl -Label "account capability host '$accCapHost'"

# ---------------------------------------------------------------------------
# Stage 3 - Re-assert network injection (agent -> agents-injection subnet)
# ---------------------------------------------------------------------------
if (-not $SkipInjectionReassert) {
    Write-Host "==> Re-asserting network injection (agent -> $agentSubnet)" -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess($accCapHost, 'PATCH networkInjections')) {
        $agentSubnetId = az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $agentSubnet --query id -o tsv
        $injBody = @{
            properties = @{
                networkInjections = @(
                    @{
                        scenario                   = $niScenario
                        subnetArmId                = $agentSubnetId
                        useMicrosoftManagedNetwork = $niManaged
                    }
                )
            }
        } | ConvertTo-Json -Depth 8
        $injFile = New-TemporaryFile
        [System.IO.File]::WriteAllText($injFile.FullName, $injBody, (New-Object System.Text.UTF8Encoding($false)))
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        az rest --method PATCH --url $accountUrl --body "@$($injFile.FullName)" --headers "Content-Type=application/json" 2>$null | Out-Null
        $patchExit = $LASTEXITCODE
        $ErrorActionPreference = $prev
        Remove-Item $injFile.FullName -ErrorAction SilentlyContinue
        if ($patchExit -ne 0) { throw "networkInjections PATCH failed (exit $patchExit)" }
        Write-Host "    injection re-asserted." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Stage 4 - Recreate account capability host (long-running)
# When network injection is recorded on the account, the account capability host PUT REQUIRES
# a customerSubnet that matches the injected agents-injection subnet, else it fails with
# "The customerSubnet property must match the subnet recorded on the Foundry account."
# ---------------------------------------------------------------------------
$agentSubnetIdForCap = az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $agentSubnet --query id -o tsv
$accCapBody = @{ properties = @{ capabilityHostKind = 'Agents'; customerSubnet = $agentSubnetIdForCap } } | ConvertTo-Json -Depth 5
New-CapHost -Url $accCapUrl -BodyJson $accCapBody -Label "account capability host '$accCapHost'"

# ---------------------------------------------------------------------------
# Stage 5 - Recreate project capability host (same BYO connections, long-running)
# ---------------------------------------------------------------------------
$projCapBody = @{
    properties = @{
        capabilityHostKind       = 'Agents'
        vectorStoreConnections   = @($searchConn)
        storageConnections       = @($storageConn)
        threadStorageConnections = @($cosmosConn)
    }
} | ConvertTo-Json -Depth 6
New-CapHost -Url $projCapUrl -BodyJson $projCapBody -Label "project capability host '$projCapHost'"

Write-Host ''
Write-Host '==> Managed agent network redeployed (account + project capability hosts rebuilt).' -ForegroundColor Cyan
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Recreate the agent (its env was rebuilt): python ./scripts/create_ni_function_agent.py' -ForegroundColor Gray
Write-Host '  2. Retest end-to-end:                        python ./scripts/test_ni_function_agent.py' -ForegroundColor Gray
Write-Host '     (or retest from the Foundry portal Playground)' -ForegroundColor Gray
