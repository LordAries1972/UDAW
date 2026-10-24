unit UDAW.DSP.Dynamics;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 10 - core dynamics processors (plan section 11): compressor, limiter,
  downward expander, noise gate and de-esser in one stereo-linked processor.

  The detector is the Phase 3 TEnvelopeFollower over a mono key signal (the
  channel-summed input, or an external sidechain buffer, or - for the de-esser
  - a high-passed copy of the input). A soft-knee static curve turns the
  detector level into a target gain-reduction in dB; the follower's own
  attack / release provide the ballistics, plus a hold counter for the gate.
  Makeup gain is applied after. Nothing allocates after Configure; all state is
  value-type per instance. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.Filters, UDAW.DSP.Envelope;

type
  TDynamicsMode = (dynCompressor, dynLimiter, dynExpander, dynGate, dynDeEsser, dynDucker);

  TDynamicsProcessor = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FMode: TDynamicsMode;
    FThresholdDb: Double;
    FRatio: Double;
    FKneeDb: Double;
    FAttackMs: Double;
    FReleaseMs: Double;
    FMakeupDb: Double;
    FHoldMs: Double;
    FRangeDb: Double;         // expander / gate floor (max attenuation)
    FSideHpHz: Double;        // de-esser detector high-pass
    FFollower: TEnvelopeFollower;
    FSideHp: TBiquad;
    FGainSmoothCoef: Double;  // extra one-pole on the gain in linear domain
    FCurGainLin: Double;
    FHoldSamplesMax: Integer;
    FHoldCounter: Integer;
    FLastGrDb: Double;
    FDuckAtk, FDuckRel, FDuckHeldLin: Double;   // ducker gain ballistics
    procedure Recalc;
    function StaticGainDb(ALevelDb: Double): Double;
  public
    constructor Create;
    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;

    procedure SetParams(AMode: TDynamicsMode; AThresholdDb, ARatio, AKneeDb,
      AAttackMs, AReleaseMs, AMakeupDb: Double);
    procedure SetGateParams(AHoldMs, ARangeDb: Double);
    procedure SetDeEsserFreq(AHz: Double);

    { Process AFrames of planar audio in place. AIn / AOut are open arrays of
      channel pointers (may alias). ADetector, when non-empty, is an external
      sidechain key (channel pointers); when empty the key is taken from AIn. }
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer;
      const ADetector: array of PSingle);

    function CurrentGainReductionDb: Double;   // >= 0, amount of attenuation
    { static input->output level curve in dB (for editor displays) }
    function StaticTransferDb(AInDb: Double): Double;

    property Mode: TDynamicsMode read FMode;
    property ThresholdDb: Double read FThresholdDb;
    property Ratio: Double read FRatio;
  end;

function DynamicsModeId(AMode: TDynamicsMode): string;
function DynamicsModeFromId(const AId: string; out AMode: TDynamicsMode): Boolean;

implementation


uses
  UDAW.DSP.MathTables;

function DynamicsModeId(AMode: TDynamicsMode): string;
begin
  case AMode of
    dynLimiter:  Result := 'limiter';
    dynExpander: Result := 'expander';
    dynGate:     Result := 'gate';
    dynDeEsser:  Result := 'deesser';
    dynDucker:   Result := 'ducker';
  else
    Result := 'compressor';
  end;
end;

function DynamicsModeFromId(const AId: string; out AMode: TDynamicsMode): Boolean;
var
  m: TDynamicsMode;
begin
  for m := Low(TDynamicsMode) to High(TDynamicsMode) do
    if SameText(AId, DynamicsModeId(m)) then
    begin
      AMode := m;
      Exit(True);
    end;
  Result := False;
end;

{ ================= TDynamicsProcessor ================= }

constructor TDynamicsProcessor.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  FMode := dynCompressor;
  FThresholdDb := -18.0;
  FRatio := 3.0;
  FKneeDb := 6.0;
  FAttackMs := 10.0;
  FReleaseMs := 120.0;
  FMakeupDb := 0.0;
  FHoldMs := 20.0;
  FRangeDb := -60.0;
  FSideHpHz := 6000.0;
  FCurGainLin := 1.0;
  FLastGrDb := 0.0;
end;

