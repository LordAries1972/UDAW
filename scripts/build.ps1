<#
  build.ps1 - compile the UDAW Windows (Delphi 12) executable.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\build.ps1 [-Config Release]
    powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Help

  Requires Delphi 12 (Studio 23.0). The script locates the command-line
  compiler via $env:BDS, then the default install path.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Config = 'Debug',
    [string]$OutputDir = 'build\bin',
    # Wipes build\bin/build\dcu before compiling, so a stale .dcu can never
    # make a real source change look like it didn't take (see
    # scripts\clean.ps1). Off by default because it also throws away
    # dcc64's incremental-compile cache, making every build a full rebuild.
    [switch]$Clean,
    # Prints full usage and exits without touching anything (no BDS lookup,
    # no build-number bump, no compile) - safe to run to check syntax/options.
    [switch]$Help
)

if ($Help) {
    @"
build.ps1 - compile the UDAW Windows (Delphi 12) executable

USAGE
    powershell -ExecutionPolicy Bypass -File scripts\build.ps1 [options]

OPTIONS
    -Config <Debug|Release>
        Which configuration to compile. Default: Debug.
        Release turns on optimization (`-`$O+) and defines RELEASE instead of
        DEBUG; Debug compiles unoptimized (`-`$O-) with DEBUG defined.

    -OutputDir <path>
        Where UDAW.exe / UDAWUpdater.exe and their support files land.
        Default: build\bin (relative to the repo root).

    -Clean
        Runs scripts\clean.ps1 first, wiping build\bin and build\dcu
        before compiling. Off by default, because it also discards dcc64's
        incremental-compile cache, turning every build into a full rebuild.
        Use it when a stale .dcu might be masking a real source change.

    -Help
        Shows this usage text and exits immediately - no BDS lookup, no
        build-number bump, no compile, no packaging.

WHAT THIS SCRIPT DOES, IN ORDER
    1. Locates Delphi 12 (Studio 23.0) via `$env:BDS, else the default
       Program Files install path; throws if dcc64.exe isn't found there.
    2. Bumps the build number embedded in resources\UDAW.rc and the
       fallback constant in src\common\UDAW.Version.pas (version scheme
       1.0.<build>.<ddmmyyyy>). The bump is only kept if the compile below
       actually succeeds - a failed build restores both files untouched.
    3. Compiles the version resource (brcc32) and then UDAW.exe and
       UDAWUpdater.exe (dcc64) for the requested -Config.
    4. Copies VCL style resources (resources\styles\*.vsf) and the app icon
       into -OutputDir.
    5. Best-effort stamps the in-app help page's Version/Built banner
       (F:\Projects\Web\EffectualDesigns\about-udaw.dat) if that separate web
       project happens to be checked out on this machine; never fails the
       build if it isn't, or if the edit fails.
    6. Packages the successful build as an over-the-air update by running
       scripts\package-release.ps1 -BinDir <OutputDir>. A packaging failure
       DOES fail this script.

ENVIRONMENT
    BDS        Path to the Delphi 12 (Studio 23.0) install root. If unset,
               the script tries the default 32-bit and 64-bit Program Files
               locations before giving up.
    UDAW_HOME  Where UDAW keeps its runtime config/logs/cache/scratch while
               this script runs. Defaults to .udaw-home under the repo root
               if not already set, so nothing lands on C:\ under %APPDATA%
               or %TEMP% by default.

EXAMPLES
    scripts\build.ps1
        Debug build into build\bin, incremental (no clean).

    scripts\build.ps1 -Config Release
        Fully optimized release build, still packaged afterwards.

    scripts\build.ps1 -Config Release -Clean
        Wipe build\bin/build\dcu first, then a clean release build.

    scripts\build.ps1 -OutputDir build\bin-test
        Build into an alternate output directory.
"@ | Write-Host
    exit 0
}

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if ($Clean) {
    & (Join-Path $PSScriptRoot 'clean.ps1')
}

# Keep every runtime file (config, logs, cache, scratch) on this drive
# instead of %APPDATA% / %TEMP% on C:.
if (-not $env:UDAW_HOME) { $env:UDAW_HOME = Join-Path $root '.udaw-home' }

function Find-Bds {
    if ($env:BDS -and (Test-Path $env:BDS)) { return $env:BDS }
    $candidates = @(
        'C:\Program Files (x86)\Embarcadero\Studio\23.0',
        'C:\Program Files\Embarcadero\Studio\23.0'
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    throw 'Delphi 12 (Studio 23.0) not found. Set $env:BDS.'
}

$bds  = Find-Bds
$dcc  = Join-Path $bds 'bin\dcc64.exe'
$brcc = Join-Path $bds 'bin\brcc32.exe'
$rtl  = Join-Path $bds 'lib\Win64\release'
if (-not (Test-Path $dcc)) { throw "dcc64 not found at $dcc" }

New-Item -ItemType Directory -Force -Path $OutputDir, 'build\dcu' | Out-Null

# ---- Build-number auto-increment ---------------------------------------
# The product's version scheme (see src\common\UDAW.Version.pas) is
# "1.0.<build>.<ddmmyyyy>" - a build number that increments on every
# successful compile. resources\UDAW.rc's FILEVERSION/PRODUCTVERSION quad is
# the source of truth (the running .exe reads its own compiled-in version
# resource at runtime); UDAW_FALLBACK_BUILD_NUMBER in UDAW.Version.pas is
# kept in lockstep as the fallback used when no resource can be read yet.
# The bump happens here (before brcc32/dcc64, since the new number has to be
# IN the .rc for it to end up embedded in this exe) but is only left in
# place if the compile actually succeeds - a failed build restores both
# files to their pre-bump content so the counter never advances for a build
# nobody got.
$rcPath = 'resources\UDAW.rc'
$verPath = 'src\common\UDAW.Version.pas'
$rcOriginal = Get-Content -Raw $rcPath
$verOriginal = Get-Content -Raw $verPath

$buildMatch = [regex]::Match($rcOriginal, 'FILEVERSION\s+1,0,0,(\d+)')
if (-not $buildMatch.Success) { throw "Could not find FILEVERSION 1,0,0,<build> in $rcPath" }
$oldBuild = [int]$buildMatch.Groups[1].Value
$newBuild = $oldBuild + 1

Write-Host "==> Bumping build number: $oldBuild -> $newBuild"
$rcNew = $rcOriginal
$rcNew = $rcNew -replace '(FILEVERSION\s+1,0,0,)\d+', ('${1}' + $newBuild)
$rcNew = $rcNew -replace '(PRODUCTVERSION\s+1,0,0,)\d+', ('${1}' + $newBuild)
$rcNew = $rcNew -replace '("FileVersion",\s*")1\.0\.\d+(\\0")', ('${1}' + "1.0.$newBuild" + '${2}')
$rcNew = $rcNew -replace '("ProductVersion",\s*")1\.0\.\d+(\\0")', ('${1}' + "1.0.$newBuild" + '${2}')
Set-Content -Path $rcPath -Value $rcNew -NoNewline

$verNew = $verOriginal -replace '(UDAW_FALLBACK_BUILD_NUMBER = )\d+(;)', ('${1}' + $newBuild + '${2}')
Set-Content -Path $verPath -Value $verNew -NoNewline

try {
    Write-Host "==> Compiling version resource"
    & $brcc '-foUDAW.res' 'resources\UDAW.rc'
    if ($LASTEXITCODE -ne 0) { throw "brcc32 failed ($LASTEXITCODE)" }

    $ns = 'System;System.Win;Winapi;Vcl;Vcl.Imaging'
    $defines = if ($Config -eq 'Release') { 'RELEASE' } else { 'DEBUG' }
    $optimization = if ($Config -eq 'Release') { '-$O+' } else { '-$O-' }

    Write-Host "==> Building UDAW.exe ($Config)"
    & $dcc -B "-NS$ns" "-D$defines" "-U$rtl" $optimization `
        "-E$OutputDir" '-NUbuild\dcu' `
        '-Usrc\common;src\audio;src\audio\backend;src\audio\dsp;src\audio\graph;src\codecs\pcm;src\codecs\tracker;src\codecs\mp3;src\codecs\flac;src\codecs\aac;src\codecs\mp4;src\codecs\ableton;src\codecs\flstudio;src\midi;src\timeline;src\project;src\recording;src\mixer;src\tracker;src\application;src\ui;src\web;src\input;src\video;src\ai;src\browser;src\composer;src\voice;ThirdParty\TaurusTLS\Source' `
        '-Isrc\common' '-Rsrc\ui' `
        'UDAW.dpr'
    if ($LASTEXITCODE -ne 0) { throw "dcc64 failed ($LASTEXITCODE)" }

    # UDAWUpdater.exe applies a downloaded update (src\web\UDAW.Update.pas
    # launches it beside UDAW.exe, then UDAW exits) - see UDAWUpdater.dpr.
    New-Item -ItemType Directory -Force -Path 'build\dcu-updater' | Out-Null
    Write-Host "==> Building UDAWUpdater.exe ($Config)"
    & $dcc -B "-NS$ns" "-D$defines" "-U$rtl" $optimization `
        "-E$OutputDir" '-NUbuild\dcu-updater' 'UDAWUpdater.dpr'
    if ($LASTEXITCODE -ne 0) { throw "dcc64 (UDAWUpdater) failed ($LASTEXITCODE)" }
}
catch {
    Write-Host "==> Build failed - reverting build number to $oldBuild"
    Set-Content -Path $rcPath -Value $rcOriginal -NoNewline
    Set-Content -Path $verPath -Value $verOriginal -NoNewline
    throw
}

