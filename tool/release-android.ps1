# Signs a release's Android APKs with your own key and publishes it (the
# app's updater reads the releases of this same repository).
#
# CI builds a tag (v1.2.3) as a *draft* release whose APKs carry a throwaway
# key. Run this on your PC to re-sign them with the release keystore (which
# never leaves this machine; the password is asked for, not stored), upload
# them back, and publish the release.
#
#   pwsh tool/release-android.ps1 v0.1.0
#   pwsh tool/release-android.ps1 v0.1.0 -Keystore D:\keys\jfc.jks
#   pwsh tool/release-android.ps1 v0.1.0 -MirrorOnly   (already published:
#                                                       only copy it there)
#
# Create the keystore once (keep it and its password backed up: every later
# update must be signed with the same key, or it won't install over the old):
#   & "$env:LOCALAPPDATA\Android\jdk-17\bin\keytool.exe" -genkeypair -v `
#     -keystore "$HOME\kurage-release.jks" -alias kurage -dname "CN=Kurage" `
#     -keyalg RSA -keysize 4096 -validity 10000
param(
  [Parameter(Mandatory)] [string] $Tag,
  [string] $Keystore = "$HOME\kurage-release.jks",
  [string] $Alias = 'kurage',
  [string] $Repo = 'allen22ralph/kurage',
  # Another repository to copy each release to, if any (none: the app reads
  # this one's releases).
  [string] $PublicRepo = '',
  [switch] $MirrorOnly,
  [string] $BuildTools = "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.0.0"
)
$ErrorActionPreference = 'Stop'
# gh writes UTF-8; read as the console's old code page, the notes copied to
# the public repo turned "–" into "Γçô" (and • … the same way).
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$apksigner = Join-Path $BuildTools 'apksigner.bat'
if (-not (Test-Path $apksigner)) { throw "apksigner not found in $BuildTools (sdkmanager `"build-tools;36.0.0`")" }
if (-not (Test-Path $Keystore)) { throw "Keystore not found: $Keystore (see the keytool command at the top of this script)" }
if (-not $env:JAVA_HOME) { $env:JAVA_HOME = "$env:LOCALAPPDATA\Android\jdk-17" }

$json = gh release view $Tag --repo $Repo --json isDraft,assets 2>$null
if ($LASTEXITCODE -ne 0 -or -not $json) {
  # No release yet: CI makes the draft when it has built the tag.
  $run = gh run list --repo $Repo --branch $Tag --limit 1 --json status,conclusion,url | ConvertFrom-Json | Select-Object -First 1
  if ($run -and $run.status -ne 'completed') { throw "No release for $Tag yet: CI is still building it ($($run.url)). Run this again when it's done." }
  if ($run) { throw "No release for $Tag, and its CI run ended '$($run.conclusion)': $($run.url)" }
  throw "No release for $Tag. Is the tag pushed? (git push origin $Tag)"
}
$release = $json | ConvertFrom-Json

$work = Join-Path ([IO.Path]::GetTempPath()) "kurage-release-$Tag"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory $work | Out-Null

# The same tag, notes, beta flag and files in the public releases repo.
function Copy-ToPublicRepo {
  if (-not $PublicRepo) { return }
  $info = gh release view $Tag --repo $Repo --json name,body,isPrerelease | ConvertFrom-Json
  gh release download $Tag --repo $Repo --pattern '*.zip' --pattern '*.apk' --dir $work --skip-existing
  $files = @((Get-ChildItem $work -File | Where-Object { $_.Extension -in '.apk', '.zip' }).FullName)
  $notes = Join-Path $work 'notes.md'
  Set-Content -LiteralPath $notes -Value $info.body -Encoding utf8
  gh release view $Tag --repo $PublicRepo *> $null
  if ($LASTEXITCODE -eq 0) {
    gh release upload $Tag --repo $PublicRepo --clobber @files
  } else {
    $create = @('release', 'create', $Tag, '--repo', $PublicRepo, '--title', $info.name, '--notes-file', $notes)
    if ($info.isPrerelease) { $create += '--prerelease' }
    gh @create @files
  }
  if ($LASTEXITCODE -ne 0) { throw "Copying $Tag to $PublicRepo failed (does the repo exist, with a first commit?)" }
  Write-Host "Copied $Tag to $PublicRepo (the app's updates)"
}

if (-not $release.isDraft) {
  if (-not $MirrorOnly) { throw "$Tag is already published. To only copy it to $PublicRepo, add -MirrorOnly." }
  Copy-ToPublicRepo
  Remove-Item -Recurse -Force $work
  return
}
gh release download $Tag --repo $Repo --pattern '*.apk' --dir $work
$apks = Get-ChildItem $work -Filter '*.apk'
if (-not $apks) { throw "No APKs on $Tag" }

$password = Read-Host "Password for $Keystore" -AsSecureString
$env:JFC_KEYSTORE_PASS = [Net.NetworkCredential]::new('', $password).Password
try {
  foreach ($apk in $apks) {
    Write-Host "Signing $($apk.Name)"
    & $apksigner sign --ks $Keystore --ks-key-alias $Alias `
      --ks-pass env:JFC_KEYSTORE_PASS --key-pass env:JFC_KEYSTORE_PASS `
      --v4-signing-enabled false $apk.FullName
    if ($LASTEXITCODE -ne 0) { throw "Signing $($apk.Name) failed" }
  }
} finally {
  Remove-Item Env:JFC_KEYSTORE_PASS -ErrorAction SilentlyContinue
}

# Show which certificate they now carry (the same for every release).
& $apksigner verify --print-certs $apks[0].FullName | Select-String 'SHA-256'

# Replacing a file deletes it first: on a poor connection the upload could
# fail after that, leaving the release without its APKs. Check they all
# arrived (once more if not) before publishing.
function Get-MissingApks {
  $names = @(gh release view $Tag --repo $Repo --json assets --jq '.assets[].name')
  @($apks | Where-Object { $_.Name -notin $names })
}
gh release upload $Tag --repo $Repo --clobber @($apks.FullName)
$missing = Get-MissingApks
if ($missing) {
  Write-Host "Uploading again: $($missing.Name -join ', ')"
  gh release upload $Tag --repo $Repo --clobber @($missing.FullName)
  $missing = Get-MissingApks
}
if ($missing) { throw "Not uploaded: $($missing.Name -join ', '). $Tag is still a draft; run this again." }
gh release edit $Tag --repo $Repo --draft=false
Write-Host "Published $Tag"
Copy-ToPublicRepo
Remove-Item -Recurse -Force $work
