unit UDAW.Audio.Backend.DirectSound;
{$I udaw.inc}

{ Native Windows DirectSound audio backend.

  Real implementation - device enumeration (render + capture), a looping
  secondary buffer fed by a polling render thread, a looping capture buffer
  drained by a polling capture thread, buffer-lost restore, and a cooperative
  "exclusive" mode.

  DirectSound has no exclusive-device mode of its own; "exclusive" here means
  the strongest control DirectSound offers: DSSCL_PRIORITY, which lets UDAW set
  the device's primary-buffer format (rate / channels / bits) to its own instead
  of accepting whatever the mixer is using. Shared mode uses DSSCL_NORMAL.

  Only compiled on Windows. dsound.dll is part of Windows and is loaded at run
  time; the COM interfaces are declared here from the Windows SDK's dsound.h so
  nothing outside the RTL and the OS is needed. Samples are 16-bit PCM, 1 or 2
  channels. }

interface

{$IFDEF UDAW_WINDOWS}
uses
  Winapi.Windows, Winapi.ActiveX, Winapi.MMSystem,
  SysUtils, Classes, Math,
  UDAW.Types, UDAW.Errors, UDAW.Logging, UDAW.Threading,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Device;

type
  TDirectSoundBackend = class(TInterfacedObject, IAudioBackend)
  private
    FDeviceChange: TAudioStreamEvent;
  public
    function Id: TAudioBackendId;
    function Name: string;
    function IsAvailable: Boolean;
    function EnumerateDevices(ADirection: TAudioDirection): TAudioDeviceList;
    function DefaultDeviceId(ADirection: TAudioDirection): string;
    function OpenStream(const ARequest: TAudioStreamRequest;
      ACallback: TAudioStreamCallback): IAudioStream;
    procedure SetDeviceChangeHandler(AHandler: TAudioStreamEvent);
  end;

function DirectSoundAvailable: Boolean;

{$ENDIF}

implementation

{$IFDEF UDAW_WINDOWS}

const
  SUBSYS = 'AudioDirectSound';

  DSSCL_NORMAL   = $00000001;
  DSSCL_PRIORITY = $00000002;

  DSBCAPS_PRIMARYBUFFER       = $00000001;
  DSBCAPS_GLOBALFOCUS         = $00008000;
  DSBCAPS_GETCURRENTPOSITION2 = $00010000;

  DSBPLAY_LOOPING   = $00000001;
  DSCBSTART_LOOPING = $00000001;

  DSERR_BUFFERLOST = HRESULT($88780096);

  PERIODS_PER_BUFFER = 4;      // the ring holds this many render / capture periods
  MIN_PERIOD_FRAMES  = 256;    // a polled ring cannot honour the very small WASAPI sizes