Write-Host "==> Copying VCL style resources"
New-Item -ItemType Directory -Force -Path (Join-Path $OutputDir 'resources\styles') | Out-Null
Copy-Item 'resources\styles\*.vsf' (Join-Path $OutputDir 'resources\styles') -Force -ErrorAction SilentlyContinue
Copy-Item 'udaw-icon-image.png' (Join-Path $OutputDir 'udaw-icon-image.png') -Force

# ---- Stamp the in-app help page's version banner ------------------------
# F:\Projects\Web\EffectualDesigns\about-udaw.dat is the help page the
# desktop client's Help menu fetches (see UDAW_HELP_URL, src\common\
# UDAW.Types.pas) - it carries its own "Version / Built" line near
# the top, inside <!--UDAW_VERSION-->...<!--/UDAW_VERSION--> etc. comment
# markers, so it always names the exact build it shipped with rather than
# whatever a human last typed by hand. Best-effort only: a machine that
# doesn't have that separate web project checked out (or a failed edit)
# must never fail the UDAW build itself over it.
try {
    $helpPath = 'F:\Projects\Web\EffectualDesigns\about-udaw.dat'
    if (Test-Path $helpPath) {
        Write-Host "==> Stamping help page version banner"
        $versionStr = "1.0.$newBuild"
        $builtStr = Get-Date -Format 'dd/MM/yyyy'

        $helpHtml = Get-Content -Raw $helpPath
        $helpHtml = $helpHtml -replace '(?s)(<!--UDAW_VERSION-->).*?(<!--/UDAW_VERSION-->)', ('${1}' + $versionStr + '${2}')
        $helpHtml = $helpHtml -replace '(?s)(<!--UDAW_BUILDDATE-->).*?(<!--/UDAW_BUILDDATE-->)', ('${1}' + $builtStr + '${2}')
        Set-Content -Path $helpPath -Value $helpHtml -NoNewline
    }
}
catch {
    Write-Host "==> Warning: could not stamp help page version banner ($_)"
}

Write-Host "==> OK: $OutputDir\UDAW.exe"

# ---- Package the successful build as an over-the-air update -------------
# Runs scripts\package-release.ps1 (zip + signed manifest into the local web
# root). A packaging failure fails the script so it is never missed.
Write-Host "==> Packaging release (package-release.ps1)"
& (Join-Path $PSScriptRoot 'package-release.ps1') -BinDir $OutputDir
if ($LASTEXITCODE -ne 0) { throw "package-release.ps1 failed ($LASTEXITCODE)" }
