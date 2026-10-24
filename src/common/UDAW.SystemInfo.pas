unit UDAW.SystemInfo;

{ Everything a developer needs to know about the machine UDAW is running on, gathered into one
  structured report (sections of key / value rows): the application and its process, the operating
  system, the CPU, memory (physical, page file, virtual address space, the process's own), the
  video adapters (DXGI: dedicated / shared memory, current budget and usage), every monitor and
  its mode, drives, the loaded modules, power, time zone, locale and the environment.

  No user interface here - TSysInfo is plain data. The Diagnostics > System page shows it in a
  TGLInfoView, and AsText gives the same report as text for the clipboard or a bug report.
  Environment variables whose names look like secrets (key, token, secret, password ...) are listed
  with their value hidden, so a copied report never carries a credential. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  TSysInfoKind = (sikSection, sikRow);

  TSysInfoItem = record
    Kind: TSysInfoKind;
    Key: string;
    Value: string;
  end;

  TSysInfo = class
  private
    FItems: TList<TSysInfoItem>;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TSysInfoItem;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure Section(const ATitle: string);
    procedure Row(const AKey, AValue: string); overload;
    procedure Row(const AKey, AFormat: string; const AArgs: array of const); overload;
    function AsText: string;
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TSysInfoItem read GetItem; default;
  end;

{ fills AInfo with the whole report; AExtra (optional) is called last, so the application can add
  what only it knows (audio devices, project, OpenGL driver, display settings) }
procedure CollectSystemInfo(AInfo: TSysInfo; const AExtra: TProc<TSysInfo> = nil);

{ "1.5 GB (1,610,612,736 bytes)" }
function SysBytes(AValue: UInt64): string;

implementation

{$WARN SYMBOL_PLATFORM OFF}

uses
  Winapi.Windows, Winapi.PsAPI, Winapi.TlHelp32,
  Winapi.DXGI, Winapi.DXGI1_2, Winapi.DXGI1_4, Winapi.MultiMon, System.Win.Registry, System.Math,
  System.DateUtils, System.StrUtils, UDAW.Version;

type
  { Delphi's own IDXGIAdapter3 declares no interface id, so Supports / QueryInterface cannot find it;
    this is the same interface (same method order) with its id }
  IUDAWAdapter3 = interface(IDXGIAdapter2)
    ['{645967A4-1392-4310-A798-8053CE3E93FD}']
    function RegisterHardwareContentProtectionTeardownStatusEvent(hEvent: THandle; out pdwCookie: DWORD): HRESULT; stdcall;
    procedure UnregisterHardwareContentProtectionTeardownStatus(dwCookie: DWORD); stdcall;
    function QueryVideoMemoryInfo(NodeIndex: UINT; MemorySegmentGroup: TDXGIMemorySegmentGroup;
      out pVideoMemoryInfo: TDXGIQueryVideoMemoryInfo): HRESULT; stdcall;
    function SetVideoMemoryReservation(NodeIndex: UINT; MemorySegmentGroup: TDXGIMemorySegmentGroup;
      Reservation: UInt64): HRESULT; stdcall;
    function RegisterVideoMemoryBudgetChangeNotificationEvent(hEvent: THandle; out pdwCookie: DWORD): HRESULT; stdcall;
    procedure UnregisterVideoMemoryBudgetChangeNotification(dwCookie: DWORD); stdcall;
  end;

{ ================= TSysInfo ================= }

constructor TSysInfo.Create;
begin
  inherited Create;
  FItems := TList<TSysInfoItem>.Create;
end;

destructor TSysInfo.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

procedure TSysInfo.Clear;
begin
  FItems.Clear;
end;

function TSysInfo.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TSysInfo.GetItem(AIndex: Integer): TSysInfoItem;
begin
  Result := FItems[AIndex];
end;

procedure TSysInfo.Section(const ATitle: string);
var
  it: TSysInfoItem;
begin
  it.Kind := sikSection;
  it.Key := ATitle;
  it.Value := '';
  FItems.Add(it);
end;

procedure TSysInfo.Row(const AKey, AValue: string);
var
  it: TSysInfoItem;
begin
  it.Kind := sikRow;
  it.Key := AKey;
  it.Value := AValue;
  FItems.Add(it);
end;

procedure TSysInfo.Row(const AKey, AFormat: string; const AArgs: array of const);
begin
  Row(AKey, Format(AFormat, AArgs));
end;

function TSysInfo.AsText: string;
var
  sb: TStringBuilder;
  it: TSysInfoItem;
  w: Integer;
begin
  w := 0;
  for it in FItems do
    if (it.Kind = sikRow) and (Length(it.Key) > w) then w := Length(it.Key);
  w := Min(w, 44);
  sb := TStringBuilder.Create;
  try
    for it in FItems do
      if it.Kind = sikSection then
      begin
        if sb.Length > 0 then sb.AppendLine;
        sb.AppendLine('== ' + it.Key + ' ==');
      end
      else
        sb.AppendLine('  ' + it.Key.PadRight(w) + ' : ' + it.Value);
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ ================= helpers ================= }

function SysBytes(AValue: UInt64): string;
const
  UNITS: array[0..4] of string = ('bytes', 'KB', 'MB', 'GB', 'TB');
var
  v: Double;
  u: Integer;
begin
  v := AValue;
  u := 0;
  while (v >= 1024) and (u < High(UNITS)) do
  begin
    v := v / 1024;
    Inc(u);
  end;
  if u = 0 then
    Result := Format('%d bytes', [AValue])
  else
    Result := Format('%.2f %s (%s bytes)', [v, UNITS[u], FormatFloat('#,##0', AValue)]);
end;

{ a - b that never goes below zero: Windows' counters are sampled at slightly different moments }
function SubU(A, B: UInt64): UInt64;
begin
  if A > B then Result := A - B else Result := 0;
end;

{ a count of pages as bytes; the product is formed in 64 bits and can never raise }
{$OVERFLOWCHECKS OFF}
function PagesToBytes(APages: NativeUInt; APageSize: NativeUInt): UInt64;
begin
  Result := UInt64(APages) * UInt64(APageSize);
end;
{$OVERFLOWCHECKS ON}

function YesNo(AValue: Boolean): string;
begin
  if AValue then Result := 'yes' else Result := 'no';
end;

function RegText(ARoot: HKEY; const AKey, AName: string; const ADefault: string = ''): string;
var
  r: TRegistry;
begin
  Result := ADefault;
  r := TRegistry.Create(KEY_READ or KEY_WOW64_64KEY);
  try
    r.RootKey := ARoot;
    if r.OpenKeyReadOnly(AKey) then
    try
      if r.ValueExists(AName) then
        case r.GetDataType(AName) of
          rdInteger: Result := IntToStr(r.ReadInteger(AName));
          rdString, rdExpandString: Result := r.ReadString(AName);
        else
          Result := ADefault;
        end;
    finally
      r.CloseKey;
    end;
  except
    Result := ADefault;
  end;
  r.Free;
end;

function RegInt(ARoot: HKEY; const AKey, AName: string; ADefault: Int64 = 0): Int64;
var
  s: string;
begin
  s := RegText(ARoot, AKey, AName, '');
  if not TryStrToInt64(s, Result) then Result := ADefault;
end;

function FileTimeSeconds(const AFt: TFileTime): Double;
begin
  Result := ((UInt64(AFt.dwHighDateTime) shl 32) or AFt.dwLowDateTime) / 1.0E7;
end;

function FileTimeToDateTime(const AFt: TFileTime): TDateTime;
var
  loc: TFileTime;
  st: TSystemTime;
begin
  FileTimeToLocalFileTime(AFt, loc);
  FileTimeToSystemTime(loc, st);
  Result := SystemTimeToDateTime(st);
end;

function Duration(ASeconds: Double): string;
var
  s: Int64;
begin
  s := Round(ASeconds);
  Result := Format('%dd %.2dh %.2dm %.2ds', [s div 86400, (s div 3600) mod 24, (s div 60) mod 60, s mod 60]);
end;

{ ================= the report ================= }

const
  ENUM_CURRENT_SETTINGS = DWORD(-1);

type
  TRtlGetVersion = function(var AInfo: TOSVersionInfoEx): Integer; stdcall;
  TGetDpiForMonitor = function(AMonitor: HMONITOR; AType: Integer; out ADpiX, ADpiY: UINT): HRESULT; stdcall;

  TPerfInfo = record
    cb: DWORD;
    CommitTotal, CommitLimit, CommitPeak: NativeUInt;
    PhysicalTotal, PhysicalAvailable, SystemCache: NativeUInt;
    KernelTotal, KernelPaged, KernelNonpaged, PageSize: NativeUInt;
    HandleCount, ProcessCount, ThreadCount: DWORD;
  end;

function GetPerformanceInfo(var AInfo: TPerfInfo; ASize: DWORD): BOOL; stdcall;
  external 'psapi.dll' name 'GetPerformanceInfo';

function ProcessorArchName(AArch: Word): string;
begin
  case AArch of
    0: Result := 'x86';
    5: Result := 'ARM';
    6: Result := 'Itanium';
    9: Result := 'x64 (AMD64 / Intel 64)';
    12: Result := 'ARM64';
  else
    Result := 'unknown (' + IntToStr(AArch) + ')';
  end;
end;

procedure AddApplication(AInfo: TSysInfo);
var
  buf: array[0..MAX_PATH] of Char;
  cur: string;
  created, exited, kernel, user: TFileTime;
  hq: DWORD;
  gdi, usr: DWORD;
  handles: DWORD;
  threads: Integer;
  snap: THandle;
  te: TThreadEntry32;
  pid: DWORD;
  mem: TMemoryManagerState;
  i, blocks: Integer;
  bytes: UInt64;
  pm: PROCESS_MEMORY_COUNTERS_EX;
  affProc, affSys: NativeUInt;
begin
  AInfo.Section('Application');
  AInfo.Row('Product', 'Ultimanium Digital Audio Workstation (UDAW)');
  AInfo.Row('Version', UDAWDisplayVersionString);
  AInfo.Row('Build configuration', {$IFDEF RELEASE}'Release (optimised)'{$ELSE}'Debug'{$ENDIF});
  AInfo.Row('Compiler', 'Delphi %s (CompilerVersion %.1f), RTL %.1f', [
    {$IFDEF WIN64}'Win64'{$ELSE}'Win32'{$ENDIF}, CompilerVersion, RTLVersion]);
  AInfo.Row('Process bitness', {$IFDEF WIN64}'64-bit'{$ELSE}'32-bit'{$ENDIF});
  AInfo.Row('Executable', ParamStr(0));
  AInfo.Row('Command line', string(GetCommandLine));
  GetCurrentDirectory(MAX_PATH, buf);
  cur := buf;
  AInfo.Row('Working directory', cur);
  pid := GetCurrentProcessId;
  AInfo.Row('Process id', IntToStr(pid));
  AInfo.Row('Main thread id', IntToStr(MainThreadID));
  if GetProcessTimes(GetCurrentProcess, created, exited, kernel, user) then
  begin
    AInfo.Row('Started', FormatDateTime('yyyy-mm-dd hh:nn:ss', FileTimeToDateTime(created)));
    AInfo.Row('Running for', Duration((Now - FileTimeToDateTime(created)) * 86400));
    AInfo.Row('CPU time (user / kernel)', '%.2f s / %.2f s', [FileTimeSeconds(user), FileTimeSeconds(kernel)]);
  end;
  hq := GetPriorityClass(GetCurrentProcess);
  case hq of
    IDLE_PRIORITY_CLASS: AInfo.Row('Priority class', 'idle');
    BELOW_NORMAL_PRIORITY_CLASS: AInfo.Row('Priority class', 'below normal');
    NORMAL_PRIORITY_CLASS: AInfo.Row('Priority class', 'normal');
    ABOVE_NORMAL_PRIORITY_CLASS: AInfo.Row('Priority class', 'above normal');
    HIGH_PRIORITY_CLASS: AInfo.Row('Priority class', 'high');
    REALTIME_PRIORITY_CLASS: AInfo.Row('Priority class', 'real time');
  else
    AInfo.Row('Priority class', IntToStr(hq));
  end;
  if GetProcessAffinityMask(GetCurrentProcess, affProc, affSys) then
    AInfo.Row('Affinity mask (process / system)', '0x%x / 0x%x', [affProc, affSys]);
  if GetProcessHandleCount(GetCurrentProcess, handles) then AInfo.Row('Handles', IntToStr(handles));
  gdi := GetGuiResources(GetCurrentProcess, 0);
  usr := GetGuiResources(GetCurrentProcess, 1);
  AInfo.Row('GDI objects / USER objects', '%d / %d', [gdi, usr]);
  threads := 0;
  snap := CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if snap <> INVALID_HANDLE_VALUE then
  begin
    te.dwSize := SizeOf(te);
    if Thread32First(snap, te) then
      repeat
        if te.th32OwnerProcessID = pid then Inc(threads);
      until not Thread32Next(snap, te);
    CloseHandle(snap);
  end;
  AInfo.Row('Threads', IntToStr(threads));
  FillChar(pm, SizeOf(pm), 0);
  pm.cb := SizeOf(pm);
  if GetProcessMemoryInfo(GetCurrentProcess, @pm, SizeOf(pm)) then
  begin
    AInfo.Row('Working set', SysBytes(pm.WorkingSetSize));
    AInfo.Row('Peak working set', SysBytes(pm.PeakWorkingSetSize));
    AInfo.Row('Private bytes (commit)', SysBytes(pm.PrivateUsage));
    AInfo.Row('Page file usage', SysBytes(pm.PagefileUsage));
    AInfo.Row('Peak page file usage', SysBytes(pm.PeakPagefileUsage));
    AInfo.Row('Paged pool usage', SysBytes(pm.QuotaPagedPoolUsage));
    AInfo.Row('Non-paged pool usage', SysBytes(pm.QuotaNonPagedPoolUsage));
    AInfo.Row('Page faults', FormatFloat('#,##0', pm.PageFaultCount));
  end;
  GetMemoryManagerState(mem);
  blocks := 0;
  bytes := 0;
  for i := Low(mem.SmallBlockTypeStates) to High(mem.SmallBlockTypeStates) do
  begin
    Inc(blocks, mem.SmallBlockTypeStates[i].AllocatedBlockCount);
    Inc(bytes, UInt64(mem.SmallBlockTypeStates[i].AllocatedBlockCount) *
      mem.SmallBlockTypeStates[i].UseableBlockSize);
  end;
  AInfo.Row('Delphi heap - small blocks', '%s blocks, %s', [FormatFloat('#,##0', blocks), SysBytes(bytes)]);
  AInfo.Row('Delphi heap - medium blocks', '%s blocks, %s', [FormatFloat('#,##0', mem.AllocatedMediumBlockCount),
    SysBytes(mem.TotalAllocatedMediumBlockSize)]);
  AInfo.Row('Delphi heap - large blocks', '%s blocks, %s', [FormatFloat('#,##0', mem.AllocatedLargeBlockCount),
    SysBytes(mem.TotalAllocatedLargeBlockSize)]);
  AInfo.Row('Floating-point control word', '0x%.4x', [Get8087CW]);
end;

procedure AddOperatingSystem(AInfo: TSysInfo);
const
  CV = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion';
var
  vi: TOSVersionInfoEx;
  rtl: TRtlGetVersion;
  m: HMODULE;
  tzi: TTimeZoneInformation;
  tzId: DWORD;
  user, comp: array[0..255] of Char;
  n: DWORD;
  loc: array[0..84] of Char;
  tz: string;
  ub: Int64;
  inst: Int64;
  up: UInt64;
  isWow: BOOL;
  si: TSystemInfo;
  winDir: array[0..MAX_PATH] of Char;
  dc: HDC;
begin
  AInfo.Section('Operating system');
  AInfo.Row('Name', RegText(HKEY_LOCAL_MACHINE, CV, 'ProductName', TOSVersion.Name));
  AInfo.Row('Edition', RegText(HKEY_LOCAL_MACHINE, CV, 'EditionID', ''));
  AInfo.Row('Release', RegText(HKEY_LOCAL_MACHINE, CV, 'DisplayVersion', RegText(HKEY_LOCAL_MACHINE, CV, 'ReleaseId', '')));
  FillChar(vi, SizeOf(vi), 0);
  vi.dwOSVersionInfoSize := SizeOf(vi);
  m := GetModuleHandle('ntdll.dll');
  if m <> 0 then
  begin
    @rtl := GetProcAddress(m, 'RtlGetVersion');
    if Assigned(rtl) and (rtl(vi) = 0) then
      AInfo.Row('Version (kernel)', '%d.%d build %d', [vi.dwMajorVersion, vi.dwMinorVersion, vi.dwBuildNumber]);
  end;
  ub := RegInt(HKEY_LOCAL_MACHINE, CV, 'UBR', -1);
  if ub >= 0 then AInfo.Row('Patch level (UBR)', IntToStr(ub));
  AInfo.Row('Delphi reports', TOSVersion.ToString);
  GetNativeSystemInfo(si);
  AInfo.Row('Architecture', ProcessorArchName(si.wProcessorArchitecture));
  isWow := False;
  IsWow64Process(GetCurrentProcess, isWow);
  AInfo.Row('Running under WOW64', YesNo(isWow));
  inst := RegInt(HKEY_LOCAL_MACHINE, CV, 'InstallDate', 0);
  if inst > 0 then AInfo.Row('Installed', FormatDateTime('yyyy-mm-dd', UnixToDateTime(inst, False)));
  up := GetTickCount64;
  AInfo.Row('Uptime', Duration(up / 1000.0));
  AInfo.Row('Booted', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now - up / 86400000.0));
  n := Length(comp);
  if GetComputerName(comp, n) then AInfo.Row('Computer name', comp);
  n := Length(user);
  if GetUserName(user, n) then AInfo.Row('User name', user);
  GetWindowsDirectory(winDir, Length(winDir));
  AInfo.Row('Windows directory', string(winDir));
  AInfo.Row('Temp directory', GetEnvironmentVariable('TEMP'));
  AInfo.Row('Code page (ANSI / OEM)', '%d / %d', [GetACP, GetOEMCP]);
  if GetUserDefaultLocaleName(loc, Length(loc)) > 0 then AInfo.Row('User locale', loc);
  if GetSystemDefaultLocaleName(loc, Length(loc)) > 0 then AInfo.Row('System locale', loc);
  FillChar(tzi, SizeOf(tzi), 0);
  tzId := GetTimeZoneInformation(tzi);
  if tzId = TIME_ZONE_ID_DAYLIGHT then tz := tzi.DaylightName else tz := tzi.StandardName;
  AInfo.Row('Time zone', '%s (UTC%s%d min%s)', [tz, IfThen(tzi.Bias <= 0, '+', '-'), Abs(tzi.Bias),
    IfThen(tzId = TIME_ZONE_ID_DAYLIGHT, ', daylight saving', '')]);
  AInfo.Row('Local time', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
  dc := GetDC(0);
  AInfo.Row('DPI awareness', IfThen(GetSystemMetrics(SM_REMOTESESSION) <> 0, 'remote session, ', '') +
    Format('system DPI %d', [GetDeviceCaps(dc, LOGPIXELSX)]));
  ReleaseDC(0, dc);
  AInfo.Row('Safe boot / network present', '%s / %s', [YesNo(GetSystemMetrics(SM_CLEANBOOT) <> 0),
    YesNo(GetSystemMetrics(SM_NETWORK) and 1 <> 0)]);
  AInfo.Row('Mouse buttons / wheel', '%d / %s', [GetSystemMetrics(SM_CMOUSEBUTTONS), YesNo(GetSystemMetrics(SM_MOUSEWHEELPRESENT) <> 0)]);
  AInfo.Row('Touch / digitizer', IntToStr(GetSystemMetrics(SM_DIGITIZER)));
end;

procedure AddHardware(AInfo: TSysInfo);
const
  CPU0 = 'HARDWARE\DESCRIPTION\System\CentralProcessor\0';
  BIOS = 'HARDWARE\DESCRIPTION\System\BIOS';
  FEATURES: array[0..16] of record Id: DWORD; Name: string; end = (
    (Id: 6;  Name: 'SSE'), (Id: 10; Name: 'SSE2'), (Id: 13; Name: 'SSE3'),
    (Id: 36; Name: 'SSSE3'), (Id: 37; Name: 'SSE4.1'), (Id: 38; Name: 'SSE4.2'),
    (Id: 39; Name: 'AVX'), (Id: 40; Name: 'AVX2'), (Id: 41; Name: 'AVX-512F'),
    (Id: 7; Name: '3DNow'), (Id: 17; Name: 'AES'), (Id: 23; Name: 'SSE4a'),
    (Id: 22; Name: 'RDRAND'), (Id: 25; Name: 'RDTSCP'), (Id: 29; Name: 'NX (DEP)'),
    (Id: 12; Name: 'Virtualisation (VT-x / AMD-V)'), (Id: 14; Name: 'cmpxchg16b'));
var
  si: TSystemInfo;
  buf: PSystemLogicalProcessorInformation;
  len: DWORD;
  i, cores, packages, nodes: Integer;
  l1, l2, l3: UInt64;
  feat: string;
  f: Integer;
  cnt: Integer;
  p: PByte;
begin
  AInfo.Section('Processor');
  AInfo.Row('Name', Trim(RegText(HKEY_LOCAL_MACHINE, CPU0, 'ProcessorNameString', '')));
  AInfo.Row('Vendor', RegText(HKEY_LOCAL_MACHINE, CPU0, 'VendorIdentifier', ''));
  AInfo.Row('Identifier', RegText(HKEY_LOCAL_MACHINE, CPU0, 'Identifier', ''));
  AInfo.Row('Nominal speed', '%d MHz', [RegInt(HKEY_LOCAL_MACHINE, CPU0, '~MHz', 0)]);
  GetNativeSystemInfo(si);
  AInfo.Row('Architecture', ProcessorArchName(si.wProcessorArchitecture));
  AInfo.Row('Logical processors', IntToStr(si.dwNumberOfProcessors));
  AInfo.Row('Processor level / revision', '%d / 0x%.4x', [si.wProcessorLevel, si.wProcessorRevision]);
  cores := 0; packages := 0; nodes := 0; l1 := 0; l2 := 0; l3 := 0;
  len := 0;
  GetLogicalProcessorInformation(nil, len);
  if (GetLastError = ERROR_INSUFFICIENT_BUFFER) and (len > 0) then
  begin
    GetMem(buf, len);
    try
      if GetLogicalProcessorInformation(buf, len) then
      begin
        cnt := len div SizeOf(TSystemLogicalProcessorInformation);
        p := PByte(buf);
        for i := 0 to cnt - 1 do
        begin
          with PSystemLogicalProcessorInformation(p)^ do
            case Relationship of
              RelationProcessorCore: Inc(cores);
              RelationProcessorPackage: Inc(packages);
              RelationNumaNode: Inc(nodes);
              RelationCache:
                case Cache.Level of
                  1: if Cache._Type in [CacheData, CacheUnified] then Inc(l1, Cache.Size);
                  2: Inc(l2, Cache.Size);
                  3: Inc(l3, Cache.Size);
                end;
            end;
          Inc(p, SizeOf(TSystemLogicalProcessorInformation));
        end;
      end;
    finally
      FreeMem(buf);
    end;
  end;
  if cores > 0 then AInfo.Row('Physical cores', IntToStr(cores));
  if packages > 0 then AInfo.Row('Packages (sockets)', IntToStr(packages));
  if nodes > 0 then AInfo.Row('NUMA nodes', IntToStr(nodes));
  if l1 > 0 then AInfo.Row('L1 data cache (total)', SysBytes(l1));
  if l2 > 0 then AInfo.Row('L2 cache (total)', SysBytes(l2));
  if l3 > 0 then AInfo.Row('L3 cache (total)', SysBytes(l3));
  feat := '';
  for f := Low(FEATURES) to High(FEATURES) do
    if IsProcessorFeaturePresent(FEATURES[f].Id) then
      feat := feat + IfThen(feat = '', '', ', ') + FEATURES[f].Name;
  AInfo.Row('Instruction sets / features', feat);
  AInfo.Row('Page size / allocation granularity', '%d / %d bytes', [si.dwPageSize, si.dwAllocationGranularity]);
  AInfo.Row('Address space (lowest - highest)', '0x%p - 0x%p', [si.lpMinimumApplicationAddress, si.lpMaximumApplicationAddress]);

  AInfo.Section('Machine');
  AInfo.Row('System manufacturer', RegText(HKEY_LOCAL_MACHINE, BIOS, 'SystemManufacturer', ''));
  AInfo.Row('System product', RegText(HKEY_LOCAL_MACHINE, BIOS, 'SystemProductName', ''));
  AInfo.Row('System version', RegText(HKEY_LOCAL_MACHINE, BIOS, 'SystemVersion', ''));
  AInfo.Row('Baseboard manufacturer', RegText(HKEY_LOCAL_MACHINE, BIOS, 'BaseBoardManufacturer', ''));
  AInfo.Row('Baseboard product', RegText(HKEY_LOCAL_MACHINE, BIOS, 'BaseBoardProduct', ''));
  AInfo.Row('BIOS vendor', RegText(HKEY_LOCAL_MACHINE, BIOS, 'BIOSVendor', ''));
  AInfo.Row('BIOS version', RegText(HKEY_LOCAL_MACHINE, BIOS, 'BIOSVersion', ''));
  AInfo.Row('BIOS date', RegText(HKEY_LOCAL_MACHINE, BIOS, 'BIOSReleaseDate', ''));
end;

procedure AddMemory(AInfo: TSysInfo);
var
  ms: TMemoryStatusEx;
  pi: TPerfInfo;
  commitInUse: UInt64;
begin
  AInfo.Section('Memory');
  FillChar(ms, SizeOf(ms), 0);
  ms.dwLength := SizeOf(ms);
  if GlobalMemoryStatusEx(ms) then
  begin
    AInfo.Row('Memory in use', '%d %%', [ms.dwMemoryLoad]);
    AInfo.Row('Total physical memory (RAM)', SysBytes(ms.ullTotalPhys));
    AInfo.Row('Available physical memory', SysBytes(ms.ullAvailPhys));
    AInfo.Row('Used physical memory', SysBytes(SubU(ms.ullTotalPhys, ms.ullAvailPhys)));
    AInfo.Row('Commit limit (RAM + page file)', SysBytes(ms.ullTotalPageFile));
    AInfo.Row('Commit available', SysBytes(ms.ullAvailPageFile));
    commitInUse := SubU(ms.ullTotalPageFile, ms.ullAvailPageFile);
    AInfo.Row('Commit in use', SysBytes(commitInUse));
    AInfo.Row('Virtual address space of this process - total', SysBytes(ms.ullTotalVirtual));
    AInfo.Row('Virtual address space of this process - free', SysBytes(ms.ullAvailVirtual));
    AInfo.Row('Virtual address space of this process - used', SysBytes(SubU(ms.ullTotalVirtual, ms.ullAvailVirtual)));
    AInfo.Row('Maximum for this process (address space)', SysBytes(ms.ullTotalVirtual));
  end;
  FillChar(pi, SizeOf(pi), 0);
  pi.cb := SizeOf(pi);
  if GetPerformanceInfo(pi, SizeOf(pi)) then
  begin
    AInfo.Row('Page size (system)', '%d bytes', [pi.PageSize]);
    AInfo.Row('Commit - total / limit / peak', '%s / %s / %s', [SysBytes(PagesToBytes(pi.CommitTotal, pi.PageSize)),
      SysBytes(PagesToBytes(pi.CommitLimit, pi.PageSize)), SysBytes(PagesToBytes(pi.CommitPeak, pi.PageSize))]);
    AInfo.Row('System cache', SysBytes(PagesToBytes(pi.SystemCache, pi.PageSize)));
    AInfo.Row('Kernel memory - total', SysBytes(PagesToBytes(pi.KernelTotal, pi.PageSize)));
    AInfo.Row('Kernel memory - paged', SysBytes(PagesToBytes(pi.KernelPaged, pi.PageSize)));
    AInfo.Row('Kernel memory - non-paged', SysBytes(PagesToBytes(pi.KernelNonpaged, pi.PageSize)));
    AInfo.Row('System handles / processes / threads', '%s / %d / %d', [FormatFloat('#,##0', pi.HandleCount),
      pi.ProcessCount, pi.ThreadCount]);
  end;
end;

function VendorName(AId: UINT): string;
begin
  case AId of
    $10DE: Result := 'NVIDIA';
    $1002, $1022: Result := 'AMD';
    $8086: Result := 'Intel';
    $1414: Result := 'Microsoft (software / WARP)';
    $5143: Result := 'Qualcomm';
    $1AF4, $15AD: Result := 'virtual machine';
  else
    Result := 'unknown';
  end;
end;

procedure AddAdapters(AInfo: TSysInfo);
var
  factory: IDXGIFactory1;
  adapter: IDXGIAdapter1;
  a3: IUDAWAdapter3;
  desc: TDXGIAdapterDesc1;
  vm: TDXGIQueryVideoMemoryInfo;
  i: Integer;
  hr: HRESULT;
begin
  AInfo.Section('Video adapters (DXGI)');
  try
    hr := CreateDXGIFactory1(IDXGIFactory1, factory);
    if Failed(hr) or (factory = nil) then
    begin
      AInfo.Row('Status', 'DXGI is not available (0x%.8x)', [hr]);
      Exit;
    end;
    i := 0;
    while factory.EnumAdapters1(i, adapter) = S_OK do
    begin
      if Succeeded(adapter.GetDesc1(desc)) then
      begin
        AInfo.Row(Format('Adapter %d', [i]), string(desc.Description));
        AInfo.Row(Format('  vendor / device / revision', []), '%s (0x%.4x) / 0x%.4x / %d',
          [VendorName(desc.VendorId), desc.VendorId, desc.DeviceId, desc.Revision]);
        AInfo.Row('  dedicated video memory (VRAM)', SysBytes(desc.DedicatedVideoMemory));
        AInfo.Row('  dedicated system memory', SysBytes(desc.DedicatedSystemMemory));
        AInfo.Row('  shared system memory', SysBytes(desc.SharedSystemMemory));
        AInfo.Row('  software adapter', YesNo((desc.Flags and 2) <> 0));
        if Supports(adapter, IUDAWAdapter3, a3) then
        begin
          if Succeeded(a3.QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, vm)) then
          begin
            AInfo.Row('  local memory budget', SysBytes(vm.Budget));
            AInfo.Row('  local memory in use (this process)', SysBytes(vm.CurrentUsage));
          end;
          if Succeeded(a3.QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, vm)) then
          begin
            AInfo.Row('  non-local (shared) memory budget', SysBytes(vm.Budget));
            AInfo.Row('  non-local memory in use (this process)', SysBytes(vm.CurrentUsage));
          end;
        end;
      end;
      a3 := nil;
      adapter := nil;
      Inc(i);
    end;
    if i = 0 then AInfo.Row('Status', 'no adapters reported');
  except
    on E: Exception do AInfo.Row('Status', 'DXGI query failed: ' + E.Message);
  end;
