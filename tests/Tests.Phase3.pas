unit Tests.Phase3;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 3 acceptance tests: the internal DSP foundation.

  Covers block/pan/window math and the parameter smoother; fractional-sample
  interpolation kernels; the RBJ biquad family + one-pole + DC blocker + TPT
  state-variable filter (response and stability); the radix-2 FFT (round-trip
  identity, single-bin sine, windowed dBFS calibration); the arbitrary-ratio
  resampler (up / down / identity, frequency and amplitude preservation, length
  ratio); the ADSR / envelope-follower generators; and the meter suite (peak
  ballistics, sliding RMS calibration, true-peak, BS.1770 loudness gating and
  its dB tracking, stereo correlation).

  Requires src/common, src/audio and src/audio/dsp on the search path. }

interface

procedure RegisterPhase3Tests;

implementation

uses
  SysUtils, Math,
  UDAW.Testing,
  UDAW.Audio.Types,
  UDAW.DSP.Math, UDAW.DSP.Interpolation, UDAW.DSP.Filters, UDAW.DSP.FFT,
  UDAW.DSP.Resampler, UDAW.DSP.Envelope, UDAW.DSP.Meter;

{ ---------------- helpers ---------------- }

procedure MakeSine(var ABuf: array of Single; AFreq, ASampleRate, AAmp: Double;
  APhase: Double = 0.0);
var
  i: Integer;
begin
  for i := 0 to High(ABuf) do
    ABuf[i] := AAmp * Sin(2 * Pi * AFreq * i / ASampleRate + APhase);
end;

{ crude fundamental estimate from positive-going zero crossings }
function DominantHz(const ABuf: array of Single; ACount: Integer; ASampleRate: Double): Double;
var
  i, firstX, lastX, crossings: Integer;
  prev, cur: Single;
begin
  Result := 0;
  firstX := -1; lastX := -1; crossings := 0;
  prev := ABuf[0];
  for i := 1 to ACount - 1 do
  begin
    cur := ABuf[i];
    if (prev <= 0) and (cur > 0) then
    begin
      if firstX < 0 then firstX := i;
      lastX := i;
      Inc(crossings);
    end;
    prev := cur;
  end;
  if (crossings < 2) or (lastX <= firstX) then Exit;
  Result := (crossings - 1) * ASampleRate / (lastX - firstX);
end;

function BufPeak(const ABuf: array of Single; ACount: Integer): Single;
var
  i: Integer;
  m, a: Single;
begin
  m := 0;
  for i := 0 to ACount - 1 do
  begin
    a := Abs(ABuf[i]);
    if a > m then m := a;
  end;
  Result := m;
end;

{ ================= DSP.Math ================= }

procedure Test_Math_Denormal;
begin
  CheckNear(0.0, FlushDenorm(1.0E-30), 0, 'tiny flushed to zero');
  CheckNear(0.5, FlushDenorm(0.5), 1e-9, 'normal value untouched');
  CheckNear(0.0, SanitizeSample(0.0 / 0.0), 0, 'NaN sanitised to 0');
  Check(IsFiniteSample(0.25), 'finite recognised');
  CheckFalse(IsFiniteSample(1.0 / 0.0), 'infinity rejected');
end;

procedure Test_Math_BlockOps;
var
  a, b: array[0..7] of Single;
  i: Integer;
begin
  for i := 0 to 7 do begin a[i] := i; b[i] := 10; end;
  BlockAddScaled(@a[0], @b[0], 0.5, 8);
  for i := 0 to 7 do
    CheckNear(i + 5.0, a[i], 1e-5, 'add scaled ' + IntToStr(i));
  BlockScale(@a[0], 2.0, 8);
  CheckNear(10.0, a[0], 1e-5, 'scale first');
  CheckNear(24.0, a[7], 1e-5, 'scale last');

  for i := 0 to 7 do begin a[i] := 1.0; b[i] := 0.0; end;
  BlockMixRamp(@a[0], @b[0], 0.0, 1.0, 8);   // a fades from 1 toward 0
  Check(a[0] > a[7], 'mix ramp moves toward src');
  CheckNear(1.0, a[0], 1e-6, 'ramp starts at start mix');
end;

procedure Test_Math_EnergyHelpers;
var
  s: array[0..999] of Single;
