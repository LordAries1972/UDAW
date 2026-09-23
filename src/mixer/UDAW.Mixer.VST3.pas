unit UDAW.Mixer.VST3;
{$I udaw.inc}
{$ALIGN 8}
{$POINTERMATH ON}

{ VST3 effect hosting, Windows.

  VST3 is a COM-style ABI: plain vtables of __stdcall function pointers with
  the IUnknown triple first. Rather than depend on Steinberg's SDK headers,
  this unit re-declares the few interfaces an effect host needs as raw
  vtable records (IPluginFactory, IComponent, IAudioProcessor, IBStream,
  IHostApplication) and drives them directly.

  Scope: load the module (plain .vst3 DLL or bundle folder), take the first
  "Audio Module Class", initialise it with a minimal IHostApplication,
  negotiate a stereo in/out bus arrangement, set up 32-bit realtime
  processing and process blocks. State save/restore goes through
  IComponent::getState/setState over a host IBStream. Not attempted here:
  the edit-controller (parameter list / automation) and the plug-in GUI
  (IPlugView); those need the separate controller object and connection
  points. }

interface

uses
  Windows, SysUtils, Classes, Math, System.NetEncoding;

type
  EVST3Error = class(Exception);

  TVST3Host = class
  private
    FModule: HMODULE;
    FFactory: Pointer;
    FComponent: Pointer;
    FProcessor: Pointer;
    FPath: string;
    FName, FVendor: string;
    FSampleRate: Integer;
    FMaxFrames: Integer;
    FChannels: Integer;
    FActive, FProcessing: Boolean;
    FScratchIn, FScratchOut: array of array of Single;
    FInPtrs, FOutPtrs: array of System.PSingle;
    function ResolveModulePath(const APath: string): string;
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
    function GetParam(AIndex: Integer): Single;
    procedure SetParam(AIndex: Integer; AValue: Single);
    function SaveStateBase64: string;
    procedure LoadStateBase64(const AState: string);
    property Path: string read FPath;
  end;

implementation

const
  IID_FUnknown: TGUID = '{00000000-0000-0000-C000-000000000046}';
  IID_IComponent: TGUID = '{E831FF31-F2D5-4301-928E-BBEE25697802}';
  IID_IAudioProcessor: TGUID = '{42043F99-B7DA-453C-A569-E79D9AAEC33D}';
  IID_IBStream: TGUID = '{C3BF6EA2-3099-4752-9B6B-F9901EE33E9B}';
  IID_IHostApplication: TGUID = '{58E595CC-DB2D-4969-8B6A-AF8C36A664E5}';

  kResultOk = 0;
  kNotImplemented = -2147467263; { 0x80004001 }
  kNoInterface = -2147467262;    { 0x80004002 }
  kSpeakerStereo = 3;            { L | R }

