unit Tests.Phase19;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 19 acceptance tests - advanced DSP (multiband dynamics, a lookahead
  compressor, a mastering chain, and offline phase-vocoder time-stretch /
  pitch-shift). Verified in memory with synthetic tones, no reference media:

    * TMultibandCompressor sums back to (approximately) unity with all bands
      transparent, and reports gain reduction on the low band only when the
      low band's threshold is crossed;
    * TAdvancedCompressor accepts a nonzero lookahead and still reacts to a
      loud transient with nonzero gain reduction;
    * TMasteringChain never lets a full-scale sine exceed a low CeilingDb;
    * TPhaseVocoderStretch roughly doubles a buffer's length under a 2.0
      stretch factor while preserving the dominant frequency of a sine;
    * TPitchShifter preserves length while raising a 440 Hz sine's dominant
      frequency by one octave (12 semitones) to ~880 Hz.

  Tolerances are generous throughout - these are DSP algorithms with
  inherent windowing / estimation error, not exact-value regressions.

  Requires src/audio/dsp on the search path. }

interface

procedure RegisterPhase19Tests;

implementation

uses
  SysUtils, Math,
  UDAW.Testing,
  UDAW.DSP.Math,
  UDAW.DSP.Dynamics,
  UDAW.DSP.MultibandComp,
  UDAW.DSP.Mastering,
  UDAW.DSP.TimeStretch,
  UDAW.DSP.PitchShift,
  UDAW.DSP.FFT;

const
  GRP = 'phase19.advanceddsp';
  SR = 44100;

{ ---------------- helpers ---------------- }

procedure MakeSine(AFreqHz: Double; ASampleRate, AFrames: Integer; AAmp: Double;
  var ABuf: TArray<Single>);
var
  i: Integer;
begin
  SetLength(ABuf, AFrames);
  for i := 0 to AFrames - 1 do
    ABuf[i] := Single(AAmp * Sin(DSP_TWO_PI * AFreqHz * i / ASampleRate));
end;

function RmsOf(const ABuf: array of Single): Double;
var
  i: Integer;
  s: Double;
begin
  s := 0;
  for i := 0 to High(ABuf) do s := s + Sqr(Double(ABuf[i]));
  if Length(ABuf) = 0 then Exit(0);
  Result := Sqrt(s / Length(ABuf));
end;

function PeakOf(const ABuf: array of Single): Double;
var
  i: Integer;
  a: Double;
begin
  Result := 0;
  for i := 0 to High(ABuf) do
  begin
    a := Abs(ABuf[i]);
    if a > Result then Result := a;
  end;
end;

{ FFT-based dominant-frequency estimate over a window taken from the middle
  of ABuf. AFFTSize must be a power of two and <= Length(ABuf). }
function DominantFreq(const ABuf: array of Single; ASampleRate, AFFTSize: Integer): Double;
var
  fft: TFFT;
  start, i, nb, bestBin: Integer;
  window: array of Single;
  re, im, mag: array of Double;
  bestMag: Double;
begin
  Result := 0;
  if Length(ABuf) < AFFTSize then Exit;
  start := (Length(ABuf) - AFFTSize) div 2;
  SetLength(window, AFFTSize);
  for i := 0 to AFFTSize - 1 do
    window[i] := ABuf[start + i];

  fft := TFFT.Create(AFFTSize);
  try
    nb := fft.SpectrumBins;
    SetLength(re, nb);
    SetLength(im, nb);
    SetLength(mag, nb);
    fft.RealForward(window, re, im);
    fft.MagnitudeSpectrum(re, im, mag);
    bestBin := 1;
    bestMag := mag[1];
    for i := 2 to nb - 1 do
      if mag[i] > bestMag then
      begin
        bestMag := mag[i];
        bestBin := i;
      end;
    Result := fft.BinToHz(bestBin, ASampleRate);
  finally
    fft.Free;
  end;
end;

{ ---------------- TMultibandCompressor ---------------- }

procedure Test_Multiband_TransparentSumsFlat;
var
  mb: TMultibandCompressor;
  b, i, frames: Integer;
  inp, outp: TArray<Single>;
  inPtr, outPtr: array[0..0] of PSingle;
  rmsIn, rmsOut: Double;
