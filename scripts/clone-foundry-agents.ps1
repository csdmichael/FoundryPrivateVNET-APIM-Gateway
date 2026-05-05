$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$config = Get-Content .\config\azure_resources.json | ConvertFrom-Json
$sourceEndpoint = $config.foundry.source_project_endpoint.TrimEnd('/')
$targetEndpoint = $config.foundry.project_endpoint.TrimEnd('/')
$agents = @('Eng-Design-PPT-Agent', 'Tax-PDF-Forms-Agent')
$apiVersion = '2024-05-01-preview'
$token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv

foreach ($agentName in $agents) {
    $sourceUrl = "$sourceEndpoint/agents/$agentName?api-version=$apiVersion"
    $targetUrl = "$targetEndpoint/agents/$agentName?api-version=$apiVersion"

    $headers = @{
        Authorization = "Bearer $token"
        'Content-Type' = 'application/json'
    }

    $definition = Invoke-RestMethod -Method Get -Uri $sourceUrl -Headers $headers
    if ($null -eq $definition) {
        throw "Unable to read source agent $agentName"
    }

    $payload = $definition | Select-Object -Property * -ExcludeProperty id,createdAt,updatedAt | ConvertTo-Json -Depth 100
    Invoke-RestMethod -Method Put -Uri $targetUrl -Headers $headers -Body $payload | Out-Null
}
