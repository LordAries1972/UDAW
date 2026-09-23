unit UDAW.DSP.Analysis;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 27 - Local Audio Analysis for AI (plan section 40, lines 2422-2473).

  "Never send huge PCM buffers to an LLM unnecessarily." This unit reduces an
  already-rendered stereo buffer (a bounced mix, the master bus, a selected
  clip) to the compact structured summary the plan's example shows -
  loudness, true peak, per-band energy, stereo correlation, clipping - plus
  the further metrics plan section 40 lists: crest factor, dynamic range,
  silence, spectral centroid/rolloff, a rough detected pitch and BPM, and
  transient density. UDAW.AI.Mixing (Phase 27) and UDAW.AI.Mastering
  (Phase 28) both build their suggestions from this result; the AI tool
  layer (Phase 26, UDAW.AI.ToolCommands) exposes it as the AnalyzeAudio tool
  so an AI provider only ever sees this JSON, never raw samples.

  Built entirely on the Phase 3 metering primitives (UDAW.DSP.Meter) and
  the Phase 3 FFT (UDAW.DSP.FFT); no third-party DSP or analysis library. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.Meter, UDAW.DSP.FFT, UDAW.AI.JSON;

type
  TAudioAnalysisResult = record
    Frames: Integer;
    SampleRate: Integer;
    DurationSec: Double;

    IntegratedLufs: Double;
    ShortTermLufs: Double;
    TruePeakDb: Double;
    SamplePeakDb: Double;
    RmsDb: Double;

    LowBandEnergy: Double;      // fraction of total spectral energy, ~20-250 Hz
    MidBandEnergy: Double;      // ~250-4000 Hz
    HighBandEnergy: Double;     // ~4000-20000 Hz

    StereoCorrelation: Double;  // -1..+1
    ClippingSamples: Integer;
    CrestFactorDb: Double;      // sample peak - RMS
    DynamicRangeDb: Double;     // loudest 1s block RMS - quietest non-silent 1s block RMS
    SilencePercent: Double;     // % of frames below -60 dBFS

    SpectralCentroidHz: Double;
    SpectralRolloffHz: Double;  // frequency below which 85% of spectral energy sits

    DetectedPitchHz: Double;    // 0 if no clear pitch found
    EstimatedBpm: Double;       // 0 if not determinable
    TransientDensityPerSec: Double;

    class function Empty: TAudioAnalysisResult; static;
  end;

{ Analyzes a full stereo buffer in one pass. Intended for offline use (a
  bounced mix, a rendered master, a selected clip) - not the RT audio thread:
  it allocates scratch buffers and runs an FFT pass over the whole signal. }
function DetectPitchHz(const AMono: TAudioSampleArray; ASampleRate: Integer): Double;

function AnalyzeStereoBuffer(const AL, AR: TAudioSampleArray;
  ASampleRate: Integer): TAudioAnalysisResult;

function AnalysisResultToJSON(const AResult: TAudioAnalysisResult): TJSONValue;
function AnalysisResultToJSONString(const AResult: TAudioAnalysisResult): string;

const
  ANALYSIS_SUBSYS = 'DSP.Analysis';

implementation

const
  FFT_SIZE = 2048;
  FFT_HOP  = 1024;
  BAND_LOW_HI_HZ  = 250.0;
  BAND_MID_HI_HZ  = 4000.0;
  SILENCE_THRESH_LIN = 0.001;     // -60 dBFS
  CLIP_THRESH_LIN    = 0.999;
  ROLLOFF_FRACTION   = 0.85;
  PITCH_MIN_HZ = 50.0;
  PITCH_MAX_HZ = 1000.0;
  PITCH_CONFIDENCE_THRESHOLD = 0.35;

class function TAudioAnalysisResult.Empty: TAudioAnalysisResult;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.IntegratedLufs := METER_MIN_DB;
  Result.ShortTermLufs := METER_MIN_DB;
  Result.TruePeakDb := METER_MIN_DB;
  Result.SamplePeakDb := METER_MIN_DB;
  Result.RmsDb := METER_MIN_DB;
  Result.CrestFactorDb := 0;
  Result.DynamicRangeDb := 0;
end;

