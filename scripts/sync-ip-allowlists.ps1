<#
.SYNOPSIS
    Synchronize the developer/company egress IP allowlist across the three
    public-but-restricted resources used for the private-VNET demo:
      1. APIM gateway global ip-filter policy
      2. Function App inbound access restrictions
      3. Foundry (Cognitive Services) account network ACLs

.DESCRIPTION
    The client (developer machine) reaches Azure PaaS endpoints through a rotating
    Azure SNAT pool, so a single /32 is not enough. This script sets the SAME set
    of client IPs on all three resources. APIM's own outbound NAT egress IP is also
    kept on the Function so APIM -> Function calls succeed.

    Re-run any time the egress pool changes (discover new IPs via the
    x-ms-forbidden-ip response header from the Function App).
#>
[CmdletBinding()]
param(
    [string[]]$ClientIp = @(
        '20.1.194.235',
        '20.110.218.7',
        '172.172.34.115',
        '172.200.70.35',
        '20.114.144.49',
        '172.200.70.89'
    ),
    # APIM outbound NAT egress IP(s) that must reach the Function backend.
    [string[]]$ApimEgressIp = @('4.156.128.70'),
    [string]$SubscriptionId = '86b37969-9445-49cf-b03f-d8866235171c',
    [string]$ResourceGroup  = 'ai-myaacoub',
    [string]$ApimName       = 'ai-gateway-apim-poc-my',
    [string]$FunctionApp    = 'func-fdryvnetgw-data-eastus',
    [string]$FoundryAccount = '002-ai-poc-private'
)

$ErrorActionPreference = 'Stop'

function Invoke-AzWrite {
    param([Parameter(Mandatory)][scriptblock]$Cmd, [string]$What = 'az command')
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Cmd 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" } }
    finally { $ErrorActionPreference = $prev }
}

az account set --subscription $SubscriptionId | Out-Null

# ---------------------------------------------------------------------------
# 1. APIM global ip-filter policy (NOTE: global scope must NOT contain <base/>)
# ---------------------------------------------------------------------------
Write-Host '==> Updating APIM global ip-filter policy' -ForegroundColor Cyan
$addresses = ($ClientIp | ForEach-Object { "        <address>$_</address>" }) -join "`n"
$policyXml = @"
<policies>
  <inbound>
    <ip-filter action="allow">
$addresses
    </ip-filter>
  </inbound>
  <backend>
    <forward-request />
  </backend>
  <outbound />
  <on-error />
</policies>
"@
$apimId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$body = @{ properties = @{ format = 'rawxml'; value = $policyXml } } | ConvertTo-Json -Depth 6
$bodyPath = Join-Path ([System.IO.Path]::GetTempPath()) 'apim-global-policy.json'
$respPath = Join-Path ([System.IO.Path]::GetTempPath()) 'apim-global-policy-resp.json'
[System.IO.File]::WriteAllText($bodyPath, $body, (New-Object System.Text.UTF8Encoding($false)))
Invoke-AzWrite { az rest --method PUT --url "https://management.azure.com$apimId/policies/policy?api-version=2024-05-01" --body "@$bodyPath" --headers "Content-Type=application/json" --output-file $respPath } 'apim policy put'

# ---------------------------------------------------------------------------
# 2. Function App inbound access restrictions (client IPs + APIM egress)
# ---------------------------------------------------------------------------
Write-Host '==> Updating Function App access restrictions' -ForegroundColor Cyan
$existing = az functionapp config access-restriction show -g $ResourceGroup -n $FunctionApp --query "ipSecurityRestrictions[].ip_address" -o tsv
$priority = 100
foreach ($ip in $ClientIp) {
    if ($existing -notcontains "$ip/32") {
        Invoke-AzWrite { az functionapp config access-restriction add -g $ResourceGroup -n $FunctionApp --rule-name "allow-client-$priority" --action Allow --ip-address "$ip/32" --priority $priority --description 'Company/dev egress IP' } "func add $ip"
    }
    $priority += 10
}
foreach ($ip in $ApimEgressIp) {
    if ($existing -notcontains "$ip/32") {
        Invoke-AzWrite { az functionapp config access-restriction add -g $ResourceGroup -n $FunctionApp --rule-name "allow-apim-egress-$priority" --action Allow --ip-address "$ip/32" --priority $priority --description 'APIM outbound NAT egress' } "func add apim $ip"
    }
    $priority += 10
}

# ---------------------------------------------------------------------------
# 3. Foundry account network ACLs (client IPs only; APIM reaches Foundry via PE)
# ---------------------------------------------------------------------------
Write-Host '==> Updating Foundry network ACLs' -ForegroundColor Cyan
$foundryId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$FoundryAccount"
$ipRules = ($ClientIp | ForEach-Object { @{ value = $_ } })
$foundryBody = @{ properties = @{ publicNetworkAccess = 'Enabled'; networkAcls = @{ defaultAction = 'Deny'; ipRules = $ipRules } } } | ConvertTo-Json -Depth 8
$foundryBodyPath = Join-Path ([System.IO.Path]::GetTempPath()) 'foundry-acls.json'
$foundryRespPath = Join-Path ([System.IO.Path]::GetTempPath()) 'foundry-acls-resp.json'
[System.IO.File]::WriteAllText($foundryBodyPath, $foundryBody, (New-Object System.Text.UTF8Encoding($false)))
# Build the URL by concatenation: "$foundryId?api-version" lets PowerShell swallow
# the query string as part of the variable token, so keep '?' outside the var.
$foundryUrl = 'https://management.azure.com' + $foundryId + '?api-version=2024-10-01'
Invoke-AzWrite { az rest --method PATCH --url $foundryUrl --body "@$foundryBodyPath" --headers "Content-Type=application/json" --output-file $foundryRespPath } 'foundry acls patch'

Write-Host "`nDone. Allowlist synchronized across APIM, Function App, and Foundry." -ForegroundColor Green
Write-Host ("Client IPs: {0}" -f ($ClientIp -join ', '))
Write-Host ("APIM egress IPs (Function only): {0}" -f ($ApimEgressIp -join ', '))
