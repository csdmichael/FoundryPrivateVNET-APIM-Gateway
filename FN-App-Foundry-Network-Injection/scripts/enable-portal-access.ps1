<#
.SYNOPSIS
    Give a developer machine access to the fully-private Foundry portal/data-plane for the
    network-injection account.

.DESCRIPTION
    Reads config/network_injection_config.json. Two modes:

    -Mode JumpBox  (default, RECOMMENDED, stays fully private)
        Creates a dev-jumpbox subnet in the injected VNet and prints the steps to reach the
        private Foundry portal from inside the VNet (Azure Bastion jump box / VPN / dev tunnel).
        Nothing is exposed publicly: publicNetworkAccess stays Disabled.

    -Mode IpAllow  (temporary testing convenience, weaker than a private path)
        Flips the account to publicNetworkAccess=Enabled + networkAcls.defaultAction=Deny and
        adds the developer IP(s) from config.portal_access.developer_ips to the allow list.
        Use only to test from a laptop; revert with -Mode Revert.

    -Mode Revert
        Re-disables public network access (returns to the private posture).

    NOTE on Azure SNAT (from prior findings): this client's egress to Azure PaaS endpoints
    often rotates through a pool of Microsoft/Azure SNAT IPs rather than its internet IP, and
    the nextgen Foundry portal proxies a data-plane probe from a Microsoft backend IP. A single
    /32 allow rule may therefore be insufficient; the durable answer is the JumpBox (Pattern A).

.PARAMETER Mode
    JumpBox (default) | IpAllow | Revert

.PARAMETER ClientIp
    Override the developer IP(s) to allow in IpAllow mode (comma-separated). Defaults to
    config.portal_access.developer_ips.
#>
[CmdletBinding()]
param(
    [ValidateSet('JumpBox', 'IpAllow', 'Revert')]
    [string]$Mode = 'JumpBox',
    [string[]]$ClientIp
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

function Invoke-AzProbe {
    param([Parameter(Mandatory)][scriptblock]$Probe)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $Probe 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return ($out | Select-Object -First 1) }
        return $null
    } finally { $ErrorActionPreference = $prev }
}
function Invoke-AzWrite {
    param([Parameter(Mandatory)][scriptblock]$Cmd, [string]$What = 'az command')
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Cmd 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" } }
    finally { $ErrorActionPreference = $prev }
}

$cfg = Get-Content .\config\network_injection_config.json -Raw | ConvertFrom-Json
$subscriptionId = $cfg.subscription_id
$resourceGroup  = $cfg.resource_group
$accountName    = $cfg.foundry.account_name
az account set --subscription $subscriptionId | Out-Null

if ($Mode -eq 'JumpBox') {
    $vnetName   = $cfg.networking.vnet_name
    $jumpSubnet = $cfg.portal_access.jumpbox_subnet
    $jumpPrefix = $cfg.portal_access.jumpbox_subnet_prefix
    Write-Host "==> Mode JumpBox: private access into $vnetName" -ForegroundColor Cyan
    $exists = Invoke-AzProbe { az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n $jumpSubnet --query id -o tsv }
    if (-not $exists) {
        Invoke-AzWrite { az network vnet subnet create -g $resourceGroup --vnet-name $vnetName -n $jumpSubnet --address-prefixes $jumpPrefix } "jumpbox subnet"
        Write-Host "    created subnet '$jumpSubnet' ($jumpPrefix)" -ForegroundColor Green
    } else {
        Write-Host "    subnet '$jumpSubnet' exists" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Next (one-time), keeping everything private:" -ForegroundColor Cyan
    Write-Host "  1. Create a small VM in '$jumpSubnet' (no public IP)."
    Write-Host "  2. Add an 'AzureBastionSubnet' (>= /26) and an Azure Bastion host to $vnetName."
    Write-Host "  3. Connect to the VM via Bastion, open a browser, and go to https://ai.azure.com."
    Write-Host "     From inside the VNet the Foundry private endpoint + private DNS resolve, so the"
    Write-Host "     portal data-plane works with publicNetworkAccess still Disabled."
    Write-Host "  Alternatives: Point-to-Site VPN into $vnetName, or 'az network bastion tunnel' / dev tunnel."
    return
}

$accountId = $cfg.foundry.account_resource_id
$apiVersion = $cfg.foundry.account_api_version
$url = 'https://management.azure.com' + $accountId + '?api-version=' + $apiVersion

if ($Mode -eq 'Revert') {
    Write-Host "==> Mode Revert: disabling public network access on '$accountName'" -ForegroundColor Cyan
    $body = '{"properties":{"publicNetworkAccess":"Disabled"}}'
    $f = New-TemporaryFile
    [System.IO.File]::WriteAllText($f.FullName, $body, (New-Object System.Text.UTF8Encoding($false)))
    $resp = New-TemporaryFile
    Invoke-AzWrite { az rest --method PATCH --url $url --body ("@" + $f.FullName) --headers "Content-Type=application/json" --output-file $resp.FullName } 'revert PATCH'
    Remove-Item $f.FullName, $resp.FullName -Force -ErrorAction SilentlyContinue
    Write-Host "    publicNetworkAccess=Disabled (private posture restored)" -ForegroundColor Green
    return
}

# Mode IpAllow
$ips = if ($ClientIp) { $ClientIp } else { $cfg.portal_access.developer_ips }
Write-Host "==> Mode IpAllow: allow $($ips -join ', ') on '$accountName'" -ForegroundColor Cyan
Write-Host "    WARNING: this enables public network access (default-Deny + allowlist)." -ForegroundColor Yellow
Write-Host "    Prefer -Mode JumpBox for a fully private path. Revert with -Mode Revert." -ForegroundColor Yellow

$ipRules = @($ips | ForEach-Object { @{ value = $_ } })
$body = @{
    properties = @{
        publicNetworkAccess = 'Enabled'
        networkAcls = @{
            defaultAction = 'Deny'
            ipRules       = $ipRules
        }
    }
} | ConvertTo-Json -Depth 8
$f = New-TemporaryFile
[System.IO.File]::WriteAllText($f.FullName, $body, (New-Object System.Text.UTF8Encoding($false)))
$resp = New-TemporaryFile
Invoke-AzWrite { az rest --method PATCH --url $url --body ("@" + $f.FullName) --headers "Content-Type=application/json" --output-file $resp.FullName } 'ipallow PATCH'
Remove-Item $f.FullName, $resp.FullName -Force -ErrorAction SilentlyContinue

$applied = az rest --method GET --url $url -o json | ConvertFrom-Json
Write-Host "    publicNetworkAccess = $($applied.properties.publicNetworkAccess)" -ForegroundColor Green
Write-Host "    defaultAction       = $($applied.properties.networkAcls.defaultAction)" -ForegroundColor Green
Write-Host "    ipRules             = $(( $applied.properties.networkAcls.ipRules | ForEach-Object { $_.value }) -join ', ')" -ForegroundColor Green
Write-Host ""
Write-Host "Open https://ai.azure.com and select project '$($cfg.foundry.project_name)'." -ForegroundColor Cyan
Write-Host "If the portal still blocks: your egress IP likely rotates (Azure SNAT) or the portal's" -ForegroundColor DarkGray
Write-Host "backend probe is denied. Re-check your public IP, or switch to -Mode JumpBox." -ForegroundColor DarkGray
