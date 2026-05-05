param(
    [switch]$DetailedPlan,
    [switch]$DeployApi,
    [switch]$DeployUi,
    [switch]$SkipClone,
    [switch]$SkipApim,
    [switch]$SkipTests,
    [switch]$SkipPackage,
    [switch]$SkipTerraform
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$env:TF_VAR_deploy_api = $DeployApi.IsPresent.ToString().ToLowerInvariant()
$env:TF_VAR_deploy_ui = $DeployUi.IsPresent.ToString().ToLowerInvariant()

if (-not $SkipTerraform) {
    if (-not (Test-Path .\.terraform)) {
        terraform init
    }

    terraform validate

    if ($DetailedPlan) {
        terraform plan -var-file="main.tfvars.json" -out=tfplan
        terraform apply -auto-approve tfplan
    }
    else {
        terraform apply -auto-approve -var-file="main.tfvars.json"
    }
}

if (-not $SkipClone) {
    & "$PSScriptRoot\provision-source-use-cases.ps1"
}

if (-not $SkipApim) {
    & "$PSScriptRoot\configure-apim.ps1"
    & "$PSScriptRoot\configure-foundry-ai-gateway.ps1"
}

if (-not $SkipPackage) {
    & "$PSScriptRoot\package-teams-agents.ps1"
}

if (-not $SkipTests) {
    & "$PSScriptRoot\test-sample-prompts.ps1"
}