begin
  frames := 4096;
  MakeSine(1000.0, SR, frames, 0.8, inp);
  SetLength(outp, frames);

  mb := TMultibandCompressor.Create;
  try
    mb.Configure(SR, 1);
    { transparent: threshold at 0 dB, ratio 1:1 on every band }
    for b := 0 to 2 do
      mb.SetBandParams(b, 0.0, 1.0, 0.0, 5.0, 50.0, 0.0);

    inPtr[0] := @inp[0];
    outPtr[0] := @outp[0];
    mb.ProcessBlock(inPtr, outPtr, frames);
  finally
    mb.Free;
  end;

  { crossover settling takes a little while; compare energy over the tail }
  rmsIn := RmsOf(Copy(inp, frames div 2, frames div 2));
  rmsOut := RmsOf(Copy(outp, frames div 2, frames div 2));
  Check(rmsOut > 0.01, 'transparent multiband output is not silent');
  Check(Abs(20.0 * Log10(rmsOut / Max(rmsIn, 1.0E-9))) < 3.0,
    Format('transparent 3-band sum stays within 3 dB of input (in=%.4f out=%.4f)',
      [rmsIn, rmsOut]));
end;

procedure Test_Multiband_LowBandCompresses;
var
  mb: TMultibandCompressor;
  frames: Integer;
  lowTone, highTone, outp: TArray<Single>;
  inPtr, outPtr: array[0..0] of PSingle;
  b: Integer;
begin
  frames := 8192;
  SetLength(outp, frames);

  mb := TMultibandCompressor.Create;
  try
    mb.Configure(SR, 1);
    for b := 0 to 2 do
      mb.SetBandParams(b, 0.0, 1.0, 0.0, 5.0, 50.0, 0.0);
    { hammer the low band: low threshold, high ratio }
    mb.SetBandParams(0, -40.0, 10.0, 3.0, 5.0, 50.0, 0.0);

    MakeSine(80.0, SR, frames, 0.9, lowTone);
    inPtr[0] := @lowTone[0];
    outPtr[0] := @outp[0];
    mb.ProcessBlock(inPtr, outPtr, frames);
    Check(mb.BandGainReductionDb(0) > 0.5,
      Format('low-band tone triggers low-band gain reduction (%.2f dB)',
        [mb.BandGainReductionDb(0)]));

    mb.Reset;
    MakeSine(8000.0, SR, frames, 0.9, highTone);
    inPtr[0] := @highTone[0];
    mb.ProcessBlock(inPtr, outPtr, frames);
    Check(mb.BandGainReductionDb(0) < 0.5,
      Format('high-band-only tone leaves the low band ~untouched (%.2f dB)',
        [mb.BandGainReductionDb(0)]));
  finally
    mb.Free;
  end;
end;

{ ---------------- TAdvancedCompressor ---------------- }

procedure Test_AdvancedCompressor_LookaheadReactsToTransient;
var
  ac: TAdvancedCompressor;
  frames, i: Integer;
  inp, outp: TArray<Single>;
  inPtr, outPtr: array[0..0] of PSingle;
begin
  frames := 4096;
  SetLength(inp, frames);
  SetLength(outp, frames);
  for i := 0 to frames - 1 do
  begin
    if i < frames div 4 then
      inp[i] := 0.0
    else
      inp[i] := Single(0.95 * Sin(DSP_TWO_PI * 1000.0 * i / SR));   // step to full-scale
  end;

  ac := TAdvancedCompressor.Create;
  try
    ac.Configure(SR, 1);
    ac.SetLookaheadMs(5.0);
    ac.SetParams(dynLimiter, -18.0, 20.0, 1.0, 0.1, 50.0, 0.0);

    inPtr[0] := @inp[0];
    outPtr[0] := @outp[0];
    ac.ProcessBlock(inPtr, outPtr, frames);

    Check(ac.CurrentGainReductionDb > 0.0,
      Format('lookahead compressor shows gain reduction after the transient (%.2f dB)',
        [ac.CurrentGainReductionDb]));
  finally
    ac.Free;
  end;
end;

{ ---------------- TMasteringChain ---------------- }

