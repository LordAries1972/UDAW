unit UDAW.Mixer.PluginHost;
{$I udaw.inc}

{ The common face of a hosted plug-in, whatever its format.  TVST2Host (UDAW.Mixer.VST2) and
  TVST3Host (UDAW.Mixer.VST3) both descend from TPluginHostBase, so the mixer nodes, the
  plug-in editor window, the scanner and the timeline range renderer can drive either format
  through one set of calls:

    * audio in / out, bypass, latency, tail
    * MIDI in (note, controller, pitch bend, program, pressure) and MIDI out
    * transport (tempo, beat position, bar, loop) for tempo-synced plug-ins
    * parameters by index, with names, units, display text and text entry
    * programs / presets
    * state save / restore
    * the plug-in's own editor window, with resize / edit callbacks
    * extra output channels (multi-output instruments) and an optional side-chain input

  MIDI that arrives from any thread is queued here (TPluginHostBase.SendMidi); the format
  host drains the queue at the start of each block (TakeMidiIn) and converts it to its own
  event type.  MIDI the plug-in sends out is queued by the format host (PushMidiOut) and read
  with PopMidiOut. }

interface

uses
  Windows, SysUtils, Classes, Math, SyncObjs;

const
  PLUGIN_MAX_MIDI = 2048;       // queued MIDI messages per block, each direction

