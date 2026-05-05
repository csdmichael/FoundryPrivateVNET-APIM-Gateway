$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$tfvars = Get-Content .\main.tfvars.json | ConvertFrom-Json
$subscriptionId = $tfvars.subscription_id
$resourceGroup = $tfvars.resource_group_name
$locationSlug = ($tfvars.location -replace '\s+', '').ToLowerInvariant()
$namePrefix = $tfvars.name_prefix
$apiWebAppName = if ($null -ne $tfvars.api_web_app_name -and $tfvars.api_web_app_name) { $tfvars.api_web_app_name } else { "lwapp-${namePrefix}api-$locationSlug" }
$uiWebAppName = if ($null -ne $tfvars.ui_web_app_name -and $tfvars.ui_web_app_name) { $tfvars.ui_web_app_name } else { "lwapp-${namePrefix}ui-$locationSlug" }

$vnetName = "vnet-$namePrefix-$locationSlug"
$logAnalyticsName = "log-$namePrefix-$locationSlug"
$apiIdentityName = "msi-${namePrefix}api-$locationSlug"
$uiIdentityName = "msi-${namePrefix}ui-$locationSlug"
$foundryPrivateEndpointName = "pe-${namePrefix}fdry-$locationSlug"
$searchPrivateEndpointName = "pe-${namePrefix}srch-$locationSlug"

$imports = @(
    @{ Address = 'azurerm_log_analytics_workspace.main'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OperationalInsights/workspaces/$logAnalyticsName" },
    @{ Address = 'azurerm_user_assigned_identity.api'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$apiIdentityName" },
    @{ Address = 'azurerm_user_assigned_identity.ui'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$uiIdentityName" },
    @{ Address = 'azurerm_virtual_network.main'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnetName" },
    @{ Address = 'azurerm_subnet.appsvc_integration'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnetName/subnets/appsvc-integration" },
    @{ Address = 'azurerm_subnet.private_endpoints'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnetName/subnets/private-endpoints" },
    @{ Address = 'azurerm_private_dns_zone.foundry'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com" },
    @{ Address = 'azurerm_private_dns_zone.search'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net" },
    @{ Address = 'azurerm_private_dns_zone_virtual_network_link.foundry'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com/virtualNetworkLinks/foundry-link" },
    @{ Address = 'azurerm_private_dns_zone_virtual_network_link.search'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net/virtualNetworkLinks/search-link" },
    @{ Address = 'azurerm_private_endpoint.foundry'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateEndpoints/$foundryPrivateEndpointName" },
    @{ Address = 'azurerm_private_endpoint.search'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateEndpoints/$searchPrivateEndpointName" },
    @{ Address = 'azurerm_linux_web_app.api'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$apiWebAppName" },
    @{ Address = 'azurerm_linux_web_app.ui'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$uiWebAppName" }
)

$trackedAddresses = @(terraform state list 2>$null)

foreach ($import in $imports) {
    $address = $import.Address
    $resourceId = $import.Id

    if ($trackedAddresses -contains $address) {
        Write-Host "Already tracked: $address"
        continue
    }

    az resource show --ids $resourceId -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Not present in Azure, skipping: $address"
        continue
    }

    Write-Host "Importing $address"
    & terraform import '-var-file=main.tfvars.json' $address $resourceId
}