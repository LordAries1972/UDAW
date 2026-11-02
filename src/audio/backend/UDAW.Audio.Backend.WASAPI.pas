unit UDAW.Audio.Backend.WASAPI;
{$I udaw.inc}

{ Phase 2 - native Windows audio backend (WASAPI).

  Real implementation - device enumeration, default-device resolution, shared
  and exclusive mode, event-driven render and capture, sample-rate / format
  negotiation, device-change detection (IMMNotificationClient) and
  device-invalidation recovery (AUDCLNT_E_DEVICE_INVALIDATED -> aseDeviceLost).

  Only compiled on Windows. The COM interfaces are declared here directly
  because the Delphi 12 RTL does not ship CoreAudio / MMDeviceApi units. }

interface

{$IFDEF UDAW_WINDOWS}
uses
  Winapi.Windows, Winapi.ActiveX, Winapi.MMSystem,
  SysUtils, Classes, Math,
  UDAW.Types, UDAW.Errors, UDAW.Logging, UDAW.Threading,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Ring,
  UDAW.Audio.Device;

type
  TWASAPIBackend = class(TInterfacedObject, IAudioBackend)
  private
    FDeviceChange: TAudioStreamEvent;
    FNotify: IUnknown;              // IMMNotificationClient sink, kept alive
    FEnum: IUnknown;               // IMMDeviceEnumerator
    FComInited: Boolean;           // this backend CoInitialized its owner thread
  public
    destructor Destroy; override;
    function Id: TAudioBackendId;
    function Name: string;
    function IsAvailable: Boolean;
    function EnumerateDevices(ADirection: TAudioDirection): TAudioDeviceList;
    function DefaultDeviceId(ADirection: TAudioDirection): string;
    function OpenStream(const ARequest: TAudioStreamRequest;
      ACallback: TAudioStreamCallback): IAudioStream;
    procedure SetDeviceChangeHandler(AHandler: TAudioStreamEvent);
    procedure DispatchDeviceChange(const AMessage: string);
  end;

function WASAPIAvailable: Boolean;

{$ENDIF}

implementation

{$IFDEF UDAW_WINDOWS}

const
  SUBSYS = 'AudioWASAPI';

  CLSID_MMDeviceEnumerator: TGUID = '{BCDE0395-E52F-467C-8E3D-C4579291692E}';
  IID_IMMDeviceEnumerator:  TGUID = '{A95664D2-9614-4F35-A746-DE8DB63617E6}';
  IID_IAudioClient:         TGUID = '{1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}';
  IID_IAudioRenderClient:   TGUID = '{F294ACFC-3146-4483-A7BF-ADDCA7C260E2}';
  IID_IAudioCaptureClient:  TGUID = '{C8ADBD64-E71E-48A0-A4DE-185C395CD317}';

  DATAFLOW_RENDER  = 0;
  DATAFLOW_CAPTURE = 1;
  ROLE_CONSOLE     = 0;
  ROLE_MULTIMEDIA  = 1;

  DEVICE_STATE_ACTIVE = $00000001;
  STGM_READ = 0;

  AUDCLNT_SHAREMODE_SHARED    = 0;
  AUDCLNT_SHAREMODE_EXCLUSIVE = 1;

  AUDCLNT_STREAMFLAGS_EVENTCALLBACK      = $00040000;
  AUDCLNT_STREAMFLAGS_NOPERSIST          = $00080000;
  AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM     = DWORD($80000000);
  AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY= $08000000;

  AUDCLNT_BUFFERFLAGS_SILENT = $2;

  REFTIMES_PER_SEC = 10000000;

  S_FALSE = HRESULT(1);
  AUDCLNT_E_UNSUPPORTED_FORMAT       = HRESULT($88890008);
  AUDCLNT_E_DEVICE_INVALIDATED       = HRESULT($88890004);
  AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED  = HRESULT($88890019);
  AUDCLNT_E_BUFFER_SIZE_ERROR        = HRESULT($88890018);
  AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED = HRESULT($8889000A);

  WAVE_FORMAT_PCM_        = 1;
  WAVE_FORMAT_IEEE_FLOAT_ = 3;
  WAVE_FORMAT_EXTENSIBLE_ = $FFFE;

  KSDATAFORMAT_SUBTYPE_PCM: TGUID        = '{00000001-0000-0010-8000-00AA00389B71}';
  KSDATAFORMAT_SUBTYPE_IEEE_FLOAT: TGUID = '{00000003-0000-0010-8000-00AA00389B71}';

  VT_LPWSTR = 31;

  PKEY_Device_FriendlyName_fmtid: TGUID = '{A45C254E-DF1C-4EFD-8020-67D146A850E0}';
  PKEY_Device_FriendlyName_pid = DWORD(14);