type
  { one MIDI message with its position inside the block (in or out) }
  TPluginMidi = record
    Status, Data1, Data2: Byte;
    DeltaFrames: Integer;
  end;
  TPluginMidiArray = array of TPluginMidi;

  { what the host tells tempo-synced plug-ins about the transport }
  TPluginTransport = record
    Playing, Recording, LoopOn: Boolean;
    Tempo: Double;              // BPM
    PpqPos: Double;             // position in quarter notes
    SamplePos: Int64;
    TimeSigNum, TimeSigDen: Integer;
    LoopStartPpq, LoopEndPpq: Double;
    class function Make(APlaying: Boolean; ATempo, APpqPos: Double): TPluginTransport; static;
  end;

  TPluginSizeEvent = procedure(AWidth, AHeight: Integer) of object;
  TPluginAutomateEvent = procedure(AIndex: Integer; AValue: Single) of object;
  TPluginEditEvent = procedure(AIndex: Integer) of object;

  { a program (preset) of the plug-in }
  TPluginProgramInfo = record
    Index: Integer;
    Name: string;
  end;

  EPluginHostError = class(Exception);

  TPluginHostBase = class
  private
    FInLock, FOutLock: TCriticalSection;
    FMidiIn: array[0..PLUGIN_MAX_MIDI - 1] of TPluginMidi;
    FMidiInCount: Integer;
    FMidiOut: array[0..PLUGIN_MAX_MIDI - 1] of TPluginMidi;
    FMidiOutCount: Integer;
  protected
    FPath: string;
    FSampleRate: Integer;
    FTransport: TPluginTransport;
    FRequireEffect: Boolean;
    FOnSizeWindow: TPluginSizeEvent;
    FOnAutomate: TPluginAutomateEvent;
    FOnBeginEdit, FOnEndEdit: TPluginEditEvent;
    { moves up to ACap queued input messages into ADest, oldest first; returns the count }
    function TakeMidiIn(var ADest: array of TPluginMidi): Integer;
    procedure ClearMidiIn;
    { for the format host: a message the plug-in sent out }
    procedure PushMidiOut(AStatus, AData1, AData2: Byte; ADeltaFrames: Integer);
  public
    constructor Create;
    destructor Destroy; override;

    { ---- loading ---- }
    procedure LoadOnly(const APath: string); virtual; abstract;
    procedure LoadAndOpen(const APath: string; ASampleRate, AMaxFrames, AChannels: Integer); virtual; abstract;
    procedure Configure(ASampleRate, AMaxFrames, AChannels: Integer); virtual; abstract;
    procedure Close; virtual; abstract;
    function IsLoaded: Boolean; virtual; abstract;
    function FormatName: string; virtual; abstract;        // 'VST2' / 'VST3'
    { True (the default): LoadOnly refuses instruments and plug-ins without audio inputs, so
      an effect picker never offers them.  Set False before LoadOnly to host an instrument. }
    property RequireEffect: Boolean read FRequireEffect write FRequireEffect;

    { ---- audio ---- }
    procedure Process(const AIn, AOut: array of System.PSingle; AFrames: Integer); virtual; abstract;
    procedure Reset; virtual; abstract;
    procedure SetBypass(ABypass: Boolean); virtual; abstract;
    function SupportsBypass: Boolean; virtual; abstract;
    function LatencySamples: Integer; virtual; abstract;
    function TailSamples: Integer; virtual; abstract;     // 0 unknown, 1 none, else samples
    function NumInputs: Integer; virtual; abstract;       // audio input channels (all buses)
    function NumOutputs: Integer; virtual; abstract;      // audio output channels (all buses)
    { After Process: the plug-in's output channel ACh counted across all output buses (so a
      multi-output instrument can be routed to several mixer channels); nil when out of range. }
    function OutputChannel(ACh: Integer): System.PSingle; virtual; abstract;
    { A side-chain input for the next Process calls (nil clears it).  AChannels pointers, each
      with at least the block's frames; they must stay valid until cleared. }
    procedure SetSidechain(const AChannels: array of System.PSingle); virtual;

    { ---- identity ---- }
    function EffectName: string; virtual; abstract;
    function VendorString: string; virtual; abstract;
    function IsSynth: Boolean; virtual; abstract;
    { True when the plug-in takes MIDI (instrument, or an effect with an event input) }
    function WantsMidi: Boolean; virtual; abstract;
    function SubCategories: string; virtual;

    { ---- MIDI ---- }
    { thread-safe; delta frames are inside the NEXT block }
    procedure SendMidi(AStatus, AData1, AData2: Byte; ADeltaFrames: Integer = 0);
    procedure NoteOn(AChannel, ANote, AVelocity: Integer; ADeltaFrames: Integer = 0);
    procedure NoteOff(AChannel, ANote: Integer; AVelocity: Integer = 0; ADeltaFrames: Integer = 0);
    procedure ControlChange(AChannel, AController, AValue: Integer);
    procedure PitchBend(AChannel, AValue14: Integer);        // 0..16383, 8192 = centre
    procedure ChannelPressure(AChannel, AValue: Integer);
    procedure PolyPressure(AChannel, ANote, AValue: Integer);
    procedure ProgramChange(AChannel, AProgram: Integer);
    procedure AllNotesOff;
    { drains the MIDI the plug-in sent out since the last call; returns the count copied }
    function PopMidiOut(var ABuf: array of TPluginMidi): Integer;

    { ---- transport ---- }
    procedure SetTransport(const ATransport: TPluginTransport); virtual;

    { ---- parameters (by index; values 0..1) ---- }
    function ParamCount: Integer; virtual; abstract;
    function ParamName(AIndex: Integer): string; virtual; abstract;
    function ParamLabel(AIndex: Integer): string; virtual; abstract;     // unit text
    function ParamDisplay(AIndex: Integer): string; virtual; abstract;   // value as text
    function GetParam(AIndex: Integer): Single; virtual; abstract;
    procedure SetParam(AIndex: Integer; AValue: Single); virtual; abstract;
    function ParamCanAutomate(AIndex: Integer): Boolean; virtual; abstract;
    function ParamIsSwitch(AIndex: Integer): Boolean; virtual;
    { number of discrete steps (0 = continuous) }
    function ParamSteps(AIndex: Integer): Integer; virtual;
    function SetParamFromText(AIndex: Integer; const AText: string): Boolean; virtual; abstract;

    { ---- programs ---- }
    function ProgramCount: Integer; virtual; abstract;
    function CurrentProgram: Integer; virtual; abstract;
    procedure SetProgram(AIndex: Integer); virtual; abstract;
    function ProgramName(AIndex: Integer): string; virtual; abstract;

    { ---- state ---- }
    function SaveStateBase64: string; virtual; abstract;
    procedure LoadStateBase64(const AState: string); virtual; abstract;

    { ---- editor ---- }
    function HasEditor: Boolean; virtual; abstract;
    function OpenEditor(AParentWnd: HWND; out AWidth, AHeight: Integer): Boolean; virtual; abstract;
    procedure CloseEditor; virtual; abstract;
    procedure EditorIdle; virtual; abstract;
    function EditorSize(out AWidth, AHeight: Integer): Boolean; virtual; abstract;
    function IsEditorOpen: Boolean; virtual; abstract;
    { the host tells the plug-in the window has been resized }
    procedure ResizeEditor(AWidth, AHeight: Integer); virtual;
    function EditorCanResize: Boolean; virtual;
    { True once after the plug-in said its I/O layout, latency or parameter list changed }
    function TakeRestartRequest: Boolean; virtual;

    property Path: string read FPath;
    property SampleRate: Integer read FSampleRate;
    property OnSizeWindow: TPluginSizeEvent read FOnSizeWindow write FOnSizeWindow;
    property OnAutomate: TPluginAutomateEvent read FOnAutomate write FOnAutomate;
    property OnBeginEdit: TPluginEditEvent read FOnBeginEdit write FOnBeginEdit;
    property OnEndEdit: TPluginEditEvent read FOnEndEdit write FOnEndEdit;
  end;

implementation

class function TPluginTransport.Make(APlaying: Boolean; ATempo, APpqPos: Double): TPluginTransport;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Playing := APlaying;
  Result.Tempo := IfThen(ATempo >= 1, ATempo, 120);
  Result.PpqPos := APpqPos;
  Result.TimeSigNum := 4;
  Result.TimeSigDen := 4;
end;

constructor TPluginHostBase.Create;
begin
  inherited Create;
  FInLock := TCriticalSection.Create;
  FOutLock := TCriticalSection.Create;
  FRequireEffect := True;
  FSampleRate := 44100;
  FTransport := TPluginTransport.Make(False, 120, 0);
end;

destructor TPluginHostBase.Destroy;
begin
  FInLock.Free;
  FOutLock.Free;
  inherited Destroy;
end;

function TPluginHostBase.TakeMidiIn(var ADest: array of TPluginMidi): Integer;
var
  n: Integer;
begin
  FInLock.Enter;
  try
    n := Min(FMidiInCount, Length(ADest));
    if n > 0 then
    begin
      Move(FMidiIn[0], ADest[0], n * SizeOf(TPluginMidi));
      if n < FMidiInCount then
        Move(FMidiIn[n], FMidiIn[0], (FMidiInCount - n) * SizeOf(TPluginMidi));
    end;
    Dec(FMidiInCount, n);
    Result := n;
  finally
    FInLock.Leave;
  end;
end;

procedure TPluginHostBase.ClearMidiIn;
begin
  FInLock.Enter;
  try
    FMidiInCount := 0;
  finally
    FInLock.Leave;
  end;
end;

procedure TPluginHostBase.PushMidiOut(AStatus, AData1, AData2: Byte; ADeltaFrames: Integer);
begin
  FOutLock.Enter;
  try
    if FMidiOutCount >= PLUGIN_MAX_MIDI then Exit;
    FMidiOut[FMidiOutCount].Status := AStatus;
    FMidiOut[FMidiOutCount].Data1 := AData1;
    FMidiOut[FMidiOutCount].Data2 := AData2;
    FMidiOut[FMidiOutCount].DeltaFrames := ADeltaFrames;
    Inc(FMidiOutCount);
  finally
    FOutLock.Leave;
  end;
end;

procedure TPluginHostBase.SendMidi(AStatus, AData1, AData2: Byte; ADeltaFrames: Integer);
begin
  if not IsLoaded then Exit;
  FInLock.Enter;
  try
    if FMidiInCount >= PLUGIN_MAX_MIDI then Exit;
    FMidiIn[FMidiInCount].Status := AStatus;
    FMidiIn[FMidiInCount].Data1 := AData1 and $7F;
    FMidiIn[FMidiInCount].Data2 := AData2 and $7F;
    FMidiIn[FMidiInCount].DeltaFrames := Max(0, ADeltaFrames);
    Inc(FMidiInCount);
  finally
    FInLock.Leave;
  end;
end;

procedure TPluginHostBase.NoteOn(AChannel, ANote, AVelocity, ADeltaFrames: Integer);
begin
  SendMidi($90 or (AChannel and $0F), ANote and $7F, Max(1, Min(127, AVelocity)), ADeltaFrames);
end;

procedure TPluginHostBase.NoteOff(AChannel, ANote, AVelocity, ADeltaFrames: Integer);
begin
  SendMidi($80 or (AChannel and $0F), ANote and $7F, Max(0, Min(127, AVelocity)), ADeltaFrames);
end;

procedure TPluginHostBase.ControlChange(AChannel, AController, AValue: Integer);
begin
  SendMidi($B0 or (AChannel and $0F), AController and $7F, Max(0, Min(127, AValue)));
end;

procedure TPluginHostBase.PitchBend(AChannel, AValue14: Integer);
begin
  AValue14 := Max(0, Min(16383, AValue14));
  SendMidi($E0 or (AChannel and $0F), AValue14 and $7F, AValue14 shr 7);
end;

procedure TPluginHostBase.ChannelPressure(AChannel, AValue: Integer);
begin
  SendMidi($D0 or (AChannel and $0F), Max(0, Min(127, AValue)), 0);
end;

procedure TPluginHostBase.PolyPressure(AChannel, ANote, AValue: Integer);
begin
  SendMidi($A0 or (AChannel and $0F), ANote and $7F, Max(0, Min(127, AValue)));
end;

procedure TPluginHostBase.ProgramChange(AChannel, AProgram: Integer);
begin
  SendMidi($C0 or (AChannel and $0F), AProgram and $7F, 0);
end;

procedure TPluginHostBase.AllNotesOff;
var
  ch: Integer;
begin
  for ch := 0 to 15 do
  begin
    ControlChange(ch, 123, 0);   { all notes off }
    ControlChange(ch, 120, 0);   { all sound off }
  end;
end;

function TPluginHostBase.PopMidiOut(var ABuf: array of TPluginMidi): Integer;
var
  n: Integer;
begin
  FOutLock.Enter;
  try
    n := Min(FMidiOutCount, Length(ABuf));
    if n > 0 then
    begin
      Move(FMidiOut[0], ABuf[0], n * SizeOf(TPluginMidi));
      if n < FMidiOutCount then
        Move(FMidiOut[n], FMidiOut[0], (FMidiOutCount - n) * SizeOf(TPluginMidi));
    end;
    Dec(FMidiOutCount, n);
    Result := n;
  finally
    FOutLock.Leave;
  end;
end;

procedure TPluginHostBase.SetTransport(const ATransport: TPluginTransport);
begin
  FTransport := ATransport;
  if FTransport.Tempo < 1 then FTransport.Tempo := 120;
  if FTransport.TimeSigNum < 1 then FTransport.TimeSigNum := 4;
  if FTransport.TimeSigDen < 1 then FTransport.TimeSigDen := 4;
end;

procedure TPluginHostBase.SetSidechain(const AChannels: array of System.PSingle);
begin
  { formats without a side-chain input ignore it }
end;

function TPluginHostBase.SubCategories: string;
begin
  Result := '';
end;

function TPluginHostBase.ParamIsSwitch(AIndex: Integer): Boolean;
begin
  Result := ParamSteps(AIndex) = 1;
end;

function TPluginHostBase.ParamSteps(AIndex: Integer): Integer;
begin
  Result := 0;
end;

procedure TPluginHostBase.ResizeEditor(AWidth, AHeight: Integer);
begin
end;

function TPluginHostBase.EditorCanResize: Boolean;
begin
  Result := False;
end;

function TPluginHostBase.TakeRestartRequest: Boolean;
begin
  Result := False;
end;

end.
