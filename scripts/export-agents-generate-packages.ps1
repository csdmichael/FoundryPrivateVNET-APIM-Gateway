<#
.SYNOPSIS
    Export agents from Azure AI Foundry and generate Teams agent packages.

.DESCRIPTION
    1. Connects to the Foundry project and lists agents by name.
    2. Exports each agent's config (model, instructions, tools, search index).
    3. Generates the full Teams agent package folder (manifest.json,
       apiSpecificationFile.json, responseRenderingTemplate.json).
    4. Zips each package ready for sideloading into Teams.

.PARAMETER PackageOnly
    Skip the Foundry export step and regenerate packages from existing config files only.
#>
param(
    [switch]$PackageOnly
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

# ── Load config ──────────────────────────────────────────────────────────────
$azureResources  = Get-Content .\config\azure_resources.json  | ConvertFrom-Json
$agentConfig     = Get-Content .\config\agent_config.json     | ConvertFrom-Json
$promptsConfig   = Get-Content .\config\prompts_config.json   | ConvertFrom-Json
$tfvars          = Get-Content .\main.tfvars.json             | ConvertFrom-Json

$projectEndpoint = $azureResources.foundry.project_endpoint
$apimGatewayUrl  = $azureResources.apim.gateway_url
$apimApiPath     = $azureResources.apim.api_path
$githubBaseUrl   = "https://github.com/csdmichael/FoundryPrivateVNET-APIM-Gateway/blob/main/docs"

# Map use-case keys to package definitions
$useCases = @{
    tax_pdf_forms = @{
        AgentName      = $agentConfig.use_cases.tax_pdf_forms.agent.name
        PackageDir     = 'Agent-Packages\Tax-PDF-Forms-Agent'
        BotAppId       = $tfvars.tax_bot_app_id
        ManifestId     = '3d33b58f-6c93-48c4-b8b6-6da36fd8d111'
        ShortName      = 'Tax PDF Forms Agent'
        FullName       = 'Tax PDF Forms Agent via APIM'
        ShortDesc      = 'Foundry agent package for tax PDF forms.'
        FullDesc       = 'Teams package for the Tax PDF Forms agent routed through Azure API Management.'
        AccentColor    = '#0F6CBD'
        Disclaimer     = 'Answers are grounded in the configured tax PDF documents and may reflect deployment-time search data.'
        TopicLabel     = 'tax PDF forms'
        ApiTitle       = 'Tax PDF Forms Agent'
        ApiDescription = 'Chat with the Tax PDF Forms agent via Azure API Management and a private Azure AI Foundry deployment.'
        ApiSummary     = 'Ask a question about tax PDF forms'
        ApiOpDesc      = 'Submit a prompt to the Tax PDF Forms agent and return a grounded response from the configured private Foundry workflow.'
        ParamDesc      = 'Your question about tax PDF forms'
    }
    eng_design_ppt = @{
        AgentName      = $agentConfig.use_cases.eng_design_ppt.agent.name
        PackageDir     = 'Agent-Packages\Eng-Design-PPT-Agent'
        BotAppId       = $tfvars.eng_bot_app_id
        ManifestId     = '2f3f3c91-1f4f-4c0f-b40c-1b6f6f1b1222'
        ShortName      = 'Eng Design PPT Agent'
        FullName       = 'Engineering Design PPT Agent via APIM'
        ShortDesc      = 'Foundry agent package for engineering design presentations.'
        FullDesc       = 'Teams package for the Engineering Design PPT agent routed through Azure API Management.'
        AccentColor    = '#0F6CBD'
        Disclaimer     = 'Answers are grounded in the configured engineering presentation documents and may reflect deployment-time search data.'
        TopicLabel     = 'engineering design presentations'
        ApiTitle       = 'Engineering Design PPT Agent'
        ApiDescription = 'Chat with the Engineering Design PPT agent via Azure API Management and a private Azure AI Foundry deployment.'
        ApiSummary     = 'Ask a question about engineering design presentations'
        ApiOpDesc      = 'Submit a prompt to the Engineering Design PPT agent and return a grounded response from the configured private Foundry workflow.'
        ParamDesc      = 'Your question about engineering design presentations'
    }
}

# ── Export agents from Foundry ───────────────────────────────────────────────
$exportedAgents = @{}

if (-not $PackageOnly) {
    Write-Host "`n=== Exporting agents from Foundry ===" -ForegroundColor Cyan

    # Route through APIM gateway when configured, unless FOUNDRY_DIRECT=1
    $agentsApiPath = $azureResources.apim.foundry_agents_api_path
    $useDirect = ($env:FOUNDRY_DIRECT -eq '1') -or (-not $agentsApiPath)
    if ($useDirect) {
        $agentEndpoint = $projectEndpoint
        Write-Host "Endpoint (direct): $agentEndpoint"
    }
    else {
        $projectSuffix = ($projectEndpoint -split '\.services\.ai\.azure\.com', 2)[1]
        $agentEndpoint = "$apimGatewayUrl/$agentsApiPath$projectSuffix"
        Write-Host "Endpoint (via APIM): $agentEndpoint"
    }

    # When routing via APIM, managed identity handles Foundry auth — no caller token needed.
    # When calling Foundry directly, a bearer token with audience https://ai.azure.com is required.
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($useDirect) {
        $token = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
        if ($LASTEXITCODE -ne 0) { throw "Failed to get Azure access token. Run 'az login' first." }
        $headers['Authorization'] = "Bearer $token"
    }

    # List agents via Foundry Assistants REST API
    $listUrl = "$agentEndpoint/assistants?api-version=2025-05-01"

    Write-Host "Fetching agent list..."
    $response = Invoke-RestMethod -Uri $listUrl -Headers $headers -Method Get
    $agents = $response.data
    if (-not $agents) { $agents = @($response) }

    Write-Host "Found $($agents.Count) agent(s) in Foundry project."

    foreach ($ucKey in $useCases.Keys) {
        $uc = $useCases[$ucKey]
        $agentName = $uc.AgentName
        $matched = $agents | Where-Object { $_.name -eq $agentName } | Select-Object -First 1

        if (-not $matched) {
            Write-Warning "Agent '$agentName' not found in Foundry. Will generate package from config only."
            continue
        }

        Write-Host "Exported agent: $agentName (id=$($matched.id), model=$($matched.model))"
        $exportedAgents[$ucKey] = @{
            Id           = $matched.id
            Name         = $matched.name
            Model        = $matched.model
            Instructions = $matched.instructions
            Tools        = $matched.tools
            ToolResources = $matched.tool_resources
            Temperature  = $matched.temperature
        }
    }

    # Save raw exports for reference
    $exportDir = 'Agent-Packages\.exports'
    New-Item -ItemType Directory -Force -Path $exportDir | Out-Null
    $exportedAgents | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $exportDir 'foundry-agents-export.json') -Encoding UTF8
    Write-Host "Raw exports saved to $exportDir\foundry-agents-export.json"
}
else {
    Write-Host "`n=== PackageOnly mode: skipping Foundry export ===" -ForegroundColor Yellow
}