end;

function MonitorEnumProc(AMon: HMONITOR; ADC: HDC; ARect: PRect; AData: LPARAM): BOOL; stdcall;
var
  info: TSysInfo;
  mi: TMonitorInfoEx;
  dm: TDevMode;
  dd: TDisplayDevice;
  dpiX, dpiY: UINT;
  getDpi: TGetDpiForMonitor;
  sh: HMODULE;
  modes: Integer;
  name: string;
begin
  Result := True;
  info := TSysInfo(AData);
  FillChar(mi, SizeOf(mi), 0);
  mi.cbSize := SizeOf(mi);
  if not GetMonitorInfo(AMon, @mi) then Exit;
  name := string(mi.szDevice);
  info.Row(Format('Monitor %s', [name]), IfThen((mi.dwFlags and MONITORINFOF_PRIMARY) <> 0, 'primary', 'secondary'));
  info.Row('  desktop rectangle', '%d,%d - %d,%d  (%d x %d)', [mi.rcMonitor.Left, mi.rcMonitor.Top,
    mi.rcMonitor.Right, mi.rcMonitor.Bottom, mi.rcMonitor.Right - mi.rcMonitor.Left, mi.rcMonitor.Bottom - mi.rcMonitor.Top]);
  info.Row('  work area (without taskbar)', '%d,%d - %d,%d', [mi.rcWork.Left, mi.rcWork.Top, mi.rcWork.Right, mi.rcWork.Bottom]);
  FillChar(dm, SizeOf(dm), 0);
  dm.dmSize := SizeOf(dm);
  if EnumDisplaySettings(PChar(name), ENUM_CURRENT_SETTINGS, dm) then
  begin
    info.Row('  current mode', '%d x %d, %d Hz, %d bits per pixel', [dm.dmPelsWidth, dm.dmPelsHeight,
      dm.dmDisplayFrequency, dm.dmBitsPerPel]);
    end;
  modes := 0;
  while EnumDisplaySettings(PChar(name), modes, dm) do Inc(modes);
  info.Row('  modes available', IntToStr(modes));
  FillChar(dd, SizeOf(dd), 0);
  dd.cb := SizeOf(dd);
  if EnumDisplayDevices(PChar(name), 0, dd, 0) then
    info.Row('  display', string(dd.DeviceString));
  sh := LoadLibrary('shcore.dll');
  if sh <> 0 then
  begin
    @getDpi := GetProcAddress(sh, 'GetDpiForMonitor');
    if Assigned(getDpi) and Succeeded(getDpi(AMon, 0, dpiX, dpiY)) then
      info.Row('  effective DPI / scale', '%d x %d / %d %%', [dpiX, dpiY, Round(dpiX * 100 / 96)]);
    FreeLibrary(sh);
  end;
