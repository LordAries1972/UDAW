unit UDAW.DSP.Mastering;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 19 - Advanced DSP (plan section, docs/UDAW-Original-Plan.txt lines
  3706-3719): a stereo mastering chain.

  TMasteringChain is always 2-channel (stereo) and processes, in order:

    1. glue/tone shaping    - an internal TMultibandCompressor (Phase 19
                               multiband unit)
    2. stereo width         - mid/side encode, scale the side channel by
                               WidthAmount, decode back to L/R
    3. brick-wall limiting  - an internal TTruePeakMeter (Phase 3) drives a
                               short-lookahead delay + fast-attack/slower-
                               release one-pole gain follower so the output
                               true peak never exceeds CeilingDb
    4. loudness normalize   - an internal TLoudnessMeter (BS.1770 ShortTerm)
                               drives a slow AGC that nudges a running gain
                               toward TargetLufs

  Nothing allocates after Configure. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.Meter, UDAW.DSP.MultibandComp;

type
  TMasteringChain = class
  private
    FSampleRate: Integer;
    FCeilingDb: Double;
    FCeilingLin: Double;
    FTargetLufs: Double;
    FWidthAmount: Double;

    FMultiband: TMultibandCompressor;

    { true-peak limiter stage }
    FTruePeak: array[0..1] of TTruePeakMeter;
    FLimiterDelay: array[0..1] of TAudioSampleArray;   // small lookahead ring
    FLimiterWrite: array[0..1] of Integer;
    FLimiterDelaySamples: Integer;
    FLimiterDelayCap: Integer;
    FLimiterGain: Double;          // current smoothed linear gain
    FLimiterAttackCoef: Double;    // fast, per-sample one-pole toward a lower gain
    FLimiterReleaseCoef: Double;   // slower, per-sample one-pole back toward 1.0

    { loudness-normalize stage }
    FLoudness: TLoudnessMeter;
    FNormGain: Double;             // running AGC gain, linear
    FNormAdaptCoef: Double;        // slow one-pole toward the target each block

    { scratch, sized once }
    FMbOut: array[0..1] of TAudioSampleArray;
    FMbPtr: array[0..1] of PSingle;
    FScratchFrames: Integer;

    procedure EnsureScratch(AFrames: Integer);
    procedure RecalcLimiterCoeffs;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Configure(ASampleRate: Integer);
    procedure Reset;

    procedure SetCeilingDb(ADb: Double);
    procedure SetTargetLufs(ALufs: Double);
    procedure SetWidthAmount(AWidth: Double);

    { Delegates to the internal multiband compressor. }
    procedure SetBandParams(ABand: Integer; AThresholdDb, ARatio, AKneeDb,
      AAttackMs, AReleaseMs, AMakeupDb: Double);
    procedure SetCrossovers(ALowMidHz, AMidHighHz: Double);

    { Exactly 2 channel pointers each (L, R). }
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);

    function CurrentTruePeakDb: Double;
    function CurrentIntegratedLufs: Double;

    property CeilingDb: Double read FCeilingDb;
    property TargetLufs: Double read FTargetLufs;
    property WidthAmount: Double read FWidthAmount;
  end;

implementation

const
  MASTERING_CHANNELS = 2;

{ ================= TMasteringChain ================= }

constructor TMasteringChain.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FCeilingDb := -1.0;
  FCeilingLin := DbToLinear(FCeilingDb);
  FTargetLufs := -14.0;
  FWidthAmount := 1.0;
  FMultiband := TMultibandCompressor.Create;
  FLoudness := TLoudnessMeter.Create(FSampleRate, MASTERING_CHANNELS);
  FLimiterGain := 1.0;
  FNormGain := 1.0;
end;

destructor TMasteringChain.Destroy;
begin
  FMultiband.Free;
  FLoudness.Free;
  inherited Destroy;
end;

procedure TMasteringChain.EnsureScratch(AFrames: Integer);
var
  ch: Integer;
begin
  if AFrames <= FScratchFrames then Exit;
  FScratchFrames := AFrames;
  for ch := 0 to MASTERING_CHANNELS - 1 do
  begin
    SetLength(FMbOut[ch], FScratchFrames);
    FMbPtr[ch] := @FMbOut[ch][0];
  end;
end;

