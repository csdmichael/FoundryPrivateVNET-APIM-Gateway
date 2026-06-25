<#
.SYNOPSIS
    Provision (or delete) a Windows jump box VM + Azure Bastion inside the network-injection VNet
    so you can validate the agent's private path from a VNet-joined host.

.DESCRIPTION
    The injected Foundry agent's tool call must resolve the private Function App over private DNS.
    To prove that end-to-end (and to run scripts/test_ni_function_agent.py while the Foundry account
    is FULLY private), you need a host inside vnet-fdryvnetgw-ni-eastus2. This script creates:

      1. dev-jumpbox subnet            (VM NIC; no public IP on the VM)
      2. AzureBastionSubnet            (required exact name, /26+)
      3. A Standard public IP          (for Bastion only)
      4. Azure Bastion (Basic SKU)     (browser RDP to the VM)
      5. A Windows Server 2022 VM      (the jump box; reached only via Bastion)

    All values come from config/network_injection_config.json (jumpbox + networking blocks). The VM
    admin password is prompted securely (Read-Host -AsSecureString) and never written to disk or
    logs; pass it directly. Provisioning is idempotent — existing resources are skipped.

    COST: Azure Bastion (Basic) and the VM both bill hourly while they exist. When finished, run
    with -Delete to remove the VM, Bastion, public IP, and the two subnets.

.PARAMETER Delete
    Tear down the jump box, Bastion, public IP, and the dev-jumpbox + AzureBastionSubnet subnets.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/provision-jumpbox.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/provision-jumpbox.ps1 -Delete
#>
[CmdletBinding()]
param([switch]$Delete)

$ErrorActionPreference = 'Stop'

# Run a mutating az command under EAP=Continue and throw only on a non-zero exit code,
# so benign az stderr warnings don't abort the script (Windows PS 5.1 behavior).
function Invoke-AzWrite {
    param([Parameter(Mandatory)][scriptblock]$Script, [Parameter(Mandatory)][string]$What)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Script
        if ($LASTEXITCODE -ne 0) { throw "az failed ($What), exit $LASTEXITCODE" }
    } finally { $ErrorActionPreference = $prev }
}

# Existence probe: returns the value or $null; never throws on a not-found stderr.
function Invoke-AzProbe {
    param([Parameter(Mandatory)][scriptblock]$Script)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $v = & $Script 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return $v
    } finally { $ErrorActionPreference = $prev }
}

# ---------------------------------------------------------------------------
# Load configuration (no hardcoding)
# ---------------------------------------------------------------------------
Write-Host '==> Loading configuration' -ForegroundColor Cyan
$cfg = Get-Content .\config\network_injection_config.json -Raw | ConvertFrom-Json

$subscriptionId = $cfg.subscription_id
$rg             = $cfg.resource_group
$loc            = $cfg.location
$vnet           = $cfg.networking.vnet_name

$jb             = $cfg.jumpbox
$vmName         = $jb.vm_name
$vmSize         = $jb.vm_size
$image          = $jb.image
$adminUser      = $jb.admin_username
$vmSubnet       = $jb.subnet_name
$vmSubnetPfx    = $jb.subnet_prefix
$bastionName    = $jb.bastion_name
$bastionSubnet  = $jb.bastion_subnet_name
$bastionSubPfx  = $jb.bastion_subnet_prefix
$bastionPip     = $jb.bastion_public_ip_name
$bastionSku     = $jb.bastion_sku

az account set --subscription $subscriptionId | Out-Null