end;

procedure AddDisplays(AInfo: TSysInfo);
var
  dd: TDisplayDevice;
  i: Integer;
begin
  AInfo.Section('Displays');
  AInfo.Row('Monitors', IntToStr(GetSystemMetrics(SM_CMONITORS)));
  AInfo.Row('Virtual desktop', '%d x %d at %d,%d', [GetSystemMetrics(SM_CXVIRTUALSCREEN),
    GetSystemMetrics(SM_CYVIRTUALSCREEN), GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN)]);
  EnumDisplayMonitors(0, nil, @MonitorEnumProc, LPARAM(AInfo));
  i := 0;
  FillChar(dd, SizeOf(dd), 0);
  dd.cb := SizeOf(dd);
  while EnumDisplayDevices(nil, i, dd, 0) do
  begin
    AInfo.Row(Format('Display device %d', [i]), '%s - %s%s', [string(dd.DeviceName), string(dd.DeviceString),
      IfThen((dd.StateFlags and DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) <> 0, ' (on the desktop)', ' (not attached)')]);
    Inc(i);
    FillChar(dd, SizeOf(dd), 0);
    dd.cb := SizeOf(dd);
  end;
end;

procedure AddStorage(AInfo: TSysInfo);
var
  mask: DWORD;
  c: Char;
  root: string;
  dt: UINT;
  freeToCaller, total, free: UInt64;
  vol, fs: array[0..MAX_PATH] of Char;
  serial, maxLen, flags: DWORD;
  kind: string;
  oldMode: UINT;
