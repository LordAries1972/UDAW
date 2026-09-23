unit UDAW.Sequencer.Patterns;
{$I udaw.inc}

{ Pattern-generation helpers found in FL Studio / Ableton / Bitwig:
  - TStepPattern: step sequencer (per-step velocity, probability, swing,
    Euclidean fill) rendered to note events.
  - TArpeggiator: up/down/updown/random/played order over a chord with an
    octave range, rate and gate.
  - TMetronome: click-track events with accent and count-in.
  Positions are in quarter-note beats so they map onto the tempo map. }

interface

uses
  SysUtils, Math, Generics.Collections, Generics.Defaults;

type
  TSeqNote = record
    Beat: Double;      { start, quarter notes }
    Length: Double;    { duration, quarter notes }
    Key: Integer;      { MIDI note 0..127 }
    Velocity: Integer; { 1..127 }
  end;
  TSeqNotes = TArray<TSeqNote>;

  TStepPattern = class
  private
    FSteps: Integer;
    FOn: TArray<Boolean>;
    FVel: TArray<Integer>;
    FProb: TArray<Double>;
    FStepBeats: Double;
    FSwing: Double;
    FGate: Double;
    FKey: Integer;
    procedure SetSteps(AValue: Integer);
  public
    constructor Create(ASteps: Integer = 16);
    procedure SetStep(AIndex: Integer; AOn: Boolean; AVelocity: Integer = 100;
      AProbability: Double = 1.0);
    { evenly distributes APulses over the pattern, rotated by ARotate }
    procedure Euclidean(APulses, ARotate: Integer);
    procedure Clear;
    function Render(ALoops: Integer; ASeed: Cardinal = 1): TSeqNotes;
    property Steps: Integer read FSteps write SetSteps;
    property StepBeats: Double read FStepBeats write FStepBeats;
    property Swing: Double read FSwing write FSwing;   { 0..0.75 delay of off-steps }
    property Gate: Double read FGate write FGate;      { fraction of step length }
    property Key: Integer read FKey write FKey;
  end;

  TArpMode = (amUp, amDown, amUpDown, amRandom, amPlayed);

  TArpeggiator = class
  public
    Mode: TArpMode;
    Octaves: Integer;
    RateBeats: Double;
    Gate: Double;
    constructor Create;
    function Render(const AChord: array of Integer; AVelocity: Integer;
      AStartBeat, ADurationBeats: Double; ASeed: Cardinal = 1): TSeqNotes;
  end;

  TMetronome = class
  public
    BeatsPerBar: Integer;
    CountInBars: Integer;
    constructor Create;
    { downbeat key 76 (hi), other beats 77 (lo); count-in beats start negative }
    function Render(ALengthBeats: Double): TSeqNotes;
  end;

implementation

function NextRand(var ASeed: Cardinal): Double;
begin
  ASeed := ASeed * 1664525 + 1013904223;
  Result := (ASeed shr 8) / 16777216.0;
end;

{ TStepPattern }

constructor TStepPattern.Create(ASteps: Integer);
begin
  inherited Create;
  FStepBeats := 0.25;
  FGate := 0.9;
  FKey := 60;
  SetSteps(ASteps);
end;

procedure TStepPattern.SetSteps(AValue: Integer);
var
  i, old: Integer;
begin
  AValue := EnsureRange(AValue, 1, 64);
  old := Length(FOn);
  FSteps := AValue;
  SetLength(FOn, FSteps);
  SetLength(FVel, FSteps);
  SetLength(FProb, FSteps);
  for i := old to FSteps - 1 do
  begin
    FOn[i] := False;
    FVel[i] := 100;
    FProb[i] := 1.0;
  end;
end;

procedure TStepPattern.SetStep(AIndex: Integer; AOn: Boolean; AVelocity: Integer;
  AProbability: Double);
begin
  if (AIndex < 0) or (AIndex >= FSteps) then Exit;
  FOn[AIndex] := AOn;
  FVel[AIndex] := EnsureRange(AVelocity, 1, 127);
  FProb[AIndex] := EnsureRange(AProbability, 0.0, 1.0);
end;

procedure TStepPattern.Clear;
var
  i: Integer;
begin
  for i := 0 to FSteps - 1 do FOn[i] := False;
end;

procedure TStepPattern.Euclidean(APulses, ARotate: Integer);
var
  i, idx: Integer;