type
  PDSBufDesc = ^TDSBufDesc;
  TDSBufDesc = record          // DSBUFFERDESC1 / DSCBUFFERDESC1 (both accepted by dsound)
    dwSize: DWORD;
    dwFlags: DWORD;
    dwBufferBytes: DWORD;
    dwReserved: DWORD;
    lpwfxFormat: PWaveFormatEx;
  end;

  IDirectSoundBufferX = interface(IUnknown)
    ['{279AFA85-4981-11CE-A521-0020AF0BE560}']
    function GetCaps(pCaps: Pointer): HRESULT; stdcall;
    function GetCurrentPosition(pdwPlay, pdwWrite: PDWORD): HRESULT; stdcall;
    function GetFormat(pwfx: PWaveFormatEx; dwSizeAllocated: DWORD; pdwSizeWritten: PDWORD): HRESULT; stdcall;
    function GetVolume(out plVolume: Longint): HRESULT; stdcall;
    function GetPan(out plPan: Longint): HRESULT; stdcall;
    function GetFrequency(out pdwFrequency: DWORD): HRESULT; stdcall;
    function GetStatus(out pdwStatus: DWORD): HRESULT; stdcall;
    function Initialize(pDirectSound: Pointer; pDesc: PDSBufDesc): HRESULT; stdcall;
    function Lock(dwOffset, dwBytes: DWORD; ppv1: PPointer; pdwBytes1: PDWORD;
      ppv2: PPointer; pdwBytes2: PDWORD; dwFlags: DWORD): HRESULT; stdcall;
    function Play(dwReserved1, dwPriority, dwFlags: DWORD): HRESULT; stdcall;
    function SetCurrentPosition(dwNewPosition: DWORD): HRESULT; stdcall;
    function SetFormat(pwfx: PWaveFormatEx): HRESULT; stdcall;
    function SetVolume(lVolume: Longint): HRESULT; stdcall;
    function SetPan(lPan: Longint): HRESULT; stdcall;
    function SetFrequency(dwFrequency: DWORD): HRESULT; stdcall;
    function Stop: HRESULT; stdcall;
    function Unlock(pv1: Pointer; dwBytes1: DWORD; pv2: Pointer; dwBytes2: DWORD): HRESULT; stdcall;
    function Restore: HRESULT; stdcall;
  end;

  IDirectSoundX = interface(IUnknown)
    ['{279AFA83-4981-11CE-A521-0020AF0BE560}']
    function CreateSoundBuffer(pDesc: PDSBufDesc; out ppBuffer: IDirectSoundBufferX;
      pUnkOuter: IUnknown): HRESULT; stdcall;
    function GetCaps(pCaps: Pointer): HRESULT; stdcall;
    function DuplicateSoundBuffer(pOriginal: IDirectSoundBufferX;
      out ppDuplicate: IDirectSoundBufferX): HRESULT; stdcall;
    function SetCooperativeLevel(hwnd: HWND; dwLevel: DWORD): HRESULT; stdcall;
    function Compact: HRESULT; stdcall;
    function GetSpeakerConfig(out pdwSpeakerConfig: DWORD): HRESULT; stdcall;
    function SetSpeakerConfig(dwSpeakerConfig: DWORD): HRESULT; stdcall;
    function Initialize(pcGuidDevice: PGUID): HRESULT; stdcall;
  end;

  IDirectSoundCaptureBufferX = interface(IUnknown)
    ['{B0210782-89CD-11D0-AF08-00A0C925CD16}']
    function GetCaps(pCaps: Pointer): HRESULT; stdcall;
    function GetCurrentPosition(pdwCapture, pdwRead: PDWORD): HRESULT; stdcall;
    function GetFormat(pwfx: PWaveFormatEx; dwSizeAllocated: DWORD; pdwSizeWritten: PDWORD): HRESULT; stdcall;
    function GetStatus(pdwStatus: PDWORD): HRESULT; stdcall;
    function Initialize(pCapture: Pointer; pDesc: PDSBufDesc): HRESULT; stdcall;
    function Lock(dwOffset, dwBytes: DWORD; ppv1: PPointer; pdwBytes1: PDWORD;
      ppv2: PPointer; pdwBytes2: PDWORD; dwFlags: DWORD): HRESULT; stdcall;
    function Start(dwFlags: DWORD): HRESULT; stdcall;
    function Stop: HRESULT; stdcall;
    function Unlock(pv1: Pointer; dwBytes1: DWORD; pv2: Pointer; dwBytes2: DWORD): HRESULT; stdcall;
  end;

  IDirectSoundCaptureX = interface(IUnknown)
    ['{B0210781-89CD-11D0-AF08-00A0C925CD16}']
    function CreateCaptureBuffer(pDesc: PDSBufDesc; out ppBuffer: IDirectSoundCaptureBufferX;
      pUnkOuter: IUnknown): HRESULT; stdcall;
    function GetCaps(pCaps: Pointer): HRESULT; stdcall;
    function Initialize(pcGuidDevice: PGUID): HRESULT; stdcall;
  end;

  TDSEnumCallbackW = function(lpGuid: PGUID; lpDescription, lpModule: PWideChar;
    lpContext: Pointer): BOOL; stdcall;

  TDirectSoundCreateFn = function(lpGuid: PGUID; out ppDS: IDirectSoundX;
    pUnkOuter: IUnknown): HRESULT; stdcall;
  TDirectSoundCaptureCreateFn = function(lpGuid: PGUID; out ppDSC: IDirectSoundCaptureX;
    pUnkOuter: IUnknown): HRESULT; stdcall;
  TDirectSoundEnumerateFn = function(cb: TDSEnumCallbackW; lpContext: Pointer): HRESULT; stdcall;

var
  GDSLib: HMODULE = 0;
  GDSChecked: Boolean = False;
  GDSCreate: TDirectSoundCreateFn = nil;
  GDSCaptureCreate: TDirectSoundCaptureCreateFn = nil;
  GDSEnumerate: TDirectSoundEnumerateFn = nil;
  GDSCaptureEnumerate: TDirectSoundEnumerateFn = nil;

