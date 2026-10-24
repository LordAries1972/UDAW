unit UDAW.Timeline.ExtraFx;
{$I udaw.inc}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

{ Offline audio effects for the Timeline "Audio Effects" menu that are not DSP
  graph nodes: they work on the whole marked selection (like noise reduction
  and auto-tune), so they can look ahead, measure the material first (loudness
  normalise, declip) or repair it (declick, dehum).  UI-free and test-friendly:
  planar float in, planar float out, "key=value;key=value" parameters.

  Ids (all start with '@'): echo, swaplr, invertphase, ringmod, vibrato,
  vocalchannel, dialogueleveler, loudnorm, dehum, declick, declip, bandpass,
  telephone, stereofixer, midside, crossfeed, lfefilter, subbass, freqshift, autowah,
  robot, megaphone, underwater, tapestop, gater, rotary, vinyl, comb, peaknorm, vocoder,
  wahwah, autofilter, formant, haas, monobass, vocalremove, tape, radio, fuzz, rectifier,
  ensemble, multitap, tapedelay, stutter, parallelcomp, tilteq,
  depop, levelrider, dialogrider, tplimiter, oversat, fadecurve. }

interface

uses
  SysUtils, Math, UDAW.Audio.Types;

type
  TAudioMeterReport = record
    IntegratedLufs, MomentaryMaxLufs, ShortTermMaxLufs: Double;
    SamplePeakDb, TruePeakDb, RmsDb: Double;
    Correlation, SideToMidDb, DcOffset: Double;
  end;

  { First-order Ambisonics (AmbiX: ACN channel order W, Y, Z, X; SN3D) analysis of a
    4-or-more-channel block: per-channel level, and where the sound is coming from. }
  TAmbisonicReport = record
    ChannelRmsDb: array[0..3] of Double;   // W, Y, Z, X
    AzimuthDeg: Double;                    // 0 = front, +90 = left, +-180 = behind
    ElevationDeg: Double;                  // +90 = overhead
    Directivity: Double;                   // 1 = a single point source, 0 = fully diffuse
  end;

function IsExtraFxKind(const AKind: string): Boolean;

{ Loudness (BS.1770-style), peaks (true peak by 4x interpolation), RMS, stereo
  correlation and side/mid balance of a block of audio. }
procedure MeasureAudio(const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer; out AReport: TAudioMeterReport);

{ False when the block has fewer than 4 channels. }
function MeasureAmbisonics(const AIn: TAudioPlanar; AChannels, AFrames: Integer; out AReport: TAmbisonicReport): Boolean;

{ AOut is resized to AChannels x AFrames and fully overwritten. }
procedure ApplyExtraFx(const AKind, AParams: string; const AIn: TAudioPlanar;
  AChannels, AFrames, ASampleRate: Integer; var AOut: TAudioPlanar);

implementation


uses
  UDAW.DSP.MathTables;

const
  KINDS: array[0..51] of string = ('@echo', '@swaplr', '@invertphase', '@ringmod', '@vibrato',
    '@vocalchannel', '@dialogueleveler', '@loudnorm', '@dehum', '@declick', '@declip',
    '@bandpass', '@telephone',
    '@stereofixer', '@midside', '@crossfeed', '@lfefilter', '@subbass', '@freqshift', '@autowah', '@robot', '@megaphone', '@underwater', '@tapestop', '@gater', '@rotary', '@vinyl', '@comb', '@peaknorm', '@vocoder',
    '@wahwah', '@autofilter', '@formant', '@haas', '@monobass', '@vocalremove', '@tape', '@radio',
    '@fuzz', '@rectifier', '@ensemble', '@multitap', '@tapedelay', '@stutter', '@parallelcomp', '@tilteq',
    '@depop', '@levelrider', '@dialogrider', '@tplimiter', '@oversat', '@fadecurve');

function IsExtraFxKind(const AKind: string): Boolean;
var
  i: Integer;
begin
  for i := Low(KINDS) to High(KINDS) do
    if SameText(AKind, KINDS[i]) then Exit(True);
  Result := False;
end;

function ParamF(const AParams, AKey: string; ADef: Double): Double;
var
  part: string;
  p: Integer;
begin
  Result := ADef;
  for part in AParams.Split([';']) do
  begin
    p := Pos('=', part);
    if (p > 0) and SameText(Trim(Copy(part, 1, p - 1)), AKey) then
      Exit(StrToFloatDef(Trim(Copy(part, p + 1, MaxInt)), ADef, TFormatSettings.Invariant));
  end;
end;

{ ------------------------------ biquad ---------------------------------- }

type
  TBq = record
    b0, b1, b2, a1, a2, x1, x2, y1, y2: Double;
  end;

const
  BQ_LOWPASS = 0; BQ_HIGHPASS = 1; BQ_BANDPASS = 2; BQ_NOTCH = 3; BQ_PEAK = 4; BQ_HISHELF = 5;

procedure BqDesign(var Q: TBq; AKind: Integer; AFs, AFreq, AQ, AGainDb: Double);
var
  w0, cs, sn, alpha, a, sq, a0: Double;
begin
  if AFreq > AFs * 0.45 then AFreq := AFs * 0.45;
  if AFreq < 1 then AFreq := 1;
  w0 := 2 * Pi * AFreq / AFs;
  cs := FastCos(w0);
  sn := FastSin(w0);
  alpha := sn / (2 * Max(AQ, 0.05));
  a := FastExp10(AGainDb / 40);
  case AKind of
    BQ_LOWPASS:
      begin
        Q.b0 := (1 - cs) / 2; Q.b1 := 1 - cs; Q.b2 := (1 - cs) / 2;
        a0 := 1 + alpha; Q.a1 := -2 * cs; Q.a2 := 1 - alpha;
      end;
    BQ_HIGHPASS:
      begin
        Q.b0 := (1 + cs) / 2; Q.b1 := -(1 + cs); Q.b2 := (1 + cs) / 2;
        a0 := 1 + alpha; Q.a1 := -2 * cs; Q.a2 := 1 - alpha;
      end;
    BQ_BANDPASS:
      begin
        Q.b0 := alpha; Q.b1 := 0; Q.b2 := -alpha;
        a0 := 1 + alpha; Q.a1 := -2 * cs; Q.a2 := 1 - alpha;
      end;
    BQ_NOTCH:
      begin
        Q.b0 := 1; Q.b1 := -2 * cs; Q.b2 := 1;
        a0 := 1 + alpha; Q.a1 := -2 * cs; Q.a2 := 1 - alpha;
      end;
    BQ_PEAK:
      begin
        Q.b0 := 1 + alpha * a; Q.b1 := -2 * cs; Q.b2 := 1 - alpha * a;
        a0 := 1 + alpha / a; Q.a1 := -2 * cs; Q.a2 := 1 - alpha / a;
      end;
  else
    begin
      { high shelf, slope 1 }
      alpha := sn / 2 * Sqrt(2);
      sq := 2 * Sqrt(a) * alpha;
      Q.b0 := a * ((a + 1) + (a - 1) * cs + sq);
      Q.b1 := -2 * a * ((a - 1) + (a + 1) * cs);
      Q.b2 := a * ((a + 1) + (a - 1) * cs - sq);
      a0 := (a + 1) - (a - 1) * cs + sq;
      Q.a1 := 2 * ((a - 1) - (a + 1) * cs);
      Q.a2 := (a + 1) - (a - 1) * cs - sq;
    end;
  end;
  Q.b0 := Q.b0 / a0; Q.b1 := Q.b1 / a0; Q.b2 := Q.b2 / a0;
  Q.a1 := Q.a1 / a0; Q.a2 := Q.a2 / a0;
  Q.x1 := 0; Q.x2 := 0; Q.y1 := 0; Q.y2 := 0;
end;

function BqRun(var Q: TBq; X: Double): Double; inline;
begin
  Result := Q.b0 * X + Q.b1 * Q.x1 + Q.b2 * Q.x2 - Q.a1 * Q.y1 - Q.a2 * Q.y2;
  Q.x2 := Q.x1; Q.x1 := X;
  Q.y2 := Q.y1; Q.y1 := Result;
end;

function DbToLin(ADb: Double): Double; inline;
begin
  Result := FastExp10(ADb / 20);
end;

function LinToDb(ALin: Double): Double; inline;
begin
  if ALin < 1E-9 then Result := -180 else Result := 20 * FastLog10(ALin);
end;

{ feed-forward peak compressor, hard knee, gain smoothed in the dB domain }
procedure CompressInPlace(var X: TAudioSampleArray; AFrames, AFs: Integer;
  AThrDb, ARatio, AAttackMs, AReleaseMs, AMakeupDb: Double);
var
  i: Integer;
  env, over, target, g, atk, rel, lvl: Double;
begin
  atk := FastExp(-1 / (Max(0.1, AAttackMs) * 0.001 * AFs));
  rel := FastExp(-1 / (Max(1.0, AReleaseMs) * 0.001 * AFs));
  env := -120;
  g := 0;
  for i := 0 to AFrames - 1 do
  begin
    lvl := LinToDb(Abs(X[i]));
    if lvl > env then env := atk * env + (1 - atk) * lvl
    else env := rel * env + (1 - rel) * lvl;
    over := env - AThrDb;
    if over > 0 then target := -over * (1 - 1 / ARatio) else target := 0;
    if target < g then g := atk * g + (1 - atk) * target
    else g := rel * g + (1 - rel) * target;
    X[i] := X[i] * DbToLin(g + AMakeupDb);
  end;
end;

