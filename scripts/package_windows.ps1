# Build the Windows installers from a finished Flutter bundle.
#
#   scripts/package_windows.ps1 -Bundle <dir> -Version <x.y.z> -Out <dir>
#
# Produces both installer formats the project ships:
#   imagyn-<version>-windows-x64-setup.exe   Inno Setup
#   imagyn-<version>-windows-x64.msi         WiX
#
# Only x64: Flutter has no 32-bit Windows embedder (TargetPlatform lists
# windows_x64 and windows_arm64 and nothing else), so there is no x86 build to
# package. Requires the Inno Setup compiler (ISCC.exe) and WiX v5 or newer
# (`dotnet tool install --global wix`).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Bundle,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

if (-not (Test-Path (Join-Path $Bundle 'imagyn.exe'))) {
    throw "no imagyn.exe in $Bundle"
}
$icon = Join-Path $root 'platform\icons\imagyn.ico'
if (-not (Test-Path $icon)) {
    throw "$icon is missing; run scripts/make_icons.sh first"
}
$license = Join-Path $root 'LICENSE'
if (-not (Test-Path $license)) {
    throw "$license is missing"
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# Inno Setup resolves `Source` and `OutputDir` relative to the .iss file's own
# directory, and WiX's `$(SourceDir)` behaves the same way, so a relative path
# makes the packaging look under packaging/windows/build/... and fail. Pin both
# to absolute paths now that the output directory exists.
$Out = (Resolve-Path -LiteralPath $Out).Path
$Bundle = (Resolve-Path -LiteralPath $Bundle).Path

# --- EXE installer (Inno Setup) ----------------------------------------------
$iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
}
if (-not $iscc) {
    throw "ISCC.exe not found; install Inno Setup 6"
}

# ArchitecturesAllowed=x64compatible needs Inno Setup 6.3 or newer. An older
# compiler fails on that line with a parse error, so say so up front instead.
$innoVersion = $null
try { $innoVersion = [version](Get-Item $iscc).VersionInfo.ProductVersion } catch { }
if ($innoVersion -and $innoVersion -lt [version]'6.3') {
    throw "Inno Setup 6.3 or newer is required for the x64compatible architecture identifier, found $innoVersion"
}

& $iscc `
    "/DVersion=$Version" `
    "/DSourceDir=$Bundle" `
    "/DOutputDir=$Out" `
    "/DLicenseFile=$license" `
    "/DIconFile=$icon" `
    (Join-Path $root 'packaging\windows\imagyn.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }

# --- MSI (WiX v5+) -----------------------------------------------------------
$msi = Join-Path $Out "imagyn-$Version-windows-x64.msi"
& wix build -arch x64 `
    -d "Version=$Version" `
    -d "SourceDir=$Bundle" `
    -d "IconFile=$icon" `
    -o $msi `
    (Join-Path $root 'packaging\windows\Imagyn.wxs')
if ($LASTEXITCODE -ne 0) { throw "wix build failed with exit code $LASTEXITCODE" }

Get-ChildItem $Out | ForEach-Object { Write-Host "package_windows: $($_.Name)" }
