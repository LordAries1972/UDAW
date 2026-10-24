unit UDAW.Timeline.Warp;
{$I udaw.inc}

{ Warp markers (Ableton/FL "audio warping"): pin points in a clip's audio to
  new positions so the material between them is time-stretched (pitch
  preserved) - used to lock a loose performance or a sample to the beat grid.

  A marker maps a source time (seconds into the clip window) to a destination
  time (seconds into the warped result). Between consecutive markers the
  audio is phase-vocoder stretched by dst-length / src-length; before the
  first / after the last marker the tempo is unchanged (factor 1).

  AutoWarpMarkers detects onsets (spectral flux) and pins each strong onset
  that lies close to a beat line onto that line. All offline, UI-free. }

interface

uses
  SysUtils, Math, Generics.Collections, Generics.Defaults,
  UDAW.Audio.Types, UDAW.DSP.FFT, UDAW.DSP.TimeStretch;

type
  TWarpMarker = record
    SrcSec: Double;
    DstSec: Double;
  end;
  TWarpMarkers = TArray<TWarpMarker>;

const
  WARP_MIN_SEGMENT_SEC = 0.05;
  WARP_MIN_FACTOR = 0.25;
  WARP_MAX_FACTOR = 4.0;

{ keeps markers sorted by SrcSec, strictly increasing in both SrcSec and
  DstSec, and drops any that would squeeze a segment below the minimum. }
procedure NormalizeWarpMarkers(var AMarkers: TWarpMarkers);

procedure AddWarpMarker(var AMarkers: TWarpMarkers; ASrcSec, ADstSec: Double);

{ index of the marker whose SrcSec is nearest ASrcSec within ATolSec, else -1 }
function NearestWarpMarker(const AMarkers: TWarpMarkers; ASrcSec, ATolSec: Double): Integer;

{ onset times (seconds) via half-wave-rectified spectral flux + adaptive
  threshold peak picking }
function DetectOnsets(const AMono: array of Single; ASampleRate: Integer): TArray<Double>;

{ ABpm and AClipStartSec place the beat grid on the absolute timeline:
  beat n is at n*60/ABpm; markers are relative to the clip's start. Only
  onsets within AMaxShiftBeats of a beat line are pinned. }
function AutoWarpMarkers(const AOnsets: TArray<Double>; ABpm, AClipStartSec: Double;
  AMaxShiftBeats: Double = 0.25): TWarpMarkers;

{ Renders the warp. The result has the same length as the input: the segment
  after the last marker is stretched to fill whatever time remains. }
procedure RenderWarp(const AIn: TAudioPlanar; AChannels, AFrames, ASampleRate: Integer;
  const AMarkers: TWarpMarkers; out AOut: TAudioPlanar; out AOutFrames: Integer);

implementation


uses
  UDAW.DSP.MathTables;

procedure NormalizeWarpMarkers(var AMarkers: TWarpMarkers);
var
  i, n: Integer;
  res: TWarpMarkers;
  prevS, prevD: Double;
begin
  TArray.Sort<TWarpMarker>(AMarkers, TComparer<TWarpMarker>.Construct(
    function(const A, B: TWarpMarker): Integer
    begin
      Result := CompareValue(A.SrcSec, B.SrcSec);
    end));
  SetLength(res, Length(AMarkers));
  n := 0;
  prevS := 0;
  prevD := 0;
  for i := 0 to High(AMarkers) do
    if (AMarkers[i].SrcSec - prevS >= WARP_MIN_SEGMENT_SEC) and
       (AMarkers[i].DstSec - prevD >= WARP_MIN_SEGMENT_SEC) and
       ((AMarkers[i].DstSec - prevD) / (AMarkers[i].SrcSec - prevS) >= WARP_MIN_FACTOR) and
       ((AMarkers[i].DstSec - prevD) / (AMarkers[i].SrcSec - prevS) <= WARP_MAX_FACTOR) then
    begin
      res[n] := AMarkers[i];
      prevS := res[n].SrcSec;
      prevD := res[n].DstSec;
      Inc(n);
    end;
  SetLength(res, n);
  AMarkers := res;
end;

