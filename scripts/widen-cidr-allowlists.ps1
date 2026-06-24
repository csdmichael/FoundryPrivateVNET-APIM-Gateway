$ErrorActionPreference = 'Continue'
$sub   = '86b37969-9445-49cf-b03f-d8866235171c'
$rg    = 'ai-myaacoub'
$apim  = 'ai-gateway-apim-poc-my'
$func  = 'func-fdryvnetgw-data-eastus'
$fdry  = '002-ai-poc-private'
$apimId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim"

# CIDR blocks covering all observed rotating Azure SNAT IPs
$cidrs = @(
    @{ Cidr = '20.1.0.0/16';    From = '20.1.0.0';    To = '20.1.255.255' },
    @{ Cidr = '20.110.0.0/16';  From = '20.110.0.0';  To = '20.110.255.255' },
    @{ Cidr = '20.114.0.0/16';  From = '20.114.0.0';  To = '20.114.255.255' },
    @{ Cidr = '172.172.0.0/16'; From = '172.172.0.0'; To = '172.172.255.255' },
    @{ Cidr = '172.200.0.0/16'; From = '172.200.0.0'; To = '172.200.255.255' }
)

# --- 1. APIM global ip-filter (address-range; NO <base/> in global scope) ---
Write-Host '=== APIM ip-filter (address-range) ==='
$rangeLines = ($cidrs | ForEach-Object { '        <address-range from="{0}" to="{1}" />' -f $_.From, $_.To }) -join "`n"
$policy = @"
<policies>
  <inbound>
    <ip-filter action="allow">
$rangeLines
    </ip-filter>
  </inbound>
  <backend>
    <forward-request />
  </backend>
  <outbound />
  <on-error />
</policies>
"@
$body = @{ properties = @{ format = 'rawxml'; value = $policy } } | ConvertTo-Json -Depth 6
$pf = Join-Path $env:TEMP 'apim-cidr.json'
$rf = Join-Path $env:TEMP 'apim-cidr-resp.json'
[System.IO.File]::WriteAllText($pf, $body, (New-Object System.Text.UTF8Encoding($false)))
az rest --method PUT --url ("https://management.azure.com" + $apimId + "/policies/policy?api-version=2024-05-01") --body "@$pf" --headers "Content-Type=application/json" --output-file $rf 2>&1 | Out-Null
Write-Host "  APIM policy PUT exit=$LASTEXITCODE"

# --- 2. Function access restrictions (CIDR) ---
Write-Host '=== Function access restrictions (CIDR) ==='
$prio = 200
foreach ($c in $cidrs) {
    $name = 'cidr-' + ($c.Cidr -replace '[./]', '-')
    az functionapp config access-restriction add -g $rg -n $func --rule-name $name --action Allow --ip-address $c.Cidr --priority $prio -o none 2>&1 | Out-Null
    Write-Host ("  {0} (prio {1}) exit={2}" -f $c.Cidr, $prio, $LASTEXITCODE)
    $prio += 10
}

# --- 3. Foundry networkAcls (CIDR) ---
Write-Host '=== Foundry network rules (CIDR) ==='
foreach ($c in $cidrs) {
    az cognitiveservices account network-rule add -g $rg -n $fdry --ip-address $c.Cidr -o none 2>&1 | Out-Null
    Write-Host ("  {0} exit={1}" -f $c.Cidr, $LASTEXITCODE)
}

Write-Host 'DONE'