begin
  AInfo.Section('Drives');
  oldMode := SetErrorMode(SEM_FAILCRITICALERRORS);
  try
    mask := GetLogicalDrives;
    for c := 'A' to 'Z' do
    begin
      if (mask and (1 shl (Ord(c) - Ord('A')))) = 0 then Continue;
      root := c + ':\';
      dt := GetDriveType(PChar(root));
      case dt of
        DRIVE_REMOVABLE: kind := 'removable';
        DRIVE_FIXED: kind := 'fixed';
        DRIVE_REMOTE: kind := 'network';
        DRIVE_CDROM: kind := 'optical';
        DRIVE_RAMDISK: kind := 'RAM disk';
      else
        kind := 'unknown';
      end;
      vol[0] := #0;
      fs[0] := #0;
      if GetVolumeInformation(PChar(root), vol, Length(vol), @serial, maxLen, flags, fs, Length(fs)) and
         GetDiskFreeSpaceEx(PChar(root), freeToCaller, total, @free) then
        AInfo.Row(root, '%s, %s "%s", %s total, %s free', [kind, string(fs), string(vol), SysBytes(total), SysBytes(freeToCaller)])
      else
        AInfo.Row(root, '%s (not ready)', [kind]);
    end;
  finally
    SetErrorMode(oldMode);
  end;