procedure Test_MasteringChain_RespectsCeiling;
var
  mc: TMasteringChain;
  frames: Integer;
  l, r, outL, outR: TArray<Single>;
  inPtr, outPtr: array[0..1] of PSingle;
  ceilingDb, ceilingLin, peak: Double;
begin
  frames := 8192;
  MakeSine(440.0, SR, frames, 1.0, l);
  MakeSine(440.0, SR, frames, 1.0, r);
  SetLength(outL, frames);
  SetLength(outR, frames);

  ceilingDb := -3.0;
  ceilingLin := Power(10.0, ceilingDb / 20.0);

  mc := TMasteringChain.Create;
  try
    mc.Configure(SR);
    mc.SetCeilingDb(ceilingDb);
    { keep the multiband + normalize stages out of the way for this check }
    mc.SetTargetLufs(-6.0);

    inPtr[0] := @l[0]; inPtr[1] := @r[0];
    outPtr[0] := @outL[0]; outPtr[1] := @outR[0];
    mc.ProcessBlock(inPtr, outPtr, frames);
  finally
    mc.Free;
  end;

  peak := Max(PeakOf(outL), PeakOf(outR));
  Check(peak <= ceilingLin + 0.01,
    Format('mastering chain output never exceeds the %.1f dB ceiling (peak=%.4f, ceiling=%.4f)',
      [ceilingDb, peak, ceilingLin]));
end;

{ ---------------- TPhaseVocoderStretch ---------------- }

procedure Test_PhaseVocoder_StretchLengthAndPitch;
var
  pv: TPhaseVocoderStretch;
  frames: Integer;
  inp, outp: TArray<Single>;
  dom: Double;
begin
  frames := 44100;   // 1 second @ 44.1 kHz
  MakeSine(440.0, SR, frames, 0.8, inp);

  pv := TPhaseVocoderStretch.Create(2048);
  try
    pv.Process(inp, 2.0, outp);
  finally
    pv.Free;
  end;

  Check(Length(outp) > Round(frames * 1.8), 'stretched output is roughly 2x as long (lower bound)');
  Check(Length(outp) < Round(frames * 2.2), 'stretched output is roughly 2x as long (upper bound)');

  dom := DominantFreq(outp, SR, 4096);
  Check(Abs(dom - 440.0) < 25.0,
    Format('time-stretch preserves pitch (dominant freq %.1f near 440 Hz)', [dom]));
end;

{ ---------------- TPitchShifter ---------------- }

procedure Test_PitchShifter_OctaveUp;
var
  ps: TPitchShifter;
  frames: Integer;
  inp, outp: TArray<Single>;
  dom: Double;
begin
  frames := 44100;
  MakeSine(440.0, SR, frames, 0.8, inp);

  ps := TPitchShifter.Create(2048);
  try
    ps.Process(inp, 12.0, SR, outp);
  finally
    ps.Free;
  end;

  Check(Abs(Length(outp) - frames) < Round(frames * 0.05),
    Format('pitch-shifted output length close to input (%d vs %d)', [Length(outp), frames]));

  dom := DominantFreq(outp, SR, 4096);
  Check(Abs(dom - 880.0) < 60.0,
    Format('pitch shift up an octave: dominant freq %.1f near 880 Hz', [dom]));
end;

procedure RegisterPhase19Tests;
begin
  RegisterTest(GRP, 'multiband compressor: transparent bands sum flat', Test_Multiband_TransparentSumsFlat);
  RegisterTest(GRP, 'multiband compressor: low band compresses independently', Test_Multiband_LowBandCompresses);
  RegisterTest(GRP, 'advanced compressor: lookahead reacts to a transient', Test_AdvancedCompressor_LookaheadReactsToTransient);
  RegisterTest(GRP, 'mastering chain: output respects the true-peak ceiling', Test_MasteringChain_RespectsCeiling);
  RegisterTest(GRP, 'phase vocoder: 2x stretch preserves pitch', Test_PhaseVocoder_StretchLengthAndPitch);
  RegisterTest(GRP, 'pitch shifter: +12 semitones preserves length', Test_PitchShifter_OctaveUp);
end;

end.