function DirectSoundAvailable: Boolean;
begin
  if not GDSChecked then
  begin
    GDSChecked := True;
    GDSLib := LoadLibrary('dsound.dll');
    if GDSLib <> 0 then
    begin
      @GDSCreate := GetProcAddress(GDSLib, 'DirectSoundCreate');
      @GDSCaptureCreate := GetProcAddress(GDSLib, 'DirectSoundCaptureCreate');
      @GDSEnumerate := GetProcAddress(GDSLib, 'DirectSoundEnumerateW');
      @GDSCaptureEnumerate := GetProcAddress(GDSLib, 'DirectSoundCaptureEnumerateW');
    end;
  end;
  Result := Assigned(GDSCreate) and Assigned(GDSEnumerate);
end;

procedure CheckHr(hr: HRESULT; const AWhat: string);
begin
  if hr < 0 then
    RaiseUDAWFmt(errPlatform, SUBSYS, '%s failed (hr=0x%.8x)', [AWhat, hr]);
end;

{ the device id kept in Settings is the DirectSound device GUID as text; '' (or text that is not a
  GUID - e.g. a WASAPI id left over from another backend) means the system default device }
function IdToGuid(const AId: string; out AGuid: TGUID): Boolean;
begin
  Result := False;
  if AId = '' then Exit;
  try
    AGuid := StringToGUID(AId);
    Result := True;
  except
    Result := False;
  end;
end;

{ ---------------- enumeration ---------------- }

type
  PEnumCtx = ^TEnumCtx;
  TEnumCtx = record
    List: TAudioDeviceList;
    Direction: TAudioDirection;
  end;

function EnumCallback(lpGuid: PGUID; lpDescription, lpModule: PWideChar;
  lpContext: Pointer): BOOL; stdcall;
var
  ctx: PEnumCtx;
  info: TAudioDeviceInfo;
begin
  Result := True;
  if lpGuid = nil then Exit;            // the "Primary Sound Driver" alias of the default device
  ctx := PEnumCtx(lpContext);
  FillChar(info, SizeOf(info), 0);
  info.BackendId := abDirectSound;
  info.Direction := ctx^.Direction;
  info.Id := GUIDToString(lpGuid^);
  info.Name := lpDescription;
  info.MinChannels := 1;
  info.MaxChannels := 2;
  info.DefaultSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  info.MinBufferFrames := MIN_PERIOD_FRAMES;
  info.MaxBufferFrames := UDAW_MAX_BUFFER_FRAMES;
  info.DefaultBufferFrames := UDAW_DEFAULT_BUFFER_FRAMES;
  SetLength(ctx^.List, Length(ctx^.List) + 1);
  ctx^.List[High(ctx^.List)] := info;
end;

{ ---------------- stream ---------------- }

type
  TDSStream = class;

  TDSWorker = class(TUDAWThread)
  private
    FStream: TDSStream;
    FCapture: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AStream: TDSStream; ACapture: Boolean);
  end;

  TDSStream = class(TInterfacedObject, IAudioStream)
  private
    FBackend: TDirectSoundBackend;
    FRequest: TAudioStreamRequest;
    FCallback: TAudioStreamCallback;
    FEventHandler: TAudioStreamEvent;
    FGranted: TAudioStreamGranted;
    FState: Integer;                    // atomic TAudioStreamState
    FRenderWorker: TDSWorker;
    FCaptureWorker: TDSWorker;
    FStopReq: Integer;                  // atomic
    FRenderAttempted: Integer;          // atomic - set once the render open succeeded or failed
    FCaptureAttempted: Integer;         // atomic
    FStatsLock: TUDAWLock;
    FStats: TAudioStreamStats;

    procedure SetState(AState: TAudioStreamState);
    procedure FireEvent(AKind: TAudioStreamEventKind; const AMsg: string);
    procedure NoteXRun(ACount: Int64);
    procedure NoteBlock(AFrames: Integer; ALoad: Double);
    function DeviceNameOf(const AId: string; ADirection: TAudioDirection): string;
    procedure RenderThreadBody;
    procedure CaptureThreadBody;
  public
    constructor Create(ABackend: TDirectSoundBackend; const ARequest: TAudioStreamRequest;
      ACallback: TAudioStreamCallback);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    procedure Close;
    function State: TAudioStreamState;
    function Granted: TAudioStreamGranted;
    function Stats: TAudioStreamStats;
    procedure ResetStats;
    procedure SetEventHandler(AHandler: TAudioStreamEvent);
    function BackendName: string;
  end;

