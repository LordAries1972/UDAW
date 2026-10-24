unit UDAW.DSP.Meter;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 3 - metering primitives. No third-party code; the loudness path follows
  ITU-R BS.1770-4 / EBU R128 directly.

  * TPeakMeter       - sample peak with instant attack, dB/s release, and an
                       independent peak-hold that decays after a hold time
  * TRmsMeter        - true sliding-window RMS (default 300 ms)
  * TTruePeakMeter   - 4x oversampled peak (inter-sample peak) via a polyphase
                       windowed-sinc FIR; reports dBTP
  * TLoudnessMeter   - K-weighted momentary (400 ms) / short-term (3 s) / gated
                       integrated loudness in LUFS, plus max M/S
  * TCorrelationMeter- sliding L/R correlation coefficient (-1..+1)

  Everything is mono-per-instance except the stereo loudness / correlation
  meters. State is heap-light; the sliding buffers are allocated once at Init. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.Filters;

const
  METER_MIN_DB = -120.0;

type
  TPeakMeter = record
  private
    FSampleRate: Double;
    FReleasePerSample: Double;   // linear multiplier per sample
    FValue: Double;
    FHold: Double;
    FHoldSamplesLeft: Integer;
    FHoldSamples: Integer;
    FHoldDecayPerSample: Double;
  public
    procedure Init(ASampleRate: Double; AReleaseDbPerSec: Double = 20.0;
      AHoldMs: Double = 1500.0; AHoldDecayDbPerSec: Double = 10.0);
    procedure Reset;
    procedure Push(AX: Single); inline;
    procedure PushBlock(ABuf: PSingle; AFrames: Integer);
    function Value: Double;        // linear, ballistic
    function ValueDb: Double;
    function HoldValue: Double;
    function HoldDb: Double;
  end;

  TRmsMeter = record
  private
    FBuf: array of Double;    // ring of squared samples
    FHead: Integer;
    FCount: Integer;
    FSum: Double;
    FWindow: Integer;
  public
    procedure Init(ASampleRate: Double; AWindowMs: Double = 300.0);
    procedure Reset;
    procedure Push(AX: Single); inline;
    procedure PushBlock(ABuf: PSingle; AFrames: Integer);
    function Value: Double;       // linear RMS
    function ValueDb: Double;
    property WindowSamples: Integer read FWindow;
  end;

  TTruePeakMeter = record
  private
    FCoeffs: array of Double;    // polyphase FIR, [phase*taps + tap]
    FPhases: Integer;
    FTaps: Integer;
    FHist: array of Single;      // last FTaps input samples (ring)
    FHead: Integer;
    FPeak: Double;
  public
    procedure Init(ASampleRate: Double; AOversample: Integer = 4; ATaps: Integer = 24);
    procedure Reset;
    procedure Push(AX: Single);
    procedure PushBlock(ABuf: PSingle; AFrames: Integer);
    function ValueDb: Double;     // dBTP (>0 possible)
    function ValueLinear: Double;
  end;

  TLoudnessMeter = class
  private
    FSampleRate: Double;
    FChannels: Integer;
    FWeights: array of Double;
    FPre: array of TBiquad;      // stage 1 (shelf), one per channel
    FRlb: array of TBiquad;      // stage 2 (highpass), one per channel
    FSubLen: Integer;            // 100 ms in samples
    FSubPos: Integer;
    FSubSumSq: array of Double;  // per-channel accumulator for current sub-block
    FSubEnergies: array of Double;  // ring of recent sub-block energies (E = sum_ch G*ms)
    FSubRingHead: Integer;
    FSubRingCount: Integer;
    FGateEnergies: array of Double; // one per 400 ms gating block (step 100 ms)
    FGateCount: Integer;
    FMaxMomentary: Double;
    FMaxShort: Double;
    procedure SetPrefilters;
    function BlockLoudnessFromEnergy(AEnergy: Double): Double;
    function MeanOfLastSubEnergies(ACount: Integer): Double;
  public
    constructor Create(ASampleRate: Double; AChannels: Integer = 2);
    procedure Reset;
    procedure PushFrame(const ASamples: array of Single);
    procedure PushPlanar(const APlanar: TAudioPlanar; AFrames: Integer);
    function Momentary: Double;      // LUFS over the last 400 ms
    function ShortTerm: Double;      // LUFS over the last 3 s
    function Integrated: Double;     // gated LUFS over everything pushed
    function MaxMomentary: Double;
    function MaxShortTerm: Double;
    property Channels: Integer read FChannels;
  end;

  TCorrelationMeter = record
  private
    FL, FR: array of Double;
    FHead: Integer;
    FCount: Integer;
    FSumLR, FSumLL, FSumRR: Double;
    FWindow: Integer;
  public
    procedure Init(ASampleRate: Double; AWindowMs: Double = 300.0);
    procedure Reset;
    procedure Push(AL, AR: Single);
    procedure PushBlock(AL, AR: PSingle; AFrames: Integer);
    function Value: Double;   // -1..+1
  end;

