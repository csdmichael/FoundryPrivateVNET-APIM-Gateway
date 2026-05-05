$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$tfvars = Get-Content .\main.tfvars.json | ConvertFrom-Json
$subscriptionId = $tfvars.subscription_id
$resourceGroup = $tfvars.resource_group_name
$locationSlug = ($tfvars.location -replace '\s+', '').ToLowerInvariant()
$namePrefix = $tfvars.name_prefix
$deployApi = if ($null -ne $env:TF_VAR_deploy_api -and $env:TF_VAR_deploy_api) { [System.Convert]::ToBoolean($env:TF_VAR_deploy_api) } elseif ($null -ne $tfvars.deploy_api) { [bool]$tfvars.deploy_api } else { $false }
$deployUi = if ($null -ne $env:TF_VAR_deploy_ui -and $env:TF_VAR_deploy_ui) { [System.Convert]::ToBoolean($env:TF_VAR_deploy_ui) } elseif ($null -ne $tfvars.deploy_ui) { [bool]$tfvars.deploy_ui } else { $false }
$apiWebAppName = if ($null -ne $tfvars.api_web_app_name -and $tfvars.api_web_app_name) { $tfvars.api_web_app_name } else { "lwapp-${namePrefix}api-$locationSlug" }
$uiWebAppName = if ($null -ne $tfvars.ui_web_app_name -and $tfvars.ui_web_app_name) { $tfvars.ui_web_app_name } else { "lwapp-${namePrefix}ui-$locationSlug" }

$vnetName = "vnet-$namePrefix-$locationSlug"
$logAnalyticsName = "log-$namePrefix-$locationSlug"
$apiIdentityName = "msi-${namePrefix}api-$locationSlug"
$uiIdentityName = "msi-${namePrefix}ui-$locationSlug"

$searchServiceResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Search/searchServices/$($tfvars.search_service_name)"
$privateEndpoints = @(az network private-endpoint list --resource-group $resourceGroup -o json | ConvertFrom-Json)

function Get-PrivateEndpointIdByTargetResource {
    param(
        [string]$TargetResourceId
    )

    foreach ($privateEndpoint in $privateEndpoints) {
        foreach ($connection in @($privateEndpoint.privateLinkServiceConnections)) {
            if ($connection.privateLinkServiceId -eq $TargetResourceId) {
                return $privateEndpoint.id
            }
        }
    }

    return $null
}

$foundryPrivateEndpointId = Get-PrivateEndpointIdByTargetResource -TargetResourceId $tfvars.foundry_account_resource_id
$searchPrivateEndpointId = Get-PrivateEndpointIdByTargetResource -TargetResourceId $searchServiceResourceId

function Remove-StateAddresses {
    param(
        [string[]]$Addresses,
        [string[]]$TrackedAddresses
    )

    foreach ($address in $Addresses) {
        if ($TrackedAddresses -contains $address) {
            Write-Host "Removing from state: $address"
            & terraform state rm $address | Out-Null
        }
    }
}

function Get-TrackedResourceId {
    param(
        [string]$Address
    )

    $stateOutput = & terraform state show -no-color $Address 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $stateOutput) {
        return $null
    }

    foreach ($line in $stateOutput) {
        if ($line -match '^\s*id\s*=\s*"?(.*?)"?$') {
            return $matches[1]
        }
    }

    return $null
}

