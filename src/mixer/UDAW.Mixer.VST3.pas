unit UDAW.Mixer.VST3;
{$I udaw.inc}
{$ALIGN 8}
{$POINTERMATH ON}

{ VST3 hosting, Windows.

  VST3 is a COM-style ABI: plain vtables of __stdcall function pointers with the IUnknown
  triple first.  Rather than depend on Steinberg's SDK headers, this unit re-declares the
  interfaces a host needs as raw vtable records and drives them directly.

  Hosted, the same way TVST2Host (UDAW.Mixer.VST2) hosts a VST2 plug-in, through the common
  TPluginHostBase interface:

    * the processor (IComponent + IAudioProcessor): audio in/out on every bus - main, aux
      (side-chain input) and extra outputs for multi-output instruments - 32-bit realtime
    * the edit controller (a separate class, or the component itself): the full parameter
      list with names, units, display text, step counts, text entry, automation both ways
      (host -> plug-in through IParameterChanges, plug-in GUI -> host through
      IComponentHandler), bypass and program-change parameters
    * MIDI in as VST3 events (note on/off with note ids, poly pressure) and, through
      IMidiMapping, controllers / pitch bend / aftertouch / program change as parameter
      changes; MIDI out from the plug-in's output events
    * IProcessContext: tempo, bar and beat position, time signature, loop, play state
    * programs through IUnitInfo (or the program-change parameter)
    * state: component state + controller state, saved and restored together
    * the plug-in's own window (IPlugView, "HWND") with IPlugFrame resize handling
    * IConnectionPoint between component and controller, with host-made IMessage /
      IAttributeList objects, IPlugInterfaceSupport, restartComponent requests

  Not hosted: note-expression and MPE (events are sent with plain note ids), ARA, and the
  Linux / macOS run-loop interfaces (this unit is Windows-only). }

interface

uses
  Windows, SysUtils, Classes, Math, SyncObjs, Generics.Collections, System.NetEncoding,
  UDAW.Mixer.PluginHost;

type
  EVST3Error = class(EPluginHostError);

