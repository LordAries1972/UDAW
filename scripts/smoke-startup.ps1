[CmdletBinding()]
param([string]$ExePath = 'build\verified\UDAW.exe')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class UdawStartupSmoke {
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc p, IntPtr l);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint id);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder b, int n);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder b, int n);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int z,bool r);
 [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
 public static IntPtr Find(int pid, string cls) { IntPtr found=IntPtr.Zero; EnumWindows((h,l)=> {uint p; GetWindowThreadProcessId(h,out p); var b=new StringBuilder(128); GetClassName(h,b,128); if(p==pid && b.ToString()==cls) found=h; return true;},IntPtr.Zero); return found; }
 public static IntPtr FirstPage(IntPtr parent) {IntPtr found=IntPtr.Zero; EnumChildWindows(parent,(h,l)=> {var b=new StringBuilder(128); GetClassName(h,b,128); if(found==IntPtr.Zero && b.ToString()=="TPageControl") found=h; return true;},IntPtr.Zero); return found;}
 public static string Describe(int pid) {var result=new StringBuilder(); EnumWindows((h,l)=> {uint p; GetWindowThreadProcessId(h,out p); if(p==pid) {var b=new StringBuilder(512); GetClassName(h,b,512); result.Append(b).Append(": "); GetWindowText(h,b,512); result.AppendLine(b.ToString()); EnumChildWindows(h,(c,k)=>{var t=new StringBuilder(2048); GetWindowText(c,t,2048); if(t.Length>0) result.AppendLine(t.ToString()); return true;},IntPtr.Zero);} return true;},IntPtr.Zero); return result.ToString();}
}
'@
$smokeRoot = Join-Path $root 'build\startup-smoke'
$configPath = Join-Path $smokeRoot 'UDAW\Config\udaw.ini'
New-Item -ItemType Directory -Force -Path (Split-Path $configPath) | Out-Null
@'
[ui]
theme=Carbon
window_width=1000
window_height=700
window_maximized=0
[audio]
autostart=0
'@ | Set-Content -LiteralPath $configPath
$oldHome = $env:UDAW_HOME
$env:UDAW_HOME = $smokeRoot
$tabs = @(Select-String -Path src\ui\UDAW.UI.MainForm.dfm -Pattern '^    object (tab\w+): TTabSheet' | ForEach-Object { $_.Matches[0].Groups[1].Value })
$expected = [Array]::IndexOf($tabs, 'tabProject')
try {
    for ($run = 1; $run -le 2; $run++) {
        $testProcess = Start-Process -FilePath (Join-Path $root $ExePath) -PassThru -WindowStyle Hidden
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(25)
            do {
                Start-Sleep -Milliseconds 200
                $mainHandle = [UdawStartupSmoke]::Find($testProcess.Id, 'TfrmMain')
                if ([UdawStartupSmoke]::Find($testProcess.Id, '#32770') -ne [IntPtr]::Zero) { break }
            } while ($mainHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline -and -not $testProcess.HasExited)
            if ($mainHandle -eq [IntPtr]::Zero) {
                throw ('Main form did not initialize. Exit code: ' + $testProcess.ExitCode + '. Windows: ' + [UdawStartupSmoke]::Describe($testProcess.Id))
            }
            Start-Sleep -Milliseconds 800
            $page = [UdawStartupSmoke]::FirstPage($mainHandle)
            $active = [UdawStartupSmoke]::SendMessage($page, 0x130B, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()
            if ($active -ne $expected) { throw "Wrong startup tab: $active expected $expected" }
            if ($run -eq 1) {
                [UdawStartupSmoke]::MoveWindow($mainHandle, 10, 10, 1100, 720, $true) | Out-Null
                [UdawStartupSmoke]::SendMessage($mainHandle, 0x112, [IntPtr]0xF030, [IntPtr]::Zero) | Out-Null
            } elseif (-not [UdawStartupSmoke]::IsZoomed($mainHandle)) { throw 'Maximized state was not restored' }
            [UdawStartupSmoke]::PostMessage($mainHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            if (-not $testProcess.WaitForExit(10000)) { throw 'Smoke application did not close' }
            if ($testProcess.ExitCode -ne 0) { throw "Startup exit code: $($testProcess.ExitCode)" }
            Write-Output "Startup run $run passed: Project tab selected, clean close"
        } finally {
            if (-not $testProcess.HasExited) { Stop-Process -Id $testProcess.Id -Force }
        }
    }
    Select-String -LiteralPath $configPath -Pattern 'theme=|window_width=|window_height=|window_maximized='
} finally { $env:UDAW_HOME = $oldHome }
