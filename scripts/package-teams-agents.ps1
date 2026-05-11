$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$packages = @(
    @{ Name = 'Tax-PDF-Forms-Agent'; Folder = 'Agent-Packages\Tax-PDF-Forms-Agent' },
    @{ Name = 'Eng-Design-PPT-Agent'; Folder = 'Agent-Packages\Eng-Design-PPT-Agent' },
    @{ Name = 'Tax-PDF-Forms-Agent-Limited'; Folder = 'Agent-Packages\Tax-PDF-Forms-Agent-Limited' },
    @{ Name = 'Eng-Design-PPT-Agent-Limited'; Folder = 'Agent-Packages\Eng-Design-PPT-Agent-Limited' }
)

foreach ($package in $packages) {
    $zipPath = Join-Path $package.Folder "$($package.Name).zip"
    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $package.Folder 'manifest.json'),(Join-Path $package.Folder 'color.png'),(Join-Path $package.Folder 'outline.png'),(Join-Path $package.Folder 'apiSpecificationFile.json'),(Join-Path $package.Folder 'responseRenderingTemplate.json') -DestinationPath $zipPath
}
