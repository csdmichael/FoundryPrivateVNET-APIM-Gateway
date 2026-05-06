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

    & "$PSScriptRoot\terraform-import-existing.ps1"

    terraform validate

    if ($DetailedPlan) {
        terraform plan -var-file="main.tfvars.json" -out=tfplan
        terraform apply -auto-approve tfplan
    }
    else {
        terraform apply -auto-approve -var-file="main.tfvars.json"
    }
}

# --- Parallel phase: run independent post-terraform tasks concurrently ---
$parallelJobs = @()

if (-not $SkipClone) {
    $parallelJobs += Start-Job -Name 'provision' -ScriptBlock {
        Set-Location $using:PWD
        & "$using:PSScriptRoot\provision-source-use-cases.ps1"
    }
}

if (-not $SkipApim) {
    $parallelJobs += Start-Job -Name 'apim' -ScriptBlock {
        Set-Location $using:PWD
        & "$using:PSScriptRoot\configure-apim.ps1"
        & "$using:PSScriptRoot\configure-foundry-ai-gateway.ps1"
    }
}

if (-not $SkipPackage) {
    $parallelJobs += Start-Job -Name 'package' -ScriptBlock {
        Set-Location $using:PWD
        & "$using:PSScriptRoot\package-teams-agents.ps1"
    }
}

if ($parallelJobs.Count -gt 0) {
    Write-Host "Running $($parallelJobs.Count) tasks in parallel: $($parallelJobs.Name -join ', ')"
    $parallelJobs | Wait-Job | ForEach-Object {
        Write-Host "--- [$($_.Name)] output ---"
        Receive-Job $_
        if ($_.State -eq 'Failed') {
            $failedName = $_.Name
            $parallelJobs | Remove-Job -Force
            throw "Parallel task '$failedName' failed. See output above."
        }
    }
    $parallelJobs | Remove-Job -Force
}

if (-not $SkipTests) {
    & "$PSScriptRoot\test-sample-prompts.ps1"
}
