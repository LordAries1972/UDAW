unit UDAW.Timeline.LoopScan;
{$I udaw.inc}

{ Loop-segment scanner behind Timeline > Tools > Scan Loop Segments. UI-free so
  it can be tested.

  A segment runs from one near-silent point to the next, each cut on a zero
  crossing at the quietest sample of its dip, so a segment can be looped
  without a click. The
  length of each segment is then matched against the note lengths loops are
  built from: 1/4, 1/8, 1/16, 1/32, 1/64, 2/4 and 4/4 (a quarter note is one
  beat, so 4/4 is a whole bar of four beats). }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types;

type
  TLoopDivision = (ldQuarter, ldEighth, ldSixteenth, ldThirtySecond, ldSixtyFourth,
    ldHalfBar, ldBar);

const
  LOOP_DEFAULT_SILENCE_DB = 12.0;     // a quiet point lies this many dB below the music around it
  LOOP_DEFAULT_MIN_SILENCE = 0.02;    // quiet points are at least this many seconds apart
  LOOP_DEFAULT_TOLERANCE = 0.10;      // allowed length error, fraction of the note length
  LOOP_MIN_TOLERANCE_SEC = 0.008;     // never tighter than this, whatever the tempo

function LoopDivisionName(ADiv: TLoopDivision): string;
{ length of the division in quarter notes (beats) }
function LoopDivisionBeats(ADiv: TLoopDivision): Double;

{ Cut points (frames, relative to AStartFrame, ascending): the quiet points of the
  region - local minima of the level lying ADepthDb below the loudest level
  around them - each placed on a zero crossing at the quietest sample, so a
  segment between two cuts starts and ends silent and loops without a click.
  Consecutive pairs are the segments; the region's own edges are NOT cuts unless
  they are quiet points. Empty when fewer than two are found. }
function FindLoopCuts(const AIn: TAudioPlanar; AChannels, AStartFrame, AFrameCount,
  ASampleRate: Integer; ADepthDb: Double = LOOP_DEFAULT_SILENCE_DB;
  AMinGapSec: Double = LOOP_DEFAULT_MIN_SILENCE): TArray<Integer>;

{ Which division (if any) a segment of ALengthSec seconds is a whole multiple of
  at AQuarterSec seconds per quarter note - the closest one wins. }
function ClassifyLoopLength(ALengthSec, AQuarterSec: Double; out ADiv: TLoopDivision;
  ATolerance: Double = LOOP_DEFAULT_TOLERANCE): Boolean;

type
  TLoopSegment = record
    StartFrame, EndFrame: Integer;   // relative to the scanned region
    Division: TLoopDivision;
  end;

  {$IFDEF FPC}
  TQuarterSecondsAt = function(AFrame: Integer): Double of object;
  {$ELSE}
  TQuarterSecondsAt = reference to function(AFrame: Integer): Double;
  {$ENDIF}

{ Walks the cut points from FindLoopCuts. From each cut it looks at the cuts
  that follow, up to a bar ahead, and takes the farthest one whose distance is
  a whole 1/4 .. 4/4 (AQuarterAt gives seconds per quarter note at a region
  frame). When none fits, the walk moves on to the next cut. So a loop with
  small gaps inside it is captured whole, not as its pieces. ASkipped counts
  the cuts that started no segment. }
function MatchLoopSegments(const ACuts: TArray<Integer>; ASampleRate: Integer;
  const AQuarterAt: TQuarterSecondsAt; out ASkipped: Integer;
  ATolerance: Double = LOOP_DEFAULT_TOLERANCE): TArray<TLoopSegment>;

implementation

const
  ENVELOPE_WINDOW_SEC = 0.005;

function LoopDivisionName(ADiv: TLoopDivision): string;
begin
  case ADiv of
    ldQuarter:      Result := '1/4';
    ldEighth:       Result := '1/8';
    ldSixteenth:    Result := '1/16';
    ldThirtySecond: Result := '1/32';
    ldSixtyFourth:  Result := '1/64';
    ldHalfBar:      Result := '2/4';
  else
    Result := '4/4';
  end;
end;

function LoopDivisionBeats(ADiv: TLoopDivision): Double;
begin
  case ADiv of
    ldQuarter:      Result := 1.0;
    ldEighth:       Result := 0.5;
    ldSixteenth:    Result := 0.25;
    ldThirtySecond: Result := 0.125;
    ldSixtyFourth:  Result := 0.0625;
    ldHalfBar:      Result := 2.0;
  else
    Result := 4.0;
  end;
end;

function FindLoopCuts(const AIn: TAudioPlanar; AChannels, AStartFrame, AFrameCount,
  ASampleRate: Integer; ADepthDb, AMinGapSec: Double): TArray<Integer>;
var
  hop, nWin, radius, ctxWin, w, k, ch, f, lo, hi, base, bestZ, bestAny, nKept: Integer;
  env: array of Double;
  peak, s, v, ctxMax, e, depth, mixNow, mixNext, bestZAbs, bestAnyAbs: Double;
  isMin: Boolean;
  cand: TArray<Integer>;   // window indices
  kept: TArray<Integer>;

  function Mix(AFrame: Integer): Double;
  var
    c: Integer;
  begin
    Result := 0;
    for c := 0 to AChannels - 1 do Result := Result + AIn[c][AStartFrame + AFrame];
  end;

