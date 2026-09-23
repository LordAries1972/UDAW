unit UDAW.Mixer.Model;
{$I udaw.inc}

{ Phase 9 - Mixer: the in-memory mixer model (plan section 10).

  TMixerModel owns an ordered list of TMixStrip. A strip is one professional
  channel strip: an input selector, trim gain, polarity invert, an ordered
  insert chain (each insert is one Phase 3/4 DSP processor hosted by kind +
  parameter string), pre/post-fader sends into buses, constant-power pan,
  stereo width, fader, mute, solo, record-arm, an automation-mode flag, an
  output selector (which bus / the master it feeds) and an optional VCA group
  assignment. Every strip carries live meter scalars the engine writes and the
  UI reads.

  The model has no GUI or audio-engine dependency: UDAW.Mixer.Engine consumes
  it to render, UDAW.Mixer.Serialization round-trips it inside the project file,
  and UDAW.Mixer.Commands mutates it undoably. Exactly one strip is the master
  (skMaster); every other strip's OutputTargetId must resolve to a bus / aux /
  master, and neither the output graph nor the send graph may contain a cycle -
  ValidateRouting rejects both (plan section 6: illegal feedback / circular
  dependency / invalid bus routing). }

interface

uses
  SysUtils, Classes, Math, StrUtils, Generics.Collections,
  UDAW.Errors, UDAW.Mixer.Automation, UDAW.Mixer.Modulation;

const
  MIXER_SUBSYS = 'Mixer';

  MIX_MIN_DB = -120.0;   { fader / send / trim floor treated as -inf }
  MIX_MAX_DB =  24.0;
  MIX_TRIM_MIN_DB = -48.0;
  MIX_TRIM_MAX_DB =  48.0;
  MIX_WIDTH_MIN = 0.0;
  MIX_WIDTH_MAX = 2.0;
  MIX_METER_HOLD_MS_DEFAULT = 1500.0;
  MIX_METER_HOLD_DECAY_DEFAULT = 10.0;

