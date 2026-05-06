param(
    [switch]$SearchOnly,
    [switch]$AgentsOnly
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$pythonCommand = if ($env:PYTHON_BIN) { $env:PYTHON_BIN } else { 'python' }
$localCreateSearchScriptPath = Join-Path $PSScriptRoot 'create_cosmosdb_search_index.py'
$localCreateAgentScriptPath = Join-Path $PSScriptRoot 'create_foundry_agent.py'

function Assert-LastExitCode {
    param(
        [string]$Operation
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

if (-not $SearchOnly -and -not $AgentsOnly) {
    $SearchOnly = $true
    $AgentsOnly = $true
}

$config = Get-Content .\config\azure_resources.json | ConvertFrom-Json

$searchAdminKey = az search admin-key show --service-name $config.search.target_service_name --resource-group $config.resource_group --query primaryKey -o tsv
Assert-LastExitCode "Retrieving Search admin key"
if (-not $searchAdminKey) {
    throw "Unable to retrieve Search admin key for $($config.search.target_service_name)."
}
$env:AZURE_AI_SEARCH_KEY = $searchAdminKey

if ($AgentsOnly) {
    & "$PSScriptRoot\ensure-foundry-search-connection.ps1"
}

foreach ($useCase in @('tax_pdf_forms', 'eng_design_ppt')) {
    $env:USE_CASE = $useCase

    if ($SearchOnly) {
        & $pythonCommand $localCreateSearchScriptPath
        Assert-LastExitCode "Creating Search assets for use case '$useCase'"
    }

    if ($AgentsOnly) {
        $env:AZURE_AI_SEARCH_CONNECTION_NAME = $config.foundry.search_connection_name
        & $pythonCommand $localCreateAgentScriptPath
        Assert-LastExitCode "Creating Foundry agent for use case '$useCase'"
    }
}