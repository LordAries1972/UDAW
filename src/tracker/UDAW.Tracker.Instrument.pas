unit UDAW.Tracker.Instrument;
{$I udaw.inc}

{ Phase 11 - Tracker Engine: instruments and their envelopes.

  A tracker instrument here is a single mono Float32 sample plus a root note,
  a loop (off / forward / ping-pong), per-instrument volume / pan, a per-tick
  fade-out applied after a key-off, and independent volume / panning
  envelopes. Later phases add multisample layers and WAV import (plan
  section 12); the model and the replay core are shaped so that is an
  extension, not a rewrite. }

interface

uses
  SysUtils, Math,
  UDAW.Errors,
  UDAW.Audio.Types,
  UDAW.Tracker.Types;

const
  TRK_ENV_MAX_POINTS = 32;

type
  TTrackerLoopMode = (tlmOff, tlmForward, tlmPingPong);

  TTrackerEnvPoint = record
    Tick: Integer;      // >= 0, strictly increasing
    Value: Single;      // 0..1
  end;

  TTrackerEnvelope = record
    Enabled: Boolean;
    Points: array of TTrackerEnvPoint;
    SustainPoint: Integer;   // index held while the key is down, or -1
    LoopStart: Integer;      // index, or -1
    LoopEnd: Integer;        // index, or -1
    procedure Clear;
    procedure AddPoint(ATick: Integer; AValue: Single);
    function LastTick: Integer;
    { Linear-interpolated value at ATick (clamps outside the point range). }
    function ValueAt(ATick: Integer): Single;
  end;

  TTrackerInstrument = class
  private
    FName: string;
    FRootNote: Byte;
    FSampleRate: Integer;
    FData: TAudioSampleArray;   // mono
    FLoopMode: TTrackerLoopMode;
    FLoopStart: Integer;
    FLoopEnd: Integer;
    FVolume: Single;            // 0..1
    FPan: Single;               // -1..+1
    FFadeout: Single;           // fraction removed per tick after key-off (0..1)
    FVolEnv: TTrackerEnvelope;
    FPanEnv: TTrackerEnvelope;
    FLayers: array of TTrackerInstrument;   // owned extra samples (XM multi-sample instruments)
    FKeyMap: array[0..TRK_NOTE_MAX] of Byte;   // note -> 0 = own sample, n = FLayers[n-1]
    procedure ClampLoop;
    function GetLayer(AIndex: Integer): TTrackerInstrument;
    function GetLayerCount: Integer;
  public
    constructor Create(const AName: string = 'Instrument');
    destructor Destroy; override;
    function Clone: TTrackerInstrument;

    { Multi-sample instruments: a layer is a further sample (its own data, rate, loop,
      volume, pan and root note) that the key map selects per note; envelopes and
      fade-out always come from the instrument itself. }
    function AddLayer: TTrackerInstrument;
    procedure SetKeyMap(ANote, ALayer: Integer);
    function KeyMapAt(ANote: Integer): Integer;
    { the sample that plays ANote: Self, or one of the layers }
    function SampleForNote(ANote: Integer): TTrackerInstrument;
    property LayerCount: Integer read GetLayerCount;
    property Layers[AIndex: Integer]: TTrackerInstrument read GetLayer;

    procedure SetData(const AData: TAudioSampleArray; ASampleRate: Integer);
    { Fill with a deterministic one-cycle-looped sine at AFreqHz for the tests
      and the "fill demo" UI action. Loop is set to the whole sample forward. }
    procedure MakeSine(AFreqHz: Double; ASeconds: Double; ASampleRate: Integer = 48000;
      AAmplitude: Single = 0.7);

    function FrameCount: Integer;
    function Describe: string;

    property Name: string read FName write FName;
    property RootNote: Byte read FRootNote write FRootNote;
    property SampleRate: Integer read FSampleRate write FSampleRate;
    property LoopMode: TTrackerLoopMode read FLoopMode write FLoopMode;
    property LoopStart: Integer read FLoopStart write FLoopStart;
    property LoopEnd: Integer read FLoopEnd write FLoopEnd;
    property Volume: Single read FVolume write FVolume;
    property Pan: Single read FPan write FPan;
    property Fadeout: Single read FFadeout write FFadeout;
    property Data: TAudioSampleArray read FData;
    property VolEnv: TTrackerEnvelope read FVolEnv write FVolEnv;
    property PanEnv: TTrackerEnvelope read FPanEnv write FPanEnv;
  end;

