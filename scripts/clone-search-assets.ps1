$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$config = Get-Content .\config\azure_resources.json | ConvertFrom-Json
$subscriptionId = $config.subscription_id
$resourceGroup = $config.resource_group
$sourceService = $config.search.source_service_name
$targetService = $config.search.target_service_name

$useCases = @('tax_pdf_forms', 'eng_design_ppt')

foreach ($useCase in $useCases) {
    $assets = $config.use_cases.$useCase.search_assets
    foreach ($assetType in @('dataSources', 'indexes', 'indexers')) {
        $name = switch ($assetType) {
            'dataSources' { $assets.data_source }
            'indexes' { $assets.index }
            default { $assets.indexer }
        }

        $apiVersion = switch ($assetType) {
            'dataSources' { '2024-07-01' }
            'indexes' { '2024-07-01' }
            default { '2024-07-01' }
        }

        $sourcePath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Search/searchServices/$sourceService/$assetType/$name?api-version=$apiVersion"
        $targetPath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Search/searchServices/$targetService/$assetType/$name?api-version=$apiVersion"

        $definition = az rest --method get --url "https://management.azure.com$sourcePath" | ConvertFrom-Json
        if ($null -eq $definition) {
            throw "Unable to retrieve $assetType/$name from $sourceService"
        }

        $body = $definition | Select-Object -Property * -ExcludeProperty id,name,type,etag,systemData | ConvertTo-Json -Depth 100
        az rest --method put --url "https://management.azure.com$targetPath" --body $body | Out-Null
    }
}