procedure TMasteringChain.RecalcLimiterCoeffs;
begin
  { attack: reach a lower gain target in ~1 ms; release: relax back to unity
    over ~200 ms. Both one-pole time constants in the linear-gain domain. }
  FLimiterAttackCoef := Exp(-1.0 / (0.001 * FSampleRate));
  FLimiterReleaseCoef := Exp(-1.0 / (0.200 * FSampleRate));
  { a few ms of lookahead so the true-peak reading can steer the gain before
    the corresponding sample reaches the output }
  FLimiterDelaySamples := Round(0.003 * FSampleRate);   // 3 ms
  if FLimiterDelaySamples > FLimiterDelayCap - 1 then
    FLimiterDelaySamples := FLimiterDelayCap - 1;
  if FLimiterDelaySamples < 0 then FLimiterDelaySamples := 0;
end;

procedure TMasteringChain.Configure(ASampleRate: Integer);
var
  ch: Integer;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;

  FMultiband.Configure(FSampleRate, MASTERING_CHANNELS);

  for ch := 0 to MASTERING_CHANNELS - 1 do
    FTruePeak[ch].Init(FSampleRate);

  FLimiterDelayCap := Round(0.020 * FSampleRate) + 4;   // 20 ms capacity
  for ch := 0 to MASTERING_CHANNELS - 1 do
  begin
    SetLength(FLimiterDelay[ch], FLimiterDelayCap);
    FLimiterWrite[ch] := 0;
  end;
  RecalcLimiterCoeffs;

  FLoudness.Free;
  FLoudness := TLoudnessMeter.Create(FSampleRate, MASTERING_CHANNELS);

  FScratchFrames := 0;
  EnsureScratch(UDAW_DEFAULT_BUFFER_FRAMES);

  { the normalize stage adapts slowly (a few seconds time constant) so it
    behaves as a gentle long-term AGC, not a fast level-riding compressor;
    this makes it safe to run per-block, in both offline and streaming use,
    without a separate priming/analysis pass. }
  FNormAdaptCoef := Exp(-1.0 / (3.0 * FSampleRate));

  Reset;
end;

procedure TMasteringChain.Reset;
var
  ch, i: Integer;
begin
  FMultiband.Reset;
  for ch := 0 to MASTERING_CHANNELS - 1 do
  begin
    FTruePeak[ch].Reset;
    for i := 0 to High(FLimiterDelay[ch]) do
      FLimiterDelay[ch][i] := 0;
    FLimiterWrite[ch] := 0;
  end;
  FLimiterGain := 1.0;
  FLoudness.Reset;
  FNormGain := 1.0;
end;

procedure TMasteringChain.SetCeilingDb(ADb: Double);
begin
  FCeilingDb := ADb;
  FCeilingLin := DbToLinear(FCeilingDb);
end;

procedure TMasteringChain.SetTargetLufs(ALufs: Double);
begin
  FTargetLufs := ALufs;
end;

procedure TMasteringChain.SetWidthAmount(AWidth: Double);
begin
  if AWidth < 0 then AWidth := 0;
  FWidthAmount := AWidth;
end;

procedure TMasteringChain.SetBandParams(ABand: Integer; AThresholdDb, ARatio,
  AKneeDb, AAttackMs, AReleaseMs, AMakeupDb: Double);
begin
  FMultiband.SetBandParams(ABand, AThresholdDb, ARatio, AKneeDb, AAttackMs,
    AReleaseMs, AMakeupDb);
end;

procedure TMasteringChain.SetCrossovers(ALowMidHz, AMidHighHz: Double);
begin
  FMultiband.SetCrossovers(ALowMidHz, AMidHighHz);
end;

procedure TMasteringChain.ProcessBlock(const AIn, AOut: array of PSingle;
  AFrames: Integer);
var
  i: Integer;
  mid, side: Double;
  l, r: Double;
  frame: array[0..1] of Single;
  tpNowLin, targetGain, g: Double;
  stLufs, errLufs, normTarget: Double;
  rd: Integer;
  delayedL, delayedR: Single;