begin
  MakeSine(s, 125, 1000, 1.0);   // 125 cycles, 8 samples/cycle -> a sample hits +/-1
  CheckNear(0.70710678, BlockRms(@s[0], 1000), 0.01, 'full-scale sine RMS');
  CheckNear(500.0, SumSquares(@s[0], 1000), 5.0, 'sum of squares ~ N/2');
  CheckNear(1.0, BlockPeak(@s[0], 1000), 0.01, 'block peak = amplitude');
end;

procedure Test_Math_PanLaws;
var
  l, r: Single;
begin
  PanGains(0.0, plLinear, l, r);
  CheckNear(0.5, l, 1e-6, 'linear centre L');
  CheckNear(0.5, r, 1e-6, 'linear centre R');

  PanGains(0.0, plConstantPower, l, r);
  CheckNear(0.70710678, l, 1e-4, 'const-power centre L');
  CheckNear(1.0, l * l + r * r, 1e-4, 'const-power sums to unit energy');

  PanGains(-1.0, plConstantPower, l, r);
  CheckNear(1.0, l, 1e-4, 'hard left L=1');
  CheckNear(0.0, r, 1e-4, 'hard left R=0');

  XfadeGains(0.5, l, r);
  CheckNear(1.0, l * l + r * r, 1e-4, 'equal-power xfade unit energy');
end;

procedure Test_Math_Windows;
begin
  CheckNear(0.0, WindowValue(wkHann, 0, 64), 1e-9, 'Hann[0] = 0');
  CheckNear(1.0, WindowValue(wkHann, 32, 65), 1e-9, 'Hann centre = 1');
  CheckNear(0.5, WindowCoherentGain(wkHann, 4096), 0.01, 'Hann coherent gain ~ 0.5');
  Check(WindowCoherentGain(wkBlackmanHarris, 4096) < 0.45, 'BH window lower coherent gain');
end;

procedure Test_Math_Pow2;
begin
  Check(IsPow2(1024), '1024 is pow2');
  CheckFalse(IsPow2(1000), '1000 is not pow2');
  CheckEqualInt(1024, NextPow2(1000), 'next pow2 of 1000');
  CheckEqualInt(1024, NextPow2(1024), 'next pow2 of exact');
  CheckEqualInt(10, IntLog2(1024), 'log2 1024');
end;

procedure Test_Math_ParamSmoother;
var
  s: TParamSmoother;
  i: Integer;
  v: Double;
begin
  s.Init(48000, 5.0, 0.0);
  s.SetTarget(1.0);
  for i := 0 to 48000 - 1 do v := s.Process;   // 1 s >> 5 ms
  CheckNear(1.0, v, 1e-3, 'smoother converges to target');
  s.SetImmediate(0.25);
  CheckNear(0.25, s.Process, 1e-9, 'SetImmediate jumps with no ramp');
end;

{ ================= Interpolation ================= }

procedure Test_Interp_Kernels;
begin
  CheckNear(1.5, InterpLinear(1.0, 2.0, 0.5), 1e-6, 'linear midpoint');
  CheckNear(5.0, InterpHermite4(3, 5, 7, 9, 0.0), 1e-5, 'hermite at frac 0 = x0');
  CheckNear(7.0, InterpHermite4(3, 5, 7, 9, 1.0), 1e-5, 'hermite at frac 1 = x1');
  { Lagrange-3 is exact for a cubic: f(x)=x^3 sampled at -1,0,1,2 -> f(0.5)=0.125 }
  CheckNear(0.125, InterpLagrange3(-1, 0, 1, 8, 0.5), 1e-5, 'lagrange exact on cubic');
end;

procedure Test_Interp_ReadFractional_Clamps;
var
  b: array[0..3] of Single;
begin
  b[0] := 10; b[1] := 20; b[2] := 30; b[3] := 40;
  CheckNear(10.0, ReadFractional(@b[0], 4, -2.0, ikHermite), 1e-6, 'clamp low edge');
  CheckNear(40.0, ReadFractional(@b[0], 4, 9.0, ikHermite), 1e-6, 'clamp high edge');
  CheckNear(25.0, ReadFractional(@b[0], 4, 1.5, ikLinear), 1e-6, 'interior linear read');
end;

{ ================= Filters ================= }

procedure Test_Biquad_LowpassResponse;
var
  bq: TBiquad;
