<#
Reproducible builds on Windows.

  .\build.ps1 check     analyze + test in the pinned Docker image (default)
  .\build.ps1 analyze
  .\build.ps1 test
  .\build.ps1 apk       Android APKs -> dist\
  .\build.ps1 shell     shell inside the build container
  .\build.ps1 image     only build the image, print its tag
  .\build.ps1 windows   Windows app -> dist\ (native; needs tool\setup-windows.ps1)

Docker commands need Docker Desktop (Linux containers, the default).
#>
param([string]$Command = 'check')

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$versionsFile = Join-Path $root 'tool\versions.env'
$dockerfile = Join-Path $root 'tool\docker\Dockerfile'
$dist = Join-Path $root 'dist'

$versions = @{}
foreach ($line in Get-Content $versionsFile) {
  if ($line -match '^\s*([A-Z_]+)=(.*)$') { $versions[$Matches[1]] = $Matches[2].Trim() }
}

function Invoke-Native {
  param([string]$Exe, [string[]]$Arguments)
  & $Exe @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed ($LASTEXITCODE)" }
}

if ($Command -eq 'windows') {
  $flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
  if (-not $flutter) { throw 'flutter not found on PATH. Run tool\setup-windows.ps1 first.' }
  $actual = (& $flutter --version --machine | ConvertFrom-Json).frameworkVersion
  if ($actual -ne $versions.FLUTTER_VERSION) {
    throw "Flutter $actual is installed but $($versions.FLUTTER_VERSION) is pinned. Run tool\setup-windows.ps1."
  }
  Push-Location $root
  try {
    Invoke-Native $flutter @('pub', 'get', '--enforce-lockfile')
    Invoke-Native $flutter @('build', 'windows', '--release')
    New-Item -ItemType Directory -Force $dist | Out-Null
    $zip = Join-Path $dist 'kurage-windows-x64.zip'
    Compress-Archive -Path 'build\windows\x64\runner\Release\*' -DestinationPath $zip -Force
    Write-Host "Built $zip"
  } finally {
    Pop-Location
  }
  exit 0
}

# Same tag as build.sh: hash of Dockerfile + versions, line endings ignored.
$text = ((Get-Content $dockerfile -Raw) + (Get-Content $versionsFile -Raw)) -replace "`r", ''
$sha = [System.Security.Cryptography.SHA256]::Create()
$bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
$hash = (-join ($bytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 12)
$image = "jellyfin-client-build:$hash"

& docker image inspect $image *> $null
if ($LASTEXITCODE -ne 0) {
  $buildArgs = foreach ($key in $versions.Keys) { '--build-arg'; "$key=$($versions[$key])" }
  Invoke-Native docker (@('build') + $buildArgs + @('-t', $image, '-f', $dockerfile, (Join-Path $root 'tool\docker')))
}

if ($Command -eq 'image') { Write-Output $image; exit 0 }

New-Item -ItemType Directory -Force $dist | Out-Null
$runArgs = @('run', '--rm')
if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) { $runArgs += '-it' }
Invoke-Native docker ($runArgs + @(
    '-v', "${root}:/repo:ro",
    '-v', "${dist}:/out",
    '-v', 'jellyfin-client-cache:/cache',
    $image, 'bash', '/repo/tool/docker/inside.sh', $Command))
