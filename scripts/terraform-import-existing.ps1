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

# azurecaf_name format for private endpoints: pe-{name}-{suffix}
$foundryPeName = "pe-${namePrefix}fdry-$locationSlug"
$searchPeName = "pe-${namePrefix}srch-$locationSlug"

# Look up PE IDs by target resource, fall back to name
$ErrorActionPreference = 'Continue'

$foundryPrivateEndpointId = az network private-endpoint list --resource-group $resourceGroup --query "[?privateLinkServiceConnections[0].privateLinkServiceId=='$($tfvars.foundry_account_resource_id)'].id | [0]" -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($foundryPrivateEndpointId)) {
    $foundryPrivateEndpointId = az network private-endpoint show --name $foundryPeName --resource-group $resourceGroup --query id -o tsv 2>$null
}

$searchPrivateEndpointId = az network private-endpoint list --resource-group $resourceGroup --query "[?privateLinkServiceConnections[0].privateLinkServiceId=='$searchServiceResourceId'].id | [0]" -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($searchPrivateEndpointId)) {
    $searchPrivateEndpointId = az network private-endpoint show --name $searchPeName --resource-group $resourceGroup --query id -o tsv 2>$null
}

$ErrorActionPreference = 'Stop'

# Helper: run terraform with proper argument passing so for_each addresses
# (e.g.  azurerm_linux_web_app.bot["tax_pdf_forms"]) survive PowerShell-to-
# native quoting on both Windows and Linux.
# Manually builds the Arguments string with escaped quotes, compatible with
# both Windows PowerShell 5.1 and PowerShell 7+.
function Invoke-Terraform {
    param([string[]]$Arguments)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'terraform'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $PWD.Path
    # Escape each argument: if it contains quotes or spaces, wrap in double
    # quotes with inner quotes backslash-escaped.
    $escapedArgs = foreach ($arg in $Arguments) {
        if ($arg -match '["\s]') {
            $escaped = $arg -replace '"', '\"'
            "`"$escaped`""
        } else {
            $arg
        }
    }
    $psi.Arguments = $escapedArgs -join ' '
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdOut = $proc.StandardOutput.ReadToEnd()
    $stdErr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return @{
        ExitCode = $proc.ExitCode
        StdOut   = if ($stdOut) { $stdOut.TrimEnd() } else { '' }
        StdErr   = if ($stdErr) { $stdErr.TrimEnd() } else { '' }
    }
}

function Remove-StateAddresses {
    param(
        [string[]]$Addresses,
        [string[]]$TrackedAddresses
    )

    foreach ($address in $Addresses) {
        if ($TrackedAddresses -contains $address) {
            Write-Host "Removing from state: $address"
            Invoke-Terraform -Arguments @('state', 'rm', $address) | Out-Null
        }
    }
}

function Get-TrackedResourceId {
    param(
        [string]$Address
    )

    $result = Invoke-Terraform -Arguments @('state', 'show', '-no-color', $address)
    if ($result.ExitCode -ne 0 -or -not $result.StdOut) {
        return $null
    }

    foreach ($line in ($result.StdOut -split "`n")) {
        if ($line -match '^\s*id\s*=\s*"?(.*?)"?$') {
            return $matches[1]
        }
    }

    return $null
}

function Test-StateResourceId {
    param(
        [string]$Address,
        [string]$ExpectedId
    )

    $trackedId = Get-TrackedResourceId -Address $Address
    if ([string]::IsNullOrWhiteSpace($trackedId)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedId)) {
        return $true
    }

    return $trackedId -eq $ExpectedId
}

function Invoke-VerifiedTerraformImport {
    param(
        [string]$Address,
        [string]$ResourceId,
        [int]$MaxAttempts = 2
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "Retrying import ($attempt/$MaxAttempts): $Address"
        }

        $importExitCode = 0
        $importText = ''

        $result = Invoke-Terraform -Arguments @('import', '-var-file=main.tfvars.json', $Address, $ResourceId)
        $importExitCode = $result.ExitCode
        $importText = @($result.StdOut, $result.StdErr) -join "`n"
        if ($importText) {
            $importText.TrimEnd() -split "`n" | ForEach-Object { Write-Host "  $_" }
        }

        if (Test-StateResourceId -Address $Address -ExpectedId $ResourceId) {
            return @{
                Success = $true
                MissingRemoteObject = $false
                ExitCode = $importExitCode
                Output = $importText
            }
        }

        if ($importText -match 'non-existent remote object|no object exists with the given id') {
            return @{
                Success = $false
                MissingRemoteObject = $true
                ExitCode = $importExitCode
                Output = $importText
            }
        }

        if ($attempt -lt $MaxAttempts) {
            Invoke-Terraform -Arguments @('state', 'rm', $Address) | Out-Null
        }
    }

    return @{
        Success = $false
        MissingRemoteObject = $false
        ExitCode = $importExitCode
        Output = $importText
    }
}

