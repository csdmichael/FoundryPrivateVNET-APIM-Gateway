<#
.SYNOPSIS
    Delete and recreate the PROJECT capability host so the injected agent data proxy
    re-reads the current private DNS for the Function App's private endpoint.

.DESCRIPTION
    Symptom this fixes: the network-injection agent's OpenAPI/Azure Functions tool call returns
    "HTTP 403 Ip Forbidden" with a rotating PUBLIC x-ms-forbidden-ip header. That means the
    single-tenant data proxy in the agents-injection subnet resolved the Function App hostname to
    its PUBLIC IP and egressed to the public front door (blocked once public access is disabled),
    instead of the private endpoint.

    This usually happens when the Function App's private endpoint + privatelink.azurewebsites.net
    link were (re)created AFTER the project capability host was provisioned, so the managed agent
    environment's DNS view is stale. Capability hosts are immutable, so the only way to force the
    data proxy to re-read current private DNS is to delete + recreate the project capability host.

    The project capability host references the 3 BYO connections (Search / Storage / Cosmos),
    which are read from config and reused verbatim, so the recreated host is identical except for
    the refreshed DNS view.

    WARNING: recreating the project capability host tears down and rebuilds the project's managed
    agent environment. Existing agents/threads in the project may be removed; re-run
    create_ni_function_agent.py afterward to recreate the agent.

.PARAMETER WhatIf
    Show the actions without deleting/recreating.
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Load configuration (no hardcoding)
# ---------------------------------------------------------------------------
Write-Host '==> Loading configuration' -ForegroundColor Cyan
$cfg = Get-Content .\config\network_injection_config.json -Raw | ConvertFrom-Json

$subscriptionId = $cfg.subscription_id
$sa             = $cfg.standard_agent
$projCapHost    = $sa.capability_hosts.project_capability_host_name
$searchConn     = $sa.search.connection_name
$storageConn    = $sa.storage.connection_name
$cosmosConn     = $sa.cosmosdb.connection_name

$fdry           = $cfg.foundry
$accountId      = $fdry.account_resource_id
$projectName    = $fdry.project_name
$apiVersion     = $fdry.account_api_version

$projectArmId   = "$accountId/projects/$projectName"
$projCapUrl     = "https://management.azure.com$projectArmId/capabilityHosts/$projCapHost`?api-version=$apiVersion"

Write-Host "    project        : $projectArmId" -ForegroundColor Gray
Write-Host "    capability host: $projCapHost" -ForegroundColor Gray
Write-Host "    connections    : search=$searchConn storage=$storageConn cosmos=$cosmosConn" -ForegroundColor Gray

az account set --subscription $subscriptionId | Out-Null

function Get-CapHostState {
    param([string]$Url)
    $tmp = New-TemporaryFile
    # az writes the 404 body to stderr; with ErrorActionPreference=Stop that aborts the script,
    # so suppress native-command error handling for this probe and treat non-zero exit as "absent".
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

# ---------------------------------------------------------------------------
# Stage 1 - Delete the existing project capability host
# ---------------------------------------------------------------------------
$state = Get-CapHostState -Url $projCapUrl
if ($null -eq $state) {
    Write-Host "==> Project capability host '$projCapHost' not present - nothing to delete" -ForegroundColor Yellow
} else {
    Write-Host "==> Project capability host '$projCapHost' current state: $state" -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess($projCapHost, "DELETE project capability host")) {
        Write-Host "    deleting..." -ForegroundColor Yellow
        az rest --method delete --url $projCapUrl | Out-Null
        # Poll until GET returns not-found (deletion is async).
        $deadline = (Get-Date).AddSeconds(900)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 15
            $s = Get-CapHostState -Url $projCapUrl
            if ($null -eq $s) { Write-Host "    deleted." -ForegroundColor Green; break }
            Write-Host "    still deleting (state=$s)..." -ForegroundColor Gray
        }
        if ((Get-CapHostState -Url $projCapUrl) -ne $null) {
            throw "Project capability host '$projCapHost' did not finish deleting within timeout."
        }
    }
}

# ---------------------------------------------------------------------------
# Stage 2 - Recreate the project capability host (same connections)
# ---------------------------------------------------------------------------
$bodyObj = @{
    properties = @{
        capabilityHostKind       = 'Agents'
        vectorStoreConnections   = @($searchConn)
        storageConnections       = @($storageConn)
        threadStorageConnections = @($cosmosConn)
    }
}
$bodyFile = New-TemporaryFile
($bodyObj | ConvertTo-Json -Depth 6) | Set-Content -Path $bodyFile.FullName -Encoding ascii

if ($PSCmdlet.ShouldProcess($projCapHost, "PUT (recreate) project capability host")) {
    Write-Host "==> Recreating project capability host '$projCapHost'" -ForegroundColor Cyan
    az rest --method put --url $projCapUrl --headers "Content-Type=application/json" --body "@$($bodyFile.FullName)" | Out-Null
    Remove-Item $bodyFile.FullName -ErrorAction SilentlyContinue

    # Poll until Succeeded (provisioning is long-running).
    $deadline = (Get-Date).AddSeconds(1800)
    $final = 'Timeout'
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $s = Get-CapHostState -Url $projCapUrl
        if ($s -eq 'Succeeded') { $final = 'Succeeded'; break }
        if ($s -in @('Failed', 'Canceled')) { $final = $s; break }
        Write-Host "    provisioning (state=$s)..." -ForegroundColor Gray
    }
    if ($final -ne 'Succeeded') { throw "Project capability host '$projCapHost' did not reach Succeeded (state=$final)" }
    Write-Host "==> Project capability host '$projCapHost' Succeeded" -ForegroundColor Green
} else {
    Remove-Item $bodyFile.FullName -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Recreate the agent (its env was rebuilt): python ./scripts/create_ni_function_agent.py" -ForegroundColor Gray
Write-Host "  2. Retest end-to-end:                        python ./scripts/test_ni_function_agent.py" -ForegroundColor Gray
