unit UDAW.DSP.TempoDetect;
{$I udaw.inc}

{ Offline tempo estimator: log-energy onset envelope (200 Hz frame rate) ->
  autocorrelation over the 60..200 BPM lag range -> parabolic peak refinement,
  then octave-folded into 80..160 BPM. Returns 0 when there is not enough
  rhythmic content to decide (silence, < 4 s, no clear periodicity). Clean-room,
  no third-party code. Intended for one-shot analysis of an imported clip, not
  for the real-time thread. }

interface

{ AChannel0/AChannel1: planar PCM (AChannel1 may be nil/empty for mono). }
function EstimateTempoBPM(const AChannel0, AChannel1: array of Single;
  AFrameCount, ASampleRate: Integer): Double;

implementation

uses UDAW.DSP.MathTables, Math;

const
  ENV_RATE = 200;            // envelope frames per second
  MAX_ANALYSIS_SECONDS = 90;
  MIN_ANALYSIS_SECONDS = 4;

function EstimateTempoBPM(const AChannel0, AChannel1: array of Single;
  AFrameCount, ASampleRate: Integer): Double;
var
  hop, win, frames, i, j, start, lag, minLag, maxLag, bestLag, n: Integer;
  total: Integer;
  e, prevE, s, m, best, v, a, b, c, denom, delta, bpm: Double;
  env, flux: TArray<Double>;
  ac: TArray<Double>;
  haveR: Boolean;
begin
  Result := 0;
  if (ASampleRate <= 0) or (AFrameCount <= 0) or (Length(AChannel0) < AFrameCount) then Exit;
  total := Min(AFrameCount, ASampleRate * MAX_ANALYSIS_SECONDS);
  if total < ASampleRate * MIN_ANALYSIS_SECONDS then Exit;
  haveR := Length(AChannel1) >= AFrameCount;

  hop := Max(1, ASampleRate div ENV_RATE);
  win := hop * 2;
  frames := total div hop;
  if frames < ENV_RATE * MIN_ANALYSIS_SECONDS then Exit;

  SetLength(env, frames);
  for i := 0 to frames - 1 do
  begin
    start := i * hop;
    s := 0;
    n := 0;
    for j := start to Min(start + win, total) - 1 do
    begin
      v := AChannel0[j];
      if haveR then v := (v + AChannel1[j]) * 0.5;
      s := s + v * v;
      Inc(n);
    end;
    if n > 0 then env[i] := Sqrt(s / n) else env[i] := 0;
  end;

  { onset strength: half-wave rectified rise of compressed energy }
  SetLength(flux, frames);
  prevE := 0;
  m := 0;
  for i := 0 to frames - 1 do
  begin
    e := FastLn(1 + 100 * env[i]);
    if e > prevE then flux[i] := e - prevE else flux[i] := 0;
    prevE := e;
    m := m + flux[i];
  end;
  m := m / frames;
  if m < 1e-6 then Exit;   // silence / no onsets
  for i := 0 to frames - 1 do flux[i] := flux[i] - m;

  minLag := Round(60.0 * ENV_RATE / 200.0);   // 200 BPM
  maxLag := Round(60.0 * ENV_RATE / 60.0);    // 60 BPM
  if maxLag + 2 >= frames then Exit;
  SetLength(ac, maxLag + 2);
  for lag := minLag - 1 to maxLag + 1 do
  begin
    s := 0;
    for i := lag to frames - 1 do s := s + flux[i] * flux[i - lag];
    ac[lag] := s / (frames - lag);
  end;

  best := 0;
  bestLag := 0;
  for lag := minLag to maxLag do
    if (ac[lag] > ac[lag - 1]) and (ac[lag] >= ac[lag + 1]) and (ac[lag] > best) then
    begin
      best := ac[lag];
      bestLag := lag;
    end;
  if (bestLag = 0) or (best <= 0) then Exit;

  { parabolic refinement of the peak position }
  a := ac[bestLag - 1]; b := ac[bestLag]; c := ac[bestLag + 1];
  denom := a - 2 * b + c;
  if Abs(denom) > 1e-12 then delta := 0.5 * (a - c) / denom else delta := 0;
  if (delta < -1) or (delta > 1) then delta := 0;

  bpm := 60.0 * ENV_RATE / (bestLag + delta);
  while bpm < 80 do bpm := bpm * 2;
  while bpm > 160 do bpm := bpm / 2;
  Result := Round(bpm * 10) / 10;
end;

end.