# ── Generate Teams agent packages ────────────────────────────────────────────
Write-Host "`n=== Generating Teams agent packages ===" -ForegroundColor Cyan

# Determine current version by reading existing manifest, or default to 1.0.0
function Get-NextVersion([string]$manifestPath) {
    if (Test-Path $manifestPath) {
        $existing = Get-Content $manifestPath | ConvertFrom-Json
        $parts = $existing.version -split '\.'
        $parts[2] = [int]$parts[2] + 1
        return $parts -join '.'
    }
    return '1.0.0'
}

foreach ($ucKey in $useCases.Keys) {
    $uc = $useCases[$ucKey]
    $pkgDir = $uc.PackageDir

    Write-Host "`nGenerating package: $($uc.ShortName)"
    Write-Host "  Directory: $pkgDir"

    New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null

    $manifestPath = Join-Path $pkgDir 'manifest.json'
    $nextVersion = Get-NextVersion $manifestPath

    # If we exported the agent, use its instructions for the disclaimer
    $exported = $exportedAgents[$ucKey]
    if ($exported) {
        Write-Host "  Using exported agent config (model=$($exported.Model))"
    }

    # ── Bot prompt commands from prompts_config ──────────────────────────
    $agentPrompts = $promptsConfig.use_cases.$ucKey.agent
    $botCommands = @(
        @{ title = 'Ask'; description = "Ask a question about $($uc.TopicLabel)" }
    )
    # Pick up to 5 prompts for bot commands
    $cmdPrompts = @($agentPrompts | Select-Object -First 5)
    foreach ($p in $cmdPrompts) {
        $words = $p.text -split '\s+' | Select-Object -First 4
        $title = ($words -join ' ')
        if ($title.Length -gt 32) { $title = $title.Substring(0, 29) + '...' }
        $desc = ($p.text -split '[.?]' | Select-Object -First 1).Trim()
        if ($desc.Length -gt 128) { $desc = $desc.Substring(0, 125) + '...' }
        $promptText = $p.text
        if ($promptText.Length -gt 128) { $promptText = $promptText.Substring(0, 125) + '...' }
        $botCommands += @{
            title       = $title
            description = $desc
            type        = 'prompt'
            prompt      = $promptText
        }
    }

    # ── Compose extension sample prompts ─────────────────────────────────
    $samplePrompts = @($agentPrompts | Select-Object -First 5 | ForEach-Object {
        $t = $_.text; if ($t.Length -gt 128) { $t = $t.Substring(0, 125) + '...' }
        @{ text = $t }
    })

    # ── manifest.json ────────────────────────────────────────────────────
    $manifest = [ordered]@{
        '$schema'        = 'https://developer.microsoft.com/json-schemas/teams/vDevPreview/MicrosoftTeams.schema.json'
        manifestVersion  = 'devPreview'
        version          = $nextVersion
        id               = $uc.ManifestId
        name             = [ordered]@{ short = $uc.ShortName; full = $uc.FullName }
        developer        = [ordered]@{
            name          = 'Michael Yaacoub at Microsoft'
            websiteUrl    = "$githubBaseUrl/support.md"
            privacyUrl    = "$githubBaseUrl/privacy-policy.md"
            termsOfUseUrl = "$githubBaseUrl/terms-of-use.md"
        }
        description      = [ordered]@{ short = $uc.ShortDesc; full = $uc.FullDesc }
        icons            = [ordered]@{ outline = 'outline.png'; color = 'color.png' }
        accentColor      = $uc.AccentColor
        bots             = @(
            [ordered]@{
                botId            = $uc.BotAppId
                supportsSessions = $true
                scopes           = @('personal', 'team', 'groupChat', 'copilot')
                commandLists     = @(
                    [ordered]@{
                        scopes   = @('personal', 'copilot')
                        commands = $botCommands
                    }
                )
            }
        )
        copilotAgents    = [ordered]@{
            customEngineAgents = @(
                [ordered]@{
                    id         = $uc.BotAppId
                    type       = 'bot'
                    disclaimer = [ordered]@{ text = $uc.Disclaimer }
                }
            )
        }
        composeExtensions = @(
            [ordered]@{
                composeExtensionType             = 'apiBased'
                apiSpecificationFile             = 'apiSpecificationFile.json'
                commands = @(
                    [ordered]@{
                        id                              = 'chatWithAgent'
                        type                            = 'query'
                        title                           = "Ask $($uc.ShortName -replace ' Agent$','')"
                        description                     = "Ask a question about $($uc.TopicLabel)"
                        samplePrompts                   = $samplePrompts
                        initialRun                      = $false
                        apiResponseRenderingTemplateFile = 'responseRenderingTemplate.json'
                        parameters = @(
                            [ordered]@{
                                name        = 'prompt'
                                title       = 'Question'
                                description = $uc.ParamDesc
                                inputType   = 'text'
                            }
                        )
                    }
                )
            }
        )
        permissions      = @('identity', 'messageTeamMembers')
        validDomains     = @(([uri]$apimGatewayUrl).Host)
    }

    $manifest | ConvertTo-Json -Depth 15 | Set-Content $manifestPath -Encoding UTF8
    Write-Host "  Created manifest.json (v$nextVersion)"

    # ── apiSpecificationFile.json ────────────────────────────────────────
    $apiSpec = [ordered]@{
        openapi = '3.0.1'
        info    = [ordered]@{
            title       = $uc.ApiTitle
            version     = $nextVersion
            description = $uc.ApiDescription
            contact     = [ordered]@{
                name = 'Foundry Private VNET APIM Gateway'
                url  = "$githubBaseUrl/support.md"
            }
        }
        'x-security-controls' = [ordered]@{
            rateLimiting    = [ordered]@{
                strategy                  = 'Handled by Azure API Management policies and upstream gateway throttling.'
                ipBasedThrottling         = $true
                subscriptionOrUserRateLimits = $true
                spikeArrest               = $true
                payloadSizeLimitKb        = 64
                accountRecoveryThresholds = [ordered]@{ maxAttempts = 5; windowSeconds = 300 }
            }
            inputValidation = [ordered]@{
                strategy                  = 'The API accepts a single prompt field and rejects malformed payloads through APIM policy and backend validation.'
                contentTypeEnforcement    = $true
                headerValidation          = $true
                schemaValidationAtGateway = $true
                wafProtection             = $true
            }
            errorHandling   = [ordered]@{
                strategy                       = 'Errors are normalized by the gateway and backend response shaping before being returned to the Teams client.'
                genericExternalErrors          = $true
                secureLogStorage               = $true
                structuredLoggingToLogAnalytics = $true
            }
        }
        servers = @( [ordered]@{ url = "$apimGatewayUrl/$apimApiPath" } )
        paths   = [ordered]@{
            '/chat' = [ordered]@{
                post = [ordered]@{
                    operationId = 'chatWithAgent'
                    summary     = $uc.ApiSummary
                    description = $uc.ApiOpDesc
                    requestBody = [ordered]@{
                        required = $true
                        content  = [ordered]@{
                            'application/json' = [ordered]@{
                                schema = [ordered]@{
                                    type       = 'object'
                                    required   = @('prompt')
                                    properties = [ordered]@{
                                        prompt = [ordered]@{
                                            type        = 'string'
                                            description = $uc.ParamDesc
                                        }
                                    }
                                }
                            }
                        }
                    }
                    responses = [ordered]@{
                        '200' = [ordered]@{
                            description = 'Agent response'
                            content     = [ordered]@{
                                'application/json' = [ordered]@{
                                    schema = [ordered]@{
                                        type       = 'object'
                                        properties = [ordered]@{
                                            response = [ordered]@{ type = 'string'; description = 'The agent answer' }
                                            use_case = [ordered]@{ type = 'string' }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    $apiSpec | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $pkgDir 'apiSpecificationFile.json') -Encoding UTF8
    Write-Host "  Created apiSpecificationFile.json"

    # ── responseRenderingTemplate.json ───────────────────────────────────
    $renderTemplate = [ordered]@{
        version              = 'devPreview'
        jsonPath             = '$'
        responseLayout       = 'list'
        responseCardTemplate = [ordered]@{
            type      = 'AdaptiveCard'
            '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
            version   = '1.5'
            body      = @(
                [ordered]@{ type = 'TextBlock'; text = '${response}'; wrap = $true }
            )
        }
        previewCardTemplate  = [ordered]@{
            title = $uc.ShortName
            text  = '${response}'
        }
    }

    $renderTemplate | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $pkgDir 'responseRenderingTemplate.json') -Encoding UTF8
    Write-Host "  Created responseRenderingTemplate.json"

    # ── Ensure icon files exist ──────────────────────────────────────────
    foreach ($icon in @('color.png', 'outline.png')) {
        $iconPath = Join-Path $pkgDir $icon
        if (-not (Test-Path $iconPath)) {
            Write-Warning "  Missing icon: $iconPath — package will be incomplete."
        }
    }

    # ── Zip the package ──────────────────────────────────────────────────
    $zipName = "$($uc.AgentName).zip"
    $zipPath = Join-Path $pkgDir $zipName
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    $filesToZip = @('manifest.json', 'color.png', 'outline.png', 'apiSpecificationFile.json', 'responseRenderingTemplate.json') |
        ForEach-Object { Join-Path $pkgDir $_ } |
        Where-Object { Test-Path $_ }

    Compress-Archive -Path $filesToZip -DestinationPath $zipPath
    Write-Host "  Packaged: $zipPath" -ForegroundColor Green
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
if ($exportedAgents.Count -gt 0) {
    Write-Host "Exported $($exportedAgents.Count) agent(s) from Foundry."
}
foreach ($ucKey in $useCases.Keys) {
    $uc = $useCases[$ucKey]
    $zip = Join-Path $uc.PackageDir "$($uc.AgentName).zip"
    if (Test-Path $zip) {
        $size = [math]::Round((Get-Item $zip).Length / 1KB, 1)
        Write-Host ('  [{0}] {1} ({2} KB)' -f $ucKey, $zip, $size)
    }
}
Write-Host ''
Write-Host 'Upload the .zip files to Teams Admin Center or sideload in Teams Developer Portal.'