type
  PPropVariantW = ^TPropVariantW;
  TPropVariantW = record
    vt: Word;
    wReserved1, wReserved2, wReserved3: Word;
    case Integer of
      0: (pwszVal: PWideChar);
      1: (blob: array[0..15] of Byte);
  end;

  TPropertyKeyW = record
    fmtid: TGUID;
    pid: DWORD;
  end;

  PWaveFormatExt = ^TWaveFormatExt;
  TWaveFormatExt = record
    Format: TWaveFormatEx;
    wValidBitsPerSample: Word;
    dwChannelMask: DWORD;
    SubFormat: TGUID;
  end;

  IMMNotificationClient = interface(IUnknown)
    ['{7991EEC9-7E89-4D85-8390-6C703CEC60C0}']
    function OnDeviceStateChanged(pwstrDeviceId: PWideChar; dwNewState: DWORD): HRESULT; stdcall;
    function OnDeviceAdded(pwstrDeviceId: PWideChar): HRESULT; stdcall;
    function OnDeviceRemoved(pwstrDeviceId: PWideChar): HRESULT; stdcall;
    function OnDefaultDeviceChanged(flow: DWORD; role: DWORD; pwstrDefaultDeviceId: PWideChar): HRESULT; stdcall;
    function OnPropertyValueChanged(pwstrDeviceId: PWideChar; key: TPropertyKeyW): HRESULT; stdcall;
  end;

  IPropertyStoreW = interface(IUnknown)
    ['{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}']
    function GetCount(out cProps: DWORD): HRESULT; stdcall;
    function GetAt(iProp: DWORD; out pkey: TPropertyKeyW): HRESULT; stdcall;
    function GetValue(const key: TPropertyKeyW; out pv: TPropVariantW): HRESULT; stdcall;
    function SetValue(const key: TPropertyKeyW; const propvar: TPropVariantW): HRESULT; stdcall;
    function Commit: HRESULT; stdcall;
  end;

  IMMDevice = interface(IUnknown)
    ['{D666063F-1587-4E43-81F1-B948E807363F}']
    function Activate(const iid: TGUID; dwClsCtx: DWORD; pActivationParams: Pointer;
      out iface): HRESULT; stdcall;
    function OpenPropertyStore(stgmAccess: DWORD; out props: IPropertyStoreW): HRESULT; stdcall;
    function GetId(out strId: PWideChar): HRESULT; stdcall;
    function GetState(out State: DWORD): HRESULT; stdcall;
  end;

  IMMDeviceCollection = interface(IUnknown)
    ['{0BD7A1BE-7A1A-44DB-8397-CC5392387B5E}']
    function GetCount(out cDevices: UINT): HRESULT; stdcall;
    function Item(nDevice: UINT; out device: IMMDevice): HRESULT; stdcall;
  end;

  IMMDeviceEnumerator = interface(IUnknown)
    ['{A95664D2-9614-4F35-A746-DE8DB63617E6}']
    function EnumAudioEndpoints(dataFlow: DWORD; dwStateMask: DWORD;
      out devices: IMMDeviceCollection): HRESULT; stdcall;
    function GetDefaultAudioEndpoint(dataFlow: DWORD; role: DWORD;
      out endpoint: IMMDevice): HRESULT; stdcall;
    function GetDevice(pwstrId: PWideChar; out device: IMMDevice): HRESULT; stdcall;
    function RegisterEndpointNotificationCallback(client: IMMNotificationClient): HRESULT; stdcall;
    function UnregisterEndpointNotificationCallback(client: IMMNotificationClient): HRESULT; stdcall;
  end;

  IAudioClient = interface(IUnknown)
    ['{1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}']
    function Initialize(ShareMode: DWORD; StreamFlags: DWORD;
      hnsBufferDuration: Int64; hnsPeriodicity: Int64;
      pFormat: PWaveFormatEx; AudioSessionGuid: PGUID): HRESULT; stdcall;
    function GetBufferSize(out NumBufferFrames: UINT32): HRESULT; stdcall;
    function GetStreamLatency(out hnsLatency: Int64): HRESULT; stdcall;
    function GetCurrentPadding(out NumPaddingFrames: UINT32): HRESULT; stdcall;
    function IsFormatSupported(ShareMode: DWORD; pFormat: PWaveFormatEx;
      out ppClosestMatch: PWaveFormatEx): HRESULT; stdcall;
    function GetMixFormat(out ppDeviceFormat: PWaveFormatEx): HRESULT; stdcall;
    function GetDevicePeriod(out hnsDefaultDevicePeriod: Int64;
      out hnsMinimumDevicePeriod: Int64): HRESULT; stdcall;
    function Start: HRESULT; stdcall;
    function Stop: HRESULT; stdcall;
    function Reset: HRESULT; stdcall;
    function SetEventHandle(eventHandle: THandle): HRESULT; stdcall;
    function GetService(const riid: TGUID; out ppv): HRESULT; stdcall;
  end;

  IAudioRenderClient = interface(IUnknown)
    ['{F294ACFC-3146-4483-A7BF-ADDCA7C260E2}']
    function GetBuffer(NumFramesRequested: UINT32; out ppData: PByte): HRESULT; stdcall;
    function ReleaseBuffer(NumFramesWritten: UINT32; dwFlags: DWORD): HRESULT; stdcall;
  end;

  IAudioCaptureClient = interface(IUnknown)
    ['{C8ADBD64-E71E-48A0-A4DE-185C395CD317}']
    function GetBuffer(out ppData: PByte; out NumFramesToRead: UINT32;
      out dwFlags: DWORD; out DevicePosition: UInt64; out QPCPosition: UInt64): HRESULT; stdcall;
    function ReleaseBuffer(NumFramesRead: UINT32): HRESULT; stdcall;
    function GetNextPacketSize(out NumFramesInNextPacket: UINT32): HRESULT; stdcall;
  end;

function PropVariantClear(var pvar: TPropVariantW): HRESULT; stdcall;
  external 'ole32.dll' name 'PropVariantClear';

{ ---------------- notification sink ---------------- }

type
  TMMNotifyClient = class(TInterfacedObject, IMMNotificationClient)
  private
    FOwner: TWASAPIBackend;
  public
    constructor Create(AOwner: TWASAPIBackend);
    function OnDeviceStateChanged(pwstrDeviceId: PWideChar; dwNewState: DWORD): HRESULT; stdcall;
    function OnDeviceAdded(pwstrDeviceId: PWideChar): HRESULT; stdcall;
    function OnDeviceRemoved(pwstrDeviceId: PWideChar): HRESULT; stdcall;
    function OnDefaultDeviceChanged(flow: DWORD; role: DWORD; pwstrDefaultDeviceId: PWideChar): HRESULT; stdcall;
    function OnPropertyValueChanged(pwstrDeviceId: PWideChar; key: TPropertyKeyW): HRESULT; stdcall;
  end;

constructor TMMNotifyClient.Create(AOwner: TWASAPIBackend);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TMMNotifyClient.OnDeviceStateChanged(pwstrDeviceId: PWideChar; dwNewState: DWORD): HRESULT;
begin
  if FOwner <> nil then FOwner.DispatchDeviceChange('device state changed');
  Result := S_OK;
end;