begin
  if (Length(AIn) < MASTERING_CHANNELS) or (Length(AOut) < MASTERING_CHANNELS) then Exit;
  EnsureScratch(AFrames);

  { --- 1. multiband glue/tone shaping --- }
  FMultiband.ProcessBlock(
    [AIn[0], AIn[1]],
    [FMbPtr[0], FMbPtr[1]],
    AFrames);

  for i := 0 to AFrames - 1 do
  begin
    { --- 2. stereo width via mid/side --- }
    l := FMbOut[0][i];
    r := FMbOut[1][i];
    mid := (l + r) * 0.5;
    side := (l - r) * 0.5;
    side := side * FWidthAmount;
    l := mid + side;
    r := mid - side;

    { --- 3. brick-wall true-peak-safe limiter ---
      Feed the true-peak meters with the pre-limiter signal, derive a target
      gain from how far the true peak sits above the ceiling, then smooth
      that target with a fast attack / slower release one-pole follower and
      apply it to a short-lookahead-delayed copy of the signal so the gain
      has a chance to settle before the corresponding sample is emitted. }
    FTruePeak[0].Push(Single(l));
    FTruePeak[1].Push(Single(r));
    tpNowLin := Max(FTruePeak[0].ValueLinear, FTruePeak[1].ValueLinear);
    if tpNowLin > FCeilingLin then
      targetGain := FCeilingLin / tpNowLin
    else
      targetGain := 1.0;

    if targetGain < FLimiterGain then
      g := FLimiterAttackCoef
    else
      g := FLimiterReleaseCoef;
    FLimiterGain := targetGain + (FLimiterGain - targetGain) * g;
    if FLimiterGain > 1.0 then FLimiterGain := 1.0;
    if FLimiterGain < 0.0 then FLimiterGain := 0.0;

    FLimiterDelay[0][FLimiterWrite[0]] := Single(l);
    FLimiterDelay[1][FLimiterWrite[1]] := Single(r);
    rd := FLimiterWrite[0] - FLimiterDelaySamples;
    while rd < 0 do rd := rd + FLimiterDelayCap;
    delayedL := FLimiterDelay[0][rd];
    rd := FLimiterWrite[1] - FLimiterDelaySamples;
    while rd < 0 do rd := rd + FLimiterDelayCap;
    delayedR := FLimiterDelay[1][rd];
    FLimiterWrite[0] := (FLimiterWrite[0] + 1) mod FLimiterDelayCap;
    FLimiterWrite[1] := (FLimiterWrite[1] + 1) mod FLimiterDelayCap;

    l := delayedL * FLimiterGain;
    r := delayedR * FLimiterGain;

    { --- 4. loudness-normalize (slow AGC toward TargetLufs) --- }
    frame[0] := Single(l);
    frame[1] := Single(r);
    FLoudness.PushFrame(frame);
    stLufs := FLoudness.ShortTerm;
    if stLufs > METER_MIN_DB + 1.0 then
    begin
      errLufs := FTargetLufs - stLufs;           // + means "turn up"
      normTarget := FNormGain * DbToLinear(errLufs);
      { clamp the AGC's own excursion so it cannot fight the limiter or blow
        up on a very quiet/silent lead-in }
      if normTarget > 8.0 then normTarget := 8.0;
      if normTarget < 0.125 then normTarget := 0.125;
      FNormGain := normTarget + (FNormGain - normTarget) * FNormAdaptCoef;
    end;

    l := l * FNormGain;
    r := r * FNormGain;

    { Final hard safety clamp: the smoothed one-pole follower above is the
      musical part of the limiter (it reacts ahead of time thanks to the
      lookahead delay), but being a one-pole it only approaches its target
      asymptotically and the normalize stage can push level back up again -
      so guarantee the CeilingDb contract exactly with a last per-sample
      proportional (stereo-image-preserving) scale-down of any sample that
      still peeks over the ceiling. }
    if Max(Abs(l), Abs(r)) > FCeilingLin then
    begin
      g := FCeilingLin / Max(Abs(l), Abs(r));
      l := l * g;
      r := r * g;
    end;

    AOut[0][i] := Single(FlushDenorm(Single(l)));
    AOut[1][i] := Single(FlushDenorm(Single(r)));
  end;
end;

function TMasteringChain.CurrentTruePeakDb: Double;
begin
  Result := Max(FTruePeak[0].ValueDb, FTruePeak[1].ValueDb);
end;

function TMasteringChain.CurrentIntegratedLufs: Double;
begin
  Result := FLoudness.Integrated;
end;

end.