procedure BuildPcm16(var AFmt: TWaveFormatEx; AChannels, ARate: Integer);
begin
  FillChar(AFmt, SizeOf(AFmt), 0);
  AFmt.wFormatTag := WAVE_FORMAT_PCM;
  AFmt.nChannels := AChannels;
  AFmt.nSamplesPerSec := ARate;
  AFmt.wBitsPerSample := 16;
  AFmt.nBlockAlign := AChannels * 2;
  AFmt.nAvgBytesPerSec := ARate * AFmt.nBlockAlign;
  AFmt.cbSize := 0;
end;

constructor TDSWorker.Create(AStream: TDSStream; ACapture: Boolean);
begin
  FStream := AStream;
  FCapture := ACapture;
  FreeOnTerminate := False;
  inherited Create(False);
  Priority := tpHighest;
end;

procedure TDSWorker.Execute;
begin
  timeBeginPeriod(1);        // the polling sleeps below need 1 ms timer resolution
  try
    if FCapture then
    begin
      TThread.NameThreadForDebugging('udaw-ds-cap');
      FStream.CaptureThreadBody;
    end
    else
    begin
      TThread.NameThreadForDebugging('udaw-ds-rnd');
      FStream.RenderThreadBody;
    end;
  finally
    timeEndPeriod(1);
  end;
end;

constructor TDSStream.Create(ABackend: TDirectSoundBackend;
  const ARequest: TAudioStreamRequest; ACallback: TAudioStreamCallback);
begin
  inherited Create;
  FBackend := ABackend;
  FRequest := ARequest;
  FCallback := ACallback;
  FStatsLock := TUDAWLock.Create('directsound-stats');
  FillChar(FGranted, SizeOf(FGranted), 0);
  FGranted.Direction := ARequest.Direction;
  FGranted.ShareMode := ARequest.ShareMode;
  SetState(assStopped);
end;

destructor TDSStream.Destroy;
begin
  Close;
  FStatsLock.Free;
  inherited Destroy;
end;

procedure TDSStream.SetState(AState: TAudioStreamState);
begin
  AtomicSet32(FState, Ord(AState));
end;

function TDSStream.State: TAudioStreamState;
begin
  Result := TAudioStreamState(AtomicRead32(FState));
end;

function TDSStream.Granted: TAudioStreamGranted;
begin
  Result := FGranted;
end;

function TDSStream.Stats: TAudioStreamStats;
begin
  FStatsLock.Enter;
  try
    Result := FStats;
  finally
    FStatsLock.Leave;
  end;
end;

procedure TDSStream.ResetStats;
begin
  FStatsLock.Enter;
  try
    FStats.CallbackCount := 0;
    FStats.FramesProcessed := 0;
    FStats.XRunCount := 0;
    FStats.CpuLoad := 0;
    FStats.PeakCpuLoad := 0;
  finally
    FStatsLock.Leave;
  end;
end;

procedure TDSStream.SetEventHandler(AHandler: TAudioStreamEvent);
begin
  FEventHandler := AHandler;
end;

function TDSStream.BackendName: string;
begin
  Result := 'directsound';
end;

procedure TDSStream.FireEvent(AKind: TAudioStreamEventKind; const AMsg: string);
begin
  if Assigned(FEventHandler) then
    try
      FEventHandler(AKind, AMsg);
    except
    end;
end;

procedure TDSStream.NoteXRun(ACount: Int64);
begin
  if ACount <= 0 then Exit;
  FStatsLock.Enter;
  try
    FStats.XRunCount := FStats.XRunCount + ACount;
  finally
    FStatsLock.Leave;
  end;
end;

procedure TDSStream.NoteBlock(AFrames: Integer; ALoad: Double);
begin
  FStatsLock.Enter;
  try
    Inc(FStats.CallbackCount);
    FStats.FramesProcessed := FStats.FramesProcessed + AFrames;
    FStats.LastBlockFrames := AFrames;
    FStats.CpuLoad := FStats.CpuLoad * 0.9 + ALoad * 0.1;
    if ALoad > FStats.PeakCpuLoad then FStats.PeakCpuLoad := ALoad;
  finally
    FStatsLock.Leave;
  end;
end;

function TDSStream.DeviceNameOf(const AId: string; ADirection: TAudioDirection): string;
var
  devs: TAudioDeviceList;
  i: Integer;