# ---------------------------------------------------------------------------
# Delete path
# ---------------------------------------------------------------------------
if ($Delete) {
    Write-Host "==> Deleting jump box resources (VM, Bastion, public IP, subnets)" -ForegroundColor Cyan

    if (Invoke-AzProbe { az vm show -g $rg -n $vmName --query id -o tsv }) {
        Write-Host "    deleting VM '$vmName' (and its OS disk + NIC)..." -ForegroundColor Yellow
        Invoke-AzWrite { az vm delete -g $rg -n $vmName --yes } "delete VM"
        # Best-effort cleanup of the auto-created NIC/disk left behind.
        $nic = Invoke-AzProbe { az network nic show -g $rg -n "$vmName`VMNic" --query id -o tsv }
        if ($nic) { Invoke-AzWrite { az network nic delete -g $rg -n "$vmName`VMNic" } "delete NIC" }
    } else { Write-Host "    VM '$vmName' not present" -ForegroundColor Gray }

    if (Invoke-AzProbe { az network bastion show -g $rg -n $bastionName --query id -o tsv }) {
        Write-Host "    deleting Bastion '$bastionName' (long-running)..." -ForegroundColor Yellow
        Invoke-AzWrite { az network bastion delete -g $rg -n $bastionName } "delete Bastion"
    } else { Write-Host "    Bastion '$bastionName' not present" -ForegroundColor Gray }

    if (Invoke-AzProbe { az network public-ip show -g $rg -n $bastionPip --query id -o tsv }) {
        Invoke-AzWrite { az network public-ip delete -g $rg -n $bastionPip } "delete public IP"
    }

    foreach ($sn in @($bastionSubnet, $vmSubnet)) {
        if (Invoke-AzProbe { az network vnet subnet show -g $rg --vnet-name $vnet -n $sn --query id -o tsv }) {
            Write-Host "    deleting subnet '$sn'..." -ForegroundColor Yellow
            Invoke-AzWrite { az network vnet subnet delete -g $rg --vnet-name $vnet -n $sn } "delete subnet $sn"
        }
    }
    Write-Host "==> Jump box teardown complete." -ForegroundColor Green
    return
}

# ---------------------------------------------------------------------------
# Stage 1 - Subnets (VM NIC + AzureBastionSubnet)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 1: subnets" -ForegroundColor Cyan
if (-not (Invoke-AzProbe { az network vnet subnet show -g $rg --vnet-name $vnet -n $vmSubnet --query id -o tsv })) {
    Invoke-AzWrite { az network vnet subnet create -g $rg --vnet-name $vnet -n $vmSubnet --address-prefixes $vmSubnetPfx } "create subnet $vmSubnet"
    Write-Host "    created subnet '$vmSubnet' ($vmSubnetPfx)" -ForegroundColor Green
} else { Write-Host "    subnet '$vmSubnet' exists" -ForegroundColor Yellow }

