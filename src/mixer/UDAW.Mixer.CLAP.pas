unit UDAW.Mixer.CLAP;
{$I udaw.inc}
{$ALIGN 8}
{$POINTERMATH ON}

{ CLAP (CLever Audio Plug-in) effect hosting, Windows.

  Clean-room re-declaration of the public, MIT-licensed CLAP 1.x C ABI: the
  exported `clap_entry` data symbol, the plugin factory, clap_plugin_t, the
  host struct, process/audio-buffer/event structs and the `clap.params` and
  `clap.state` extensions. Scope matches the VST2 host: an audio-in /
  audio-out effect host (port 0 stereo), parameters by index, state save /
  restore, fault isolation. Instrument note-event routing and the plugin GUI
  extension are not attempted here. }

interface

uses
  Windows, SysUtils, Classes, Math, System.NetEncoding;

type
  ECLAPError = class(Exception);

  TCLAPHost = class
  private
    FModule: HMODULE;
    FEntry: Pointer;      { PClapEntry }
    FPlugin: Pointer;     { PClapPlugin }
    FPath: string;
    FName, FVendor, FId: string;
    FSampleRate: Integer;
    FMaxFrames: Integer;
    FChannels: Integer;
    FActive, FProcessing: Boolean;
    FParamIds: TArray<Cardinal>;
    FParamMin, FParamMax: TArray<Double>;
    FParamNames: TArray<string>;
    FPendingIdx: TArray<Integer>;
    FPendingVal: TArray<Double>;
    FPendingCount: Integer;
    FScratchIn, FScratchOut: array of array of Single;
    FInPtrs, FOutPtrs: array of System.PSingle;
    FSteady: Int64;
    procedure ScanParams;
    function ExtParams: Pointer;
    function ExtState: Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure LoadOnly(const APath: string);
    procedure LoadAndOpen(const APath: string; ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Configure(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Close;
    procedure Process(const AIn, AOut: array of System.PSingle; AFrames: Integer);
    procedure Reset;
    function IsLoaded: Boolean;
    function EffectName: string;
    function VendorString: string;
    function ParamCount: Integer;
    function ParamName(AIndex: Integer): string;
    function GetParam(AIndex: Integer): Single;          { normalised 0..1 }
    procedure SetParam(AIndex: Integer; AValue: Single); { normalised 0..1 }
    function SaveStateBase64: string;
    procedure LoadStateBase64(const AState: string);
    property Path: string read FPath;
  end;

implementation

const
  CLAP_CORE_EVENT_SPACE_ID = 0;
  CLAP_EVENT_PARAM_VALUE = 5;
  CLAP_PROCESS_ERROR = 0;

type
  TClapVersion = record
    Major, Minor, Revision: Cardinal;
  end;

  PClapPluginDescriptor = ^TClapPluginDescriptor;
  TClapPluginDescriptor = record
    Version: TClapVersion;
    Id, Name, Vendor, Url, ManualUrl, SupportUrl, VersionStr, Description: PAnsiChar;
    Features: Pointer;
  end;

  PClapHost = ^TClapHostRec;
  TClapHostRec = record
    Version: TClapVersion;
    HostData: Pointer;
    Name, Vendor, Url, VersionStr: PAnsiChar;
    GetExtension: function(Host: PClapHost; Id: PAnsiChar): Pointer; cdecl;
    RequestRestart: procedure(Host: PClapHost); cdecl;
    RequestProcess: procedure(Host: PClapHost); cdecl;
    RequestCallback: procedure(Host: PClapHost); cdecl;
  end;

  PClapPlugin = ^TClapPlugin;
  PClapProcess = ^TClapProcess;
  TClapPlugin = record
    Desc: PClapPluginDescriptor;
    PluginData: Pointer;
    Init: function(P: PClapPlugin): ByteBool; cdecl;
    Destroy: procedure(P: PClapPlugin); cdecl;
    Activate: function(P: PClapPlugin; SampleRate: Double; MinFrames, MaxFrames: Cardinal): ByteBool; cdecl;
    Deactivate: procedure(P: PClapPlugin); cdecl;
    StartProcessing: function(P: PClapPlugin): ByteBool; cdecl;
    StopProcessing: procedure(P: PClapPlugin); cdecl;
    Reset: procedure(P: PClapPlugin); cdecl;
    Process: function(P: PClapPlugin; Proc: PClapProcess): Integer; cdecl;
    GetExtension: function(P: PClapPlugin; Id: PAnsiChar): Pointer; cdecl;
    OnMainThread: procedure(P: PClapPlugin); cdecl;
  end;

  PClapFactory = ^TClapFactory;
  TClapFactory = record
    GetPluginCount: function(F: PClapFactory): Cardinal; cdecl;
    GetPluginDescriptor: function(F: PClapFactory; Index: Cardinal): PClapPluginDescriptor; cdecl;
    CreatePlugin: function(F: PClapFactory; Host: PClapHost; PluginId: PAnsiChar): PClapPlugin; cdecl;
  end;

  PClapEntry = ^TClapEntry;
  TClapEntry = record
    Version: TClapVersion;
    Init: function(PluginPath: PAnsiChar): ByteBool; cdecl;
    Deinit: procedure; cdecl;
    GetFactory: function(FactoryId: PAnsiChar): Pointer; cdecl;
  end;

  TClapAudioBuffer = record
    Data32: ^System.PSingle;
    Data64: Pointer;
    ChannelCount: Cardinal;
    Latency: Cardinal;
    ConstantMask: UInt64;
  end;
  PClapAudioBuffer = ^TClapAudioBuffer;

  PClapEventHeader = ^TClapEventHeader;
  TClapEventHeader = record
    Size: Cardinal;
    Time: Cardinal;
    SpaceId: Word;
    EventType: Word;
    Flags: Cardinal;
  end;

  TClapEventParamValue = record
    Header: TClapEventHeader;
    ParamId: Cardinal;
    Cookie: Pointer;
    NoteId: Integer;
    PortIndex: SmallInt;
    Channel: SmallInt;
    Key: SmallInt;
    Value: Double;
  end;

  PClapInputEvents = ^TClapInputEvents;
  TClapInputEvents = record
    Ctx: Pointer;
    Size: function(L: PClapInputEvents): Cardinal; cdecl;
    Get: function(L: PClapInputEvents; Index: Cardinal): PClapEventHeader; cdecl;
  end;

  PClapOutputEvents = ^TClapOutputEvents;
  TClapOutputEvents = record
    Ctx: Pointer;
    TryPush: function(L: PClapOutputEvents; Ev: PClapEventHeader): ByteBool; cdecl;
  end;

  TClapProcess = record
    SteadyTime: Int64;
    FramesCount: Cardinal;
    Transport: Pointer;
    AudioInputs: PClapAudioBuffer;
    AudioOutputs: PClapAudioBuffer;
    AudioInputsCount: Cardinal;
    AudioOutputsCount: Cardinal;
    InEvents: PClapInputEvents;
    OutEvents: PClapOutputEvents;
  end;

  TClapParamInfo = record
    Id: Cardinal;
    Flags: Cardinal;
    Cookie: Pointer;
    Name: array[0..255] of AnsiChar;
    Module: array[0..1023] of AnsiChar;
    MinValue, MaxValue, DefaultValue: Double;
  end;

  PClapPluginParams = ^TClapPluginParams;
  TClapPluginParams = record
    Count: function(P: PClapPlugin): Cardinal; cdecl;
    GetInfo: function(P: PClapPlugin; Index: Cardinal; var Info: TClapParamInfo): ByteBool; cdecl;
    GetValue: function(P: PClapPlugin; ParamId: Cardinal; var Value: Double): ByteBool; cdecl;
    ValueToText: Pointer;
    TextToValue: Pointer;
    Flush: procedure(P: PClapPlugin; InEv: PClapInputEvents; OutEv: PClapOutputEvents); cdecl;
  end;

  PClapOStream = ^TClapOStream;
  TClapOStream = record
    Ctx: Pointer;
    Write: function(S: PClapOStream; Buffer: Pointer; Size: UInt64): Int64; cdecl;
  end;
  PClapIStream = ^TClapIStream;
  TClapIStream = record
    Ctx: Pointer;
    Read: function(S: PClapIStream; Buffer: Pointer; Size: UInt64): Int64; cdecl;
  end;

  PClapPluginState = ^TClapPluginState;
  TClapPluginState = record
    Save: function(P: PClapPlugin; S: PClapOStream): ByteBool; cdecl;
    Load: function(P: PClapPlugin; S: PClapIStream): ByteBool; cdecl;
  end;

  TClapEntryFn = Pointer;

{ ---- host callbacks (no host extensions offered) ---- }

function HostGetExtension(Host: PClapHost; Id: PAnsiChar): Pointer; cdecl;
begin
  Result := nil;
end;

procedure HostNoop(Host: PClapHost); cdecl;
begin
end;

var
  GHost: TClapHostRec;
  GHostInit: Boolean = False;

function EnsureHost: PClapHost;
begin
  if not GHostInit then
  begin
    FillChar(GHost, SizeOf(GHost), 0);
    GHost.Version.Major := 1;
    GHost.Version.Minor := 1;
    GHost.Version.Revision := 0;
    GHost.Name := 'UDAW';
    GHost.Vendor := 'Ultimanium';
    GHost.Url := 'https://ultimanium.com';
    GHost.VersionStr := '1.0';
    GHost.GetExtension := HostGetExtension;
    GHost.RequestRestart := HostNoop;
    GHost.RequestProcess := HostNoop;
    GHost.RequestCallback := HostNoop;
    GHostInit := True;
  end;
  Result := @GHost;
end;

{ ---- input / output event lists ---- }

type
  TEventCtx = record
    Events: array of TClapEventParamValue;
    Count: Integer;
  end;
  PEventCtx = ^TEventCtx;

function InSize(L: PClapInputEvents): Cardinal; cdecl;
begin
  Result := Cardinal(PEventCtx(L^.Ctx)^.Count);
end;

function InGet(L: PClapInputEvents; Index: Cardinal): PClapEventHeader; cdecl;
begin
  Result := @PEventCtx(L^.Ctx)^.Events[Index].Header;
end;

function OutPush(L: PClapOutputEvents; Ev: PClapEventHeader): ByteBool; cdecl;
begin
  Result := True; { plugin output events (e.g. param gestures) are discarded }
end;

{ ---- state streams ---- }

function OWrite(S: PClapOStream; Buffer: Pointer; Size: UInt64): Int64; cdecl;
var
  ms: TMemoryStream;
begin
  ms := TMemoryStream(S^.Ctx);
  Result := ms.Write(Buffer^, Size);
end;

function IRead(S: PClapIStream; Buffer: Pointer; Size: UInt64): Int64; cdecl;
var
  ms: TMemoryStream;
begin
  ms := TMemoryStream(S^.Ctx);
  Result := ms.Read(Buffer^, Size);
end;

{ ---- TCLAPHost ---- }

constructor TCLAPHost.Create;
begin
  inherited Create;
  FSampleRate := 44100;
end;

destructor TCLAPHost.Destroy;
begin
  Close;
  inherited;
end;

function TCLAPHost.IsLoaded: Boolean;
begin
  Result := FPlugin <> nil;
end;

function TCLAPHost.EffectName: string;
begin
  Result := FName;
end;

function TCLAPHost.VendorString: string;
begin
  Result := FVendor;
end;

function TCLAPHost.ExtParams: Pointer;
begin
  Result := nil;
  if FPlugin <> nil then
    Result := PClapPlugin(FPlugin)^.GetExtension(PClapPlugin(FPlugin), 'clap.params');
end;

function TCLAPHost.ExtState: Pointer;
begin
  Result := nil;
  if FPlugin <> nil then
    Result := PClapPlugin(FPlugin)^.GetExtension(PClapPlugin(FPlugin), 'clap.state');
end;

procedure TCLAPHost.LoadOnly(const APath: string);
var
  entry: PClapEntry;
  factory: PClapFactory;
  desc: PClapPluginDescriptor;
  p: PClapPlugin;
  pathA: AnsiString;
begin
  Close;
  FPath := APath;
  FModule := LoadLibrary(PChar(APath));
  if FModule = 0 then
    raise ECLAPError.CreateFmt('Cannot load CLAP module "%s" (error %d)', [APath, GetLastError]);
  FEntry := GetProcAddress(FModule, 'clap_entry');
  if FEntry = nil then
    raise ECLAPError.Create('Not a CLAP plugin: missing clap_entry export');
  entry := PClapEntry(FEntry);
  pathA := AnsiString(APath);
  if not entry^.Init(PAnsiChar(pathA)) then
    raise ECLAPError.Create('CLAP entry init failed');
  factory := entry^.GetFactory('clap.plugin-factory');
  if (factory = nil) or (factory^.GetPluginCount(factory) = 0) then
    raise ECLAPError.Create('CLAP module exposes no plugins');
  desc := factory^.GetPluginDescriptor(factory, 0);
  FId := string(AnsiString(desc^.Id));
  FName := string(AnsiString(desc^.Name));
  FVendor := string(AnsiString(desc^.Vendor));
  p := factory^.CreatePlugin(factory, EnsureHost, desc^.Id);
  if p = nil then
    raise ECLAPError.Create('CLAP create_plugin failed');
  FPlugin := p;
  if not p^.Init(p) then
  begin
    FPlugin := nil;
    raise ECLAPError.Create('CLAP plugin init failed');
  end;
  ScanParams;
end;

procedure TCLAPHost.ScanParams;
var
  pe: PClapPluginParams;
  n, i: Cardinal;
  info: TClapParamInfo;
  cnt: Integer;
begin
  SetLength(FParamIds, 0);
  pe := ExtParams;
  if pe = nil then Exit;
  n := pe^.Count(PClapPlugin(FPlugin));
  SetLength(FParamIds, n);
  SetLength(FParamMin, n);
  SetLength(FParamMax, n);
  SetLength(FParamNames, n);
  cnt := 0;
  for i := 0 to n - 1 do
  begin
    FillChar(info, SizeOf(info), 0);
    if pe^.GetInfo(PClapPlugin(FPlugin), i, info) then
    begin
      FParamIds[cnt] := info.Id;
      FParamMin[cnt] := info.MinValue;
      FParamMax[cnt] := info.MaxValue;
      FParamNames[cnt] := string(AnsiString(PAnsiChar(@info.Name[0])));
      Inc(cnt);
    end;
  end;
  SetLength(FParamIds, cnt);
  SetLength(FParamMin, cnt);
  SetLength(FParamMax, cnt);
  SetLength(FParamNames, cnt);
  SetLength(FPendingIdx, Max(cnt, 1) * 2);
  SetLength(FPendingVal, Max(cnt, 1) * 2);
end;

procedure TCLAPHost.LoadAndOpen(const APath: string; ASampleRate, AMaxFrames, AChannels: Integer);
begin
  LoadOnly(APath);
  Configure(ASampleRate, AMaxFrames, AChannels);
end;

procedure TCLAPHost.Configure(ASampleRate, AMaxFrames, AChannels: Integer);
var
  p: PClapPlugin;
  ch: Integer;
begin
  if FPlugin = nil then Exit;
  p := PClapPlugin(FPlugin);
  if FActive then
  begin
    if FProcessing then p^.StopProcessing(p);
    p^.Deactivate(p);
    FActive := False;
    FProcessing := False;
  end;
  FSampleRate := ASampleRate;
  FMaxFrames := Max(AMaxFrames, 1);
  FChannels := Max(AChannels, 1);
  SetLength(FScratchIn, FChannels);
  SetLength(FScratchOut, FChannels);
  SetLength(FInPtrs, FChannels);
  SetLength(FOutPtrs, FChannels);
  for ch := 0 to FChannels - 1 do
  begin
    SetLength(FScratchIn[ch], FMaxFrames);
    SetLength(FScratchOut[ch], FMaxFrames);
    FInPtrs[ch] := @FScratchIn[ch][0];
    FOutPtrs[ch] := @FScratchOut[ch][0];
  end;
  if not p^.Activate(p, FSampleRate, 1, FMaxFrames) then
    raise ECLAPError.Create('CLAP activate failed');
  FActive := True;
  if p^.StartProcessing(p) then FProcessing := True;
end;

procedure TCLAPHost.Close;
var
  p: PClapPlugin;
begin
  if FPlugin <> nil then
  begin
    p := PClapPlugin(FPlugin);
    if FProcessing then p^.StopProcessing(p);
    if FActive then p^.Deactivate(p);
    p^.Destroy(p);
    FPlugin := nil;
  end;
  FActive := False;
  FProcessing := False;
  if FEntry <> nil then
  begin
    PClapEntry(FEntry)^.Deinit;
    FEntry := nil;
  end;
  if FModule <> 0 then
  begin
    FreeLibrary(FModule);
    FModule := 0;
  end;
end;

procedure TCLAPHost.Reset;
var
  p: PClapPlugin;
begin
  if FPlugin = nil then Exit;
  p := PClapPlugin(FPlugin);
  p^.Reset(p);
end;

procedure TCLAPHost.Process(const AIn, AOut: array of System.PSingle; AFrames: Integer);
var
  p: PClapPlugin;
  pr: TClapProcess;
  bufIn, bufOut: TClapAudioBuffer;
  ev: TEventCtx;
  inEv: TClapInputEvents;
  outEv: TClapOutputEvents;
  ch, nc, i: Integer;
  st: Integer;
begin
  if (FPlugin = nil) or (not FProcessing) or (AFrames <= 0) then Exit;
  if AFrames > FMaxFrames then AFrames := FMaxFrames;
  p := PClapPlugin(FPlugin);
  nc := Min(Min(Length(AIn), Length(AOut)), FChannels);
  for ch := 0 to nc - 1 do
    Move(AIn[ch]^, FScratchIn[ch][0], AFrames * SizeOf(Single));
  { queue pending parameter changes as CLAP param-value events }
  SetLength(ev.Events, FPendingCount);
  ev.Count := FPendingCount;
  for i := 0 to FPendingCount - 1 do
  begin
    FillChar(ev.Events[i], SizeOf(TClapEventParamValue), 0);
    ev.Events[i].Header.Size := SizeOf(TClapEventParamValue);
    ev.Events[i].Header.Time := 0;
    ev.Events[i].Header.SpaceId := CLAP_CORE_EVENT_SPACE_ID;
    ev.Events[i].Header.EventType := CLAP_EVENT_PARAM_VALUE;
    ev.Events[i].ParamId := FParamIds[FPendingIdx[i]];
    ev.Events[i].NoteId := -1;
    ev.Events[i].PortIndex := -1;
    ev.Events[i].Channel := -1;
    ev.Events[i].Key := -1;
    ev.Events[i].Value := FPendingVal[i];
  end;
  FPendingCount := 0;
  inEv.Ctx := @ev;
  inEv.Size := InSize;
  inEv.Get := InGet;
  outEv.Ctx := nil;
  outEv.TryPush := OutPush;
  bufIn.Data32 := @FInPtrs[0];
  bufIn.Data64 := nil;
  bufIn.ChannelCount := FChannels;
  bufIn.Latency := 0;
  bufIn.ConstantMask := 0;
  bufOut := bufIn;
  bufOut.Data32 := @FOutPtrs[0];
  FillChar(pr, SizeOf(pr), 0);
  pr.SteadyTime := FSteady;
  pr.FramesCount := AFrames;
  pr.AudioInputs := @bufIn;
  pr.AudioOutputs := @bufOut;
  pr.AudioInputsCount := 1;
  pr.AudioOutputsCount := 1;
  pr.InEvents := @inEv;
  pr.OutEvents := @outEv;
  st := p^.Process(p, @pr);
  Inc(FSteady, AFrames);
  if st = CLAP_PROCESS_ERROR then
    raise ECLAPError.Create('CLAP process returned an error');
  for ch := 0 to nc - 1 do
    Move(FScratchOut[ch][0], AOut[ch]^, AFrames * SizeOf(Single));
end;

function TCLAPHost.ParamCount: Integer;
begin
  Result := Length(FParamIds);
end;

function TCLAPHost.ParamName(AIndex: Integer): string;
begin
  if (AIndex >= 0) and (AIndex < Length(FParamNames)) then Result := FParamNames[AIndex]
  else Result := '';
end;

function TCLAPHost.GetParam(AIndex: Integer): Single;
var
  pe: PClapPluginParams;
  v: Double;
begin
  Result := 0;
  pe := ExtParams;
  if (pe = nil) or (AIndex < 0) or (AIndex >= Length(FParamIds)) then Exit;
  if pe^.GetValue(PClapPlugin(FPlugin), FParamIds[AIndex], v) then
    if FParamMax[AIndex] > FParamMin[AIndex] then
      Result := (v - FParamMin[AIndex]) / (FParamMax[AIndex] - FParamMin[AIndex]);
end;

procedure TCLAPHost.SetParam(AIndex: Integer; AValue: Single);
begin
  if (AIndex < 0) or (AIndex >= Length(FParamIds)) then Exit;
  if FPendingCount >= Length(FPendingIdx) then Exit;
  FPendingIdx[FPendingCount] := AIndex;
  FPendingVal[FPendingCount] := FParamMin[AIndex] +
    EnsureRange(AValue, 0.0, 1.0) * (FParamMax[AIndex] - FParamMin[AIndex]);
  Inc(FPendingCount);
end;

function TCLAPHost.SaveStateBase64: string;
var
  se: PClapPluginState;
  ms: TMemoryStream;
  os: TClapOStream;
  bytes: TBytes;
begin
  Result := '';
  se := ExtState;
  if se = nil then Exit;
  ms := TMemoryStream.Create;
  try
    os.Ctx := ms;
    os.Write := OWrite;
    if se^.Save(PClapPlugin(FPlugin), @os) and (ms.Size > 0) then
    begin
      SetLength(bytes, ms.Size);
      Move(ms.Memory^, bytes[0], ms.Size);
      Result := TNetEncoding.Base64.EncodeBytesToString(bytes);
    end;
  finally
    ms.Free;
  end;
end;

procedure TCLAPHost.LoadStateBase64(const AState: string);
var
  se: PClapPluginState;
  ms: TMemoryStream;
  isr: TClapIStream;
  bytes: TBytes;
begin
  se := ExtState;
  if (se = nil) or (AState = '') then Exit;
  bytes := TNetEncoding.Base64.DecodeStringToBytes(AState);
  ms := TMemoryStream.Create;
  try
    ms.WriteBuffer(bytes[0], Length(bytes));
    ms.Position := 0;
    isr.Ctx := ms;
    isr.Read := IRead;
    se^.Load(PClapPlugin(FPlugin), @isr);
  finally
    ms.Free;
  end;
end;

end.