begin
  Result := nil;
  if (AChannels <= 0) or (ASampleRate <= 0) or (AFrameCount <= 0) or
     (Length(AIn) < AChannels) then Exit;
  hop := Max(Round(ENVELOPE_WINDOW_SEC * ASampleRate), 16);
  nWin := AFrameCount div hop;
  if nWin < 3 then Exit;

  { windowed RMS level, channels together }
  SetLength(env, nWin);
  peak := 0;
  for w := 0 to nWin - 1 do
  begin
    s := 0;
    for ch := 0 to AChannels - 1 do
      for f := 0 to hop - 1 do
      begin
        v := AIn[ch][AStartFrame + w * hop + f];
        s := s + v * v;
      end;
    e := Sqrt(s / (hop * AChannels));
    env[w] := e;
    if e > peak then peak := e;
  end;
  if peak < 1e-5 then Exit;                       // nothing but digital silence

  radius := Max(Ceil(AMinGapSec * ASampleRate / hop), 1);
  ctxWin := Max(Round(0.25 * ASampleRate / hop), radius * 2);

  { a quiet point is a local minimum of the level that lies ADepthDb below the loudest level in
    the quarter second around it (so dense music is judged against itself, not the clip's peak);
    anything under -80 dBFS-of-peak counts as quiet whatever surrounds it. A plateau
    (digital silence) yields its LAST window, just ahead of the next sound. }
  cand := nil;
  for w := 0 to nWin - 1 do
  begin
    isMin := True;
    for k := Max(0, w - radius) to w - 1 do
      if env[k] < env[w] then begin isMin := False; Break; end;
    if isMin then
      for k := w + 1 to Min(nWin - 1, w + radius) do
        if env[k] <= env[w] then begin isMin := False; Break; end;
    if not isMin then Continue;
    if env[w] < peak * 1e-4 then
      cand := cand + [w]
    else
    begin
      ctxMax := 0;
      for k := Max(0, w - ctxWin) to Min(nWin - 1, w + ctxWin) do
        if env[k] > ctxMax then ctxMax := env[k];
      depth := 20.0 * Log10(ctxMax / Max(env[w], 1e-9));
      if depth > Abs(ADepthDb) then cand := cand + [w];
    end;
  end;

  { keep quiet points at least AMinGapSec apart: of two close ones, the quieter wins }
  kept := nil;
  nKept := 0;
  for k := 0 to High(cand) do
  begin
    if (nKept > 0) and (cand[k] - kept[nKept - 1] < radius) then
    begin
      if env[cand[k]] < env[kept[nKept - 1]] then kept[nKept - 1] := cand[k];
    end
    else
    begin
      kept := kept + [cand[k]];
      Inc(nKept);
    end;
  end;

  { place each cut inside its window on a zero crossing at the quietest sample, so both ends of
    a segment are silent and click-free and the segment can be looped }
  for k := 0 to High(kept) do
  begin
    base := kept[k] * hop;
    lo := base;
    hi := Min(base + hop - 1, AFrameCount - 2);
    bestZ := -1;
    bestAny := lo;
    bestZAbs := MaxDouble;
    bestAnyAbs := MaxDouble;
    mixNow := Mix(lo);
    for f := lo to hi do
    begin
      mixNext := Mix(f + 1);
      if Abs(mixNow) <= bestAnyAbs then begin bestAnyAbs := Abs(mixNow); bestAny := f; end;
      if (mixNow * mixNext <= 0) and (Abs(mixNow) <= bestZAbs) then
      begin
        bestZAbs := Abs(mixNow);
        bestZ := f;
      end;
      mixNow := mixNext;
    end;
    if bestZ >= 0 then Result := Result + [bestZ] else Result := Result + [bestAny];
  end;
  if Length(Result) < 2 then Result := nil;
end;

function ClassifyLoopLength(ALengthSec, AQuarterSec: Double; out ADiv: TLoopDivision;
  ATolerance: Double): Boolean;
var
  d: TLoopDivision;
  target, err, bestErr, tol: Double;
begin
  Result := False;
  ADiv := ldQuarter;
  if (ALengthSec <= 0) or (AQuarterSec <= 0) then Exit;
  bestErr := MaxDouble;
  for d := Low(TLoopDivision) to High(TLoopDivision) do
  begin
    target := LoopDivisionBeats(d) * AQuarterSec;
    err := Abs(ALengthSec - target);
    tol := Max(ATolerance * target, LOOP_MIN_TOLERANCE_SEC);
    if (err <= tol) and (err < bestErr) then
    begin
      bestErr := err;
      ADiv := d;
      Result := True;
    end;
  end;
end;

function MatchLoopSegments(const ACuts: TArray<Integer>; ASampleRate: Integer;
  const AQuarterAt: TQuarterSecondsAt; out ASkipped: Integer;
  ATolerance: Double): TArray<TLoopSegment>;
var
  i, j, bestJ, n: Integer;
  q, len: Double;
  d, bestD: TLoopDivision;
  seg: TLoopSegment;
begin
  Result := nil;
  ASkipped := 0;
  n := Length(ACuts);
  if (n < 2) or (ASampleRate <= 0) then Exit;
  i := 0;
  while i < n - 1 do
  begin
    q := AQuarterAt(ACuts[i]);
    bestJ := -1;
    bestD := ldQuarter;
    if q > 0 then
      for j := i + 1 to n - 1 do
      begin
        len := (ACuts[j] - ACuts[i]) / ASampleRate;
        if len > LoopDivisionBeats(ldBar) * q * (1 + ATolerance) + LOOP_MIN_TOLERANCE_SEC then Break;
        if ClassifyLoopLength(len, q, d, ATolerance) then
        begin
          bestJ := j;
          bestD := d;
        end;
      end;
    if bestJ >= 0 then
    begin
      seg.StartFrame := ACuts[i];
      seg.EndFrame := ACuts[bestJ];
      seg.Division := bestD;
      Result := Result + [seg];
      i := bestJ;
    end
    else
    begin
      Inc(ASkipped);
      Inc(i);
    end;
  end;
end;

end.