begin
  Clear;
  APulses := EnsureRange(APulses, 0, FSteps);
  for i := 0 to APulses - 1 do
  begin
    idx := ((i * FSteps) div APulses + ARotate) mod FSteps;
    if idx < 0 then Inc(idx, FSteps);
    FOn[idx] := True;
  end;
end;

function TStepPattern.Render(ALoops: Integer; ASeed: Cardinal): TSeqNotes;
var
  l, i: Integer;
  b: Double;
  L2: TList<TSeqNote>;
  nt: TSeqNote;
begin
  L2 := TList<TSeqNote>.Create;
  try
    for l := 0 to Max(ALoops, 1) - 1 do
      for i := 0 to FSteps - 1 do
      begin
        if not FOn[i] then Continue;
        if (FProb[i] < 1.0) and (NextRand(ASeed) > FProb[i]) then Continue;
        b := (l * FSteps + i) * FStepBeats;
        if Odd(i) then b := b + FSwing * FStepBeats;
        nt.Beat := b;
        nt.Length := FStepBeats * FGate;
        nt.Key := FKey;
        nt.Velocity := FVel[i];
        L2.Add(nt);
      end;
    Result := L2.ToArray;
  finally
    L2.Free;
  end;
end;

{ TArpeggiator }

constructor TArpeggiator.Create;
begin
  inherited Create;
  Mode := amUp;
  Octaves := 1;
  RateBeats := 0.25;
  Gate := 0.8;
end;

function TArpeggiator.Render(const AChord: array of Integer; AVelocity: Integer;
  AStartBeat, ADurationBeats: Double; ASeed: Cardinal): TSeqNotes;
var
  pool, sorted, seq: TArray<Integer>;
  i, o, k, n, steps: Integer;
  nt: TSeqNote;
  L: TList<TSeqNote>;
begin
  SetLength(Result, 0);
  if (Length(AChord) = 0) or (RateBeats <= 0) then Exit;
  SetLength(sorted, Length(AChord));
  for i := 0 to High(AChord) do sorted[i] := AChord[i];
  if Mode <> amPlayed then TArray.Sort<Integer>(sorted);
  n := 0;
  SetLength(pool, Length(sorted) * Max(Octaves, 1));
  for o := 0 to Max(Octaves, 1) - 1 do
    for i := 0 to High(sorted) do
    begin
      pool[n] := sorted[i] + 12 * o;
      Inc(n);
    end;
  case Mode of
    amDown:
      begin
        SetLength(seq, n);
        for i := 0 to n - 1 do seq[i] := pool[n - 1 - i];
      end;
    amUpDown:
      begin
        SetLength(seq, Max(2 * n - 2, 1));
        for i := 0 to n - 1 do seq[i] := pool[i];
        for i := 1 to n - 2 do seq[n - 1 + i] := pool[n - 1 - i];
      end;
  else
    seq := pool;
  end;
  L := TList<TSeqNote>.Create;
  try
    steps := Trunc(ADurationBeats / RateBeats + 1e-9);
    for i := 0 to steps - 1 do
    begin
      if Mode = amRandom then
        k := pool[Trunc(NextRand(ASeed) * n) mod n]
      else
        k := seq[i mod Length(seq)];
      nt.Beat := AStartBeat + i * RateBeats;
      nt.Length := RateBeats * Gate;
      nt.Key := EnsureRange(k, 0, 127);
      nt.Velocity := EnsureRange(AVelocity, 1, 127);
      L.Add(nt);
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

{ TMetronome }

constructor TMetronome.Create;
begin
  inherited Create;
  BeatsPerBar := 4;
  CountInBars := 0;
end;

function TMetronome.Render(ALengthBeats: Double): TSeqNotes;
var
  i, total, bpb: Integer;
begin
  bpb := Max(BeatsPerBar, 1);
  total := Max(Trunc(ALengthBeats) + CountInBars * bpb, 0);
  SetLength(Result, total);
  for i := 0 to total - 1 do
  begin
    Result[i].Beat := i - CountInBars * bpb;
    Result[i].Length := 0.1;
    if i mod bpb = 0 then
    begin
      Result[i].Key := 76;
      Result[i].Velocity := 120;
    end
    else
    begin
      Result[i].Key := 77;
      Result[i].Velocity := 85;
    end;
  end;
end;

end.