if (-not (Invoke-AzProbe { az network vnet subnet show -g $rg --vnet-name $vnet -n $bastionSubnet --query id -o tsv })) {
    Invoke-AzWrite { az network vnet subnet create -g $rg --vnet-name $vnet -n $bastionSubnet --address-prefixes $bastionSubPfx } "create $bastionSubnet"
    Write-Host "    created subnet '$bastionSubnet' ($bastionSubPfx)" -ForegroundColor Green
} else { Write-Host "    subnet '$bastionSubnet' exists" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Stage 2 - Public IP + Bastion (Basic SKU, browser RDP)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 2: Bastion" -ForegroundColor Cyan
if (-not (Invoke-AzProbe { az network public-ip show -g $rg -n $bastionPip --query id -o tsv })) {
    Invoke-AzWrite { az network public-ip create -g $rg -n $bastionPip -l $loc --sku Standard --allocation-method Static } "create Bastion public IP"
    Write-Host "    created public IP '$bastionPip'" -ForegroundColor Green
} else { Write-Host "    public IP '$bastionPip' exists" -ForegroundColor Yellow }

if (-not (Invoke-AzProbe { az network bastion show -g $rg -n $bastionName --query id -o tsv })) {
    Write-Host "    creating Bastion '$bastionName' ($bastionSku) - this takes several minutes..." -ForegroundColor Yellow
    Invoke-AzWrite { az network bastion create -g $rg -n $bastionName -l $loc --vnet-name $vnet --public-ip-address $bastionPip --sku $bastionSku } "create Bastion"
    Write-Host "    created Bastion '$bastionName'" -ForegroundColor Green
} else { Write-Host "    Bastion '$bastionName' exists" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Stage 3 - Windows VM (no public IP; reachable only via Bastion)
# ---------------------------------------------------------------------------
Write-Host "==> Stage 3: Windows jump box VM" -ForegroundColor Cyan
if (Invoke-AzProbe { az vm show -g $rg -n $vmName --query id -o tsv }) {
    Write-Host "    VM '$vmName' already exists - skipping create" -ForegroundColor Yellow
} else {
    # Prompt for the admin password securely. It is never echoed, logged, or written to disk.
    Write-Host ""
    Write-Host "    Enter an admin password for the Windows jump box (input hidden)." -ForegroundColor Cyan
    Write-Host "    Requirements: 12-123 chars, 3 of {lowercase, uppercase, digit, symbol}." -ForegroundColor Gray
    $secure = Read-Host "    Admin password" -AsSecureString
    $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        Write-Host "    creating VM '$vmName' ($vmSize, $image)..." -ForegroundColor Yellow
        Invoke-AzWrite {
            az vm create -g $rg -n $vmName -l $loc `
                --image $image --size $vmSize `
                --admin-username $adminUser --admin-password $plain `
                --vnet-name $vnet --subnet $vmSubnet `
                --public-ip-address '""' --nsg-rule NONE `
                --storage-sku StandardSSD_LRS
        } "create VM"
        Write-Host "    created VM '$vmName'" -ForegroundColor Green
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if (Get-Variable plain -ErrorAction SilentlyContinue) { Remove-Variable plain }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$privateIp = Invoke-AzProbe { az vm list-ip-addresses -g $rg -n $vmName --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv }
Write-Host ""
Write-Host "==> Jump box ready" -ForegroundColor Green
Write-Host "    VM            : $vmName ($vmSize, $loc)" -ForegroundColor Gray
Write-Host "    Admin user    : $adminUser" -ForegroundColor Gray
Write-Host "    Private IP    : $privateIp (no public IP)" -ForegroundColor Gray
Write-Host "    Bastion       : $bastionName ($bastionSku)" -ForegroundColor Gray
Write-Host ""
Write-Host "Connect (browser RDP via Bastion):" -ForegroundColor Cyan
Write-Host "  Azure portal > Virtual machines > $vmName > Connect > Bastion >" -ForegroundColor Gray
Write-Host "  enter username '$adminUser' + your password > Connect." -ForegroundColor Gray
Write-Host ""
Write-Host "Or native RDP from this machine via Bastion tunnel (needs Standard SKU + AZ CLI):" -ForegroundColor Cyan
Write-Host "  az network bastion rdp --name $bastionName --resource-group $rg ``" -ForegroundColor Gray
Write-Host "      --target-resource-id (az vm show -g $rg -n $vmName --query id -o tsv)" -ForegroundColor Gray
Write-Host ""
Write-Host "On the VM, to run the in-VNet validation:" -ForegroundColor Cyan
Write-Host "  nslookup func-fdryvnetgw-data-ni-eastus2.azurewebsites.net   # expect 10.50.2.10" -ForegroundColor Gray
Write-Host "  # install Azure CLI + Python 3.11, clone the repo, then:" -ForegroundColor Gray
Write-Host "  az login" -ForegroundColor Gray
Write-Host "  pip install -r requirements.txt" -ForegroundColor Gray
Write-Host "  python scripts/test_ni_function_agent.py" -ForegroundColor Gray
Write-Host ""
Write-Host "Tear down when done (stops hourly billing):" -ForegroundColor Cyan
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/provision-jumpbox.ps1 -Delete" -ForegroundColor Gray
