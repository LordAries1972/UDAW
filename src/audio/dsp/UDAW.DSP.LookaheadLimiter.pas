unit UDAW.DSP.LookaheadLimiter;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 34 - real lookahead brickwall limiter, distinct from TDynamicsProcessor's
  dynLimiter (which is only a fast-ratio compressor preset with no lookahead
  and no output-peak guarantee).

  Each channel runs a Phase 3 TTruePeakMeter (4x oversampled, so it also
  catches inter-sample peaks) ahead of a lookahead delay line; channels are
  gain-linked (the loudest channel's reading drives every channel's gain, so
  the stereo image never shifts). The gain follower's attack time constant is
  derived from the lookahead time itself, so a full gain-reduction move can
  always complete before the offending sample reaches the output; release is
  the user-facing "how fast does it let go" control. A final per-sample
  proportional clamp (same technique as TMasteringChain) guarantees the
  ceiling exactly even though the one-pole follower only approaches its
  target asymptotically. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.Meter;

const
  LKL_MAX_LOOKAHEAD_MS = 20.0;

type
  TLookaheadLimiter = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FCeilingDb: Double;
    FCeilingLin: Double;
    FReleaseMs: Double;
    FLookaheadMs: Double;

    FTruePeak: array of TTruePeakMeter;
    FDelay: array of array of Single;    // [channel][ring]
    FDelayCap: Integer;
    FDelaySamples: Integer;
    FWrite: Integer;
    FScratch: array of Single;           // per-channel delayed-sample scratch, sized once

    FGain: Double;
    FAttackCoef: Double;
    FReleaseCoef: Double;
    FGainReductionDb: Double;

    procedure RecalcCoeffs;
  public
    constructor Create;
    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;
    procedure SetParams(ACeilingDb, AReleaseMs, ALookaheadMs: Double);
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
    function CurrentGainReductionDb: Double;
  end;

implementation

constructor TLookaheadLimiter.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  FCeilingDb := -0.3;
  FCeilingLin := DbToLinear(FCeilingDb);
  FReleaseMs := 100.0;
  FLookaheadMs := 5.0;
  FGain := 1.0;
end;

procedure TLookaheadLimiter.RecalcCoeffs;
begin
  { the gain follower must be able to fall from unity to any depth within the
    lookahead window, so its attack time constant is tied to that window
    rather than being a separate user control }
  FAttackCoef := Exp(-1.0 / (Max(0.001, FLookaheadMs * 0.001) * FSampleRate));
  FReleaseCoef := Exp(-1.0 / (Max(1.0, FReleaseMs) * 0.001 * FSampleRate));
  FDelaySamples := Round(FLookaheadMs * 0.001 * FSampleRate);
  if FDelaySamples > FDelayCap - 1 then FDelaySamples := FDelayCap - 1;
  if FDelaySamples < 0 then FDelaySamples := 0;
end;

procedure TLookaheadLimiter.Configure(ASampleRate, AChannels: Integer);
var
  ch: Integer;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;

  SetLength(FTruePeak, FChannels);
  for ch := 0 to FChannels - 1 do
    FTruePeak[ch].Init(FSampleRate);

  FDelayCap := Round(LKL_MAX_LOOKAHEAD_MS * 0.001 * FSampleRate) + 4;
  SetLength(FDelay, FChannels);
  for ch := 0 to FChannels - 1 do
    SetLength(FDelay[ch], FDelayCap);
  SetLength(FScratch, FChannels);

  RecalcCoeffs;
  Reset;
end;

procedure TLookaheadLimiter.Reset;
var
  ch, i: Integer;
begin
  for ch := 0 to High(FTruePeak) do
    FTruePeak[ch].Reset;
  for ch := 0 to High(FDelay) do
    for i := 0 to High(FDelay[ch]) do
      FDelay[ch][i] := 0;
  FWrite := 0;
  FGain := 1.0;
  FGainReductionDb := 0.0;
end;

procedure TLookaheadLimiter.SetParams(ACeilingDb, AReleaseMs, ALookaheadMs: Double);
begin
  if ACeilingDb > 0 then ACeilingDb := 0;
  if AReleaseMs < 1.0 then AReleaseMs := 1.0;
  if ALookaheadMs < 0.1 then ALookaheadMs := 0.1
  else if ALookaheadMs > LKL_MAX_LOOKAHEAD_MS then ALookaheadMs := LKL_MAX_LOOKAHEAD_MS;
  FCeilingDb := ACeilingDb;
  FCeilingLin := DbToLinear(FCeilingDb);
  FReleaseMs := AReleaseMs;
  FLookaheadMs := ALookaheadMs;
  if FSampleRate > 0 then RecalcCoeffs;
end;

procedure TLookaheadLimiter.ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
var
  i, ch, nc: Integer;
  tpNowLin, targetGain, coef, peakDelayedLin, g: Double;
  rd: Integer;
begin
  nc := Length(AIn);
  if nc = 0 then Exit;
  if nc > Length(FTruePeak) then nc := Length(FTruePeak);
  if nc > Length(FScratch) then nc := Length(FScratch);

  for i := 0 to AFrames - 1 do
  begin
    tpNowLin := 0;
    for ch := 0 to nc - 1 do
    begin
      FTruePeak[ch].Push(AIn[ch][i]);
      if FTruePeak[ch].ValueLinear > tpNowLin then tpNowLin := FTruePeak[ch].ValueLinear;
    end;

    if tpNowLin > FCeilingLin then
      targetGain := FCeilingLin / tpNowLin
    else
      targetGain := 1.0;

    if targetGain < FGain then coef := FAttackCoef else coef := FReleaseCoef;
    FGain := targetGain + (FGain - targetGain) * coef;
    if FGain > 1.0 then FGain := 1.0;
    if FGain < 0.0 then FGain := 0.0;

    peakDelayedLin := 0;
    for ch := 0 to nc - 1 do
    begin
      FDelay[ch][FWrite] := AIn[ch][i];
      rd := FWrite - FDelaySamples;
      while rd < 0 do Inc(rd, FDelayCap);
      FScratch[ch] := FDelay[ch][rd];
    end;
    FWrite := (FWrite + 1) mod FDelayCap;

    for ch := 0 to nc - 1 do
    begin
      g := FScratch[ch] * FGain;
      if Abs(g) > peakDelayedLin then peakDelayedLin := Abs(g);
    end;
    { final exact-ceiling safety clamp, proportional across channels so the
      stereo/multichannel image is preserved }
    if peakDelayedLin > FCeilingLin then
    begin
      coef := FCeilingLin / peakDelayedLin;
      for ch := 0 to nc - 1 do
        AOut[ch][i] := Single(FlushDenorm(Single(FScratch[ch] * FGain * coef)));
    end
    else
      for ch := 0 to nc - 1 do
        AOut[ch][i] := Single(FlushDenorm(Single(FScratch[ch] * FGain)));
  end;

  FGainReductionDb := LinearToDb(FGain);
end;

function TLookaheadLimiter.CurrentGainReductionDb: Double;
begin
  Result := FGainReductionDb;
end;

end.