end;

procedure AddPower(AInfo: TSysInfo);
var
  ps: TSystemPowerStatus;
begin
  AInfo.Section('Power');
  if GetSystemPowerStatus(ps) then
  begin
    case ps.ACLineStatus of
      0: AInfo.Row('Power source', 'battery');
      1: AInfo.Row('Power source', 'mains (AC)');
    else
      AInfo.Row('Power source', 'unknown');
    end;
    if ps.BatteryFlag = 128 then AInfo.Row('Battery', 'none')
    else AInfo.Row('Battery', '%d %% (flags 0x%x)', [ps.BatteryLifePercent, ps.BatteryFlag]);
  end;
end;

procedure AddModules(AInfo: TSysInfo);
var
  mods: array[0..1023] of HMODULE;
  needed: DWORD;
  i, n: Integer;
  name: array[0..MAX_PATH] of Char;
  mi: TModuleInfo;
begin
  AInfo.Section('Loaded modules');
  if not EnumProcessModules(GetCurrentProcess, @mods[0], SizeOf(mods), needed) then Exit;
  n := Min(Length(mods), needed div SizeOf(HMODULE));
  AInfo.Row('Count', IntToStr(n));
  for i := 0 to n - 1 do
  begin
    name[0] := #0;
    GetModuleFileNameEx(GetCurrentProcess, mods[i], name, Length(name));
    if GetModuleInformation(GetCurrentProcess, mods[i], @mi, SizeOf(mi)) then
      AInfo.Row(ExtractFileName(string(name)), '0x%p, %s KB, %s', [mi.lpBaseOfDll, FormatFloat('#,##0', mi.SizeOfImage div 1024), string(name)])
    else
      AInfo.Row(ExtractFileName(string(name)), string(name));
  end;
