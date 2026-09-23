<#
  clean-windows.ps1 - wipe every compiled Delphi artifact so the next build
  can't silently reuse a stale .dcu/.exe and make a real source change look
  like it "didn't take".

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\clean-windows.ps1

  Removes:
    - build\bin\*        (compiled .exe/.res/.map and copied runtime resources)
    - build\dcu\*        (compiled .dcu units)
    - any stray .dcu/.map/.~* left next to source by a build that didn't
      route through -NUbuild\dcu (e.g. an IDE compile, not this script)
  Leaves alone: build\*.log and any other ad-hoc scratch/report files under
  build\ that aren't compiler output - those are build/test history, not
  build artifacts, and this script only ever deletes things a fresh build
  regenerates on its own.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Clear-Dir {
    param([string]$Path)
    if (Test-Path $Path) {
        Write-Host "==> Clearing $Path"
        Get-ChildItem -Path $Path -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Clear-Dir 'build\bin'
Clear-Dir 'build\dcu'

Write-Host "==> Removing stray .dcu/.map left outside build\dcu"
Get-ChildItem -Path $root -Recurse -Include '*.dcu','*.map','*.~*' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\ThirdParty\\' } |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "==> Clean complete"