procedure ResizeOut(var AOut: TAudioPlanar; AChannels, AFrames: Integer);
var
  ch: Integer;
begin
  SetLength(AOut, AChannels);
  for ch := 0 to AChannels - 1 do SetLength(AOut[ch], AFrames);
end;

{ ------------------------------ effects --------------------------------- }

procedure DoEcho(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i, d, pos: Integer;
  ms, fb, mix, lp, damp, wet: Double;
  buf: TAudioSampleArray;
begin
  ms := Max(20.0, Min(2000.0, ParamF(AParams, 'ms', 380)));
  fb := Max(0.0, Min(0.92, ParamF(AParams, 'fb', 0.45)));
  mix := Max(0.0, Min(1.0, ParamF(AParams, 'mix', 0.35)));
  damp := 0.35;
  for ch := 0 to AChannels - 1 do
  begin
    { the right channel's echo is 1.5x as late: a wide stereo echo }
    if ch = 1 then d := Round(ms * 1.5 * 0.001 * AFs) else d := Round(ms * 0.001 * AFs);
    d := Max(1, d);
    SetLength(buf, d);
    for i := 0 to d - 1 do buf[i] := 0;
    pos := 0;
    lp := 0;
    for i := 0 to AFrames - 1 do
    begin
      wet := buf[pos];
      lp := lp + damp * (wet - lp);
      buf[pos] := AIn[ch][i] + fb * lp;
      pos := (pos + 1) mod d;
      AOut[ch][i] := AIn[ch][i] + mix * wet;
    end;
  end;
end;

procedure DoRing(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  fr, mix, ph, dph: Double;
begin
  fr := Max(1.0, Min(5000.0, ParamF(AParams, 'freq', 440)));
  mix := Max(0.0, Min(1.0, ParamF(AParams, 'mix', 0.6)));
  dph := 2 * Pi * fr / AFs;
  for ch := 0 to AChannels - 1 do
  begin
    ph := 0;
    for i := 0 to AFrames - 1 do
    begin
      AOut[ch][i] := AIn[ch][i] * ((1 - mix) + mix * FastSin(ph));
      ph := ph + dph;
      if ph > 2 * Pi then ph := ph - 2 * Pi;
    end;
  end;
end;

procedure DoVibrato(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i, i0: Integer;
  rate, depthMs, centre, dly, pos, frac, a, b: Double;
begin
  rate := Max(0.1, Min(20.0, ParamF(AParams, 'rate', 5.5)));
  depthMs := Max(0.1, Min(12.0, ParamF(AParams, 'depth', 3)));
  centre := depthMs * 0.001 * AFs;
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do
    begin
      dly := centre * (1 + FastSin(2 * Pi * rate * i / AFs));
      pos := i - dly;
      if pos < 0 then
        AOut[ch][i] := 0
      else
      begin
        i0 := Trunc(pos);
        frac := pos - i0;
        a := AIn[ch][i0];
        if i0 + 1 < AFrames then b := AIn[ch][i0 + 1] else b := a;
        AOut[ch][i] := a + (b - a) * frac;
      end;
    end;
end;

procedure DoVocalChannel(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  hp, pres, air, mud: TBq;
  v: Double;
  amt: Double;
begin
  amt := Max(0.0, Min(2.0, ParamF(AParams, 'amt', 1)));
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(hp, BQ_HIGHPASS, AFs, 85, 0.707, 0);
    BqDesign(mud, BQ_PEAK, AFs, 300, 1.0, -2.5 * amt);
    BqDesign(pres, BQ_PEAK, AFs, 3500, 1.0, 3.0 * amt);
    BqDesign(air, BQ_HISHELF, AFs, 11000, 0.707, 2.5 * amt);
    for i := 0 to AFrames - 1 do
    begin
      v := BqRun(hp, AIn[ch][i]);
      v := BqRun(mud, v);
      v := BqRun(pres, v);
      v := BqRun(air, v);
      AOut[ch][i] := v;
    end;
    CompressInPlace(AOut[ch], AFrames, AFs, -20, 3, 8, 140, 3 * amt);
  end;
end;

procedure DoDialogueLeveler(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  blk, nb, b, ch, i, i0, i1: Integer;
  target, ms, smooth, gDb, want, atk, rel, coefMs, rmsDb, gPrev, gNow, ramp: Double;
begin
  target := Max(-40.0, Min(-6.0, ParamF(AParams, 'target', -20)));
  blk := Max(64, AFs div 100);
  nb := (AFrames + blk - 1) div blk;
  coefMs := 1 - FastExp(-1 / (0.4 * 100));
  atk := 1 - FastExp(-1 / (0.15 * 100));
  rel := 1 - FastExp(-1 / (0.8 * 100));
  smooth := 0;
  gDb := 0;
  for b := 0 to nb - 1 do
  begin
    i0 := b * blk;
    i1 := Min(AFrames, i0 + blk);
    ms := 0;
    for ch := 0 to AChannels - 1 do
      for i := i0 to i1 - 1 do ms := ms + Sqr(AIn[ch][i]);
    ms := ms / Max(1, (i1 - i0) * AChannels);
    smooth := smooth + coefMs * (ms - smooth);
    rmsDb := 10 * FastLog10(Max(smooth, 1E-12));
    gPrev := gDb;
    if rmsDb > -52 then
    begin
      want := Max(-6.0, Min(15.0, target - rmsDb));
      if want < gDb then gDb := gDb + atk * (want - gDb)
      else gDb := gDb + rel * (want - gDb);
    end;
    gNow := gDb;
    for ch := 0 to AChannels - 1 do
      for i := i0 to i1 - 1 do
      begin
        ramp := (i - i0) / Max(1, blk);
        AOut[ch][i] := AIn[ch][i] * DbToLin(gPrev + (gNow - gPrev) * ramp);
      end;
  end;
end;

{ ITU-R BS.1770 style integrated loudness: K-weighting, 400 ms blocks, -70 LUFS absolute gate and -10 LU relative gate }
function MeasureLufs(const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer): Double;
var
  ch, i, blk, nb, b, cnt, i0, i1: Integer;
  sh, hp: TBq;
  k: TAudioSampleArray;
  ms: array of Double;
  sum, mean, lufs, rel: Double;
begin
  blk := Max(1, Round(0.4 * AFs));
  nb := AFrames div blk;
  if nb < 1 then nb := 1;
  SetLength(ms, nb);
  for b := 0 to nb - 1 do ms[b] := 0;
  SetLength(k, AFrames);
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(sh, BQ_HISHELF, AFs, 1500, 0.707, 4);
    BqDesign(hp, BQ_HIGHPASS, AFs, 38, 0.5, 0);
    for i := 0 to AFrames - 1 do k[i] := BqRun(hp, BqRun(sh, AIn[ch][i]));
    for b := 0 to nb - 1 do
    begin
      i0 := b * blk;
      i1 := Min(AFrames, i0 + blk);
      sum := 0;
      for i := i0 to i1 - 1 do sum := sum + Sqr(k[i]);
      ms[b] := ms[b] + sum / Max(1, i1 - i0);
    end;
  end;
  mean := 0;
  cnt := 0;
  for b := 0 to nb - 1 do
    if -0.691 + 10 * FastLog10(Max(ms[b], 1E-12)) > -70 then
    begin
      mean := mean + ms[b];
      Inc(cnt);
    end;
  if cnt = 0 then Exit(-70);
  lufs := -0.691 + 10 * FastLog10(Max(mean / cnt, 1E-12));
  rel := lufs - 10;
  mean := 0;
  cnt := 0;
  for b := 0 to nb - 1 do
    if -0.691 + 10 * FastLog10(Max(ms[b], 1E-12)) > rel then
    begin
      mean := mean + ms[b];
      Inc(cnt);
    end;
  if cnt = 0 then Exit(lufs);
  Result := -0.691 + 10 * FastLog10(Max(mean / cnt, 1E-12));
end;

procedure DoLoudNorm(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  target, cur, gDb, g, peak: Double;
begin
  target := Max(-40.0, Min(-6.0, ParamF(AParams, 'lufs', -16)));
  cur := MeasureLufs(AIn, AChannels, AFrames, AFs);
  gDb := Max(-24.0, Min(24.0, target - cur));
  g := DbToLin(gDb);
  peak := 0;
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do peak := Max(peak, Abs(AIn[ch][i]));
  { never push the sample peak past -0.1 dBFS }
  if peak * g > 0.989 then g := 0.989 / peak;
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do AOut[ch][i] := AIn[ch][i] * g;
end;

procedure DoDehum(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i, h, nh: Integer;
  f0: Double;
  bq: array[1..8] of TBq;
  v: Double;
begin
  f0 := Max(40.0, Min(70.0, ParamF(AParams, 'hz', 50)));
  nh := 1;
  while (nh < 8) and (f0 * (nh + 1) < AFs * 0.4) do Inc(nh);
  for ch := 0 to AChannels - 1 do
  begin
    for h := 1 to nh do BqDesign(bq[h], BQ_NOTCH, AFs, f0 * h, 35, 0);
    for i := 0 to AFrames - 1 do
    begin
      v := AIn[ch][i];
      for h := 1 to nh do v := BqRun(bq[h], v);
      AOut[ch][i] := v;
    end;
  end;
end;

procedure DoDeclick(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames: Integer;
  var AOut: TAudioPlanar);
var
  ch, i, a, b, j: Integer;
  thr, avg, d, v0, v1: Double;
  flag, dil: array of Boolean;
begin
  thr := Max(3.0, Min(30.0, ParamF(AParams, 'sens', 9)));
  SetLength(flag, AFrames);
  SetLength(dil, AFrames);
  for ch := 0 to AChannels - 1 do
  begin
    for i := 0 to AFrames - 1 do
    begin
      AOut[ch][i] := AIn[ch][i];
      flag[i] := False;
      dil[i] := False;
    end;
    avg := 0.01;
    for i := 2 to AFrames - 1 do
    begin
      d := Abs(AIn[ch][i] - 2 * AIn[ch][i - 1] + AIn[ch][i - 2]);
      if d > thr * avg + 0.03 then flag[i - 1] := True
      else avg := avg * 0.998 + d * 0.002;
    end;
    for i := 0 to AFrames - 1 do
      if flag[i] then
        for j := Max(0, i - 2) to Min(AFrames - 1, i + 2) do dil[j] := True;
    i := 1;
    while i < AFrames - 1 do
    begin
      if dil[i] then
      begin
        a := i;
        while (i < AFrames - 1) and dil[i] do Inc(i);
        b := i - 1;
        if (b - a < 64) and (a > 0) and (b + 1 < AFrames) then
        begin
          v0 := AIn[ch][a - 1];
          v1 := AIn[ch][b + 1];
          for j := a to b do
            AOut[ch][j] := v0 + (v1 - v0) * (j - a + 1) / (b - a + 2);
        end;
      end
      else
        Inc(i);
    end;
  end;
end;

procedure DoDeclip(const AIn: TAudioPlanar; AChannels, AFrames: Integer; var AOut: TAudioPlanar);
var
  ch, i, a, b, j, len: Integer;
  peak, thr, s0, s1, t, t2, t3, p0, p1, h, v, lim, outPeak, scale: Double;
begin
  outPeak := 0;
  for ch := 0 to AChannels - 1 do
  begin
    peak := 0;
    for i := 0 to AFrames - 1 do peak := Max(peak, Abs(AIn[ch][i]));
    for i := 0 to AFrames - 1 do AOut[ch][i] := AIn[ch][i];
    if peak < 0.3 then Continue;
    thr := peak * 0.985;
    lim := peak * 1.6;
    i := 2;
    while i < AFrames - 2 do
    begin
      if Abs(AIn[ch][i]) >= thr then
      begin
        a := i;
        while (i < AFrames - 2) and (Abs(AIn[ch][i]) >= thr) and
          ((AIn[ch][i] >= 0) = (AIn[ch][a] >= 0)) do Inc(i);
        b := i - 1;
        len := b - a + 2;
        if (b - a >= 1) and (b - a < 40) then
        begin
          p0 := AIn[ch][a - 1];
          p1 := AIn[ch][b + 1];
          s0 := (AIn[ch][a - 1] - AIn[ch][a - 2]) * len;
          s1 := (AIn[ch][b + 2] - AIn[ch][b + 1]) * len;
          for j := a to b do
          begin
            t := (j - a + 1) / len;
            t2 := t * t;
            t3 := t2 * t;
            h := (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * s0 + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * s1;
            v := h;
            if v > lim then v := lim;
            if v < -lim then v := -lim;
            if (AIn[ch][j] >= 0) and (v < AIn[ch][j]) then v := AIn[ch][j];
            if (AIn[ch][j] < 0) and (v > AIn[ch][j]) then v := AIn[ch][j];
            AOut[ch][j] := v;
          end;
        end;
      end
      else
        Inc(i);
    end;
  end;
  { restored peaks may exceed full scale: bring the whole selection back under it }
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do outPeak := Max(outPeak, Abs(AOut[ch][i]));
  if outPeak > 0.99 then
  begin
    scale := 0.99 / outPeak;
    for ch := 0 to AChannels - 1 do
      for i := 0 to AFrames - 1 do AOut[ch][i] := AOut[ch][i] * scale;
  end;
end;

procedure DoBandpass(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  bq: TBq;
begin
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(bq, BQ_BANDPASS, AFs, ParamF(AParams, 'freq', 1000), ParamF(AParams, 'q', 1.2), 0);
    for i := 0 to AFrames - 1 do AOut[ch][i] := BqRun(bq, AIn[ch][i]) * 1.4;
  end;
end;

procedure DoTelephone(const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer; var AOut: TAudioPlanar);
var
  ch, i: Integer;
  hp1, hp2, lp1, lp2: TBq;
  v: Double;
begin
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(hp1, BQ_HIGHPASS, AFs, 300, 0.707, 0);
    BqDesign(hp2, BQ_HIGHPASS, AFs, 300, 0.707, 0);
    BqDesign(lp1, BQ_LOWPASS, AFs, 3400, 0.707, 0);
    BqDesign(lp2, BQ_LOWPASS, AFs, 3400, 0.707, 0);
    for i := 0 to AFrames - 1 do
    begin
      v := BqRun(lp2, BqRun(lp1, BqRun(hp2, BqRun(hp1, AIn[ch][i]))));
      { a little handset distortion }
      AOut[ch][i] := FastSin(Max(-1.5, Min(1.5, v * 1.8))) * 0.9;
    end;
  end;
end;

{ ---------------------- Fairlight-style additions ------------------------- }

procedure BqCoefs(var Q: TBq; const T: TBq); inline;
begin
  Q.b0 := T.b0; Q.b1 := T.b1; Q.b2 := T.b2; Q.a1 := T.a1; Q.a2 := T.a2;
end;

function Clamp(AV, ALo, AHi: Double): Double; inline;
begin
  if AV < ALo then Result := ALo else if AV > AHi then Result := AHi else Result := AV;
end;

{ linear-interpolated read, clamped to the buffer }
function ReadInterp(const X: TAudioSampleArray; AFrames: Integer; APos: Double): Double; inline;
var
  i0: Integer;
  fr, a, b: Double;
begin
  if APos <= 0 then Exit(X[0]);
  i0 := Trunc(APos);
  if i0 >= AFrames - 1 then Exit(X[AFrames - 1]);
  fr := APos - i0;
  a := X[i0];
  b := X[i0 + 1];
  Result := a + (b - a) * fr;
end;

procedure CopyThrough(const AIn: TAudioPlanar; AChannels, AFrames: Integer; var AOut: TAudioPlanar);
var
  ch, i: Integer;
begin
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do AOut[ch][i] := AIn[ch][i];
end;

procedure DoStereoFixer(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames: Integer;
  var AOut: TAudioPlanar);
var
  i: Integer;
  width, corr, sl, sr, m, gl, gr, mid, side, rsign: Double;
begin
  CopyThrough(AIn, AChannels, AFrames, AOut);
  if AChannels < 2 then Exit;
  width := Clamp(ParamF(AParams, 'width', 1), 0, 2);
  corr := 0; sl := 0; sr := 0;
  for i := 0 to AFrames - 1 do
  begin
    corr := corr + AIn[0][i] * AIn[1][i];
    sl := sl + AIn[0][i] * AIn[0][i];
    sr := sr + AIn[1][i] * AIn[1][i];
  end;
  rsign := 1;
  if (ParamF(AParams, 'fixphase', 1) >= 0.5) and (corr < 0) then rsign := -1;
  gl := 1; gr := 1;
  if (ParamF(AParams, 'fixbalance', 1) >= 0.5) and (sl > 1E-12) and (sr > 1E-12) then
  begin
    m := (Sqrt(sl) + Sqrt(sr)) * 0.5;
    gl := Clamp(m / Sqrt(sl), 0.5, 2);
    gr := Clamp(m / Sqrt(sr), 0.5, 2);
  end;
  for i := 0 to AFrames - 1 do
  begin
    mid := (AIn[0][i] * gl + rsign * AIn[1][i] * gr) * 0.5;
    side := (AIn[0][i] * gl - rsign * AIn[1][i] * gr) * 0.5 * width;
    AOut[0][i] := mid + side;
    AOut[1][i] := mid - side;
  end;
end;

procedure DoMidSide(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames: Integer;
  var AOut: TAudioPlanar);
var
  i: Integer;
  gm, gs, mid, side: Double;
begin
  CopyThrough(AIn, AChannels, AFrames, AOut);
  if AChannels < 2 then Exit;
  gm := DbToLin(Clamp(ParamF(AParams, 'mid', 0), -24, 24));
  gs := DbToLin(Clamp(ParamF(AParams, 'side', -3), -24, 24));
  for i := 0 to AFrames - 1 do
  begin
    mid := (AIn[0][i] + AIn[1][i]) * 0.5 * gm;
    side := (AIn[0][i] - AIn[1][i]) * 0.5 * gs;
    AOut[0][i] := mid + side;
    AOut[1][i] := mid - side;
  end;
end;

procedure DoCrossfeed(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  i: Integer;
  amt, l, r, fl, fr, norm: Double;
  lpl, lpr: TBq;
begin
  CopyThrough(AIn, AChannels, AFrames, AOut);
  if AChannels < 2 then Exit;
  amt := Clamp(ParamF(AParams, 'amt', 0.3), 0, 1);
  norm := 1 / (1 + amt * 0.6);
  BqDesign(lpl, BQ_LOWPASS, AFs, 700, 0.707, 0);
  BqDesign(lpr, BQ_LOWPASS, AFs, 700, 0.707, 0);
  for i := 0 to AFrames - 1 do
  begin
    l := AIn[0][i];
    r := AIn[1][i];
    fl := BqRun(lpl, l);
    fr := BqRun(lpr, r);
    AOut[0][i] := (l + amt * fr) * norm;
    AOut[1][i] := (r + amt * fl) * norm;
  end;
end;

procedure DoLfe(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  hz: Double;
  a, b: TBq;
begin
  hz := Clamp(ParamF(AParams, 'hz', 120), 30, 500);
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(a, BQ_LOWPASS, AFs, hz, 0.54, 0);
    BqDesign(b, BQ_LOWPASS, AFs, hz, 1.31, 0);
    for i := 0 to AFrames - 1 do AOut[ch][i] := BqRun(b, BqRun(a, AIn[ch][i]));
  end;
end;

procedure DoSubBass(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  mix, hz, m, f, prev, env, ea, sq, sub: Double;
  l1, l2, o1: TBq;
  up: Boolean;
begin
  CopyThrough(AIn, AChannels, AFrames, AOut);
  mix := Clamp(ParamF(AParams, 'mix', 0.5), 0, 1.5);
  hz := Clamp(ParamF(AParams, 'hz', 80), 40, 200);
  BqDesign(l1, BQ_LOWPASS, AFs, hz * 1.5, 0.707, 0);
  BqDesign(l2, BQ_LOWPASS, AFs, hz * 1.5, 0.707, 0);
  BqDesign(o1, BQ_LOWPASS, AFs, hz, 0.707, 0);
  ea := FastExp(-1 / (0.02 * AFs));
  prev := 0; env := 0; up := False;
  for i := 0 to AFrames - 1 do
  begin
    m := 0;
    for ch := 0 to AChannels - 1 do m := m + AIn[ch][i];
    m := m / Max(1, AChannels);
    f := BqRun(l2, BqRun(l1, m));
    if (prev <= 0) and (f > 0) then up := not up;
    prev := f;
    env := ea * env + (1 - ea) * Abs(f);
    if up then sq := 1 else sq := -1;
    sub := BqRun(o1, sq) * env * 1.6 * mix;
    for ch := 0 to AChannels - 1 do AOut[ch][i] := AOut[ch][i] + sub;
  end;
end;

procedure DoFreqShift(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
const
  HALF = 63;
var
  h: array[0..2 * HALF] of Double;
  ch, i, k, j: Integer;
  shift, mix, ph, dph, xd, xh, w: Double;
begin
  shift := Clamp(ParamF(AParams, 'hz', 50), -2000, 2000);
  mix := Clamp(ParamF(AParams, 'mix', 1), 0, 1);
  { windowed type-III Hilbert FIR: odd taps only }
  for k := 0 to 2 * HALF do
  begin
    j := k - HALF;
    if (j = 0) or (not Odd(j)) then h[k] := 0
    else
    begin
      w := 0.54 + 0.46 * FastCos(Pi * j / (HALF + 1));
      h[k] := 2 / (Pi * j) * w;
    end;
  end;
  dph := 2 * Pi * shift / AFs;
  for ch := 0 to AChannels - 1 do
  begin
    ph := 0;
    for i := 0 to AFrames - 1 do
    begin
      if i - HALF >= 0 then xd := AIn[ch][i - HALF] else xd := 0;
      xh := 0;
      for k := 0 to 2 * HALF do
      begin
        j := i - k;
        if j >= 0 then xh := xh + h[k] * AIn[ch][j];
      end;
      AOut[ch][i] := (1 - mix) * xd + mix * (xd * FastCos(ph) - xh * FastSin(ph));
      ph := ph + dph;
      if ph > 2 * Pi then ph := ph - 2 * Pi else if ph < -2 * Pi then ph := ph + 2 * Pi;
    end;
  end;
end;

procedure DoAutoWah(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  sens, q, env, fc, aa, ar, x, bp: Double;
  f, t: TBq;
begin
  sens := Clamp(ParamF(AParams, 'sens', 0.8), 0.1, 3);
  q := Clamp(ParamF(AParams, 'q', 4), 0.7, 12);
  aa := FastExp(-1 / (0.005 * AFs));
  ar := FastExp(-1 / (0.06 * AFs));
  for ch := 0 to AChannels - 1 do
  begin
    env := 0;
    BqDesign(f, BQ_BANDPASS, AFs, 400, q, 0);
    for i := 0 to AFrames - 1 do
    begin
      x := AIn[ch][i];
      if Abs(x) > env then env := aa * env + (1 - aa) * Abs(x)
      else env := ar * env + (1 - ar) * Abs(x);
      if (i and 15) = 0 then
      begin
        fc := 350 + Min(1.0, env * sens * 5) * 2600;
        BqDesign(t, BQ_BANDPASS, AFs, fc, q, 0);
        BqCoefs(f, t);
      end;
      bp := BqRun(f, x);
      AOut[ch][i] := x * 0.35 + bp * 1.4;
    end;
  end;
end;

procedure DoRobot(const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer; var AOut: TAudioPlanar);
var
  ch, i, d: Integer;
  ph, dph, x: Double;
  buf: TAudioSampleArray;
begin
  d := Max(2, Round(AFs * 0.006));
  dph := 2 * Pi * 60 / AFs;
  SetLength(buf, d);
  for ch := 0 to AChannels - 1 do
  begin
    for i := 0 to d - 1 do buf[i] := 0;
    ph := 0;
    for i := 0 to AFrames - 1 do
    begin
      x := AIn[ch][i] * FastSin(ph);
      ph := ph + dph;
      if ph > 2 * Pi then ph := ph - 2 * Pi;
      x := x + 0.65 * buf[i mod d];
      buf[i mod d] := x;
      AOut[ch][i] := x * 0.55;
    end;
  end;
end;

procedure DoMegaphone(const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer; var AOut: TAudioPlanar);
var
  ch, i: Integer;
  h1, h2, l1, l2: TBq;
  v: Double;
begin
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(h1, BQ_HIGHPASS, AFs, 500, 0.707, 0);
    BqDesign(h2, BQ_HIGHPASS, AFs, 500, 0.707, 0);
    BqDesign(l1, BQ_LOWPASS, AFs, 4000, 0.707, 0);
    BqDesign(l2, BQ_LOWPASS, AFs, 4000, 0.707, 0);
    for i := 0 to AFrames - 1 do
    begin
      v := BqRun(l2, BqRun(l1, BqRun(h2, BqRun(h1, AIn[ch][i])))) * 4;
      AOut[ch][i] := Clamp(v, -1, 1) * 0.7;
    end;
  end;
end;

procedure DoUnderwater(const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer; var AOut: TAudioPlanar);
var
  ch, i: Integer;
  l1, l2: TBq;
  tmp: TAudioSampleArray;
  dly: Double;
begin
  SetLength(tmp, AFrames);
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(l1, BQ_LOWPASS, AFs, 650, 0.9, 0);
    BqDesign(l2, BQ_LOWPASS, AFs, 650, 0.9, 0);
    for i := 0 to AFrames - 1 do tmp[i] := BqRun(l2, BqRun(l1, AIn[ch][i]));
    for i := 0 to AFrames - 1 do
    begin
      dly := 0.002 * AFs * (1 + FastSin(2 * Pi * (0.45 + 0.1 * ch) * i / AFs));
      AOut[ch][i] := ReadInterp(tmp, AFrames, i - dly) * 1.5;
    end;
  end;
end;

procedure DoTapeStop(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i, st, len: Integer;
  ms, p, u, s: Double;
begin
  ms := Clamp(ParamF(AParams, 'ms', 1500), 100, 10000);
  len := Min(AFrames, Max(2, Round(ms * 0.001 * AFs)));
  st := AFrames - len;
  for ch := 0 to AChannels - 1 do
  begin
    for i := 0 to st - 1 do AOut[ch][i] := AIn[ch][i];
    p := st;
    for i := st to AFrames - 1 do
    begin
      u := (i - st) / len;
      s := (1 - u) * (1 - u);
      AOut[ch][i] := ReadInterp(AIn[ch], AFrames, p);
      p := p + s;
    end;
  end;
end;

procedure DoGater(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  rate, depth, duty, ph, target, g, sm: Double;
begin
  rate := Clamp(ParamF(AParams, 'rate', 8), 0.5, 32);
  depth := Clamp(ParamF(AParams, 'depth', 1), 0, 1);
  duty := Clamp(ParamF(AParams, 'duty', 0.5), 0.1, 0.9);
  sm := FastExp(-1 / (0.002 * AFs));
  for ch := 0 to AChannels - 1 do
  begin
    g := 1;
    for i := 0 to AFrames - 1 do
    begin
      ph := Frac(rate * i / AFs);
      if ph < duty then target := 1 else target := 1 - depth;
      g := sm * g + (1 - sm) * target;
      AOut[ch][i] := AIn[ch][i] * g;
    end;
  end;
end;

procedure DoRotary(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  rate, depth, ph, dly, amp: Double;
begin
  rate := Clamp(ParamF(AParams, 'rate', 0.8), 0.1, 8);
  depth := Clamp(ParamF(AParams, 'depth', 0.5), 0, 1);
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do
    begin
      ph := 2 * Pi * rate * i / AFs + ch * Pi / 2;
      dly := 0.0006 * AFs * depth * (1 + FastSin(ph));
      amp := 1 - depth * 0.35 * (1 + FastCos(ph));
      AOut[ch][i] := ReadInterp(AIn[ch], AFrames, i - dly) * amp / (1 - depth * 0.1);
    end;
end;

procedure DoVinyl(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  amt, p, click, hiss, seed, r: Double;
  rng: Cardinal;
  lp: TBq;
begin
  amt := Clamp(ParamF(AParams, 'amt', 0.5), 0, 1);
  for ch := 0 to AChannels - 1 do
  begin
    rng := 2463534242 + Cardinal(ch) * 7919;
    BqDesign(lp, BQ_LOWPASS, AFs, 12000, 0.707, 0);
    click := 0;
    hiss := 0;
    p := (6 + 30 * amt) / AFs;
    for i := 0 to AFrames - 1 do
    begin
      rng := rng xor (rng shl 13);
      rng := rng xor (rng shr 17);
      rng := rng xor (rng shl 5);
      r := rng / 4294967296.0;
      if r < p then
      begin
        rng := rng xor (rng shl 13);
        rng := rng xor (rng shr 17);
        rng := rng xor (rng shl 5);
        seed := rng / 4294967296.0;
        if r < p * 0.5 then click := (0.05 + 0.3 * seed) * amt
        else click := -(0.05 + 0.3 * seed) * amt;
      end;
      click := click * 0.86;
      hiss := hiss + 0.4 * (((rng and $FFFF) / 32768.0 - 1) * 0.012 * amt - hiss);
      AOut[ch][i] := BqRun(lp, AIn[ch][i]) + click + hiss;
    end;
  end;
end;

procedure DoComb(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i, d: Integer;
  ms, fb, mix, y: Double;
  buf: TAudioSampleArray;
begin
  ms := Clamp(ParamF(AParams, 'ms', 5), 0.2, 50);
  fb := Clamp(ParamF(AParams, 'fb', 0.6), -0.95, 0.95);
  mix := Clamp(ParamF(AParams, 'mix', 0.5), 0, 1);
  d := Max(1, Round(ms * 0.001 * AFs));
  SetLength(buf, d);
  for ch := 0 to AChannels - 1 do
  begin
    for i := 0 to d - 1 do buf[i] := 0;
    for i := 0 to AFrames - 1 do
    begin
      y := AIn[ch][i] + fb * buf[i mod d];
      buf[i mod d] := y;
      AOut[ch][i] := AIn[ch][i] * (1 - mix) + y * (1 - Abs(fb)) * mix;
    end;
  end;
end;

procedure DoPeakNorm(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  pk, g: Double;
begin
  pk := 0;
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do pk := Max(pk, Abs(AIn[ch][i]));
  if pk < 1E-6 then g := 1 else g := DbToLin(Clamp(ParamF(AParams, 'peak', -1), -24, 0)) / pk;
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do AOut[ch][i] := AIn[ch][i] * g;
end;

procedure DoVocoder(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
const
  MAXB = 32;
var
  ch, i, k, nb: Integer;
  pitch, mix, ratio, fc, q, ph, dph, saw, noise, car, wet, ea, er, v, inE, outE, g: Double;
  an, cr: array[0..MAXB - 1] of TBq;
  env: array[0..MAXB - 1] of Double;
  rng: Cardinal;
  dry: TAudioSampleArray;
begin
  nb := Max(8, Min(MAXB, Round(ParamF(AParams, 'bands', 16))));
  pitch := Clamp(ParamF(AParams, 'pitch', 110), 40, 400);
  mix := Clamp(ParamF(AParams, 'mix', 1), 0, 1);
  ratio := FastPow(7000 / 120, 1 / (nb - 1));
  q := 1 / (Sqrt(ratio) - 1 / Sqrt(ratio));
  ea := FastExp(-1 / (0.003 * AFs));
  er := FastExp(-1 / (0.015 * AFs));
  dph := pitch / AFs;
  SetLength(dry, AFrames);
  for ch := 0 to AChannels - 1 do
  begin
    for k := 0 to nb - 1 do
    begin
      fc := 120 * FastPow(ratio, k);
      BqDesign(an[k], BQ_BANDPASS, AFs, fc, q, 0);
      BqDesign(cr[k], BQ_BANDPASS, AFs, fc, q, 0);
      env[k] := 0;
    end;
    rng := 1234567 + Cardinal(ch) * 104729;
    ph := 0;
    inE := 0;
    outE := 0;
    for i := 0 to AFrames - 1 do
    begin
      { synthetic carrier: a buzzy sawtooth plus a little noise so consonants stay intelligible }
      saw := 2 * ph - 1;
      ph := ph + dph;
      if ph >= 1 then ph := ph - 1;
      rng := rng xor (rng shl 13);
      rng := rng xor (rng shr 17);
      rng := rng xor (rng shl 5);
      noise := (rng / 2147483648.0) - 1;
      car := saw + 0.35 * noise;
      wet := 0;
      for k := 0 to nb - 1 do
      begin
        v := Abs(BqRun(an[k], AIn[ch][i]));
        if v > env[k] then env[k] := ea * env[k] + (1 - ea) * v
        else env[k] := er * env[k] + (1 - er) * v;
        wet := wet + env[k] * BqRun(cr[k], car);
      end;
      dry[i] := wet;
      inE := inE + AIn[ch][i] * AIn[ch][i];
      outE := outE + wet * wet;
    end;
    { match the vocoded level to the original so the effect never jumps in volume }
    if outE > 1E-18 then g := Min(30.0, Sqrt(inE / outE)) else g := 0;
    for i := 0 to AFrames - 1 do
      AOut[ch][i] := (1 - mix) * AIn[ch][i] + mix * dry[i] * g;
  end;
end;

{ ---------------- effects found in other Windows audio applications ---------------- }

procedure DoWahWah(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  rate, depth, q, fc, lfo: Double;
  f, t: TBq;
begin
  rate := Clamp(ParamF(AParams, 'rate', 0.8), 0.1, 10);
  depth := Clamp(ParamF(AParams, 'depth', 0.9), 0, 1);
  q := Clamp(ParamF(AParams, 'q', 5), 0.7, 12);
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(f, BQ_BANDPASS, AFs, 400, q, 0);
    for i := 0 to AFrames - 1 do
    begin
      if (i and 15) = 0 then
      begin
        lfo := 0.5 + 0.5 * FastSin(2 * Pi * rate * i / AFs);
        fc := 350 * FastPow(6.5, depth * lfo);
        BqDesign(t, BQ_BANDPASS, AFs, fc, q, 0);
        BqCoefs(f, t);
      end;
      AOut[ch][i] := AIn[ch][i] * 0.3 + BqRun(f, AIn[ch][i]) * 1.5;
    end;
  end;
end;

procedure DoAutoFilter(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  rate, depth, q, fc, lfo: Double;
  f, t: TBq;
begin
  rate := Clamp(ParamF(AParams, 'rate', 0.4), 0.05, 10);
  depth := Clamp(ParamF(AParams, 'depth', 0.8), 0, 1);
  q := Clamp(ParamF(AParams, 'q', 3), 0.5, 12);
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(f, BQ_LOWPASS, AFs, 800, q, 0);
    for i := 0 to AFrames - 1 do
    begin
      if (i and 7) = 0 then
      begin
        lfo := 0.5 + 0.5 * FastSin(2 * Pi * rate * i / AFs + ch * 0.6);
        fc := 8000 * FastPow(0.025, depth * (1 - lfo));
        BqDesign(t, BQ_LOWPASS, AFs, fc, q, 0);
        BqCoefs(f, t);
      end;
      AOut[ch][i] := BqRun(f, AIn[ch][i]) * 1.1;
    end;
  end;
end;

procedure DoFormant(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
const
  FORM: array[0..4, 0..2] of Double = (
    (800, 1150, 2900), (400, 1600, 2700), (270, 2140, 2950), (450, 800, 2830), (325, 700, 2700));
  AMP: array[0..2] of Double = (1.0, 0.8, 0.5);
var
  ch, i, k, v: Integer;
  bp: array[0..2] of TBq;
  mix, y, inE, outE, g: Double;
  wet: TAudioSampleArray;
begin
  v := Max(0, Min(4, Round(ParamF(AParams, 'vowel', 0))));
  mix := Clamp(ParamF(AParams, 'mix', 1), 0, 1);
  SetLength(wet, AFrames);
  for ch := 0 to AChannels - 1 do
  begin
    for k := 0 to 2 do BqDesign(bp[k], BQ_BANDPASS, AFs, FORM[v][k], 7, 0);
    inE := 0;
    outE := 0;
    for i := 0 to AFrames - 1 do
    begin
      y := 0;
      for k := 0 to 2 do y := y + AMP[k] * BqRun(bp[k], AIn[ch][i]);
      wet[i] := y;
      inE := inE + AIn[ch][i] * AIn[ch][i];
      outE := outE + y * y;
    end;
    if outE > 1E-18 then g := Min(30.0, Sqrt(inE / outE)) else g := 0;
    for i := 0 to AFrames - 1 do AOut[ch][i] := (1 - mix) * AIn[ch][i] + mix * wet[i] * g;
  end;
end;

procedure DoHaas(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  i, d: Integer;
begin
  CopyThrough(AIn, AChannels, AFrames, AOut);
  if AChannels < 2 then Exit;
  d := Max(1, Round(Clamp(ParamF(AParams, 'ms', 18), 1, 40) * 0.001 * AFs));
  for i := 0 to AFrames - 1 do
    if i >= d then AOut[1][i] := AIn[1][i - d] * 0.92 else AOut[1][i] := 0;
end;

procedure DoMonoBass(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  i: Integer;
  hz, lo: Double;
  l1, l2, h0a, h0b, h1a, h1b: TBq;
begin
  CopyThrough(AIn, AChannels, AFrames, AOut);
  if AChannels < 2 then Exit;
  hz := Clamp(ParamF(AParams, 'hz', 120), 40, 400);
  { Linkwitz-Riley (2 x Butterworth) crossover: each channel keeps its own
    highpassed signal, and only the lows are summed to mono. A plain
    "input minus lowpass" leaves a phase-shifted low residual that is not mono. }
  BqDesign(l1, BQ_LOWPASS, AFs, hz, 0.707, 0);
  BqDesign(l2, BQ_LOWPASS, AFs, hz, 0.707, 0);
  BqDesign(h0a, BQ_HIGHPASS, AFs, hz, 0.707, 0);
  BqDesign(h0b, BQ_HIGHPASS, AFs, hz, 0.707, 0);
  BqDesign(h1a, BQ_HIGHPASS, AFs, hz, 0.707, 0);
  BqDesign(h1b, BQ_HIGHPASS, AFs, hz, 0.707, 0);
  for i := 0 to AFrames - 1 do
  begin
    lo := BqRun(l2, BqRun(l1, (AIn[0][i] + AIn[1][i]) * 0.5));
    AOut[0][i] := BqRun(h0b, BqRun(h0a, AIn[0][i])) + lo;
    AOut[1][i] := BqRun(h1b, BqRun(h1a, AIn[1][i])) + lo;
  end;
end;

procedure DoVocalRemove(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  i: Integer;
  amt, keep, mid, lo: Double;
  l1, l2: TBq;
begin
  CopyThrough(AIn, AChannels, AFrames, AOut);
  if AChannels < 2 then Exit;
  amt := Clamp(ParamF(AParams, 'amt', 1), 0, 1);
  keep := Clamp(ParamF(AParams, 'keepbass', 1), 0, 1);
  BqDesign(l1, BQ_LOWPASS, AFs, 120, 0.707, 0);
  BqDesign(l2, BQ_LOWPASS, AFs, 120, 0.707, 0);
  for i := 0 to AFrames - 1 do
  begin
    mid := (AIn[0][i] + AIn[1][i]) * 0.5;
    lo := BqRun(l2, BqRun(l1, mid));
    AOut[0][i] := AIn[0][i] - amt * mid + amt * keep * lo;
    AOut[1][i] := AIn[1][i] - amt * mid + amt * keep * lo;
  end;
end;

procedure DoTape(const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer; var AOut: TAudioPlanar);
var
  ch, i: Integer;
  lp, hp: TBq;
  tmp: TAudioSampleArray;
  dly: Double;
begin
  SetLength(tmp, AFrames);
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(lp, BQ_LOWPASS, AFs, 12000, 0.707, 0);
    BqDesign(hp, BQ_HIGHPASS, AFs, 30, 0.707, 0);
    for i := 0 to AFrames - 1 do
      tmp[i] := BqRun(lp, BqRun(hp, Tanh(AIn[ch][i] * 1.8) * 0.62));
    for i := 0 to AFrames - 1 do
    begin
      dly := AFs * (0.003 + 0.0006 * FastSin(2 * Pi * 0.6 * i / AFs) + 0.00008 * FastSin(2 * Pi * 7.3 * i / AFs + ch));
      AOut[ch][i] := ReadInterp(tmp, AFrames, i - dly);
    end;
  end;
end;

procedure DoRadio(const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer; var AOut: TAudioPlanar);
var
  ch, i: Integer;
  h1, h2, l1, l2: TBq;
  v, n: Double;
  rng: Cardinal;
begin
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(h1, BQ_HIGHPASS, AFs, 300, 0.707, 0);
    BqDesign(h2, BQ_HIGHPASS, AFs, 300, 0.707, 0);
    BqDesign(l1, BQ_LOWPASS, AFs, 5000, 0.707, 0);
    BqDesign(l2, BQ_LOWPASS, AFs, 5000, 0.707, 0);
    rng := 88172645 + Cardinal(ch) * 7727;
    for i := 0 to AFrames - 1 do
    begin
      rng := rng xor (rng shl 13);
      rng := rng xor (rng shr 17);
      rng := rng xor (rng shl 5);
      n := (rng / 2147483648.0) - 1;
      v := BqRun(l2, BqRun(l1, BqRun(h2, BqRun(h1, AIn[ch][i] + n * 0.004))));
      AOut[ch][i] := Tanh(v * 2.5) * 0.6;
    end;
  end;
end;

{ 4x oversampled waveshaper: cubic upsampling, shape, low-pass below Nyquist, decimate }
procedure Shape4x(const X: TAudioSampleArray; AFrames, AFs: Integer; ADrive, ABias: Double;
  var Y: TAudioSampleArray);
var
  i, k: Integer;
  p0, p1, p2, p3, t, u, s: Double;
  a, b: TBq;
begin
  SetLength(Y, AFrames);
  BqDesign(a, BQ_LOWPASS, 4 * AFs, 0.42 * AFs, 0.54, 0);
  BqDesign(b, BQ_LOWPASS, 4 * AFs, 0.42 * AFs, 1.31, 0);
  for i := 0 to AFrames - 1 do
  begin
    if i > 0 then p0 := X[i - 1] else p0 := X[i];
    p1 := X[i];
    if i + 1 < AFrames then p2 := X[i + 1] else p2 := p1;
    if i + 2 < AFrames then p3 := X[i + 2] else p3 := p2;
    for k := 0 to 3 do
    begin
      t := k / 4;
      u := 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t +
        (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t);
      s := BqRun(b, BqRun(a, Tanh(u * ADrive + ABias) - Tanh(ABias)));
      if k = 0 then Y[i] := s;
    end;
  end;
end;

procedure DoFuzz(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  drive, bias: Double;
  lp: TBq;
  y: TAudioSampleArray;
begin
  drive := Clamp(ParamF(AParams, 'drive', 25), 3, 80);
  bias := 0.25;
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(lp, BQ_LOWPASS, AFs, 6000, 0.707, 0);
    Shape4x(AIn[ch], AFrames, AFs, drive, bias, y);
    for i := 0 to AFrames - 1 do AOut[ch][i] := BqRun(lp, y[i]) * 0.5;
  end;
end;

procedure DoRectifier(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  mix: Double;
  hp: TBq;
begin
  mix := Clamp(ParamF(AParams, 'mix', 0.6), 0, 1);
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(hp, BQ_HIGHPASS, AFs, 40, 0.707, 0);
    for i := 0 to AFrames - 1 do
      AOut[ch][i] := (1 - mix) * AIn[ch][i] + mix * 1.6 * BqRun(hp, Abs(AIn[ch][i]));
  end;
end;

procedure DoEnsemble(const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer; var AOut: TAudioPlanar);
var
  ch, i, v: Integer;
  sum, dly: Double;
begin
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do
    begin
      sum := 0;
      for v := 0 to 2 do
      begin
        dly := AFs * 0.001 * (12 + 3 * FastSin(2 * Pi * (0.31 + 0.13 * v) * i / AFs + v * 2.1 + ch * 1.3));
        sum := sum + ReadInterp(AIn[ch], AFrames, i - dly);
      end;
      AOut[ch][i] := AIn[ch][i] * 0.6 + sum * 0.3;
    end;
end;

procedure DoMultiTap(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
const
  G: array[1..4] of Double = (0.7, 0.55, 0.4, 0.3);
var
  ch, i, k, d: Integer;
  ms, mix, acc: Double;
begin
  ms := Clamp(ParamF(AParams, 'ms', 600), 100, 2000);
  mix := Clamp(ParamF(AParams, 'mix', 0.5), 0, 1);
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do
    begin
      acc := 0;
      for k := 1 to 4 do
      begin
        d := Round(ms * k / 4 * 0.001 * AFs);
        if i >= d then acc := acc + G[k] * AIn[ch][i - d];
      end;
      AOut[ch][i] := AIn[ch][i] + mix * acc;
    end;
end;

procedure DoTapeDelay(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  ms, fb, mix, dly, rd, lp, damp: Double;
  w: TAudioSampleArray;
begin
  ms := Clamp(ParamF(AParams, 'ms', 350), 40, 1500);
  fb := Clamp(ParamF(AParams, 'fb', 0.5), 0, 0.9);
  mix := Clamp(ParamF(AParams, 'mix', 0.35), 0, 1);
  damp := 0.3;
  SetLength(w, AFrames);
  for ch := 0 to AChannels - 1 do
  begin
    lp := 0;
    for i := 0 to AFrames - 1 do
    begin
      dly := AFs * 0.001 * ms * (1 + 0.004 * FastSin(2 * Pi * 0.5 * i / AFs + ch)) ;
      if i - dly >= 0 then rd := ReadInterp(w, AFrames, i - dly) else rd := 0;
      lp := lp + damp * (rd - lp);
      w[i] := AIn[ch][i] + Tanh(fb * lp);
      AOut[ch][i] := AIn[ch][i] + mix * rd;
    end;
  end;
end;

procedure DoStutter(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i, stepLen, sliceLen, s0, k, edge: Integer;
  rep: Integer;
  g: Double;
begin
  stepLen := Max(64, Round(Clamp(ParamF(AParams, 'ms', 250), 20, 4000) * 0.001 * AFs));
  rep := Max(2, Min(16, Round(ParamF(AParams, 'rep', 4))));
  sliceLen := Max(32, stepLen div rep);
  edge := Max(1, Min(sliceLen div 4, Round(0.002 * AFs)));
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do
    begin
      s0 := (i div stepLen) * stepLen;
      k := (i - s0) mod sliceLen;
      g := 1;
      if k < edge then g := k / edge
      else if k > sliceLen - edge then g := (sliceLen - k) / edge;
      AOut[ch][i] := AIn[ch][Min(AFrames - 1, s0 + k)] * g;
    end;
end;

procedure DoParallelComp(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  mix: Double;
  tmp: TAudioSampleArray;
begin
  mix := Clamp(ParamF(AParams, 'mix', 0.5), 0, 1);
  SetLength(tmp, AFrames);
  for ch := 0 to AChannels - 1 do
  begin
    for i := 0 to AFrames - 1 do tmp[i] := AIn[ch][i];
    CompressInPlace(tmp, AFrames, AFs, -32, 8, 4, 90, 8);
    for i := 0 to AFrames - 1 do AOut[ch][i] := (1 - mix * 0.5) * AIn[ch][i] + mix * 0.5 * tmp[i];
  end;
end;

procedure DoTilt(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  tilt, trim: Double;
  sh: TBq;
begin
  tilt := Clamp(ParamF(AParams, 'tilt', 3), -12, 12);
  trim := DbToLin(-tilt / 2);
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(sh, BQ_HISHELF, AFs, 1000, 0.707, tilt);
    for i := 0 to AFrames - 1 do AOut[ch][i] := BqRun(sh, AIn[ch][i]) * trim;
  end;
end;

{ ---------------- tools modelled on professional audio suites ---------------- }

{ peak of the signal between two samples, estimated by cubic (Catmull-Rom) interpolation at 4x }
function TruePeakFrame(const X: TAudioSampleArray; AFrames, AIdx: Integer): Double;
var
  p0, p1, p2, p3, t, v: Double;
  k: Integer;
begin
  Result := Abs(X[AIdx]);
  if AIdx + 1 >= AFrames then Exit;
  if AIdx > 0 then p0 := X[AIdx - 1] else p0 := X[AIdx];
  p1 := X[AIdx];
  p2 := X[AIdx + 1];
  if AIdx + 2 < AFrames then p3 := X[AIdx + 2] else p3 := p2;
  for k := 1 to 3 do
  begin
    t := k / 4;
    v := 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t +
      (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t);
    if Abs(v) > Result then Result := Abs(v);
  end;
end;

procedure MeasureAudio(const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer; out AReport: TAudioMeterReport);
var
  ch, i, blk, hop, b, a0, a1, nWin: Integer;
  sh, hp: TBq;
  pre: array of Double;
  k: Double;
  sumL, sumR, sumLR, sumM, sumS, sumSq, pk, tp, dc, ms, v: Double;
  winLen: Integer;
begin
  AReport.IntegratedLufs := -70;
  AReport.MomentaryMaxLufs := -70;
  AReport.ShortTermMaxLufs := -70;
  AReport.SamplePeakDb := -180;
  AReport.TruePeakDb := -180;
  AReport.RmsDb := -180;
  AReport.Correlation := 1;
  AReport.SideToMidDb := -180;
  AReport.DcOffset := 0;
  if (AChannels < 1) or (AFrames < 1) then Exit;
  AReport.IntegratedLufs := MeasureLufs(AIn, AChannels, AFrames, AFs);
  { momentary (400 ms) and short-term (3 s) maxima over K-weighted power }
  SetLength(pre, AFrames + 1);
  pre[0] := 0;
  for i := 0 to AFrames - 1 do pre[i + 1] := 0;
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(sh, BQ_HISHELF, AFs, 1500, 0.707, 4);
    BqDesign(hp, BQ_HIGHPASS, AFs, 38, 0.5, 0);
    for i := 0 to AFrames - 1 do
    begin
      k := BqRun(hp, BqRun(sh, AIn[ch][i]));
      pre[i + 1] := pre[i + 1] + k * k;
    end;
  end;
  for i := 1 to AFrames do pre[i] := pre[i] + pre[i - 1];
  for b := 0 to 1 do
  begin
    if b = 0 then winLen := Round(0.4 * AFs) else winLen := 3 * AFs;
    winLen := Max(1, Min(winLen, AFrames));
    hop := Max(1, Round(0.1 * AFs));
    nWin := (AFrames - winLen) div hop + 1;
    v := -70;
    for blk := 0 to nWin - 1 do
    begin
      a0 := blk * hop;
      a1 := a0 + winLen;
      ms := (pre[a1] - pre[a0]) / winLen;
      v := Max(v, -0.691 + 10 * FastLog10(Max(ms, 1E-12)));
    end;
    if b = 0 then AReport.MomentaryMaxLufs := v else AReport.ShortTermMaxLufs := v;
  end;
  { peaks, RMS, DC }
  pk := 0; tp := 0; sumSq := 0; dc := 0;
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do
    begin
      pk := Max(pk, Abs(AIn[ch][i]));
      tp := Max(tp, TruePeakFrame(AIn[ch], AFrames, i));
      sumSq := sumSq + AIn[ch][i] * AIn[ch][i];
      dc := dc + AIn[ch][i];
    end;
  AReport.SamplePeakDb := LinToDb(pk);
  AReport.TruePeakDb := LinToDb(tp);
  AReport.RmsDb := LinToDb(Sqrt(sumSq / (AFrames * AChannels)));
  AReport.DcOffset := dc / (AFrames * AChannels);
  if AChannels >= 2 then
  begin
    sumL := 0; sumR := 0; sumLR := 0; sumM := 0; sumS := 0;
    for i := 0 to AFrames - 1 do
    begin
      sumL := sumL + AIn[0][i] * AIn[0][i];
      sumR := sumR + AIn[1][i] * AIn[1][i];
      sumLR := sumLR + AIn[0][i] * AIn[1][i];
      sumM := sumM + Sqr((AIn[0][i] + AIn[1][i]) * 0.5);
      sumS := sumS + Sqr((AIn[0][i] - AIn[1][i]) * 0.5);
    end;
    if (sumL > 1E-18) and (sumR > 1E-18) then AReport.Correlation := sumLR / Sqrt(sumL * sumR);
    if sumM > 1E-18 then AReport.SideToMidDb := 10 * FastLog10(Max(sumS, 1E-18) / sumM);
  end;
end;

function MeasureAmbisonics(const AIn: TAudioPlanar; AChannels, AFrames: Integer; out AReport: TAmbisonicReport): Boolean;
var
  i: Integer;
  w, y, z, x, sw, sy, sz, sx, iw, iy, iz, ix, hor, mag: Double;
begin
  for i := 0 to 3 do AReport.ChannelRmsDb[i] := -180;
  AReport.AzimuthDeg := 0;
  AReport.ElevationDeg := 0;
  AReport.Directivity := 0;
  Result := (AChannels >= 4) and (AFrames > 0);
  if not Result then Exit;
  sw := 0; sy := 0; sz := 0; sx := 0;
  ix := 0; iy := 0; iz := 0;
  for i := 0 to AFrames - 1 do
  begin
    w := AIn[0][i]; y := AIn[1][i]; z := AIn[2][i]; x := AIn[3][i];
    sw := sw + w * w; sy := sy + y * y; sz := sz + z * z; sx := sx + x * x;
    ix := ix + w * x; iy := iy + w * y; iz := iz + w * z;
  end;
  AReport.ChannelRmsDb[0] := LinToDb(Sqrt(sw / AFrames));
  AReport.ChannelRmsDb[1] := LinToDb(Sqrt(sy / AFrames));
  AReport.ChannelRmsDb[2] := LinToDb(Sqrt(sz / AFrames));
  AReport.ChannelRmsDb[3] := LinToDb(Sqrt(sx / AFrames));
  iw := sw;
  hor := Sqrt(ix * ix + iy * iy);
  mag := Sqrt(ix * ix + iy * iy + iz * iz);
  if mag > 1E-18 then
  begin
    AReport.AzimuthDeg := FastArcTan2(iy, ix) * 180 / Pi;
    AReport.ElevationDeg := FastArcTan2(iz, hor) * 180 / Pi;
  end;
  if iw > 1E-18 then AReport.Directivity := Clamp(mag / iw, 0, 1);
end;

procedure DoDePop(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  amt, hz, base, env, ea, er, r, g, gs, thr, lo, ss: Double;
  l1, l2: TBq;
  lowArr: TAudioSampleArray;
begin
  amt := Clamp(ParamF(AParams, 'amt', 1), 0, 1);
  hz := Clamp(ParamF(AParams, 'hz', 150), 60, 300);
  ea := FastExp(-1 / (0.002 * AFs));
  er := FastExp(-1 / (0.03 * AFs));
  gs := FastExp(-1 / (0.004 * AFs));
  SetLength(lowArr, AFrames);
  for ch := 0 to AChannels - 1 do
  begin
    BqDesign(l1, BQ_LOWPASS, AFs, hz, 0.707, 0);
    BqDesign(l2, BQ_LOWPASS, AFs, hz, 0.707, 0);
    ss := 0;
    for i := 0 to AFrames - 1 do
    begin
      lowArr[i] := BqRun(l2, BqRun(l1, AIn[ch][i]));
      ss := ss + lowArr[i] * lowArr[i];
    end;
    base := Sqrt(ss / Max(1, AFrames));
    thr := Max(base * 2.5, 1E-5);
    env := 0;
    g := 1;
    for i := 0 to AFrames - 1 do
    begin
      lo := lowArr[i];
      if Abs(lo) > env then env := ea * env + (1 - ea) * Abs(lo)
      else env := er * env + (1 - er) * Abs(lo);
      r := 1;
      if env > thr then r := FastPow(thr / env, amt);
      r := Max(0.08, r);
      g := gs * g + (1 - gs) * r;
      AOut[ch][i] := AIn[ch][i] - lo * (1 - g);
    end;
  end;
end;

{ Level Rider / Dialog Rider: slow, linked gain riding toward a target level, limited to +/- range dB }
procedure DoRider(const AParams: string; AGated: Boolean; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  target, range, ms, gate, lvlDb, want, g, ea, ga, s, msq: Double;
  hp, lp: TBq;
  gains: TAudioSampleArray;
begin
  target := Clamp(ParamF(AParams, 'target', -20), -50, -6);
  range := Clamp(ParamF(AParams, 'range', 6), 1, 24);
  ms := Clamp(ParamF(AParams, 'ms', 400), 50, 3000);
  if AGated then gate := Clamp(ParamF(AParams, 'gate', -55), -80, -20) else gate := -80;
  ea := FastExp(-1 / (ms * 0.001 * AFs));
  ga := FastExp(-1 / (ms * 0.003 * AFs));
  BqDesign(hp, BQ_HIGHPASS, AFs, 150, 0.707, 0);
  BqDesign(lp, BQ_LOWPASS, AFs, 4000, 0.707, 0);
  SetLength(gains, AFrames);
  msq := 0;
  g := 0;
  for i := 0 to AFrames - 1 do
  begin
    s := 0;
    for ch := 0 to AChannels - 1 do s := s + AIn[ch][i];
    s := s / AChannels;
    if AGated then s := BqRun(lp, BqRun(hp, s));
    msq := ea * msq + (1 - ea) * s * s;
    lvlDb := 10 * FastLog10(Max(msq, 1E-14));
    if lvlDb > gate then
    begin
      want := Clamp(target - lvlDb, -range, range);
      g := ga * g + (1 - ga) * want;
    end;
    gains[i] := DbToLin(g);
  end;
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do AOut[ch][i] := AIn[ch][i] * gains[i];
end;

procedure DoTruePeakLimiter(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i, L, head, tail, c, idx, lo, hi: Integer;
  ceiling, rel, pk, rc, r, sum: Double;
  g, gmin, gbox, pre: array of Double;
  dq: array of Integer;
begin
  ceiling := DbToLin(Clamp(ParamF(AParams, 'ceiling', -1), -12, 0));
  L := Max(1, Round(Clamp(ParamF(AParams, 'look', 5), 1, 20) * 0.001 * AFs));
  rel := Clamp(ParamF(AParams, 'release', 100), 10, 1000);
  rc := 1 - FastExp(-1 / (rel * 0.001 * AFs));
  SetLength(g, AFrames);
  SetLength(gmin, AFrames);
  SetLength(gbox, AFrames);
  SetLength(pre, AFrames + 1);
  SetLength(dq, AFrames);
  for i := 0 to AFrames - 1 do
  begin
    pk := 0;
    for ch := 0 to AChannels - 1 do pk := Max(pk, TruePeakFrame(AIn[ch], AFrames, i));
    if pk > ceiling then g[i] := ceiling / pk else g[i] := 1;
  end;
  { minimum over +/- L samples, then an average over the same span: the result never exceeds the
    gain any sample inside its window needs, so the ceiling holds without hard gain jumps }
  head := 0; tail := 0;
  for idx := 0 to AFrames - 1 + L do
  begin
    if idx < AFrames then
    begin
      while (tail > head) and (g[dq[tail - 1]] >= g[idx]) do Dec(tail);
      dq[tail] := idx;
      Inc(tail);
    end;
    c := idx - L;
    if c >= 0 then
    begin
      while dq[head] < c - L do Inc(head);
      gmin[c] := g[dq[head]];
    end;
  end;
  pre[0] := 0;
  for i := 0 to AFrames - 1 do pre[i + 1] := pre[i] + gmin[i];
  for i := 0 to AFrames - 1 do
  begin
    lo := Max(0, i - L);
    hi := Min(AFrames - 1, i + L);
    sum := pre[hi + 1] - pre[lo];
    gbox[i] := sum / (hi - lo + 1);
  end;
  r := 1;
  for i := 0 to AFrames - 1 do
  begin
    if gbox[i] < r then r := gbox[i] else r := r + (gbox[i] - r) * rc;
    for ch := 0 to AChannels - 1 do AOut[ch][i] := AIn[ch][i] * r;
  end;
end;

procedure DoOverSat(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames, AFs: Integer;
  var AOut: TAudioPlanar);
var
  ch, i: Integer;
  drive, mix, comp: Double;
  y: TAudioSampleArray;
begin
  drive := Clamp(ParamF(AParams, 'drive', 3), 1, 20);
  mix := Clamp(ParamF(AParams, 'mix', 1), 0, 1);
  comp := 1 / Max(0.4, Tanh(drive * 0.5));
  for ch := 0 to AChannels - 1 do
  begin
    Shape4x(AIn[ch], AFrames, AFs, drive, 0, y);
    for i := 0 to AFrames - 1 do AOut[ch][i] := (1 - mix) * AIn[ch][i] + mix * y[i] * comp * 0.8;
  end;
end;

function FadeShape(AShape: Integer; AU: Double): Double;
begin
  AU := Clamp(AU, 0, 1);
  case AShape of
    1: Result := AU * AU * (3 - 2 * AU);
    2: Result := FastSin(AU * Pi / 2);
    3: Result := (FastPow(100, AU) - 1) / 99;
    4: Result := FastLn(1 + 9 * AU) / FastLn(10);
  else
    Result := AU;
  end;
end;

procedure DoFadeCurve(const AParams: string; const AIn: TAudioPlanar; AChannels, AFrames: Integer;
  var AOut: TAudioPlanar);
var
  ch, i, shape: Integer;
  fadeOut: Boolean;
  u, g: Double;
begin
  shape := Max(0, Min(4, Round(ParamF(AParams, 'shape', 1))));
  fadeOut := ParamF(AParams, 'out', 0) >= 0.5;
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do
    begin
      if AFrames > 1 then u := i / (AFrames - 1) else u := 1;
      if fadeOut then u := 1 - u;
      g := FadeShape(shape, u);
      AOut[ch][i] := AIn[ch][i] * g;
    end;
end;

procedure ApplyExtraFx(const AKind, AParams: string; const AIn: TAudioPlanar;
  AChannels, AFrames, ASampleRate: Integer; var AOut: TAudioPlanar);
var
  ch, i: Integer;
begin
  ResizeOut(AOut, AChannels, AFrames);
  if SameText(AKind, '@echo') then DoEcho(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@swaplr') then
  begin
    { left and right trade places; any channel beyond the first pair stays put }
    for ch := 0 to AChannels - 1 do
      for i := 0 to AFrames - 1 do
        if (AChannels >= 2) and (ch = 0) then AOut[ch][i] := AIn[1][i]
        else if (AChannels >= 2) and (ch = 1) then AOut[ch][i] := AIn[0][i]
        else AOut[ch][i] := AIn[ch][i];
  end
  else if SameText(AKind, '@invertphase') then
  begin
    for ch := 0 to AChannels - 1 do
      for i := 0 to AFrames - 1 do AOut[ch][i] := -AIn[ch][i];
  end
  else if SameText(AKind, '@ringmod') then DoRing(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@vibrato') then DoVibrato(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@vocalchannel') then DoVocalChannel(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@dialogueleveler') then DoDialogueLeveler(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@loudnorm') then DoLoudNorm(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@dehum') then DoDehum(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@declick') then DoDeclick(AParams, AIn, AChannels, AFrames, AOut)
  else if SameText(AKind, '@declip') then DoDeclip(AIn, AChannels, AFrames, AOut)
  else if SameText(AKind, '@bandpass') then DoBandpass(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@telephone') then DoTelephone(AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@stereofixer') then DoStereoFixer(AParams, AIn, AChannels, AFrames, AOut)
  else if SameText(AKind, '@midside') then DoMidSide(AParams, AIn, AChannels, AFrames, AOut)
  else if SameText(AKind, '@crossfeed') then DoCrossfeed(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@lfefilter') then DoLfe(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@subbass') then DoSubBass(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@freqshift') then DoFreqShift(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@autowah') then DoAutoWah(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@robot') then DoRobot(AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@megaphone') then DoMegaphone(AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@underwater') then DoUnderwater(AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@tapestop') then DoTapeStop(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@gater') then DoGater(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@rotary') then DoRotary(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@vinyl') then DoVinyl(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@comb') then DoComb(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@peaknorm') then DoPeakNorm(AParams, AIn, AChannels, AFrames, AOut)
  else if SameText(AKind, '@vocoder') then DoVocoder(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@wahwah') then DoWahWah(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@autofilter') then DoAutoFilter(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@formant') then DoFormant(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@haas') then DoHaas(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@monobass') then DoMonoBass(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@vocalremove') then DoVocalRemove(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@tape') then DoTape(AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@radio') then DoRadio(AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@fuzz') then DoFuzz(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@rectifier') then DoRectifier(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@ensemble') then DoEnsemble(AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@multitap') then DoMultiTap(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@tapedelay') then DoTapeDelay(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@stutter') then DoStutter(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@parallelcomp') then DoParallelComp(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@tilteq') then DoTilt(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@depop') then DoDePop(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@levelrider') then DoRider(AParams, False, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@dialogrider') then DoRider(AParams, True, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@tplimiter') then DoTruePeakLimiter(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@oversat') then DoOverSat(AParams, AIn, AChannels, AFrames, ASampleRate, AOut)
  else if SameText(AKind, '@fadecurve') then DoFadeCurve(AParams, AIn, AChannels, AFrames, AOut)
  else
    for ch := 0 to AChannels - 1 do
      for i := 0 to AFrames - 1 do AOut[ch][i] := AIn[ch][i];
end;

end.