function TMMNotifyClient.OnDeviceAdded(pwstrDeviceId: PWideChar): HRESULT;
begin
  if FOwner <> nil then FOwner.DispatchDeviceChange('device added');
  Result := S_OK;
end;

function TMMNotifyClient.OnDeviceRemoved(pwstrDeviceId: PWideChar): HRESULT;
begin
  if FOwner <> nil then FOwner.DispatchDeviceChange('device removed');
  Result := S_OK;
end;

function TMMNotifyClient.OnDefaultDeviceChanged(flow, role: DWORD; pwstrDefaultDeviceId: PWideChar): HRESULT;
begin
  if (FOwner <> nil) and (role = ROLE_MULTIMEDIA) then
    FOwner.DispatchDeviceChange('default device changed');
  Result := S_OK;
end;

function TMMNotifyClient.OnPropertyValueChanged(pwstrDeviceId: PWideChar; key: TPropertyKeyW): HRESULT;
begin
  Result := S_OK;
end;

{ ---------------- helpers ---------------- }

function HrOk(hr: HRESULT): Boolean; inline;
begin
  Result := hr >= 0;
end;

function IfThenI64(ACond: Boolean; ATrue, AFalse: Int64): Int64;
begin
  if ACond then Result := ATrue else Result := AFalse;
end;

{ Per-call COM apartment guard for backend methods invoked from an arbitrary
  caller thread. Returns the CoInitializeEx result; pass it back to ComLeave. }
function ComEnter: HRESULT;
begin
  Result := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
end;

procedure ComLeave(AEnterResult: HRESULT);
begin
  if AEnterResult in [S_OK, S_FALSE] then
    CoUninitialize;
end;

procedure CheckHr(hr: HRESULT; const AWhat: string);
begin
  if hr < 0 then
    RaiseUDAWFmt(errPlatform, SUBSYS, '%s failed (hr=0x%.8x)', [AWhat, hr]);
end;

function CoCreateEnumerator: IMMDeviceEnumerator;
var
  hr: HRESULT;
begin
  hr := CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL,
    IID_IMMDeviceEnumerator, Result);
  CheckHr(hr, 'CoCreateInstance(MMDeviceEnumerator)');
end;

function DeviceFriendlyName(ADevice: IMMDevice): string;
var
  ps: IPropertyStoreW;
  key: TPropertyKeyW;
  pv: TPropVariantW;
begin
  Result := '';
  if not HrOk(ADevice.OpenPropertyStore(STGM_READ, ps)) then Exit;
  key.fmtid := PKEY_Device_FriendlyName_fmtid;
  key.pid := PKEY_Device_FriendlyName_pid;
  FillChar(pv, SizeOf(pv), 0);
  if HrOk(ps.GetValue(key, pv)) and (pv.vt = VT_LPWSTR) and (pv.pwszVal <> nil) then
    Result := pv.pwszVal;
  PropVariantClear(pv);
end;

function DeviceIdStr(ADevice: IMMDevice): string;
var
  p: PWideChar;
begin
  Result := '';
  p := nil;
  if HrOk(ADevice.GetId(p)) and (p <> nil) then
  begin
    Result := p;
    CoTaskMemFree(p);
  end;
end;

function FormatToDeviceFormat(const AFmt: TWaveFormatEx): TAudioDeviceFormat;
var
  ext: PWaveFormatExt;
begin
  Result := dfUnknown;
  if AFmt.wFormatTag = WAVE_FORMAT_IEEE_FLOAT_ then
  begin
    if AFmt.wBitsPerSample = 32 then Result := dfFloat32
    else if AFmt.wBitsPerSample = 64 then Result := dfFloat64;
  end
  else if AFmt.wFormatTag = WAVE_FORMAT_PCM_ then
  begin
    case AFmt.wBitsPerSample of
      16: Result := dfInt16;
      24: Result := dfInt24Packed;
      32: Result := dfInt32;
    end;
  end
  else if AFmt.wFormatTag = WAVE_FORMAT_EXTENSIBLE_ then
  begin
    ext := PWaveFormatExt(@AFmt);
    if IsEqualGUID(ext^.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) then
    begin
      if AFmt.wBitsPerSample = 32 then Result := dfFloat32
      else if AFmt.wBitsPerSample = 64 then Result := dfFloat64;
    end
    else if IsEqualGUID(ext^.SubFormat, KSDATAFORMAT_SUBTYPE_PCM) then
    begin
      case AFmt.wBitsPerSample of
        16: Result := dfInt16;
        24: Result := dfInt24Packed;
        32: Result := dfInt32;
      end;
    end;
  end;
end;

procedure BuildFloatFormat(var AFmt: TWaveFormatExt; AChannels, ARate: Integer);
begin
  FillChar(AFmt, SizeOf(AFmt), 0);
  AFmt.Format.wFormatTag := WAVE_FORMAT_EXTENSIBLE_;
  AFmt.Format.nChannels := AChannels;
  AFmt.Format.nSamplesPerSec := ARate;
  AFmt.Format.wBitsPerSample := 32;
  AFmt.Format.nBlockAlign := AChannels * 4;
  AFmt.Format.nAvgBytesPerSec := ARate * AFmt.Format.nBlockAlign;
  AFmt.Format.cbSize := SizeOf(TWaveFormatExt) - SizeOf(TWaveFormatEx);
  AFmt.wValidBitsPerSample := 32;
  if AChannels = 1 then AFmt.dwChannelMask := $4
  else if AChannels = 2 then AFmt.dwChannelMask := $3
  else AFmt.dwChannelMask := (DWORD(1) shl AChannels) - 1;
  AFmt.SubFormat := KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
end;

