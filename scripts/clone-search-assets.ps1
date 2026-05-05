$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

& "$PSScriptRoot\provision-source-use-cases.ps1" -SearchOnly