begin
  Result := 'Default DirectSound device';
  if AId = '' then Exit;
  devs := FBackend.EnumerateDevices(ADirection);
  for i := 0 to High(devs) do
    if SameText(devs[i].Id, AId) then
      Exit(devs[i].Name);
end;

procedure TDSStream.RenderThreadBody;
var
  ds: IDirectSoundX;
  prim, sec: IDirectSoundBufferX;
  wf: TWaveFormatEx;
  desc: TDSBufDesc;
  guid: TGUID;
  guidPtr: PGUID;
  devId: string;
  channels, rate, periodFrames, blockAlign: Integer;
  periodBytes, total, writePos, playPos, freeBytes, n1, n2: DWORD;
  p1, p2: Pointer;
  hwnd: THandle;
  buf: TAudioBuffer;
  t: TAudioStreamTime;
  hr: HRESULT;
  t0, t1: UInt64;
  periodMs, load: Double;
  cbIndex, streamFrames: Int64;
  waitMs: Integer;
  comInit: HRESULT;
  exclusive: Boolean;
begin
  comInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
   try
    devId := FRequest.RenderDeviceId;
    guidPtr := nil;
    if IdToGuid(devId, guid) then
      guidPtr := @guid
    else
      devId := '';

    CheckHr(GDSCreate(guidPtr, ds, nil), 'DirectSoundCreate');

    hwnd := GetForegroundWindow;
    if hwnd = 0 then hwnd := GetDesktopWindow;
    exclusive := FRequest.ShareMode = asmExclusive;
    if exclusive and (ds.SetCooperativeLevel(hwnd, DSSCL_PRIORITY) < 0) then
    begin
      Logger.Warn(SUBSYS, 'priority (exclusive) cooperative level refused; using shared');
      exclusive := False;
    end;
    if not exclusive then
      CheckHr(ds.SetCooperativeLevel(hwnd, DSSCL_NORMAL), 'SetCooperativeLevel');

    channels := FRequest.RenderChannels;
    if channels <= 0 then channels := 2;
    if channels > 2 then channels := 2;
    rate := FRequest.SampleRate;
    if rate <= 0 then rate := UDAW_DEFAULT_SAMPLE_RATE;
    periodFrames := FRequest.BufferFrames;
    if periodFrames <= 0 then periodFrames := UDAW_DEFAULT_BUFFER_FRAMES;
    if periodFrames < MIN_PERIOD_FRAMES then periodFrames := MIN_PERIOD_FRAMES;
    blockAlign := channels * 2;
    periodBytes := DWORD(periodFrames * blockAlign);
    total := periodBytes * PERIODS_PER_BUFFER;

    BuildPcm16(wf, channels, rate);

    { exclusive: take over the device's primary buffer so it runs at UDAW's format }
    if exclusive then
    begin
      FillChar(desc, SizeOf(desc), 0);
      desc.dwSize := SizeOf(desc);
      desc.dwFlags := DSBCAPS_PRIMARYBUFFER;
      if (ds.CreateSoundBuffer(@desc, prim, nil) >= 0) and (prim <> nil) then
      begin
        if prim.SetFormat(@wf) < 0 then
          Logger.Warn(SUBSYS, 'could not set the device format; it keeps its own');
      end
      else
        Logger.Warn(SUBSYS, 'primary buffer unavailable; exclusive format control skipped');
    end;

    FillChar(desc, SizeOf(desc), 0);
    desc.dwSize := SizeOf(desc);
    desc.dwFlags := DSBCAPS_GETCURRENTPOSITION2 or DSBCAPS_GLOBALFOCUS;
    desc.dwBufferBytes := total;
    desc.lpwfxFormat := @wf;
    CheckHr(ds.CreateSoundBuffer(@desc, sec, nil), 'CreateSoundBuffer');

    { prime the whole ring with silence }
    CheckHr(sec.Lock(0, total, @p1, @n1, @p2, @n2, 0), 'Lock(prime)');
    FillChar(p1^, n1, 0);
    if (p2 <> nil) and (n2 > 0) then FillChar(p2^, n2, 0);
    sec.Unlock(p1, n1, p2, n2);

    FGranted.RenderChannels := channels;
    FGranted.RenderFormat := dfInt16;
    FGranted.SampleRate := rate;
    FGranted.BufferFrames := periodFrames;
    FGranted.OutputLatencyFrames := periodFrames * PERIODS_PER_BUFFER;
    FGranted.RenderDeviceId := devId;
    FGranted.RenderDeviceName := DeviceNameOf(devId, adRender);
    if exclusive then FGranted.ShareMode := asmExclusive else FGranted.ShareMode := asmShared;
    AtomicSet32(FRenderAttempted, 1);   // FGranted is now valid

    buf := TAudioBuffer.Create(channels, periodFrames, rate);
    try
      CheckHr(sec.SetCurrentPosition(0), 'SetCurrentPosition');
      CheckHr(sec.Play(0, 0, DSBPLAY_LOOPING), 'Play');
      SetState(assRunning);

      writePos := 0;
      cbIndex := 0; streamFrames := 0;
      periodMs := (1000.0 * periodFrames) / rate;
      if periodMs <= 0 then periodMs := 1;
      waitMs := Trunc(periodMs / 4);
      if waitMs < 1 then waitMs := 1;

      while AtomicRead32(FStopReq) = 0 do
      begin
        hr := sec.GetCurrentPosition(@playPos, nil);
        if hr = DSERR_BUFFERLOST then
        begin
          sec.Restore;
          sec.Play(0, 0, DSBPLAY_LOOPING);
          Continue;
        end;
        if hr < 0 then
        begin
          SetState(assLost);
          FireEvent(aseDeviceLost, 'DirectSound render device lost');
          Break;
        end;

        freeBytes := (playPos + total - writePos) mod total;
        if freeBytes < periodBytes then
        begin
          Sleep(waitMs);
          Continue;
        end;
        if freeBytes > total - periodBytes then
          NoteXRun(1);                   // the play cursor has caught up with what was written

        buf.SetActiveFrames(periodFrames);
        buf.Clear;
        buf.StreamPosition := streamFrames;

        t.CallbackIndex := cbIndex;
        t.StreamFrames := streamFrames;
        t.HostTimeNs := Int64(TThread.GetTickCount64) * 1000000;
        t.SampleRate := rate;

        t0 := TThread.GetTickCount64;
        try
          FCallback(nil, buf, t);
        except
          on E: Exception do
            Logger.Error(SUBSYS, 'render callback raised: ' + E.Message);
        end;
        t1 := TThread.GetTickCount64;

        hr := sec.Lock(writePos, periodBytes, @p1, @n1, @p2, @n2, 0);
        if hr = DSERR_BUFFERLOST then
        begin
          sec.Restore;
          sec.Play(0, 0, DSBPLAY_LOOPING);
          Continue;
        end;
        CheckHr(hr, 'Lock');
        { the ring is a whole number of periods and writePos is always period-aligned, so the
          locked block never wraps }
        buf.StoreInterleaved(p1^, dfInt16, channels, periodFrames);
        sec.Unlock(p1, n1, p2, n2);

        writePos := (writePos + periodBytes) mod total;
        Inc(cbIndex);
        Inc(streamFrames, periodFrames);
        load := (t1 - t0) / periodMs;
        NoteBlock(periodFrames, load);
      end;

      sec.Stop;
    finally
      buf.Free;
    end;
   except
     on E: Exception do
     begin
       Logger.Error(SUBSYS, 'render thread aborted: ' + E.Message);
       if State <> assLost then SetState(assLost);
       FireEvent(aseDeviceLost, 'render thread error: ' + E.Message);
     end;
   end;
  finally
    AtomicSet32(FRenderAttempted, 1);    // unblocks Start()'s wait even on failure
    sec := nil;
    prim := nil;
    ds := nil;
    if comInit in [S_OK, S_FALSE] then
      CoUninitialize;
  end;