type
  { every VST3 object starts with a pointer to its vtable }
  PVTable = ^TVTable;
  TVTable = array[0..31] of Pointer;
  PObj = ^TObj;
  TObj = record
    VTable: PVTable;
  end;

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

  TProcessData = record
    ProcessMode: Integer;
    SymbolicSampleSize: Integer;
    NumSamples: Integer;
    NumInputs: Integer;
    NumOutputs: Integer;
    Inputs: ^TAudioBusBuffers;
    Outputs: ^TAudioBusBuffers;
    InputParameterChanges: Pointer;
    OutputParameterChanges: Pointer;
    InputEvents: Pointer;
    OutputEvents: Pointer;
    ProcessContext: Pointer;
  end;

  { ---- vtable call signatures (all __stdcall) ---- }
  TFnQuery = function(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
  TFnRef = function(Self: Pointer): Cardinal; stdcall;
  TFnFactoryInfo = function(Self: Pointer; var Info: TFactoryInfo): Integer; stdcall;
  TFnCount = function(Self: Pointer): Integer; stdcall;
  TFnClassInfo = function(Self: Pointer; Index: Integer; var Info: TClassInfo): Integer; stdcall;
  TFnCreate = function(Self: Pointer; const Cid, IID: TGUID; out Obj: Pointer): Integer; stdcall;
  TFnInit = function(Self: Pointer; Context: Pointer): Integer; stdcall;
  TFnTerm = function(Self: Pointer): Integer; stdcall;
  TFnSetActive = function(Self: Pointer; State: Byte): Integer; stdcall;
  TFnStateIO = function(Self: Pointer; Stream: Pointer): Integer; stdcall;
  TFnSetBusArr = function(Self: Pointer; Ins: PInteger; NumIns: Integer;
    Outs: PInteger; NumOuts: Integer): Integer; stdcall;
  TFnCanSize = function(Self: Pointer; Size: Integer): Integer; stdcall;
  TFnSetup = function(Self: Pointer; var Setup: TProcessSetup): Integer; stdcall;
  TFnSetProc = function(Self: Pointer; State: Byte): Integer; stdcall;
  TFnProcess = function(Self: Pointer; var Data: TProcessData): Integer; stdcall;
  TFnActivateBus = function(Self: Pointer; MediaType, Dir, Index: Integer; State: Byte): Integer; stdcall;
  TFnModEntry = function: Pointer; stdcall;
  TFnModInit = function: Byte; cdecl;

{ ---- host-side objects: IHostApplication and IBStream ---- }

var
  GHostVT: TVTable;
  GHostObj: TObj;

function HostQuery(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
begin
  if IsEqualGUID(IID, IID_FUnknown) or IsEqualGUID(IID, IID_IHostApplication) then
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

function HostAddRef(Self: Pointer): Cardinal; stdcall;
begin
  Result := 1;
end;

function HostRelease(Self: Pointer): Cardinal; stdcall;
begin
  Result := 1;
end;

function HostGetName(Self: Pointer; Name: PWideChar): Integer; stdcall;
const
  N: WideString = 'UDAW';
var
  i: Integer;
begin
  for i := 1 to Length(N) do Name[i - 1] := N[i];
  Name[Length(N)] := #0;
  Result := kResultOk;
end;

function HostCreateInstance(Self: Pointer; const Cid, IID: TGUID; out Obj: Pointer): Integer; stdcall;
begin
  Obj := nil;
  Result := kNotImplemented;
end;

type
  TStreamObj = record
    VTable: PVTable;
    Stream: TMemoryStream;
  end;
  PStreamObj = ^TStreamObj;

var
  GStreamVT: TVTable;

function StrmQuery(Self: Pointer; const IID: TGUID; out Obj: Pointer): Integer; stdcall;
begin
  if IsEqualGUID(IID, IID_FUnknown) or IsEqualGUID(IID, IID_IBStream) then
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

procedure InitHostObjects;
begin
  if GHostVT[0] <> nil then Exit;
  GHostVT[0] := @HostQuery;
  GHostVT[1] := @HostAddRef;
  GHostVT[2] := @HostRelease;
  GHostVT[3] := @HostGetName;
  GHostVT[4] := @HostCreateInstance;
  GHostObj.VTable := @GHostVT;
  GStreamVT[0] := @StrmQuery;
  GStreamVT[1] := @StrmRef;
  GStreamVT[2] := @StrmRef;
  GStreamVT[3] := @StrmRead;
  GStreamVT[4] := @StrmWrite;
  GStreamVT[5] := @StrmSeek;
  GStreamVT[6] := @StrmTell;
end;

{ ---- TVST3Host ---- }

constructor TVST3Host.Create;
begin
  inherited Create;
  FSampleRate := 44100;
  InitHostObjects;
end;

destructor TVST3Host.Destroy;
begin
  Close;
  inherited;
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

function TVST3Host.ParamCount: Integer;
begin
  Result := 0;  { parameters need the edit-controller; not hosted yet }
end;

function TVST3Host.GetParam(AIndex: Integer): Single;
begin
  Result := 0;
end;

procedure TVST3Host.SetParam(AIndex: Integer; AValue: Single);
begin
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
  fac: PObj;
  cnt, i: Integer;
  ci: TClassInfo;
  fi: TFactoryInfo;
  comp: Pointer;
  proc: Pointer;
  found: Boolean;
  r: Integer;
begin
  Close;
  FPath := APath;
  FModule := LoadLibrary(PChar(ResolveModulePath(APath)));
  if FModule = 0 then
    raise EVST3Error.CreateFmt('Cannot load VST3 module "%s" (error %d)', [APath, GetLastError]);
  @modInit := GetProcAddress(FModule, 'InitDll');
  if Assigned(modInit) then modInit;
  @entry := GetProcAddress(FModule, 'GetPluginFactory');
  if not Assigned(entry) then
    raise EVST3Error.Create('Not a VST3 plugin: missing GetPluginFactory export');
  fac := PObj(entry());
  FFactory := fac;
  if fac = nil then raise EVST3Error.Create('VST3 factory is nil');
  FillChar(fi, SizeOf(fi), 0);
  TFnFactoryInfo(fac^.VTable^[3])(fac, fi);
  FVendor := string(AnsiString(PAnsiChar(@fi.Vendor[0])));
  cnt := TFnCount(fac^.VTable^[4])(fac);
  found := False;
  for i := 0 to cnt - 1 do
  begin
    FillChar(ci, SizeOf(ci), 0);
    if TFnClassInfo(fac^.VTable^[5])(fac, i, ci) <> kResultOk then Continue;
    if SameText(string(AnsiString(PAnsiChar(@ci.Category[0]))), 'Audio Module Class') then
    begin
      FName := string(AnsiString(PAnsiChar(@ci.Name[0])));
      comp := nil;
      r := TFnCreate(fac^.VTable^[6])(fac, ci.Cid, IID_IComponent, comp);
      if (r <> kResultOk) or (comp = nil) then
        raise EVST3Error.Create('VST3 createInstance(IComponent) failed');
      FComponent := comp;
      found := True;
      Break;
    end;
  end;
  if not found then raise EVST3Error.Create('VST3 module has no Audio Module Class');
  r := TFnInit(PObj(FComponent)^.VTable^[3])(FComponent, @GHostObj);
  if r <> kResultOk then raise EVST3Error.Create('VST3 component initialize failed');
  proc := nil;
  r := TFnQuery(PObj(FComponent)^.VTable^[0])(FComponent, IID_IAudioProcessor, proc);
  if (r <> kResultOk) or (proc = nil) then
    raise EVST3Error.Create('VST3 component has no IAudioProcessor');
  FProcessor := proc;
end;

procedure TVST3Host.LoadAndOpen(const APath: string; ASampleRate, AMaxFrames, AChannels: Integer);
begin
  LoadOnly(APath);
  Configure(ASampleRate, AMaxFrames, AChannels);
end;

procedure TVST3Host.Configure(ASampleRate, AMaxFrames, AChannels: Integer);
var
  ch, r: Integer;
  arr: Integer;
  setup: TProcessSetup;
begin
  if FProcessor = nil then Exit;
  if FActive then
  begin
    TFnSetProc(PObj(FProcessor)^.VTable^[8])(FProcessor, 0);
    TFnSetActive(PObj(FComponent)^.VTable^[11])(FComponent, 0);
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
  arr := kSpeakerStereo;
  TFnSetBusArr(PObj(FProcessor)^.VTable^[3])(FProcessor, @arr, 1, @arr, 1);
  TFnActivateBus(PObj(FComponent)^.VTable^[10])(FComponent, 0, 0, 0, 1);
  TFnActivateBus(PObj(FComponent)^.VTable^[10])(FComponent, 0, 1, 0, 1);
  if TFnCanSize(PObj(FProcessor)^.VTable^[5])(FProcessor, 0) <> kResultOk then
    raise EVST3Error.Create('VST3 plugin does not support 32-bit processing');
  setup.ProcessMode := 0;          { kRealtime }
  setup.SymbolicSampleSize := 0;   { kSample32 }
  setup.MaxSamplesPerBlock := FMaxFrames;
  setup.SampleRate := FSampleRate;
  if TFnSetup(PObj(FProcessor)^.VTable^[7])(FProcessor, setup) <> kResultOk then
    raise EVST3Error.Create('VST3 setupProcessing failed');
  TFnSetActive(PObj(FComponent)^.VTable^[11])(FComponent, 1);
  FActive := True;
  r := TFnSetProc(PObj(FProcessor)^.VTable^[8])(FProcessor, 1);
  if (r = kResultOk) or (r = kNotImplemented) then FProcessing := True;
end;

procedure TVST3Host.Close;
var
  modExit: TFnModInit;
begin
  if FComponent <> nil then
  begin
    if FProcessing and (FProcessor <> nil) then
      TFnSetProc(PObj(FProcessor)^.VTable^[8])(FProcessor, 0);
    if FActive then TFnSetActive(PObj(FComponent)^.VTable^[11])(FComponent, 0);
    if FProcessor <> nil then TFnRef(PObj(FProcessor)^.VTable^[2])(FProcessor);
    TFnTerm(PObj(FComponent)^.VTable^[4])(FComponent);
    TFnRef(PObj(FComponent)^.VTable^[2])(FComponent);
  end;
  if FFactory <> nil then TFnRef(PObj(FFactory)^.VTable^[2])(FFactory);
  FProcessor := nil;
  FComponent := nil;
  FFactory := nil;
  FActive := False;
  FProcessing := False;
  if FModule <> 0 then
  begin
    @modExit := GetProcAddress(FModule, 'ExitDll');
    if Assigned(modExit) then modExit;
    FreeLibrary(FModule);
    FModule := 0;
  end;
end;

procedure TVST3Host.Reset;
begin
  if (FComponent = nil) or (not FActive) then Exit;
  { plugins reset their DSP state on an active off/on cycle }
  TFnSetActive(PObj(FComponent)^.VTable^[11])(FComponent, 0);
  TFnSetActive(PObj(FComponent)^.VTable^[11])(FComponent, 1);
end;

procedure TVST3Host.Process(const AIn, AOut: array of System.PSingle; AFrames: Integer);
var
  data: TProcessData;
  bi, bo: TAudioBusBuffers;
  ch, nc: Integer;
  r: Integer;
begin
  if (FProcessor = nil) or (not FProcessing) or (AFrames <= 0) then Exit;
  if AFrames > FMaxFrames then AFrames := FMaxFrames;
  nc := Min(Min(Length(AIn), Length(AOut)), FChannels);
  for ch := 0 to nc - 1 do
    Move(AIn[ch]^, FScratchIn[ch][0], AFrames * SizeOf(Single));
  bi.NumChannels := FChannels;
  bi.SilenceFlags := 0;
  bi.ChannelBuffers32 := @FInPtrs[0];
  bo := bi;
  bo.ChannelBuffers32 := @FOutPtrs[0];
  FillChar(data, SizeOf(data), 0);
  data.ProcessMode := 0;
  data.SymbolicSampleSize := 0;
  data.NumSamples := AFrames;
  data.NumInputs := 1;
  data.NumOutputs := 1;
  data.Inputs := @bi;
  data.Outputs := @bo;
  r := TFnProcess(PObj(FProcessor)^.VTable^[9])(FProcessor, data);
  if r <> kResultOk then
    raise EVST3Error.CreateFmt('VST3 process returned %d', [r]);
  for ch := 0 to nc - 1 do
    Move(FScratchOut[ch][0], AOut[ch]^, AFrames * SizeOf(Single));
end;

function TVST3Host.SaveStateBase64: string;
var
  so: TStreamObj;
  ms: TMemoryStream;
  bytes: TBytes;
begin
  Result := '';
  if FComponent = nil then Exit;
  ms := TMemoryStream.Create;
  try
    so.VTable := @GStreamVT;
    so.Stream := ms;
    if (TFnStateIO(PObj(FComponent)^.VTable^[13])(FComponent, @so) = kResultOk) and
       (ms.Size > 0) then
    begin
      SetLength(bytes, ms.Size);
      Move(ms.Memory^, bytes[0], ms.Size);
      Result := TNetEncoding.Base64.EncodeBytesToString(bytes);
    end;
  finally
    ms.Free;
  end;
end;

procedure TVST3Host.LoadStateBase64(const AState: string);
var
  so: TStreamObj;
  ms: TMemoryStream;
  bytes: TBytes;
begin
  if (FComponent = nil) or (AState = '') then Exit;
  bytes := TNetEncoding.Base64.DecodeStringToBytes(AState);
  if Length(bytes) = 0 then Exit;
  ms := TMemoryStream.Create;
  try
    ms.WriteBuffer(bytes[0], Length(bytes));
    ms.Position := 0;
    so.VTable := @GStreamVT;
    so.Stream := ms;
    TFnStateIO(PObj(FComponent)^.VTable^[12])(FComponent, @so);
  finally
    ms.Free;
  end;
end;

end.
