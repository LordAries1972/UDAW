unit UDAW.DSP.Envelope;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 3 - envelope generation and detection.

  * TADSR             - sample-accurate ADSR generator with analog-style
                        exponential segments (RC curve with a target-overshoot
                        so the segment actually reaches its end level in the
                        programmed time). Gate on / off, retrigger, IsActive.
  * TEnvelopeFollower - attack/release detector over |x| (peak) or sqrt(x^2)
                        (RMS-ish); the level source for compressors, gates,
                        de-essers and meters.
  * TAREnvelope       - a minimal attack/release gain ramp (fades, auto-mute).

  All state is value-type; nothing allocates. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math;

type
  TADSRStage = (asIdle, asAttack, asDecay, asSustain, asRelease);

  TADSR = record
  private
    FSampleRate: Double;
    FAttackMs, FDecayMs, FSustain, FReleaseMs: Double;
    FStage: TADSRStage;
    FValue: Double;
    FAttackCoef, FAttackBase: Double;
    FDecayCoef, FDecayBase: Double;
    FReleaseCoef, FReleaseBase: Double;
    FTargetRatioA, FTargetRatioDR: Double;
    procedure Recalc;
    function SegCoef(ARateMs, ARatio: Double): Double;
  public
    procedure Init(ASampleRate: Double);
    { times in milliseconds, sustain 0..1 }
    procedure SetADSR(AAttackMs, ADecayMs, ASustain, AReleaseMs: Double);
    { curve shape: larger = more linear, smaller = more exponential (default ~0.3 / 0.0001) }
    procedure SetCurve(AAttackRatio, ADecayReleaseRatio: Double);
    procedure Gate(AOn: Boolean);
    procedure NoteOn;
    procedure NoteOff;
    procedure HardReset;
    function Process: Single; {$IFDEF FPC}inline;{$ENDIF}
    procedure ProcessBlockMul(ABuf: PSingle; AFrames: Integer);
    function IsActive: Boolean;
    property Stage: TADSRStage read FStage;
    property Value: Double read FValue;
  end;

  TFollowerMode = (fmPeak, fmRms);

  TEnvelopeFollower = record
  private
    FSampleRate: Double;
    FAttackCoef, FReleaseCoef: Double;
    FEnv: Double;
    FMode: TFollowerMode;
    FRmsSq: Double;
  public
    procedure Init(ASampleRate: Double);
    procedure SetTimes(AAttackMs, AReleaseMs: Double);
    procedure SetMode(AMode: TFollowerMode);
    procedure Reset;
    function Process(AX: Single): Single; {$IFDEF FPC}inline;{$ENDIF}
    function ProcessBlock(ABuf: PSingle; AFrames: Integer): Single;   // returns last env
    function EnvelopeDb: Double;
    property Envelope: Double read FEnv;
  end;

  TAREnvelope = record
  private
    FCoefUp, FCoefDn: Double;
    FValue: Double;
    FTarget: Double;
    FSampleRate: Double;
  public
    procedure Init(ASampleRate: Double; AAttackMs, AReleaseMs: Double);
    procedure SetTarget(AValue: Double);
    procedure SetImmediate(AValue: Double);
    function Process: Single; {$IFDEF FPC}inline;{$ENDIF}
    procedure ProcessBlockMul(ABuf: PSingle; AFrames: Integer);
    function Settled: Boolean;
    property Value: Double read FValue;
  end;

function ADSRStageName(AStage: TADSRStage): string;

implementation

function ADSRStageName(AStage: TADSRStage): string;
begin
  case AStage of
    asIdle:    Result := 'idle';
    asAttack:  Result := 'attack';
    asDecay:   Result := 'decay';
    asSustain: Result := 'sustain';
    asRelease: Result := 'release';
  else
    Result := '?';
  end;
end;