function SafeDb(ALinear: Double): Double;

implementation


uses
  UDAW.DSP.MathTables;

function SafeDb(ALinear: Double): Double;
begin
  if ALinear <= 0 then
    Result := METER_MIN_DB
  else
  begin
    Result := 20.0 * FastLog10(ALinear);
    if Result < METER_MIN_DB then Result := METER_MIN_DB;
  end;
end;

{ ---------------- TPeakMeter ---------------- }

procedure TPeakMeter.Init(ASampleRate, AReleaseDbPerSec, AHoldMs, AHoldDecayDbPerSec: Double);
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FSampleRate := ASampleRate;
  { convert dB/s to a per-sample linear multiplier: 10^(-(db/s)/(20*fs)) }
  FReleasePerSample := Power(10.0, -AReleaseDbPerSec / (20.0 * FSampleRate));
  FHoldDecayPerSample := Power(10.0, -AHoldDecayDbPerSec / (20.0 * FSampleRate));
  FHoldSamples := Round(AHoldMs * 0.001 * FSampleRate);
  Reset;
end;

procedure TPeakMeter.Reset;
begin
  FValue := 0;
  FHold := 0;
  FHoldSamplesLeft := 0;
end;

procedure TPeakMeter.Push(AX: Single);
var
  a: Double;
begin
  a := Abs(AX);
  if a >= FValue then
    FValue := a
  else
  begin
    FValue := FValue * FReleasePerSample;
    if FValue < DSP_DENORMAL_FLOOR then FValue := 0;
  end;

  if a >= FHold then
  begin
    FHold := a;
    FHoldSamplesLeft := FHoldSamples;
  end
  else if FHoldSamplesLeft > 0 then
    Dec(FHoldSamplesLeft)
  else
  begin
    FHold := FHold * FHoldDecayPerSample;
    if FHold < DSP_DENORMAL_FLOOR then FHold := 0;
  end;
end;