{ ---------------- spectral pass: centroid, rolloff, band energy, flux ---------------- }

procedure RunSpectralPass(const AMono: TAudioSampleArray; ASampleRate: Integer;
  out ACentroidHz, ARolloffHz, ALowFrac, AMidFrac, AHighFrac: Double;
  out AOnsetTimesSec: TArray<Double>);
var
  fft: TFFT;
  bins: Integer;
  win: array of Single;
  re, im: array of Double;
  mag, prevMag, sumMag: array of Double;
  b, w, windowCount: Integer;
  pos: Integer;
  hz: Double;
  totalEnergy, cum, lowE, midE, highE, wsum: Double;
  flux: TArray<Double>;
  fluxCount: Integer;
  fluxMean, fluxSq, fluxStd, thresh: Double;
  onsets: TArray<Double>;
  onsetCount: Integer;
  i: Integer;
begin
  ACentroidHz := 0; ARolloffHz := 0; ALowFrac := 0; AMidFrac := 0; AHighFrac := 0;
  SetLength(AOnsetTimesSec, 0);
  if Length(AMono) < FFT_SIZE then Exit;

  fft := TFFT.Create(FFT_SIZE);
  try
    bins := fft.SpectrumBins;
    SetLength(win, FFT_SIZE);
    SetLength(re, bins); SetLength(im, bins);
    SetLength(mag, bins); SetLength(prevMag, bins); SetLength(sumMag, bins);
    for b := 0 to bins - 1 do
    begin
      prevMag[b] := 0;
      sumMag[b] := 0;
    end;

    windowCount := 0;
    fluxCount := 0;
    SetLength(flux, (Length(AMono) div FFT_HOP) + 2);
    SetLength(onsets, 0);
    onsetCount := 0;

    pos := 0;
    while pos + FFT_SIZE <= Length(AMono) do
    begin
      for w := 0 to FFT_SIZE - 1 do
        win[w] := Single(AMono[pos + w] * WindowValue(wkHann, w, FFT_SIZE));
      fft.RealForward(win, re, im);
      fft.MagnitudeSpectrum(re, im, mag);

      for b := 0 to bins - 1 do
        sumMag[b] := sumMag[b] + mag[b];

      { spectral flux: sum of positive frame-to-frame magnitude increases -
        a standard, simple onset-detection function }
      if windowCount > 0 then
      begin
        wsum := 0;
        for b := 0 to bins - 1 do
          if mag[b] > prevMag[b] then
            wsum := wsum + (mag[b] - prevMag[b]);
        flux[fluxCount] := wsum;
        Inc(fluxCount);
      end;
      for b := 0 to bins - 1 do prevMag[b] := mag[b];

      Inc(windowCount);
      Inc(pos, FFT_HOP);
    end;

    if windowCount = 0 then Exit;

    { average spectrum -> centroid / rolloff / band energy }
    totalEnergy := 0;
    for b := 0 to bins - 1 do
    begin
      sumMag[b] := sumMag[b] / windowCount;
      totalEnergy := totalEnergy + sumMag[b] * sumMag[b];
    end;
    if totalEnergy <= 0 then Exit;

    lowE := 0; midE := 0; highE := 0;
    for b := 0 to bins - 1 do
    begin
      hz := fft.BinToHz(b, ASampleRate);
      if hz < BAND_LOW_HI_HZ then lowE := lowE + sumMag[b] * sumMag[b]
      else if hz < BAND_MID_HI_HZ then midE := midE + sumMag[b] * sumMag[b]
      else highE := highE + sumMag[b] * sumMag[b];
    end;
    ALowFrac := lowE / totalEnergy;
    AMidFrac := midE / totalEnergy;
    AHighFrac := highE / totalEnergy;

    { magnitude-weighted mean frequency }
    wsum := 0;
    for b := 0 to bins - 1 do wsum := wsum + sumMag[b];
    if wsum > 0 then
    begin
      ACentroidHz := 0;
      for b := 0 to bins - 1 do
        ACentroidHz := ACentroidHz + fft.BinToHz(b, ASampleRate) * sumMag[b];
      ACentroidHz := ACentroidHz / wsum;
    end;

    cum := 0;
    ARolloffHz := fft.BinToHz(bins - 1, ASampleRate);
    for b := 0 to bins - 1 do
    begin
      cum := cum + sumMag[b] * sumMag[b];
      if cum >= ROLLOFF_FRACTION * totalEnergy then
      begin
        ARolloffHz := fft.BinToHz(b, ASampleRate);
        Break;
      end;
    end;

    { onset detection: adaptive threshold = mean + 1.5 * stddev of the flux }
    if fluxCount >= 4 then
    begin
      fluxMean := 0;
      for i := 0 to fluxCount - 1 do fluxMean := fluxMean + flux[i];
      fluxMean := fluxMean / fluxCount;
      fluxSq := 0;
      for i := 0 to fluxCount - 1 do fluxSq := fluxSq + Sqr(flux[i] - fluxMean);
      fluxStd := Sqrt(fluxSq / fluxCount);
      thresh := fluxMean + 1.5 * fluxStd;
      for i := 1 to fluxCount - 2 do
        if (flux[i] > thresh) and (flux[i] >= flux[i - 1]) and (flux[i] >= flux[i + 1]) then
        begin
          SetLength(onsets, onsetCount + 1);
          { flux[i] corresponds to the window boundary after the (i+1)-th hop
            (windowCount starts counting from the 2nd analysis window) }
          onsets[onsetCount] := ((i + 1) * FFT_HOP) / ASampleRate;
          Inc(onsetCount);
        end;
      AOnsetTimesSec := onsets;
    end;
  finally
    fft.Free;
  end;
