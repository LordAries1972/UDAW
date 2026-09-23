<#
  test-windows.ps1 - build and run the Phase 1 test suite with Delphi 12.
  Exit code is 0 only if every test passes.
#>
[CmdletBinding()]
param(
    # See scripts\clean.ps1 / build.ps1's -Clean.
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if ($Clean) {
    & (Join-Path $PSScriptRoot 'clean.ps1')
}

# Keep every runtime file (config, logs, cache, test scratch) on this drive
# instead of %APPDATA% / %TEMP% on C:.
if (-not $env:UDAW_HOME) { $env:UDAW_HOME = Join-Path $root '.udaw-home' }

function Find-Bds {
    if ($env:BDS -and (Test-Path $env:BDS)) { return $env:BDS }
    foreach ($c in @('C:\Program Files (x86)\Embarcadero\Studio\23.0',
                     'C:\Program Files\Embarcadero\Studio\23.0')) {
        if (Test-Path $c) { return $c }
    }
    throw 'Delphi 12 (Studio 23.0) not found. Set $env:BDS.'
}

$bds = Find-Bds
$dcc = Join-Path $bds 'bin\dcc64.exe'
$rtl = Join-Path $bds 'lib\Win64\release'

New-Item -ItemType Directory -Force -Path 'build\bin', 'build\dcu' | Out-Null

Write-Host "==> Building UDAW.Tests.exe"
& $dcc -B '-NSSystem;System.Win;Winapi;Vcl;Vcl.Imaging' "-U$rtl" `
    '-$R+' '-$Q+' '-$O-' '-$W+' `
    '-Ebuild\bin' '-NUbuild\dcu' `
    '-Usrc\common;src\audio;src\audio\backend;src\audio\dsp;src\audio\graph;src\codecs\pcm;src\codecs\tracker;src\codecs\mp3;src\codecs\flac;src\codecs\aac;src\codecs\mp4;src\codecs\ableton;src\codecs\flstudio;src\midi;src\timeline;src\project;src\recording;src\mixer;src\tracker;src\ai;src\voice;src\ui;src\composer;src\browser;src\sequencer;src\synth;src\input;src\application;src\web;ThirdParty\TaurusTLS\Source' '-Isrc\common' `
    'tests\UDAW.Tests.dpr'
if ($LASTEXITCODE -ne 0) { throw "dcc64 failed ($LASTEXITCODE)" }

Copy-Item -Force 'ThirdParty\OpenSSL\Win64\*.dll' 'build\bin\'
Write-Host "==> Running tests"
& 'build\bin\UDAW.Tests.exe'
$rc = $LASTEXITCODE
Write-Host "==> test runner exit code: $rc"
exit $rc