procedure AddWarpMarker(var AMarkers: TWarpMarkers; ASrcSec, ADstSec: Double);
var
  i: Integer;
begin
  i := NearestWarpMarker(AMarkers, ASrcSec, 0.02);
  if i >= 0 then
  begin
    AMarkers[i].DstSec := ADstSec;
    Exit;
  end;
  SetLength(AMarkers, Length(AMarkers) + 1);
  AMarkers[High(AMarkers)].SrcSec := ASrcSec;
  AMarkers[High(AMarkers)].DstSec := ADstSec;
end;

function NearestWarpMarker(const AMarkers: TWarpMarkers; ASrcSec, ATolSec: Double): Integer;
var
  i: Integer;
  best, d: Double;
begin
  Result := -1;
  best := ATolSec;
  for i := 0 to High(AMarkers) do
  begin
    d := Abs(AMarkers[i].SrcSec - ASrcSec);
    if d <= best then
    begin
      best := d;
      Result := i;
    end;
  end;
end;

function DetectOnsets(const AMono: array of Single; ASampleRate: Integer): TArray<Double>;
const
  N = 1024;
  HOP = 256;
var
  fft: TFFT;
  buf: TArray<Single>;
  re, im, prev, flux: TArray<Double>;
  win: TArray<Single>;
  frames, f, i, k, w, cnt, bins: Integer;
  mag, mean, thr: Double;
  res: TList<Double>;
  lastT, t: Double;
begin
  SetLength(Result, 0);
  if Length(AMono) < N * 2 then Exit;
  fft := TFFT.Create(N);
  res := TList<Double>.Create;
  try
    bins := N div 2 + 1;
    SetLength(buf, N);
    SetLength(re, bins);
    SetLength(im, bins);
    SetLength(prev, bins);
    SetLength(win, N);
    for i := 0 to N - 1 do win[i] := 0.5 - 0.5 * FastCos(2.0 * Pi * i / N);
    frames := (Length(AMono) - N) div HOP;
    SetLength(flux, frames);
    for f := 0 to frames - 1 do
    begin
      for i := 0 to N - 1 do buf[i] := AMono[f * HOP + i] * win[i];
      fft.RealForward(buf, re, im);
      flux[f] := 0;
      for k := 0 to bins - 1 do
      begin
        mag := Sqrt(re[k] * re[k] + im[k] * im[k]);
        if mag > prev[k] then flux[f] := flux[f] + (mag - prev[k]);
        prev[k] := mag;
      end;
    end;
    lastT := -1;
    w := Round(0.2 * ASampleRate / HOP); { adaptive threshold window ~0.2 s }
    if w < 4 then w := 4;
    for f := 1 to frames - 2 do
    begin
      mean := 0;
      cnt := 0;
      for i := Max(f - w, 0) to Min(f + w, frames - 1) do
      begin
        mean := mean + flux[i];
        Inc(cnt);
      end;
      mean := mean / cnt;
      thr := mean * 1.6 + 1e-6;
      if (flux[f] > thr) and (flux[f] >= flux[f - 1]) and (flux[f] > flux[f + 1]) then
      begin
        { onset time = window centre }
        t := (f * HOP + N * 0.5) / ASampleRate;
        if t - lastT >= 0.08 then
        begin
          res.Add(t);
          lastT := t;
        end;
      end;
    end;
    Result := res.ToArray;
  finally
    res.Free;
    fft.Free;
  end;
end;

function AutoWarpMarkers(const AOnsets: TArray<Double>; ABpm, AClipStartSec: Double;
  AMaxShiftBeats: Double): TWarpMarkers;
var
  spb, absT, beat, nearest, dst: Double;
  i, n: Integer;
begin
  SetLength(Result, 0);
  if ABpm < 20 then Exit;
  spb := 60.0 / ABpm;
  SetLength(Result, Length(AOnsets));
  n := 0;
  for i := 0 to High(AOnsets) do
  begin
    absT := AClipStartSec + AOnsets[i];
    beat := absT / spb;
    nearest := Round(beat);
    if Abs(beat - nearest) > AMaxShiftBeats then Continue;
    dst := nearest * spb - AClipStartSec;
    if dst <= 0 then Continue;
    Result[n].SrcSec := AOnsets[i];
    Result[n].DstSec := dst;
    Inc(n);
  end;
  SetLength(Result, n);
  NormalizeWarpMarkers(Result);