begin
  bq.Init(48000);
  bq.SetParams(bqLowpass, 1000, 0.70710678);
  CheckNear(0.0, bq.MagnitudeDb(50), 0.3, 'LP passband ~ 0 dB');
  CheckNear(-3.0, bq.MagnitudeDb(1000), 0.6, 'LP -3 dB at cutoff');
  Check(bq.MagnitudeDb(12000) < -30, 'LP strong attenuation an octave+ up');
end;

procedure Test_Biquad_HighpassAndPeaking;
var
  hp, pk: TBiquad;
begin
  hp.Init(48000);
  hp.SetParams(bqHighpass, 500, 0.70710678);
  Check(hp.MagnitudeDb(20) < -20, 'HP kills sub-bass');
  CheckNear(0.0, hp.MagnitudeDb(10000), 0.3, 'HP passband flat');

  pk.Init(48000);
  pk.SetParams(bqPeaking, 2000, 2.0, 6.0);
  CheckNear(6.0, pk.MagnitudeDb(2000), 0.3, 'peaking gives +6 dB at centre');
  CheckNear(0.0, pk.MagnitudeDb(100), 0.3, 'peaking flat far below');
end;

procedure Test_Biquad_ProcessSine;
var
  bq: TBiquad;
  lo, hi: array[0..2047] of Single;
  i: Integer;
begin
  bq.Init(48000);
  bq.SetParams(bqLowpass, 2000, 0.70710678);
  MakeSine(lo, 300, 48000, 0.5);
  for i := 0 to High(lo) do lo[i] := bq.ProcessSample(lo[i]);
  CheckNear(0.5, BufPeak(lo, 2048), 0.03, 'low tone passes LP roughly intact');

  bq.Reset;
  MakeSine(hi, 16000, 48000, 0.5);
  for i := 0 to High(hi) do hi[i] := bq.ProcessSample(hi[i]);
  Check(BufPeak(hi, 2048) < 0.1, 'high tone strongly attenuated by LP');
end;

procedure Test_OnePole_And_DCBlocker;
var
  op: TOnePole;
  dc: TDCBlocker;
  i: Integer;
  x, y: Single;
  last: Single;
begin
  op.Init(48000);
  op.SetCutoff(opLowpass, 1000);
  for i := 0 to 9999 do y := op.ProcessSample(1.0);   // step response -> DC gain 1
  CheckNear(1.0, y, 1e-3, 'one-pole LP passes DC at unity');

  dc.Init(48000, 20);
  for i := 0 to 19999 do
  begin
    x := 1.0 + 0.25 * Sin(2 * Pi * 1000 * i / 48000);   // DC offset + tone
    last := dc.ProcessSample(x);
  end;
  Check(Abs(last) < 0.35, 'DC blocker removed the offset, kept the tone');
end;

procedure Test_SVF_ResponseAndStability;
var
  svf: TStateVariableFilter;
  hi: array[0..4095] of Single;
  i: Integer;
  o: TSVFOutputs;
  bad: Boolean;
begin
  svf.Init(48000);
  svf.SetParams(1000, 0.7071);
  MakeSine(hi, 12000, 48000, 0.5);
  for i := 0 to High(hi) do
    hi[i] := svf.ProcessSample(hi[i]).LP;
  Check(BufPeak(hi, 4096) < 0.15, 'SVF lowpass attenuates 12 kHz');

  { hammer it with a high-Q modulated sweep - must stay finite }
  svf.Reset;
  bad := False;
  for i := 0 to 200000 do
  begin
    svf.SetParams(200 + 15000 * (0.5 + 0.5 * Sin(i * 0.001)), 8.0);
    o := svf.ProcessSample(Sin(i * 0.05));
    if (o.LP <> o.LP) or (Abs(o.LP) > 100) then begin bad := True; Break; end;
  end;
  CheckFalse(bad, 'modulated high-Q SVF stayed stable');
end;

procedure Test_BiquadChain_Butterworth;
var
  ch: TBiquadChain;
begin
  ch := TBiquadChain.Create(48000, 2);   // 4th order
  try
    ch.SetButterworthLowpass(1000);
    CheckNear(0.0, ch.MagnitudeDb(100), 0.3, '4th-order LP passband flat');
    CheckNear(-3.0, ch.MagnitudeDb(1000), 0.8, '4th-order LP -3 dB at cutoff');
    Check(ch.MagnitudeDb(2000) < -20, '4th-order rolls off ~24 dB/oct');
  finally
    ch.Free;
  end;
end;

{ ================= FFT ================= }

