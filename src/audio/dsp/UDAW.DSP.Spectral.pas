unit UDAW.DSP.Spectral;
{$I udaw.inc}
{$POINTERMATH ON}

{ Offline spectral tools built on the internal FFT (no third-party code):
  - TSTFT           sqrt-Hann, 75 % overlap analysis / overlap-add synthesis
  - SpectralDenoise noise-profile spectral subtraction with temporal smoothing
  - SplitStems      classical (non-neural) 4-stem split: percussive/harmonic
                    median-filter masks + bass crossover + centre-channel
                    similarity mask for vocals
  - ConvolveIR      uniform-partitioned FFT convolution (convolution reverb)
  - TPitchCorrector scale-aware auto-tune (per-window autocorrelation pitch,
                    phase-vocoder shift, overlap-added)
  All work on planar Single buffers and never touch the audio thread. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.FFT, UDAW.DSP.Analysis,
  UDAW.DSP.PitchShift;

type
  TSpecFrames = TArray<TArray<Double>>;

  TSTFT = class
  private
    FN: Integer;
    FHop: Integer;
    FFFT: TFFT;
    FWin: array of Single;
  public
    constructor Create(AFFTSize: Integer = 2048);
    destructor Destroy; override;
    procedure Analyze(const AIn: array of Single; out ARe, AIm: TSpecFrames);
    function Synthesize(const ARe, AIm: TSpecFrames; ALength: Integer): TAudioSampleArray;
    property Size: Integer read FN;
    property Hop: Integer read FHop;
    function Bins: Integer;
  end;

  TStemSet = record
    Drums, Bass, Vocals, Other: TAudioPlanar;
  end;

{ AL/AR: source. Noise profile taken from [ANoiseStart, ANoiseStart+ANoiseLen)
  samples. AReductionDb 0..40. }
procedure SpectralDenoise(const AIn: array of Single; ASampleRate: Integer;
  ANoiseStart, ANoiseLen: Integer; AReductionDb: Double; out AOut: TAudioSampleArray);

procedure SplitStems(const AL, AR: array of Single; ASampleRate: Integer;
  out AStems: TStemSet);

{ Classical (non-neural) speech / music separation.  Time-frequency masking from
  four cues: how far a bin rises above its own long-term level (speech is
  modulated, pads / hum / room tone are steady), the speech band, how centred
  the bin is between the channels, and the bass crossover.  AStrength 0..1
  sharpens the mask.  Voice + music add back up to the input. }
procedure SeparateSpeechMusic(const AL, AR: array of Single; ASampleRate: Integer;
  AStrength: Double; out AVoiceL, AVoiceR, AMusicL, AMusicR: TAudioSampleArray);

{ AIR: impulse response (mono). Output length = Length(AIn) + Length(AIR) - 1. }
procedure ConvolveIR(const AIn, AIR: array of Single; out AOut: TAudioSampleArray);

type
  TPitchCorrector = class
  public
    ScaleMask: array[0..11] of Boolean; { pitch classes allowed, 0 = C }
    Strength: Double;                   { 0..1 how far to move toward target }
    ReferenceA: Double;                 { tuning, default 440 }
    constructor Create;
    procedure SetChromatic;
    procedure SetMajor(ARoot: Integer);
    procedure SetMinor(ARoot: Integer);
    procedure Process(const AIn: array of Single; ASampleRate: Integer;
      out AOut: TAudioSampleArray);
  end;

implementation


uses
  UDAW.DSP.MathTables;

{ ---------------------------- STFT ---------------------------- }

constructor TSTFT.Create(AFFTSize: Integer);
var
  i: Integer;
begin
  inherited Create;
  FN := AFFTSize;
  FHop := FN div 4;
  FFFT := TFFT.Create(FN);
  SetLength(FWin, FN);
  for i := 0 to FN - 1 do
    FWin[i] := Sqrt(0.5 - 0.5 * FastCos(2.0 * Pi * i / FN));
end;

destructor TSTFT.Destroy;
begin
  FFFT.Free;
  inherited;
end;

function TSTFT.Bins: Integer;
begin
  Result := FN div 2 + 1;
end;

procedure TSTFT.Analyze(const AIn: array of Single; out ARe, AIm: TSpecFrames);
var
  frames, f, i, pos: Integer;
  buf: array of Single;
  re, im: TArray<Double>;
begin
  frames := (Length(AIn) + FN) div FHop + 1;
  SetLength(ARe, frames);
  SetLength(AIm, frames);
  SetLength(buf, FN);
  SetLength(re, Bins);
  SetLength(im, Bins);
  for f := 0 to frames - 1 do
  begin
    pos := f * FHop - FN + FHop; { frame f covers [pos, pos+N) ; first frame mostly pad }
    for i := 0 to FN - 1 do
      if (pos + i >= 0) and (pos + i < Length(AIn)) then
        buf[i] := AIn[pos + i] * FWin[i]
      else
        buf[i] := 0;
    FFFT.RealForward(buf, re, im);
    ARe[f] := Copy(re);
    AIm[f] := Copy(im);
  end;
end;

function TSTFT.Synthesize(const ARe, AIm: TSpecFrames; ALength: Integer): TAudioSampleArray;
var
  f, i, pos: Integer;
  buf: array of Single;
  acc: TArray<Double>;
begin
  SetLength(Result, ALength);
  SetLength(acc, ALength);
  SetLength(buf, FN);
  for f := 0 to High(ARe) do
  begin
    FFFT.RealInverse(ARe[f], AIm[f], buf);
    pos := f * FHop - FN + FHop;
    for i := 0 to FN - 1 do
      if (pos + i >= 0) and (pos + i < ALength) then
        acc[pos + i] := acc[pos + i] + buf[i] * FWin[i];
  end;
  { sum of squared sqrt-Hann at 75 % overlap = 2 }
  for i := 0 to ALength - 1 do
    Result[i] := Single(acc[i] * 0.5);
end;

{ ---------------------------- denoise ---------------------------- }

procedure SpectralDenoise(const AIn: array of Single; ASampleRate: Integer;
  ANoiseStart, ANoiseLen: Integer; AReductionDb: Double; out AOut: TAudioSampleArray);
var
  stft: TSTFT;
  re, im: TSpecFrames;
  noise: TArray<Double>;
  f, k, n0, n1, cnt, bins: Integer;
  mag, g, floorG, alpha: Double;
  prev: TArray<Double>;
begin
  stft := TSTFT.Create(2048);
  try
    stft.Analyze(AIn, re, im);
    bins := stft.Bins;
    SetLength(noise, bins);
    SetLength(prev, bins);
    n0 := Max(ANoiseStart, 0) div stft.Hop;
    n1 := Min((ANoiseStart + ANoiseLen) div stft.Hop, High(re));
    if n1 < n0 then n1 := n0;
    cnt := 0;
    for f := n0 to n1 do
    begin
      for k := 0 to bins - 1 do
        noise[k] := noise[k] + Sqrt(re[f][k] * re[f][k] + im[f][k] * im[f][k]);
      Inc(cnt);
    end;
    for k := 0 to bins - 1 do noise[k] := noise[k] / Max(cnt, 1);
    floorG := FastExp10(-EnsureRange(AReductionDb, 0.0, 60.0) / 20.0);
    alpha := 1.5; { over-subtraction }
    for k := 0 to bins - 1 do prev[k] := 1.0;
    for f := 0 to High(re) do
      for k := 0 to bins - 1 do
      begin
        mag := Sqrt(re[f][k] * re[f][k] + im[f][k] * im[f][k]);
        if mag > 1e-12 then
          g := Max(1.0 - alpha * noise[k] / mag, floorG)
        else
          g := floorG;
        { fast attack, slower release: avoids musical-noise chatter }
        if g < prev[k] then g := 0.5 * prev[k] + 0.5 * g
        else g := 0.8 * prev[k] + 0.2 * g;
        prev[k] := g;
        re[f][k] := re[f][k] * g;
        im[f][k] := im[f][k] * g;
      end;
    AOut := stft.Synthesize(re, im, Length(AIn));
  finally
    stft.Free;
  end;
end;

{ ---------------------------- stems ---------------------------- }

function MedianOf(var A: array of Double; ACount: Integer): Double;
var
  i, j: Integer;
  t: Double;
begin
  for i := 1 to ACount - 1 do
  begin
    t := A[i];
    j := i - 1;
    while (j >= 0) and (A[j] > t) do
    begin
      A[j + 1] := A[j];
      Dec(j);
    end;
    A[j + 1] := t;
  end;
  Result := A[ACount div 2];
end;

procedure SplitStems(const AL, AR: array of Single; ASampleRate: Integer;
  out AStems: TStemSet);
const
  MW = 8; { median half-width }
  XOVER = 180.0;
var
  stft: TSTFT;
  lr, li, rr, ri, mag, hm, pm: TSpecFrames;
  outRe, outIm: array[0..3, 0..1] of TSpecFrames; { stem, channel }
  frames, bins, f, k, j, cnt, n, s, c: Integer;
  tmp: array[0..2 * MW] of Double;
  h2, p2, mp, mh, cm, bassW, sim, a, b, binHz, mr, mi: Double;
  m: array[0..3] of Double;
  procedure NewSet(var S2: TSpecFrames);
  var q: Integer;
  begin
    SetLength(S2, frames);
    for q := 0 to frames - 1 do SetLength(S2[q], bins);
  end;
begin
  n := Min(Length(AL), Length(AR));
  stft := TSTFT.Create(2048);
  try
    stft.Analyze(Slice(AL, n), lr, li);
    stft.Analyze(Slice(AR, n), rr, ri);
    frames := Length(lr);
    bins := stft.Bins;
    NewSet(mag); NewSet(hm); NewSet(pm);
    for s := 0 to 3 do
      for c := 0 to 1 do
      begin
        NewSet(outRe[s, c]);
        NewSet(outIm[s, c]);
      end;
    for f := 0 to frames - 1 do
      for k := 0 to bins - 1 do
      begin
        mr := lr[f][k] + rr[f][k];
        mi := li[f][k] + ri[f][k];
        mag[f][k] := 0.5 * Sqrt(mr * mr + mi * mi);
      end;
    { harmonic = median along time, percussive = median along frequency }
    for f := 0 to frames - 1 do
      for k := 0 to bins - 1 do
      begin
        cnt := 0;
        for j := Max(f - MW, 0) to Min(f + MW, frames - 1) do
        begin
          tmp[cnt] := mag[j][k];
          Inc(cnt);
        end;
        hm[f][k] := MedianOf(tmp, cnt);
        cnt := 0;
        for j := Max(k - MW, 0) to Min(k + MW, bins - 1) do
        begin
          tmp[cnt] := mag[f][j];
          Inc(cnt);
        end;
        pm[f][k] := MedianOf(tmp, cnt);
      end;
    binHz := ASampleRate / stft.Size;
    for f := 0 to frames - 1 do
      for k := 0 to bins - 1 do
      begin
        h2 := hm[f][k] * hm[f][k];
        p2 := pm[f][k] * pm[f][k];
        if h2 + p2 < 1e-24 then mp := 0.5 else mp := p2 / (h2 + p2);
        mh := 1.0 - mp;
        bassW := EnsureRange((XOVER * 1.25 - k * binHz) / (XOVER * 0.5), 0.0, 1.0);
        { centre similarity: 1 when L == R (complex distance), 0 when unrelated }
        a := Sqrt(Sqr(lr[f][k] - rr[f][k]) + Sqr(li[f][k] - ri[f][k]));
        b := Sqrt(Sqr(lr[f][k] + rr[f][k]) + Sqr(li[f][k] + ri[f][k]));
        if b < 1e-12 then sim := 0 else sim := EnsureRange(1.0 - a / b, 0.0, 1.0);
        cm := sim * sim;
        { complementary masks -> the four stems sum back to the input }
        m[0] := mp;
        m[1] := mh * bassW;
        m[2] := mh * (1 - bassW) * cm;
        m[3] := mh * (1 - bassW) * (1 - cm);
        for s := 0 to 3 do
        begin
          outRe[s, 0][f][k] := lr[f][k] * m[s];
          outIm[s, 0][f][k] := li[f][k] * m[s];
          outRe[s, 1][f][k] := rr[f][k] * m[s];
          outIm[s, 1][f][k] := ri[f][k] * m[s];
        end;
      end;
    SetLength(AStems.Drums, 2); SetLength(AStems.Bass, 2);
    SetLength(AStems.Vocals, 2); SetLength(AStems.Other, 2);
    for c := 0 to 1 do
    begin
      AStems.Drums[c] := stft.Synthesize(outRe[0, c], outIm[0, c], n);
      AStems.Bass[c] := stft.Synthesize(outRe[1, c], outIm[1, c], n);
      AStems.Vocals[c] := stft.Synthesize(outRe[2, c], outIm[2, c], n);
      AStems.Other[c] := stft.Synthesize(outRe[3, c], outIm[3, c], n);
    end;
  finally
    stft.Free;
  end;
end;

{ ---------------------------- speech / music ---------------------------- }

procedure SeparateSpeechMusic(const AL, AR: array of Single; ASampleRate: Integer;
  AStrength: Double; out AVoiceL, AVoiceR, AMusicL, AMusicR: TAudioSampleArray);
const
  LONG_W = 40;   { +/- frames of the long-term level (about 0.9 s at 44.1 kHz) }
var
  stft: TSTFT;
  lr, li, rr, ri, mask, sm: TSpecFrames;
  vr, vi, wr, wi: array[0..1] of TSpecFrames;
  logPre: TSpecFrames;       { running sums of ln(magnitude) along time, per bin }
  frames, bins, f, k, n, c, f0, f1, cnt, df, dk, ff, kk: Integer;
  binHz, hz, mag, longLvl, r, t, act, band, a, b, sim, cm, p, acc, m: Double;
begin
  n := Min(Length(AL), Length(AR));
  SetLength(AVoiceL, n); SetLength(AVoiceR, n);
  SetLength(AMusicL, n); SetLength(AMusicR, n);
  if n < 2048 then
  begin
    { too short to analyse: everything counts as voice }
    for f := 0 to n - 1 do
    begin
      AVoiceL[f] := AL[f]; AVoiceR[f] := AR[f];
      AMusicL[f] := 0; AMusicR[f] := 0;
    end;
    Exit;
  end;
  AStrength := EnsureRange(AStrength, 0.0, 1.0);
  p := 1.0 + 2.0 * AStrength;
  stft := TSTFT.Create(2048);
  try
    stft.Analyze(Slice(AL, n), lr, li);
    stft.Analyze(Slice(AR, n), rr, ri);
    frames := Length(lr);
    bins := stft.Bins;
    binHz := ASampleRate / stft.Size;
    SetLength(logPre, frames + 1);
    for f := 0 to frames do SetLength(logPre[f], bins);
    for k := 0 to bins - 1 do logPre[0][k] := 0;
    for f := 0 to frames - 1 do
      for k := 0 to bins - 1 do
      begin
        mag := 0.5 * Sqrt(Sqr(lr[f][k] + rr[f][k]) + Sqr(li[f][k] + ri[f][k]));
        logPre[f + 1][k] := logPre[f][k] + FastLn(mag + 1E-9);
      end;
    SetLength(mask, frames);
    for f := 0 to frames - 1 do
    begin
      SetLength(mask[f], bins);
      f0 := Max(0, f - LONG_W);
      f1 := Min(frames - 1, f + LONG_W);
      cnt := f1 - f0 + 1;
      for k := 0 to bins - 1 do
      begin
        mag := 0.5 * Sqrt(Sqr(lr[f][k] + rr[f][k]) + Sqr(li[f][k] + ri[f][k]));
        longLvl := FastExp((logPre[f1 + 1][k] - logPre[f0][k]) / cnt);
        r := (mag + 1E-9) / (longLvl + 1E-9);
        t := EnsureRange((r - 1.0) / 2.5, 0.0, 1.0);
        act := t * t * (3.0 - 2.0 * t);
        hz := k * binHz;
        if hz < 60 then band := 0.0
        else if hz < 110 then band := (hz - 60) / 50
        else if hz < 4500 then band := 1.0
        else if hz < 9000 then band := 1.0 - (hz - 4500) / 4500 * 0.65
        else band := 0.2;
        a := Sqrt(Sqr(lr[f][k] - rr[f][k]) + Sqr(li[f][k] - ri[f][k]));
        b := Sqrt(Sqr(lr[f][k] + rr[f][k]) + Sqr(li[f][k] + ri[f][k]));
        if b < 1E-12 then sim := 0 else sim := EnsureRange(1.0 - a / b, 0.0, 1.0);
        cm := sim * sim;
        m := band * (0.25 + 0.75 * act) * (0.35 + 0.65 * cm);
        mask[f][k] := FastPow(EnsureRange(m, 0.0, 1.0), p);
      end;
    end;
    { 3 x 3 box smoothing of the mask: removes isolated "musical noise" bins }
    SetLength(sm, frames);
    for f := 0 to frames - 1 do
    begin
      SetLength(sm[f], bins);
      for k := 0 to bins - 1 do
      begin
        acc := 0;
        cnt := 0;
        for df := -1 to 1 do
          for dk := -1 to 1 do
          begin
            ff := f + df;
            kk := k + dk;
            if (ff >= 0) and (ff < frames) and (kk >= 0) and (kk < bins) then
            begin
              acc := acc + mask[ff][kk];
              Inc(cnt);
            end;
          end;
        sm[f][k] := acc / cnt;
      end;
    end;
    for c := 0 to 1 do
    begin
      SetLength(vr[c], frames); SetLength(vi[c], frames);
      SetLength(wr[c], frames); SetLength(wi[c], frames);
    end;
    for f := 0 to frames - 1 do
    begin
      for c := 0 to 1 do
      begin
        SetLength(vr[c][f], bins); SetLength(vi[c][f], bins);
        SetLength(wr[c][f], bins); SetLength(wi[c][f], bins);
      end;
      for k := 0 to bins - 1 do
      begin
        m := sm[f][k];
        vr[0][f][k] := lr[f][k] * m;       vi[0][f][k] := li[f][k] * m;
        vr[1][f][k] := rr[f][k] * m;       vi[1][f][k] := ri[f][k] * m;
        wr[0][f][k] := lr[f][k] * (1 - m); wi[0][f][k] := li[f][k] * (1 - m);
        wr[1][f][k] := rr[f][k] * (1 - m); wi[1][f][k] := ri[f][k] * (1 - m);
      end;
    end;
    AVoiceL := stft.Synthesize(vr[0], vi[0], n);
    AVoiceR := stft.Synthesize(vr[1], vi[1], n);
    AMusicL := stft.Synthesize(wr[0], wi[0], n);
    AMusicR := stft.Synthesize(wr[1], wi[1], n);
  finally
    stft.Free;
  end;
end;

{ ---------------------------- convolution ---------------------------- }

procedure ConvolveIR(const AIn, AIR: array of Single; out AOut: TAudioSampleArray);
const
  B = 2048; { partition size; FFT size 2B }
var
  fft: TFFT;
  np, i, j, blk, nblk, outLen, pos, idx: Integer;
  hr, hi: array of array of Double; { IR partition spectra }
  fr, fi: array of array of Double; { frequency delay line }
  xr, xi, yr, yi: array of Double;
  acc: TArray<Double>;
  t: Double;
begin
  outLen := Length(AIn) + Length(AIR) - 1;
  if (Length(AIn) = 0) or (Length(AIR) = 0) then
  begin
    SetLength(AOut, 0);
    Exit;
  end;
  fft := TFFT.Create(2 * B);
  try
    np := (Length(AIR) + B - 1) div B;
    SetLength(hr, np); SetLength(hi, np); SetLength(fr, np); SetLength(fi, np);
    SetLength(xr, 2 * B); SetLength(xi, 2 * B);
    SetLength(yr, 2 * B); SetLength(yi, 2 * B);
    for j := 0 to np - 1 do
    begin
      SetLength(hr[j], 2 * B); SetLength(hi[j], 2 * B);
      SetLength(fr[j], 2 * B); SetLength(fi[j], 2 * B);
      for i := 0 to 2 * B - 1 do
      begin
        hr[j][i] := 0; hi[j][i] := 0;
        if (i < B) and (j * B + i < Length(AIR)) then hr[j][i] := AIR[j * B + i];
      end;
      fft.ForwardInPlace(hr[j], hi[j]);
    end;
    SetLength(acc, outLen + 4 * B);
    nblk := (Length(AIn) + B - 1) div B + np;
    for blk := 0 to nblk - 1 do
    begin
      { shift delay line: newest at index 0 }
      for j := np - 1 downto 1 do
      begin
        Move(fr[j - 1][0], fr[j][0], 2 * B * SizeOf(Double));
        Move(fi[j - 1][0], fi[j][0], 2 * B * SizeOf(Double));
      end;
      for i := 0 to 2 * B - 1 do
      begin
        xr[i] := 0; xi[i] := 0;
        pos := blk * B + i;
        if (i < B) and (pos < Length(AIn)) then xr[i] := AIn[pos];
      end;
      fft.ForwardInPlace(xr, xi);
      Move(xr[0], fr[0][0], 2 * B * SizeOf(Double));
      Move(xi[0], fi[0][0], 2 * B * SizeOf(Double));
      for i := 0 to 2 * B - 1 do begin yr[i] := 0; yi[i] := 0; end;
      for j := 0 to Min(np - 1, blk) do
        for i := 0 to 2 * B - 1 do
        begin
          yr[i] := yr[i] + fr[j][i] * hr[j][i] - fi[j][i] * hi[j][i];
          yi[i] := yi[i] + fr[j][i] * hi[j][i] + fi[j][i] * hr[j][i];
        end;
      fft.InverseInPlace(yr, yi);
      for i := 0 to 2 * B - 1 do
      begin
        idx := blk * B + i;
        if idx < Length(acc) then acc[idx] := acc[idx] + yr[i];
      end;
    end;
    SetLength(AOut, outLen);
    for i := 0 to outLen - 1 do
    begin
      t := acc[i];
      AOut[i] := Single(t);
    end;
  finally
    fft.Free;
  end;
end;

{ ---------------------------- pitch correction ---------------------------- }

constructor TPitchCorrector.Create;
begin
  inherited Create;
  Strength := 1.0;
  ReferenceA := 440.0;
  SetChromatic;
end;

procedure TPitchCorrector.SetChromatic;
var
  i: Integer;
begin
  for i := 0 to 11 do ScaleMask[i] := True;
end;

procedure TPitchCorrector.SetMajor(ARoot: Integer);
const
  IV: array[0..6] of Integer = (0, 2, 4, 5, 7, 9, 11);
var
  i: Integer;
begin
  for i := 0 to 11 do ScaleMask[i] := False;
  for i := 0 to 6 do ScaleMask[(ARoot + IV[i]) mod 12] := True;
end;

procedure TPitchCorrector.SetMinor(ARoot: Integer);
const
  IV: array[0..6] of Integer = (0, 2, 3, 5, 7, 8, 10);
var
  i: Integer;
begin
  for i := 0 to 11 do ScaleMask[i] := False;
  for i := 0 to 6 do ScaleMask[(ARoot + IV[i]) mod 12] := True;
end;

procedure TPitchCorrector.Process(const AIn: array of Single; ASampleRate: Integer;
  out AOut: TAudioSampleArray);
const
  WIN = 4096;
  HOP = 1024;
var
  shifter: TPitchShifter;
  acc, wsum: TArray<Double>;
  seg: TArray<Single>;
  shifted: TArray<Single>;
  mono: TAudioSampleArray;
  pos, i, n, cand, best, midiNear, d, bestD, maxD, j, L, a, si: Integer;
  hz, midi, target, semis, w, bestDist, dist, score, bestScore, energy: Double;
  shiftedWin: Boolean;
begin
  n := Length(AIn);
  SetLength(AOut, n);
  if n = 0 then Exit;
  SetLength(acc, n + WIN);
  SetLength(wsum, n + WIN);
  SetLength(seg, WIN);
  SetLength(mono, WIN);
  shifter := TPitchShifter.Create(2048);
  try
    pos := -WIN + HOP;
    while pos < n do
    begin
      for i := 0 to WIN - 1 do
        if (pos + i >= 0) and (pos + i < n) then seg[i] := AIn[pos + i] else seg[i] := 0;
      for i := 0 to WIN - 1 do mono[i] := seg[i];
      hz := DetectPitchHz(mono, ASampleRate);
      semis := 0;
      if hz > 50.0 then
      begin
        midi := 69.0 + 12.0 * Log2(hz / ReferenceA);
        midiNear := Round(midi);
        best := midiNear;
        bestDist := 1e9;
        for cand := midiNear - 6 to midiNear + 6 do
          if ScaleMask[((cand mod 12) + 12) mod 12] then
          begin
            dist := Abs(cand - midi);
            if dist < bestDist then begin bestDist := dist; best := cand; end;
          end;
        target := best;
        semis := (target - midi) * EnsureRange(Strength, 0.0, 1.0);
      end;
      shiftedWin := Abs(semis) > 0.02;
      if shiftedWin then
      begin
        shifter.Process(seg, semis, ASampleRate, shifted);
        if Length(shifted) < WIN then SetLength(shifted, WIN);
      end
      else
        shifted := Copy(seg);
      { Phase alignment. Each window is shifted on its own, so its phase at the
        window start is the INPUT's phase; dropped in as is, neighbouring
        windows disagree and the overlap-add drifts back to the input's
        frequency (the correction cancels out over time). Slide the window by
        up to one pitch period to the lag where it best continues the output
        already built (waveform-similarity alignment), so the shifted pitch
        carries on across window boundaries. Smallest |lag| wins ties, so an
        untouched passage stays an exact copy. }
      d := 0;
      if (hz > 50.0) and (pos > 0) then
      begin
        maxD := Min(Round(ASampleRate / hz), (WIN - HOP) div 2);
        L := Min(HOP, WIN - 2 * maxD);
        bestScore := -1.0E30;
        bestD := 0;
        for j := 0 to 2 * maxD do
        begin
          if j = 0 then d := 0
          else if j and 1 = 1 then d := (j + 1) div 2
          else d := -(j div 2);
          score := 0;
          energy := 1.0E-9;
          for i := 0 to L - 1 do
          begin
            a := pos + maxD + i;
            si := maxD + i - d;
            if (a >= 0) and (a < n) and (wsum[a] > 1.0E-6) and (si >= 0) and (si < WIN) then
            begin
              score := score + (acc[a] / wsum[a]) * shifted[si];
              energy := energy + Double(shifted[si]) * shifted[si];
            end;
          end;
          score := score / Sqrt(energy);
          if score > bestScore + 1.0E-9 then
          begin
            bestScore := score;
            bestD := d;
          end;
        end;
        d := bestD;
      end;
      for i := 0 to WIN - 1 do
        if (pos + d + i >= 0) and (pos + d + i < n) then
        begin
          w := 0.5 - 0.5 * FastCos(2.0 * Pi * i / WIN);
          acc[pos + d + i] := acc[pos + d + i] + shifted[i] * w;
          wsum[pos + d + i] := wsum[pos + d + i] + w;
        end;
      Inc(pos, HOP);
    end;
    for i := 0 to n - 1 do
      if wsum[i] > 1e-6 then AOut[i] := Single(acc[i] / wsum[i]) else AOut[i] := AIn[i];
  finally
    shifter.Free;
  end;
end;

end.
