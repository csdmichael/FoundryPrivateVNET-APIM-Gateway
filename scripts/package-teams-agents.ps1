$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$packages = @(
    @{ Name = 'Tax-PDF-Forms-Agent'; Folder = 'Agent-Packages\Tax-PDF-Forms-Agent' },
    @{ Name = 'Eng-Design-PPT-Agent'; Folder = 'Agent-Packages\Eng-Design-PPT-Agent' }
)

foreach ($package in $packages) {
    $zipPath = Join-Path $package.Folder "$($package.Name).zip"
    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $package.Folder 'manifest.json'),(Join-Path $package.Folder 'color.png'),(Join-Path $package.Folder 'outline.png') -DestinationPath $zipPath
}