procedure Test_FFT_RoundTrip;
var
  fft: TFFT;
  re, im, re0, im0: array of Double;
  i, n: Integer;
  maxErr: Double;
begin
  n := 1024;
  fft := TFFT.Create(n);
  try
    SetLength(re, n); SetLength(im, n);
    SetLength(re0, n); SetLength(im0, n);
    RandSeed := 12345;
    for i := 0 to n - 1 do
    begin
      re[i] := Random - 0.5; im[i] := Random - 0.5;
      re0[i] := re[i]; im0[i] := im[i];
    end;
    fft.ForwardInPlace(re, im);
    fft.InverseInPlace(re, im);
    maxErr := 0;
    for i := 0 to n - 1 do
    begin
      maxErr := Max(maxErr, Abs(re[i] - re0[i]));
      maxErr := Max(maxErr, Abs(im[i] - im0[i]));
    end;
    Check(maxErr < 1e-9, 'FFT forward/inverse is the identity (err=' +
      FloatToStr(maxErr) + ')');
  finally
    fft.Free;
  end;
end;

procedure Test_FFT_SineBin;
var
  fft: TFFT;
  t: array of Single;
  re, im, mag: array of Double;
  i, n, kExp, kPeak: Integer;
  best: Double;
begin
  n := 2048;
  fft := TFFT.Create(n);
  try
    SetLength(t, n);
    for i := 0 to n - 1 do
      t[i] := 0.5 * Sin(2 * Pi * 64 * i / n);   // exactly 64 cycles -> bin 64
    SetLength(re, fft.SpectrumBins);
    SetLength(im, fft.SpectrumBins);
    SetLength(mag, fft.SpectrumBins);
    fft.RealForward(t, re, im);
    fft.MagnitudeSpectrum(re, im, mag);
    kExp := 64;
    kPeak := 1; best := 0;
    for i := 1 to fft.SpectrumBins - 1 do
      if mag[i] > best then begin best := mag[i]; kPeak := i; end;
    CheckEqualInt(kExp, kPeak, 'sine energy lands in the expected bin');
    CheckNear(0.5, mag[kPeak] / (n / 2), 0.02, 'recovered amplitude ~ 0.5');
  finally
    fft.Free;
  end;
end;

procedure Test_FFT_WindowedDb;
var
  fft: TFFT;
  t: array of Single;
  db: array of Double;
  i, n, k: Integer;
  best: Double;
  bestk: Integer;
begin
  n := 4096;
  fft := TFFT.Create(n);
  try
    SetLength(t, n);
    for i := 0 to n - 1 do
      t[i] := 1.0 * Sin(2 * Pi * 200 * i / n);   // on bin 200
    SetLength(db, fft.SpectrumBins);
    fft.AnalyzeDb(t, wkHann, db);
    best := -1000; bestk := 0;
    for k := 1 to fft.SpectrumBins - 1 do
      if db[k] > best then begin best := db[k]; bestk := k; end;
    CheckEqualInt(200, bestk, 'windowed peak at bin 200');
    CheckNear(0.0, best, 0.4, 'full-scale sine reads ~ 0 dBFS with Hann coherent-gain correction');
  finally
    fft.Free;
  end;
end;

{ ================= Resampler ================= }

procedure Test_Resampler_Upsample;
var
  rs: TResampler;
  src, dst: TAudioPlanar;
  nIn, got: Integer;
begin
  nIn := 24000;
  SetLength(src, 1); SetLength(src[0], nIn);
  MakeSine(src[0], 1000, 24000, 0.5);
  SetLength(dst, 1); SetLength(dst[0], nIn * 2 + 64);

  rs := TResampler.Create(1, rqSinc, 16);
  try
    rs.SetRates(24000, 48000);
    got := rs.Process(src, nIn, dst, nIn * 2 + 64);
    { one streaming call, no flush: loses ~2*ZeroCrossings frames of edge lead-in/out }
    Check((got <= nIn * 2) and (got >= nIn * 2 - 80),
      'upsampled length ~ 2x input (' + IntToStr(got) + ')');
    CheckNear(1000.0, DominantHz(dst[0], got, 48000), 5.0, 'frequency preserved on upsample');
    CheckNear(0.5, BufPeak(dst[0], got), 0.03, 'amplitude preserved on upsample');
  finally
    rs.Free;
  end;
end;

procedure Test_Resampler_Downsample;
var
  rs: TResampler;
  src, dst: TAudioPlanar;
  nIn, got: Integer;
