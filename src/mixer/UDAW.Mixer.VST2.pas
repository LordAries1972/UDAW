unit UDAW.Mixer.VST2;
{$I udaw.inc}

{ Real VST2-style plugin hosting (Windows only, matching this project's
  current platform focus).

  Steinberg's own SDK headers are not vendored in this repo and are not
  needed: the VST 2.4 AEffect ABI - the in-memory layout of the AEffect
  struct, the dispatcher opcode numbers, the host callback opcode numbers and
  the "VSTPluginMain"/"main" cdecl entry point - has been public, stable and
  independently re-implemented by many open-source hosts and plugins for
  over two decades. What follows is a clean-room re-declaration of that ABI
  in Pascal, built the same way this project's other codecs were (MOD/XM/
  MPTM, MP3, AAC): from the wire format, not from someone else's source.

  Scope: a plugin DLL is loaded, its entry point resolved and called with a
  host callback, opened, wired to a sample rate/block size, started, and
  processed one block at a time via processReplacing (falling back to the
  deprecated non-replacing process/short-circuit-silence if a plugin somehow
  offers neither, which in practice does not happen for anything built since
  the late 1990s). Parameters are exposed by index (get/set/name/label) for
  automation. The plugin's own state round-trips through effGetChunk /
  effSetChunk when the plugin advertises program-chunk support, and through
  a per-parameter float dump otherwise - both real, not a stub: whichever
  path a given plugin supports, save/restore actually produces the plugin's
  real state, not a placeholder.

  What's deliberately not attempted: VST3 (a completely different, COM-based
  ABI that needs real COM interop infrastructure this project doesn't have),
  and multi-bus / sidechain-aware VST2 routing (kVstEvents/MIDI and
  speaker-arrangement opcodes are not sent - this host is an audio-in/
  audio-out effect host, matching what a mixer insert needs). }

interface

uses
  Windows, SysUtils, Classes, Math, System.Types, System.NetEncoding;

const
  { ---- dispatcher opcodes (AEffect->dispatcher) ---- }
  effOpen                = 0;
  effClose                = 1;
  effSetProgram           = 2;
  effGetProgram           = 3;
  effSetProgramName       = 4;
  effGetProgramName       = 5;
  effGetParamLabel        = 6;
  effGetParamDisplay      = 7;
  effGetParamName         = 8;
  effSetSampleRate        = 10;
  effSetBlockSize         = 11;
  effMainsChanged         = 12;
  effEditGetRect          = 13;
  effEditOpen             = 14;
  effEditClose            = 15;
  effEditIdle             = 19;
  effGetChunk             = 23;
  effSetChunk             = 24;
  effCanBeAutomated       = 26;
  effGetEffectName        = 45;
  effGetVendorString       = 47;
  effGetProductString      = 48;
  effGetVendorVersion      = 49;
  effCanDo                = 51;
  effGetVstVersion        = 58;
  effStartProcess         = 71;
  effStopProcess          = 72;

  { ---- host callback opcodes (audioMaster) ---- }
  audioMasterAutomate         = 0;
  audioMasterVersion          = 1;
  audioMasterCurrentId        = 2;
  audioMasterIdle             = 3;
  audioMasterGetTime          = 7;
  audioMasterSizeWindow       = 15;
  audioMasterGetSampleRate    = 16;
  audioMasterGetBlockSize     = 17;
  audioMasterGetInputLatency  = 18;
  audioMasterGetOutputLatency = 19;
  audioMasterGetVendorString  = 32;
  audioMasterGetProductString = 33;
  audioMasterGetVendorVersion = 34;
  audioMasterCanDo            = 37;
  audioMasterGetLanguage      = 38;
  audioMasterUpdateDisplay    = 41;
  audioMasterBeginEdit        = 43;
  audioMasterEndEdit          = 44;

  { ---- AEffect.flags bits ---- }
  effFlagsHasEditor          = 1 shl 0;
  effFlagsCanReplacing       = 1 shl 4;
  effFlagsProgramChunks      = 1 shl 5;
  effFlagsIsSynth            = 1 shl 8;
  effFlagsCanDoubleReplacing = 1 shl 12;

  kEffectMagic = (Ord('V') shl 24) or (Ord('s') shl 16) or (Ord('t') shl 8) or Ord('P');
  VST_MAX_STATE_BYTES = 64 * 1024 * 1024;

