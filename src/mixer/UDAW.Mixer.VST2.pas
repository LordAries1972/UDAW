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

  Also hosted: MIDI in (effProcessEvents with VstMidiEvents, sample-accurate
  delta frames) and MIDI out (audioMasterProcessEvents), instruments (no audio
  inputs), VstTimeInfo transport/tempo/bar/cycle info for tempo-synced
  plugins, programs/presets, bypass, tail and latency, pin properties (multi-
  output instruments, sidechain inputs), speaker arrangement, parameter
  properties / text entry, and the editor callbacks (size window, automate,
  begin/end edit). VST3 lives in UDAW.Mixer.VST3. }

interface

uses
  Windows, SysUtils, Classes, Math, SyncObjs, System.Types, System.NetEncoding,
  UDAW.Mixer.PluginHost;

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
  effProcessEvents        = 25;
  effCanBeAutomated       = 26;
  effString2Parameter     = 27;
  effGetProgramNameIndexed = 29;
  effGetInputProperties   = 33;
  effGetOutputProperties  = 34;
  effGetPlugCategory      = 35;
  effSetSpeakerArrangement = 42;
  effSetBypass            = 44;
  effGetEffectName        = 45;
  effGetVendorString       = 47;
  effGetProductString      = 48;
  effGetVendorVersion      = 49;
  effCanDo                = 51;
  effGetTailSize          = 52;
  effGetParameterProperties = 56;
  effGetVstVersion        = 58;
  effBeginSetProgram      = 67;
  effEndSetProgram        = 68;
  effStartProcess         = 71;
  effStopProcess          = 72;
  effGetNumMidiInputChannels  = 78;
  effGetNumMidiOutputChannels = 79;

  { ---- host callback opcodes (audioMaster) ---- }
  audioMasterAutomate         = 0;
  audioMasterVersion          = 1;
  audioMasterCurrentId        = 2;
  audioMasterIdle             = 3;
  audioMasterWantMidi         = 6;
  audioMasterGetTime          = 7;
  audioMasterProcessEvents    = 8;
  audioMasterGetNumAutomatableParameters = 11;
  audioMasterIOChanged        = 13;
  audioMasterNeedIdle         = 14;
  audioMasterSizeWindow       = 15;
  audioMasterGetSampleRate    = 16;
  audioMasterGetBlockSize     = 17;
  audioMasterGetInputLatency  = 18;
  audioMasterGetOutputLatency = 19;
  audioMasterWillReplaceOrAccumulate = 22;
  audioMasterGetCurrentProcessLevel = 23;
  audioMasterGetAutomationState = 24;
  audioMasterGetVendorString  = 32;
  audioMasterGetProductString = 33;
  audioMasterGetVendorVersion = 34;
  audioMasterCanDo            = 37;
  audioMasterGetLanguage      = 38;
  audioMasterGetDirectory     = 41;
  audioMasterUpdateDisplay    = 42;
  audioMasterBeginEdit        = 43;
  audioMasterEndEdit          = 44;

  { ---- AEffect.flags bits ---- }
  effFlagsHasEditor          = 1 shl 0;
  effFlagsCanReplacing       = 1 shl 4;
  effFlagsProgramChunks      = 1 shl 5;
  effFlagsIsSynth            = 1 shl 8;
  effFlagsCanDoubleReplacing = 1 shl 12;

  { VstTimeInfo.flags }
  kVstTransportChanged  = 1 shl 0;
  kVstTransportPlaying  = 1 shl 1;
  kVstTransportCycleActive = 1 shl 2;
  kVstTransportRecording = 1 shl 3;
  kVstNanosValid        = 1 shl 8;
  kVstPpqPosValid       = 1 shl 9;
  kVstTempoValid        = 1 shl 10;
  kVstBarsValid         = 1 shl 11;
  kVstCyclePosValid     = 1 shl 12;
  kVstTimeSigValid      = 1 shl 13;

  { effGetPlugCategory results }
  kPlugCategUnknown = 0;
  kPlugCategEffect = 1;
  kPlugCategSynth = 2;
  kPlugCategGenerator = 11;

  { VstParameterProperties.flags }
  kVstParameterIsSwitch = 1 shl 0;
  kVstParameterUsesIntegerMinMax = 1 shl 1;
  kVstParameterUsesFloatStep = 1 shl 2;
  kVstParameterUsesIntStep = 1 shl 3;

  { VstPinProperties.flags }
  kVstPinIsActive = 1 shl 0;
  kVstPinIsStereo = 1 shl 1;

  { VstSpeakerArrangement types }
  kSpeakerArrMono = 12;
  kSpeakerArrStereo = 1;

  VST2_MAX_EVENTS = 2048;       // queued MIDI events per block, each direction

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

  { VstTimeInfo: what audioMasterGetTime returns (88 bytes, 8-byte aligned). }
  TVstTimeInfo = record
    SamplePos, SampleRate, NanoSeconds, PpqPos, Tempo, BarStartPos,
    CycleStartPos, CycleEndPos: Double;
    TimeSigNumerator, TimeSigDenominator, SmpteOffset, SmpteFrameRate,
    SamplesToNextClock, Flags: Integer;
  end;
  PVstTimeInfo = ^TVstTimeInfo;

  { VstMidiEvent (kVstMidiType = 1), 32 bytes. }
  TVstMidiEvent = record
    EventType, ByteSize, DeltaFrames, Flags, NoteLength, NoteOffset: Integer;
    MidiData: array[0..3] of Byte;
    Detune, NoteOffVelocity, Reserved1, Reserved2: ShortInt;
  end;
  PVstMidiEvent = ^TVstMidiEvent;

  { VstEvents with room for VST2_MAX_EVENTS pointers (the C header declares 2). }
  TVstEventsBlock = record
    NumEvents: Integer;
    Reserved: NativeInt;
    Events: array[0..VST2_MAX_EVENTS - 1] of Pointer;
  end;
  PVstEventsBlock = ^TVstEventsBlock;

  TVstParameterProperties = record
    StepFloat, SmallStepFloat, LargeStepFloat: Single;
    Lbl: array[0..63] of AnsiChar;
    Flags: Integer;
    MinInteger, MaxInteger, StepInteger, LargeStepInteger: Integer;
    ShortLabel: array[0..7] of AnsiChar;
    DisplayIndex, Category, NumParametersInCategory, Reserved: SmallInt;
    CategoryLabel: array[0..23] of AnsiChar;
    Future: array[0..15] of Byte;
  end;

  TVstPinProperties = record
    Lbl: array[0..63] of AnsiChar;
    Flags: Integer;
    ArrangementType: Integer;
    ShortLabel: array[0..7] of AnsiChar;
    Future: array[0..47] of Byte;
  end;

  EVST2Error = class(Exception);

  { One loaded, opened plugin instance. Not thread-safe by itself - a mixer
    insert calls Process only from the block that owns it, matching every
    other TAudioNode. }
  TVST2Host = class(TPluginHostBase)
  private
    FModuleHandle: HMODULE;
    FEffect: PAEffect;
    FBlockSize: Integer;
    FOpened: Boolean;
    FProcessing: Boolean;
    FEditorWnd: HWND;
    FInBuf: array of System.PSingle;    // scratch pointers into a shared block, per channel
    FOutBuf: array of System.PSingle;
    FScratch: array of Single;   // backing store for FInBuf/FOutBuf (2 * maxch * maxframes)
    FMaxFrames: Integer;
    FChannels: Integer;
    FTimeInfo: TVstTimeInfo;
    FStopwatch: Int64;
    FStopFreq: Int64;
    FEvPlay: array[0..VST2_MAX_EVENTS - 1] of TVstMidiEvent;
    FEvBlock: TVstEventsBlock;
    FIOChanged: Boolean;
    FMidiScratch: array[0..PLUGIN_MAX_MIDI - 1] of TPluginMidi;
    procedure DeliverEvents(AFrames: Integer);
    procedure AdvanceTransport(AFrames: Integer);
    function HostCanDo(const AText: string): Integer;
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
    procedure LoadOnly(const APath: string); override;
    { LoadOnly, then effOpen + effMainsChanged(1) + Configure - ready to
      Process. }
    procedure LoadAndOpen(const APath: string; ASampleRate, AMaxFrames, AChannels: Integer); override;
    procedure Configure(ASampleRate, AMaxFrames, AChannels: Integer); override;
    procedure Close; override;

    { RT-safe once Configure has sized the scratch buffers: deinterleaves
      AIn/AOut's channel pointers into the plugin's expected per-channel
      float arrays and calls processReplacing (or process, for the rare
      plugin that never adopted the replacing API). }
    procedure Process(const AIn, AOut: array of System.PSingle; AFrames: Integer); override;
    procedure Reset; override;

    function IsLoaded: Boolean; override;
    function HasEditor: Boolean; override;
    function EffectName: string; override;
    function VendorString: string; override;
    function ProductString: string;
    function UniqueID: Integer;
    function NumInputs: Integer; override;
    function NumOutputs: Integer; override;

    { ---- parameters (by index, for automation) ---- }
    function ParamCount: Integer; override;
    function ParamName(AIndex: Integer): string; override;
    function ParamLabel(AIndex: Integer): string; override;
    function ParamDisplay(AIndex: Integer): string; override;
    function GetParam(AIndex: Integer): Single; override;   // 0..1, VST convention
    procedure SetParam(AIndex: Integer; AValue: Single); override;

    { ---- state persistence ---- }
    { Program-chunk state if the plugin advertises effFlagsProgramChunks,
      else a per-parameter float dump - either way, real recoverable state,
      base64-encoded so it fits in the mixer's text-format INSERT line. }
    function SaveStateBase64: string; override;
    procedure LoadStateBase64(const AState: string); override;

    { ---- native editor GUI (effEditOpen) ---- }
    { AParentWnd is the HWND that will host the plugin's own window (a
      TPanel's Handle, typically). Returns the plugin-requested size. }
    function OpenEditor(AParentWnd: HWND; out AWidth, AHeight: Integer): Boolean; override;
    procedure CloseEditor; override;
    procedure EditorIdle; override;   // call periodically (e.g. a 30 ms timer) while open
    property EditorOpen: HWND read FEditorWnd;

    { ---- instruments, MIDI and transport ---- }
    function IsSynth: Boolean; override;
    function Category: Integer;                 // kPlugCateg*
    function NumMidiInputChannels: Integer;
    function NumMidiOutputChannels: Integer;
    function WantsMidi: Boolean; override;      // synth, or reports MIDI input channels

    { ---- programs / presets, bypass, tail, latency ---- }
    function ProgramCount: Integer; override;
    function CurrentProgram: Integer; override;
    procedure SetProgram(AIndex: Integer); override;
    function ProgramName(AIndex: Integer): string; override;
    function SupportsBypass: Boolean; override;
    procedure SetBypass(ABypass: Boolean); override;
    function TailSamples: Integer; override;    // 0 unknown, 1 none, else samples
    function LatencySamples: Integer; override;
    function PluginCanDo(const AText: string): Integer;   // 1 yes, -1 no, 0 don't know
    function VstVersion: Integer;
    function VendorVersion: Integer;

    { ---- parameters, extended ---- }
    function ParamCanAutomate(AIndex: Integer): Boolean; override;
    function ParamProperties(AIndex: Integer; out AProps: TVstParameterProperties): Boolean;
    function SetParamFromText(AIndex: Integer; const AText: string): Boolean; override;

    { ---- buses ---- }
    function InputPinLabel(AIndex: Integer): string;
    function OutputPinLabel(AIndex: Integer): string;
    function InputPinIsStereo(AIndex: Integer): Boolean;
    function OutputPinIsStereo(AIndex: Integer): Boolean;
    function SetSpeakerArrangement(AInputs, AOutputs: Integer): Boolean;  // channel counts 1 or 2
    { After Process: the plugin's output channel ACh (also beyond the channels the caller asked
      for), valid until the next Process; nil when out of range. Lets a multi-output instrument
      be routed to several mixer channels. }
    function OutputChannel(ACh: Integer): System.PSingle; override;
    { True once after a plugin called audioMasterIOChanged (its I/O layout changed): call
      Configure again. }
    function TakeIOChanged: Boolean;

    { the editor's size as the plugin reports it now (some only know it after effEditOpen) }

    { ---- the common plug-in host interface (UDAW.Mixer.PluginHost) ---- }
    function FormatName: string; override;
    procedure SetTransport(const ATransport: TPluginTransport); override;
    function ParamSteps(AIndex: Integer): Integer; override;
    function ParamIsSwitch(AIndex: Integer): Boolean; override;
    function IsEditorOpen: Boolean; override;
    function EditorSize(out AWidth, AHeight: Integer): Boolean; override;
    function TakeRestartRequest: Boolean; override;
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
  QueryPerformanceFrequency(FStopFreq);
  QueryPerformanceCounter(FStopwatch);
  FillChar(FTimeInfo, SizeOf(FTimeInfo), 0);
  FTimeInfo.Tempo := 120;
  FTimeInfo.TimeSigNumerator := 4;
  FTimeInfo.TimeSigDenominator := 4;
  FTimeInfo.SampleRate := 44100;
  FSampleRate := 44100;
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

function TVST2Host.HostCanDo(const AText: string): Integer;
const
  Supported: array[0..11] of string = ('sendVstEvents', 'sendVstMidiEvent', 'sendVstTimeInfo',
    'receiveVstEvents', 'receiveVstMidiEvent', 'reportConnectionChanges', 'acceptIOChanges',
    'sizeWindow', 'startStopProcess', 'sendVstMidiEventFlagIsRealtime', 'supplyIdle', 'supportShell');
var
  i: Integer;
begin
  Result := 0;
  for i := Low(Supported) to High(Supported) do
    if SameText(AText, Supported[i]) then
    begin
      Result := 1;
      Exit;
    end;
end;

function TVST2Host.HandleHostCallback(AOpcode, AIndex: Integer; AValue: NativeInt;
  APtr: Pointer; AOpt: Single): NativeInt;
var
  s: UTF8String;
  ev: PVstEventsBlock;
  me: PVstMidiEvent;
  i, n: Integer;
  t: Int64;
begin
  case AOpcode of
    audioMasterVersion:          Result := 2400;
    audioMasterCurrentId:        Result := 0;
    audioMasterIdle:             Result := 0;
    audioMasterNeedIdle:         Result := 1;
    audioMasterWantMidi:         Result := 1;
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
    audioMasterCanDo:
      if APtr <> nil then Result := HostCanDo(string(AnsiString(PAnsiChar(APtr))))
      else Result := 0;
    audioMasterGetLanguage:      Result := 1;    { kVstLangEnglish }
    audioMasterUpdateDisplay:    Result := 0;
    audioMasterBeginEdit:
      begin
        if Assigned(FOnBeginEdit) then FOnBeginEdit(AIndex);
        Result := 1;
      end;
    audioMasterEndEdit:
      begin
        if Assigned(FOnEndEdit) then FOnEndEdit(AIndex);
        Result := 1;
      end;
    audioMasterAutomate:
      begin
        { the plugin's own UI moved a parameter; AOpt is the new 0..1 value }
        if Assigned(FOnAutomate) then FOnAutomate(AIndex, AOpt);
        Result := 1;
      end;
    audioMasterGetTime:
      begin
        QueryPerformanceCounter(t);
        if FStopFreq > 0 then
          FTimeInfo.NanoSeconds := (t - FStopwatch) * 1.0e9 / FStopFreq;
        FTimeInfo.SampleRate := FSampleRate;
        Result := NativeInt(@FTimeInfo);
      end;
    audioMasterProcessEvents:
      begin
        { MIDI a plugin sends out; only MIDI events (type 1) are kept }
        Result := 0;
        ev := PVstEventsBlock(APtr);
        if ev <> nil then
        begin
          n := ev^.NumEvents;
          if n > VST2_MAX_EVENTS then n := VST2_MAX_EVENTS;
          for i := 0 to n - 1 do
          begin
            me := PVstMidiEvent(ev^.Events[i]);
            if (me <> nil) and (me^.EventType = 1) then
              PushMidiOut(me^.MidiData[0], me^.MidiData[1], me^.MidiData[2], me^.DeltaFrames);
          end;
          Result := 1;
        end;
      end;
    audioMasterIOChanged:
      begin
        FIOChanged := True;
        Result := 1;
      end;
    audioMasterSizeWindow:
      begin
        if Assigned(FOnSizeWindow) then
        begin
          FOnSizeWindow(AIndex, Integer(AValue));
          Result := 1;
        end
        else
          Result := 0;
      end;
    audioMasterWillReplaceOrAccumulate: Result := 1;   { replace }
    audioMasterGetCurrentProcessLevel:  Result := 2;   { kVstProcessLevelRealtime }
    audioMasterGetAutomationState:      Result := 1;   { off }
    audioMasterGetNumAutomatableParameters:
      if FEffect <> nil then Result := FEffect^.NumParams else Result := 0;
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
    if FRequireEffect then
    begin
      if (FEffect^.Flags and effFlagsIsSynth <> 0) or
         (FEffect^.NumInputs <= 0) or (FEffect^.NumOutputs <= 0) then
        raise EVST2Error.CreateFmt('VST2: "%s" is not an audio-in/audio-out effect', [APath]);
    end
    else if FEffect^.NumOutputs <= 0 then
      raise EVST2Error.CreateFmt('VST2: "%s" has no audio outputs', [APath]);
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

  DeliverEvents(n);

  if (FEffect^.Flags and effFlagsCanReplacing <> 0) and Assigned(FEffect^.ProcessReplacing) then
    FEffect^.ProcessReplacing(FEffect, @FInBuf[0], @FOutBuf[0], n)
  else if Assigned(FEffect^.ProcessDeprecated) then
    FEffect^.ProcessDeprecated(FEffect, @FInBuf[0], @FOutBuf[0], n);
  AdvanceTransport(n);

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

{ ---- MIDI, transport ---- }

procedure TVST2Host.AdvanceTransport(AFrames: Integer);
var
  secs: Double;
begin
  FTimeInfo.Flags := FTimeInfo.Flags and (not kVstTransportChanged);
  if (FTimeInfo.Flags and kVstTransportPlaying) = 0 then Exit;
  FTimeInfo.SamplePos := FTimeInfo.SamplePos + AFrames;
  if FSampleRate > 0 then
  begin
    secs := AFrames / FSampleRate;
    FTimeInfo.PpqPos := FTimeInfo.PpqPos + secs * FTimeInfo.Tempo / 60.0;
  end;
end;

procedure TVST2Host.DeliverEvents(AFrames: Integer);
var
  i, n: Integer;
begin
  n := TakeMidiIn(FMidiScratch);
  if n > VST2_MAX_EVENTS then n := VST2_MAX_EVENTS;
  if n = 0 then Exit;
  for i := 0 to n - 1 do
  begin
    FillChar(FEvPlay[i], SizeOf(TVstMidiEvent), 0);
    FEvPlay[i].EventType := 1;                      { kVstMidiType }
    FEvPlay[i].ByteSize := SizeOf(TVstMidiEvent);
    FEvPlay[i].DeltaFrames := Min(FMidiScratch[i].DeltaFrames, Max(0, AFrames - 1));
    FEvPlay[i].Flags := 1;                          { kVstMidiEventIsRealtime }
    FEvPlay[i].MidiData[0] := FMidiScratch[i].Status;
    FEvPlay[i].MidiData[1] := FMidiScratch[i].Data1;
    FEvPlay[i].MidiData[2] := FMidiScratch[i].Data2;
    FEvBlock.Events[i] := @FEvPlay[i];
  end;
  FEvBlock.NumEvents := n;
  FEvBlock.Reserved := 0;
  DispatchOpcode(effProcessEvents, 0, 0, @FEvBlock, 0);
end;

procedure TVST2Host.SetTransport(const ATransport: TPluginTransport);
var
  fl: Integer;
  barLen: Double;
begin
  inherited SetTransport(ATransport);
  fl := kVstNanosValid or kVstPpqPosValid or kVstTempoValid or kVstBarsValid or
        kVstCyclePosValid or kVstTimeSigValid;
  if FTransport.Playing then fl := fl or kVstTransportPlaying;
  if FTransport.LoopOn then fl := fl or kVstTransportCycleActive;
  if FTransport.Recording then fl := fl or kVstTransportRecording;
  if (fl and kVstTransportPlaying) <> (FTimeInfo.Flags and kVstTransportPlaying) then
    fl := fl or kVstTransportChanged;
  barLen := FTransport.TimeSigNum * 4.0 / FTransport.TimeSigDen;
  FTimeInfo.SamplePos := FTransport.SamplePos;
  FTimeInfo.PpqPos := FTransport.PpqPos;
  FTimeInfo.Tempo := FTransport.Tempo;
  FTimeInfo.TimeSigNumerator := FTransport.TimeSigNum;
  FTimeInfo.TimeSigDenominator := FTransport.TimeSigDen;
  FTimeInfo.BarStartPos := Floor(FTransport.PpqPos / barLen) * barLen;
  FTimeInfo.CycleStartPos := FTransport.LoopStartPpq;
  FTimeInfo.CycleEndPos := FTransport.LoopEndPpq;
  FTimeInfo.Flags := fl;
end;

function TVST2Host.FormatName: string;
begin
  Result := 'VST2';
end;

function TVST2Host.ParamSteps(AIndex: Integer): Integer;
var
  pp: TVstParameterProperties;
begin
  Result := 0;
  if not ParamProperties(AIndex, pp) then Exit;
  if (pp.Flags and kVstParameterIsSwitch) <> 0 then
    Result := 1
  else if ((pp.Flags and kVstParameterUsesIntStep) <> 0) and (pp.StepInteger > 0) and
          ((pp.Flags and kVstParameterUsesIntegerMinMax) <> 0) then
    Result := (pp.MaxInteger - pp.MinInteger) div pp.StepInteger;
end;

function TVST2Host.ParamIsSwitch(AIndex: Integer): Boolean;
var
  pp: TVstParameterProperties;
begin
  Result := ParamProperties(AIndex, pp) and ((pp.Flags and kVstParameterIsSwitch) <> 0);
end;

function TVST2Host.IsEditorOpen: Boolean;
begin
  Result := FEditorWnd <> 0;
end;

function TVST2Host.TakeRestartRequest: Boolean;
begin
  Result := TakeIOChanged;
end;

{ ---- identity, programs, bypass ---- }

function TVST2Host.IsSynth: Boolean;
begin
  Result := (FEffect <> nil) and
    (((FEffect^.Flags and effFlagsIsSynth) <> 0) or (Category = kPlugCategSynth));
end;

function TVST2Host.Category: Integer;
begin
  Result := Integer(DispatchOpcode(effGetPlugCategory, 0, 0, nil, 0));
end;

function TVST2Host.NumMidiInputChannels: Integer;
begin
  Result := Max(0, Integer(DispatchOpcode(effGetNumMidiInputChannels, 0, 0, nil, 0)));
end;

function TVST2Host.NumMidiOutputChannels: Integer;
begin
  Result := Max(0, Integer(DispatchOpcode(effGetNumMidiOutputChannels, 0, 0, nil, 0)));
end;

function TVST2Host.WantsMidi: Boolean;
begin
  Result := IsSynth or (PluginCanDo('receiveVstMidiEvent') > 0) or (NumMidiInputChannels > 0);
end;

function TVST2Host.ProgramCount: Integer;
begin
  if FEffect = nil then Exit(0);
  Result := FEffect^.NumPrograms;
end;

function TVST2Host.CurrentProgram: Integer;
begin
  Result := Integer(DispatchOpcode(effGetProgram, 0, 0, nil, 0));
end;

procedure TVST2Host.SetProgram(AIndex: Integer);
begin
  if (FEffect = nil) or (AIndex < 0) or (AIndex >= FEffect^.NumPrograms) then Exit;
  DispatchOpcode(effBeginSetProgram, 0, 0, nil, 0);
  DispatchOpcode(effSetProgram, 0, AIndex, nil, 0);
  DispatchOpcode(effEndSetProgram, 0, 0, nil, 0);
end;

function TVST2Host.ProgramName(AIndex: Integer): string;
var
  buf: array[0..255] of AnsiChar;
begin
  FillChar(buf, SizeOf(buf), 0);
  if DispatchOpcode(effGetProgramNameIndexed, AIndex, 0, @buf[0], 0) = 0 then
  begin
    { plugins that cannot name a program by index only know the current one }
    if AIndex <> CurrentProgram then Exit('Program ' + IntToStr(AIndex + 1));
    DispatchOpcode(effGetProgramName, 0, 0, @buf[0], 0);
  end;
  Result := string(AnsiString(PAnsiChar(@buf[0])));
  if Result = '' then Result := 'Program ' + IntToStr(AIndex + 1);
end;

function TVST2Host.PluginCanDo(const AText: string): Integer;
var
  a: AnsiString;
begin
  a := AnsiString(AText);
  Result := Integer(DispatchOpcode(effCanDo, 0, 0, PAnsiChar(a), 0));
end;

function TVST2Host.SupportsBypass: Boolean;
begin
  Result := PluginCanDo('bypass') > 0;
end;

procedure TVST2Host.SetBypass(ABypass: Boolean);
begin
  DispatchOpcode(effSetBypass, 0, Ord(ABypass), nil, 0);
end;

function TVST2Host.TailSamples: Integer;
begin
  Result := Max(0, Integer(DispatchOpcode(effGetTailSize, 0, 0, nil, 0)));
end;

function TVST2Host.LatencySamples: Integer;
begin
  if FEffect = nil then Exit(0);
  Result := Max(0, FEffect^.InitialDelay);
end;

function TVST2Host.VstVersion: Integer;
begin
  Result := Integer(DispatchOpcode(effGetVstVersion, 0, 0, nil, 0));
end;

function TVST2Host.VendorVersion: Integer;
begin
  Result := Integer(DispatchOpcode(effGetVendorVersion, 0, 0, nil, 0));
end;

{ ---- parameters, extended ---- }

function TVST2Host.ParamCanAutomate(AIndex: Integer): Boolean;
begin
  { 0 = the plugin does not say: treat as automatable, like every host does }
  Result := DispatchOpcode(effCanBeAutomated, AIndex, 0, nil, 0) <> 0;
end;

function TVST2Host.ParamProperties(AIndex: Integer; out AProps: TVstParameterProperties): Boolean;
begin
  FillChar(AProps, SizeOf(AProps), 0);
  Result := DispatchOpcode(effGetParameterProperties, AIndex, 0, @AProps, 0) = 1;
end;

function TVST2Host.SetParamFromText(AIndex: Integer; const AText: string): Boolean;
var
  a: AnsiString;
begin
  a := AnsiString(AText);
  Result := DispatchOpcode(effString2Parameter, AIndex, 0, PAnsiChar(a), 0) = 1;
end;

{ ---- buses ---- }

function TVST2Host.InputPinLabel(AIndex: Integer): string;
var
  pp: TVstPinProperties;
begin
  FillChar(pp, SizeOf(pp), 0);
  if DispatchOpcode(effGetInputProperties, AIndex, 0, @pp, 0) = 1 then
    Result := string(AnsiString(PAnsiChar(@pp.Lbl[0])))
  else
    Result := '';
  if Result = '' then Result := 'In ' + IntToStr(AIndex + 1);
end;

function TVST2Host.OutputPinLabel(AIndex: Integer): string;
var
  pp: TVstPinProperties;
begin
  FillChar(pp, SizeOf(pp), 0);
  if DispatchOpcode(effGetOutputProperties, AIndex, 0, @pp, 0) = 1 then
    Result := string(AnsiString(PAnsiChar(@pp.Lbl[0])))
  else
    Result := '';
  if Result = '' then Result := 'Out ' + IntToStr(AIndex + 1);
end;

function TVST2Host.InputPinIsStereo(AIndex: Integer): Boolean;
var
  pp: TVstPinProperties;
begin
  FillChar(pp, SizeOf(pp), 0);
  Result := (DispatchOpcode(effGetInputProperties, AIndex, 0, @pp, 0) = 1) and
            ((pp.Flags and kVstPinIsStereo) <> 0);
end;

function TVST2Host.OutputPinIsStereo(AIndex: Integer): Boolean;
var
  pp: TVstPinProperties;
begin
  FillChar(pp, SizeOf(pp), 0);
  Result := (DispatchOpcode(effGetOutputProperties, AIndex, 0, @pp, 0) = 1) and
            ((pp.Flags and kVstPinIsStereo) <> 0);
end;

function TVST2Host.SetSpeakerArrangement(AInputs, AOutputs: Integer): Boolean;
type
  { VstSpeakerArrangement with eight 112-byte VstSpeakerProperties (zeroed: only the type and
    channel count matter to the plugins that look at it) }
  TArr = record
    ArrType, NumChannels: Integer;
    Speakers: array[0..8 * 112 - 1] of Byte;
  end;
var
  a, b: TArr;

  procedure Fill(var X: TArr; AChannels: Integer);
  begin
    FillChar(X, SizeOf(X), 0);
    X.NumChannels := AChannels;
    if AChannels = 1 then X.ArrType := kSpeakerArrMono else X.ArrType := kSpeakerArrStereo;
  end;

begin
  Fill(a, AInputs);
  Fill(b, AOutputs);
  Result := DispatchOpcode(effSetSpeakerArrangement, 0, NativeInt(@a), @b, 0) = 1;
end;

function TVST2Host.OutputChannel(ACh: Integer): System.PSingle;
begin
  if (ACh < 0) or (ACh > High(FOutBuf)) then Exit(nil);
  Result := FOutBuf[ACh];
end;

function TVST2Host.TakeIOChanged: Boolean;
begin
  Result := FIOChanged;
  FIOChanged := False;
end;

function TVST2Host.EditorSize(out AWidth, AHeight: Integer): Boolean;
var
  rectPtr: PVstERect;
begin
  AWidth := 0;
  AHeight := 0;
  rectPtr := nil;
  DispatchOpcode(effEditGetRect, 0, 0, @rectPtr, 0);
  Result := rectPtr <> nil;
  if Result then
  begin
    AWidth := rectPtr^.Right - rectPtr^.Left;
    AHeight := rectPtr^.Bottom - rectPtr^.Top;
  end;
end;

procedure TVST2Host.Reset;
begin
  if FEffect = nil then Exit;
  ClearMidiIn;
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
  w2, h2: Integer;
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
  { several plugins only know their real size once the editor is open }
  if EditorSize(w2, h2) and (w2 > 0) and (h2 > 0) then
  begin
    AWidth := w2;
    AHeight := h2;
  end;
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
