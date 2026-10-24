<#
  build.ps1 - compile the UDAW Windows (Delphi 12) executable.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\build.ps1 [-Config Debug|Release] [-OutputDir <path>] [-Clean]
    powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Help   (or -h / --help: lists every use case)

  Requires Delphi 12 (Studio 23.0). The script locates the command-line
  compiler via $env:BDS, then the default install path.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Config = 'Release',
    [string]$OutputDir = 'build\bin',
    # Wipes build\bin/build\dcu before compiling, so a stale .dcu can never
    # make a real source change look like it didn't take (see
    # scripts\clean.ps1). Off by default because it also throws away
    # dcc64's incremental-compile cache, making every build a full rebuild.
    [switch]$Clean,
    # Prints full usage and exits without touching anything (no BDS lookup,
    # no build-number bump, no compile) - safe to run to check syntax/options.
    [Alias('h')]
    [switch]$Help
)

if ($Help) {
    @"
build.ps1 - compile the UDAW Windows (Delphi 12) executable

USAGE
    powershell -ExecutionPolicy Bypass -File scripts\build.ps1 [-Config <Debug|Release>]
        [-OutputDir <path>] [-Clean] [-Help | -h | --help]

OPTIONS
    -Config <Debug|Release>
        Which configuration to compile. Default: Release.
        Release: optimized (`-`$O+), RELEASE defined - includes the automatic
                 install of newer published builds and the tamper check, and
                 is packaged as an over-the-air update afterwards.
        Debug:   unoptimized (`-`$O-), DEBUG defined - for local debugging
                 only. NEVER packaged: Debug compiles out the automatic
                 update install, so an install running it cannot update itself.

    -OutputDir <path>
        Where UDAW.exe / UDAWUpdater.exe and their support files land.
        Default: build\bin (relative to the repo root). A Release build is
        packaged from this same folder.

    -Clean
        Runs scripts\clean.ps1 first, wiping build\bin and build\dcu (always
        those two - not a custom -OutputDir) before compiling. Off by default,
        because it also discards dcc64's incremental-compile cache, turning
        every build into a full rebuild.

    -Help, -h, --help
        Shows this text and exits immediately - no BDS lookup, no
        build-number bump, no compile, no packaging.

USE CASES
    1. Normal build + publish an update (the everyday case)
         scripts\build.ps1
       Release build into build\bin, incremental, then packaged into
       F:\Projects\Web\EffectualDesigns (cgi-bin\udaw-update-win64.zip +
       udaw-version-win64.json). Upload both by FTP for installs to update.

    2. Clean Release build + publish
         scripts\build.ps1 -Clean
       Same as 1 after wiping build\bin and build\dcu. Use when a change
       doesn't seem to "take" (a stale .dcu), or before a release you want
       to be sure of.

    3. Explicit Release (same as 1, for scripts that spell it out)
         scripts\build.ps1 -Config Release
         scripts\build.ps1 -Config Release -Clean

    4. Debug build for local debugging - not published
         scripts\build.ps1 -Config Debug
         scripts\build.ps1 -Config Debug -Clean
       Unoptimized with DEBUG defined; prints "Debug build: NOT packaged".
       Don't copy it onto a test install: that install then can't
       auto-update (use Settings > Registration > Check for updates >
       Download & install update to get it back onto a Release build).

    5. Build into a separate folder (keep build\bin untouched)
         scripts\build.ps1 -OutputDir build\bin-test
         scripts\build.ps1 -Config Debug -OutputDir build\bin-debug
       Note a Release build here is still packaged, from that folder.

    6. Use a Delphi 12 installed somewhere non-standard
         `$env:BDS = 'D:\Embarcadero\Studio\23.0'; scripts\build.ps1

    7. Keep UDAW's runtime files (config/logs/cache/scratch) elsewhere
         `$env:UDAW_HOME = 'F:\udaw-home'; scripts\build.ps1
       Default is .udaw-home under the repo root.

    8. Show this help
         scripts\build.ps1 -Help
         scripts\build.ps1 -h
         scripts\build.ps1 --help

    RELATED SCRIPTS (not options of build.ps1)
         scripts\clean.ps1            wipe build\bin and build\dcu only
         scripts\package-release.ps1  re-package the Release build already in
                                      build\bin without recompiling (refuses
                                      a Debug exe)
         scripts\test-windows.ps1     run the test suite

WHAT THIS SCRIPT DOES, IN ORDER
    1. Locates Delphi 12 (Studio 23.0) via `$env:BDS, else the default
       Program Files install path; throws if dcc64.exe isn't found there.
    2. Bumps the build number embedded in resources\UDAW.rc and the
       fallback constant in src\common\UDAW.Version.pas (version scheme
       1.0.<build>.<ddmmyyyy>) - for Debug and Release alike. The bump is
       only kept if the compile below succeeds - a failed build restores
       both files untouched.
    3. Compiles the version resource (brcc32) and then UDAW.exe and
       UDAWUpdater.exe (dcc64) for the requested -Config.
    4. Copies VCL style resources (resources\styles\*.vsf) and the app icon
       into -OutputDir.
    5. Best-effort stamps the in-app help page's Version/Built banner
       (F:\Projects\Web\EffectualDesigns\about-udaw.dat) if that web project
       is on this machine; never fails the build if it isn't, or if the edit
       fails.
    6. Release only: packages the build as an over-the-air update by running
       scripts\package-release.ps1 -BinDir <OutputDir>. A packaging failure
       DOES fail this script. Nothing is uploaded - that is still a manual FTP.

ENVIRONMENT
    BDS        Path to the Delphi 12 (Studio 23.0) install root. If unset,
               the script tries the default 32-bit and 64-bit Program Files
               locations before giving up.
    UDAW_HOME  Where UDAW keeps its runtime config/logs/cache/scratch while
               this script runs. Defaults to .udaw-home under the repo root
               if not already set, so nothing lands on C:\ under %APPDATA%
               or %TEMP% by default.
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
        '-Usrc\common;src\audio;src\audio\backend;src\audio\dsp;src\audio\graph;src\codecs\pcm;src\codecs\tracker;src\codecs\mp3;src\codecs\flac;src\codecs\aac;src\codecs\mp4;src\codecs\ableton;src\codecs\flstudio;src\midi;src\timeline;src\project;src\recording;src\mixer;src\tracker;src\application;src\ui;src\web;src\input;src\video;src\ai;src\browser;src\composer;src\voice;ThirdParty\TaurusTLS\Source;ThirdParty\dglOpenGL' `
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
Copy-Item 'about-udaw.dat' (Join-Path $OutputDir 'about-udaw.dat') -Force   # help page, read from disk (the web server is gone)

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
    # the help page now lives next to the project (read from disk / embedded in the exe)
    $helpPath = Join-Path $PSScriptRoot '..\about-udaw.dat'
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
# Release only: a published Debug build strands every install that takes it,
# since Debug compiles out the automatic install of newer builds.
if ($Config -eq 'Release') {
    Write-Host "==> Packaging release (package-release.ps1)"
    & (Join-Path $PSScriptRoot 'package-release.ps1') -BinDir $OutputDir
    if ($LASTEXITCODE -ne 0) { throw "package-release.ps1 failed ($LASTEXITCODE)" }
} else {
    Write-Host "==> Debug build: NOT packaged (only Release builds are published as updates)"
}