end;

{ ---------------- pitch: normalized autocorrelation over a representative window --- }

function DetectPitchHz(const AMono: TAudioSampleArray; ASampleRate: Integer): Double;
var
  minLag, maxLag, lag, n, i, startPos: Integer;
  acc, energy0, bestVal: Double;
  bestLag: Integer;
begin
  Result := 0;
  n := 4096;
  if Length(AMono) < n then n := Length(AMono);
  if n < 256 then Exit;
  startPos := (Length(AMono) - n) div 2;

  minLag := Round(ASampleRate / PITCH_MAX_HZ);
  maxLag := Round(ASampleRate / PITCH_MIN_HZ);
  if minLag < 1 then minLag := 1;
  if maxLag > n - 1 then maxLag := n - 1;
  if maxLag <= minLag then Exit;

  energy0 := 0;
  for i := 0 to n - 1 do
    energy0 := energy0 + Double(AMono[startPos + i]) * Double(AMono[startPos + i]);
  if energy0 <= 1.0E-12 then Exit;

  bestVal := 0; bestLag := 0;
  for lag := minLag to maxLag do
  begin
    acc := 0;
    for i := 0 to n - lag - 1 do
      acc := acc + Double(AMono[startPos + i]) * Double(AMono[startPos + i + lag]);
    acc := acc / energy0;
    if acc > bestVal then
    begin
      bestVal := acc;
      bestLag := lag;
    end;
  end;

  if (bestLag > 0) and (bestVal >= PITCH_CONFIDENCE_THRESHOLD) then
    Result := ASampleRate / bestLag;
end;

{ ---------------- BPM: cluster inter-onset intervals into a 60-180 BPM range --- }

function EstimateBpm(const AOnsetTimesSec: TArray<Double>): Double;
var
  i, bucket, bestBucket, bestCount: Integer;
  diff, bpm: Double;
  buckets: array[60..180] of Integer;
  bucketSum: array[60..180] of Double;
begin
  Result := 0;
  if Length(AOnsetTimesSec) < 5 then Exit;
  for bucket := 60 to 180 do begin buckets[bucket] := 0; bucketSum[bucket] := 0; end;

  for i := 1 to High(AOnsetTimesSec) do
  begin
    diff := AOnsetTimesSec[i] - AOnsetTimesSec[i - 1];
    if diff <= 0.02 then Continue;    // ignore near-duplicate onsets
    bpm := 60.0 / diff;
    while bpm < 60.0 do bpm := bpm * 2.0;
    while bpm >= 180.0 do bpm := bpm / 2.0;
    bucket := Round(bpm);
    if bucket < 60 then bucket := 60;
    if bucket > 180 then bucket := 180;
    Inc(buckets[bucket]);
    bucketSum[bucket] := bucketSum[bucket] + bpm;
  end;

  bestBucket := -1; bestCount := 0;
  for bucket := 60 to 180 do
    if buckets[bucket] > bestCount then
    begin
      bestCount := buckets[bucket];
      bestBucket := bucket;
    end;
  if (bestBucket >= 60) and (bestCount >= 3) then
    Result := bucketSum[bestBucket] / bestCount;
