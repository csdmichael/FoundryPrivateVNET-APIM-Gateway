$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$config = Get-Content .\config\prompts_config.json | ConvertFrom-Json
$azConfig = Get-Content .\config\azure_resources.json | ConvertFrom-Json
$apiBase = if ($env:APP_API_BASE_URL) { $env:APP_API_BASE_URL.TrimEnd('/') } else { "$($azConfig.app_services.api_url)/api" }

foreach ($useCase in @('tax_pdf_forms', 'eng_design_ppt')) {
    $prompt = $config.use_cases.$useCase.agent[0].text
    $body = @{
        prompt = $prompt
        use_case = $useCase
    } | ConvertTo-Json

    Write-Host "Testing $useCase prompt against $apiBase/chat"
    Invoke-RestMethod -Method Post -Uri "$apiBase/chat" -ContentType 'application/json' -Body $body | ConvertTo-Json -Depth 10
}