{ ---------------- TADSR ---------------- }
{ Coefficient form after Nigel Redmon's "ADSR envelope" article - a first-order
  recursion x := base + x*coef whose asymptote is offset past the segment target
  by ATargetRatio, so the segment lands on its end level in finite time. }

procedure TADSR.Init(ASampleRate: Double);
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FSampleRate := ASampleRate;
  FAttackMs := 5;
  FDecayMs := 80;
  FSustain := 0.7;
  FReleaseMs := 150;
  FTargetRatioA := 0.3;
  FTargetRatioDR := 0.0001;
  FStage := asIdle;
  FValue := 0;
  Recalc;
end;

function TADSR.SegCoef(ARateMs, ARatio: Double): Double;
var
  rateSamples: Double;
begin
  rateSamples := (ARateMs * 0.001) * FSampleRate;
  if rateSamples < 1.0E-6 then
    Result := 0.0   // instantaneous: x := base (= target) next sample
  else
    Result := Exp(-Ln((1.0 + ARatio) / ARatio) / rateSamples);
end;

procedure TADSR.Recalc;
begin
  FAttackCoef := SegCoef(FAttackMs, FTargetRatioA);
  FAttackBase := (1.0 + FTargetRatioA) * (1.0 - FAttackCoef);

  FDecayCoef := SegCoef(FDecayMs, FTargetRatioDR);
  FDecayBase := (FSustain - FTargetRatioDR) * (1.0 - FDecayCoef);

  FReleaseCoef := SegCoef(FReleaseMs, FTargetRatioDR);
  FReleaseBase := (0.0 - FTargetRatioDR) * (1.0 - FReleaseCoef);
end;

procedure TADSR.SetADSR(AAttackMs, ADecayMs, ASustain, AReleaseMs: Double);
begin
  if AAttackMs < 0 then AAttackMs := 0;
  if ADecayMs < 0 then ADecayMs := 0;
  if AReleaseMs < 0 then AReleaseMs := 0;
  if ASustain < 0 then ASustain := 0 else if ASustain > 1 then ASustain := 1;
  FAttackMs := AAttackMs;
  FDecayMs := ADecayMs;
  FSustain := ASustain;
  FReleaseMs := AReleaseMs;
  Recalc;
end;

procedure TADSR.SetCurve(AAttackRatio, ADecayReleaseRatio: Double);
begin
  if AAttackRatio < 1.0E-6 then AAttackRatio := 1.0E-6;
  if ADecayReleaseRatio < 1.0E-9 then ADecayReleaseRatio := 1.0E-9;
  FTargetRatioA := AAttackRatio;
  FTargetRatioDR := ADecayReleaseRatio;
  Recalc;
end;

procedure TADSR.Gate(AOn: Boolean);
begin
  if AOn then
  begin
    if FStage = asIdle then FValue := 0;
    FStage := asAttack;
  end
  else if FStage <> asIdle then
    FStage := asRelease;
end;

procedure TADSR.NoteOn;
begin
  Gate(True);
end;

procedure TADSR.NoteOff;
begin
  Gate(False);
end;

procedure TADSR.HardReset;
begin
  FStage := asIdle;
  FValue := 0;
end;

function TADSR.Process: Single;
begin
  case FStage of
    asIdle:
      FValue := 0;
    asAttack:
      begin
        FValue := FAttackBase + FValue * FAttackCoef;
        if FValue >= 1.0 then
        begin
          FValue := 1.0;
          FStage := asDecay;
        end;
      end;
    asDecay:
      begin
        FValue := FDecayBase + FValue * FDecayCoef;
        if FValue <= FSustain then
        begin
          FValue := FSustain;
          FStage := asSustain;
        end;
      end;
    asSustain:
      FValue := FSustain;
    asRelease:
      begin
        FValue := FReleaseBase + FValue * FReleaseCoef;
        if FValue <= 0.0 then
        begin
          FValue := 0.0;
          FStage := asIdle;
        end;
      end;
  end;
  Result := FValue;
end;