function LoopModeId(AMode: TTrackerLoopMode): string;
function LoopModeFromId(const AId: string; out AMode: TTrackerLoopMode): Boolean;

implementation


uses
  UDAW.DSP.MathTables;

function LoopModeId(AMode: TTrackerLoopMode): string;
begin
  case AMode of
    tlmForward:  Result := 'forward';
    tlmPingPong: Result := 'pingpong';
  else
    Result := 'off';
  end;
end;

function LoopModeFromId(const AId: string; out AMode: TTrackerLoopMode): Boolean;
begin
  Result := True;
  if SameText(AId, 'forward') then AMode := tlmForward
  else if SameText(AId, 'pingpong') then AMode := tlmPingPong
  else if SameText(AId, 'off') then AMode := tlmOff
  else Result := False;
end;

{ ================= TTrackerEnvelope ================= }

procedure TTrackerEnvelope.Clear;
begin
  Enabled := False;
  SetLength(Points, 0);
  SustainPoint := -1;
  LoopStart := -1;
  LoopEnd := -1;
end;

procedure TTrackerEnvelope.AddPoint(ATick: Integer; AValue: Single);
var
  n: Integer;
begin
  if Length(Points) >= TRK_ENV_MAX_POINTS then Exit;
  if ATick < 0 then ATick := 0;
  if AValue < 0 then AValue := 0 else if AValue > 1 then AValue := 1;
  n := Length(Points);
  if (n > 0) and (ATick <= Points[n - 1].Tick) then
    ATick := Points[n - 1].Tick + 1;
  SetLength(Points, n + 1);
  Points[n].Tick := ATick;
  Points[n].Value := AValue;
end;

function TTrackerEnvelope.LastTick: Integer;
begin
  if Length(Points) = 0 then Result := 0
  else Result := Points[High(Points)].Tick;
end;

function TTrackerEnvelope.ValueAt(ATick: Integer): Single;
var
  i: Integer;
  t0, t1: Integer;
  v0, v1, f: Single;
begin
  if Length(Points) = 0 then Exit(1.0);
  if ATick <= Points[0].Tick then Exit(Points[0].Value);
  if ATick >= Points[High(Points)].Tick then Exit(Points[High(Points)].Value);
  for i := 0 to High(Points) - 1 do
    if (ATick >= Points[i].Tick) and (ATick < Points[i + 1].Tick) then
    begin
      t0 := Points[i].Tick;
      t1 := Points[i + 1].Tick;
      v0 := Points[i].Value;
      v1 := Points[i + 1].Value;
      if t1 = t0 then Exit(v1);
      f := (ATick - t0) / (t1 - t0);
      Exit(v0 + (v1 - v0) * f);
    end;
  Result := Points[High(Points)].Value;
end;

{ ================= TTrackerInstrument ================= }

constructor TTrackerInstrument.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FRootNote := A4_NOTE_VALUE;
  FSampleRate := 48000;
  FLoopMode := tlmOff;
  FVolume := 1.0;
  FPan := 0.0;
  FFadeout := 0.0;
  FVolEnv.Clear;
  FPanEnv.Clear;
end;

destructor TTrackerInstrument.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FLayers) do FLayers[i].Free;
  SetLength(FLayers, 0);
  SetLength(FData, 0);
  inherited Destroy;
end;

function TTrackerInstrument.GetLayerCount: Integer;
begin
  Result := Length(FLayers);
end;

function TTrackerInstrument.GetLayer(AIndex: Integer): TTrackerInstrument;
begin
  Result := FLayers[AIndex];
end;

function TTrackerInstrument.AddLayer: TTrackerInstrument;
begin
  Result := TTrackerInstrument.Create(FName);
  SetLength(FLayers, Length(FLayers) + 1);
  FLayers[High(FLayers)] := Result;
