param([switch]$Deploy)
$ErrorActionPreference = 'Stop'
$rg = 'ai-myaacoub'
$acct = '003-ai-poc-network-injection'

Write-Host '== gpt-4 family models available ==' -ForegroundColor Cyan
$models = az cognitiveservices account list-models -g $rg -n $acct -o json | ConvertFrom-Json
$models | Where-Object { $_.name -like 'gpt-4*' } |
    Select-Object name, version, format, @{n='skus';e={ ($_.skus.name -join ',') }} |
    Sort-Object name, version | Format-Table -AutoSize

if ($Deploy) {
    $name = 'gpt-4.1'
    $target = $models | Where-Object { $_.name -eq $name } | Sort-Object version -Descending | Select-Object -First 1
    if (-not $target) { Write-Host "model $name not available on this account" -ForegroundColor Red; exit 1 }
    $ver = $target.version
    $sku = ($target.skus | Where-Object { $_.name -in @('GlobalStandard','Standard','DataZoneStandard') } | Select-Object -First 1).name
    if (-not $sku) { $sku = $target.skus[0].name }
    Write-Host "Deploying $name ($ver) sku=$sku ..." -ForegroundColor Yellow
    az cognitiveservices account deployment create -g $rg -n $acct `
        --deployment-name $name `
        --model-name $name --model-version $ver --model-format OpenAI `
        --sku-name $sku --sku-capacity 50 | Out-Null
    Write-Host "Deployment '$name' created." -ForegroundColor Green
    az cognitiveservices account deployment list -g $rg -n $acct --query '[].[name,properties.model.version,sku.name,sku.capacity]' -o tsv
}
