unit UDAW.Mixer.Modulation;
{$I udaw.inc}

{ General modulator system (Bitwig/Ableton-style): modulator sources are
  routed to mixer parameters with a bipolar amount.

  Sources: LFO (sine/triangle/saw/square/sample&hold), smoothed random,
  16-step sequence, envelope follower (level of a mixer strip's input) and a
  static macro knob. Routes target a strip fader (dB), pan (-1..1) or a hosted
  plugin parameter (0..1). Evaluated once per audio block; values are pure
  functions of the playhead time (LFO/random/steps) or of the follower state,
  so offline export and live playback agree. }

interface

uses
  SysUtils, Math, Classes, Generics.Collections,
  UDAW.Mixer.Automation;

type
  TModKind = (mkLfo, mkRandom, mkSteps, mkFollower, mkMacro);
  TLfoShape = (lsSine, lsTriangle, lsSaw, lsSquare, lsSampleHold);

  TModulator = class
  public
    Name: string;
    Kind: TModKind;
    Shape: TLfoShape;
    RateHz: Double;         { LFO / random rate }
    SyncBeats: Double;      { > 0: rate = BPM / 60 / SyncBeats (tempo sync) }
    Phase: Double;          { 0..1 start offset }
    Steps: array[0..15] of Double; { -1..1 }
    StepCount: Integer;
    FollowStripId: Integer; { follower source strip }
    Attack, Release: Double;{ follower seconds }
    Value: Double;          { macro value, -1..1 }
    Seed: Cardinal;
    FEnv: Double;           { follower state }
    FLastLevel: Double;     { follower input for the next block }
    constructor Create(AKind: TModKind);
    { returns -1..1 }
    function Evaluate(ATimeSeconds, ABpm: Double): Double;
    { followers: feed the source peak (0..1 linear) and advance ABlockSec }
    procedure FeedLevel(ALinear, ABlockSec: Double);
  end;

  TModRoute = record
    ModIndex: Integer;
    StripId: Integer;
    Param: TAutomationParam; { apFader, apPan, apInsertParam }
    TargetIndex: Integer;    { insert index }
    SubIndex: Integer;       { plugin parameter index }
    Amount: Double;          { fader: dB, pan: +-1, plugin: +-1 of 0..1 }
    Base: Double;            { plugin parameter centre value 0..1 }
  end;

  TModulationSet = class
  private
    FMods: TObjectList<TModulator>;
    FRoutes: TList<TModRoute>;
  public
    Bpm: Double;
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Clone: TModulationSet;
    function AddModulator(AKind: TModKind; const AName: string): TModulator;
    procedure RemoveModulator(AIndex: Integer);
    function ModCount: Integer;
    function GetMod(AIndex: Integer): TModulator;
    procedure AddRoute(const ARoute: TModRoute);
    procedure RemoveRoute(AIndex: Integer);
    function RouteCount: Integer;
    function GetRoute(AIndex: Integer): TModRoute;
    procedure RemoveStrip(AStripId: Integer);
    { sum of modulation (in the target's own units) for a target }
    function Offset(AStripId: Integer; AParam: TAutomationParam;
      ATargetIndex, ASubIndex: Integer; ATimeSeconds: Double): Double;
    function HasRoutes: Boolean;
    { text persistence: MODSRC / MODROUTE lines }
    procedure Serialize(ALines: TStrings);
    function TryParseLine(const ALine: string): Boolean;
  end;

function ModKindId(AKind: TModKind): string;
function ModKindFromId(const AId: string; out AKind: TModKind): Boolean;

implementation


uses
  UDAW.DSP.MathTables;

const
  KIND_IDS: array[TModKind] of string = ('lfo', 'random', 'steps', 'follower', 'macro');

function ModKindId(AKind: TModKind): string;
begin
  Result := KIND_IDS[AKind];
end;

function ModKindFromId(const AId: string; out AKind: TModKind): Boolean;
var
  k: TModKind;
begin
  for k := Low(TModKind) to High(TModKind) do
    if SameText(AId, KIND_IDS[k]) then
    begin
      AKind := k;
      Exit(True);
    end;
  Result := False;
end;

function HashNoise(ASeed: Cardinal; AIndex: Int64): Double;
var
  h: Cardinal;
begin
  h := ASeed xor Cardinal(AIndex * 2654435761);
  h := (h xor (h shr 15)) * 2246822519;
  h := (h xor (h shr 13)) * 3266489917;
  h := h xor (h shr 16);
  Result := (h / 4294967295.0) * 2.0 - 1.0;
end;

{ TModulator }

constructor TModulator.Create(AKind: TModKind);
var
  i: Integer;
begin
  inherited Create;
  Kind := AKind;
  Shape := lsSine;
  RateHz := 1.0;
  StepCount := 8;
  Attack := 0.01;
  Release := 0.2;
  Seed := 12345;
  for i := 0 to 15 do Steps[i] := 0;
end;

function TModulator.Evaluate(ATimeSeconds, ABpm: Double): Double;
var
  rate, ph, pos, a, b, fr: Double;
  idx: Int64;
  n: Integer;
begin
  rate := RateHz;
  if (SyncBeats > 0) and (ABpm > 0) then rate := ABpm / 60.0 / SyncBeats;
  case Kind of
    mkLfo:
      begin
        ph := Frac(ATimeSeconds * rate + Phase);
        if ph < 0 then ph := ph + 1.0;
        case Shape of
          lsSine: Result := FastSin(2.0 * Pi * ph);
          lsTriangle: Result := 1.0 - 4.0 * Abs(ph - 0.5);
          lsSaw: Result := 2.0 * ph - 1.0;
          lsSquare: if ph < 0.5 then Result := 1.0 else Result := -1.0;
        else
          Result := HashNoise(Seed, Floor(ATimeSeconds * rate + Phase));
        end;
      end;
    mkRandom:
      begin
        pos := ATimeSeconds * rate;
        idx := Floor(pos);
        fr := pos - idx;
        fr := fr * fr * (3.0 - 2.0 * fr); { smoothstep glide between values }
        a := HashNoise(Seed, idx);
        b := HashNoise(Seed, idx + 1);
        Result := a + (b - a) * fr;
      end;
    mkSteps:
      begin
        n := EnsureRange(StepCount, 1, 16);
        pos := ATimeSeconds * rate;
        idx := Floor(pos);
        Result := Steps[((idx mod n) + n) mod n];
      end;
    mkFollower: Result := EnsureRange(FEnv * 2.0 - 1.0, -1.0, 1.0);
  else
    Result := EnsureRange(Value, -1.0, 1.0);
  end;
end;

procedure TModulator.FeedLevel(ALinear, ABlockSec: Double);
var
  coef, t: Double;
begin
  if ALinear > FEnv then t := Attack else t := Release;
  if t < 1e-4 then coef := 1.0 else coef := 1.0 - FastExp(-ABlockSec / t);
  FEnv := FEnv + (Min(ALinear, 1.0) - FEnv) * coef;
end;

{ TModulationSet }

constructor TModulationSet.Create;
begin
  inherited Create;
  FMods := TObjectList<TModulator>.Create(True);
  FRoutes := TList<TModRoute>.Create;
  Bpm := 120.0;
end;

destructor TModulationSet.Destroy;
begin
  FRoutes.Free;
  FMods.Free;
  inherited;
end;

procedure TModulationSet.Clear;
begin
  FRoutes.Clear;
  FMods.Clear;
end;

function TModulationSet.Clone: TModulationSet;
var
  i: Integer;
  m, c: TModulator;
begin
  Result := TModulationSet.Create;
  Result.Bpm := Bpm;
  for i := 0 to FMods.Count - 1 do
  begin
    m := FMods[i];
    c := Result.AddModulator(m.Kind, m.Name);
    c.Shape := m.Shape; c.RateHz := m.RateHz; c.SyncBeats := m.SyncBeats;
    c.Phase := m.Phase; c.Steps := m.Steps; c.StepCount := m.StepCount;
    c.FollowStripId := m.FollowStripId; c.Attack := m.Attack; c.Release := m.Release;
    c.Value := m.Value; c.Seed := m.Seed;
  end;
  for i := 0 to FRoutes.Count - 1 do Result.FRoutes.Add(FRoutes[i]);
end;

function TModulationSet.AddModulator(AKind: TModKind; const AName: string): TModulator;
begin
  Result := TModulator.Create(AKind);
  Result.Name := AName;
  FMods.Add(Result);
end;

procedure TModulationSet.RemoveModulator(AIndex: Integer);
var
  i: Integer;
  r: TModRoute;
begin
  if (AIndex < 0) or (AIndex >= FMods.Count) then Exit;
  for i := FRoutes.Count - 1 downto 0 do
    if FRoutes[i].ModIndex = AIndex then
      FRoutes.Delete(i)
    else if FRoutes[i].ModIndex > AIndex then
    begin
      r := FRoutes[i];
      Dec(r.ModIndex);
      FRoutes[i] := r;
    end;
  FMods.Delete(AIndex);
end;

function TModulationSet.ModCount: Integer;
begin
  Result := FMods.Count;
end;

function TModulationSet.GetMod(AIndex: Integer): TModulator;
begin
  Result := FMods[AIndex];
end;

procedure TModulationSet.AddRoute(const ARoute: TModRoute);
begin
  FRoutes.Add(ARoute);
end;

procedure TModulationSet.RemoveRoute(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex < FRoutes.Count) then FRoutes.Delete(AIndex);
end;

function TModulationSet.RouteCount: Integer;
begin
  Result := FRoutes.Count;
end;

function TModulationSet.GetRoute(AIndex: Integer): TModRoute;
begin
  Result := FRoutes[AIndex];
end;

procedure TModulationSet.RemoveStrip(AStripId: Integer);
var
  i: Integer;
begin
  for i := FRoutes.Count - 1 downto 0 do
    if FRoutes[i].StripId = AStripId then FRoutes.Delete(i);
  for i := 0 to FMods.Count - 1 do
    if FMods[i].FollowStripId = AStripId then FMods[i].FollowStripId := 0;
end;

function TModulationSet.HasRoutes: Boolean;
begin
  Result := FRoutes.Count > 0;
end;

function TModulationSet.Offset(AStripId: Integer; AParam: TAutomationParam;
  ATargetIndex, ASubIndex: Integer; ATimeSeconds: Double): Double;
var
  i: Integer;
  r: TModRoute;
begin
  Result := 0;
  for i := 0 to FRoutes.Count - 1 do
  begin
    r := FRoutes[i];
    if (r.StripId <> AStripId) or (r.Param <> AParam) then Continue;
    if AParam = apInsertParam then
      if (r.TargetIndex <> ATargetIndex) or (r.SubIndex <> ASubIndex) then Continue;
    if (r.ModIndex < 0) or (r.ModIndex >= FMods.Count) then Continue;
    Result := Result + r.Amount * FMods[r.ModIndex].Evaluate(ATimeSeconds, Bpm);
  end;
end;

procedure TModulationSet.Serialize(ALines: TStrings);
var
  i, k: Integer;
  m: TModulator;
  r: TModRoute;
  fs: TFormatSettings;
  st: string;
begin
  fs := TFormatSettings.Invariant;
  for i := 0 to FMods.Count - 1 do
  begin
    m := FMods[i];
    st := '';
    for k := 0 to 15 do st := st + FloatToStr(m.Steps[k], fs) + ',';
    ALines.Add(Format('MODSRC %d %s "%s" shape=%d rate=%s sync=%s phase=%s stepn=%d follow=%d atk=%s rel=%s val=%s seed=%d steps=%s',
      [i, KIND_IDS[m.Kind], m.Name, Ord(m.Shape), FloatToStr(m.RateHz, fs),
       FloatToStr(m.SyncBeats, fs), FloatToStr(m.Phase, fs), m.StepCount,
       m.FollowStripId, FloatToStr(m.Attack, fs), FloatToStr(m.Release, fs),
       FloatToStr(m.Value, fs), m.Seed, st], fs));
  end;
  for i := 0 to FRoutes.Count - 1 do
  begin
    r := FRoutes[i];
    ALines.Add(Format('MODROUTE %d %d %s %d %d %s %s',
      [r.ModIndex, r.StripId, AutomationParamId(r.Param), r.TargetIndex,
       r.SubIndex, FloatToStr(r.Amount, fs), FloatToStr(r.Base, fs)], fs));
  end;
end;

function KV(const ALine, AKey: string; const ADef: string = ''): string;
var
  p, q: Integer;
begin
  p := Pos(' ' + AKey + '=', ALine);
  if p = 0 then Exit(ADef);
  Inc(p, Length(AKey) + 2);
  q := p;
  while (q <= Length(ALine)) and (ALine[q] <> ' ') do Inc(q);
  Result := Copy(ALine, p, q - p);
end;

function TModulationSet.TryParseLine(const ALine: string): Boolean;
var
  fs: TFormatSettings;
  parts: TStringList;
  kind: TModKind;
  m: TModulator;
  r: TModRoute;
  prm: TAutomationParam;
  q1, q2, k: Integer;
  nm, stp: string;
  sl: TStringList;
begin
  Result := False;
  fs := TFormatSettings.Invariant;
  if Pos('MODSRC ', ALine) = 1 then
  begin
    q1 := Pos('"', ALine);
    q2 := Pos('"', Copy(ALine, q1 + 1, MaxInt)) + q1;
    if (q1 = 0) or (q2 <= q1) then Exit;
    nm := Copy(ALine, q1 + 1, q2 - q1 - 1);
    parts := TStringList.Create;
    try
      parts.Delimiter := ' ';
      parts.StrictDelimiter := True;
      parts.DelimitedText := Copy(ALine, 1, q1 - 1);
      if parts.Count < 3 then Exit;
      if not ModKindFromId(parts[2], kind) then Exit;
    finally
      parts.Free;
    end;
    m := AddModulator(kind, nm);
    m.Shape := TLfoShape(EnsureRange(StrToIntDef(KV(ALine, 'shape', '0'), 0), 0, 4));
    m.RateHz := StrToFloatDef(KV(ALine, 'rate', '1'), 1, fs);
    m.SyncBeats := StrToFloatDef(KV(ALine, 'sync', '0'), 0, fs);
    m.Phase := StrToFloatDef(KV(ALine, 'phase', '0'), 0, fs);
    m.StepCount := StrToIntDef(KV(ALine, 'stepn', '8'), 8);
    m.FollowStripId := StrToIntDef(KV(ALine, 'follow', '0'), 0);
    m.Attack := StrToFloatDef(KV(ALine, 'atk', '0.01'), 0.01, fs);
    m.Release := StrToFloatDef(KV(ALine, 'rel', '0.2'), 0.2, fs);
    m.Value := StrToFloatDef(KV(ALine, 'val', '0'), 0, fs);
    m.Seed := Cardinal(StrToInt64Def(KV(ALine, 'seed', '12345'), 12345));
    stp := KV(ALine, 'steps', '');
    sl := TStringList.Create;
    try
      sl.Delimiter := ',';
      sl.StrictDelimiter := True;
      sl.DelimitedText := stp;
      for k := 0 to Min(sl.Count, 16) - 1 do
        m.Steps[k] := StrToFloatDef(sl[k], 0, fs);
    finally
      sl.Free;
    end;
    Exit(True);
  end;
  if Pos('MODROUTE ', ALine) = 1 then
  begin
    parts := TStringList.Create;
    try
      parts.Delimiter := ' ';
      parts.StrictDelimiter := True;
      parts.DelimitedText := ALine;
      if parts.Count < 7 then Exit;
      if not AutomationParamFromId(parts[3], prm) then Exit;
      r.ModIndex := StrToIntDef(parts[1], -1);
      r.StripId := StrToIntDef(parts[2], 0);
      r.Param := prm;
      r.TargetIndex := StrToIntDef(parts[4], 0);
      r.SubIndex := StrToIntDef(parts[5], 0);
      r.Amount := StrToFloatDef(parts[6], 0, fs);
      if parts.Count > 7 then r.Base := StrToFloatDef(parts[7], 0.5, fs) else r.Base := 0.5;
      FRoutes.Add(r);
      Result := True;
    finally
      parts.Free;
    end;
  end;
end;

end.