procedure TADSR.ProcessBlockMul(ABuf: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    ABuf[i] := ABuf[i] * Process;
end;

function TADSR.IsActive: Boolean;
begin
  Result := FStage <> asIdle;
end;

{ ---------------- TEnvelopeFollower ---------------- }

procedure TEnvelopeFollower.Init(ASampleRate: Double);
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FSampleRate := ASampleRate;
  FMode := fmPeak;
  FEnv := 0;
  FRmsSq := 0;
  SetTimes(5, 100);
end;

procedure TEnvelopeFollower.SetTimes(AAttackMs, AReleaseMs: Double);
begin
  if AAttackMs < 0 then AAttackMs := 0;
  if AReleaseMs < 0 then AReleaseMs := 0;
  if AAttackMs < 1.0E-4 then FAttackCoef := 0.0
  else FAttackCoef := Exp(-1.0 / ((AAttackMs * 0.001) * FSampleRate));
  if AReleaseMs < 1.0E-4 then FReleaseCoef := 0.0
  else FReleaseCoef := Exp(-1.0 / ((AReleaseMs * 0.001) * FSampleRate));
end;

procedure TEnvelopeFollower.SetMode(AMode: TFollowerMode);
begin
  FMode := AMode;
end;

procedure TEnvelopeFollower.Reset;
begin
  FEnv := 0;
  FRmsSq := 0;
end;

function TEnvelopeFollower.Process(AX: Single): Single;
var
  inp, coef: Double;
begin
  if FMode = fmRms then
  begin
    { one-pole mean-square then sqrt }
    coef := FReleaseCoef;
    FRmsSq := (1.0 - coef) * (Double(AX) * Double(AX)) + coef * FRmsSq;
    if FRmsSq < 0 then FRmsSq := 0;
    inp := Sqrt(FRmsSq);
    FEnv := inp;
  end
  else
  begin
    inp := Abs(AX);
    if inp > FEnv then
      FEnv := inp + FAttackCoef * (FEnv - inp)
    else
      FEnv := inp + FReleaseCoef * (FEnv - inp);
  end;
  if FEnv < DSP_DENORMAL_FLOOR then FEnv := 0;
  Result := FEnv;
end;

function TEnvelopeFollower.ProcessBlock(ABuf: PSingle; AFrames: Integer): Single;
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    Process(ABuf[i]);
  Result := FEnv;
end;

function TEnvelopeFollower.EnvelopeDb: Double;
begin
  Result := LinearToDb(FEnv);
end;

{ ---------------- TAREnvelope ---------------- }

procedure TAREnvelope.Init(ASampleRate: Double; AAttackMs, AReleaseMs: Double);
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FSampleRate := ASampleRate;
  if AAttackMs < 1.0E-4 then FCoefUp := 0.0
  else FCoefUp := Exp(-1.0 / ((AAttackMs * 0.001) * FSampleRate));
  if AReleaseMs < 1.0E-4 then FCoefDn := 0.0
  else FCoefDn := Exp(-1.0 / ((AReleaseMs * 0.001) * FSampleRate));
  FValue := 0;
  FTarget := 0;
end;

procedure TAREnvelope.SetTarget(AValue: Double);
begin
  FTarget := AValue;
end;

procedure TAREnvelope.SetImmediate(AValue: Double);
begin
  FTarget := AValue;
  FValue := AValue;
end;

function TAREnvelope.Process: Single;
var
  coef: Double;
begin
  if FTarget > FValue then coef := FCoefUp else coef := FCoefDn;
  FValue := FTarget + (FValue - FTarget) * coef;
  if Abs(FValue - FTarget) < DSP_DENORMAL_FLOOR then FValue := FTarget;
  Result := FValue;
end;

procedure TAREnvelope.ProcessBlockMul(ABuf: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    ABuf[i] := ABuf[i] * Process;
end;

function TAREnvelope.Settled: Boolean;
begin
  Result := Abs(FValue - FTarget) < 1.0E-6;
end;

end.
