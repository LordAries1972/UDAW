unit UDAW.Platform;
{$I udaw.inc}

{ Compile-time and run-time platform detection.
  All OS/architecture branching in higher layers should read from here rather
  than testing compiler defines directly. }

interface

uses
  SysUtils, Classes;

type
  TUDAWOS = (osUnknown, osWindows, osMacOS, osLinux, osBSD);
  TUDAWArch = (archUnknown, archX86, archX64, archARM32, archARM64);

  TPlatformInfo = record
    OS: TUDAWOS;
    Arch: TUDAWArch;
    OSName: string;        // e.g. 'Windows 11', 'macOS', 'Linux'
    OSVersion: string;     // e.g. '10.0.22631'
    KernelName: string;
    Is64BitOS: Boolean;
    IsAppleSilicon: Boolean;
    LogicalCPUCount: Integer;
    HostName: string;
    UserName: string;
    function Summary: string;
  end;

function OSToStr(AOS: TUDAWOS): string;
function ArchToStr(AArch: TUDAWArch): string;

{ Cached; first call performs detection. }
function CurrentPlatform: TPlatformInfo;

{ Compile-time constants (resolved by the compiler that built this unit). }
function CompiledOS: TUDAWOS; inline;
function CompiledArch: TUDAWArch; inline;

implementation

const
  OS_NAMES: array[TUDAWOS] of string =
    ('Unknown', 'Windows', 'macOS', 'Linux', 'BSD');
  ARCH_NAMES: array[TUDAWArch] of string =
    ('Unknown', 'x86', 'x86-64', 'ARM32', 'ARM64');

var
  GInfo: TPlatformInfo;
  GDetected: Boolean = False;

function OSToStr(AOS: TUDAWOS): string;
begin
  Result := OS_NAMES[AOS];
end;

function ArchToStr(AArch: TUDAWArch): string;
begin
  Result := ARCH_NAMES[AArch];
end;

function CompiledOS: TUDAWOS;
begin
  {$IF DEFINED(UDAW_WINDOWS)}
  Result := osWindows;
  {$ELSEIF DEFINED(UDAW_MACOS)}
  Result := osMacOS;
  {$ELSEIF DEFINED(LINUX)}
  Result := osLinux;
  {$ELSEIF DEFINED(UDAW_POSIX)}
  Result := osBSD;
  {$ELSE}
  Result := osUnknown;
  {$IFEND}
end;

function CompiledArch: TUDAWArch;
begin
  {$IF DEFINED(CPUX86_64) OR DEFINED(CPUX64) OR DEFINED(CPUAMD64)}
  Result := archX64;
  {$ELSEIF DEFINED(CPU386) OR DEFINED(CPUX86) OR DEFINED(CPUI386)}
  Result := archX86;
  {$ELSEIF DEFINED(CPUAARCH64) OR DEFINED(CPUARM64)}
  Result := archARM64;
  {$ELSEIF DEFINED(CPUARM)}
  Result := archARM32;
  {$ELSE}
  Result := archUnknown;
  {$IFEND}
end;

function EnvOr(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

procedure Detect;
begin
  FillChar(GInfo, SizeOf(GInfo), 0);
  GInfo.OS := CompiledOS;
  GInfo.Arch := CompiledArch;
  GInfo.LogicalCPUCount := TThread.ProcessorCount;
  if GInfo.LogicalCPUCount < 1 then
    GInfo.LogicalCPUCount := 1;

  GInfo.OSName := TOSVersion.Name;
  GInfo.OSVersion := Format('%d.%d.%d',
    [TOSVersion.Major, TOSVersion.Minor, TOSVersion.Build]);
  {$IFDEF FPC}
  GInfo.KernelName := {$I %FPCTARGETOS%};
  {$ELSE}
  GInfo.KernelName := OS_NAMES[GInfo.OS];
  {$ENDIF}

  GInfo.IsAppleSilicon := (GInfo.OS = osMacOS) and (GInfo.Arch = archARM64);

  { UDAW ships 64-bit only, so OS bitness tracks the process/arch. }
  GInfo.Is64BitOS := (SizeOf(Pointer) = 8) or (GInfo.Arch in [archX64, archARM64]);

  {$IFDEF UDAW_WINDOWS}
  GInfo.HostName := EnvOr('COMPUTERNAME', 'unknown-host');
  GInfo.UserName := EnvOr('USERNAME', 'unknown-user');
  {$ELSE}
  GInfo.HostName := EnvOr('HOSTNAME', EnvOr('HOST', 'unknown-host'));
  GInfo.UserName := EnvOr('USER', EnvOr('LOGNAME', 'unknown-user'));
  {$ENDIF}

  GDetected := True;
end;

function CurrentPlatform: TPlatformInfo;
begin
  if not GDetected then
    Detect;
  Result := GInfo;
end;

{ TPlatformInfo }

function TPlatformInfo.Summary: string;
begin
  Result := Format('%s %s (%s), %d logical CPUs, host=%s user=%s',
    [OSToStr(OS), OSVersion, ArchToStr(Arch), LogicalCPUCount, HostName, UserName]);
  if IsAppleSilicon then
    Result := Result + ' [Apple Silicon]';
end;

end.