end;

procedure TDSStream.CaptureThreadBody;
var
  cap: IDirectSoundCaptureX;
  cb: IDirectSoundCaptureBufferX;
  wf: TWaveFormatEx;
  desc: TDSBufDesc;
  guid: TGUID;
  guidPtr: PGUID;
  devId: string;
  channels, rate, periodFrames, blockAlign: Integer;
  periodBytes, total, readPos, capPos, availBytes, n1, n2: DWORD;
  p1, p2: Pointer;
  buf: TAudioBuffer;
  t: TAudioStreamTime;
  hr: HRESULT;
  t0, t1: UInt64;
  periodMs, load: Double;
  cbIndex, streamFrames: Int64;
  waitMs: Integer;
  comInit: HRESULT;
begin
  comInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
   try
    if not Assigned(GDSCaptureCreate) then
      RaiseUDAW(errPlatform, SUBSYS, 'DirectSound capture is not available');

    devId := FRequest.CaptureDeviceId;
    guidPtr := nil;
    if IdToGuid(devId, guid) then
      guidPtr := @guid
    else
      devId := '';

    CheckHr(GDSCaptureCreate(guidPtr, cap, nil), 'DirectSoundCaptureCreate');

    channels := FRequest.CaptureChannels;
    if channels <= 0 then channels := 2;
    if channels > 2 then channels := 2;
    rate := FRequest.SampleRate;
    if rate <= 0 then rate := UDAW_DEFAULT_SAMPLE_RATE;
    periodFrames := FRequest.BufferFrames;
    if periodFrames <= 0 then periodFrames := UDAW_DEFAULT_BUFFER_FRAMES;
    if periodFrames < MIN_PERIOD_FRAMES then periodFrames := MIN_PERIOD_FRAMES;
    blockAlign := channels * 2;
    periodBytes := DWORD(periodFrames * blockAlign);
    total := periodBytes * PERIODS_PER_BUFFER;

    BuildPcm16(wf, channels, rate);
    FillChar(desc, SizeOf(desc), 0);
    desc.dwSize := SizeOf(desc);
    desc.dwBufferBytes := total;
    desc.lpwfxFormat := @wf;
    CheckHr(cap.CreateCaptureBuffer(@desc, cb, nil), 'CreateCaptureBuffer');

    FGranted.CaptureChannels := channels;
    FGranted.CaptureFormat := dfInt16;
    FGranted.InputLatencyFrames := periodFrames * PERIODS_PER_BUFFER;
    FGranted.CaptureDeviceId := devId;
    FGranted.CaptureDeviceName := DeviceNameOf(devId, adCapture);
    if FRequest.Direction = adCapture then
    begin
      FGranted.SampleRate := rate;
      FGranted.BufferFrames := periodFrames;
    end;
    AtomicSet32(FCaptureAttempted, 1);   // FGranted.CaptureChannels is now valid

    buf := TAudioBuffer.Create(channels, periodFrames, rate);
    try
      CheckHr(cb.Start(DSCBSTART_LOOPING), 'Capture Start');
      if FRequest.Direction <> adDuplex then
        SetState(assRunning);

      readPos := 0;
      cbIndex := 0; streamFrames := 0;
      periodMs := (1000.0 * periodFrames) / rate;
      if periodMs <= 0 then periodMs := 1;
      waitMs := Trunc(periodMs / 4);
      if waitMs < 1 then waitMs := 1;

      while AtomicRead32(FStopReq) = 0 do
      begin
        hr := cb.GetCurrentPosition(@capPos, nil);
        if hr < 0 then
        begin
          SetState(assLost);
          FireEvent(aseDeviceLost, 'DirectSound capture device lost');
          Break;
        end;

        availBytes := (capPos + total - readPos) mod total;
        if availBytes < periodBytes then
        begin
          Sleep(waitMs);
          Continue;
        end;
        if availBytes > total - periodBytes then
          NoteXRun(1);                   // the capture cursor has caught up with what was read

        CheckHr(cb.Lock(readPos, periodBytes, @p1, @n1, @p2, @n2, 0), 'Capture Lock');
        buf.LoadInterleaved(p1^, dfInt16, channels, periodFrames);
        cb.Unlock(p1, n1, p2, n2);
        buf.SetActiveFrames(periodFrames);
        buf.StreamPosition := streamFrames;

        t.CallbackIndex := cbIndex;
        t.StreamFrames := streamFrames;
        t.HostTimeNs := Int64(TThread.GetTickCount64) * 1000000;
        t.SampleRate := rate;
        t0 := TThread.GetTickCount64;
        try
          FCallback(buf, nil, t);
        except
          on E: Exception do
            Logger.Error(SUBSYS, 'capture callback raised: ' + E.Message);
        end;
        t1 := TThread.GetTickCount64;
        load := (t1 - t0) / periodMs;
        if FRequest.Direction <> adDuplex then NoteBlock(periodFrames, load);

        readPos := (readPos + periodBytes) mod total;
        Inc(cbIndex);
        Inc(streamFrames, periodFrames);
      end;

      cb.Stop;
    finally
      buf.Free;
    end;
   except
     on E: Exception do
     begin
       Logger.Error(SUBSYS, 'capture thread aborted: ' + E.Message);
       if State <> assLost then SetState(assLost);
       FireEvent(aseDeviceLost, 'capture thread error: ' + E.Message);
     end;
   end;
  finally
    AtomicSet32(FCaptureAttempted, 1);   // unblocks Start()'s wait even on failure
    cb := nil;
    cap := nil;
    if comInit in [S_OK, S_FALSE] then
      CoUninitialize;
  end;
