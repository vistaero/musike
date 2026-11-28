param([switch]$Publish, [switch]$Run)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $taskRoot -Parent
$project = Join-Path $taskRoot 'Musike.WinUI\Musike.WinUI.csproj'
Push-Location $repoRoot
try {
    dotnet --version
    if ($LASTEXITCODE -ne 0) { throw 'Install the .NET 10 SDK, then retry.' }
    node desktop-winui/scripts/prepare.mjs
    if ($LASTEXITCODE -ne 0) { throw 'Preparing the backend failed. Run pnpm install first.' }
    if ($Publish) {
        $output = Join-Path $repoRoot 'release\Musike-WinUI-Windows-x64'
        dotnet publish $project -c Release -r win-x64 --self-contained true -o $output
        if ($LASTEXITCODE -ne 0) { throw 'WinUI publish failed.' }
        Compress-Archive -LiteralPath (Get-ChildItem -LiteralPath $output | Select-Object -ExpandProperty FullName) -DestinationPath (Join-Path $repoRoot 'release\Musike-WinUI-Windows-x64.zip') -Force
    } elseif ($Run) {
        dotnet run --project $project -c Debug -r win-x64
        if ($LASTEXITCODE -ne 0) { throw 'WinUI launch failed.' }
    } else {
        dotnet build $project -c Debug -r win-x64
        if ($LASTEXITCODE -ne 0) { throw 'WinUI build failed.' }
    }
} finally { Pop-Location }