$imports = @(
    @{ Address = 'azurerm_log_analytics_workspace.main'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OperationalInsights/workspaces/$logAnalyticsName" },
    @{ Address = 'azurerm_virtual_network.main'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnetName" },
    @{ Address = 'azurerm_subnet.appsvc_integration'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnetName/subnets/appsvc-integration" },
    @{ Address = 'azurerm_subnet.private_endpoints'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnetName/subnets/private-endpoints" },
    @{ Address = 'azurerm_private_dns_zone.foundry'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com" },
    @{ Address = 'azurerm_private_dns_zone.search'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net" },
    @{ Address = 'azurerm_private_dns_zone_virtual_network_link.foundry'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com/virtualNetworkLinks/foundry-link" },
    @{ Address = 'azurerm_private_dns_zone_virtual_network_link.search'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net/virtualNetworkLinks/search-link" },
    @{ Address = 'azurerm_private_endpoint.foundry'; Id = $foundryPrivateEndpointId },
    @{ Address = 'azurerm_private_endpoint.search'; Id = $searchPrivateEndpointId }
)

if ($deployApi) {
    $imports += @(
        @{ Address = 'azurerm_user_assigned_identity.api[0]'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$apiIdentityName" },
        @{ Address = 'azurerm_linux_web_app.api[0]'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$apiWebAppName" },
        @{ Address = 'azurerm_monitor_diagnostic_setting.api[0]'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$apiWebAppName|api-to-law" }
    )
}

if ($deployUi) {
    $imports += @(
        @{ Address = 'azurerm_user_assigned_identity.ui[0]'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$uiIdentityName" },
        @{ Address = 'azurerm_linux_web_app.ui[0]'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$uiWebAppName" },
        @{ Address = 'azurerm_monitor_diagnostic_setting.ui[0]'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$uiWebAppName|ui-to-law" }
    )
}

$trackedAddresses = @(terraform state list 2>$null)

if (-not $deployApi) {
    Remove-StateAddresses -Addresses @(
        'azurerm_monitor_diagnostic_setting.api',
        'azurerm_monitor_diagnostic_setting.api[0]',
        'azurerm_app_service_virtual_network_swift_connection.api',
        'azurerm_app_service_virtual_network_swift_connection.api[0]',
        'azurerm_linux_web_app.api',
        'azurerm_linux_web_app.api[0]',
        'azurerm_user_assigned_identity.api',
        'azurerm_user_assigned_identity.api[0]'
    ) -TrackedAddresses $trackedAddresses
}

if (-not $deployUi) {
    Remove-StateAddresses -Addresses @(
        'azurerm_monitor_diagnostic_setting.ui',
        'azurerm_monitor_diagnostic_setting.ui[0]',
        'azurerm_app_service_virtual_network_swift_connection.ui',
        'azurerm_app_service_virtual_network_swift_connection.ui[0]',
        'azurerm_linux_web_app.ui',
        'azurerm_linux_web_app.ui[0]',
        'azurerm_user_assigned_identity.ui',
        'azurerm_user_assigned_identity.ui[0]'
    ) -TrackedAddresses $trackedAddresses
}

$trackedAddresses = @(terraform state list 2>$null)

foreach ($import in $imports) {
    $address = $import.Address
    $resourceId = $import.Id
    $isTracked = $trackedAddresses -contains $address

    if ([string]::IsNullOrWhiteSpace($resourceId)) {
        if ($isTracked) {
            Write-Host "Missing in Azure, removing stale state: $address"
            & terraform state rm $address | Out-Null
        }

        Write-Host "No resource ID resolved, skipping: $address"
        continue
    }

    if ($isTracked) {
        $trackedId = Get-TrackedResourceId -Address $address
        if ($trackedId -eq $resourceId) {
            Write-Host "Already tracked: $address"
            continue
        }

        Write-Host "State drift detected, replacing tracked resource: $address"
        & terraform state rm $address | Out-Null
    }

    Write-Host "Importing $address"
    Write-Host "Importing $address"
    $importOutput = & terraform import '-var-file=main.tfvars.json' $address $resourceId 2>&1
    if ($LASTEXITCODE -ne 0) {
        $outputText = $importOutput | Out-String
        if ($outputText -match 'Cannot import non-existent|not found|does not exist') {
            Write-Host "Not present in Azure, skipping: $address"
            $global:LASTEXITCODE = 0
        }
        else {
            Write-Host $outputText
            throw "terraform import failed for $address"
        }
    }
}

exit 0