end;

procedure TDSStream.Start;
const
  WAIT_STEP_MS = 20;
  WAIT_TIMEOUT_MS = 3000;
var
  waited: Integer;
  needRender, needCapture: Boolean;
begin
  if State = assRunning then Exit;
  if State = assLost then
    RaiseUDAW(errInvalidState, SUBSYS, 'stream lost; reopen');
  AtomicSet32(FStopReq, 0);
  AtomicSet32(FRenderAttempted, 0);
  AtomicSet32(FCaptureAttempted, 0);

  needRender := FRequest.Direction in [adDuplex, adRender];
  needCapture := FRequest.Direction in [adDuplex, adCapture];

  if FRequest.Direction = adDuplex then
  begin
    { render first: it fixes the stream's rate and period, which capture then shares }
    FRenderWorker := TDSWorker.Create(Self, False);
    waited := 0;
    while (waited < WAIT_TIMEOUT_MS) and (AtomicRead32(FRenderAttempted) = 0) do
    begin
      Sleep(5);
      Inc(waited, 5);
    end;
    FCaptureWorker := TDSWorker.Create(Self, True);
  end
  else if FRequest.Direction = adCapture then
    FCaptureWorker := TDSWorker.Create(Self, True)
  else
    FRenderWorker := TDSWorker.Create(Self, False);

  waited := 0;
  while waited < WAIT_TIMEOUT_MS do
  begin
    if (State = assLost) or
       ((not needRender) or (AtomicRead32(FRenderAttempted) <> 0)) and
       ((not needCapture) or (AtomicRead32(FCaptureAttempted) <> 0)) then
      Break;
    Sleep(WAIT_STEP_MS);
    Inc(waited, WAIT_STEP_MS);
  end;
end;

procedure TDSStream.Stop;
begin
  AtomicSet32(FStopReq, 1);
  if FRenderWorker <> nil then
  begin
    FRenderWorker.WaitFor;
    FreeAndNil(FRenderWorker);
  end;
  if FCaptureWorker <> nil then
  begin
    FCaptureWorker.WaitFor;
    FreeAndNil(FCaptureWorker);
  end;
  if State = assRunning then
    SetState(assStopped);
end;

procedure TDSStream.Close;
begin
  Stop;
  if State <> assClosed then
    SetState(assClosed);
end;

{ ---------------- TDirectSoundBackend ---------------- }

function TDirectSoundBackend.Id: TAudioBackendId;
begin
  Result := abDirectSound;
end;

function TDirectSoundBackend.Name: string;
begin
  Result := 'Windows DirectSound';
end;

function TDirectSoundBackend.IsAvailable: Boolean;
begin
  Result := DirectSoundAvailable;
end;

function TDirectSoundBackend.EnumerateDevices(ADirection: TAudioDirection): TAudioDeviceList;
var
  ctx: TEnumCtx;
begin
  SetLength(Result, 0);
  if not DirectSoundAvailable then Exit;
  ctx.Direction := ADirection;
  SetLength(ctx.List, 0);
  if ADirection = adCapture then
  begin
    if Assigned(GDSCaptureEnumerate) then
      GDSCaptureEnumerate(EnumCallback, @ctx);
  end
  else
    GDSEnumerate(EnumCallback, @ctx);
  Result := ctx.List;
end;

function TDirectSoundBackend.DefaultDeviceId(ADirection: TAudioDirection): string;
begin
  Result := '';       // '' = DirectSound's primary driver, i.e. the system default
end;

function TDirectSoundBackend.OpenStream(const ARequest: TAudioStreamRequest;
  ACallback: TAudioStreamCallback): IAudioStream;
begin
  if not Assigned(ACallback) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'OpenStream: callback is nil');
  Result := TDSStream.Create(Self, ARequest, ACallback);
end;

procedure TDirectSoundBackend.SetDeviceChangeHandler(AHandler: TAudioStreamEvent);
begin
  FDeviceChange := AHandler;     // DirectSound reports no hot-plug events; kept for the interface
end;

{$ENDIF}

end.
