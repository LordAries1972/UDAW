<#
  package-release.ps1 - publish a UDAW build as an over-the-air update.

  Usage (after a Release build):
    powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Config Release
    powershell -ExecutionPolicy Bypass -File scripts\package-release.ps1

  Produces, in the local web root (F:\Projects\Web\EffectualDesigns):
    cgi-bin\udaw-update-win64.zip   the update package (served by udaw-download.php)
    udaw-version-win64.json         the HMAC-signed manifest UDAW.Update reads:
        { platform, version, generated, package, sha256, exe_sha256, sig }
        sig = HMAC-SHA256(version|platform|package|sha256|exe_sha256, key)
      sha256     = SHA-256 of the ZIP (verified before extracting)
      exe_sha256 = SHA-256 of UDAW.exe inside it (the online anti-piracy
                   checksum every running copy of this exact build is
                   compared against at startup)

  A copy of the ZIP is also kept in the repository's releases\ folder as
  udaw-update-win64-<version>.zip (one file per version, never overwritten by
  a different version).

  The package also carries the repository's Plugins\ and scripts\ folders
  (Python caches, Plugins\prof and this script - it holds the signing key - are
  left out).

  Nothing here uploads anything: the two files must still be uploaded to
  ultimanium.com by FTP (cgi-bin\ file into cgi-bin\, the .json into the site
  root) before running copies see the update.