begin
  nIn := 48000;
  SetLength(src, 1); SetLength(src[0], nIn);
  MakeSine(src[0], 1000, 48000, 0.5);   // well below the 12 kHz new Nyquist
  SetLength(dst, 1); SetLength(dst[0], nIn);

  rs := TResampler.Create(1, rqSinc, 16);
  try
    rs.SetRates(48000, 24000);
    got := rs.Process(src, nIn, dst, nIn);
    Check(Abs(got - nIn div 2) < 40, 'downsampled length ~ 0.5x (' + IntToStr(got) + ')');
    CheckNear(1000.0, DominantHz(dst[0], got, 24000), 5.0, 'frequency preserved on downsample');
    CheckNear(0.5, BufPeak(dst[0], got), 0.04, 'amplitude preserved on downsample');
  finally
    rs.Free;
  end;
end;

procedure Test_Resampler_OneShotIdentity;
var
  src, outp: TAudioPlanar;
  n, m, off: Integer;
  maxErr, e: Single;
begin
  n := 8000;
  SetLength(src, 2);
  SetLength(src[0], n); SetLength(src[1], n);
  MakeSine(src[0], 440, 44100, 0.4);
  MakeSine(src[1], 660, 44100, 0.3);
  outp := ResamplePlanar(src, n, 44100, 44100, rqSinc);
  Check(Abs(Length(outp[0]) - n) < 40, 'identity ratio keeps length');
  CheckNear(0.4, BufPeak(outp[0], Length(outp[0])), 0.01, 'identity keeps ch0 amplitude');
  CheckNear(0.3, BufPeak(outp[1], Length(outp[1])), 0.01, 'identity keeps ch1 amplitude');
  CheckNear(440.0, DominantHz(outp[0], Length(outp[0]), 44100), 1.0, 'identity keeps ch0 pitch');

  { at unity ratio every read lands on frac 0, so the sinc picks the exact
    centre sample - the output is a pure delayed copy. Find the shift and
    verify it is sample-exact. }
  maxErr := 1e9;
  for off := 0 to 40 do
  begin
    e := 0;
    if off + 400 + 3000 < Length(outp[0]) then
      for m := 400 to 3400 do
        e := Max(e, Abs(outp[0][m] - src[0][m + off]));
    if e < maxErr then maxErr := e;
  end;
  Check(maxErr < 1e-4, 'unity-ratio sinc resample is sample-exact after its delay');
end;

procedure Test_Resampler_LinearMode;
var
  rs: TResampler;
  src, dst: TAudioPlanar;
  got: Integer;
begin
  SetLength(src, 1); SetLength(src[0], 10000);
  MakeSine(src[0], 500, 44100, 0.5);
  SetLength(dst, 1); SetLength(dst[0], 20000);
  rs := TResampler.Create(1, rqLinear);
  try
    rs.SetRates(44100, 48000);
    got := rs.Process(src, 10000, dst, 20000);
    Check(Abs(got - Round(10000 * 48000 / 44100)) < 8, 'linear-mode length ratio');
    CheckNear(500.0, DominantHz(dst[0], got, 48000), 4.0, 'linear-mode keeps pitch');
  finally
    rs.Free;
  end;
end;

{ ================= Envelope ================= }

procedure Test_ADSR_Cycle;
var
  env: TADSR;
  i: Integer;
begin
  env.Init(48000);
  env.SetADSR(10, 50, 0.5, 100);   // ms
  env.NoteOn;
  for i := 0 to Round(0.12 * 48000) do env.Process;   // past attack(10)+decay(50)
  CheckNear(0.5, env.Value, 0.02, 'ADSR settles at sustain level');
  Check(env.Stage = asSustain, 'ADSR in sustain stage');
  env.NoteOff;
  for i := 0 to Round(0.5 * 48000) do env.Process;    // past release
  CheckNear(0.0, env.Value, 1e-3, 'ADSR returns to zero after release');
  CheckFalse(env.IsActive, 'ADSR inactive when idle');
end;

procedure Test_EnvelopeFollower;
var
  f: TEnvelopeFollower;
  i: Integer;
  x: Single;