$imports = @(
    @{ Address = 'azurerm_log_analytics_workspace.main'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OperationalInsights/workspaces/$logAnalyticsName" },
    @{ Address = 'azurerm_subnet.appsvc_integration'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnetName/subnets/appsvc-integration" },
    @{ Address = 'azurerm_subnet.private_endpoints'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnetName/subnets/private-endpoints" },
    @{ Address = 'azurerm_private_dns_zone.foundry'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com" },
    @{ Address = 'azurerm_private_dns_zone.search'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net" },
    @{ Address = 'azurerm_private_dns_zone_virtual_network_link.foundry'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com/virtualNetworkLinks/foundry-link" },
    @{ Address = 'azurerm_private_dns_zone_virtual_network_link.search'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net/virtualNetworkLinks/search-link" },
    @{ Address = 'azurerm_private_endpoint.foundry'; Id = $foundryPrivateEndpointId },
    @{ Address = 'azurerm_private_endpoint.search'; Id = $searchPrivateEndpointId },
    @{ Address = 'azurerm_linux_web_app.bot["tax_pdf_forms"]'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/func-${namePrefix}-tax-bot-$locationSlug" },
    @{ Address = 'azapi_resource.bot_registration["tax_pdf_forms"]'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.BotService/botServices/foundry-privatevnet-tax-bot" },
    @{ Address = 'azapi_resource.bot_teams_channel["tax_pdf_forms"]'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.BotService/botServices/foundry-privatevnet-tax-bot/channels/MsTeamsChannel" },
    @{ Address = 'azurerm_linux_web_app.bot["eng_design_ppt"]'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/func-${namePrefix}-eng-bot-$locationSlug" },
    @{ Address = 'azapi_resource.bot_registration["eng_design_ppt"]'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.BotService/botServices/foundry-privatevnet-eng-bot" },
    @{ Address = 'azapi_resource.bot_teams_channel["eng_design_ppt"]'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.BotService/botServices/foundry-privatevnet-eng-bot/channels/MsTeamsChannel" }
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

Remove-StateAddresses -Addresses @(
    'azurerm_virtual_network.main',
    'azurerm_linux_web_app.bot',
    'azapi_resource.bot_registration',
    'azapi_resource.bot_teams_channel'
) -TrackedAddresses $trackedAddresses

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

$prevErrorPref = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

foreach ($import in $imports) {
    $address = $import.Address
    $resourceId = $import.Id
    $isTracked = $trackedAddresses -contains $address

    if ([string]::IsNullOrWhiteSpace($resourceId)) {
        if ($isTracked) {
            Write-Host "Missing in Azure, removing stale state: $address"
            Invoke-Terraform -Arguments @('state', 'rm', $address) | Out-Null
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
        Invoke-Terraform -Arguments @('state', 'rm', $address) | Out-Null
    }

    Write-Host "Importing $address"
    $importResult = Invoke-VerifiedTerraformImport -Address $address -ResourceId $resourceId
    if ($importResult.Success) {
        if ($importResult.ExitCode -ne 0) {
            Write-Host "  Import reported errors but resource is in state with expected ID: $address"
        }
        else {
            Write-Host "  Imported with verified state: $address"
        }

        $trackedAddresses += $address
        continue
    }

    if ($importResult.MissingRemoteObject) {
        Write-Host "  Resource does not exist in Azure, skipping (will be created by apply): $address"
        continue
    }

    $ErrorActionPreference = $prevErrorPref
    throw "terraform import failed for $address (exit code $($importResult.ExitCode))"
}

$ErrorActionPreference = $prevErrorPref

# Verify critical resources were imported
$requiredImports = @(
    @{ Address = 'azurerm_subnet.private_endpoints'; Id = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Network/virtualNetworks/$vnetName/subnets/private-endpoints" }
)
foreach ($required in $requiredImports) {
    if (-not (Test-StateResourceId -Address $required.Address -ExpectedId $required.Id)) {
        throw "Critical resource not in state after import: $($required.Address). Expected ID: $($required.Id)"
    }
}

exit 0