end;

procedure TTrackerInstrument.SetKeyMap(ANote, ALayer: Integer);
begin
  if (ANote < 0) or (ANote > TRK_NOTE_MAX) then Exit;
  if (ALayer < 0) or (ALayer > Length(FLayers)) then ALayer := 0;
  FKeyMap[ANote] := Byte(ALayer);
end;

function TTrackerInstrument.KeyMapAt(ANote: Integer): Integer;
begin
  if (ANote < 0) or (ANote > TRK_NOTE_MAX) then Exit(0);
  Result := FKeyMap[ANote];
end;

function TTrackerInstrument.SampleForNote(ANote: Integer): TTrackerInstrument;
var
  l: Integer;
begin
  Result := Self;
  l := KeyMapAt(ANote);
  if (l > 0) and (l <= Length(FLayers)) and (FLayers[l - 1].FrameCount > 0) then
    Result := FLayers[l - 1];
end;

function TTrackerInstrument.Clone: TTrackerInstrument;
var
  i: Integer;
begin
  Result := TTrackerInstrument.Create(FName);
  Result.FRootNote := FRootNote;
  Result.FSampleRate := FSampleRate;
  Result.FData := Copy(FData);
  Result.FLoopMode := FLoopMode;
  Result.FLoopStart := FLoopStart;
  Result.FLoopEnd := FLoopEnd;
  Result.FVolume := FVolume;
  Result.FPan := FPan;
  Result.FFadeout := FFadeout;
  Result.FVolEnv := FVolEnv;
  Result.FVolEnv.Points := Copy(FVolEnv.Points);
  Result.FPanEnv := FPanEnv;
  Result.FPanEnv.Points := Copy(FPanEnv.Points);
  SetLength(Result.FLayers, Length(FLayers));
  for i := 0 to High(FLayers) do Result.FLayers[i] := FLayers[i].Clone;
  Result.FKeyMap := FKeyMap;
end;

procedure TTrackerInstrument.ClampLoop;
begin
  if FLoopStart < 0 then FLoopStart := 0;
  if FLoopEnd > Length(FData) then FLoopEnd := Length(FData);
  if FLoopEnd <= FLoopStart then
  begin
    FLoopStart := 0;
    FLoopEnd := Length(FData);
  end;
end;

procedure TTrackerInstrument.SetData(const AData: TAudioSampleArray; ASampleRate: Integer);
begin
  FData := Copy(AData);
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  FLoopStart := 0;
  FLoopEnd := Length(FData);
  ClampLoop;
end;

procedure TTrackerInstrument.MakeSine(AFreqHz, ASeconds: Double; ASampleRate: Integer;
  AAmplitude: Single);
var
  n, i: Integer;
begin
  if ASampleRate <= 0 then ASampleRate := 48000;
  FSampleRate := ASampleRate;
  n := Max(1, Round(ASeconds * ASampleRate));
  SetLength(FData, n);
  for i := 0 to n - 1 do
    FData[i] := Single(AAmplitude * FastSin(2 * Pi * AFreqHz * i / ASampleRate));
  FRootNote := A4_NOTE_VALUE;
  { the native pitch of this sample is AFreqHz -> pick the root note that
    matches it so the player's pitch maths line up }
  FRootNote := Byte(ClampInt(A4_NOTE_VALUE + Round(12.0 * FastLn(AFreqHz / A4_HZ) / FastLn(2.0)),
    TRK_NOTE_MIN, TRK_NOTE_MAX));
  FLoopMode := tlmForward;
  FLoopStart := 0;
  FLoopEnd := n;
end;

function TTrackerInstrument.FrameCount: Integer;
begin
  Result := Length(FData);
end;

function TTrackerInstrument.Describe: string;
begin
  Result := Format('"%s" root=%s rate=%d frames=%d loop=%s vol=%.2f pan=%.2f fade=%.3f',
    [FName, NoteName(FRootNote), FSampleRate, Length(FData), LoopModeId(FLoopMode),
     FVolume, FPan, FFadeout]);
end;

end.
