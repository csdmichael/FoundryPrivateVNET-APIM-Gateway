param(
    [switch]$SkipClone,
    [switch]$SkipApim,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

terraform init
terraform validate
terraform plan -var-file="main.tfvars.json" -out=tfplan
terraform apply -auto-approve tfplan

if (-not $SkipClone) {
    & "$PSScriptRoot\provision-source-use-cases.ps1"
}

if (-not $SkipApim) {
    & "$PSScriptRoot\configure-apim.ps1"
}

& "$PSScriptRoot\package-teams-agents.ps1"

if (-not $SkipTests) {
    & "$PSScriptRoot\test-sample-prompts.ps1"
}