procedure BuildPcmFormat(var AFmt: TWaveFormatExt; AChannels, ARate, ABits: Integer);
begin
  FillChar(AFmt, SizeOf(AFmt), 0);
  AFmt.Format.wFormatTag := WAVE_FORMAT_EXTENSIBLE_;
  AFmt.Format.nChannels := AChannels;
  AFmt.Format.nSamplesPerSec := ARate;
  AFmt.Format.wBitsPerSample := ABits;
  AFmt.Format.nBlockAlign := AChannels * (ABits div 8);
  AFmt.Format.nAvgBytesPerSec := ARate * AFmt.Format.nBlockAlign;
  AFmt.Format.cbSize := SizeOf(TWaveFormatExt) - SizeOf(TWaveFormatEx);
  AFmt.wValidBitsPerSample := ABits;
  if AChannels = 2 then AFmt.dwChannelMask := $3
  else if AChannels = 1 then AFmt.dwChannelMask := $4
  else AFmt.dwChannelMask := (DWORD(1) shl AChannels) - 1;
  AFmt.SubFormat := KSDATAFORMAT_SUBTYPE_PCM;
end;

{ ---------------- stream ---------------- }

type
  TWASAPIStream = class;

  TWASAPIWorker = class(TUDAWThread)
  private
    FStream: TWASAPIStream;
    FCapture: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AStream: TWASAPIStream; ACapture: Boolean);
  end;

  TWASAPIStream = class(TInterfacedObject, IAudioStream)
  private
    FBackend: TWASAPIBackend;
    FRequest: TAudioStreamRequest;
    FCallback: TAudioStreamCallback;
    FEventHandler: TAudioStreamEvent;
    FGranted: TAudioStreamGranted;
    FState: Integer;                    // atomic TAudioStreamState

    FRenderWorker: TWASAPIWorker;
    FCaptureWorker: TWASAPIWorker;
    FStopReq: Integer;                  // atomic
    { Set (1) once the render/capture thread body has finished its OpenClient
      negotiation, success or failure - lets Start() wait for the SLOWER of
      the two device opens (a capture device commonly takes longer than
      render) instead of a fixed Sleep that can return before FGranted.
      CaptureChannels was actually written, which was leaving Granted.
      CaptureChannels at 0 even though the device would have opened fine a
      moment later. }
    FRenderAttempted: Integer;          // atomic
    FCaptureAttempted: Integer;         // atomic

    FStatsLock: TUDAWLock;
    FStats: TAudioStreamStats;

    procedure SetState(AState: TAudioStreamState);
    procedure FireEvent(AKind: TAudioStreamEventKind; const AMsg: string);
    procedure NoteXRun(ACount: Int64);
    procedure NoteBlock(AFrames: Integer; ALoad: Double);

    procedure RenderThreadBody;
    procedure CaptureThreadBody;
    function OpenClient(ACapture: Boolean; out AClient: IAudioClient;
      out AFmt: TAudioDeviceFormat; out AChannels: Integer;
      out ABufferFrames: UINT32; out ALatencyFrames: Integer): Boolean;
  public
    constructor Create(ABackend: TWASAPIBackend; const ARequest: TAudioStreamRequest;
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

constructor TWASAPIWorker.Create(AStream: TWASAPIStream; ACapture: Boolean);
begin
  FStream := AStream;
  FCapture := ACapture;
  FreeOnTerminate := False;
  inherited Create(False);
  Priority := tpTimeCritical;
end;

procedure TWASAPIWorker.Execute;
begin
  if FCapture then
  begin
    TThread.NameThreadForDebugging('udaw-wasapi-cap');
    FStream.CaptureThreadBody;
  end
  else
  begin
    TThread.NameThreadForDebugging('udaw-wasapi-rnd');
    FStream.RenderThreadBody;
  end;
end;

{ ---- TWASAPIStream ---- }

constructor TWASAPIStream.Create(ABackend: TWASAPIBackend;
  const ARequest: TAudioStreamRequest; ACallback: TAudioStreamCallback);
begin
  inherited Create;
  FBackend := ABackend;
  FRequest := ARequest;
  FCallback := ACallback;
  FStatsLock := TUDAWLock.Create('wasapi-stats');
  FillChar(FGranted, SizeOf(FGranted), 0);
  FGranted.Direction := ARequest.Direction;
  FGranted.ShareMode := ARequest.ShareMode;
  SetState(assStopped);
end;

destructor TWASAPIStream.Destroy;
begin
  Close;
  FStatsLock.Free;
  inherited Destroy;
end;

procedure TWASAPIStream.SetState(AState: TAudioStreamState);
begin
  AtomicSet32(FState, Ord(AState));
end;

function TWASAPIStream.State: TAudioStreamState;
begin
  Result := TAudioStreamState(AtomicRead32(FState));
end;

function TWASAPIStream.Granted: TAudioStreamGranted;
begin
  Result := FGranted;
end;

function TWASAPIStream.Stats: TAudioStreamStats;
begin
  FStatsLock.Enter;
  try
    Result := FStats;
  finally
    FStatsLock.Leave;
  end;
end;

procedure TWASAPIStream.ResetStats;
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

procedure TWASAPIStream.SetEventHandler(AHandler: TAudioStreamEvent);
begin
  FEventHandler := AHandler;
end;

function TWASAPIStream.BackendName: string;
begin
  Result := 'wasapi';
end;

procedure TWASAPIStream.FireEvent(AKind: TAudioStreamEventKind; const AMsg: string);
begin
  if Assigned(FEventHandler) then
    try
      FEventHandler(AKind, AMsg);
    except
    end;
end;

procedure TWASAPIStream.NoteXRun(ACount: Int64);
begin
  if ACount <= 0 then Exit;
  FStatsLock.Enter;
  try
    FStats.XRunCount := FStats.XRunCount + ACount;
  finally
    FStatsLock.Leave;
  end;
end;

procedure TWASAPIStream.NoteBlock(AFrames: Integer; ALoad: Double);
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

function TWASAPIStream.OpenClient(ACapture: Boolean; out AClient: IAudioClient;
  out AFmt: TAudioDeviceFormat; out AChannels: Integer;
  out ABufferFrames: UINT32; out ALatencyFrames: Integer): Boolean;
var
  enumr: IMMDeviceEnumerator;
  dev: IMMDevice;
  devId: string;
  dataflow: DWORD;
  mix: PWaveFormatEx;
  wf: TWaveFormatExt;
  closest: PWaveFormatEx;
  hr: HRESULT;
  shareMode: DWORD;
  wantRate, wantChannels: Integer;
  defPeriod, minPeriod, dur: Int64;
  latHns: Int64;
  usedFmt: PWaveFormatEx;
  triedBits: array[0..3] of Integer;
  i: Integer;
begin
  { Every failure path raises via CheckHr; the sole completing path sets
    Result := True at the end. }
  AClient := nil;
  enumr := CoCreateEnumerator;

  if ACapture then
  begin
    dataflow := DATAFLOW_CAPTURE;
    devId := FRequest.CaptureDeviceId;
    wantChannels := FRequest.CaptureChannels;
  end
  else
  begin
    dataflow := DATAFLOW_RENDER;
    devId := FRequest.RenderDeviceId;
    wantChannels := FRequest.RenderChannels;
  end;

  dev := nil;
  if devId <> '' then
    if not HrOk(enumr.GetDevice(PWideChar(WideString(devId)), dev)) then
    begin
      Logger.Warn(SUBSYS, 'chosen audio device not found; using the system default');
      dev := nil;
      devId := '';
    end;
  if dev = nil then
    CheckHr(enumr.GetDefaultAudioEndpoint(dataflow, ROLE_MULTIMEDIA, dev),
      'GetDefaultAudioEndpoint');

  CheckHr(dev.Activate(IID_IAudioClient, CLSCTX_ALL, nil, AClient), 'IMMDevice.Activate');

  if FRequest.ShareMode = asmExclusive then
    shareMode := AUDCLNT_SHAREMODE_EXCLUSIVE
  else
    shareMode := AUDCLNT_SHAREMODE_SHARED;

  wantRate := FRequest.SampleRate;

  mix := nil;
  CheckHr(AClient.GetMixFormat(mix), 'GetMixFormat');
  try
    if wantRate <= 0 then
      wantRate := Integer(mix^.nSamplesPerSec);
    if wantChannels <= 0 then
      wantChannels := mix^.nChannels;

    usedFmt := nil;

    if shareMode = AUDCLNT_SHAREMODE_SHARED then
    begin
      { shared mode must use the mix format's rate & channels; only the sample
        type is guaranteed float. Honour that and let the engine resample. }
      wantRate := Integer(mix^.nSamplesPerSec);
      wantChannels := mix^.nChannels;
      BuildFloatFormat(wf, wantChannels, wantRate);
      closest := nil;
      hr := AClient.IsFormatSupported(shareMode, @wf.Format, closest);
      if hr = S_FALSE then
      begin
        { use the exact mix format }
        usedFmt := mix;
        AFmt := FormatToDeviceFormat(mix^);
        wantChannels := mix^.nChannels;
        wantRate := Integer(mix^.nSamplesPerSec);
      end
      else if HrOk(hr) then
      begin
        usedFmt := @wf.Format;
        AFmt := dfFloat32;
      end
      else
      begin
        usedFmt := mix;
        AFmt := FormatToDeviceFormat(mix^);
        wantChannels := mix^.nChannels;
        wantRate := Integer(mix^.nSamplesPerSec);
      end;
      if closest <> nil then CoTaskMemFree(closest);
    end
    else
    begin
      { exclusive: negotiate float32 then int32/int24/int16 at the wanted rate }
      triedBits[0] := -32; triedBits[1] := 32; triedBits[2] := 24; triedBits[3] := 16;
      for i := 0 to High(triedBits) do
      begin
        if triedBits[i] = -32 then
          BuildFloatFormat(wf, wantChannels, wantRate)
        else
          BuildPcmFormat(wf, wantChannels, wantRate, triedBits[i]);
        closest := nil;
        hr := AClient.IsFormatSupported(shareMode, @wf.Format, closest);
        if closest <> nil then CoTaskMemFree(closest);
        if HrOk(hr) and (hr <> S_FALSE) then
        begin
          usedFmt := @wf.Format;
          AFmt := FormatToDeviceFormat(wf.Format);
          Break;
        end;
      end;
      if usedFmt = nil then
      begin
        Logger.Warn(SUBSYS, 'exclusive format negotiation failed; falling back to shared');
        FRequest.ShareMode := asmShared;
        FGranted.ShareMode := asmShared;
        shareMode := AUDCLNT_SHAREMODE_SHARED;
        wantRate := Integer(mix^.nSamplesPerSec);
        wantChannels := mix^.nChannels;
        usedFmt := mix;
        AFmt := FormatToDeviceFormat(mix^);
      end;
    end;

    AChannels := wantChannels;

    CheckHr(AClient.GetDevicePeriod(defPeriod, minPeriod), 'GetDevicePeriod');
    if FRequest.BufferFrames > 0 then
      dur := Round(Int64(FRequest.BufferFrames) * REFTIMES_PER_SEC / wantRate)
    else
      dur := defPeriod;
    if shareMode = AUDCLNT_SHAREMODE_EXCLUSIVE then
    begin
      if dur < minPeriod then dur := minPeriod;
    end
    else
      dur := defPeriod;

    hr := AClient.Initialize(shareMode,
      AUDCLNT_STREAMFLAGS_EVENTCALLBACK or AUDCLNT_STREAMFLAGS_NOPERSIST,
      dur, IfThenI64(shareMode = AUDCLNT_SHAREMODE_EXCLUSIVE, dur, 0),
      usedFmt, nil);

    if hr = AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED then
    begin
      { retry with the aligned size the device wants }
      AClient := nil;
      CheckHr(dev.Activate(IID_IAudioClient, CLSCTX_ALL, nil, AClient), 're-Activate');
      CheckHr(AClient.GetBufferSize(ABufferFrames), 'GetBufferSize(aligned)');
      dur := Round(Int64(ABufferFrames) * REFTIMES_PER_SEC / wantRate + 0.5);
      hr := AClient.Initialize(shareMode,
        AUDCLNT_STREAMFLAGS_EVENTCALLBACK or AUDCLNT_STREAMFLAGS_NOPERSIST,
        dur, IfThenI64(shareMode = AUDCLNT_SHAREMODE_EXCLUSIVE, dur, 0),
        usedFmt, nil);
    end;
    CheckHr(hr, 'IAudioClient.Initialize');

    CheckHr(AClient.GetBufferSize(ABufferFrames), 'GetBufferSize');
    latHns := 0;
    AClient.GetStreamLatency(latHns);
    ALatencyFrames := Round(latHns * wantRate / REFTIMES_PER_SEC) + Integer(ABufferFrames);

    if not ACapture then
    begin
      FGranted.RenderChannels := wantChannels;
      FGranted.RenderFormat := AFmt;
      FGranted.OutputLatencyFrames := ALatencyFrames;
      FGranted.RenderDeviceId := devId;
      FGranted.RenderDeviceName := DeviceFriendlyName(dev);
    end
    else
    begin
      FGranted.CaptureChannels := wantChannels;
      FGranted.CaptureFormat := AFmt;
      FGranted.InputLatencyFrames := ALatencyFrames;
      FGranted.CaptureDeviceId := devId;
      FGranted.CaptureDeviceName := DeviceFriendlyName(dev);
    end;
    FGranted.SampleRate := wantRate;
    FGranted.BufferFrames := Integer(ABufferFrames);
    Result := True;
  finally
    if mix <> nil then CoTaskMemFree(mix);
  end;
end;

procedure TWASAPIStream.RenderThreadBody;
var
  client: IAudioClient;
  rc: IAudioRenderClient;
  hEvent: THandle;
  fmt: TAudioDeviceFormat;
  channels: Integer;
  bufFrames, padding, avail: UINT32;
  latency: Integer;
  data: PByte;
  buf: TAudioBuffer;
  t: TAudioStreamTime;
  hr: HRESULT;
  wr: DWORD;
  t0, t1: UInt64;
  periodMs, load: Double;
  cbIndex, streamFrames: Int64;
  comInit: HRESULT;
begin
  comInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
   try
    if not OpenClient(False, client, fmt, channels, bufFrames, latency) then
      Exit;
    AtomicSet32(FRenderAttempted, 1); // FGranted.RenderChannels is now valid
    CheckHr(client.GetService(IID_IAudioRenderClient, rc), 'GetService(RenderClient)');

    hEvent := CreateEvent(nil, False, False, nil);
    if hEvent = 0 then
      RaiseUDAW(errPlatform, SUBSYS, 'CreateEvent failed');
    try
      CheckHr(client.SetEventHandle(hEvent), 'SetEventHandle');

      buf := TAudioBuffer.Create(channels, bufFrames, FGranted.SampleRate);
      try
        { prime with silence }
        if HrOk(rc.GetBuffer(bufFrames, data)) then
          rc.ReleaseBuffer(bufFrames, AUDCLNT_BUFFERFLAGS_SILENT);

        CheckHr(client.Start, 'IAudioClient.Start');
        SetState(assRunning);
        cbIndex := 0; streamFrames := 0;
        periodMs := (1000.0 * bufFrames) / FGranted.SampleRate;
        if periodMs <= 0 then periodMs := 1;

        while AtomicRead32(FStopReq) = 0 do
        begin
          wr := WaitForSingleObject(hEvent, 200);
          if wr = WAIT_TIMEOUT then
          begin
            NoteXRun(1);
            Continue;
          end;
          if wr <> WAIT_OBJECT_0 then
            Break;

          hr := client.GetCurrentPadding(padding);
          if hr = AUDCLNT_E_DEVICE_INVALIDATED then
          begin
            SetState(assLost);
            FireEvent(aseDeviceLost, 'render device invalidated');
            Break;
          end;
          CheckHr(hr, 'GetCurrentPadding');

          if FRequest.ShareMode = asmExclusive then
            avail := bufFrames
          else
            avail := bufFrames - padding;
          if avail = 0 then
            Continue;

          hr := rc.GetBuffer(avail, data);
          if hr = AUDCLNT_E_DEVICE_INVALIDATED then
          begin
            SetState(assLost);
            FireEvent(aseDeviceLost, 'render GetBuffer invalidated');
            Break;
          end;
          CheckHr(hr, 'RenderClient.GetBuffer');

          buf.SetActiveFrames(avail);
          buf.Clear;
          buf.StreamPosition := streamFrames;

          t.CallbackIndex := cbIndex;
          t.StreamFrames := streamFrames;
          t.HostTimeNs := Int64(TThread.GetTickCount64) * 1000000;
          t.SampleRate := FGranted.SampleRate;

          t0 := TThread.GetTickCount64;
          try
            FCallback(nil, buf, t);
          except
            on E: Exception do
              Logger.Error(SUBSYS, 'render callback raised: ' + E.Message);
          end;
          t1 := TThread.GetTickCount64;

          buf.StoreInterleaved(data^, fmt, channels, avail);
          hr := rc.ReleaseBuffer(avail, 0);
          if hr = AUDCLNT_E_DEVICE_INVALIDATED then
          begin
            SetState(assLost);
            FireEvent(aseDeviceLost, 'render ReleaseBuffer invalidated');
            Break;
          end;
          CheckHr(hr, 'RenderClient.ReleaseBuffer');

          Inc(cbIndex);
          Inc(streamFrames, avail);
          load := (t1 - t0) / periodMs;
          NoteBlock(avail, load);

        end;

        client.Stop;
      finally
        buf.Free;
      end;
    finally
      CloseHandle(hEvent);
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
    AtomicSet32(FRenderAttempted, 1); // unblocks Start()'s wait even on failure
    client := nil;
    rc := nil;
    if comInit in [S_OK, S_FALSE] then
      CoUninitialize;
  end;
end;

procedure TWASAPIStream.CaptureThreadBody;
var
  client: IAudioClient;
  cc: IAudioCaptureClient;
  hEvent: THandle;
  fmt: TAudioDeviceFormat;
  channels: Integer;
  bufFrames, packet, framesRead: UINT32;
  flags: DWORD;
  devPos, qpcPos: UInt64;
  latency: Integer;
  data: PByte;
  buf: TAudioBuffer;
  t: TAudioStreamTime;
  hr: HRESULT;
  wr: DWORD;
  t0, t1: UInt64;
  periodMs, load: Double;
  cbIndex, streamFrames: Int64;
  comInit: HRESULT;
begin
  comInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
   try
    if not OpenClient(True, client, fmt, channels, bufFrames, latency) then
      Exit;
    AtomicSet32(FCaptureAttempted, 1); // FGranted.CaptureChannels is now valid
    CheckHr(client.GetService(IID_IAudioCaptureClient, cc), 'GetService(CaptureClient)');

    hEvent := CreateEvent(nil, False, False, nil);
    if hEvent = 0 then
      RaiseUDAW(errPlatform, SUBSYS, 'CreateEvent failed');
    try
      CheckHr(client.SetEventHandle(hEvent), 'SetEventHandle(capture)');
      buf := TAudioBuffer.Create(channels, bufFrames, FGranted.SampleRate);
      try
        CheckHr(client.Start, 'IAudioClient.Start(capture)');
        if FRequest.Direction <> adDuplex then
          SetState(assRunning);
        cbIndex := 0; streamFrames := 0;
        periodMs := (1000.0 * bufFrames) / FGranted.SampleRate;
        if periodMs <= 0 then periodMs := 1;

        while AtomicRead32(FStopReq) = 0 do
        begin
          wr := WaitForSingleObject(hEvent, 200);
          if wr = WAIT_TIMEOUT then
          begin
            NoteXRun(1);
            Continue;
          end;
          if wr <> WAIT_OBJECT_0 then Break;

          hr := cc.GetNextPacketSize(packet);
          if hr = AUDCLNT_E_DEVICE_INVALIDATED then
          begin
            SetState(assLost);
            FireEvent(aseDeviceLost, 'capture device invalidated');
            Break;
          end;
          CheckHr(hr, 'GetNextPacketSize');

          while packet > 0 do
          begin
            hr := cc.GetBuffer(data, framesRead, flags, devPos, qpcPos);
            if hr = AUDCLNT_E_DEVICE_INVALIDATED then
            begin
              SetState(assLost);
              FireEvent(aseDeviceLost, 'capture GetBuffer invalidated');
              cc.ReleaseBuffer(0);
              Exit;
            end;
            CheckHr(hr, 'CaptureClient.GetBuffer');

            if framesRead > 0 then
            begin
              if (flags and AUDCLNT_BUFFERFLAGS_SILENT) <> 0 then
                buf.Configure(channels, framesRead, FGranted.SampleRate)
              else
                buf.LoadInterleaved(data^, fmt, channels, framesRead);
              buf.SetActiveFrames(framesRead);
              buf.StreamPosition := streamFrames;

              begin
                t.CallbackIndex := cbIndex;
                t.StreamFrames := streamFrames;
                t.HostTimeNs := Int64(qpcPos) * 100;
                t.SampleRate := FGranted.SampleRate;
                t0 := TThread.GetTickCount64;
                try
                  FCallback(buf, nil, t);
                except
                  on E: Exception do
                    Logger.Error(SUBSYS, 'capture callback raised: ' + E.Message);
                end;
                t1 := TThread.GetTickCount64;
                load := (t1 - t0) / periodMs;
                if FRequest.Direction <> adDuplex then NoteBlock(framesRead, load);
              end;
              Inc(cbIndex);
              Inc(streamFrames, framesRead);
            end;

            cc.ReleaseBuffer(framesRead);
            hr := cc.GetNextPacketSize(packet);
            if not HrOk(hr) then Break;
          end;
        end;
        client.Stop;
      finally
        buf.Free;
      end;
    finally
      CloseHandle(hEvent);
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
    AtomicSet32(FCaptureAttempted, 1); // unblocks Start()'s wait even on failure
    client := nil;
    cc := nil;
    if comInit in [S_OK, S_FALSE] then
      CoUninitialize;
  end;
end;

procedure TWASAPIStream.Start;
const
  WAIT_STEP_MS = 20;
  WAIT_TIMEOUT_MS = 3000;   // a capture device can legitimately take longer
                            // to open than a render device (see OpenClient) -
                            // this must outlast that, not just render's.
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
    FCaptureWorker := TWASAPIWorker.Create(Self, True);
    Sleep(5);
    FRenderWorker := TWASAPIWorker.Create(Self, False);
  end
  else if FRequest.Direction = adCapture then
    FCaptureWorker := TWASAPIWorker.Create(Self, True)
  else
    FRenderWorker := TWASAPIWorker.Create(Self, False);

  { Wait for EVERY requested direction's OpenClient negotiation to finish
    (success or failure - AtomicSet32(F*Attempted, 1) is set by both the
    success path, right when FGranted.*Channels becomes valid, and the
    except/finally path on failure), not just a fixed delay. A fixed 30ms/
    230ms budget was routinely too short for a capture device - by the time
    the caller (TAudioEngine.Open) re-read Granted right after this returned,
    the render side (usually fast) had finished but the capture side hadn't,
    so Granted.CaptureChannels read back as 0 even though the device would
    have opened fine a moment later - the exact bug behind "Select a real
    input device and enable capture in Settings, then reopen Audio" showing
    up even with a real, working input device selected. }
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

procedure TWASAPIStream.Stop;
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

procedure TWASAPIStream.Close;
begin
  Stop;
  if State <> assClosed then
    SetState(assClosed);
end;

{ ---------------- TWASAPIBackend ---------------- }

destructor TWASAPIBackend.Destroy;
var
  e: IMMDeviceEnumerator;
begin
  if (FEnum <> nil) and (FNotify <> nil) then
  begin
    if Supports(FEnum, IMMDeviceEnumerator, e) then
      e.UnregisterEndpointNotificationCallback(FNotify as IMMNotificationClient);
  end;
  FNotify := nil;
  FEnum := nil;
  if FComInited then
  begin
    CoUninitialize;
    FComInited := False;
  end;
  inherited Destroy;
end;

function TWASAPIBackend.Id: TAudioBackendId;
begin
  Result := abWASAPI;
end;

function TWASAPIBackend.Name: string;
begin
  Result := 'Windows WASAPI';
end;

function TWASAPIBackend.IsAvailable: Boolean;
begin
  Result := WASAPIAvailable;
end;

function TWASAPIBackend.EnumerateDevices(ADirection: TAudioDirection): TAudioDeviceList;
var
  e: IMMDeviceEnumerator;
  coll: IMMDeviceCollection;
  dev, defDev: IMMDevice;
  n, i: UINT;
  dataflow: DWORD;
  info: TAudioDeviceInfo;
  defId: string;
  client: IAudioClient;
  mix: PWaveFormatEx;
  comHr: HRESULT;
begin
  SetLength(Result, 0);
  if ADirection = adCapture then dataflow := DATAFLOW_CAPTURE else dataflow := DATAFLOW_RENDER;
  comHr := ComEnter;
  try
   e := nil;
   if not HrOk(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL,
     IID_IMMDeviceEnumerator, e)) then Exit;

  defId := '';
  if HrOk(e.GetDefaultAudioEndpoint(dataflow, ROLE_MULTIMEDIA, defDev)) then
    defId := DeviceIdStr(defDev);

  if not HrOk(e.EnumAudioEndpoints(dataflow, DEVICE_STATE_ACTIVE, coll)) then Exit;
  if not HrOk(coll.GetCount(n)) then Exit;

  for i := 0 to n - 1 do
  begin
    if not HrOk(coll.Item(i, dev)) then Continue;
    FillChar(info, SizeOf(info), 0);
    info.BackendId := abWASAPI;
    info.Direction := ADirection;
    info.Id := DeviceIdStr(dev);
    info.Name := DeviceFriendlyName(dev);
    info.IsDefault := (info.Id <> '') and SameText(info.Id, defId);
    info.MinChannels := 1;
    info.MaxChannels := 8;
    info.DefaultSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
    info.MinBufferFrames := UDAW_MIN_BUFFER_FRAMES;
    info.MaxBufferFrames := UDAW_MAX_BUFFER_FRAMES;
    info.DefaultBufferFrames := UDAW_DEFAULT_BUFFER_FRAMES;
    mix := nil;
    if HrOk(dev.Activate(IID_IAudioClient, CLSCTX_ALL, nil, client)) then
    begin
      if HrOk(client.GetMixFormat(mix)) and (mix <> nil) then
      begin
        info.DefaultSampleRate := Integer(mix^.nSamplesPerSec);
        info.MaxChannels := mix^.nChannels;
        CoTaskMemFree(mix);
      end;
      client := nil;
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := info;
  end;
  finally
    ComLeave(comHr);
  end;