end;

{ ================= AnalyzeStereoBuffer ================= }

function AnalyzeStereoBuffer(const AL, AR: TAudioSampleArray;
  ASampleRate: Integer): TAudioAnalysisResult;
var
  n, i: Integer;
  peakLin, sumSq, sumLR, sumLL, sumRR: Double;
  clipCount, silentFrames: Integer;
  tpL, tpR: TTruePeakMeter;
  loud: TLoudnessMeter;
  frame: array[0..1] of Single;
  mono: TAudioSampleArray;
  blockLen, blockIdx, blockCount: Integer;
  blockSumSq: Double;
  blockDbList: TArray<Double>;
  blockDbCount: Integer;
  maxBlockDb, minBlockDb: Double;
  onsetTimes: TArray<Double>;
  a, r: Single;
begin
  Result := TAudioAnalysisResult.Empty;
  n := Length(AL);
  if Length(AR) < n then n := Length(AR);
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;

  Result.Frames := n;
  Result.SampleRate := ASampleRate;
  Result.DurationSec := n / ASampleRate;
  if n = 0 then Exit;

  { ---- peak / clipping / silence / correlation (single pass) ---- }
  peakLin := 0;
  sumSq := 0;
  sumLR := 0; sumLL := 0; sumRR := 0;
  clipCount := 0;
  silentFrames := 0;
  SetLength(mono, n);
  for i := 0 to n - 1 do
  begin
    a := AL[i]; r := AR[i];
    mono[i] := (a + r) * 0.5;
    if Abs(a) > peakLin then peakLin := Abs(a);
    if Abs(r) > peakLin then peakLin := Abs(r);
    sumSq := sumSq + (Double(a) * a + Double(r) * r) * 0.5;
    sumLR := sumLR + Double(a) * r;
    sumLL := sumLL + Double(a) * a;
    sumRR := sumRR + Double(r) * r;
    if (Abs(a) >= CLIP_THRESH_LIN) or (Abs(r) >= CLIP_THRESH_LIN) then Inc(clipCount);
    if (Abs(a) < SILENCE_THRESH_LIN) and (Abs(r) < SILENCE_THRESH_LIN) then Inc(silentFrames);
  end;
  Result.SamplePeakDb := SafeDb(peakLin);
  Result.RmsDb := SafeDb(Sqrt(sumSq / n));
  Result.CrestFactorDb := Result.SamplePeakDb - Result.RmsDb;
  Result.ClippingSamples := clipCount;
  Result.SilencePercent := 100.0 * silentFrames / n;
  if (sumLL > 1.0E-20) and (sumRR > 1.0E-20) then
  begin
    Result.StereoCorrelation := sumLR / Sqrt(sumLL * sumRR);
    if Result.StereoCorrelation > 1 then Result.StereoCorrelation := 1
    else if Result.StereoCorrelation < -1 then Result.StereoCorrelation := -1;
  end;

  { ---- true peak (dBTP) ---- }
  tpL.Init(ASampleRate);
  tpR.Init(ASampleRate);
  tpL.PushBlock(@AL[0], n);
  tpR.PushBlock(@AR[0], n);
  Result.TruePeakDb := Max(tpL.ValueDb, tpR.ValueDb);

  { ---- BS.1770 loudness ---- }
  loud := TLoudnessMeter.Create(ASampleRate, 2);
  try
    for i := 0 to n - 1 do
    begin
      frame[0] := AL[i];
      frame[1] := AR[i];
      loud.PushFrame(frame);
    end;
    Result.IntegratedLufs := loud.Integrated;
    Result.ShortTermLufs := loud.ShortTerm;
  finally
    loud.Free;
  end;

  { ---- dynamic range: spread of 1s-block RMS across non-silent blocks ---- }
  blockLen := ASampleRate;
  if blockLen < 1 then blockLen := 1;
  blockCount := n div blockLen;
  SetLength(blockDbList, blockCount);
  blockDbCount := 0;
  for blockIdx := 0 to blockCount - 1 do
  begin
    blockSumSq := 0;
    for i := blockIdx * blockLen to blockIdx * blockLen + blockLen - 1 do
      blockSumSq := blockSumSq + (Double(AL[i]) * AL[i] + Double(AR[i]) * AR[i]) * 0.5;
    a := Single(SafeDb(Sqrt(blockSumSq / blockLen)));
    if a > -50.0 then
    begin
      blockDbList[blockDbCount] := a;
      Inc(blockDbCount);
    end;
  end;
  if blockDbCount >= 2 then
  begin
    maxBlockDb := blockDbList[0]; minBlockDb := blockDbList[0];
    for i := 1 to blockDbCount - 1 do
    begin
      if blockDbList[i] > maxBlockDb then maxBlockDb := blockDbList[i];
      if blockDbList[i] < minBlockDb then minBlockDb := blockDbList[i];
    end;
    Result.DynamicRangeDb := maxBlockDb - minBlockDb;
  end;

  { ---- spectral centroid / rolloff / band energy / onsets ---- }
  RunSpectralPass(mono, ASampleRate, Result.SpectralCentroidHz, Result.SpectralRolloffHz,
    Result.LowBandEnergy, Result.MidBandEnergy, Result.HighBandEnergy, onsetTimes);

  if Length(onsetTimes) > 0 then
    Result.TransientDensityPerSec := Length(onsetTimes) / Result.DurationSec;
  Result.EstimatedBpm := EstimateBpm(onsetTimes);

  { ---- detected pitch ---- }
  Result.DetectedPitchHz := DetectPitchHz(mono, ASampleRate);