#>
[CmdletBinding()]
param(
    [string]$BinDir = 'build\bin',
    [string]$WebRoot = 'F:\Projects\Web\EffectualDesigns',
    # Must equal MyGlobals::SYSTEM_ACCESS_KEY (constants.php) and
    # UDAW_SYSTEM_ACCESS_KEY (src\web\UDAW.Licensing.pas).
    [string]$SigningKey = 'UD_S3CR3T_2026!xZ9#qLmP'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

foreach ($f in 'UDAW.exe', 'UDAWUpdater.exe') {
    if (-not (Test-Path (Join-Path $BinDir $f))) { throw "$f not found in $BinDir - build first." }
}

# Refuse to publish anything but a Release build. Debug compiles out the
# {$IFDEF RELEASE} block in UDAW.dpr that installs a newer published build and
# restarts, so an install that took a Debug package could never auto-update
# again. 'Re-checking for updates...' is a string literal that only exists
# inside that block, so its presence proves RELEASE was defined.
$exeBytes = [IO.File]::ReadAllBytes((Join-Path $BinDir 'UDAW.exe'))
$marker = [Text.Encoding]::Unicode.GetBytes('Re-checking for updates...')
$exeText = [BitConverter]::ToString($exeBytes)
if (-not $exeText.Contains([BitConverter]::ToString($marker))) {
    throw "UDAW.exe in $BinDir is not a Release build (RELEASE not defined) - rebuild with scriptsuild.ps1 -Config Release. Publishing it would stop installs from auto-updating."
}

$rc = Get-Content -Raw 'resources\UDAW.rc'
$m = [regex]::Match($rc, 'FILEVERSION\s+(\d+),(\d+),(\d+),(\d+)')
if (-not $m.Success) { throw 'Could not read FILEVERSION from resources\UDAW.rc' }
$version = '{0}.{1}.{2}.{3}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[4].Value

# ---- stage exactly what the updater should copy over an install ----------
$stage = Join-Path ([IO.Path]::GetTempPath()) ('udaw-package-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    foreach ($f in 'UDAW.exe', 'UDAWUpdater.exe', 'udaw-icon-image.png', 'about-udaw.dat', 'udaw-license.dat', 'LICENSE.md') {
        $src = Join-Path $BinDir $f
        if (Test-Path $src) { Copy-Item $src $stage }
    }
    Get-ChildItem $BinDir -Filter '*.dll' -File | Copy-Item -Destination $stage
    if (Test-Path (Join-Path $BinDir 'resources')) {
        Copy-Item (Join-Path $BinDir 'resources') (Join-Path $stage 'resources') -Recurse
    }

    # Plugins\ and scripts\ ship with every package, taken from the repository so the package never
    # depends on what a previous run left in the bin folder. Left out: Python caches (__pycache__,
    # *.pyc), the profiler's output (Plugins\prof) and scripts\package-release.ps1 itself, which
    # holds the manifest signing key and must never reach a user's machine.
    function Copy-ShippedFolder([string]$Name, [string[]]$Skip) {
        $srcDir = Join-Path $root $Name
        if (-not (Test-Path $srcDir)) { throw "$Name\ not found at $srcDir - it must ship with every package." }
        $srcFull = (Resolve-Path $srcDir).Path.TrimEnd('\') + '\'
        $count = 0
        foreach ($f in Get-ChildItem $srcDir -Recurse -File) {
            $rel = $f.FullName.Substring($srcFull.Length)
            if (@($rel.Split('\') | Where-Object { $_ -ieq '__pycache__' }).Count -gt 0) { continue }
            if ($f.Extension -ieq '.pyc') { continue }
            if ($Skip -icontains $rel) { continue }
            $dest = Join-Path (Join-Path $stage $Name) $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            Copy-Item $f.FullName $dest
            $count++
        }
        if ($count -eq 0) { throw "$Name\ held nothing to ship." }
        Write-Host "    shipping $Name\ ($count files)"
    }
    Copy-ShippedFolder 'Plugins' @('prof')
    Copy-ShippedFolder 'scripts' @('package-release.ps1')

    $exeSha = (Get-FileHash (Join-Path $stage 'UDAW.exe') -Algorithm SHA256).Hash.ToLower()

    # Per-file hashes of everything shipped (relative, lower-case, '/'-separated).
    # The client re-hashes each one at startup; the canonical listing is signed.
    $files = [ordered]@{}
    $stageFull = (Resolve-Path $stage).Path.TrimEnd('\') + '\'
    foreach ($f in Get-ChildItem $stage -Recurse -File) {
        $rel = $f.FullName.Substring($stageFull.Length).Replace('\', '/').ToLower()
        $files[$rel] = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower()
    }
    [string[]]$lines = @($files.Keys | ForEach-Object { "${_}:$($files[$_])" })
    [Array]::Sort($lines, [StringComparer]::Ordinal)   # must match the client's CompareStr
    $canon = ($lines | ForEach-Object { $_ + "`n" }) -join ''
    $sha = [Security.Cryptography.SHA256]::Create()
    $filesDigest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canon))) -replace '-', '').ToLower()

    $zipName = 'udaw-update-win64.zip'
    $zipPath = Join-Path ([IO.Path]::GetTempPath()) $zipName
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
    $zipSha = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
}
finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

$payload = "$version|Win64|$zipName|$zipSha|$exeSha|$filesDigest"
$hmac = New-Object System.Security.Cryptography.HMACSHA256
$hmac.Key = [Text.Encoding]::UTF8.GetBytes($SigningKey)
$sig = ([BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))) -replace '-', '').ToLower()

$manifest = [ordered]@{
    platform   = 'Win64'
    version    = $version
    generated  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    package    = $zipName
    sha256     = $zipSha
    exe_sha256 = $exeSha
    files      = $files
    sig        = $sig
} | ConvertTo-Json -Compress

$releasesDir = Join-Path $root 'releases'
New-Item -ItemType Directory -Force -Path $releasesDir | Out-Null
$releaseCopy = Join-Path $releasesDir ("udaw-update-win64-$version.zip")
Copy-Item $zipPath $releaseCopy -Force

New-Item -ItemType Directory -Force -Path (Join-Path $WebRoot 'cgi-bin') | Out-Null
Move-Item $zipPath (Join-Path $WebRoot "cgi-bin\$zipName") -Force
[IO.File]::WriteAllText((Join-Path $WebRoot 'udaw-version-win64.json'), $manifest, (New-Object Text.UTF8Encoding($false)))

Write-Host "==> Packaged UDAW $version"
Write-Host "    exe sha256 : $exeSha"
Write-Host "    zip sha256 : $zipSha"
Write-Host "    release    : $releaseCopy"
Write-Host "    upload     : cgi-bin\$zipName  and  udaw-version-win64.json"