procedure TDynamicsProcessor.Configure(ASampleRate, AChannels: Integer);
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  FFollower.Init(FSampleRate);
  FFollower.SetMode(fmPeak);
  FSideHp.Init(FSampleRate);
  Recalc;
  Reset;
end;

procedure TDynamicsProcessor.Recalc;
begin
  if FRatio < 1.0 then FRatio := 1.0;
  if FKneeDb < 0 then FKneeDb := 0;
  if FMode = dynDucker then
  begin
    { the key is followed quickly; attack / release shape the duck itself }
    FFollower.SetTimes(0.5, 20.0);
    FDuckAtk := FastExp(-1.0 / (Max(0.1, FAttackMs) * 0.001 * FSampleRate));
    FDuckRel := FastExp(-1.0 / (Max(1.0, FReleaseMs) * 0.001 * FSampleRate));
  end
  else
    FFollower.SetTimes(Max(0.05, FAttackMs), Max(1.0, FReleaseMs));
  FSideHp.SetParams(bqHighpass, Max(200.0, Min(FSideHpHz, FSampleRate * 0.45)), 0.70710678);
  { a short extra smoothing pole so the gain itself never steps }
  FGainSmoothCoef := FastExp(-1.0 / (0.001 * 2.0 * FSampleRate));
  FHoldSamplesMax := Round(Max(0.0, FHoldMs) * 0.001 * FSampleRate);
end;

procedure TDynamicsProcessor.Reset;
begin
  FFollower.Reset;
  FSideHp.Reset;
  FCurGainLin := 1.0;
  FHoldCounter := 0;
  FLastGrDb := 0.0;
  FDuckHeldLin := 1.0;
end;

procedure TDynamicsProcessor.SetParams(AMode: TDynamicsMode; AThresholdDb, ARatio,
  AKneeDb, AAttackMs, AReleaseMs, AMakeupDb: Double);
begin
  FMode := AMode;
  FThresholdDb := AThresholdDb;
  FRatio := ARatio;
  FKneeDb := AKneeDb;
  FAttackMs := AAttackMs;
  FReleaseMs := AReleaseMs;
  FMakeupDb := AMakeupDb;
  Recalc;
end;

procedure TDynamicsProcessor.SetGateParams(AHoldMs, ARangeDb: Double);
begin
  FHoldMs := AHoldMs;
  FRangeDb := ARangeDb;
  Recalc;
end;

procedure TDynamicsProcessor.SetDeEsserFreq(AHz: Double);
begin
  FSideHpHz := AHz;
  Recalc;
end;

function TDynamicsProcessor.StaticGainDb(ALevelDb: Double): Double;
var
  x, T, W, d: Double;
begin
  Result := 0.0;
  x := ALevelDb;
  T := FThresholdDb;
  W := FKneeDb;
  case FMode of
    dynCompressor, dynLimiter, dynDeEsser:
      begin
        { standard downward compressor with quadratic soft knee }
        if 2.0 * (x - T) < -W then
          Result := 0.0
        else if (W > 0) and (2.0 * Abs(x - T) <= W) then
        begin
          d := x - T + W * 0.5;
          Result := (1.0 / FRatio - 1.0) * d * d / (2.0 * W);
        end
        else
          Result := (x - T) * (1.0 / FRatio - 1.0);
      end;
    dynExpander, dynGate:
      begin
        { mirror of the above for downward expansion below the threshold }
        if 2.0 * (x - T) > W then
          Result := 0.0
        else if (W > 0) and (2.0 * Abs(x - T) <= W) then
        begin
          d := x - T - W * 0.5;
          Result := (1.0 - FRatio) * d * d / (2.0 * W);
        end
        else
          Result := (x - T) * (FRatio - 1.0);
        if Result < FRangeDb then Result := FRangeDb;
      end;
    dynDucker:
      begin
        { key above the threshold pulls the signal down by up to RangeDb (a
          negative number); the knee width is the transition zone }
        if W < 1.0 then W := 1.0;
        d := (x - T) / W + 0.5;
        if d <= 0 then d := 0 else if d >= 1 then d := 1
        else d := d * d * (3.0 - 2.0 * d);
        Result := Min(0.0, FRangeDb) * d;
      end;
  end;
end;

procedure TDynamicsProcessor.ProcessBlock(const AIn, AOut: array of PSingle;
  AFrames: Integer; const ADetector: array of PSingle);