end;

function LooksSecret(const AName: string): Boolean;
const
  WORDS: array[0..7] of string = ('KEY', 'TOKEN', 'SECRET', 'PASSWORD', 'PASSWD', 'PWD', 'CREDENTIAL', 'AUTH');
var
  w: string;
  u: string;
begin
  u := UpperCase(AName);
  for w in WORDS do
    if Pos(w, u) > 0 then Exit(True);
  Result := False;
end;

procedure AddEnvironment(AInfo: TSysInfo);
var
  env, p: PChar;
  s, nm, vl: string;
  eq: Integer;
  list: TStringList;
  i: Integer;
begin
  AInfo.Section('Environment variables (secret-looking values hidden)');
  list := TStringList.Create;
  try
    env := GetEnvironmentStrings;
    if env <> nil then
    try
      p := env;
      while p^ <> #0 do
      begin
        s := p;
        Inc(p, Length(s) + 1);
        eq := Pos('=', s, 2);
        if eq > 1 then list.Add(s);
      end;
    finally
      FreeEnvironmentStrings(env);
    end;
    list.Sort;
    for i := 0 to list.Count - 1 do
    begin
      eq := Pos('=', list[i], 2);
      nm := Copy(list[i], 1, eq - 1);
      vl := Copy(list[i], eq + 1, MaxInt);
      if LooksSecret(nm) then vl := '(hidden)';
      AInfo.Row(nm, vl);
    end;
  finally
    list.Free;
  end;