begin
  f.Init(48000);
  f.SetTimes(1, 50);
  f.SetMode(fmPeak);
  for i := 0 to 48000 - 1 do
  begin
    x := 0.8 * Sin(2 * Pi * 200 * i / 48000);
    f.Process(x);
  end;
  CheckNear(0.8, f.Envelope, 0.05, 'peak follower tracks amplitude');
  for i := 0 to 48000 - 1 do f.Process(0.0);   // 1 s of silence
  Check(f.Envelope < 0.01, 'follower releases toward zero on silence');

  f.Init(48000);
  f.SetTimes(1, 20);
  f.SetMode(fmRms);
  for i := 0 to 48000 - 1 do
    f.Process(0.5 * Sin(2 * Pi * 500 * i / 48000));
  CheckNear(0.3535, f.Envelope, 0.03, 'RMS follower ~ amp/sqrt(2)');
end;

{ ================= Meters ================= }

procedure Test_PeakMeter_Ballistics;
var
  m: TPeakMeter;
  i: Integer;
begin
  m.Init(48000, 20.0, 100.0, 10.0);
  m.Push(1.0);
  CheckNear(1.0, m.Value, 1e-6, 'instant attack to the peak');
  for i := 0 to 4799 do m.Push(0.0);   // 100 ms of release @ 20 dB/s -> -2 dB
  Check((m.ValueDb < -1.0) and (m.ValueDb > -4.0), 'peak released ~2 dB in 100 ms');
  Check(m.HoldDb >= m.ValueDb, 'hold sits at or above the ballistic value');
end;

procedure Test_RmsMeter_Calibration;
var
  m: TRmsMeter;
  s: array[0..8191] of Single;
  i: Integer;
begin
  m.Init(48000, 100.0);
  MakeSine(s, 1000, 48000, 1.0);
  for i := 0 to High(s) do m.Push(s[i]);
  CheckNear(-3.01, m.ValueDb, 0.3, 'full-scale sine RMS = -3.01 dBFS');
end;

procedure Test_TruePeakMeter;
var
  m: TTruePeakMeter;
  s: array[0..4095] of Single;
  i: Integer;
begin
  m.Init(48000, 4, 24);
  MakeSine(s, 997, 48000, 1.0);
  for i := 0 to High(s) do m.Push(s[i]);
  Check(Abs(m.ValueDb) < 0.6, 'full-scale sine reads ~ 0 dBTP (' +
    FormatFloat('0.00', m.ValueDb) + ')');

  { a high tone sampled between its crests: inter-sample peak exceeds the sample
    peak, and the 4x meter must recover more than the raw samples show }
  m.Reset;
  MakeSine(s, 19000, 48000, 0.5, Pi / 4);
  for i := 0 to High(s) do m.Push(s[i]);
  Check(m.ValueLinear >= BufPeak(s, 4096) - 0.005,
    'true-peak >= sample peak for an under-sampled crest (' +
    FormatFloat('0.000', m.ValueLinear) + ' vs ' + FormatFloat('0.000', BufPeak(s, 4096)) + ')');
  Check(m.ValueLinear > 0.48, 'true-peak recovers close to the real 0.5 crest');
end;

procedure Test_Loudness_TracksLevel;
var
  a, b: TLoudnessMeter;
  sr, i, n: Integer;
  fr: array[0..1] of Single;
  loA, loB: Double;
begin
  sr := 48000;
  n := Round(1.5 * sr);
  a := TLoudnessMeter.Create(sr, 2);
  b := TLoudnessMeter.Create(sr, 2);
  try
    for i := 0 to n - 1 do
    begin
      fr[0] := 0.25 * Sin(2 * Pi * 1000 * i / sr);
      fr[1] := fr[0];
      a.PushFrame(fr);
      fr[0] := fr[0] * 2.0;   // +6 dB
      fr[1] := fr[0];
      b.PushFrame(fr);
    end;
    loA := a.Integrated;
    loB := b.Integrated;
    Check(loA > -70, 'integrated loudness of a steady tone is above the abs gate');
    CheckNear(6.0, loB - loA, 0.4, '+6 dB in => +6 LU integrated');
    CheckNear(loA, a.Momentary, 0.5, 'steady tone: momentary ~ integrated');
    { rough absolute anchor: -12.04 dBFS peak stereo 1 kHz sine ~ -12 LUFS +/- 2 }
    Check((loA > -15) and (loA < -9), 'absolute loudness in the expected range (' +
      FormatFloat('0.0', loA) + ')');
  finally
    a.Free;
    b.Free;
  end;
end;

procedure Test_Loudness_Silence;
var
  m: TLoudnessMeter;
  fr: array[0..1] of Single;
  i: Integer;