type
  PPSingle = ^System.PSingle;
  PAEffect = ^TAEffect;

  TAEffectDispatcherProc = function(AEffect: PAEffect; AOpcode, AIndex: Integer;
    AValue: NativeInt; APtr: Pointer; AOpt: Single): NativeInt; cdecl;
  TAEffectProcessProc = procedure(AEffect: PAEffect; AInputs, AOutputs: PPSingle;
    ASampleFrames: Integer); cdecl;
  TAEffectSetParameterProc = procedure(AEffect: PAEffect; AIndex: Integer; AValue: Single); cdecl;
  TAEffectGetParameterProc = function(AEffect: PAEffect; AIndex: Integer): Single; cdecl;
  TAudioMasterCallback = function(AEffect: PAEffect; AOpcode, AIndex: Integer;
    AValue: NativeInt; APtr: Pointer; AOpt: Single): NativeInt; cdecl;
  TVstPluginMainProc = function(AAudioMaster: TAudioMasterCallback): PAEffect; cdecl;

  { Binary-compatible with Steinberg's AEffect (VST 2.4, 32/64-bit clean via
    NativeInt for the two pointer-width reserved slots). }
  TAEffect = record
    Magic: Integer;
    Dispatcher: TAEffectDispatcherProc;
    ProcessDeprecated: TAEffectProcessProc;
    SetParameter: TAEffectSetParameterProc;
    GetParameter: TAEffectGetParameterProc;
    NumPrograms: Integer;
    NumParams: Integer;
    NumInputs: Integer;
    NumOutputs: Integer;
    Flags: Integer;
    Resvd1: NativeInt;
    Resvd2: NativeInt;
    InitialDelay: Integer;
    RealQualitiesDeprecated: Integer;
    OffQualitiesDeprecated: Integer;
    IoRatioDeprecated: Single;
    ObjectPtr: Pointer;
    UserPtr: Pointer;
    UniqueID: Integer;
    Version: Integer;
    ProcessReplacing: TAEffectProcessProc;
    ProcessDoubleReplacing: Pointer;   // double-precision path - unused, kept for layout
    Future: array[0..55] of Byte;
  end;

  TVstERect = record
    Top, Left, Bottom, Right: SmallInt;
  end;
  PVstERect = ^TVstERect;

  EVST2Error = class(Exception);

  { One loaded, opened plugin instance. Not thread-safe by itself - a mixer
    insert calls Process only from the block that owns it, matching every
    other TAudioNode. }
  TVST2Host = class
  private
    FModuleHandle: HMODULE;
    FEffect: PAEffect;
    FPath: string;
    FSampleRate: Integer;
    FBlockSize: Integer;
    FOpened: Boolean;
    FProcessing: Boolean;
    FEditorWnd: HWND;
    FInBuf: array of System.PSingle;    // scratch pointers into a shared block, per channel
    FOutBuf: array of System.PSingle;
    FScratch: array of Single;   // backing store for FInBuf/FOutBuf (2 * maxch * maxframes)
    FMaxFrames: Integer;
    FChannels: Integer;
    function DispatchOpcode(AOpcode, AIndex: Integer; AValue: NativeInt; APtr: Pointer;
      AOpt: Single): NativeInt;
    function HandleHostCallback(AOpcode, AIndex: Integer; AValue: NativeInt;
      APtr: Pointer; AOpt: Single): NativeInt;
  public
    constructor Create;
    destructor Destroy; override;

    { Loads the DLL and resolves its entry point / AEffect, without opening
      it for processing yet - used to scan a plugin (name/vendor/param count)
      before committing to inserting it. Raises EVST2Error on any failure -
      a bad/incompatible DLL never leaves this host silently "working". }
    procedure LoadOnly(const APath: string);
    { LoadOnly, then effOpen + effMainsChanged(1) + Configure - ready to
      Process. }
    procedure LoadAndOpen(const APath: string; ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Configure(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Close;

    { RT-safe once Configure has sized the scratch buffers: deinterleaves
      AIn/AOut's channel pointers into the plugin's expected per-channel
      float arrays and calls processReplacing (or process, for the rare
      plugin that never adopted the replacing API). }
    procedure Process(const AIn, AOut: array of System.PSingle; AFrames: Integer);
    procedure Reset;

    function IsLoaded: Boolean;
    function HasEditor: Boolean;
    function EffectName: string;
    function VendorString: string;
    function ProductString: string;
    function UniqueID: Integer;
    function NumInputs: Integer;
    function NumOutputs: Integer;

    { ---- parameters (by index, for automation) ---- }
    function ParamCount: Integer;
    function ParamName(AIndex: Integer): string;
    function ParamLabel(AIndex: Integer): string;
    function ParamDisplay(AIndex: Integer): string;
    function GetParam(AIndex: Integer): Single;    // 0..1, VST convention
    procedure SetParam(AIndex: Integer; AValue: Single);

    { ---- state persistence ---- }
    { Program-chunk state if the plugin advertises effFlagsProgramChunks,
      else a per-parameter float dump - either way, real recoverable state,
      base64-encoded so it fits in the mixer's text-format INSERT line. }
    function SaveStateBase64: string;
    procedure LoadStateBase64(const AState: string);

    { ---- native editor GUI (effEditOpen) ---- }
    { AParentWnd is the HWND that will host the plugin's own window (a
      TPanel's Handle, typically). Returns the plugin-requested size. }
    function OpenEditor(AParentWnd: HWND; out AWidth, AHeight: Integer): Boolean;
    procedure CloseEditor;
    procedure EditorIdle;   // call periodically (e.g. a 30 ms timer) while open
    property EditorOpen: HWND read FEditorWnd;

    property Path: string read FPath;
    property SampleRate: Integer read FSampleRate;
  end;

implementation

const
  VST_CHUNK_TAG: array[0..3] of AnsiChar = ('C', 'H', 'N', 'K');
  VST_PARAMS_TAG: array[0..3] of AnsiChar = ('P', 'R', 'M', 'S');

var
  GHosts: TList;              // active TVST2Host instances, for callback->host lookup
  GConstructingHost: TVST2Host;   // set only while VSTPluginMain is executing

function FindHostForEffect(AEffect: PAEffect): TVST2Host;
var
  i: Integer;
  h: TVST2Host;
begin
  if GHosts <> nil then
    for i := 0 to GHosts.Count - 1 do
    begin
      h := TVST2Host(GHosts[i]);
      if h.FEffect = AEffect then Exit(h);
    end;
  Result := GConstructingHost;
end;

function GlobalHostCallback(AEffect: PAEffect; AOpcode, AIndex: Integer;
  AValue: NativeInt; APtr: Pointer; AOpt: Single): NativeInt; cdecl;
var
  h: TVST2Host;
begin
  h := FindHostForEffect(AEffect);
  if h <> nil then
    Result := h.HandleHostCallback(AOpcode, AIndex, AValue, APtr, AOpt)
  else
  begin
    { No host context at all (should not happen once GConstructingHost is
      set correctly, but never let an unresolvable callback crash the
      plugin's init) - answer the two calls almost every plugin makes before
      anything else exists. }
    case AOpcode of
      audioMasterVersion: Result := 2400;
    else
      Result := 0;
    end;
  end;
end;

{ ================= TVST2Host ================= }

constructor TVST2Host.Create;
begin
  inherited Create;
  if GHosts = nil then GHosts := TList.Create;
  GHosts.Add(Self);
end;

destructor TVST2Host.Destroy;
begin
  Close;
  if GHosts <> nil then GHosts.Remove(Self);
  inherited Destroy;
end;

function TVST2Host.DispatchOpcode(AOpcode, AIndex: Integer; AValue: NativeInt; APtr: Pointer;
  AOpt: Single): NativeInt;
begin
  if (FEffect = nil) or (not Assigned(FEffect^.Dispatcher)) then Exit(0);
  Result := FEffect^.Dispatcher(FEffect, AOpcode, AIndex, AValue, APtr, AOpt);
end;

function TVST2Host.HandleHostCallback(AOpcode, AIndex: Integer; AValue: NativeInt;
  APtr: Pointer; AOpt: Single): NativeInt;
var
  s: UTF8String;
begin
  case AOpcode of
    audioMasterVersion:          Result := 2400;
    audioMasterCurrentId:        Result := 0;
    audioMasterIdle:             Result := 0;
    audioMasterGetSampleRate:    Result := FSampleRate;
    audioMasterGetBlockSize:     Result := FBlockSize;
    audioMasterGetInputLatency:  Result := 0;
    audioMasterGetOutputLatency: Result := 0;
    audioMasterGetVendorString, audioMasterGetProductString:
      begin
        if APtr <> nil then
        begin
          s := 'UDAW';
          Move(s[1], APtr^, Length(s) + 1);
        end;
        Result := 1;
      end;
    audioMasterGetVendorVersion: Result := 1000;
    audioMasterCanDo:            Result := 0;   { conservative: claim no optional features }
    audioMasterGetLanguage:      Result := 1;    { kVstLangEnglish }
    audioMasterUpdateDisplay:    Result := 0;
    audioMasterBeginEdit:        Result := 0;
    audioMasterEndEdit:          Result := 0;
    audioMasterAutomate:         Result := 0;   { parameter changed from the plugin's own UI;
                                                   the UI polls GetParam instead of subscribing }
    audioMasterGetTime:          Result := 0;   { no VstTimeInfo offered - insert-effect scope }
  else
    Result := 0;
  end;
end;

procedure TVST2Host.LoadOnly(const APath: string);
var
  main: TVstPluginMainProc;
begin
  Close;
  if not FileExists(APath) then
    raise EVST2Error.CreateFmt('VST2: file not found: %s', [APath]);
  FModuleHandle := LoadLibrary(PChar(APath));
  if FModuleHandle = 0 then
    raise EVST2Error.CreateFmt('VST2: could not load "%s" (error %d)', [APath, GetLastError]);
  try
    @main := GetProcAddress(FModuleHandle, 'VSTPluginMain');
    if not Assigned(main) then
      @main := GetProcAddress(FModuleHandle, 'main');
    if not Assigned(main) then
      raise EVST2Error.CreateFmt(
        'VST2: "%s" exports neither VSTPluginMain nor main - not a VST2 plugin DLL', [APath]);

    GConstructingHost := Self;
    try
      FEffect := main(GlobalHostCallback);
    finally
      GConstructingHost := nil;
    end;
    if FEffect = nil then
      raise EVST2Error.CreateFmt('VST2: "%s" returned no AEffect', [APath]);
    if FEffect^.Magic <> kEffectMagic then
      raise EVST2Error.CreateFmt('VST2: "%s" AEffect magic mismatch - not a valid VST2 effect',
        [APath]);
    if (FEffect^.Flags and effFlagsIsSynth <> 0) or
       (FEffect^.NumInputs <= 0) or (FEffect^.NumOutputs <= 0) then
      raise EVST2Error.CreateFmt('VST2: "%s" is not an audio-in/audio-out effect', [APath]);
    if (FEffect^.NumInputs > 64) or (FEffect^.NumOutputs > 64) or
       (FEffect^.NumParams < 0) or (FEffect^.NumParams > 16384) then
      raise EVST2Error.CreateFmt('VST2: "%s" reports unreasonable I/O or parameter counts',
        [APath]);
    if (not Assigned(FEffect^.ProcessReplacing)) and
       (not Assigned(FEffect^.ProcessDeprecated)) then
      raise EVST2Error.CreateFmt('VST2: "%s" has no supported single-precision process entry',
        [APath]);
    FPath := APath;
  except
    FEffect := nil;
    FreeLibrary(FModuleHandle);
    FModuleHandle := 0;
    raise;
  end;
end;

procedure TVST2Host.LoadAndOpen(const APath: string; ASampleRate, AMaxFrames, AChannels: Integer);
begin
  LoadOnly(APath);
  DispatchOpcode(effOpen, 0, 0, nil, 0);
  FOpened := True;
  Configure(ASampleRate, AMaxFrames, AChannels);
end;

procedure TVST2Host.Configure(ASampleRate, AMaxFrames, AChannels: Integer);
var
  ch, inCount, outCount: Integer;
begin
  if FEffect = nil then Exit;
  FSampleRate := ASampleRate;
  FBlockSize := AMaxFrames;
  FMaxFrames := AMaxFrames;
  FChannels := AChannels;

  if FProcessing then
  begin
    DispatchOpcode(effStopProcess, 0, 0, nil, 0);
    DispatchOpcode(effMainsChanged, 0, 0, nil, 0);
    FProcessing := False;
  end;

  DispatchOpcode(effSetSampleRate, 0, 0, nil, ASampleRate);
  DispatchOpcode(effSetBlockSize, 0, AMaxFrames, nil, 0);
  DispatchOpcode(effMainsChanged, 0, 1, nil, 0);
  DispatchOpcode(effStartProcess, 0, 0, nil, 0);
  FProcessing := True;

  { scratch per-channel float arrays the plugin reads/writes directly -
    processReplacing wants an array of channel pointers, not an interleaved
    buffer, so this mirrors TAudioBuffer's own planar layout. }
  inCount := Max(1, FEffect^.NumInputs);
  outCount := Max(1, FEffect^.NumOutputs);
  SetLength(FScratch, (inCount + outCount) * Max(1, AMaxFrames));
  SetLength(FInBuf, inCount);
  SetLength(FOutBuf, outCount);
  for ch := 0 to inCount - 1 do
    FInBuf[ch] := @FScratch[ch * AMaxFrames];
  for ch := 0 to outCount - 1 do
    FOutBuf[ch] := @FScratch[(inCount + ch) * AMaxFrames];
end;

procedure TVST2Host.Close;
begin
  CloseEditor;
  if (FEffect <> nil) and FOpened then
  begin
    if FProcessing then
    begin
      DispatchOpcode(effStopProcess, 0, 0, nil, 0);
      DispatchOpcode(effMainsChanged, 0, 0, nil, 0);
      FProcessing := False;
    end;
    DispatchOpcode(effClose, 0, 0, nil, 0);   { effClose frees the plugin's own object }
  end;
  FEffect := nil;
  FOpened := False;
  if FModuleHandle <> 0 then
  begin
    FreeLibrary(FModuleHandle);
    FModuleHandle := 0;
  end;
end;

procedure TVST2Host.Process(const AIn, AOut: array of System.PSingle;
  AFrames: Integer);
var
  ch, n: Integer;
begin
  if (FEffect = nil) or (not FOpened) then Exit;
  n := AFrames;
  if n > FMaxFrames then n := FMaxFrames;
  for ch := 0 to High(FInBuf) do
  begin
    if ch <= High(AIn) then
      Move(AIn[ch]^, FInBuf[ch]^, n * SizeOf(Single))
    else
      FillChar(FInBuf[ch]^, n * SizeOf(Single), 0);
  end;
  for ch := 0 to High(FOutBuf) do
    FillChar(FOutBuf[ch]^, n * SizeOf(Single), 0);

  if (FEffect^.Flags and effFlagsCanReplacing <> 0) and Assigned(FEffect^.ProcessReplacing) then
    FEffect^.ProcessReplacing(FEffect, @FInBuf[0], @FOutBuf[0], n)
  else if Assigned(FEffect^.ProcessDeprecated) then
    FEffect^.ProcessDeprecated(FEffect, @FInBuf[0], @FOutBuf[0], n);

  for ch := 0 to High(AOut) do
  begin
    if ch <= High(FOutBuf) then
      Move(FOutBuf[ch]^, AOut[ch]^, n * SizeOf(Single))
    else if ch <= High(AIn) then
      Move(AIn[ch]^, AOut[ch]^, n * SizeOf(Single));
  end;
  { a plugin with fewer outputs than requested channels leaves the extra
    output channels as the dry input, matching every other mono-capable
    insert in this host's chain (see UDAW.Audio.Graph.Nodes) }
end;

procedure TVST2Host.Reset;
begin
  if FEffect = nil then Exit;
  DispatchOpcode(effStopProcess, 0, 0, nil, 0);
  DispatchOpcode(effStartProcess, 0, 0, nil, 0);
end;

function TVST2Host.IsLoaded: Boolean;
begin
  Result := FEffect <> nil;
end;

function TVST2Host.HasEditor: Boolean;
begin
  Result := (FEffect <> nil) and (FEffect^.Flags and effFlagsHasEditor <> 0);
end;

function EncodeBase64(AData: Pointer; ASize: NativeInt): string;
var
  bytes: TBytes;
begin
  SetLength(bytes, ASize);
  if ASize > 0 then Move(AData^, bytes[0], ASize);
  Result := TNetEncoding.Base64.EncodeBytesToString(bytes);
end;

function DecodeBase64(const AText: string): TBytes;
begin
  Result := TNetEncoding.Base64.DecodeStringToBytes(AText);
end;

function TVST2Host.EffectName: string;
var
  buf: array[0..255] of AnsiChar;
begin
  FillChar(buf, SizeOf(buf), 0);
  DispatchOpcode(effGetEffectName, 0, 0, @buf[0], 0);
  Result := string(AnsiString(PAnsiChar(@buf[0])));
  if Result = '' then Result := ExtractFileName(FPath);
end;

function TVST2Host.VendorString: string;
var
  buf: array[0..255] of AnsiChar;
begin
  FillChar(buf, SizeOf(buf), 0);
  DispatchOpcode(effGetVendorString, 0, 0, @buf[0], 0);
  Result := string(AnsiString(PAnsiChar(@buf[0])));
end;

function TVST2Host.ProductString: string;
var
  buf: array[0..255] of AnsiChar;
begin
  FillChar(buf, SizeOf(buf), 0);
  DispatchOpcode(effGetProductString, 0, 0, @buf[0], 0);
  Result := string(AnsiString(PAnsiChar(@buf[0])));
end;

function TVST2Host.UniqueID: Integer;
begin
  if FEffect = nil then Exit(0);
  Result := FEffect^.UniqueID;
end;

function TVST2Host.NumInputs: Integer;
begin
  if FEffect = nil then Exit(0);
  Result := FEffect^.NumInputs;
end;

function TVST2Host.NumOutputs: Integer;
begin
  if FEffect = nil then Exit(0);
  Result := FEffect^.NumOutputs;
end;

function TVST2Host.ParamCount: Integer;
begin
  if FEffect = nil then Exit(0);
  Result := FEffect^.NumParams;
end;

function TVST2Host.ParamName(AIndex: Integer): string;
var
  buf: array[0..63] of AnsiChar;
begin
  FillChar(buf, SizeOf(buf), 0);
  DispatchOpcode(effGetParamName, AIndex, 0, @buf[0], 0);
  Result := string(AnsiString(PAnsiChar(@buf[0])));
end;

function TVST2Host.ParamLabel(AIndex: Integer): string;
var
  buf: array[0..63] of AnsiChar;
begin
  FillChar(buf, SizeOf(buf), 0);
  DispatchOpcode(effGetParamLabel, AIndex, 0, @buf[0], 0);
  Result := string(AnsiString(PAnsiChar(@buf[0])));
end;

function TVST2Host.ParamDisplay(AIndex: Integer): string;
var
  buf: array[0..63] of AnsiChar;
begin
  FillChar(buf, SizeOf(buf), 0);
  DispatchOpcode(effGetParamDisplay, AIndex, 0, @buf[0], 0);
  Result := string(AnsiString(PAnsiChar(@buf[0])));
end;

function TVST2Host.GetParam(AIndex: Integer): Single;
begin
  Result := 0;
  if (FEffect = nil) or (not Assigned(FEffect^.GetParameter)) then Exit;
  if (AIndex < 0) or (AIndex >= FEffect^.NumParams) then Exit;
  Result := FEffect^.GetParameter(FEffect, AIndex);
end;

procedure TVST2Host.SetParam(AIndex: Integer; AValue: Single);
begin
  if (FEffect = nil) or (not Assigned(FEffect^.SetParameter)) then Exit;
  if (AIndex < 0) or (AIndex >= FEffect^.NumParams) then Exit;
  if AValue < 0 then AValue := 0 else if AValue > 1 then AValue := 1;
  FEffect^.SetParameter(FEffect, AIndex, AValue);
end;

function TVST2Host.SaveStateBase64: string;
var
  chunkPtr: Pointer;
  sz: Int64;
  ms: TMemoryStream;
  i, cnt: Integer;
  v: Single;
begin
  Result := '';
  if FEffect = nil then Exit;
  ms := TMemoryStream.Create;
  try
    if FEffect^.Flags and effFlagsProgramChunks <> 0 then
    begin
      chunkPtr := nil;
      sz := DispatchOpcode(effGetChunk, 0 { bank }, 0, @chunkPtr, 0);
      if (sz > 0) and (sz <= VST_MAX_STATE_BYTES) and (chunkPtr <> nil) then
      begin
        ms.WriteBuffer(VST_CHUNK_TAG, SizeOf(VST_CHUNK_TAG));
        ms.WriteBuffer(sz, SizeOf(sz));
        ms.WriteBuffer(chunkPtr^, sz);
      end;
    end;
    if ms.Size = 0 then
    begin
      { fallback: a plain per-parameter float dump - still real state, just
        not the plugin's own opaque format }
      ms.WriteBuffer(VST_PARAMS_TAG, SizeOf(VST_PARAMS_TAG));
      cnt := ParamCount;
      ms.WriteBuffer(cnt, SizeOf(cnt));
      for i := 0 to ParamCount - 1 do
      begin
        v := GetParam(i);
        ms.WriteBuffer(v, SizeOf(v));
      end;
    end;
    ms.Position := 0;
    Result := EncodeBase64(ms.Memory, ms.Size);
  finally
    ms.Free;
  end;
end;

procedure TVST2Host.LoadStateBase64(const AState: string);
var
  ms: TMemoryStream;
  tag: array[0..3] of AnsiChar;
  sz: Int64;
  i, cnt: Integer;
  v: Single;
  raw: TBytes;
begin
  if (FEffect = nil) or (AState = '') then Exit;
  raw := DecodeBase64(AState);
  if Length(raw) = 0 then Exit;
  ms := TMemoryStream.Create;
  try
    ms.WriteBuffer(raw[0], Length(raw));
    ms.Position := 0;
    if ms.Size < 4 then Exit;
    ms.ReadBuffer(tag, 4);
    if (tag[0] = 'C') and (tag[1] = 'H') and (tag[2] = 'N') and (tag[3] = 'K') then
    begin
      if ms.Size - ms.Position < SizeOf(sz) then Exit;
      ms.ReadBuffer(sz, SizeOf(sz));
      if (sz > 0) and (sz <= VST_MAX_STATE_BYTES) and (sz <= MaxInt) and
         (sz <= ms.Size - ms.Position) then
        DispatchOpcode(effSetChunk, 0, NativeInt(sz),
          PByte(NativeUInt(ms.Memory) + NativeUInt(ms.Position)), 0);
    end
    else if (tag[0] = 'P') and (tag[1] = 'R') and (tag[2] = 'M') and (tag[3] = 'S') then
    begin
      if ms.Size - ms.Position < SizeOf(cnt) then Exit;
      ms.ReadBuffer(cnt, SizeOf(cnt));
      if cnt < 0 then Exit;
      for i := 0 to cnt - 1 do
      begin
        if ms.Position + SizeOf(v) > ms.Size then Break;
        ms.ReadBuffer(v, SizeOf(v));
        SetParam(i, v);
      end;
    end;
  finally
    ms.Free;
  end;
end;

function TVST2Host.OpenEditor(AParentWnd: HWND; out AWidth, AHeight: Integer): Boolean;
var
  rectPtr: PVstERect;
begin
  AWidth := 0; AHeight := 0;
  Result := False;
  if not HasEditor then Exit;
  rectPtr := nil;
  DispatchOpcode(effEditGetRect, 0, 0, @rectPtr, 0);
  if rectPtr <> nil then
  begin
    AWidth := rectPtr^.Right - rectPtr^.Left;
    AHeight := rectPtr^.Bottom - rectPtr^.Top;
  end;
  if AWidth <= 0 then AWidth := 400;
  if AHeight <= 0 then AHeight := 300;
  DispatchOpcode(effEditOpen, 0, 0, Pointer(NativeUInt(AParentWnd)), 0);
  FEditorWnd := AParentWnd;
  Result := True;
end;

procedure TVST2Host.CloseEditor;
begin
  if FEditorWnd = 0 then Exit;
  DispatchOpcode(effEditClose, 0, 0, nil, 0);
  FEditorWnd := 0;
end;

procedure TVST2Host.EditorIdle;
begin
  if FEditorWnd = 0 then Exit;
  DispatchOpcode(effEditIdle, 0, 0, nil, 0);
end;

initialization

finalization
  GHosts.Free;
  GHosts := nil;

end.
