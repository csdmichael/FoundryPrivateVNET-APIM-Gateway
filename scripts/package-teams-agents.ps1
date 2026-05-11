$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$packages = @(
    @{ Name = 'Tax-PDF-Forms-Agent'; Folder = 'Agent-Packages\Tax-PDF-Forms-Agent' },
    @{ Name = 'Eng-Design-PPT-Agent'; Folder = 'Agent-Packages\Eng-Design-PPT-Agent' },
    @{ Name = 'Tax-PDF-Forms-Agent-Limited'; Folder = 'Agent-Packages\Tax-PDF-Forms-Agent-Limited' },
    @{ Name = 'Eng-Design-PPT-Agent-Limited'; Folder = 'Agent-Packages\Eng-Design-PPT-Agent-Limited' }
)

foreach ($package in $packages) {
    if (-not (Test-Path $package.Folder)) {
        Write-Warning "Skipping package '$($package.Name)' because folder '$($package.Folder)' does not exist."
        continue
    }

    $zipPath = Join-Path $package.Folder "$($package.Name).zip"
    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force
    }

    $filesToZip = @('manifest.json', 'color.png', 'outline.png', 'apiSpecificationFile.json', 'responseRenderingTemplate.json') |
        ForEach-Object { Join-Path $package.Folder $_ } |
        Where-Object { Test-Path $_ }

    if ($filesToZip.Count -eq 0) {
        Write-Warning "Skipping package '$($package.Name)' because no package files were found in '$($package.Folder)'."
        continue
    }

    Compress-Archive -Path $filesToZip -DestinationPath $zipPath
}