var
  i, ch, nc, nd: Integer;
  key, envLin, envDb, grDb, targetLin, makeup: Double;
  wantOpen: Boolean;
  s, invNd, invNc, lastEnvLin, lastEnvDb, lastGrDb, lastTargetLin, gainMakeup: Double;
begin
  nc := Length(AIn);
  if nc = 0 then Exit;
  nd := Length(ADetector);
  makeup := DbToLinear(FMakeupDb);
  invNc := 1.0 / nc;
  if nd > 0 then invNd := 1.0 / nd else invNd := 0.0;
  { transcendental results are reused while their input is unchanged (silence,
    steady signals) - identical output, far fewer Log10/Power calls }
  lastEnvLin := -1.0;
  lastEnvDb := 0.0;
  lastGrDb := 1.0;      // grDb is always <= 0, so this never matches
  lastTargetLin := 1.0;

  for i := 0 to AFrames - 1 do
  begin
    { --- build the mono key --- }
    if nd > 0 then
    begin
      key := 0;
      for ch := 0 to nd - 1 do
        key := key + Abs(ADetector[ch][i]);
      key := key * invNd;
    end
    else
    begin
      key := 0;
      for ch := 0 to nc - 1 do
        key := key + Abs(AIn[ch][i]);
      key := key * invNc;
    end;
    if FMode = dynDeEsser then
      key := Abs(FSideHp.ProcessSample(Single(key)));

    envLin := FFollower.Process(Single(key));
    if envLin <> lastEnvLin then
    begin
      if envLin < 1.0E-9 then envDb := -180.0 else envDb := 20.0 * FastLog10(envLin);
      lastEnvLin := envLin;
      lastEnvDb := envDb;
    end
    else
      envDb := lastEnvDb;

    grDb := StaticGainDb(envDb);   // <= 0

    { gate hold: once open, stay open for HoldSamples of sub-threshold signal }
    if FMode = dynGate then
    begin
      wantOpen := envDb >= FThresholdDb;
      if wantOpen then
        FHoldCounter := FHoldSamplesMax
      else if FHoldCounter > 0 then
      begin
        Dec(FHoldCounter);
        grDb := 0.0;
      end;
    end;

    if grDb <> lastGrDb then
    begin
      if grDb = 0.0 then targetLin := 1.0 else targetLin := DbToLinear(grDb);
      lastGrDb := grDb;
      lastTargetLin := targetLin;
    end
    else
      targetLin := lastTargetLin;
    if FMode = dynDucker then
    begin
      { hold the duck for HoldMs after the key drops, then release }
      if grDb < -0.05 then
      begin
        FHoldCounter := FHoldSamplesMax;
        FDuckHeldLin := targetLin;
      end
      else if FHoldCounter > 0 then
      begin
        Dec(FHoldCounter);
        targetLin := FDuckHeldLin;
      end
      else
        FDuckHeldLin := 1.0;
      if targetLin < FCurGainLin then
        FCurGainLin := targetLin + (FCurGainLin - targetLin) * FDuckAtk
      else
        FCurGainLin := targetLin + (FCurGainLin - targetLin) * FDuckRel;
    end
    else
      { one-pole smooth the linear gain (follower already shaped the level, this
        just removes any residual zipper at the knee) }
      FCurGainLin := targetLin + (FCurGainLin - targetLin) * FGainSmoothCoef;
    if Abs(FCurGainLin - targetLin) < DSP_DENORMAL_FLOOR then FCurGainLin := targetLin;

    gainMakeup := FCurGainLin * makeup;
    for ch := 0 to nc - 1 do
    begin
      s := AIn[ch][i] * gainMakeup;
      AOut[ch][i] := Single(FlushDenorm(Single(s)));
    end;
  end;
  { meter value: only the end-of-block gain reduction is ever read }
  if AFrames > 0 then
    FLastGrDb := -20.0 * FastLog10(Max(FCurGainLin, 1.0E-9));
end;

function TDynamicsProcessor.StaticTransferDb(AInDb: Double): Double;
begin
  Result := AInDb + StaticGainDb(AInDb) + FMakeupDb;
end;

function TDynamicsProcessor.CurrentGainReductionDb: Double;
begin
  Result := FLastGrDb;
  if Result < 0 then Result := 0;
end;

end.