begin
  m := TLoudnessMeter.Create(48000, 2);
  try
    fr[0] := 0; fr[1] := 0;
    for i := 0 to 48000 do m.PushFrame(fr);
    Check(m.Integrated <= -70.0, 'silence integrates to <= -70 LUFS (gated to floor)');
  finally
    m.Free;
  end;
end;

procedure Test_CorrelationMeter;
var
  c: TCorrelationMeter;
  i: Integer;
  l, r: Single;
begin
  c.Init(48000, 50.0);
  for i := 0 to 9999 do
  begin
    l := Sin(2 * Pi * 500 * i / 48000);
    c.Push(l, l);                       // identical channels -> +1
  end;
  CheckNear(1.0, c.Value, 1e-3, 'mono-correlated signal reads +1');

  c.Reset;
  for i := 0 to 9999 do
  begin
    l := Sin(2 * Pi * 500 * i / 48000);
    r := -l;
    c.Push(l, r);                       // inverted -> -1
  end;
  CheckNear(-1.0, c.Value, 1e-3, 'anti-phase signal reads -1');
end;

{ ---------------- registration ---------------- }

procedure RegisterPhase3Tests;
begin
  RegisterTest('dsp.math', 'denormal + finite guards',   @Test_Math_Denormal);
  RegisterTest('dsp.math', 'block operations',            @Test_Math_BlockOps);
  RegisterTest('dsp.math', 'energy helpers',              @Test_Math_EnergyHelpers);
  RegisterTest('dsp.math', 'pan / crossfade laws',        @Test_Math_PanLaws);
  RegisterTest('dsp.math', 'analysis windows',            @Test_Math_Windows);
  RegisterTest('dsp.math', 'power-of-two helpers',        @Test_Math_Pow2);
  RegisterTest('dsp.math', 'parameter smoother',          @Test_Math_ParamSmoother);

  RegisterTest('dsp.interp', 'interpolation kernels',     @Test_Interp_Kernels);
  RegisterTest('dsp.interp', 'ReadFractional clamps',     @Test_Interp_ReadFractional_Clamps);

  RegisterTest('dsp.filter', 'biquad lowpass response',   @Test_Biquad_LowpassResponse);
  RegisterTest('dsp.filter', 'biquad highpass + peaking', @Test_Biquad_HighpassAndPeaking);
  RegisterTest('dsp.filter', 'biquad processes a sine',   @Test_Biquad_ProcessSine);
  RegisterTest('dsp.filter', 'one-pole + DC blocker',     @Test_OnePole_And_DCBlocker);
  RegisterTest('dsp.filter', 'SVF response + stability',  @Test_SVF_ResponseAndStability);
  RegisterTest('dsp.filter', 'Butterworth biquad chain',  @Test_BiquadChain_Butterworth);

  RegisterTest('dsp.fft', 'forward/inverse identity',     @Test_FFT_RoundTrip);
  RegisterTest('dsp.fft', 'single-bin sine',              @Test_FFT_SineBin);
  RegisterTest('dsp.fft', 'windowed dBFS calibration',    @Test_FFT_WindowedDb);

  RegisterTest('dsp.resampler', 'upsample 24k->48k',      @Test_Resampler_Upsample);
  RegisterTest('dsp.resampler', 'downsample 48k->24k',    @Test_Resampler_Downsample);
  RegisterTest('dsp.resampler', 'one-shot identity',      @Test_Resampler_OneShotIdentity);
  RegisterTest('dsp.resampler', 'linear-mode ratio',      @Test_Resampler_LinearMode);

  RegisterTest('dsp.envelope', 'ADSR full cycle',         @Test_ADSR_Cycle);
  RegisterTest('dsp.envelope', 'envelope follower',       @Test_EnvelopeFollower);

  RegisterTest('dsp.meter', 'peak meter ballistics',      @Test_PeakMeter_Ballistics);
  RegisterTest('dsp.meter', 'sliding RMS calibration',    @Test_RmsMeter_Calibration);
  RegisterTest('dsp.meter', 'true-peak meter',            @Test_TruePeakMeter);
  RegisterTest('dsp.meter', 'BS.1770 loudness tracking',  @Test_Loudness_TracksLevel);
  RegisterTest('dsp.meter', 'loudness gate on silence',   @Test_Loudness_Silence);
  RegisterTest('dsp.meter', 'stereo correlation',         @Test_CorrelationMeter);
end;

end.
