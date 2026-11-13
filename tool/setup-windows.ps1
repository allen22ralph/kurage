<#
Sets up a Windows machine to build the Windows app with the pinned toolchain:

  - Visual Studio 2022 Build Tools with the components in tool\windows\.vsconfig
    (C++ tools, CMake, ATL for flutter_secure_storage, Windows 11 SDK)
  - Flutter at the version in tool\versions.env, cloned to -FlutterDir
    and added to the user PATH

Safe to re-run: it only installs or changes what's missing or different.
Visual Studio asks for admin rights when it installs or modifies components.

  .\tool\setup-windows.ps1 [-FlutterDir C:\path\to\flutter]
#>
param([string]$FlutterDir = (Join-Path $env:USERPROFILE 'flutter'))

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$vsconfig = Join-Path $PSScriptRoot 'windows\.vsconfig'
$pinned = (Get-Content (Join-Path $PSScriptRoot 'versions.env') |
  Where-Object { $_ -match '^FLUTTER_VERSION=' }) -replace '^FLUTTER_VERSION=', ''

# --- Visual Studio Build Tools -------------------------------------------
$installer = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
$vswhere = Join-Path $installer 'vswhere.exe'
$components = (Get-Content $vsconfig -Raw | ConvertFrom-Json).components |
  Where-Object { $_ -notlike '*.Workload.*' }

function Find-BuildTools {
  if (-not (Test-Path $vswhere)) { return $null }
  & $vswhere -version '[17.0,18.0)' -products '*' -property installationPath |
    Select-Object -First 1
}

$vsPath = Find-BuildTools
if (-not $vsPath) {
  Write-Host 'Installing Visual Studio 2022 Build Tools...'
  winget install --id Microsoft.VisualStudio.2022.BuildTools -e `
    --accept-source-agreements --accept-package-agreements `
    --override "--passive --wait --config `"$vsconfig`""
  $vsPath = Find-BuildTools
  if (-not $vsPath) { throw 'Visual Studio Build Tools installation failed.' }
} else {
  $missing = $components | Where-Object {
    -not (& $vswhere -path $vsPath -requires $_ -property installationPath)
  }
  if ($missing) {
    Write-Host "Adding Visual Studio components: $($missing -join ', ')"
    $p = Start-Process -FilePath (Join-Path $installer 'setup.exe') -Verb RunAs -Wait -PassThru `
      -ArgumentList @('modify', '--installPath', "`"$vsPath`"", '--config', "`"$vsconfig`"",
        '--passive', '--norestart')
    if ($p.ExitCode -notin 0, 3010) { throw "Visual Studio modify failed ($($p.ExitCode))." }
  }
}
Write-Host "Visual Studio Build Tools: $vsPath"

# --- Flutter -------------------------------------------------------------
if (-not (Test-Path (Join-Path $FlutterDir 'bin\flutter.bat'))) {
  Write-Host "Cloning Flutter $pinned to $FlutterDir..."
  git clone --branch $pinned https://github.com/flutter/flutter.git $FlutterDir
  if ($LASTEXITCODE -ne 0) { throw 'git clone failed.' }
} else {
  $current = git -C $FlutterDir describe --tags --exact-match 2>$null
  if ($current -ne $pinned) {
    Write-Host "Switching Flutter $current -> $pinned..."
    git -C $FlutterDir fetch --tags origin
    git -C $FlutterDir checkout --quiet $pinned
    if ($LASTEXITCODE -ne 0) { throw "Could not check out Flutter $pinned." }
  }
}

$bin = Join-Path $FlutterDir 'bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $bin) {
  [Environment]::SetEnvironmentVariable('Path', "$bin;$userPath", 'User')
  Write-Host "Added $bin to your PATH (open a new terminal to pick it up)."
}
$env:Path = "$bin;$env:Path"

& (Join-Path $bin 'flutter.bat') --version
Push-Location $repo
try { & (Join-Path $bin 'flutter.bat') pub get --enforce-lockfile } finally { Pop-Location }
Write-Host "`nReady. Build with: .\build.ps1 windows"