end;

procedure RenderWarp(const AIn: TAudioPlanar; AChannels, AFrames, ASampleRate: Integer;
  const AMarkers: TWarpMarkers; out AOut: TAudioPlanar; out AOutFrames: Integer);
var
  srcPts, dstPts: TArray<Double>;
  seg, ch, i, s0, s1, total, pos, m: Integer;
  segSrc: TArray<Single>;
  segOut: TArray<Single>;
  stretcher: TPhaseVocoderStretch;
  factor, srcLen, dstLen, lastSrc, lastDst, endSrc: Double;
  targetLens: TArray<Integer>;
  fadeN, j: Integer;
begin
  endSrc := AFrames / ASampleRate;
  { breakpoints: (0,0) .. markers .. (endSrc, lastDst + endSrc - lastSrc) }
  SetLength(srcPts, Length(AMarkers) + 2);
  SetLength(dstPts, Length(AMarkers) + 2);
  srcPts[0] := 0;
  dstPts[0] := 0;
  for i := 0 to High(AMarkers) do
  begin
    srcPts[i + 1] := AMarkers[i].SrcSec;
    dstPts[i + 1] := AMarkers[i].DstSec;
  end;
  lastSrc := srcPts[Length(AMarkers)];
  lastDst := dstPts[Length(AMarkers)];
  srcPts[High(srcPts)] := endSrc;
  { the final segment absorbs the remainder so the warped clip keeps exactly
    its original length (the swap stays a plain undoable source change) }
  dstPts[High(dstPts)] := endSrc;
  total := 0;
  SetLength(targetLens, Length(srcPts) - 1);
  for seg := 0 to High(targetLens) do
  begin
    targetLens[seg] := Round((dstPts[seg + 1] - dstPts[seg]) * ASampleRate);
    Inc(total, targetLens[seg]);
  end;
  AOutFrames := total;
  SetLength(AOut, AChannels);
  stretcher := TPhaseVocoderStretch.Create(2048);
  try
    for ch := 0 to AChannels - 1 do
    begin
      SetLength(AOut[ch], Max(total, 1));
      pos := 0;
      for seg := 0 to High(targetLens) do
      begin
        s0 := Round(srcPts[seg] * ASampleRate);
        s1 := Min(Round(srcPts[seg + 1] * ASampleRate), AFrames);
        srcLen := (s1 - s0) / ASampleRate;
        dstLen := targetLens[seg] / ASampleRate;
        if (s1 - s0 < 16) or (targetLens[seg] < 16) then
        begin
          pos := pos + targetLens[seg];
          Continue;
        end;
        SetLength(segSrc, s1 - s0);
        Move(AIn[ch][s0], segSrc[0], (s1 - s0) * SizeOf(Single));
        factor := dstLen / srcLen;
        if Abs(factor - 1.0) < 0.002 then
          segOut := Copy(segSrc)
        else if (s1 - s0) < 2048 then
        begin
          { too short for the vocoder frame: plain linear resample }
          SetLength(segOut, targetLens[seg]);
          for i := 0 to targetLens[seg] - 1 do
          begin
            m := Min(Trunc(i / factor), s1 - s0 - 1);
            segOut[i] := segSrc[m];
          end;
        end
        else
          stretcher.Process(segSrc, factor, segOut);
        m := Min(Length(segOut), targetLens[seg]);
        for i := 0 to m - 1 do
          if pos + i < total then AOut[ch][pos + i] := segOut[i];
        { short crossfade-in at the join hides the phase discontinuity }
        fadeN := Min(64, m);
        if seg > 0 then
          for j := 0 to fadeN - 1 do
            if pos + j < total then
              AOut[ch][pos + j] := AOut[ch][pos + j] * (j / fadeN);
        Inc(pos, targetLens[seg]);
      end;
    end;
  finally
    stretcher.Free;
  end;
end;

end.