procedure TPeakMeter.PushBlock(ABuf: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    Push(ABuf[i]);
end;

function TPeakMeter.Value: Double;
begin
  Result := FValue;
end;

function TPeakMeter.ValueDb: Double;
begin
  Result := SafeDb(FValue);
end;

function TPeakMeter.HoldValue: Double;
begin
  Result := FHold;
end;

function TPeakMeter.HoldDb: Double;
begin
  Result := SafeDb(FHold);
end;

{ ---------------- TRmsMeter ---------------- }

procedure TRmsMeter.Init(ASampleRate, AWindowMs: Double);
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FWindow := Round(AWindowMs * 0.001 * ASampleRate);
  if FWindow < 1 then FWindow := 1;
  SetLength(FBuf, FWindow);
  Reset;
end;

procedure TRmsMeter.Reset;
var
  i: Integer;
begin
  for i := 0 to High(FBuf) do FBuf[i] := 0;
  FHead := 0;
  FCount := 0;
  FSum := 0;
end;

procedure TRmsMeter.Push(AX: Single);
var
  sq: Double;
begin
  sq := Double(AX) * Double(AX);
  FSum := FSum - FBuf[FHead] + sq;
  FBuf[FHead] := sq;
  Inc(FHead);
  if FHead >= FWindow then FHead := 0;
  if FCount < FWindow then Inc(FCount);
  if FSum < 0 then FSum := 0;
end;

procedure TRmsMeter.PushBlock(ABuf: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    Push(ABuf[i]);
end;

function TRmsMeter.Value: Double;
begin
  if FCount = 0 then Exit(0);
  Result := Sqrt(FSum / FCount);
end;

function TRmsMeter.ValueDb: Double;
begin
  Result := SafeDb(Value);
end;

{ ---------------- TTruePeakMeter ---------------- }

procedure TTruePeakMeter.Init(ASampleRate: Double; AOversample, ATaps: Integer);
var
  ph, t, idx: Integer;
  x, w: Double;
begin
  if AOversample < 2 then AOversample := 2;
  if AOversample > 8 then AOversample := 8;
  if ATaps < 8 then ATaps := 8;
  FPhases := AOversample;
  FTaps := ATaps;

  { Each phase is a fractional-delay windowed-sinc interpolator that
    reconstructs the band-limited signal at offset ph/FPhases between input
    samples; the pass-band therefore extends to the input Nyquist (cutoff 1.0).
    Per-phase DC normalisation removes the window's small gain error so a
    full-scale low-frequency tone reads 0 dBTP. }
  SetLength(FCoeffs, FPhases * FTaps);
  for ph := 0 to FPhases - 1 do
  begin
    for t := 0 to FTaps - 1 do
    begin
      x := (t - (FTaps div 2)) + (ph / FPhases);
      if Abs(x) >= (FTaps div 2) then
        w := 0
      else
        w := 0.42
           + 0.5  * Cos(DSP_PI * x / (FTaps div 2))
           + 0.08 * Cos(2.0 * DSP_PI * x / (FTaps div 2));
      idx := ph * FTaps + t;
      FCoeffs[idx] := SincNorm(x) * w;
    end;
    x := 0;
    for t := 0 to FTaps - 1 do x := x + FCoeffs[ph * FTaps + t];
    if x <> 0 then
      for t := 0 to FTaps - 1 do
        FCoeffs[ph * FTaps + t] := FCoeffs[ph * FTaps + t] / x;
  end;

  SetLength(FHist, FTaps);
  Reset;
end;

procedure TTruePeakMeter.Reset;
var
  i: Integer;
begin
  for i := 0 to High(FHist) do FHist[i] := 0;
  FHead := 0;
  FPeak := 0;
end;

procedure TTruePeakMeter.Push(AX: Single);
var
  ph, t, tail: Integer;
  acc, a: Double;
  h: PSingle;
  c: PDouble;
begin
  FHist[FHead] := AX;
  Inc(FHead);
  if FHead >= FTaps then FHead := 0;

  { history is a ring read oldest -> newest starting at FHead: two straight
    runs (FHead..end, then 0..FHead-1) replace a per-tap wrap }
  tail := FTaps - FHead;
  for ph := 0 to FPhases - 1 do
  begin
    acc := 0;
    c := @FCoeffs[ph * FTaps];
    h := @FHist[FHead];
    for t := 0 to tail - 1 do
      acc := acc + h[t] * c[t];
    if FHead > 0 then
    begin
      h := @FHist[0];
      c := @FCoeffs[ph * FTaps + tail];
      for t := 0 to FHead - 1 do
        acc := acc + h[t] * c[t];
    end;
    a := Abs(acc);
    if a > FPeak then FPeak := a;
  end;
end;

procedure TTruePeakMeter.PushBlock(ABuf: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    Push(ABuf[i]);
end;

function TTruePeakMeter.ValueLinear: Double;
begin
  Result := FPeak;
end;

function TTruePeakMeter.ValueDb: Double;
begin
  if FPeak <= 0 then Exit(METER_MIN_DB);
  Result := 20.0 * FastLog10(FPeak);
end;

{ ---------------- TLoudnessMeter (BS.1770-4) ---------------- }

constructor TLoudnessMeter.Create(ASampleRate: Double; AChannels: Integer);
var
  ch: Integer;
begin
  inherited Create;
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  if AChannels < 1 then AChannels := 1;
  FSampleRate := ASampleRate;
  FChannels := AChannels;

  SetLength(FWeights, FChannels);
  for ch := 0 to FChannels - 1 do
    FWeights[ch] := 1.0;             // L/R/C = 1.0 (surrounds would be 1.41)

  SetLength(FPre, FChannels);
  SetLength(FRlb, FChannels);
  SetLength(FSubSumSq, FChannels);
  SetPrefilters;

  FSubLen := Round(0.1 * FSampleRate);   // 100 ms
  if FSubLen < 1 then FSubLen := 1;
  SetLength(FSubEnergies, 30);            // 3 s of 100 ms sub-blocks
  Reset;
end;

procedure TLoudnessMeter.SetPrefilters;
var
  ch: Integer;
  K, Vh, Vb, a0s, den: Double;
  b0, b1, b2, a1, a2: Double;
  f0, Q, G: Double;
begin
  { Stage 1: high-shelf pre-filter }
  f0 := 1681.9744509555319;
  Q  := 0.7071752369554196;
  G  := 3.999843853973347;      // dB
  K := Tan(DSP_PI * f0 / FSampleRate);
  Vh := Power(10.0, G / 20.0);
  Vb := Power(Vh, 0.4996667741545416);
  a0s := 1.0 + K / Q + K * K;
  b0 := (Vh + Vb * K / Q + K * K) / a0s;
  b1 := 2.0 * (K * K - Vh) / a0s;
  b2 := (Vh - Vb * K / Q + K * K) / a0s;
  a1 := 2.0 * (K * K - 1.0) / a0s;
  a2 := (1.0 - K / Q + K * K) / a0s;
  for ch := 0 to FChannels - 1 do
  begin
    FPre[ch].Init(FSampleRate);
    FPre[ch].SetCoeffs(b0, b1, b2, 1.0, a1, a2);
  end;

  { Stage 2: RLB high-pass }
  f0 := 38.13547087602444;
  Q  := 0.5003270373238773;
  K := Tan(DSP_PI * f0 / FSampleRate);
  den := 1.0 + K / Q + K * K;
  b0 := 1.0;
  b1 := -2.0;
  b2 := 1.0;
  a1 := 2.0 * (K * K - 1.0) / den;
  a2 := (1.0 - K / Q + K * K) / den;
  for ch := 0 to FChannels - 1 do
  begin
    FRlb[ch].Init(FSampleRate);
    FRlb[ch].SetCoeffs(b0, b1, b2, 1.0, a1, a2);
  end;
end;

procedure TLoudnessMeter.Reset;
var
  ch: Integer;
begin
  for ch := 0 to FChannels - 1 do
  begin
    FPre[ch].Reset;
    FRlb[ch].Reset;
    FSubSumSq[ch] := 0;
  end;
  FSubPos := 0;
  FSubRingHead := 0;
  FSubRingCount := 0;
  SetLength(FGateEnergies, 0);
  FGateCount := 0;
  FMaxMomentary := METER_MIN_DB;
  FMaxShort := METER_MIN_DB;
end;

function TLoudnessMeter.BlockLoudnessFromEnergy(AEnergy: Double): Double;
begin
  if AEnergy <= 0 then Exit(METER_MIN_DB);
  Result := -0.691 + 10.0 * FastLog10(AEnergy);
end;

function TLoudnessMeter.MeanOfLastSubEnergies(ACount: Integer): Double;
var
  i, n, idx: Integer;
  acc: Double;
begin
  n := FSubRingCount;
  if n > ACount then n := ACount;
  if n = 0 then Exit(0);
  acc := 0;
  for i := 1 to n do
  begin
    idx := FSubRingHead - i;
    while idx < 0 do idx := idx + Length(FSubEnergies);
    acc := acc + FSubEnergies[idx];
  end;
  Result := acc / n;
end;

procedure TLoudnessMeter.PushFrame(const ASamples: array of Single);
var
  ch: Integer;
  x, e, mMom, mShort: Double;
begin
  for ch := 0 to FChannels - 1 do
  begin
    if ch <= High(ASamples) then x := ASamples[ch] else x := 0;
    x := FRlb[ch].ProcessSample(FPre[ch].ProcessSample(x));
    FSubSumSq[ch] := FSubSumSq[ch] + x * x;
  end;
  Inc(FSubPos);
  if FSubPos < FSubLen then Exit;

  { close a 100 ms sub-block }
  e := 0;
  for ch := 0 to FChannels - 1 do
  begin
    e := e + FWeights[ch] * (FSubSumSq[ch] / FSubLen);
    FSubSumSq[ch] := 0;
  end;
  FSubPos := 0;

  FSubEnergies[FSubRingHead] := e;
  FSubRingHead := (FSubRingHead + 1) mod Length(FSubEnergies);
  if FSubRingCount < Length(FSubEnergies) then Inc(FSubRingCount);

  { a gating block = mean of the last 4 sub-blocks (400 ms, hop 100 ms) }
  if FSubRingCount >= 4 then
  begin
    if FGateCount >= Length(FGateEnergies) then
      SetLength(FGateEnergies, (FGateCount + 1) * 2);
    FGateEnergies[FGateCount] := MeanOfLastSubEnergies(4);
    Inc(FGateCount);
  end;

  mMom := BlockLoudnessFromEnergy(MeanOfLastSubEnergies(4));
  if (FSubRingCount >= 4) and (mMom > FMaxMomentary) then FMaxMomentary := mMom;
  mShort := BlockLoudnessFromEnergy(MeanOfLastSubEnergies(30));
  if (FSubRingCount >= 30) and (mShort > FMaxShort) then FMaxShort := mShort;
end;

procedure TLoudnessMeter.PushPlanar(const APlanar: TAudioPlanar; AFrames: Integer);
var
  i, ch: Integer;
  frame: array of Single;
begin
  SetLength(frame, FChannels);
  for i := 0 to AFrames - 1 do
  begin
    for ch := 0 to FChannels - 1 do
      if ch < Length(APlanar) then frame[ch] := APlanar[ch][i] else frame[ch] := 0;
    PushFrame(frame);
  end;
end;

function TLoudnessMeter.Momentary: Double;
begin
  Result := BlockLoudnessFromEnergy(MeanOfLastSubEnergies(4));
end;

function TLoudnessMeter.ShortTerm: Double;
begin
  Result := BlockLoudnessFromEnergy(MeanOfLastSubEnergies(30));
end;

function TLoudnessMeter.Integrated: Double;
var
  i, n: Integer;
  sumAbs: Double;
  cntAbs: Integer;
  relThresh, sumRel: Double;
  cntRel: Integer;
  lj: Double;
begin
  if FGateCount = 0 then Exit(METER_MIN_DB);

  { absolute gate at -70 LUFS }
  sumAbs := 0; cntAbs := 0;
  for i := 0 to FGateCount - 1 do
  begin
    lj := BlockLoudnessFromEnergy(FGateEnergies[i]);
    if lj >= -70.0 then
    begin
      sumAbs := sumAbs + FGateEnergies[i];
      Inc(cntAbs);
    end;
  end;
  if cntAbs = 0 then Exit(METER_MIN_DB);

  { relative gate at (mean loudness of surviving blocks) - 10 LU }
  relThresh := BlockLoudnessFromEnergy(sumAbs / cntAbs) - 10.0;
  sumRel := 0; cntRel := 0;
  for i := 0 to FGateCount - 1 do
  begin
    lj := BlockLoudnessFromEnergy(FGateEnergies[i]);
    if (lj >= -70.0) and (lj >= relThresh) then
    begin
      sumRel := sumRel + FGateEnergies[i];
      Inc(cntRel);
    end;
  end;
  if cntRel = 0 then
  begin
    n := cntAbs;
    Result := BlockLoudnessFromEnergy(sumAbs / n);
  end
  else
    Result := BlockLoudnessFromEnergy(sumRel / cntRel);
end;

function TLoudnessMeter.MaxMomentary: Double;
begin
  Result := FMaxMomentary;
end;

function TLoudnessMeter.MaxShortTerm: Double;
begin
  Result := FMaxShort;
end;

{ ---------------- TCorrelationMeter ---------------- }

procedure TCorrelationMeter.Init(ASampleRate, AWindowMs: Double);
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FWindow := Round(AWindowMs * 0.001 * ASampleRate);
  if FWindow < 1 then FWindow := 1;
  SetLength(FL, FWindow);
  SetLength(FR, FWindow);
  Reset;
end;

procedure TCorrelationMeter.Reset;
var
  i: Integer;
begin
  for i := 0 to FWindow - 1 do begin FL[i] := 0; FR[i] := 0; end;
  FHead := 0;
  FCount := 0;
  FSumLR := 0; FSumLL := 0; FSumRR := 0;
end;

procedure TCorrelationMeter.Push(AL, AR: Single);
var
  ol, orr: Double;
begin
  ol := FL[FHead];
  orr := FR[FHead];
  FSumLR := FSumLR - ol * orr + Double(AL) * Double(AR);
  FSumLL := FSumLL - ol * ol + Double(AL) * Double(AL);
  FSumRR := FSumRR - orr * orr + Double(AR) * Double(AR);
  FL[FHead] := AL;
  FR[FHead] := AR;
  FHead := FHead + 1;
  if FHead >= FWindow then FHead := 0;
  if FCount < FWindow then Inc(FCount);
end;

procedure TCorrelationMeter.PushBlock(AL, AR: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    Push(AL[i], AR[i]);
end;

function TCorrelationMeter.Value: Double;
var
  den: Double;
begin
  if FCount = 0 then Exit(0);
  den := Sqrt(FSumLL * FSumRR);
  if den < 1.0E-20 then Exit(0);
  Result := FSumLR / den;
  if Result > 1 then Result := 1 else if Result < -1 then Result := -1;
end;

end.