end;

function TWASAPIBackend.DefaultDeviceId(ADirection: TAudioDirection): string;
var
  e: IMMDeviceEnumerator;
  dev: IMMDevice;
  dataflow: DWORD;
  comHr: HRESULT;
begin
  Result := '';
  if ADirection = adCapture then dataflow := DATAFLOW_CAPTURE else dataflow := DATAFLOW_RENDER;
  comHr := ComEnter;
  try
    e := nil;
    if not HrOk(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL,
      IID_IMMDeviceEnumerator, e)) then Exit;
    if HrOk(e.GetDefaultAudioEndpoint(dataflow, ROLE_MULTIMEDIA, dev)) then
      Result := DeviceIdStr(dev);
  finally
    ComLeave(comHr);
  end;
end;

function TWASAPIBackend.OpenStream(const ARequest: TAudioStreamRequest;
  ACallback: TAudioStreamCallback): IAudioStream;
begin
  if not Assigned(ACallback) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'OpenStream: callback is nil');
  Result := TWASAPIStream.Create(Self, ARequest, ACallback);
end;

procedure TWASAPIBackend.SetDeviceChangeHandler(AHandler: TAudioStreamEvent);
var
  e: IMMDeviceEnumerator;
  hr: HRESULT;
begin
  FDeviceChange := AHandler;
  if FNotify <> nil then Exit;

  { Hot-plug notifications need COM alive on this (the owner) thread for the
    backend's lifetime. If nobody initialised it, do so here and undo it in
    Destroy. A failure here is non-fatal - recovery via NotifyDeviceLost still
    works, we just won't auto-refresh device lists on hot-plug. }
  if not FComInited then
  begin
    hr := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
    if hr = S_OK then
      FComInited := True;
  end;

  try
    if FEnum = nil then
    begin
      e := nil;
      if HrOk(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL,
        IID_IMMDeviceEnumerator, e)) then
        FEnum := e;
    end;
    if Supports(FEnum, IMMDeviceEnumerator, e) then
    begin
      FNotify := TMMNotifyClient.Create(Self);
      if not HrOk(e.RegisterEndpointNotificationCallback(FNotify as IMMNotificationClient)) then
        FNotify := nil;
    end;
  except
    on E: Exception do
      Logger.Warn(SUBSYS, 'device hot-plug notifications unavailable: ' + E.Message);
  end;
end;

procedure TWASAPIBackend.DispatchDeviceChange(const AMessage: string);
begin
  if Assigned(FDeviceChange) then
    try
      FDeviceChange(aseDeviceChanged, AMessage);
    except
    end;
end;

var
  GWASAPIChecked: Boolean = False;
  GWASAPIOk: Boolean = False;

function WASAPIAvailable: Boolean;
var
  e: IMMDeviceEnumerator;
  hr: HRESULT;
  needUninit: Boolean;
begin
  if GWASAPIChecked then
    Exit(GWASAPIOk);
  needUninit := False;
  hr := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  if hr = S_OK then needUninit := True;
  try
    GWASAPIOk := HrOk(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL,
      IID_IMMDeviceEnumerator, e));
    e := nil;
  except
    GWASAPIOk := False;
  end;
  if needUninit then
    CoUninitialize;
  GWASAPIChecked := True;
  Result := GWASAPIOk;
end;

{$ENDIF}

end.