type
  TMixStripKind = (
    skInput,       // a hardware / capture input channel
    skAudioTrack,  // fed by one timeline audio track
    skBus,         // sub-mix summing point
    skAux,         // effects-return / auxiliary send bus
    skVCA,         // control-group master (no audio; scales members' faders)
    skMaster       // the single final output strip
  );

  TMixSendMode = (smPreFader, smPostFader);

  TMixAutomationMode = (amOff, amRead, amTouch, amLatch, amWrite);

  { One hosted insert processor: a node-kind id understood by
    UDAW.Audio.Graph.Nodes.CreateNode plus its "key=value;..." parameter
    string. SidechainStripId (0 = none) keys a dynamics insert off another
    strip's post-fader signal. Value type - copied freely. }
  TMixInsert = record
    Kind: string;
    Params: string;
    Bypass: Boolean;
    SidechainStripId: Integer;
    class function Make(const AKind, AParams: string; ABypass: Boolean = False;
      ASidechainStripId: Integer = 0): TMixInsert; static;
  end;

  TMixSend = class
  private
    FTargetStripId: Integer;
    FGainDb: Double;
    FMode: TMixSendMode;
    FEnabled: Boolean;
  public
    constructor Create(ATargetStripId: Integer; AGainDb: Double;
      AMode: TMixSendMode; AEnabled: Boolean = True);
    function Clone: TMixSend;
    property TargetStripId: Integer read FTargetStripId write FTargetStripId;
    property GainDb: Double read FGainDb write FGainDb;
    property Mode: TMixSendMode read FMode write FMode;
    property Enabled: Boolean read FEnabled write FEnabled;
  end;

  TMixStrip = class
  private
    FId: Integer;
    FKind: TMixStripKind;
    FName: string;
    FInputSourceId: Integer;      // timeline track id / hardware channel index; 0 = none
    FTrimGainDb: Double;
    FPolarityInvert: Boolean;
    FInserts: TList<TMixInsert>;
    FSends: TObjectList<TMixSend>;
    FPan: Double;                 // -1..+1
    FStereoWidth: Double;         // 0 = mono .. 1 = as-is .. 2 = extra wide
    FFaderDb: Double;
    FMuted: Boolean;
    FSoloed: Boolean;
    FRecordArmed: Boolean;
    FAutomationMode: TMixAutomationMode;
    FOutputTargetId: Integer;     // strip id of the bus/aux/master this feeds; 0 for master
    FVCAGroupId: Integer;         // id of a skVCA strip, or 0
    FColor: Integer;
    { live meter scalars: written by the RT mix thread, read by the UI thread.
      Plain scalar reads/writes are atomic on every architecture UDAW targets
      and a torn value on a moving meter is harmless (same convention as
      TMeterNode in the audio graph). }
    FMeterPeakDbL: Double;
    FMeterPeakDbR: Double;
    FMeterRmsDb: Double;
    FMeterLufs: Double;
    FMeterLufsIntegrated: Double;
    FMeterHoldDbL: Double;
    FMeterHoldDbR: Double;
    FClipL: Boolean;
    FClipR: Boolean;
    procedure SetTrimGainDb(AValue: Double);
    procedure SetPan(AValue: Double);
    procedure SetStereoWidth(AValue: Double);
    procedure SetFaderDb(AValue: Double);
  public
    constructor Create(AId: Integer; AKind: TMixStripKind; const AName: string);
    destructor Destroy; override;
    procedure Assign(ASrc: TMixStrip);
    function Clone: TMixStrip;

    function IsAudioStrip: Boolean;     // produces / carries audio (everything but skVCA)
    function AcceptsBusInput: Boolean;  // can be an OutputTargetId / send target

    { ---- inserts ---- }
    function InsertCount: Integer;
    function GetInsert(AIndex: Integer): TMixInsert;
    procedure SetInsert(AIndex: Integer; const AInsert: TMixInsert);
    function AddInsert(const AInsert: TMixInsert): Integer;
    procedure InsertInsertAt(AIndex: Integer; const AInsert: TMixInsert);
    procedure DeleteInsert(AIndex: Integer);
    procedure MoveInsert(AFromIndex, AToIndex: Integer);

    { ---- sends ---- }
    function SendCount: Integer;
    function GetSend(AIndex: Integer): TMixSend;
    function SendToStrip(ATargetStripId: Integer): TMixSend;
    function AddSend(ATargetStripId: Integer; AGainDb: Double;
      AMode: TMixSendMode; AEnabled: Boolean = True): TMixSend;
    procedure RemoveSend(ATargetStripId: Integer);

    procedure ResetMeters;
    { Click-to-reset for the latching clip LEDs the Mixer tab paints; the
      engine only ever sets FClipL/FClipR True (see TMixerProcessor.ProcessStrip). }
    procedure ResetClip;

    property Id: Integer read FId;
    property Kind: TMixStripKind read FKind write FKind;
    property Name: string read FName write FName;
    property InputSourceId: Integer read FInputSourceId write FInputSourceId;
    property TrimGainDb: Double read FTrimGainDb write SetTrimGainDb;
    property PolarityInvert: Boolean read FPolarityInvert write FPolarityInvert;
    property Pan: Double read FPan write SetPan;
    property StereoWidth: Double read FStereoWidth write SetStereoWidth;
    property FaderDb: Double read FFaderDb write SetFaderDb;
    property Muted: Boolean read FMuted write FMuted;
    property Soloed: Boolean read FSoloed write FSoloed;
    property RecordArmed: Boolean read FRecordArmed write FRecordArmed;
    property AutomationMode: TMixAutomationMode read FAutomationMode write FAutomationMode;
    property OutputTargetId: Integer read FOutputTargetId write FOutputTargetId;
    property VCAGroupId: Integer read FVCAGroupId write FVCAGroupId;
    property Color: Integer read FColor write FColor;

    property MeterPeakDbL: Double read FMeterPeakDbL write FMeterPeakDbL;
    property MeterPeakDbR: Double read FMeterPeakDbR write FMeterPeakDbR;
    property MeterRmsDb: Double read FMeterRmsDb write FMeterRmsDb;
    property MeterLufs: Double read FMeterLufs write FMeterLufs;
    { Integrated (gated, whole-programme) LUFS - see UDAW.DSP.Meter.TLoudnessMeter.
      Only meaningful once transport has run long enough to close a gating
      block; reads METER_MIN_DB until then. Shown prominently for the master
      strip (Mixer tab's loudness readout). }
    property MeterLufsIntegrated: Double read FMeterLufsIntegrated write FMeterLufsIntegrated;
    { Peak-hold value (dB), decaying per UDAW.DSP.Meter.TPeakMeter.HoldDb. }
    property MeterHoldDbL: Double read FMeterHoldDbL write FMeterHoldDbL;
    property MeterHoldDbR: Double read FMeterHoldDbR write FMeterHoldDbR;
    { Latching 0 dBFS indicators, set by the engine and cleared only by
      ResetClip (a click on the LED in the Mixer tab). }
    property ClipL: Boolean read FClipL write FClipL;
    property ClipR: Boolean read FClipR write FClipR;
  end;

  TMixerModel = class
  private
    FStrips: TObjectList<TMixStrip>;
    FNextId: Integer;
    FAutomation: TAutomationSet;
    FModulation: TModulationSet;
    FMeterHoldMs: Double;
    FMeterHoldDecayDbPerSec: Double;
    procedure SetMeterHoldMs(AValue: Double);
    procedure SetMeterHoldDecayDbPerSec(AValue: Double);
    function IndexOfStrip(AId: Integer): Integer;
    function HasRoutingCycle(out AWhere: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Clone: TMixerModel;

    { Breakpoint automation for strip, send and insert parameters. Owned;
      always non-nil. }
    property Automation: TAutomationSet read FAutomation;
    property Modulation: TModulationSet read FModulation;
    property MeterHoldMs: Double read FMeterHoldMs write SetMeterHoldMs;
    property MeterHoldDecayDbPerSec: Double read FMeterHoldDecayDbPerSec
      write SetMeterHoldDecayDbPerSec;

    { A fresh mixer for a new project: one master strip. }
    procedure InitDefault;
    { Guarantees exactly one master strip exists (used by the deserializer for
      pre-Phase-9 project files that carry no MIXER section). }
    function EnsureMaster: TMixStrip;

    procedure BumpNextId(AObservedId: Integer);
    property NextId: Integer read FNextId write FNextId;

    function AddStrip(AKind: TMixStripKind; const AName: string): TMixStrip;
    function AddStripWithId(AId: Integer; AKind: TMixStripKind; const AName: string): TMixStrip;
    procedure RemoveStrip(AId: Integer);
    procedure MoveStrip(AId, ANewIndex: Integer);
    function StripById(AId: Integer): TMixStrip;
    function StripCount: Integer;
    function GetStrip(AIndex: Integer): TMixStrip;
    function MasterStrip: TMixStrip;
    function MasterCount: Integer;
    function SourceHasEffects(ASourceId: Integer): Boolean;
    { List index of a strip by id / of the master strip, or -1. (The engine's
      topological sort works in list-index space.) }
    function IndexOfStripId(AId: Integer): Integer;
    function IndexOfMaster: Integer;

    { True when any audio strip is soloed - then every non-soloed, non-master
      audio strip is silenced. }
    function AnySolo: Boolean;
    { 0.0 or 1.0: the mute/solo gate applied to this strip's fader. }
    function GateGain(AStrip: TMixStrip): Double;
    { Sum (in dB) of the VCA-group fader(s) this strip is chained under. A VCA
      group can itself be a member of another VCA group; the walk is depth
      limited so a malformed chain cannot loop forever. }
    function VCATrimDb(AStrip: TMixStrip): Double;

    { Routing is valid when: exactly one master; every strip's OutputTargetId
      is 0 (master only) or resolves to a bus/aux/master that is not itself;
      every send targets an existing bus/aux/master; and neither the output
      graph nor the send graph contains a cycle. }
    function ValidateRouting(out AError: string): Boolean;

    function Describe: string;
  end;

function MixStripKindId(AKind: TMixStripKind): string;
function MixStripKindFromId(const AId: string; out AKind: TMixStripKind): Boolean;
function MixStripKindDisplay(AKind: TMixStripKind): string;
function MixSendModeId(AMode: TMixSendMode): string;
function MixSendModeFromId(const AId: string; out AMode: TMixSendMode): Boolean;
function MixAutomationModeId(AMode: TMixAutomationMode): string;
function MixAutomationModeFromId(const AId: string; out AMode: TMixAutomationMode): Boolean;

function ClampDb(AValue, ALo, AHi: Double): Double;

implementation

const
  VCA_MAX_DEPTH = 16;

function ClampDb(AValue, ALo, AHi: Double): Double;
begin
  if IsNan(AValue) then Exit(0.0);
  if AValue < ALo then Result := ALo
  else if AValue > AHi then Result := AHi
  else Result := AValue;
end;

{ ---------------- name maps ---------------- }

function MixStripKindId(AKind: TMixStripKind): string;
begin
  case AKind of
    skInput:      Result := 'input';
    skAudioTrack: Result := 'audiotrack';
    skBus:        Result := 'bus';
    skAux:        Result := 'aux';
    skVCA:        Result := 'vca';
    skMaster:     Result := 'master';
  else
    Result := '?';
  end;
end;

function MixStripKindFromId(const AId: string; out AKind: TMixStripKind): Boolean;
var
  k: TMixStripKind;
begin
  for k := Low(TMixStripKind) to High(TMixStripKind) do
    if SameText(AId, MixStripKindId(k)) then
    begin
      AKind := k;
      Exit(True);
    end;
  Result := False;
end;

function MixStripKindDisplay(AKind: TMixStripKind): string;
begin
  case AKind of
    skInput:      Result := 'Input';
    skAudioTrack: Result := 'Audio';
    skBus:        Result := 'Bus';
    skAux:        Result := 'Aux';
    skVCA:        Result := 'VCA';
    skMaster:     Result := 'Master';
  else
    Result := '?';
  end;
end;

function MixSendModeId(AMode: TMixSendMode): string;
begin
  if AMode = smPreFader then Result := 'pre' else Result := 'post';
end;

function MixSendModeFromId(const AId: string; out AMode: TMixSendMode): Boolean;
begin
  Result := True;
  if SameText(AId, 'pre') then AMode := smPreFader
  else if SameText(AId, 'post') then AMode := smPostFader
  else Result := False;
end;

function MixAutomationModeId(AMode: TMixAutomationMode): string;
begin
  case AMode of
    amRead:  Result := 'read';
    amTouch: Result := 'touch';
    amLatch: Result := 'latch';
    amWrite: Result := 'write';
  else
    Result := 'off';
  end;
end;

function MixAutomationModeFromId(const AId: string; out AMode: TMixAutomationMode): Boolean;
var
  m: TMixAutomationMode;
begin
  for m := Low(TMixAutomationMode) to High(TMixAutomationMode) do
    if SameText(AId, MixAutomationModeId(m)) then
    begin
      AMode := m;
      Exit(True);
    end;
  Result := False;
end;

{ ================= TMixInsert ================= }

class function TMixInsert.Make(const AKind, AParams: string; ABypass: Boolean;
  ASidechainStripId: Integer): TMixInsert;
begin
  Result.Kind := AKind;
  Result.Params := AParams;
  Result.Bypass := ABypass;
  Result.SidechainStripId := ASidechainStripId;
end;

{ ================= TMixSend ================= }

constructor TMixSend.Create(ATargetStripId: Integer; AGainDb: Double;
  AMode: TMixSendMode; AEnabled: Boolean);
begin
  inherited Create;
  FTargetStripId := ATargetStripId;
  FGainDb := ClampDb(AGainDb, MIX_MIN_DB, MIX_MAX_DB);
  FMode := AMode;
  FEnabled := AEnabled;
end;

function TMixSend.Clone: TMixSend;
begin
  Result := TMixSend.Create(FTargetStripId, FGainDb, FMode, FEnabled);
end;

{ ================= TMixStrip ================= }

constructor TMixStrip.Create(AId: Integer; AKind: TMixStripKind; const AName: string);
begin
  inherited Create;
  FId := AId;
  FKind := AKind;
  if AName <> '' then FName := AName else FName := MixStripKindDisplay(AKind);
  FInserts := TList<TMixInsert>.Create;
  FSends := TObjectList<TMixSend>.Create(True);
  FTrimGainDb := 0.0;
  FPan := 0.0;
  FStereoWidth := 1.0;
  FFaderDb := 0.0;
  FAutomationMode := amOff;
  FOutputTargetId := 0;
  ResetMeters;
end;

destructor TMixStrip.Destroy;
begin
  FSends.Free;
  FInserts.Free;
  inherited Destroy;
end;

procedure TMixStrip.Assign(ASrc: TMixStrip);
var
  i: Integer;
begin
  FKind := ASrc.FKind;
  FName := ASrc.FName;
  FInputSourceId := ASrc.FInputSourceId;
  FTrimGainDb := ASrc.FTrimGainDb;
  FPolarityInvert := ASrc.FPolarityInvert;
  FPan := ASrc.FPan;
  FStereoWidth := ASrc.FStereoWidth;
  FFaderDb := ASrc.FFaderDb;
  FMuted := ASrc.FMuted;
  FSoloed := ASrc.FSoloed;
  FRecordArmed := ASrc.FRecordArmed;
  FAutomationMode := ASrc.FAutomationMode;
  FOutputTargetId := ASrc.FOutputTargetId;
  FVCAGroupId := ASrc.FVCAGroupId;
  FColor := ASrc.FColor;
  FInserts.Clear;
  for i := 0 to ASrc.FInserts.Count - 1 do
    FInserts.Add(ASrc.FInserts[i]);
  FSends.Clear;
  for i := 0 to ASrc.FSends.Count - 1 do
    FSends.Add(ASrc.FSends[i].Clone);
end;

function TMixStrip.Clone: TMixStrip;
begin
  Result := TMixStrip.Create(FId, FKind, FName);
  Result.Assign(Self);
end;

function TMixStrip.IsAudioStrip: Boolean;
begin
  Result := FKind <> skVCA;
end;

function TMixStrip.AcceptsBusInput: Boolean;
begin
  Result := FKind in [skBus, skAux, skMaster];
end;

function TMixStrip.InsertCount: Integer;
begin
  Result := FInserts.Count;
end;

function TMixStrip.GetInsert(AIndex: Integer): TMixInsert;
begin
  Result := FInserts[AIndex];
end;

procedure TMixStrip.SetInsert(AIndex: Integer; const AInsert: TMixInsert);
begin
  FInserts[AIndex] := AInsert;
end;

function TMixStrip.AddInsert(const AInsert: TMixInsert): Integer;
begin
  Result := FInserts.Add(AInsert);
end;

procedure TMixStrip.InsertInsertAt(AIndex: Integer; const AInsert: TMixInsert);
begin
  if AIndex < 0 then AIndex := 0;
  if AIndex > FInserts.Count then AIndex := FInserts.Count;
  FInserts.Insert(AIndex, AInsert);
end;

procedure TMixStrip.DeleteInsert(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex < FInserts.Count) then
    FInserts.Delete(AIndex);
end;

procedure TMixStrip.MoveInsert(AFromIndex, AToIndex: Integer);
begin
  if (AFromIndex < 0) or (AFromIndex >= FInserts.Count) then Exit;
  if AToIndex < 0 then AToIndex := 0;
  if AToIndex >= FInserts.Count then AToIndex := FInserts.Count - 1;
  if AFromIndex = AToIndex then Exit;
  FInserts.Move(AFromIndex, AToIndex);
end;

function TMixStrip.SendCount: Integer;
begin
  Result := FSends.Count;
end;

function TMixStrip.GetSend(AIndex: Integer): TMixSend;
begin
  Result := FSends[AIndex];
end;

function TMixStrip.SendToStrip(ATargetStripId: Integer): TMixSend;
var
  i: Integer;
begin
  for i := 0 to FSends.Count - 1 do
    if FSends[i].TargetStripId = ATargetStripId then
      Exit(FSends[i]);
  Result := nil;
end;

function TMixStrip.AddSend(ATargetStripId: Integer; AGainDb: Double;
  AMode: TMixSendMode; AEnabled: Boolean): TMixSend;
begin
  Result := SendToStrip(ATargetStripId);
  if Result <> nil then
  begin
    Result.GainDb := ClampDb(AGainDb, MIX_MIN_DB, MIX_MAX_DB);
    Result.Mode := AMode;
    Result.Enabled := AEnabled;
    Exit;
  end;
  Result := TMixSend.Create(ATargetStripId, AGainDb, AMode, AEnabled);
  FSends.Add(Result);
end;

procedure TMixStrip.RemoveSend(ATargetStripId: Integer);
var
  i: Integer;
begin
  for i := FSends.Count - 1 downto 0 do
    if FSends[i].TargetStripId = ATargetStripId then
      FSends.Delete(i);
end;

procedure TMixStrip.ResetMeters;
begin
  FMeterPeakDbL := MIX_MIN_DB;
  FMeterPeakDbR := MIX_MIN_DB;
  FMeterRmsDb := MIX_MIN_DB;
  FMeterLufs := -70.0;
  FMeterLufsIntegrated := -70.0;
  FMeterHoldDbL := MIX_MIN_DB;
  FMeterHoldDbR := MIX_MIN_DB;
  FClipL := False;
  FClipR := False;
end;

procedure TMixStrip.ResetClip;
begin
  FClipL := False;
  FClipR := False;
end;

procedure TMixStrip.SetTrimGainDb(AValue: Double);
begin
  FTrimGainDb := ClampDb(AValue, MIX_TRIM_MIN_DB, MIX_TRIM_MAX_DB);
end;

procedure TMixStrip.SetPan(AValue: Double);
begin
  if IsNan(AValue) then AValue := 0;
  if AValue < -1 then AValue := -1 else if AValue > 1 then AValue := 1;
  FPan := AValue;
end;

procedure TMixStrip.SetStereoWidth(AValue: Double);
begin
  if IsNan(AValue) then AValue := 1;
  if AValue < MIX_WIDTH_MIN then AValue := MIX_WIDTH_MIN
  else if AValue > MIX_WIDTH_MAX then AValue := MIX_WIDTH_MAX;
  FStereoWidth := AValue;
end;

procedure TMixStrip.SetFaderDb(AValue: Double);
begin
  FFaderDb := ClampDb(AValue, MIX_MIN_DB, MIX_MAX_DB);
end;

{ ================= TMixerModel ================= }

constructor TMixerModel.Create;
begin
  inherited Create;
  FStrips := TObjectList<TMixStrip>.Create(True);
  FNextId := 1;
  FAutomation := TAutomationSet.Create;
  FModulation := TModulationSet.Create;
  FMeterHoldMs := MIX_METER_HOLD_MS_DEFAULT;
  FMeterHoldDecayDbPerSec := MIX_METER_HOLD_DECAY_DEFAULT;
end;

destructor TMixerModel.Destroy;
begin
  FModulation.Free;
  FAutomation.Free;
  FStrips.Free;
  inherited Destroy;
end;

procedure TMixerModel.Clear;
begin
  FStrips.Clear;
  FNextId := 1;
  FAutomation.Clear;
  FModulation.Clear;
  FMeterHoldMs := MIX_METER_HOLD_MS_DEFAULT;
  FMeterHoldDecayDbPerSec := MIX_METER_HOLD_DECAY_DEFAULT;
end;

procedure TMixerModel.SetMeterHoldMs(AValue: Double);
begin
  if IsNan(AValue) then AValue := MIX_METER_HOLD_MS_DEFAULT;
  if AValue < 0 then AValue := 0 else if AValue > 10000 then AValue := 10000;
  FMeterHoldMs := AValue;
end;

procedure TMixerModel.SetMeterHoldDecayDbPerSec(AValue: Double);
begin
  if IsNan(AValue) then AValue := MIX_METER_HOLD_DECAY_DEFAULT;
  if AValue < 0.1 then AValue := 0.1 else if AValue > 120 then AValue := 120;
  FMeterHoldDecayDbPerSec := AValue;
end;

function TMixerModel.Clone: TMixerModel;
var
  i: Integer;
  s, d: TMixStrip;
begin
  Result := TMixerModel.Create;
  Result.FNextId := FNextId;
  Result.FMeterHoldMs := FMeterHoldMs;
  Result.FMeterHoldDecayDbPerSec := FMeterHoldDecayDbPerSec;
  for i := 0 to FStrips.Count - 1 do
  begin
    s := FStrips[i];
    d := TMixStrip.Create(s.Id, s.Kind, s.Name);
    d.Assign(s);
    Result.FStrips.Add(d);
  end;
  Result.FAutomation.Free;
  Result.FAutomation := FAutomation.Clone;
  Result.FModulation.Free;
  Result.FModulation := FModulation.Clone;
end;

procedure TMixerModel.InitDefault;
begin
  Clear;
  AddStrip(skMaster, 'Master');
end;

function TMixerModel.EnsureMaster: TMixStrip;
begin
  Result := MasterStrip;
  if Result = nil then
    Result := AddStrip(skMaster, 'Master');
end;

procedure TMixerModel.BumpNextId(AObservedId: Integer);
begin
  if AObservedId >= FNextId then
    FNextId := AObservedId + 1;
end;

function TMixerModel.IndexOfStrip(AId: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to FStrips.Count - 1 do
    if FStrips[i].Id = AId then Exit(i);
  Result := -1;
end;

function TMixerModel.AddStrip(AKind: TMixStripKind; const AName: string): TMixStrip;
begin
  Result := TMixStrip.Create(FNextId, AKind, AName);
  Inc(FNextId);
  FStrips.Add(Result);
end;

function TMixerModel.AddStripWithId(AId: Integer; AKind: TMixStripKind;
  const AName: string): TMixStrip;
begin
  if IndexOfStrip(AId) >= 0 then
    RaiseUDAWFmt(errInvalidArgument, MIXER_SUBSYS,
      'AddStripWithId: id %d already in use', [AId]);
  Result := TMixStrip.Create(AId, AKind, AName);
  FStrips.Add(Result);
  BumpNextId(AId);
end;

procedure TMixerModel.RemoveStrip(AId: Integer);
var
  idx, i: Integer;
  s: TMixStrip;
begin
  idx := IndexOfStrip(AId);
  if idx < 0 then Exit;
  if FStrips[idx].Kind = skMaster then
    RaiseUDAW(errInvalidState, MIXER_SUBSYS, 'the master strip cannot be removed');

  { drop every reference to the strip that is going away }
  for i := 0 to FStrips.Count - 1 do
  begin
    s := FStrips[i];
    if s.OutputTargetId = AId then s.OutputTargetId := 0;   // fall back to master
    if s.VCAGroupId = AId then s.VCAGroupId := 0;
    s.RemoveSend(AId);
  end;
  FAutomation.RemoveStrip(AId);
  FModulation.RemoveStrip(AId);
  FAutomation.RemoveTargetStrip(AId);
  FStrips.Delete(idx);
end;

procedure TMixerModel.MoveStrip(AId, ANewIndex: Integer);
var
  idx: Integer;
begin
  idx := IndexOfStrip(AId);
  if idx < 0 then Exit;
  if ANewIndex < 0 then ANewIndex := 0;
  if ANewIndex >= FStrips.Count then ANewIndex := FStrips.Count - 1;
  if idx = ANewIndex then Exit;
  FStrips.Move(idx, ANewIndex);
end;

function TMixerModel.StripById(AId: Integer): TMixStrip;
var
  i: Integer;
begin
  i := IndexOfStrip(AId);
  if i >= 0 then Result := FStrips[i] else Result := nil;
end;

function TMixerModel.StripCount: Integer;
begin
  Result := FStrips.Count;
end;

function TMixerModel.GetStrip(AIndex: Integer): TMixStrip;
begin
  if (AIndex >= 0) and (AIndex < FStrips.Count) then
    Result := FStrips[AIndex]
  else
    Result := nil;
end;

function TMixerModel.SourceHasEffects(ASourceId: Integer): Boolean;
var visited: TList<Integer>; i: Integer; strip: TMixStrip;
  function HasEffects(S: TMixStrip): Boolean;
  var j: Integer; send: TMixSend;
  begin
    Result := False;
    if (S = nil) or visited.Contains(S.Id) then Exit;
    visited.Add(S.Id);
    for j := 0 to S.InsertCount - 1 do
      if not S.GetInsert(j).Bypass then Exit(True);
    if S.Kind = skMaster then Exit;
    if S.OutputTargetId = 0 then Result := HasEffects(MasterStrip)
    else Result := HasEffects(StripById(S.OutputTargetId));
    if Result then Exit;
    for j := 0 to S.SendCount - 1 do
    begin
      send := S.GetSend(j);
      if send.Enabled and (send.GainDb > MIX_MIN_DB) and
        HasEffects(StripById(send.TargetStripId)) then Exit(True);
    end;
  end;
begin
  Result := False;
  visited := TList<Integer>.Create;
  try
    for i := 0 to StripCount - 1 do
    begin
      strip := GetStrip(i);
      if (strip.Kind = skAudioTrack) and (strip.InputSourceId = ASourceId) and
        (ASourceId <> 0) and HasEffects(strip) then Exit(True);
    end;
  finally visited.Free; end;
end;

function TMixerModel.MasterStrip: TMixStrip;
var
  i: Integer;
begin
  for i := 0 to FStrips.Count - 1 do
    if FStrips[i].Kind = skMaster then Exit(FStrips[i]);
  Result := nil;
end;

function TMixerModel.MasterCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FStrips.Count - 1 do
    if FStrips[i].Kind = skMaster then Inc(Result);
end;

function TMixerModel.IndexOfStripId(AId: Integer): Integer;
begin
  Result := IndexOfStrip(AId);
end;

function TMixerModel.IndexOfMaster: Integer;
var
  i: Integer;
begin
  for i := 0 to FStrips.Count - 1 do
    if FStrips[i].Kind = skMaster then Exit(i);
  Result := -1;
end;

function TMixerModel.AnySolo: Boolean;
var
  i: Integer;
begin
  for i := 0 to FStrips.Count - 1 do
    if FStrips[i].Soloed and FStrips[i].IsAudioStrip and (FStrips[i].Kind <> skMaster) then
      Exit(True);
  Result := False;
end;

function TMixerModel.GateGain(AStrip: TMixStrip): Double;
begin
  Result := 1.0;
  if AStrip = nil then Exit;
  if AStrip.Muted then Exit(0.0);
  if AStrip.Kind = skMaster then Exit(1.0);
  if AnySolo and (not AStrip.Soloed) then Result := 0.0;
end;

function TMixerModel.VCATrimDb(AStrip: TMixStrip): Double;
var
  cur: TMixStrip;
  depth: Integer;
begin
  Result := 0.0;
  if AStrip = nil then Exit;
  cur := StripById(AStrip.VCAGroupId);
  depth := 0;
  while (cur <> nil) and (cur.Kind = skVCA) and (depth < VCA_MAX_DEPTH) do
  begin
    Result := Result + cur.FaderDb;
    if cur.Muted or (AnySolo and not cur.Soloed) then
      Result := MIX_MIN_DB;   // a muted / non-soloed VCA kills its members
    cur := StripById(cur.VCAGroupId);
    Inc(depth);
  end;
end;

function TMixerModel.HasRoutingCycle(out AWhere: string): Boolean;
var
  i, j, walkGuard: Integer;
  s, cur: TMixStrip;
begin
  AWhere := '';
  { output-target chain: each audio strip must reach the master without looping }
  for i := 0 to FStrips.Count - 1 do
  begin
    s := FStrips[i];
    if (s.Kind = skMaster) or (s.Kind = skVCA) then Continue;
    cur := s;
    walkGuard := 0;
    while (cur <> nil) and (cur.Kind <> skMaster) do
    begin
      Inc(walkGuard);
      if walkGuard > FStrips.Count + 1 then
      begin
        AWhere := s.Name;
        Exit(True);
      end;
      if cur.OutputTargetId = 0 then Break;   // 0 => straight to master
      if cur.OutputTargetId = cur.Id then
      begin
        AWhere := cur.Name;
        Exit(True);
      end;
      cur := StripById(cur.OutputTargetId);
    end;
  end;
  { send graph: a send from A to B plus the reverse (directly or transitively
    through further sends) would feed a bus back into itself }
  for i := 0 to FStrips.Count - 1 do
  begin
    s := FStrips[i];
    for j := 0 to s.SendCount - 1 do
    begin
      cur := StripById(s.GetSend(j).TargetStripId);
      walkGuard := 0;
      while cur <> nil do
      begin
        Inc(walkGuard);
        if walkGuard > FStrips.Count + 1 then Break;
        if cur = s then
        begin
          AWhere := s.Name;
          Exit(True);
        end;
        if cur.SendCount > 0 then
          cur := StripById(cur.GetSend(0).TargetStripId)
        else if cur.OutputTargetId <> 0 then
          cur := StripById(cur.OutputTargetId)
        else
          cur := nil;
      end;
    end;
  end;
  Result := False;
end;

function TMixerModel.ValidateRouting(out AError: string): Boolean;
var
  i, j, mc: Integer;
  s, tgt: TMixStrip;
  where: string;
begin
  AError := '';
  if FStrips.Count = 0 then
  begin
    AError := 'mixer has no strips';
    Exit(False);
  end;
  mc := MasterCount;
  if mc <> 1 then
  begin
    AError := Format('mixer needs exactly one master strip (found %d)', [mc]);
    Exit(False);
  end;

  for i := 0 to FStrips.Count - 1 do
  begin
    s := FStrips[i];

    if (s.Kind <> skMaster) and (s.OutputTargetId <> 0) then
    begin
      tgt := StripById(s.OutputTargetId);
      if tgt = nil then
      begin
        AError := Format('strip "%s" routes to a strip that does not exist (%d)',
          [s.Name, s.OutputTargetId]);
        Exit(False);
      end;
      if tgt = s then
      begin
        AError := Format('strip "%s" routes to itself', [s.Name]);
        Exit(False);
      end;
      if not tgt.AcceptsBusInput then
      begin
        AError := Format('strip "%s" routes into "%s" which is not a bus/aux/master',
          [s.Name, tgt.Name]);
        Exit(False);
      end;
    end;

    if (s.Kind = skMaster) and (s.OutputTargetId <> 0) then
    begin
      AError := 'the master strip cannot have an output target';
      Exit(False);
    end;

    if s.VCAGroupId <> 0 then
    begin
      tgt := StripById(s.VCAGroupId);
      if (tgt = nil) or (tgt.Kind <> skVCA) then
      begin
        AError := Format('strip "%s" is assigned to VCA group %d which is not a VCA strip',
          [s.Name, s.VCAGroupId]);
        Exit(False);
      end;
    end;

    for j := 0 to s.SendCount - 1 do
    begin
      tgt := StripById(s.GetSend(j).TargetStripId);
      if tgt = nil then
      begin
        AError := Format('strip "%s" has a send to a strip that does not exist (%d)',
          [s.Name, s.GetSend(j).TargetStripId]);
        Exit(False);
      end;
      if tgt = s then
      begin
        AError := Format('strip "%s" sends to itself', [s.Name]);
        Exit(False);
      end;
      if not tgt.AcceptsBusInput then
      begin
        AError := Format('strip "%s" sends into "%s" which is not a bus/aux/master',
          [s.Name, tgt.Name]);
        Exit(False);
      end;
    end;
  end;

  if HasRoutingCycle(where) then
  begin
    AError := Format('routing cycle (illegal feedback) involving strip "%s"', [where]);
    Exit(False);
  end;

  Result := True;
end;

function TMixerModel.Describe: string;
var
  sb: TStringBuilder;
  i, j: Integer;
  s: TMixStrip;
  err: string;
begin
  sb := TStringBuilder.Create;
  try
    sb.AppendLine(Format('mixer: %d strip(s), next id %d', [FStrips.Count, FNextId]));
    if not ValidateRouting(err) then
      sb.AppendLine('  routing INVALID: ' + err)
    else if AnySolo then
      sb.AppendLine('  (solo active)');
    for i := 0 to FStrips.Count - 1 do
    begin
      s := FStrips[i];
      sb.AppendLine(Format('  #%d %-10s %-14s in=%d out=%d trim=%.1f pan=%.2f width=%.2f fader=%.1f%s%s%s vca=%d',
        [s.Id, MixStripKindId(s.Kind), s.Name, s.InputSourceId, s.OutputTargetId,
         s.TrimGainDb, s.Pan, s.StereoWidth, s.FaderDb,
         IfThen(s.PolarityInvert, ' [pol]', ''),
         IfThen(s.Muted, ' [mute]', ''), IfThen(s.Soloed, ' [solo]', ''),
         s.VCAGroupId]));
      for j := 0 to s.InsertCount - 1 do
        sb.AppendLine(Format('      insert %d: %s %s%s',
          [j, s.GetInsert(j).Kind, s.GetInsert(j).Params,
           IfThen(s.GetInsert(j).Bypass, ' [bypass]', '')]));
      for j := 0 to s.SendCount - 1 do
        sb.AppendLine(Format('      send -> %d %.1f dB %s%s',
          [s.GetSend(j).TargetStripId, s.GetSend(j).GainDb,
           MixSendModeId(s.GetSend(j).Mode),
           IfThen(not s.GetSend(j).Enabled, ' [off]', '')]));
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

end.