end;

{ one section never takes the whole report down: a failure becomes a row saying which and why }
procedure Guarded(AInfo: TSysInfo; const AName: string; const AProc: TProc<TSysInfo>);
begin
  try
    AProc(AInfo);
  except
    on E: Exception do
    begin
      AInfo.Section(AName);
      AInfo.Row('This section could not be read', AName + ' - ' + E.ClassName + ': ' + E.Message);
    end;
  end;
end;

procedure CollectSystemInfo(AInfo: TSysInfo; const AExtra: TProc<TSysInfo>);
begin
  AInfo.Clear;
  AInfo.Section('Report');
  AInfo.Row('Generated', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
  Guarded(AInfo, 'Application', AddApplication);
  Guarded(AInfo, 'Operating system', AddOperatingSystem);
  Guarded(AInfo, 'Processor', AddHardware);
  Guarded(AInfo, 'Memory', AddMemory);
  Guarded(AInfo, 'Video adapters (DXGI)', AddAdapters);
  Guarded(AInfo, 'Displays', AddDisplays);
  Guarded(AInfo, 'Drives', AddStorage);
  Guarded(AInfo, 'Power', AddPower);
  if Assigned(AExtra) then Guarded(AInfo, 'Application details', AExtra);
  Guarded(AInfo, 'Loaded modules', AddModules);
  Guarded(AInfo, 'Environment', AddEnvironment);
end;

end.