type
  PVTable = ^TVTable;
  TVTable = array[0..31] of Pointer;
  PObj = ^TObj;
  TObj = record
    VTable: PVTable;
  end;

  TString128 = array[0..127] of WideChar;

  TFactoryInfo = record
    Vendor: array[0..63] of AnsiChar;
    Url: array[0..255] of AnsiChar;
    Email: array[0..127] of AnsiChar;
    Flags: Integer;
  end;

  TClassInfo = record
    Cid: TGUID;
    Cardinality: Integer;
    Category: array[0..31] of AnsiChar;
    Name: array[0..63] of AnsiChar;
  end;

  TClassInfo2 = record
    Cid: TGUID;
    Cardinality: Integer;
    Category: array[0..31] of AnsiChar;
    Name: array[0..63] of AnsiChar;
    ClassFlags: Cardinal;
    SubCategories: array[0..127] of AnsiChar;
    Vendor: array[0..63] of AnsiChar;
    Version: array[0..63] of AnsiChar;
    SdkVersion: array[0..63] of AnsiChar;
  end;

  TProcessSetup = record
    ProcessMode: Integer;
    SymbolicSampleSize: Integer;
    MaxSamplesPerBlock: Integer;
    SampleRate: Double;
  end;

  TAudioBusBuffers = record
    NumChannels: Integer;
    SilenceFlags: UInt64;
    ChannelBuffers32: ^System.PSingle;
  end;
  PAudioBusBuffers = ^TAudioBusBuffers;

  TProcessData = record
    ProcessMode: Integer;
    SymbolicSampleSize: Integer;
    NumSamples: Integer;
    NumInputs: Integer;
    NumOutputs: Integer;
    Inputs: PAudioBusBuffers;
    Outputs: PAudioBusBuffers;
    InputParameterChanges: Pointer;
    OutputParameterChanges: Pointer;
    InputEvents: Pointer;
    OutputEvents: Pointer;
    ProcessContext: Pointer;
  end;

  TProcessContext = record
    State: Cardinal;
    SampleRate: Double;
    ProjectTimeSamples: Int64;
    SystemTime: Int64;
    ContinousTimeSamples: Int64;
    ProjectTimeMusic: Double;
    BarPositionMusic: Double;
    CycleStartMusic: Double;
    CycleEndMusic: Double;
    Tempo: Double;
    TimeSigNumerator: Integer;
    TimeSigDenominator: Integer;
    ChordKeyNote, ChordRootNote: Byte;
    ChordMask: SmallInt;
    SmpteOffsetSubframes: Integer;
    FramesPerSecond: Cardinal;
    FrameFlags: Cardinal;
    SamplesToNextClock: Integer;
  end;

  { Steinberg::Vst::Event: 24 bytes of header then a 24-byte union (48 bytes in all) }
  TVst3Event = record
    BusIndex: Integer;
    SampleOffset: Integer;
    PpqPosition: Double;
    Flags: Word;
    EventType: Word;
    Pad: Integer;
    Data: array[0..23] of Byte;
  end;
  PVst3Event = ^TVst3Event;

  TParameterInfo = record
    Id: Cardinal;
    Title: TString128;
    ShortTitle: TString128;
    Units: TString128;
    StepCount: Integer;
    DefaultNormalized: Double;
    UnitId: Integer;
    Flags: Integer;
  end;

  TBusInfo = record
    MediaType: Integer;
    Direction: Integer;
    ChannelCount: Integer;
    Name: TString128;
    BusType: Integer;
    Flags: Cardinal;
  end;

  TProgramListInfo = record
    Id: Integer;
    Name: TString128;
    ProgramCount: Integer;
  end;

  TViewRect = record
    Left, Top, Right, Bottom: Integer;
  end;
  PViewRect = ^TViewRect;

  TVST3Host = class;

  { a host-side COM object: vtable pointer first, then who it belongs to }
  TIface = record
    VTable: PVTable;
    Host: TVST3Host;
    Tag: Integer;
  end;
  PIface = ^TIface;

  { IParamValueQueue implemented by the host }
  TQueueObj = record
    VTable: PVTable;
    Id: Cardinal;
    Count: Integer;
    Offsets: array[0..7] of Integer;
    Values: array[0..7] of Double;
  end;
  PQueueObj = ^TQueueObj;

  { one parameter of the plug-in's controller }
  TVst3Param = record
    Id: Cardinal;
    Title: string;
    Units: string;
    StepCount: Integer;
    Default: Double;
    UnitId: Integer;
    Flags: Integer;
  end;

  { a change waiting to be handed to the processor }
  TPendingParam = record
    Id: Cardinal;
    Value: Double;
    Offset: Integer;
  end;

  TVST3Host = class(TPluginHostBase)
  private
    FModule: HMODULE;
    FFactory: Pointer;
    FComponent: Pointer;
    FProcessor: Pointer;
    FController: Pointer;
    FCtrlIsComponent: Boolean;
    FMidiMap: Pointer;
    FUnitInfo: Pointer;
    FView: Pointer;
    FEditorWnd: HWND;
    FName, FVendor, FSubCats: string;
    FMaxFrames: Integer;
    FChannels: Integer;
    FActive, FProcessing, FInitialised: Boolean;
    FOffline: Boolean;

    { buses }
    FInBusCount, FOutBusCount: Integer;
    FInBusCh, FOutBusCh: array of Integer;       // channels per audio bus
    FInBusAux, FOutBusAux: array of Boolean;
    FInBusFirst, FOutBusFirst: array of Integer; // first flat channel of each bus
    FInTotal, FOutTotal: Integer;
    FEventIn, FEventOut: Integer;                // event bus counts
    FInStore, FOutStore: array of Single;
    FInPtrs, FOutPtrs: array of System.PSingle;
    FInBuses, FOutBuses: array of TAudioBusBuffers;
    FSide: array of System.PSingle;

    { parameters }
    FParams: array of TVst3Param;
    FVisible: array of Integer;                  // visible index -> FParams index
    FIdToVisible: TDictionary<Cardinal, Integer>;
    FProgParamId, FBypassParamId: Cardinal;
    FProgListId, FProgCount: Integer;
    FParamLock: TCriticalSection;
    FPending: array[0..511] of TPendingParam;
    FPendingCount: Integer;
    FOutChanges: array[0..1023] of TPendingParam;
    FOutChangeCount: Integer;
    FMapCache: array of Int64;                   // [channel * 132 + controller]
    FRestartFlags: Integer;
    FLastSent: array of Double;                  // last value sent per FParams index

    { host-side COM objects handed to the plug-in }
    FIHostApp, FIPlugSupport, FIHandler, FIFrame, FIEvIn, FIEvOut, FIParIn, FIParOut: TIface;
    FInQ: array[0..255] of TQueueObj;
    FInQCount: Integer;
    FOutQ: array[0..255] of TQueueObj;
    FOutQCount: Integer;
    FEvIn, FEvOut: array[0..PLUGIN_MAX_MIDI - 1] of TVst3Event;
    FEvInCount, FEvOutCount: Integer;
    FMidiScratch: array[0..PLUGIN_MAX_MIDI - 1] of TPluginMidi;
    FNoteIds: array[0..16 * 128 - 1] of Integer;
    FNextNoteId: Integer;
    FCtx: TProcessContext;
    FStopFreq, FStopStart: Int64;
    FContSamples: Int64;

    function ResolveModulePath(const APath: string): string;
    procedure CreateController;
    procedure ReadParameters;
    procedure ReadPrograms;
    procedure SetupBuses;
    procedure ReleaseAll;
    procedure SyncControllerState;
    procedure AddPending(AId: Cardinal; AValue: Double; AOffset: Integer);
    procedure BuildInputChanges;
    procedure CollectOutputChanges;
    procedure BuildInputEvents(AFrames: Integer);
    procedure CollectOutputEvents;
    procedure FillContext(AFrames: Integer);
    function MapController(AChannel, AController: Integer): Int64;
    procedure PostMapped(AChannel, AController: Integer; AValue: Double; AOffset: Integer);
    procedure QueueOut(AId: Cardinal; AValue: Double);
    function ParamIndexOfVisible(AVisible: Integer): Integer;
    function ControllerValue(AId: Cardinal): Double;
    procedure SetParamById(AId: Cardinal; AValue: Double);
    procedure DoViewResize(const ANewSize: TViewRect);
  public
    constructor Create;
    destructor Destroy; override;

    procedure LoadOnly(const APath: string); override;
    procedure LoadAndOpen(const APath: string; ASampleRate, AMaxFrames, AChannels: Integer); override;
    procedure Configure(ASampleRate, AMaxFrames, AChannels: Integer); override;
    procedure Close; override;
    function IsLoaded: Boolean; override;
    function FormatName: string; override;

    procedure Process(const AIn, AOut: array of System.PSingle; AFrames: Integer); override;
    procedure Reset; override;
    procedure SetBypass(ABypass: Boolean); override;
    function SupportsBypass: Boolean; override;
    function LatencySamples: Integer; override;
    function TailSamples: Integer; override;
    function NumInputs: Integer; override;
    function NumOutputs: Integer; override;
    function OutputChannel(ACh: Integer): System.PSingle; override;
    procedure SetSidechain(const AChannels: array of System.PSingle); override;

    function EffectName: string; override;
    function VendorString: string; override;
    function IsSynth: Boolean; override;
    function WantsMidi: Boolean; override;
    function SubCategories: string; override;
    { number of audio buses (main + aux) on each side, for UIs that show the routing }
    function InputBusCount: Integer;
    function OutputBusCount: Integer;
    function HasSidechainInput: Boolean;
    property Offline: Boolean read FOffline write FOffline;

    function ParamCount: Integer; override;
    function ParamName(AIndex: Integer): string; override;
    function ParamLabel(AIndex: Integer): string; override;
    function ParamDisplay(AIndex: Integer): string; override;
    function GetParam(AIndex: Integer): Single; override;
    procedure SetParam(AIndex: Integer; AValue: Single); override;
    function ParamCanAutomate(AIndex: Integer): Boolean; override;
    function ParamSteps(AIndex: Integer): Integer; override;
    function SetParamFromText(AIndex: Integer; const AText: string): Boolean; override;

    function ProgramCount: Integer; override;
    function CurrentProgram: Integer; override;
    procedure SetProgram(AIndex: Integer); override;
    function ProgramName(AIndex: Integer): string; override;

    function SaveStateBase64: string; override;
    procedure LoadStateBase64(const AState: string); override;

    function HasEditor: Boolean; override;
    function OpenEditor(AParentWnd: HWND; out AWidth, AHeight: Integer): Boolean; override;
    procedure CloseEditor; override;
    procedure EditorIdle; override;
    function EditorSize(out AWidth, AHeight: Integer): Boolean; override;
    function IsEditorOpen: Boolean; override;
    procedure ResizeEditor(AWidth, AHeight: Integer); override;
    function EditorCanResize: Boolean; override;
    function TakeRestartRequest: Boolean; override;

    { ---- internal: called back from the COM objects given to the plug-in ---- }
    procedure HandlerBeginEdit(AId: Cardinal);
    procedure HandlerPerformEdit(AId: Cardinal; AValue: Double);
    procedure HandlerEndEdit(AId: Cardinal);
    procedure HandlerRestart(AFlags: Integer);
    procedure FrameResize(const ARect: TViewRect);
  end;

implementation

const
  IID_FUnknown: TGUID = '{00000000-0000-0000-C000-000000000046}';
  IID_IPluginFactory2: TGUID = '{0007B650-F24B-4C0B-A464-EDB9F00B2ABB}';
  IID_IComponent: TGUID = '{E831FF31-F2D5-4301-928E-BBEE25697802}';
  IID_IAudioProcessor: TGUID = '{42043F99-B7DA-453C-A569-E79D9AAEC33D}';
  IID_IEditController: TGUID = '{DCD7BBE3-7742-448D-A874-AACC979C759E}';
  IID_IComponentHandler: TGUID = '{93A0BEA3-0BD0-45DB-8E89-0B0CC1E46AC6}';
  IID_IConnectionPoint: TGUID = '{70A4156F-6E6E-4026-9891-48BFAA60D8D1}';
  IID_IMessage: TGUID = '{936F033B-C6C0-47DB-BB08-82F813C1E613}';
  IID_IAttributeList: TGUID = '{1E5F0AEB-CC7F-4533-A254-401138AD5EE4}';
  IID_IMidiMapping: TGUID = '{DF0FF9F7-49B7-4669-B63A-B7327ADBF5E5}';
  IID_IUnitInfo: TGUID = '{3D4BD6B5-913A-4FD2-A886-E768A5EB92C1}';
  IID_IBStream: TGUID = '{C3BF6EA2-3099-4752-9B6B-F9901EE33E9B}';
  IID_IHostApplication: TGUID = '{58E595CC-DB2D-4969-8B6A-AF8C36A664E5}';
  IID_IPlugInterfaceSupport: TGUID = '{4FB58B9E-9EAA-4E0F-AB36-1C1CCCB56FEA}';
  IID_IPlugFrame: TGUID = '{367FAF01-AFA9-4693-8D4D-A2A0ED0882A3}';
  IID_IParameterChanges: TGUID = '{A4779663-0BB6-4A56-B443-84A8466FEB9D}';
  IID_IParamValueQueue: TGUID = '{01263A18-ED07-4F6F-98C9-D3564686F9BA}';
  IID_IEventList: TGUID = '{3A2C4214-3463-49FE-B2C4-F397B9695A44}';
  IID_IPlugView: TGUID = '{5BC32507-D060-49EA-A615-1B522B755B29}';

  kResultOk = 0;
  kResultFalse = 1;
  kInvalidArgument = -2147024809;   { 0x80070057 }
  kNotImplemented = -2147467263;    { 0x80004001 }
  kNoInterface = -2147467262;       { 0x80004002 }
  kOutOfMemory = -2147024882;       { 0x8007000E }

  kAudio = 0;
  kEvent = 1;
  kInput = 0;
  kOutput = 1;
  kBusMain = 0;
  kBusAux = 1;

  kSpeakerStereo: UInt64 = 3;               { L | R }
  kSpeakerMono: UInt64 = $80000;            { 1 shl 19 }

  { Event.EventType }
  kNoteOnEvent = 0;
  kNoteOffEvent = 1;
  kPolyPressureEvent = 3;
  kLegacyMIDICCOutEvent = 65535;
  kEventIsLive = 1;

  { ProcessContext.State }
  kPlaying = 1 shl 1;
  kCycleActive = 1 shl 2;
  kRecording = 1 shl 3;
  kSystemTimeValid = 1 shl 8;
  kProjectTimeMusicValid = 1 shl 9;
  kTempoValid = 1 shl 10;
  kBarPositionValid = 1 shl 11;
  kCycleValid = 1 shl 12;
  kTimeSigValid = 1 shl 13;
  kContTimeValid = 1 shl 17;

  { ParameterInfo.Flags }
  kCanAutomate = 1;
  kIsReadOnly = 2;
  kIsHidden = 1 shl 4;
  kIsProgramChange = 1 shl 15;
  kIsBypass = 1 shl 16;

  { controller numbers beyond the 128 MIDI CCs, for IMidiMapping }
  kAfterTouch = 128;
  kPitchBend = 129;
  kCtrlProgramChange = 130;
  MAP_STRIDE = 132;
  MAP_UNKNOWN = -2;
  MAP_NONE = -1;

  NO_PARAM = $FFFFFFFF;

  STATE_MAGIC: array[0..3] of AnsiChar = ('V', '3', 'S', 'T');

type
  { ---- vtable call signatures (all __stdcall) ---- }
  TFnQuery = function(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
  TFnRef = function(Self: Pointer): Cardinal; stdcall;
  TFnFactoryInfo = function(Self: Pointer; var Info: TFactoryInfo): Integer; stdcall;
  TFnCount = function(Self: Pointer): Integer; stdcall;
  TFnClassInfo = function(Self: Pointer; Index: Integer; var Info: TClassInfo): Integer; stdcall;
  TFnClassInfo2 = function(Self: Pointer; Index: Integer; var Info: TClassInfo2): Integer; stdcall;
  TFnCreate = function(Self: Pointer; const Cid, IID: TGUID; out Obj: Pointer): Integer; stdcall;
  TFnInit = function(Self: Pointer; Context: Pointer): Integer; stdcall;
  TFnTerm = function(Self: Pointer): Integer; stdcall;
  TFnGetCid = function(Self: Pointer; out Cid: TGUID): Integer; stdcall;
  TFnBusCount = function(Self: Pointer; MediaType, Dir: Integer): Integer; stdcall;
  TFnBusInfo = function(Self: Pointer; MediaType, Dir, Index: Integer; var Info: TBusInfo): Integer; stdcall;
  TFnActivateBus = function(Self: Pointer; MediaType, Dir, Index: Integer; State: Byte): Integer; stdcall;
  TFnSetActive = function(Self: Pointer; State: Byte): Integer; stdcall;
  TFnStateIO = function(Self: Pointer; Stream: Pointer): Integer; stdcall;
  TFnSetBusArr = function(Self: Pointer; Ins: PUInt64; NumIns: Integer;
    Outs: PUInt64; NumOuts: Integer): Integer; stdcall;
  TFnGetBusArr = function(Self: Pointer; Dir, Index: Integer; var Arr: UInt64): Integer; stdcall;
  TFnCanSize = function(Self: Pointer; Size: Integer): Integer; stdcall;
  TFnLatency = function(Self: Pointer): Cardinal; stdcall;
  TFnSetup = function(Self: Pointer; var Setup: TProcessSetup): Integer; stdcall;
  TFnSetProc = function(Self: Pointer; State: Byte): Integer; stdcall;
  TFnProcess = function(Self: Pointer; var Data: TProcessData): Integer; stdcall;
  TFnConnect = function(Self: Pointer; Other: Pointer): Integer; stdcall;
  TFnParamCount = function(Self: Pointer): Integer; stdcall;
  TFnParamInfo = function(Self: Pointer; Index: Integer; var Info: TParameterInfo): Integer; stdcall;
  TFnParamToString = function(Self: Pointer; Id: Cardinal; Value: Double; var Str: TString128): Integer; stdcall;
  TFnParamFromString = function(Self: Pointer; Id: Cardinal; Str: PWideChar; var Value: Double): Integer; stdcall;
  TFnGetNorm = function(Self: Pointer; Id: Cardinal): Double; stdcall;
  TFnSetNorm = function(Self: Pointer; Id: Cardinal; Value: Double): Integer; stdcall;
  TFnSetHandler = function(Self: Pointer; Handler: Pointer): Integer; stdcall;
  TFnCreateView = function(Self: Pointer; Name: PAnsiChar): Pointer; stdcall;
  TFnMidiAssign = function(Self: Pointer; BusIndex, Channel, Controller: Integer; var Id: Cardinal): Integer; stdcall;
  TFnProgListCount = function(Self: Pointer): Integer; stdcall;
  TFnProgListInfo = function(Self: Pointer; Index: Integer; var Info: TProgramListInfo): Integer; stdcall;
  TFnProgName = function(Self: Pointer; ListId, ProgIndex: Integer; var Name: TString128): Integer; stdcall;
  TFnViewSupported = function(Self: Pointer; PlatType: PAnsiChar): Integer; stdcall;
  TFnViewAttached = function(Self: Pointer; Parent: Pointer; PlatType: PAnsiChar): Integer; stdcall;
  TFnViewNoArg = function(Self: Pointer): Integer; stdcall;
  TFnViewRect = function(Self: Pointer; Rect: PViewRect): Integer; stdcall;
  TFnViewSetFrame = function(Self: Pointer; Frame: Pointer): Integer; stdcall;
  TFnModEntry = function: Pointer; stdcall;
  TFnModInit = function: Byte; cdecl;

function VT(AObj: Pointer; AIndex: Integer): Pointer; inline;
begin
  Result := PObj(AObj)^.VTable^[AIndex];
end;

function WStr(const A: TString128): string;
begin
  Result := string(PWideChar(@A[0]));
end;

function ReleaseObj(var AObj: Pointer): Boolean;
begin
  Result := AObj <> nil;
  if AObj <> nil then
  begin
    TFnRef(VT(AObj, 2))(AObj);
    AObj := nil;
  end;
end;

{ ============================ host-side COM objects ============================ }

var
  GHostAppVT, GSupportVT, GHandlerVT, GFrameVT, GEventVT, GParChVT, GQueueVT,
  GStreamVT, GMsgVT, GAttrVT: TVTable;
  GInit: Boolean;

function SameGuid(const A, B: TGUID): Boolean;
begin
  Result := IsEqualGUID(A, B);
end;

{ ---- IBStream over a TMemoryStream ---- }
type
  TStreamObj = record
    VTable: PVTable;
    Stream: TMemoryStream;
  end;
  PStreamObj = ^TStreamObj;

function StrmQuery(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
begin
  if SameGuid(IID, IID_FUnknown) or SameGuid(IID, IID_IBStream) then
  begin
    Obj := Self;
    Result := kResultOk;
  end
  else
  begin
    Obj := nil;
    Result := kNoInterface;
  end;
end;

function StrmRef(Self: Pointer): Cardinal; stdcall;
begin
  Result := 1;
end;

function StrmRead(Self: Pointer; Buffer: Pointer; NumBytes: Integer; NumRead: PInteger): Integer; stdcall;
var
  n: Integer;
begin
  n := PStreamObj(Self)^.Stream.Read(Buffer^, NumBytes);
  if NumRead <> nil then NumRead^ := n;
  Result := kResultOk;
end;

function StrmWrite(Self: Pointer; Buffer: Pointer; NumBytes: Integer; NumWritten: PInteger): Integer; stdcall;
var
  n: Integer;
begin
  n := PStreamObj(Self)^.Stream.Write(Buffer^, NumBytes);
  if NumWritten <> nil then NumWritten^ := n;
  Result := kResultOk;
end;

function StrmSeek(Self: Pointer; Pos: Int64; Mode: Integer; Res: PInt64): Integer; stdcall;
var
  s: TMemoryStream;
begin
  s := PStreamObj(Self)^.Stream;
  case Mode of
    0: s.Position := Pos;                 { kIBSeekSet }
    1: s.Position := s.Position + Pos;    { kIBSeekCur }
  else
    s.Position := s.Size + Pos;           { kIBSeekEnd }
  end;
  if Res <> nil then Res^ := s.Position;
  Result := kResultOk;
end;

function StrmTell(Self: Pointer; Pos: PInt64): Integer; stdcall;
begin
  if Pos <> nil then Pos^ := PStreamObj(Self)^.Stream.Position;
  Result := kResultOk;
end;

{ ---- IMessage / IAttributeList (heap objects with a reference count) ---- }
type
  TAttrVal = record
    Kind: Integer;          { 0 int, 1 float, 2 string, 3 binary }
    I: Int64;
    F: Double;
    S: string;
    B: TBytes;
  end;

  TMsgData = class
    MsgId: AnsiString;
    Attrs: TDictionary<string, TAttrVal>;
    constructor Create;
    destructor Destroy; override;
  end;

  PMsgObj = ^TMsgObj;
  TMsgObj = record
    MsgVT: PVTable;         { IMessage: a pointer to this field is the IMessage* }
    AttrVT: PVTable;        { IAttributeList: a pointer to this field is the IAttributeList* }
    Refs: Integer;
    Data: TMsgData;
  end;

constructor TMsgData.Create;
begin
  inherited Create;
  Attrs := TDictionary<string, TAttrVal>.Create;
end;

destructor TMsgData.Destroy;
begin
  Attrs.Free;
  inherited Destroy;
end;

function NewMessage: PMsgObj;
begin
  GetMem(Result, SizeOf(TMsgObj));
  FillChar(Result^, SizeOf(TMsgObj), 0);
  Result^.MsgVT := @GMsgVT;
  Result^.AttrVT := @GAttrVT;
  Result^.Refs := 1;
  Result^.Data := TMsgData.Create;
end;

function MsgFromMsgIface(Self: Pointer): PMsgObj; inline;
begin
  Result := PMsgObj(Self);
end;

function MsgFromAttrIface(Self: Pointer): PMsgObj; inline;
begin
  Result := PMsgObj(PByte(Self) - SizeOf(Pointer));
end;

function MsgAddRefObj(M: PMsgObj): Cardinal;
begin
  Inc(M^.Refs);
  Result := M^.Refs;
end;

function MsgReleaseObj(M: PMsgObj): Cardinal;
begin
  Dec(M^.Refs);
  Result := M^.Refs;
  if M^.Refs <= 0 then
  begin
    M^.Data.Free;
    FreeMem(M);
    Result := 0;
  end;
end;

function MsgQuery(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
var
  m: PMsgObj;
begin
  m := MsgFromMsgIface(Self);
  if SameGuid(IID, IID_FUnknown) or SameGuid(IID, IID_IMessage) then
    Obj := @m^.MsgVT
  else if SameGuid(IID, IID_IAttributeList) then
    Obj := @m^.AttrVT
  else
  begin
    Obj := nil;
    Exit(kNoInterface);
  end;
  MsgAddRefObj(m);
  Result := kResultOk;
end;

function MsgAddRef(Self: Pointer): Cardinal; stdcall;
begin
  Result := MsgAddRefObj(MsgFromMsgIface(Self));
end;

function MsgRelease(Self: Pointer): Cardinal; stdcall;
begin
  Result := MsgReleaseObj(MsgFromMsgIface(Self));
end;

function MsgGetId(Self: Pointer): PAnsiChar; stdcall;
begin
  Result := PAnsiChar(MsgFromMsgIface(Self)^.Data.MsgId);
end;

procedure MsgSetId(Self: Pointer; Id: PAnsiChar); stdcall;
begin
  MsgFromMsgIface(Self)^.Data.MsgId := AnsiString(Id);
end;

function MsgGetAttrs(Self: Pointer): Pointer; stdcall;
begin
  Result := @MsgFromMsgIface(Self)^.AttrVT;
end;

function AttrQuery(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
var
  m: PMsgObj;
begin
  m := MsgFromAttrIface(Self);
  if SameGuid(IID, IID_FUnknown) or SameGuid(IID, IID_IAttributeList) then
    Obj := @m^.AttrVT
  else if SameGuid(IID, IID_IMessage) then
    Obj := @m^.MsgVT
  else
  begin
    Obj := nil;
    Exit(kNoInterface);
  end;
  MsgAddRefObj(m);
  Result := kResultOk;
end;

function AttrAddRef(Self: Pointer): Cardinal; stdcall;
begin
  Result := MsgAddRefObj(MsgFromAttrIface(Self));
end;

function AttrRelease(Self: Pointer): Cardinal; stdcall;
begin
  Result := MsgReleaseObj(MsgFromAttrIface(Self));
end;

function AttrSetInt(Self: Pointer; Id: PAnsiChar; Value: Int64): Integer; stdcall;
var
  v: TAttrVal;
begin
  v := Default(TAttrVal);
  v.Kind := 0;
  v.I := Value;
  MsgFromAttrIface(Self)^.Data.Attrs.AddOrSetValue(string(AnsiString(Id)), v);
  Result := kResultOk;
end;

function AttrGetInt(Self: Pointer; Id: PAnsiChar; var Value: Int64): Integer; stdcall;
var
  v: TAttrVal;
begin
  if MsgFromAttrIface(Self)^.Data.Attrs.TryGetValue(string(AnsiString(Id)), v) and (v.Kind = 0) then
  begin
    Value := v.I;
    Result := kResultOk;
  end
  else
    Result := kResultFalse;
end;

function AttrSetFloat(Self: Pointer; Id: PAnsiChar; Value: Double): Integer; stdcall;
var
  v: TAttrVal;
begin
  v := Default(TAttrVal);
  v.Kind := 1;
  v.F := Value;
  MsgFromAttrIface(Self)^.Data.Attrs.AddOrSetValue(string(AnsiString(Id)), v);
  Result := kResultOk;
end;

function AttrGetFloat(Self: Pointer; Id: PAnsiChar; var Value: Double): Integer; stdcall;
var
  v: TAttrVal;
begin
  if MsgFromAttrIface(Self)^.Data.Attrs.TryGetValue(string(AnsiString(Id)), v) and (v.Kind = 1) then
  begin
    Value := v.F;
    Result := kResultOk;
  end
  else
    Result := kResultFalse;
end;

function AttrSetString(Self: Pointer; Id: PAnsiChar; Str: PWideChar): Integer; stdcall;
var
  v: TAttrVal;
begin
  v := Default(TAttrVal);
  v.Kind := 2;
  v.S := string(Str);
  MsgFromAttrIface(Self)^.Data.Attrs.AddOrSetValue(string(AnsiString(Id)), v);
  Result := kResultOk;
end;

function AttrGetString(Self: Pointer; Id: PAnsiChar; Str: PWideChar; SizeInBytes: Cardinal): Integer; stdcall;
var
  v: TAttrVal;
  n: Integer;
begin
  if MsgFromAttrIface(Self)^.Data.Attrs.TryGetValue(string(AnsiString(Id)), v) and (v.Kind = 2) then
  begin
    n := Min(Length(v.S), Integer(SizeInBytes div 2) - 1);
    if n < 0 then n := 0;
    if (Str <> nil) and (SizeInBytes >= 2) then
    begin
      if n > 0 then Move(PWideChar(v.S)^, Str^, n * 2);
      Str[n] := #0;
    end;
    Result := kResultOk;
  end
  else
    Result := kResultFalse;
end;

function AttrSetBinary(Self: Pointer; Id: PAnsiChar; Data: Pointer; Size: Cardinal): Integer; stdcall;
var
  v: TAttrVal;
begin
  v := Default(TAttrVal);
  v.Kind := 3;
  SetLength(v.B, Size);
  if (Size > 0) and (Data <> nil) then Move(Data^, v.B[0], Size);
  MsgFromAttrIface(Self)^.Data.Attrs.AddOrSetValue(string(AnsiString(Id)), v);
  Result := kResultOk;
end;

function AttrGetBinary(Self: Pointer; Id: PAnsiChar; var Data: Pointer; var Size: Cardinal): Integer; stdcall;
var
  m: PMsgObj;
  v: TAttrVal;
begin
  m := MsgFromAttrIface(Self);
  if m^.Data.Attrs.TryGetValue(string(AnsiString(Id)), v) and (v.Kind = 3) and (Length(v.B) > 0) then
  begin
    { the buffer must outlive this call: it lives in the dictionary entry (a dynamic array is
      shared by reference when the record is copied) }
    Data := @v.B[0];
    Size := Length(v.B);
    Result := kResultOk;
  end
  else
    Result := kResultFalse;
end;

{ ---- IHostApplication ---- }
function HostQuery(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
var
  h: PIface;
begin
  h := PIface(Self);
  if SameGuid(IID, IID_FUnknown) or SameGuid(IID, IID_IHostApplication) then
  begin
    Obj := Self;
    Result := kResultOk;
  end
  else if SameGuid(IID, IID_IPlugInterfaceSupport) then
  begin
    Obj := @h^.Host.FIPlugSupport;
    Result := kResultOk;
  end
  else
  begin
    Obj := nil;
    Result := kNoInterface;
  end;
end;

function HostAddRef(Self: Pointer): Cardinal; stdcall;
begin
  Result := 1;
end;

function HostGetName(Self: Pointer; Name: PWideChar): Integer; stdcall;
const
  N: string = 'UDAW';
var
  i: Integer;
begin
  for i := 1 to Length(N) do Name[i - 1] := N[i];
  Name[Length(N)] := #0;
  Result := kResultOk;
end;

function HostCreateInstance(Self: Pointer; const Cid, IID: TGUID; out Obj: Pointer): Integer; stdcall;
var
  m: PMsgObj;
begin
  Obj := nil;
  if SameGuid(Cid, IID_IMessage) or SameGuid(Cid, IID_IAttributeList) then
  begin
    m := NewMessage;
    if SameGuid(Cid, IID_IAttributeList) or SameGuid(IID, IID_IAttributeList) then
      Obj := @m^.AttrVT
    else
      Obj := @m^.MsgVT;
    Exit(kResultOk);
  end;
  Result := kNotImplemented;
end;

{ ---- IPlugInterfaceSupport ---- }
function SupportQuery(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
begin
  if SameGuid(IID, IID_FUnknown) or SameGuid(IID, IID_IPlugInterfaceSupport) then
  begin
    Obj := Self;
    Result := kResultOk;
  end
  else
  begin
    Obj := nil;
    Result := kNoInterface;
  end;
end;

function SupportIs(Self: Pointer; const IID: TGUID): Integer; stdcall;
begin
  if SameGuid(IID, IID_IComponent) or SameGuid(IID, IID_IAudioProcessor) or
     SameGuid(IID, IID_IEditController) or SameGuid(IID, IID_IConnectionPoint) or
     SameGuid(IID, IID_IPlugView) or SameGuid(IID, IID_IMidiMapping) or
     SameGuid(IID, IID_IUnitInfo) or SameGuid(IID, IID_IParameterChanges) or
     SameGuid(IID, IID_IParamValueQueue) or SameGuid(IID, IID_IEventList) or
     SameGuid(IID, IID_IMessage) or SameGuid(IID, IID_IAttributeList) then
    Result := kResultOk
  else
    Result := kResultFalse;
end;

{ ---- IComponentHandler ---- }
function HandlerQuery(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
begin
  if SameGuid(IID, IID_FUnknown) or SameGuid(IID, IID_IComponentHandler) then
  begin
    Obj := Self;
    Result := kResultOk;
  end
  else
  begin
    Obj := nil;
    Result := kNoInterface;
  end;
end;

function HandlerBegin(Self: Pointer; Id: Cardinal): Integer; stdcall;
begin
  PIface(Self)^.Host.HandlerBeginEdit(Id);
  Result := kResultOk;
end;

function HandlerPerform(Self: Pointer; Id: Cardinal; Value: Double): Integer; stdcall;
begin
  PIface(Self)^.Host.HandlerPerformEdit(Id, Value);
  Result := kResultOk;
end;

function HandlerEnd(Self: Pointer; Id: Cardinal): Integer; stdcall;
begin
  PIface(Self)^.Host.HandlerEndEdit(Id);
  Result := kResultOk;
end;

function HandlerRestart(Self: Pointer; Flags: Integer): Integer; stdcall;
begin
  PIface(Self)^.Host.HandlerRestart(Flags);
  Result := kResultOk;
end;

{ ---- IPlugFrame ---- }
function FrameQuery(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
begin
  if SameGuid(IID, IID_FUnknown) or SameGuid(IID, IID_IPlugFrame) then
  begin
    Obj := Self;
    Result := kResultOk;
  end
  else
  begin
    Obj := nil;
    Result := kNoInterface;
  end;
end;

function FrameResizeView(Self: Pointer; View: Pointer; NewSize: PViewRect): Integer; stdcall;
begin
  if NewSize <> nil then PIface(Self)^.Host.FrameResize(NewSize^);
  Result := kResultOk;
end;

{ ---- IEventList ---- }
function EvQuery(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
begin
  if SameGuid(IID, IID_FUnknown) or SameGuid(IID, IID_IEventList) then
  begin
    Obj := Self;
    Result := kResultOk;
  end
  else
  begin
    Obj := nil;
    Result := kNoInterface;
  end;
end;

function EvCount(Self: Pointer): Integer; stdcall;
begin
  if PIface(Self)^.Tag = 0 then Result := PIface(Self)^.Host.FEvInCount
  else Result := PIface(Self)^.Host.FEvOutCount;
end;

function EvGet(Self: Pointer; Index: Integer; var E: TVst3Event): Integer; stdcall;
var
  h: TVST3Host;
begin
  h := PIface(Self)^.Host;
  if (PIface(Self)^.Tag = 0) and (Index >= 0) and (Index < h.FEvInCount) then
  begin
    E := h.FEvIn[Index];
    Result := kResultOk;
  end
  else if (PIface(Self)^.Tag = 1) and (Index >= 0) and (Index < h.FEvOutCount) then
  begin
    E := h.FEvOut[Index];
    Result := kResultOk;
  end
  else
    Result := kInvalidArgument;
end;

function EvAdd(Self: Pointer; var E: TVst3Event): Integer; stdcall;
var
  h: TVST3Host;
begin
  h := PIface(Self)^.Host;
  if PIface(Self)^.Tag = 0 then Exit(kNotImplemented);   { the input list is read-only }
  if h.FEvOutCount >= PLUGIN_MAX_MIDI then Exit(kOutOfMemory);
  h.FEvOut[h.FEvOutCount] := E;
  Inc(h.FEvOutCount);
  Result := kResultOk;
end;

{ ---- IParameterChanges and IParamValueQueue ---- }
function ParChQuery(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
begin
  if SameGuid(IID, IID_FUnknown) or SameGuid(IID, IID_IParameterChanges) then
  begin
    Obj := Self;
    Result := kResultOk;
  end
  else
  begin
    Obj := nil;
    Result := kNoInterface;
  end;
end;

function ParChCount(Self: Pointer): Integer; stdcall;
begin
  if PIface(Self)^.Tag = 0 then Result := PIface(Self)^.Host.FInQCount
  else Result := PIface(Self)^.Host.FOutQCount;
end;

function ParChGetData(Self: Pointer; Index: Integer): Pointer; stdcall;
var
  h: TVST3Host;
begin
  h := PIface(Self)^.Host;
  if PIface(Self)^.Tag = 0 then
  begin
    if (Index >= 0) and (Index < h.FInQCount) then Result := @h.FInQ[Index] else Result := nil;
  end
  else
  begin
    if (Index >= 0) and (Index < h.FOutQCount) then Result := @h.FOutQ[Index] else Result := nil;
  end;
end;

function ParChAddData(Self: Pointer; Id: PCardinal; var Index: Integer): Pointer; stdcall;
var
  h: TVST3Host;
  i: Integer;
begin
  Result := nil;
  h := PIface(Self)^.Host;
  if PIface(Self)^.Tag = 0 then
  begin
    for i := 0 to h.FInQCount - 1 do
      if h.FInQ[i].Id = Id^ then
      begin
        Index := i;
        Exit(@h.FInQ[i]);
      end;
    if h.FInQCount >= Length(h.FInQ) then Exit;
    h.FInQ[h.FInQCount].Id := Id^;
    h.FInQ[h.FInQCount].Count := 0;
    Index := h.FInQCount;
    Result := @h.FInQ[h.FInQCount];
    Inc(h.FInQCount);
  end
  else
  begin
    for i := 0 to h.FOutQCount - 1 do
      if h.FOutQ[i].Id = Id^ then
      begin
        Index := i;
        Exit(@h.FOutQ[i]);
      end;
    if h.FOutQCount >= Length(h.FOutQ) then Exit;
    h.FOutQ[h.FOutQCount].Id := Id^;
    h.FOutQ[h.FOutQCount].Count := 0;
    Index := h.FOutQCount;
    Result := @h.FOutQ[h.FOutQCount];
    Inc(h.FOutQCount);
  end;
end;

function QQuery(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
begin
  if SameGuid(IID, IID_FUnknown) or SameGuid(IID, IID_IParamValueQueue) then
  begin
    Obj := Self;
    Result := kResultOk;
  end
  else
  begin
    Obj := nil;
    Result := kNoInterface;
  end;
end;

function QGetId(Self: Pointer): Cardinal; stdcall;
begin
  Result := PQueueObj(Self)^.Id;
end;

function QPointCount(Self: Pointer): Integer; stdcall;
begin
  Result := PQueueObj(Self)^.Count;
end;

function QGetPoint(Self: Pointer; Index: Integer; var SampleOffset: Integer; var Value: Double): Integer; stdcall;
var
  q: PQueueObj;
begin
  q := PQueueObj(Self);
  if (Index < 0) or (Index >= q^.Count) then Exit(kInvalidArgument);
  SampleOffset := q^.Offsets[Index];
  Value := q^.Values[Index];
  Result := kResultOk;
end;

function QAddPoint(Self: Pointer; SampleOffset: Integer; Value: Double; var Index: Integer): Integer; stdcall;
var
  q: PQueueObj;
begin
  q := PQueueObj(Self);
  if q^.Count >= Length(q^.Offsets) then
  begin
    { full: the newest value replaces the last point }
    q^.Offsets[q^.Count - 1] := SampleOffset;
    q^.Values[q^.Count - 1] := Value;
    Index := q^.Count - 1;
    Exit(kResultOk);
  end;
  q^.Offsets[q^.Count] := SampleOffset;
  q^.Values[q^.Count] := Value;
  Index := q^.Count;
  Inc(q^.Count);
  Result := kResultOk;
end;

procedure InitGlobals;
begin
  if GInit then Exit;
  GInit := True;
  GHostAppVT[0] := @HostQuery;   GHostAppVT[1] := @HostAddRef;  GHostAppVT[2] := @HostAddRef;
  GHostAppVT[3] := @HostGetName; GHostAppVT[4] := @HostCreateInstance;
  GSupportVT[0] := @SupportQuery; GSupportVT[1] := @HostAddRef; GSupportVT[2] := @HostAddRef;
  GSupportVT[3] := @SupportIs;
  GHandlerVT[0] := @HandlerQuery; GHandlerVT[1] := @HostAddRef; GHandlerVT[2] := @HostAddRef;
  GHandlerVT[3] := @HandlerBegin; GHandlerVT[4] := @HandlerPerform; GHandlerVT[5] := @HandlerEnd;
  GHandlerVT[6] := @HandlerRestart;
  GFrameVT[0] := @FrameQuery; GFrameVT[1] := @HostAddRef; GFrameVT[2] := @HostAddRef;
  GFrameVT[3] := @FrameResizeView;
  GEventVT[0] := @EvQuery; GEventVT[1] := @HostAddRef; GEventVT[2] := @HostAddRef;
  GEventVT[3] := @EvCount; GEventVT[4] := @EvGet; GEventVT[5] := @EvAdd;
  GParChVT[0] := @ParChQuery; GParChVT[1] := @HostAddRef; GParChVT[2] := @HostAddRef;
  GParChVT[3] := @ParChCount; GParChVT[4] := @ParChGetData; GParChVT[5] := @ParChAddData;
  GQueueVT[0] := @QQuery; GQueueVT[1] := @HostAddRef; GQueueVT[2] := @HostAddRef;
  GQueueVT[3] := @QGetId; GQueueVT[4] := @QPointCount; GQueueVT[5] := @QGetPoint;
  GQueueVT[6] := @QAddPoint;
  GStreamVT[0] := @StrmQuery; GStreamVT[1] := @StrmRef; GStreamVT[2] := @StrmRef;
  GStreamVT[3] := @StrmRead; GStreamVT[4] := @StrmWrite; GStreamVT[5] := @StrmSeek;
  GStreamVT[6] := @StrmTell;
  GMsgVT[0] := @MsgQuery; GMsgVT[1] := @MsgAddRef; GMsgVT[2] := @MsgRelease;
  GMsgVT[3] := @MsgGetId; GMsgVT[4] := @MsgSetId; GMsgVT[5] := @MsgGetAttrs;
  GAttrVT[0] := @AttrQuery; GAttrVT[1] := @AttrAddRef; GAttrVT[2] := @AttrRelease;
  GAttrVT[3] := @AttrSetInt; GAttrVT[4] := @AttrGetInt; GAttrVT[5] := @AttrSetFloat;
  GAttrVT[6] := @AttrGetFloat; GAttrVT[7] := @AttrSetString; GAttrVT[8] := @AttrGetString;
  GAttrVT[9] := @AttrSetBinary; GAttrVT[10] := @AttrGetBinary;
end;

{ ============================ TVST3Host ============================ }

constructor TVST3Host.Create;
var
  i: Integer;
begin
  inherited Create;
  InitGlobals;
  FIdToVisible := TDictionary<Cardinal, Integer>.Create;
  FParamLock := TCriticalSection.Create;
  FProgParamId := NO_PARAM;
  FBypassParamId := NO_PARAM;
  FProgListId := -1;
  FIHostApp.VTable := @GHostAppVT;   FIHostApp.Host := Self;
  FIPlugSupport.VTable := @GSupportVT; FIPlugSupport.Host := Self;
  FIHandler.VTable := @GHandlerVT;   FIHandler.Host := Self;
  FIFrame.VTable := @GFrameVT;       FIFrame.Host := Self;
  FIEvIn.VTable := @GEventVT;        FIEvIn.Host := Self;   FIEvIn.Tag := 0;
  FIEvOut.VTable := @GEventVT;       FIEvOut.Host := Self;  FIEvOut.Tag := 1;
  FIParIn.VTable := @GParChVT;       FIParIn.Host := Self;  FIParIn.Tag := 0;
  FIParOut.VTable := @GParChVT;      FIParOut.Host := Self; FIParOut.Tag := 1;
  for i := 0 to High(FInQ) do FInQ[i].VTable := @GQueueVT;
  for i := 0 to High(FOutQ) do FOutQ[i].VTable := @GQueueVT;
  QueryPerformanceFrequency(FStopFreq);
  QueryPerformanceCounter(FStopStart);
  FNextNoteId := 1;
  for i := 0 to High(FNoteIds) do FNoteIds[i] := -1;
end;

destructor TVST3Host.Destroy;
begin
  Close;
  FIdToVisible.Free;
  FParamLock.Free;
  inherited Destroy;
end;

function TVST3Host.FormatName: string;
begin
  Result := 'VST3';
end;

function TVST3Host.IsLoaded: Boolean;
begin
  Result := FProcessor <> nil;
end;

function TVST3Host.EffectName: string;
begin
  Result := FName;
end;

function TVST3Host.VendorString: string;
begin
  Result := FVendor;
end;

function TVST3Host.SubCategories: string;
begin
  Result := FSubCats;
end;

function TVST3Host.IsSynth: Boolean;
begin
  Result := (Pos('instrument', LowerCase(FSubCats)) > 0) or (Pos('synth', LowerCase(FSubCats)) > 0) or
            (Pos('sampler', LowerCase(FSubCats)) > 0) or
            ((FProcessor <> nil) and (FInTotal = 0) and (FEventIn > 0) and (FOutTotal > 0));
end;

function TVST3Host.WantsMidi: Boolean;
begin
  Result := IsSynth or (FEventIn > 0);
end;

function TVST3Host.InputBusCount: Integer;
begin
  Result := FInBusCount;
end;

function TVST3Host.OutputBusCount: Integer;
begin
  Result := FOutBusCount;
end;

function TVST3Host.HasSidechainInput: Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to FInBusCount - 1 do
    if FInBusAux[i] then Exit(True);
end;

function TVST3Host.NumInputs: Integer;
begin
  Result := FInTotal;
end;

function TVST3Host.NumOutputs: Integer;
begin
  Result := FOutTotal;
end;

function TVST3Host.ResolveModulePath(const APath: string): string;
var
  arch: string;
begin
  Result := APath;
  if DirectoryExists(APath) then
  begin
    {$IFDEF CPUX64}
    arch := 'x86_64-win';
    {$ELSE}
    arch := 'x86-win';
    {$ENDIF}
    Result := IncludeTrailingPathDelimiter(APath) + 'Contents' + PathDelim + arch +
      PathDelim + ChangeFileExt(ExtractFileName(ExcludeTrailingPathDelimiter(APath)), '') + '.vst3';
  end;
end;

procedure TVST3Host.LoadOnly(const APath: string);
var
  entry: TFnModEntry;
  modInit: TFnModInit;
  cnt, i, r: Integer;
  ci: TClassInfo;
  ci2: TClassInfo2;
  fi: TFactoryInfo;
  fac2: Pointer;
  found: Boolean;
  comp, proc: Pointer;
  haveInfo2: Boolean;
begin
  Close;
  FPath := APath;
  FModule := LoadLibrary(PChar(ResolveModulePath(APath)));
  if FModule = 0 then
    raise EVST3Error.CreateFmt('Cannot load VST3 module "%s" (error %d)', [APath, GetLastError]);
  try
    @modInit := GetProcAddress(FModule, 'InitDll');
    if Assigned(modInit) then modInit;
    @entry := GetProcAddress(FModule, 'GetPluginFactory');
    if not Assigned(entry) then
      raise EVST3Error.Create('Not a VST3 plugin: missing GetPluginFactory export');
    FFactory := entry();
    if FFactory = nil then raise EVST3Error.Create('VST3 factory is nil');
    FillChar(fi, SizeOf(fi), 0);
    TFnFactoryInfo(VT(FFactory, 3))(FFactory, fi);
    FVendor := string(AnsiString(PAnsiChar(@fi.Vendor[0])));
    fac2 := nil;
    if TFnQuery(VT(FFactory, 0))(FFactory, IID_IPluginFactory2, fac2) <> kResultOk then fac2 := nil;
    cnt := TFnCount(VT(FFactory, 4))(FFactory);
    found := False;
    comp := nil;
    for i := 0 to cnt - 1 do
    begin
      FillChar(ci, SizeOf(ci), 0);
      if TFnClassInfo(VT(FFactory, 5))(FFactory, i, ci) <> kResultOk then Continue;
      if not SameText(string(AnsiString(PAnsiChar(@ci.Category[0]))), 'Audio Module Class') then Continue;
      FName := string(AnsiString(PAnsiChar(@ci.Name[0])));
      FSubCats := '';
      haveInfo2 := False;
      if fac2 <> nil then
      begin
        FillChar(ci2, SizeOf(ci2), 0);
        haveInfo2 := TFnClassInfo2(VT(fac2, 7))(fac2, i, ci2) = kResultOk;
      end;
      if haveInfo2 then
      begin
        FSubCats := string(AnsiString(PAnsiChar(@ci2.SubCategories[0])));
        if string(AnsiString(PAnsiChar(@ci2.Vendor[0]))) <> '' then
          FVendor := string(AnsiString(PAnsiChar(@ci2.Vendor[0])));
      end;
      r := TFnCreate(VT(FFactory, 6))(FFactory, ci.Cid, IID_IComponent, comp);
      if (r <> kResultOk) or (comp = nil) then
      begin
        ReleaseObj(fac2);
        raise EVST3Error.Create('VST3 createInstance(IComponent) failed');
      end;
      FComponent := comp;
      found := True;
      Break;
    end;
    ReleaseObj(fac2);
    if not found then raise EVST3Error.Create('VST3 module has no Audio Module Class');
    r := TFnInit(VT(FComponent, 3))(FComponent, @FIHostApp);
    if r <> kResultOk then raise EVST3Error.Create('VST3 component initialize failed');
    FInitialised := True;
    proc := nil;
    r := TFnQuery(VT(FComponent, 0))(FComponent, IID_IAudioProcessor, proc);
    if (r <> kResultOk) or (proc = nil) then
      raise EVST3Error.Create('VST3 component has no IAudioProcessor');
    FProcessor := proc;

    CreateController;
    ReadParameters;
    ReadPrograms;

    { bus layout, so the instrument / effect question can be answered before Configure }
    FInBusCount := Max(0, TFnBusCount(VT(FComponent, 7))(FComponent, kAudio, kInput));
    FOutBusCount := Max(0, TFnBusCount(VT(FComponent, 7))(FComponent, kAudio, kOutput));
    FEventIn := Max(0, TFnBusCount(VT(FComponent, 7))(FComponent, kEvent, kInput));
    FEventOut := Max(0, TFnBusCount(VT(FComponent, 7))(FComponent, kEvent, kOutput));
    SetupBuses;

    if FRequireEffect and ((FInTotal = 0) or (FOutTotal = 0) or IsSynth) then
      raise EVST3Error.CreateFmt('VST3: "%s" is an instrument, not an audio effect', [FName]);
    if FOutTotal = 0 then
      raise EVST3Error.CreateFmt('VST3: "%s" has no audio outputs', [FName]);
  except
    Close;
    raise;
  end;
end;

procedure TVST3Host.CreateController;
var
  ctrl, cp1, cp2: Pointer;
  cid: TGUID;
  r: Integer;
begin
  ctrl := nil;
  FCtrlIsComponent := False;
  { a single-component plug-in is its own controller }
  if TFnQuery(VT(FComponent, 0))(FComponent, IID_IEditController, ctrl) = kResultOk then
  begin
    if ctrl <> nil then
    begin
      FController := ctrl;
      FCtrlIsComponent := True;
    end;
  end
  else
    ctrl := nil;
  if FController = nil then
  begin
    FillChar(cid, SizeOf(cid), 0);
    if TFnGetCid(VT(FComponent, 5))(FComponent, cid) = kResultOk then
    begin
      ctrl := nil;
      r := TFnCreate(VT(FFactory, 6))(FFactory, cid, IID_IEditController, ctrl);
      if (r = kResultOk) and (ctrl <> nil) then
      begin
        if TFnInit(VT(ctrl, 3))(ctrl, @FIHostApp) = kResultOk then
          FController := ctrl
        else
        begin
          TFnRef(VT(ctrl, 2))(ctrl);
          ctrl := nil;
        end;
      end;
    end;
  end;
  if FController = nil then Exit;

  TFnSetHandler(VT(FController, 16))(FController, @FIHandler);

  { component <-> controller messaging }
  if not FCtrlIsComponent then
  begin
    cp1 := nil;
    cp2 := nil;
    if (TFnQuery(VT(FComponent, 0))(FComponent, IID_IConnectionPoint, cp1) = kResultOk) and (cp1 <> nil) and
       (TFnQuery(VT(FController, 0))(FController, IID_IConnectionPoint, cp2) = kResultOk) and (cp2 <> nil) then
    begin
      TFnConnect(VT(cp1, 3))(cp1, cp2);
      TFnConnect(VT(cp2, 3))(cp2, cp1);
    end;
    ReleaseObj(cp1);
    ReleaseObj(cp2);
  end;

  { optional controller interfaces }
  if TFnQuery(VT(FController, 0))(FController, IID_IMidiMapping, FMidiMap) <> kResultOk then FMidiMap := nil;
  if TFnQuery(VT(FController, 0))(FController, IID_IUnitInfo, FUnitInfo) <> kResultOk then FUnitInfo := nil;
  SetLength(FMapCache, 16 * MAP_STRIDE);
  FillChar(FMapCache[0], Length(FMapCache) * SizeOf(Int64), $FF);   { all -1 ... reset below }
  for r := 0 to High(FMapCache) do FMapCache[r] := MAP_UNKNOWN;

  SyncControllerState;
end;

procedure TVST3Host.SyncControllerState;
var
  so: TStreamObj;
  ms: TMemoryStream;
begin
  if (FController = nil) or (FComponent = nil) then Exit;
  ms := TMemoryStream.Create;
  try
    so.VTable := @GStreamVT;
    so.Stream := ms;
    if TFnStateIO(VT(FComponent, 13))(FComponent, @so) = kResultOk then
    begin
      ms.Position := 0;
      TFnStateIO(VT(FController, 5))(FController, @so);
    end;
  finally
    ms.Free;
  end;
end;

procedure TVST3Host.ReadParameters;
var
  n, i, k: Integer;
  info: TParameterInfo;
begin
  SetLength(FParams, 0);
  SetLength(FVisible, 0);
  FIdToVisible.Clear;
  FProgParamId := NO_PARAM;
  FBypassParamId := NO_PARAM;
  if FController = nil then Exit;
  n := TFnParamCount(VT(FController, 8))(FController);
  if n < 0 then n := 0;
  if n > 65536 then n := 65536;
  SetLength(FParams, n);
  SetLength(FLastSent, n);
  for i := 0 to n - 1 do FLastSent[i] := -1;
  k := 0;
  for i := 0 to n - 1 do
  begin
    FillChar(info, SizeOf(info), 0);
    if TFnParamInfo(VT(FController, 9))(FController, i, info) <> kResultOk then
    begin
      FParams[i].Id := NO_PARAM;
      Continue;
    end;
    FParams[i].Id := info.Id;
    FParams[i].Title := WStr(info.Title);
    FParams[i].Units := WStr(info.Units);
    FParams[i].StepCount := info.StepCount;
    FParams[i].Default := info.DefaultNormalized;
    FParams[i].UnitId := info.UnitId;
    FParams[i].Flags := info.Flags;
    if (info.Flags and kIsProgramChange) <> 0 then FProgParamId := info.Id;
    if (info.Flags and kIsBypass) <> 0 then FBypassParamId := info.Id;
    if (info.Flags and kIsHidden) = 0 then
    begin
      SetLength(FVisible, k + 1);
      FVisible[k] := i;
      FIdToVisible.AddOrSetValue(info.Id, k);
      Inc(k);
    end;
  end;
end;

procedure TVST3Host.ReadPrograms;
var
  cnt, i: Integer;
  pli: TProgramListInfo;
begin
  FProgListId := -1;
  FProgCount := 0;
  if FUnitInfo <> nil then
  begin
    cnt := TFnProgListCount(VT(FUnitInfo, 5))(FUnitInfo);
    for i := 0 to cnt - 1 do
    begin
      FillChar(pli, SizeOf(pli), 0);
      if TFnProgListInfo(VT(FUnitInfo, 6))(FUnitInfo, i, pli) = kResultOk then
      begin
        FProgListId := pli.Id;
        FProgCount := pli.ProgramCount;
        Break;
      end;
    end;
  end;
  if (FProgCount = 0) and (FProgParamId <> NO_PARAM) then
    for i := 0 to High(FParams) do
      if FParams[i].Id = FProgParamId then
      begin
        FProgCount := FParams[i].StepCount + 1;
        Break;
      end;
end;

{ Negotiates the bus arrangement (stereo, or mono when one channel is asked for), activates the
  buses and (re)allocates the audio buffers. }
procedure TVST3Host.SetupBuses;
var
  i, c, nIn, nOut: Integer;
  bi: TBusInfo;
  inArr, outArr: array of UInt64;
  arr: UInt64;
  mainArr: UInt64;

  function Popcount(AValue: UInt64): Integer;
  begin
    Result := 0;
    while AValue <> 0 do
    begin
      Inc(Result, Integer(AValue and 1));
      AValue := AValue shr 1;
    end;
  end;

begin
  if FProcessor = nil then Exit;
  nIn := FInBusCount;
  nOut := FOutBusCount;
  SetLength(FInBusCh, nIn);
  SetLength(FOutBusCh, nOut);
  SetLength(FInBusAux, nIn);
  SetLength(FOutBusAux, nOut);
  SetLength(FInBusFirst, nIn);
  SetLength(FOutBusFirst, nOut);
  if FChannels = 1 then mainArr := kSpeakerMono else mainArr := kSpeakerStereo;

  SetLength(inArr, Max(1, nIn));
  SetLength(outArr, Max(1, nOut));
  for i := 0 to nIn - 1 do
  begin
    FillChar(bi, SizeOf(bi), 0);
    TFnBusInfo(VT(FComponent, 8))(FComponent, kAudio, kInput, i, bi);
    FInBusAux[i] := bi.BusType = kBusAux;
    FInBusCh[i] := bi.ChannelCount;
    arr := 0;
    if TFnGetBusArr(VT(FProcessor, 4))(FProcessor, kInput, i, arr) <> kResultOk then arr := 0;
    if (i = 0) and not FInBusAux[i] then arr := mainArr;
    inArr[i] := arr;
  end;
  for i := 0 to nOut - 1 do
  begin
    FillChar(bi, SizeOf(bi), 0);
    TFnBusInfo(VT(FComponent, 8))(FComponent, kAudio, kOutput, i, bi);
    FOutBusAux[i] := bi.BusType = kBusAux;
    FOutBusCh[i] := bi.ChannelCount;
    arr := 0;
    if TFnGetBusArr(VT(FProcessor, 4))(FProcessor, kOutput, i, arr) <> kResultOk then arr := 0;
    if (i = 0) and not FOutBusAux[i] then arr := mainArr;
    outArr[i] := arr;
  end;
  TFnSetBusArr(VT(FProcessor, 3))(FProcessor, @inArr[0], nIn, @outArr[0], nOut);

  { what the plug-in settled on }
  FInTotal := 0;
  FOutTotal := 0;
  for i := 0 to nIn - 1 do
  begin
    arr := 0;
    if TFnGetBusArr(VT(FProcessor, 4))(FProcessor, kInput, i, arr) = kResultOk then
    begin
      c := Popcount(arr);
      if c > 0 then FInBusCh[i] := c;
    end;
    FInBusFirst[i] := FInTotal;
    Inc(FInTotal, FInBusCh[i]);
  end;
  for i := 0 to nOut - 1 do
  begin
    arr := 0;
    if TFnGetBusArr(VT(FProcessor, 4))(FProcessor, kOutput, i, arr) = kResultOk then
    begin
      c := Popcount(arr);
      if c > 0 then FOutBusCh[i] := c;
    end;
    FOutBusFirst[i] := FOutTotal;
    Inc(FOutTotal, FOutBusCh[i]);
  end;

  { buffers }
  if FMaxFrames < 1 then FMaxFrames := 1;
  SetLength(FInStore, Max(1, FInTotal) * FMaxFrames);
  SetLength(FOutStore, Max(1, FOutTotal) * FMaxFrames);
  SetLength(FInPtrs, Max(1, FInTotal));
  SetLength(FOutPtrs, Max(1, FOutTotal));
  for c := 0 to FInTotal - 1 do FInPtrs[c] := @FInStore[c * FMaxFrames];
  for c := 0 to FOutTotal - 1 do FOutPtrs[c] := @FOutStore[c * FMaxFrames];
  SetLength(FInBuses, Max(1, nIn));
  SetLength(FOutBuses, Max(1, nOut));
  for i := 0 to nIn - 1 do
  begin
    FInBuses[i].NumChannels := FInBusCh[i];
    FInBuses[i].SilenceFlags := 0;
    if FInBusCh[i] > 0 then FInBuses[i].ChannelBuffers32 := @FInPtrs[FInBusFirst[i]]
    else FInBuses[i].ChannelBuffers32 := nil;
  end;
  for i := 0 to nOut - 1 do
  begin
    FOutBuses[i].NumChannels := FOutBusCh[i];
    FOutBuses[i].SilenceFlags := 0;
    if FOutBusCh[i] > 0 then FOutBuses[i].ChannelBuffers32 := @FOutPtrs[FOutBusFirst[i]]
    else FOutBuses[i].ChannelBuffers32 := nil;
  end;
end;

procedure TVST3Host.LoadAndOpen(const APath: string; ASampleRate, AMaxFrames, AChannels: Integer);
begin
  FChannels := Max(AChannels, 1);
  FMaxFrames := Max(AMaxFrames, 1);
  LoadOnly(APath);
  Configure(ASampleRate, AMaxFrames, AChannels);
end;

procedure TVST3Host.Configure(ASampleRate, AMaxFrames, AChannels: Integer);
var
  i, r: Integer;
  setup: TProcessSetup;
begin
  if FProcessor = nil then Exit;
  if FActive then
  begin
    TFnSetProc(VT(FProcessor, 8))(FProcessor, 0);
    TFnSetActive(VT(FComponent, 11))(FComponent, 0);
    FActive := False;
    FProcessing := False;
  end;
  FSampleRate := ASampleRate;
  FMaxFrames := Max(AMaxFrames, 1);
  FChannels := Max(AChannels, 1);
  SetupBuses;
  if TFnCanSize(VT(FProcessor, 5))(FProcessor, 0) <> kResultOk then
    raise EVST3Error.Create('VST3 plugin does not support 32-bit processing');
  setup.ProcessMode := IfThen(FOffline, 2, 0);   { kRealtime / kOffline }
  setup.SymbolicSampleSize := 0;                 { kSample32 }
  setup.MaxSamplesPerBlock := FMaxFrames;
  setup.SampleRate := FSampleRate;
  if TFnSetup(VT(FProcessor, 7))(FProcessor, setup) <> kResultOk then
    raise EVST3Error.Create('VST3 setupProcessing failed');
  for i := 0 to FInBusCount - 1 do TFnActivateBus(VT(FComponent, 10))(FComponent, kAudio, kInput, i, 1);
  for i := 0 to FOutBusCount - 1 do TFnActivateBus(VT(FComponent, 10))(FComponent, kAudio, kOutput, i, 1);
  for i := 0 to FEventIn - 1 do TFnActivateBus(VT(FComponent, 10))(FComponent, kEvent, kInput, i, 1);
  for i := 0 to FEventOut - 1 do TFnActivateBus(VT(FComponent, 10))(FComponent, kEvent, kOutput, i, 1);
  TFnSetActive(VT(FComponent, 11))(FComponent, 1);
  FActive := True;
  r := TFnSetProc(VT(FProcessor, 8))(FProcessor, 1);
  if (r = kResultOk) or (r = kNotImplemented) then FProcessing := True;
  FContSamples := 0;
end;

procedure TVST3Host.ReleaseAll;
var
  cp1, cp2: Pointer;
  modExit: TFnModInit;
begin
  if FView <> nil then CloseEditor;
  if FComponent <> nil then
  begin
    if FProcessing and (FProcessor <> nil) then
      TFnSetProc(VT(FProcessor, 8))(FProcessor, 0);
    if FActive then TFnSetActive(VT(FComponent, 11))(FComponent, 0);
    FActive := False;
    FProcessing := False;
    { break the component <-> controller connection }
    if (FController <> nil) and not FCtrlIsComponent then
    begin
      cp1 := nil;
      cp2 := nil;
      if (TFnQuery(VT(FComponent, 0))(FComponent, IID_IConnectionPoint, cp1) = kResultOk) and (cp1 <> nil) and
         (TFnQuery(VT(FController, 0))(FController, IID_IConnectionPoint, cp2) = kResultOk) and (cp2 <> nil) then
      begin
        TFnConnect(VT(cp1, 4))(cp1, cp2);
        TFnConnect(VT(cp2, 4))(cp2, cp1);
      end;
      ReleaseObj(cp1);
      ReleaseObj(cp2);
    end;
  end;
  if FController <> nil then
  begin
    TFnSetHandler(VT(FController, 16))(FController, nil);
    ReleaseObj(FMidiMap);
    ReleaseObj(FUnitInfo);
    if not FCtrlIsComponent then
    begin
      TFnTerm(VT(FController, 4))(FController);
      ReleaseObj(FController);
    end
    else
      ReleaseObj(FController);   { the extra reference taken by QueryInterface }
  end;
  FController := nil;
  if FProcessor <> nil then ReleaseObj(FProcessor);
  if FComponent <> nil then
  begin
    if FInitialised then TFnTerm(VT(FComponent, 4))(FComponent);
    ReleaseObj(FComponent);
  end;
  FInitialised := False;
  if FFactory <> nil then ReleaseObj(FFactory);
  if FModule <> 0 then
  begin
    @modExit := GetProcAddress(FModule, 'ExitDll');
    if Assigned(modExit) then modExit;
    FreeLibrary(FModule);
    FModule := 0;
  end;
end;

procedure TVST3Host.Close;
begin
  ReleaseAll;
  FPendingCount := 0;
  FOutChangeCount := 0;
  FEvInCount := 0;
  FEvOutCount := 0;
  FInBusCount := 0;
  FOutBusCount := 0;
  FInTotal := 0;
  FOutTotal := 0;
  FEventIn := 0;
  FEventOut := 0;
  FView := nil;
  FEditorWnd := 0;
  SetLength(FParams, 0);
  SetLength(FVisible, 0);
  FIdToVisible.Clear;
  ClearMidiIn;
end;

procedure TVST3Host.Reset;
begin
  if (FComponent = nil) or (not FActive) then Exit;
  ClearMidiIn;
  FillChar(FNoteIds, SizeOf(FNoteIds), $FF);
  { plugins reset their DSP state on an active off/on cycle }
  TFnSetProc(VT(FProcessor, 8))(FProcessor, 0);
  TFnSetActive(VT(FComponent, 11))(FComponent, 0);
  TFnSetActive(VT(FComponent, 11))(FComponent, 1);
  TFnSetProc(VT(FProcessor, 8))(FProcessor, 1);
end;

function TVST3Host.LatencySamples: Integer;
begin
  if FProcessor = nil then Exit(0);
  Result := Integer(TFnLatency(VT(FProcessor, 6))(FProcessor));
end;

function TVST3Host.TailSamples: Integer;
var
  t: Cardinal;
begin
  if FProcessor = nil then Exit(0);
  t := TFnLatency(VT(FProcessor, 10))(FProcessor);
  if t = 0 then Result := 1                       { no tail }
  else if t = $FFFFFFFF then Result := MaxInt     { infinite }
  else Result := Integer(Min(t, Cardinal(MaxInt)));
end;

function TVST3Host.SupportsBypass: Boolean;
begin
  Result := FBypassParamId <> NO_PARAM;
end;

procedure TVST3Host.SetBypass(ABypass: Boolean);
begin
  if FBypassParamId = NO_PARAM then Exit;
  SetParamById(FBypassParamId, Ord(ABypass));
end;

procedure TVST3Host.SetSidechain(const AChannels: array of System.PSingle);
var
  i: Integer;
begin
  SetLength(FSide, Length(AChannels));
  for i := 0 to High(AChannels) do FSide[i] := AChannels[i];
end;

function TVST3Host.OutputChannel(ACh: Integer): System.PSingle;
begin
  if (ACh < 0) or (ACh >= FOutTotal) then Exit(nil);
  Result := FOutPtrs[ACh];
end;

{ ---- parameters ---- }

function TVST3Host.ParamIndexOfVisible(AVisible: Integer): Integer;
begin
  if (AVisible < 0) or (AVisible > High(FVisible)) then Exit(-1);
  Result := FVisible[AVisible];
end;

function TVST3Host.ParamCount: Integer;
begin
  Result := Length(FVisible);
end;

function TVST3Host.ParamName(AIndex: Integer): string;
var
  k: Integer;
begin
  k := ParamIndexOfVisible(AIndex);
  if k < 0 then Exit('');
  Result := FParams[k].Title;
end;

function TVST3Host.ParamLabel(AIndex: Integer): string;
var
  k: Integer;
begin
  k := ParamIndexOfVisible(AIndex);
  if k < 0 then Exit('');
  Result := FParams[k].Units;
end;

function TVST3Host.ControllerValue(AId: Cardinal): Double;
begin
  if FController = nil then Exit(0);
  Result := TFnGetNorm(VT(FController, 14))(FController, AId);
end;

function TVST3Host.ParamDisplay(AIndex: Integer): string;
var
  k: Integer;
  s: TString128;
begin
  k := ParamIndexOfVisible(AIndex);
  if (k < 0) or (FController = nil) then Exit('');
  FillChar(s, SizeOf(s), 0);
  if TFnParamToString(VT(FController, 10))(FController, FParams[k].Id,
       ControllerValue(FParams[k].Id), s) = kResultOk then
    Result := WStr(s)
  else
    Result := Format('%.3f', [ControllerValue(FParams[k].Id)]);
end;

function TVST3Host.GetParam(AIndex: Integer): Single;
var
  k: Integer;
begin
  k := ParamIndexOfVisible(AIndex);
  if k < 0 then Exit(0);
  Result := ControllerValue(FParams[k].Id);
end;

procedure TVST3Host.SetParamById(AId: Cardinal; AValue: Double);
begin
  if FController = nil then Exit;
  if AValue < 0 then AValue := 0 else if AValue > 1 then AValue := 1;
  TFnSetNorm(VT(FController, 15))(FController, AId, AValue);
  AddPending(AId, AValue, 0);
end;

procedure TVST3Host.SetParam(AIndex: Integer; AValue: Single);
var
  k: Integer;
begin
  k := ParamIndexOfVisible(AIndex);
  if k < 0 then Exit;
  if (FParams[k].Flags and kIsReadOnly) <> 0 then Exit;
  { automation calls this every block: only a changed value goes to the plug-in }
  if (k <= High(FLastSent)) and (FLastSent[k] = AValue) then Exit;
  if k <= High(FLastSent) then FLastSent[k] := AValue;
  SetParamById(FParams[k].Id, AValue);
end;

function TVST3Host.ParamCanAutomate(AIndex: Integer): Boolean;
var
  k: Integer;
begin
  k := ParamIndexOfVisible(AIndex);
  Result := (k >= 0) and ((FParams[k].Flags and kCanAutomate) <> 0) and
            ((FParams[k].Flags and kIsReadOnly) = 0);
end;

function TVST3Host.ParamSteps(AIndex: Integer): Integer;
var
  k: Integer;
begin
  k := ParamIndexOfVisible(AIndex);
  if k < 0 then Exit(0);
  Result := Max(0, FParams[k].StepCount);
end;

function TVST3Host.SetParamFromText(AIndex: Integer; const AText: string): Boolean;
var
  k: Integer;
  v: Double;
begin
  Result := False;
  k := ParamIndexOfVisible(AIndex);
  if (k < 0) or (FController = nil) then Exit;
  v := 0;
  if TFnParamFromString(VT(FController, 11))(FController, FParams[k].Id, PWideChar(AText), v) = kResultOk then
  begin
    SetParamById(FParams[k].Id, v);
    Result := True;
  end;
end;

procedure TVST3Host.AddPending(AId: Cardinal; AValue: Double; AOffset: Integer);
begin
  FParamLock.Enter;
  try
    if FPendingCount >= Length(FPending) then
    begin
      { full: drop the oldest }
      Move(FPending[1], FPending[0], (Length(FPending) - 1) * SizeOf(TPendingParam));
      Dec(FPendingCount);
    end;
    FPending[FPendingCount].Id := AId;
    FPending[FPendingCount].Value := AValue;
    FPending[FPendingCount].Offset := Max(0, AOffset);
    Inc(FPendingCount);
  finally
    FParamLock.Leave;
  end;
end;

{ ---- programs ---- }

function TVST3Host.ProgramCount: Integer;
begin
  Result := FProgCount;
end;

function TVST3Host.CurrentProgram: Integer;
begin
  if (FProgParamId = NO_PARAM) or (FProgCount < 1) then Exit(0);
  Result := Round(ControllerValue(FProgParamId) * Max(1, FProgCount - 1));
end;

procedure TVST3Host.SetProgram(AIndex: Integer);
begin
  if (FProgParamId = NO_PARAM) or (AIndex < 0) or (AIndex >= FProgCount) then Exit;
  SetParamById(FProgParamId, AIndex / Max(1, FProgCount - 1));
end;

function TVST3Host.ProgramName(AIndex: Integer): string;
var
  nm: TString128;
begin
  Result := '';
  if (FUnitInfo <> nil) and (FProgListId >= 0) then
  begin
    FillChar(nm, SizeOf(nm), 0);
    if TFnProgName(VT(FUnitInfo, 7))(FUnitInfo, FProgListId, AIndex, nm) = kResultOk then
      Result := WStr(nm);
  end;
  if Result = '' then Result := 'Program ' + IntToStr(AIndex + 1);
end;

{ ---- state ---- }

function TVST3Host.SaveStateBase64: string;
var
  so: TStreamObj;
  comp, ctrl, all: TMemoryStream;
  n: Integer;
  bytes: TBytes;
begin
  Result := '';
  if FComponent = nil then Exit;
  comp := TMemoryStream.Create;
  ctrl := TMemoryStream.Create;
  all := TMemoryStream.Create;
  try
    so.VTable := @GStreamVT;
    so.Stream := comp;
    TFnStateIO(VT(FComponent, 13))(FComponent, @so);
    if (FController <> nil) and not FCtrlIsComponent then
    begin
      so.Stream := ctrl;
      TFnStateIO(VT(FController, 7))(FController, @so);
    end;
    if (comp.Size = 0) and (ctrl.Size = 0) then Exit;
    all.WriteBuffer(STATE_MAGIC, 4);
    n := 1;                       { format version }
    all.WriteBuffer(n, 4);
    n := comp.Size;
    all.WriteBuffer(n, 4);
    if n > 0 then all.WriteBuffer(comp.Memory^, n);
    n := ctrl.Size;
    all.WriteBuffer(n, 4);
    if n > 0 then all.WriteBuffer(ctrl.Memory^, n);
    SetLength(bytes, all.Size);
    Move(all.Memory^, bytes[0], all.Size);
    Result := TNetEncoding.Base64.EncodeBytesToString(bytes);
  finally
    all.Free;
    ctrl.Free;
    comp.Free;
  end;
end;

procedure TVST3Host.LoadStateBase64(const AState: string);
var
  so: TStreamObj;
  bytes: TBytes;
  src, comp, ctrl: TMemoryStream;
  magic: array[0..3] of AnsiChar;
  ver, n: Integer;
begin
  if (FComponent = nil) or (AState = '') then Exit;
  bytes := TNetEncoding.Base64.DecodeStringToBytes(AState);
  if Length(bytes) = 0 then Exit;
  src := TMemoryStream.Create;
  comp := TMemoryStream.Create;
  ctrl := TMemoryStream.Create;
  try
    src.WriteBuffer(bytes[0], Length(bytes));
    src.Position := 0;
    if src.Size >= 16 then
    begin
      src.ReadBuffer(magic, 4);
      if CompareMem(@magic[0], @STATE_MAGIC[0], 4) then
      begin
        src.ReadBuffer(ver, 4);
        src.ReadBuffer(n, 4);
        if (n < 0) or (n > src.Size - src.Position) then Exit;
        if n > 0 then comp.CopyFrom(src, n);
        if src.Size - src.Position >= 4 then
        begin
          src.ReadBuffer(n, 4);
          if (n > 0) and (n <= src.Size - src.Position) then ctrl.CopyFrom(src, n);
        end;
      end
      else
      begin
        { a plain component state saved by an earlier version }
        src.Position := 0;
        comp.CopyFrom(src, src.Size);
      end;
    end
    else
      comp.CopyFrom(src, 0);
    so.VTable := @GStreamVT;
    comp.Position := 0;
    so.Stream := comp;
    TFnStateIO(VT(FComponent, 12))(FComponent, @so);
    if FController <> nil then
    begin
      comp.Position := 0;
      TFnStateIO(VT(FController, 5))(FController, @so);
      if (ctrl.Size > 0) and not FCtrlIsComponent then
      begin
        ctrl.Position := 0;
        so.Stream := ctrl;
        TFnStateIO(VT(FController, 6))(FController, @so);
      end;
    end;
  finally
    ctrl.Free;
    comp.Free;
    src.Free;
  end;
end;

{ ---- MIDI -> VST3 events and parameter changes ---- }

function TVST3Host.MapController(AChannel, AController: Integer): Int64;
var
  id: Cardinal;
  slot: Integer;
begin
  Result := MAP_NONE;
  if (FMidiMap = nil) or (AController < 0) or (AController >= MAP_STRIDE) then Exit;
  slot := (AChannel and 15) * MAP_STRIDE + AController;
  if FMapCache[slot] <> MAP_UNKNOWN then Exit(FMapCache[slot]);
  id := NO_PARAM;
  if TFnMidiAssign(VT(FMidiMap, 3))(FMidiMap, 0, AChannel and 15, AController, id) = kResultOk then
    FMapCache[slot] := id
  else
    FMapCache[slot] := MAP_NONE;
  Result := FMapCache[slot];
end;

procedure TVST3Host.PostMapped(AChannel, AController: Integer; AValue: Double; AOffset: Integer);
var
  m: Int64;
begin
  m := MapController(AChannel, AController);
  if m < 0 then Exit;
  if AValue < 0 then AValue := 0 else if AValue > 1 then AValue := 1;
  AddPending(Cardinal(m), AValue, AOffset);
  QueueOut(Cardinal(m), AValue);       { the controller hears about it on the UI thread }
end;

procedure TVST3Host.QueueOut(AId: Cardinal; AValue: Double);
begin
  FParamLock.Enter;
  try
    if FOutChangeCount < Length(FOutChanges) then
    begin
      FOutChanges[FOutChangeCount].Id := AId;
      FOutChanges[FOutChangeCount].Value := AValue;
      FOutChanges[FOutChangeCount].Offset := 0;
      Inc(FOutChangeCount);
    end;
  finally
    FParamLock.Leave;
  end;
end;

procedure TVST3Host.BuildInputEvents(AFrames: Integer);
var
  i, n, ch, slot: Integer;
  m: TPluginMidi;
  e: TVst3Event;
  d: Integer;
  prg: Integer;

  procedure Push;
  begin
    if FEvInCount < PLUGIN_MAX_MIDI then
    begin
      FEvIn[FEvInCount] := e;
      Inc(FEvInCount);
    end;
  end;

  procedure Init(AType: Word);
  begin
    FillChar(e, SizeOf(e), 0);
    e.BusIndex := 0;
    e.SampleOffset := d;
    e.PpqPosition := FTransport.PpqPos;
    e.Flags := kEventIsLive;
    e.EventType := AType;
  end;

  procedure NoteOffEv(AChannel, ANote, AVel: Integer);
  var
    sl: Integer;
  begin
    sl := (AChannel and 15) * 128 + (ANote and 127);
    Init(kNoteOffEvent);
    PSmallInt(@e.Data[0])^ := AChannel and 15;
    PSmallInt(@e.Data[2])^ := ANote and 127;
    PSingle(@e.Data[4])^ := AVel / 127.0;
    PInteger(@e.Data[8])^ := FNoteIds[sl];
    PSingle(@e.Data[12])^ := 0;
    FNoteIds[sl] := -1;
    Push;
  end;

begin
  FEvInCount := 0;
  n := TakeMidiIn(FMidiScratch);
  for i := 0 to n - 1 do
  begin
    m := FMidiScratch[i];
    d := Min(m.DeltaFrames, Max(0, AFrames - 1));
    ch := m.Status and $0F;
    case m.Status and $F0 of
      $90:
        if m.Data2 > 0 then
        begin
          slot := ch * 128 + m.Data1;
          if FNoteIds[slot] >= 0 then NoteOffEv(ch, m.Data1, 0);   { retrigger: end the old note }
          FNoteIds[slot] := FNextNoteId;
          Inc(FNextNoteId);
          if FNextNoteId > $3FFFFFFF then FNextNoteId := 1;
          Init(kNoteOnEvent);
          PSmallInt(@e.Data[0])^ := ch;
          PSmallInt(@e.Data[2])^ := m.Data1;
          PSingle(@e.Data[4])^ := 0;                       { tuning }
          PSingle(@e.Data[8])^ := m.Data2 / 127.0;         { velocity }
          PInteger(@e.Data[12])^ := 0;                     { length: unknown }
          PInteger(@e.Data[16])^ := FNoteIds[slot];
          Push;
        end
        else
          NoteOffEv(ch, m.Data1, 0);
      $80: NoteOffEv(ch, m.Data1, m.Data2);
      $A0:
        begin
          slot := ch * 128 + m.Data1;
          Init(kPolyPressureEvent);
          PSmallInt(@e.Data[0])^ := ch;
          PSmallInt(@e.Data[2])^ := m.Data1;
          PSingle(@e.Data[4])^ := m.Data2 / 127.0;
          PInteger(@e.Data[8])^ := FNoteIds[slot];
          Push;
        end;
      $B0:
        begin
          if (m.Data1 = 123) or (m.Data1 = 120) then
            for slot := 0 to 127 do
              if FNoteIds[ch * 128 + slot] >= 0 then NoteOffEv(ch, slot, 0);
          PostMapped(ch, m.Data1, m.Data2 / 127.0, d);
        end;
      $C0:
        begin
          if MapController(ch, kCtrlProgramChange) >= 0 then
            PostMapped(ch, kCtrlProgramChange, m.Data1 / 127.0, d)
          else if (FProgParamId <> NO_PARAM) and (m.Data1 < FProgCount) then
          begin
            prg := m.Data1;
            AddPending(FProgParamId, prg / Max(1, FProgCount - 1), d);
            QueueOut(FProgParamId, prg / Max(1, FProgCount - 1));
          end;
        end;
      $D0: PostMapped(ch, kAfterTouch, m.Data1 / 127.0, d);
      $E0: PostMapped(ch, kPitchBend, ((m.Data2 shl 7) or m.Data1) / 16383.0, d);
    end;
  end;
end;

procedure TVST3Host.BuildInputChanges;
var
  i, j, q, cnt: Integer;
  pend: array[0..511] of TPendingParam;
begin
  FInQCount := 0;
  FParamLock.Enter;
  try
    cnt := FPendingCount;
    if cnt > 0 then Move(FPending[0], pend[0], cnt * SizeOf(TPendingParam));
    FPendingCount := 0;
  finally
    FParamLock.Leave;
  end;
  for i := 0 to cnt - 1 do
  begin
    q := -1;
    for j := 0 to FInQCount - 1 do
      if FInQ[j].Id = pend[i].Id then
      begin
        q := j;
        Break;
      end;
    if q < 0 then
    begin
      if FInQCount >= Length(FInQ) then Continue;
      q := FInQCount;
      FInQ[q].Id := pend[i].Id;
      FInQ[q].Count := 0;
      Inc(FInQCount);
    end;
    if FInQ[q].Count >= Length(FInQ[q].Offsets) then
    begin
      FInQ[q].Values[FInQ[q].Count - 1] := pend[i].Value;
      FInQ[q].Offsets[FInQ[q].Count - 1] := Max(FInQ[q].Offsets[FInQ[q].Count - 1], pend[i].Offset);
    end
    else
    begin
      { offsets within a queue must not go backwards }
      if FInQ[q].Count > 0 then
        FInQ[q].Offsets[FInQ[q].Count] := Max(pend[i].Offset, FInQ[q].Offsets[FInQ[q].Count - 1])
      else
        FInQ[q].Offsets[FInQ[q].Count] := pend[i].Offset;
      FInQ[q].Values[FInQ[q].Count] := pend[i].Value;
      Inc(FInQ[q].Count);
    end;
  end;
end;

procedure TVST3Host.CollectOutputChanges;
var
  i: Integer;
begin
  { what the plug-in changed itself (meters, learned values...): the controller is told on the
    UI thread, from EditorIdle / the next GetParam }
  if FOutQCount = 0 then Exit;
  FParamLock.Enter;
  try
    for i := 0 to FOutQCount - 1 do
      if (FOutQ[i].Count > 0) and (FOutChangeCount < Length(FOutChanges)) then
      begin
        FOutChanges[FOutChangeCount].Id := FOutQ[i].Id;
        FOutChanges[FOutChangeCount].Value := FOutQ[i].Values[FOutQ[i].Count - 1];
        FOutChanges[FOutChangeCount].Offset := 0;
        Inc(FOutChangeCount);
      end;
  finally
    FParamLock.Leave;
  end;
end;

procedure TVST3Host.CollectOutputEvents;
var
  i, ch: Integer;
  ev: PVst3Event;
  cc, v1, v2: Integer;
begin
  for i := 0 to FEvOutCount - 1 do
  begin
    ev := @FEvOut[i];
    case ev^.EventType of
      kNoteOnEvent:
        begin
          ch := PSmallInt(@ev^.Data[0])^ and 15;
          PushMidiOut($90 or ch, PSmallInt(@ev^.Data[2])^ and 127,
            Max(1, Min(127, Round(PSingle(@ev^.Data[8])^ * 127))), ev^.SampleOffset);
        end;
      kNoteOffEvent:
        begin
          ch := PSmallInt(@ev^.Data[0])^ and 15;
          PushMidiOut($80 or ch, PSmallInt(@ev^.Data[2])^ and 127,
            Max(0, Min(127, Round(PSingle(@ev^.Data[4])^ * 127))), ev^.SampleOffset);
        end;
      kPolyPressureEvent:
        begin
          ch := PSmallInt(@ev^.Data[0])^ and 15;
          PushMidiOut($A0 or ch, PSmallInt(@ev^.Data[2])^ and 127,
            Max(0, Min(127, Round(PSingle(@ev^.Data[4])^ * 127))), ev^.SampleOffset);
        end;
      kLegacyMIDICCOutEvent:
        begin
          cc := ev^.Data[0];
          ch := ShortInt(ev^.Data[1]) and 15;
          v1 := ShortInt(ev^.Data[2]) and 127;
          v2 := ShortInt(ev^.Data[3]) and 127;
          if cc < 128 then PushMidiOut($B0 or ch, cc, v1, ev^.SampleOffset)
          else if cc = 128 then PushMidiOut($D0 or ch, v1, 0, ev^.SampleOffset)
          else if cc = 129 then PushMidiOut($E0 or ch, v1, v2, ev^.SampleOffset)
          else if cc = 130 then PushMidiOut($C0 or ch, v1, 0, ev^.SampleOffset);
        end;
    end;
  end;
  FEvOutCount := 0;
end;

procedure TVST3Host.FillContext(AFrames: Integer);
var
  t: Int64;
  barLen: Double;
begin
  FillChar(FCtx, SizeOf(FCtx), 0);
  QueryPerformanceCounter(t);
  FCtx.State := kSystemTimeValid or kContTimeValid or kProjectTimeMusicValid or kTempoValid or
                kBarPositionValid or kTimeSigValid or kCycleValid;
  if FTransport.Playing then FCtx.State := FCtx.State or kPlaying;
  if FTransport.Recording then FCtx.State := FCtx.State or kRecording;
  if FTransport.LoopOn then FCtx.State := FCtx.State or kCycleActive;
  FCtx.SampleRate := FSampleRate;
  FCtx.ProjectTimeSamples := FTransport.SamplePos;
  if FStopFreq > 0 then FCtx.SystemTime := Round((t - FStopStart) * 1.0e9 / FStopFreq);
  FCtx.ContinousTimeSamples := FContSamples;
  FCtx.ProjectTimeMusic := FTransport.PpqPos;
  barLen := FTransport.TimeSigNum * 4.0 / FTransport.TimeSigDen;
  FCtx.BarPositionMusic := Floor(FTransport.PpqPos / barLen) * barLen;
  FCtx.CycleStartMusic := FTransport.LoopStartPpq;
  FCtx.CycleEndMusic := FTransport.LoopEndPpq;
  FCtx.Tempo := FTransport.Tempo;
  FCtx.TimeSigNumerator := FTransport.TimeSigNum;
  FCtx.TimeSigDenominator := FTransport.TimeSigDen;
  { the host moves the position on by itself between SetTransport calls }
  if FTransport.Playing then
  begin
    FTransport.SamplePos := FTransport.SamplePos + AFrames;
    if FSampleRate > 0 then
      FTransport.PpqPos := FTransport.PpqPos + AFrames / FSampleRate * FTransport.Tempo / 60.0;
  end;
  Inc(FContSamples, AFrames);
end;

{ ---- audio ---- }

procedure TVST3Host.Process(const AIn, AOut: array of System.PSingle; AFrames: Integer);
var
  data: TProcessData;
  ch, b, j, src, n, nOutCh: Integer;
  r: Integer;
  firstSide: Integer;
begin
  if (FProcessor = nil) or (not FProcessing) or (AFrames <= 0) then Exit;
  n := AFrames;
  if n > FMaxFrames then n := FMaxFrames;

  { inputs: the main bus takes the caller's channels (the last one repeats when the plug-in has
    more input channels than the caller), the side-chain bus takes the side-chain, others silence }
  for b := 0 to FInBusCount - 1 do
    for j := 0 to FInBusCh[b] - 1 do
    begin
      ch := FInBusFirst[b] + j;
      if (not FInBusAux[b]) and (Length(AIn) > 0) then
      begin
        src := Min(j, High(AIn));
        Move(AIn[src]^, FInPtrs[ch]^, n * SizeOf(Single));
      end
      else if FInBusAux[b] and (Length(FSide) > 0) then
      begin
        firstSide := Min(j, High(FSide));
        Move(FSide[firstSide]^, FInPtrs[ch]^, n * SizeOf(Single));
      end
      else
        FillChar(FInPtrs[ch]^, n * SizeOf(Single), 0);
    end;
  for ch := 0 to FOutTotal - 1 do
    FillChar(FOutPtrs[ch]^, n * SizeOf(Single), 0);

  BuildInputEvents(n);
  BuildInputChanges;
  FOutQCount := 0;
  FEvOutCount := 0;
  FillContext(n);

  FillChar(data, SizeOf(data), 0);
  data.ProcessMode := IfThen(FOffline, 2, 0);
  data.SymbolicSampleSize := 0;
  data.NumSamples := n;
  data.NumInputs := FInBusCount;
  data.NumOutputs := FOutBusCount;
  if FInBusCount > 0 then data.Inputs := @FInBuses[0];
  if FOutBusCount > 0 then data.Outputs := @FOutBuses[0];
  data.InputParameterChanges := @FIParIn;
  data.OutputParameterChanges := @FIParOut;
  if FEventIn > 0 then data.InputEvents := @FIEvIn;
  if FEventOut > 0 then data.OutputEvents := @FIEvOut;
  data.ProcessContext := @FCtx;
  r := TFnProcess(VT(FProcessor, 9))(FProcessor, data);
  if r < 0 then
    raise EVST3Error.CreateFmt('VST3 process returned $%x', [Cardinal(r)]);

  CollectOutputChanges;
  CollectOutputEvents;

  { outputs: main bus to the caller, the last plug-in channel repeating if the caller wants more }
  if FOutBusCount > 0 then
  begin
    nOutCh := FOutBusCh[0];
    for ch := 0 to High(AOut) do
    begin
      if nOutCh > 0 then
        Move(FOutPtrs[Min(ch, nOutCh - 1)]^, AOut[ch]^, n * SizeOf(Single))
      else if ch <= High(AIn) then
        Move(AIn[ch]^, AOut[ch]^, n * SizeOf(Single));
    end;
  end;
end;

{ ---- plug-in window ---- }

function TVST3Host.HasEditor: Boolean;
var
  v: Pointer;
begin
  Result := FView <> nil;
  if Result or (FController = nil) then Exit;
  v := TFnCreateView(VT(FController, 17))(FController, PAnsiChar('editor'));
  Result := v <> nil;
  if v <> nil then ReleaseObj(v);
end;

function TVST3Host.EditorSize(out AWidth, AHeight: Integer): Boolean;
var
  r: TViewRect;
begin
  AWidth := 0;
  AHeight := 0;
  Result := False;
  if FView = nil then Exit;
  FillChar(r, SizeOf(r), 0);
  if TFnViewRect(VT(FView, 9))(FView, @r) = kResultOk then
  begin
    AWidth := r.Right - r.Left;
    AHeight := r.Bottom - r.Top;
    Result := True;
  end;
end;

function TVST3Host.OpenEditor(AParentWnd: HWND; out AWidth, AHeight: Integer): Boolean;
begin
  AWidth := 0;
  AHeight := 0;
  Result := False;
  if (FController = nil) or (FView <> nil) then Exit;
  FView := TFnCreateView(VT(FController, 17))(FController, PAnsiChar('editor'));
  if FView = nil then Exit;
  if TFnViewSupported(VT(FView, 3))(FView, PAnsiChar('HWND')) <> kResultOk then
  begin
    ReleaseObj(FView);
    Exit;
  end;
  TFnViewSetFrame(VT(FView, 12))(FView, @FIFrame);
  if not EditorSize(AWidth, AHeight) then
  begin
    AWidth := 400;
    AHeight := 300;
  end;
  if TFnViewAttached(VT(FView, 4))(FView, Pointer(NativeUInt(AParentWnd)), PAnsiChar('HWND')) <> kResultOk then
  begin
    TFnViewSetFrame(VT(FView, 12))(FView, nil);
    ReleaseObj(FView);
    Exit;
  end;
  FEditorWnd := AParentWnd;
  { some plug-ins only know their real size once attached }
  if EditorSize(AWidth, AHeight) and (AWidth > 0) and (AHeight > 0) then
  else
  begin
    AWidth := Max(AWidth, 400);
    AHeight := Max(AHeight, 300);
  end;
  Result := True;
end;

procedure TVST3Host.CloseEditor;
begin
  if FView = nil then Exit;
  TFnViewNoArg(VT(FView, 5))(FView);               { removed }
  TFnViewSetFrame(VT(FView, 12))(FView, nil);
  ReleaseObj(FView);
  FEditorWnd := 0;
end;

procedure TVST3Host.EditorIdle;
var
  i: Integer;
  ch: array of TPendingParam;
  cnt: Integer;
begin
  { VST3 plug-in windows run their own timers; what is left to do on the UI thread is telling the
    controller about values the processor changed }
  FParamLock.Enter;
  try
    cnt := FOutChangeCount;
    if cnt > 0 then
    begin
      SetLength(ch, cnt);
      Move(FOutChanges[0], ch[0], cnt * SizeOf(TPendingParam));
      FOutChangeCount := 0;
    end;
  finally
    FParamLock.Leave;
  end;
  if (FController <> nil) and (cnt > 0) then
    for i := 0 to cnt - 1 do
      TFnSetNorm(VT(FController, 15))(FController, ch[i].Id, ch[i].Value);
end;

function TVST3Host.IsEditorOpen: Boolean;
begin
  Result := FView <> nil;
end;

function TVST3Host.EditorCanResize: Boolean;
begin
  Result := (FView <> nil) and (TFnViewNoArg(VT(FView, 13))(FView) = kResultOk);
end;

procedure TVST3Host.ResizeEditor(AWidth, AHeight: Integer);
var
  r: TViewRect;
begin
  if FView = nil then Exit;
  r.Left := 0;
  r.Top := 0;
  r.Right := AWidth;
  r.Bottom := AHeight;
  TFnViewRect(VT(FView, 14))(FView, @r);           { checkSizeConstraint: adjusts r }
  TFnViewRect(VT(FView, 10))(FView, @r);           { onSize }
end;

procedure TVST3Host.DoViewResize(const ANewSize: TViewRect);
var
  r: TViewRect;
begin
  if FView = nil then Exit;
  r := ANewSize;
  if Assigned(FOnSizeWindow) then FOnSizeWindow(r.Right - r.Left, r.Bottom - r.Top);
  TFnViewRect(VT(FView, 10))(FView, @r);           { tell the view it has the size it asked for }
end;

procedure TVST3Host.FrameResize(const ARect: TViewRect);
begin
  DoViewResize(ARect);
end;

function TVST3Host.TakeRestartRequest: Boolean;
begin
  Result := FRestartFlags <> 0;
  if Result then
  begin
    FRestartFlags := 0;
    ReadParameters;
    ReadPrograms;
  end;
end;

{ ---- callbacks from the plug-in (component handler) ---- }

procedure TVST3Host.HandlerBeginEdit(AId: Cardinal);
var
  idx: Integer;
begin
  if Assigned(FOnBeginEdit) and FIdToVisible.TryGetValue(AId, idx) then FOnBeginEdit(idx);
end;

procedure TVST3Host.HandlerPerformEdit(AId: Cardinal; AValue: Double);
var
  idx: Integer;
begin
  { the plug-in's own window moved a parameter: the processor must hear about it too }
  AddPending(AId, AValue, 0);
  for idx := 0 to High(FParams) do
    if FParams[idx].Id = AId then
    begin
      if idx <= High(FLastSent) then FLastSent[idx] := AValue;
      Break;
    end;
  if Assigned(FOnAutomate) and FIdToVisible.TryGetValue(AId, idx) then FOnAutomate(idx, AValue);
end;

procedure TVST3Host.HandlerEndEdit(AId: Cardinal);
var
  idx: Integer;
begin
  if Assigned(FOnEndEdit) and FIdToVisible.TryGetValue(AId, idx) then FOnEndEdit(idx);
end;

procedure TVST3Host.HandlerRestart(AFlags: Integer);
begin
  { latency, I/O, parameter values / titles: the owner re-reads them in TakeRestartRequest }
  FRestartFlags := FRestartFlags or AFlags;
end;

end.
