param(
    [switch]$SearchOnly,
    [switch]$AgentsOnly,
    [string]$SourceRepo = 'https://github.com/csdmichael/AI-Search-Blob-Storage.git'
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$pythonCommand = if ($env:PYTHON_BIN) { $env:PYTHON_BIN } else { 'python' }

if (-not $SearchOnly -and -not $AgentsOnly) {
    $SearchOnly = $true
    $AgentsOnly = $true
}

$config = Get-Content .\config\azure_resources.json | ConvertFrom-Json
$sourceConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-search-blob-storage-" + [guid]::NewGuid().ToString('N'))

git clone --depth 1 $SourceRepo $sourceConfigDir | Out-Null

$sourceAzureResourcesPath = Join-Path $sourceConfigDir 'config\azure_resources.json'
$sourceAzureResources = Get-Content $sourceAzureResourcesPath | ConvertFrom-Json
$sourceAzureResources.subscription_id = $config.subscription_id
$sourceAzureResources.resource_group = $config.resource_group
$sourceAzureResources.search.service_name = $config.search.target_service_name
$sourceAzureResources.search.endpoint = $config.search.target_endpoint
$sourceAzureResources.foundry.project_endpoint = $config.foundry.project_endpoint
$sourceAzureResources.cosmosdb.account_name = $config.cosmosdb.account_name
$sourceAzureResources.cosmosdb.endpoint = $config.cosmosdb.endpoint
$sourceAzureResources.cosmosdb.resource_id = $config.cosmosdb.resource_id
$sourceAzureResources.cosmosdb.database_name = $config.cosmosdb.database_name
$sourceAzureResources.cosmosdb.container_name = $config.cosmosdb.container_name
$json = $sourceAzureResources | ConvertTo-Json -Depth 20
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($sourceAzureResourcesPath, $json, $utf8NoBom)

$sourceAgentConfigPath = Join-Path $sourceConfigDir 'config\agent_config.json'
$localAgentConfigPath = Join-Path (Get-Location) 'config\agent_config.json'
[System.IO.File]::WriteAllText(
    $sourceAgentConfigPath,
    [System.IO.File]::ReadAllText($localAgentConfigPath),
    $utf8NoBom
)

$sourceSearchConfigPath = Join-Path $sourceConfigDir 'config\search_config.json'
$sourceSearchConfig = Get-Content $sourceSearchConfigPath | ConvertFrom-Json
foreach ($useCase in @('tax_pdf_forms', 'eng_design_ppt')) {
    $sourceSearchConfig.use_cases.$useCase.chunked_index.name = $sourceSearchConfig.use_cases.$useCase.standard_index.name
    $sourceSearchConfig.use_cases.$useCase.chunked_index.semantic_config_name = $sourceSearchConfig.use_cases.$useCase.standard_index.semantic_config_name
}
$searchJson = $sourceSearchConfig | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($sourceSearchConfigPath, $searchJson, $utf8NoBom)

$sourceCreateSearchScriptPath = Join-Path $sourceConfigDir 'scripts\create_cosmosdb_search_index.py'
$sourceCreateSearchScript = [System.IO.File]::ReadAllText($sourceCreateSearchScriptPath)
$sourceCreateSearchScript = $sourceCreateSearchScript.Replace(
    'from azure.identity import DefaultAzureCredential',
    "from azure.core.credentials import AzureKeyCredential`nfrom azure.identity import DefaultAzureCredential"
)
$sourceCreateSearchScript = $sourceCreateSearchScript.Replace(
    '    credential = DefaultAzureCredential()',
    '    credential = AzureKeyCredential(os.environ["AZURE_AI_SEARCH_KEY"])'
)
[System.IO.File]::WriteAllText($sourceCreateSearchScriptPath, $sourceCreateSearchScript, $utf8NoBom)

$searchAdminKey = az search admin-key show --service-name $config.search.target_service_name --resource-group $config.resource_group --query primaryKey -o tsv
if (-not $searchAdminKey) {
    throw "Unable to retrieve Search admin key for $($config.search.target_service_name)."
}
$env:AZURE_AI_SEARCH_KEY = $searchAdminKey

if ($AgentsOnly) {
    & "$PSScriptRoot\ensure-foundry-search-connection.ps1"
}

Push-Location $sourceConfigDir
try {
    foreach ($useCase in @('tax_pdf_forms', 'eng_design_ppt')) {
        $env:USE_CASE = $useCase

        if ($SearchOnly) {
            & $pythonCommand .\scripts\create_cosmosdb_search_index.py
        }

        if ($AgentsOnly) {
            $env:AZURE_AI_SEARCH_CONNECTION_NAME = $config.foundry.search_connection_name
            & $pythonCommand .\scripts\create_agent.py
        }
    }
}
finally {
    Pop-Location
    Remove-Item $sourceConfigDir -Recurse -Force -ErrorAction SilentlyContinue
}