end;

{ ================= JSON ================= }

function AnalysisResultToJSON(const AResult: TAudioAnalysisResult): TJSONValue;
begin
  Result := JSONObject;
  Result.AddPair('duration_sec', JSONNumber(AResult.DurationSec));
  Result.AddPair('integrated_lufs', JSONNumber(AResult.IntegratedLufs));
  Result.AddPair('short_term_lufs', JSONNumber(AResult.ShortTermLufs));
  Result.AddPair('true_peak', JSONNumber(AResult.TruePeakDb));
  Result.AddPair('sample_peak_db', JSONNumber(AResult.SamplePeakDb));
  Result.AddPair('rms_db', JSONNumber(AResult.RmsDb));
  Result.AddPair('low_band_energy', JSONNumber(AResult.LowBandEnergy));
  Result.AddPair('mid_band_energy', JSONNumber(AResult.MidBandEnergy));
  Result.AddPair('high_band_energy', JSONNumber(AResult.HighBandEnergy));
  Result.AddPair('stereo_correlation', JSONNumber(AResult.StereoCorrelation));
  Result.AddPair('clipping_samples', JSONNumber(AResult.ClippingSamples));
  Result.AddPair('crest_factor_db', JSONNumber(AResult.CrestFactorDb));
  Result.AddPair('dynamic_range_db', JSONNumber(AResult.DynamicRangeDb));
  Result.AddPair('silence_percent', JSONNumber(AResult.SilencePercent));
  Result.AddPair('spectral_centroid_hz', JSONNumber(AResult.SpectralCentroidHz));
  Result.AddPair('spectral_rolloff_hz', JSONNumber(AResult.SpectralRolloffHz));
  Result.AddPair('detected_pitch_hz', JSONNumber(AResult.DetectedPitchHz));
  Result.AddPair('estimated_bpm', JSONNumber(AResult.EstimatedBpm));
  Result.AddPair('transient_density_per_sec', JSONNumber(AResult.TransientDensityPerSec));
end;

function AnalysisResultToJSONString(const AResult: TAudioAnalysisResult): string;
var
  v: TJSONValue;
begin
  v := AnalysisResultToJSON(AResult);
  try
    Result := v.ToJSONString;
  finally
    v.Free;
  end;
end;

end.
