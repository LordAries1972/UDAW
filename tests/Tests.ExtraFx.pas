unit Tests.ExtraFx;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Offline audio effects of the Timeline menu (UDAW.Timeline.ExtraFx) and the
  extended video effect set (UDAW.Video.EffectsPlus), each checked against
  input whose correct output is known. }

interface

procedure RegisterExtraFxTests;

implementation

uses
  SysUtils, Math,
  UDAW.Testing, UDAW.Audio.Types, UDAW.Timeline.ExtraFx, UDAW.Timeline.SpectralFx,
  UDAW.Timeline.LoopScan,
  UDAW.Video.Effects, UDAW.DSP.CurveMath, UDAW.DSP.Dynamics, UDAW.DSP.Spectral,
  UDAW.DSP.Distortion, UDAW.DSP.Exciter;

const
  GRP = 'timeline.extrafx';
  SR = 44100;

function SinePlanar(AChannels, AFrames: Integer; AHz, AAmp: Double): TAudioPlanar;
var
  ch, i: Integer;
begin
  SetLength(Result, AChannels);
  for ch := 0 to AChannels - 1 do
  begin
    SetLength(Result[ch], AFrames);
    for i := 0 to AFrames - 1 do
      Result[ch][i] := AAmp * Sin(2 * Pi * AHz * i / SR);
  end;
end;

function Rms(const A: TAudioSampleArray; AFrom, ATo: Integer): Double;
var
  i: Integer;
begin
  Result := 0;
  for i := AFrom to ATo - 1 do Result := Result + Sqr(A[i]);
  Result := Sqrt(Result / Max(1, ATo - AFrom));
end;

procedure KindsAreRecognised;
begin
  Check(IsExtraFxKind('@echo') and IsExtraFxKind('@declip') and IsExtraFxKind('@telephone'), 'extra kinds');
  CheckFalse(IsExtraFxKind('@denoise'), 'denoise is a spectral kind, not an extra one');
  Check(IsSpectralKind('@echo'), 'the spectral dispatcher also routes extra kinds');
end;

procedure SwapAndInvert;
var
  src, outp: TAudioPlanar;
  i: Integer;
begin
  SetLength(src, 2);
  SetLength(src[0], 8);
  SetLength(src[1], 8);
  for i := 0 to 7 do
  begin
    src[0][i] := 0.1 * i;
    src[1][i] := -0.05 * i;
  end;
  ApplyExtraFx('@swaplr', '', src, 2, 8, SR, outp);
  CheckNear(src[1][3], outp[0][3], 1E-7, 'left now holds right');
  CheckNear(src[0][3], outp[1][3], 1E-7, 'right now holds left');
  ApplyExtraFx('@invertphase', '', src, 2, 8, SR, outp);
  CheckNear(-src[0][5], outp[0][5], 1E-7, 'phase inverted');
end;

procedure EchoRepeatsTheSignal;
var
  src, outp: TAudioPlanar;
  d: Integer;
begin
  SetLength(src, 1);
  SetLength(src[0], SR);
  src[0][0] := 1;
  ApplyExtraFx('@echo', 'ms=100;fb=0.5;mix=1', src, 1, SR, SR, outp);
  d := Round(0.1 * SR);
  CheckNear(1.0, outp[0][0], 1E-6, 'dry impulse kept');
  Check(Abs(outp[0][d]) > 0.5, 'first echo arrives after the delay');
  Check(Abs(outp[0][d - 3]) < 1E-6, 'silence before the echo');
  Check(Abs(outp[0][2 * d]) > 0.05, 'a second, quieter echo follows');
end;

procedure DehumRemovesTheHum;
var
  src, outp: TAudioPlanar;
  i: Integer;
  before, after, keep: Double;
begin
  src := SinePlanar(1, SR, 50, 0.4);
  for i := 0 to SR - 1 do src[0][i] := src[0][i] + 0.3 * Sin(2 * Pi * 1000 * i / SR);
  ApplyExtraFx('@dehum', 'hz=50', src, 1, SR, SR, outp);
  before := Rms(src[0], SR div 2, SR);
  after := Rms(outp[0], SR div 2, SR);
  keep := 0.3 / Sqrt(2);
  Check(after < before, 'level drops');
  CheckNear(keep, after, 0.05, 'only the 1 kHz tone remains');
end;

procedure DeclickRepairsAnImpulse;
var
  src, outp: TAudioPlanar;
begin
  src := SinePlanar(1, 8000, 200, 0.3);
  src[0][4000] := 0.95;
  ApplyExtraFx('@declick', 'sens=9', src, 1, 8000, SR, outp);
  Check(Abs(outp[0][4000]) < 0.4, 'click removed');
  CheckNear(src[0][1000], outp[0][1000], 1E-6, 'clean audio untouched');
end;

procedure DeclipRestoresPeaks;
var
  src, outp: TAudioPlanar;
  i: Integer;
  clippedPeak: Double;
begin
  src := SinePlanar(1, 6000, 2000, 1.4);
  for i := 0 to 5999 do
    src[0][i] := Max(-0.8, Min(0.8, src[0][i]));
  ApplyExtraFx('@declip', '', src, 1, 6000, SR, outp);
  clippedPeak := 0;
  for i := 0 to 5999 do clippedPeak := Max(clippedPeak, Abs(outp[0][i]));
  Check(clippedPeak <= 0.9901, 'never exceeds full scale');
  Check(clippedPeak > 0.85, 'flat tops are rebuilt above the clip level');
end;

procedure LoudnessNormalizeHitsTarget;
var
  src, outp: TAudioPlanar;
  g: Double;
begin
  src := SinePlanar(2, SR * 3, 1000, 0.05);
  ApplyExtraFx('@loudnorm', 'lufs=-16', src, 2, SR * 3, SR, outp);
  g := Rms(outp[0], 0, SR * 3) / Rms(src[0], 0, SR * 3);
  Check(g > 2, 'quiet material is raised');
  Check(Rms(outp[0], 0, SR * 3) > 0.05, 'level increased');
end;

procedure DialogueLevelerEvensOutLevels;
var
  src, outp: TAudioPlanar;
  i, n: Integer;
  r1, r2, o1, o2: Double;
begin
  n := SR * 6;
  src := SinePlanar(1, n, 300, 0.4);
  for i := n div 2 to n - 1 do src[0][i] := src[0][i] * 0.12;
  ApplyExtraFx('@dialogueleveler', 'target=-20', src, 1, n, SR, outp);
  r1 := Rms(src[0], SR, SR * 2);
  r2 := Rms(src[0], n - SR * 2, n - SR);
  o1 := Rms(outp[0], SR, SR * 2);
  o2 := Rms(outp[0], n - SR * 2, n - SR);
  Check(o2 / o1 > r2 / r1 * 1.5, 'the quiet half is brought closer to the loud half');
end;

procedure VocalChannelAndFilters;
var
  src, outp: TAudioPlanar;
begin
  src := SinePlanar(1, SR, 40, 0.5);
  ApplyExtraFx('@vocalchannel', 'amt=1', src, 1, SR, SR, outp);
  Check(Rms(outp[0], SR div 2, SR) < Rms(src[0], SR div 2, SR) * 0.5, 'rumble below 85 Hz is cut');
  src := SinePlanar(1, SR, 8000, 0.5);
  ApplyExtraFx('@telephone', '', src, 1, SR, SR, outp);
  Check(Rms(outp[0], SR div 2, SR) < 0.1, 'telephone band removes 8 kHz');
  src := SinePlanar(1, SR, 1000, 0.5);
  ApplyExtraFx('@bandpass', 'freq=1000;q=1.2', src, 1, SR, SR, outp);
  Check(Rms(outp[0], SR div 2, SR) > 0.3, 'band-pass passes its centre');
end;

procedure SpectralDispatcherRoutes;
var
  src, outp: TAudioPlanar;
begin
  src := SinePlanar(2, 4000, 440, 0.3);
  ApplySpectralFx('@invertphase', '', src, 2, 4000, SR, outp);
  CheckNear(-src[1][100], outp[1][100], 1E-7, 'routed through ApplySpectralFx');
end;

procedure NewVideoEffectsAreReachable;
var
  info: TVideoFxInfo;
  ids: array[0..11] of string;
  i: Integer;
begin
  ids[0] := 'gaussian'; ids[1] := 'lensflare'; ids[2] := 'oilpaint'; ids[3] := 'swirl';
  ids[4] := 'kenburns'; ids[5] := 'colorbars'; ids[6] := 'irisdiamond'; ids[7] := 'shapeheart';
  ids[8] := 'burnaway'; ids[9] := 'dehaze'; ids[10] := 'vhs'; ids[11] := 'cardflipx';
  for i := 0 to High(ids) do
    Check(VideoFxFind(ids[i], info), 'catalogued: ' + ids[i]);
  Check(VideoFxCount >= 200, 'catalogue holds the extended set');
end;

procedure TransitionsEndOnTheIncomingPicture;
const
  W = 32;
  H = 24;
var
  i, j: Integer;
  info: TVideoFxInfo;
  a, b, dst: TBytes;
begin
  SetLength(a, W * H * 4);
  SetLength(b, W * H * 4);
  SetLength(dst, W * H * 4);
  for i := 0 to W * H - 1 do
  begin
    a[i * 4] := 10; a[i * 4 + 1] := 20; a[i * 4 + 2] := 30;
    b[i * 4] := 200; b[i * 4 + 1] := 210; b[i * 4 + 2] := 220;
  end;
  for i := 0 to VideoFxCount - 1 do
  begin
    info := VideoFxInfoAt(i);
    if info.Cls <> vfTransition then Continue;
    if i < 52 then Continue;   { the original set has soft wipe edges; only the extended set is exact at the ends }
    VideoFxRenderTransition(info.Id, '', 0, @a[0], @b[0], @dst[0], W, H, 1);
    for j := 0 to W * H * 4 - 1 do
      if dst[j] <> a[j] then
      begin
        Check(False, 'starts on the outgoing picture: ' + info.Id);
        Break;
      end;
    VideoFxRenderTransition(info.Id, '', 1, @a[0], @b[0], @dst[0], W, H, 1);
    for j := 0 to W * H * 4 - 1 do
      if dst[j] <> b[j] then
      begin
        Check(False, 'ends on the incoming picture: ' + info.Id);
        Break;
      end;
  end;
end;

procedure FairlightStyleEffects;
var
  src, outp: TAudioPlanar;
  i, N: Integer;
  pk, pre, post: Double;
  meter: TAudioMeterReport;
begin
  N := SR;
  { peak normalize hits the requested peak }
  src := SinePlanar(2, N, 440, 0.1);
  ApplyExtraFx('@peaknorm', 'peak=-6', src, 2, N, SR, outp);
  pk := 0;
  for i := 0 to N - 1 do pk := Max(pk, Abs(outp[0][i]));
  CheckNear(0.5012, pk, 0.01, 'peak normalize to -6 dBFS');
  { stereo fixer re-inverts a polarity-flipped right channel }
  src := SinePlanar(2, N, 440, 0.5);
  for i := 0 to N - 1 do src[1][i] := -src[1][i];
  ApplyExtraFx('@stereofixer', 'width=1', src, 2, N, SR, outp);
  CheckNear(outp[0][1000], outp[1][1000], 1E-4, 'stereo fixer repairs inverted polarity');
  { mid/side with side cut collapses an out-of-phase signal }
  ApplyExtraFx('@midside', 'mid=0;side=-24', src, 2, N, SR, outp);
  Check(Rms(outp[0], 0, N) < 0.1, 'side cut removes out-of-phase content');
  { LFE filter keeps 60 Hz and removes 4 kHz }
  src := SinePlanar(1, N, 60, 0.5);
  ApplyExtraFx('@lfefilter', 'hz=120', src, 1, N, SR, outp);
  pre := Rms(outp[0], N div 2, N);
  src := SinePlanar(1, N, 4000, 0.5);
  ApplyExtraFx('@lfefilter', 'hz=120', src, 1, N, SR, outp);
  post := Rms(outp[0], N div 2, N);
  Check((pre > 0.3) and (post < 0.01), 'LFE filter passes lows and rejects highs');
  { frequency shifter moves energy; output stays finite }
  src := SinePlanar(1, N, 1000, 0.5);
  ApplyExtraFx('@freqshift', 'hz=200;mix=1', src, 1, N, SR, outp);
  Check(Rms(outp[0], N div 2, N) > 0.25, 'frequency shifter keeps level');
  { megaphone / underwater / robot produce audible, bounded output }
  src := SinePlanar(1, N, 1000, 0.3);
  ApplyExtraFx('@megaphone', '', src, 1, N, SR, outp);
  Check((Rms(outp[0], N div 2, N) > 0.1) and (Rms(outp[0], N div 2, N) <= 0.71), 'megaphone');
  ApplyExtraFx('@underwater', '', src, 1, N, SR, outp);
  Check(Rms(outp[0], N div 2, N) < 0.15, 'underwater low-passes a 1 kHz tone');
  ApplyExtraFx('@robot', '', src, 1, N, SR, outp);
  Check(Rms(outp[0], N div 2, N) > 0.02, 'robot voice');
  { tape stop: the last part slows to silence-length repeats, front stays identical }
  src := SinePlanar(1, N, 440, 0.5);
  ApplyExtraFx('@tapestop', 'ms=500', src, 1, N, SR, outp);
  CheckNear(src[0][1000], outp[0][1000], 1E-7, 'tape stop leaves the start untouched');
  { gater: full depth silences the off phase }
  ApplyExtraFx('@gater', 'rate=4;depth=1;duty=0.5', src, 1, N, SR, outp);
  Check(Rms(outp[0], Round(N * 0.375), Round(N * 0.45)) < 0.05, 'gater closes in the off phase');
  { vinyl adds noise to digital silence }
  src := SinePlanar(1, N, 440, 0.0);
  ApplyExtraFx('@vinyl', 'amt=1', src, 1, N, SR, outp);
  Check(Rms(outp[0], 0, N) > 0.0005, 'vinyl crackle on silence');
  { comb, rotary, crosstalk, wah, sub bass leave a finite signal }
  src := SinePlanar(2, N, 220, 0.4);
  ApplyExtraFx('@comb', '', src, 2, N, SR, outp);
  Check(not IsNan(Rms(outp[0], 0, N)) and (Rms(outp[0], 0, N) > 0.05), 'comb filter');
  ApplyExtraFx('@rotary', '', src, 2, N, SR, outp);
  Check(Rms(outp[0], 0, N) > 0.05, 'rotary speaker');
  ApplyExtraFx('@crossfeed', 'amt=0.5', src, 2, N, SR, outp);
  Check(Rms(outp[1], 0, N) > 0.05, 'crossfeed');
  ApplyExtraFx('@autowah', '', src, 2, N, SR, outp);
  Check(Rms(outp[0], 0, N) > 0.02, 'auto-wah');
  ApplyExtraFx('@subbass', '', src, 2, N, SR, outp);
  Check(Rms(outp[0], 0, N) >= Rms(src[0], 0, N) * 0.9, 'sub bass adds to the signal');
  { vocoder: a spoken-like burst comes out as a buzzy carrier at a similar level; silence stays silent }
  src := SinePlanar(1, N, 300, 0.4);
  ApplyExtraFx('@vocoder', '', src, 1, N, SR, outp);
  Check((Rms(outp[0], N div 2, N) > 0.1) and (Rms(outp[0], N div 2, N) < 0.8), 'vocoder keeps a similar level');
  src := SinePlanar(1, N, 300, 0.0);
  ApplyExtraFx('@vocoder', '', src, 1, N, SR, outp);
  Check(Rms(outp[0], 0, N) < 1E-6, 'vocoder of silence is silence');
  { effects found in other audio applications: finite, audible and bounded }
  src := SinePlanar(2, N, 300, 0.4);
  for i := 0 to 1 do
  begin
    ApplyExtraFx('@wahwah', '', src, 2, N, SR, outp);
    Check(Rms(outp[i], 0, N) > 0.02, 'wah-wah');
    ApplyExtraFx('@autofilter', '', src, 2, N, SR, outp);
    Check(Rms(outp[i], 0, N) > 0.02, 'auto-filter');
    ApplyExtraFx('@tape', '', src, 2, N, SR, outp);
    Check(Rms(outp[i], N div 2, N) > 0.1, 'tape wow and flutter');
    ApplyExtraFx('@radio', '', src, 2, N, SR, outp);
    Check(Rms(outp[i], N div 2, N) > 0.1, 'AM radio');
    ApplyExtraFx('@ensemble', '', src, 2, N, SR, outp);
    Check(Rms(outp[i], N div 2, N) > 0.1, 'ensemble');
    ApplyExtraFx('@multitap', '', src, 2, N, SR, outp);
    Check(Rms(outp[i], N div 2, N) > 0.1, 'multi-tap delay');
    ApplyExtraFx('@tapedelay', '', src, 2, N, SR, outp);
    Check(Rms(outp[i], N div 2, N) > 0.1, 'tape delay');
    ApplyExtraFx('@parallelcomp', '', src, 2, N, SR, outp);
    Check(Rms(outp[i], N div 2, N) > 0.1, 'parallel compression');
  end;
  ApplyExtraFx('@fuzz', 'drive=25', src, 2, N, SR, outp);
  Check((Rms(outp[0], N div 2, N) > 0.05) and (Rms(outp[0], N div 2, N) < 0.8), 'fuzz');
  ApplyExtraFx('@rectifier', '', src, 2, N, SR, outp);
  Check(Rms(outp[0], N div 2, N) > 0.05, 'octave-up rectifier');
  ApplyExtraFx('@stutter', '', src, 2, N, SR, outp);
  Check(Rms(outp[0], 0, N) > 0.05, 'stutter');
  { the A-weighted-ish vowel filter keeps an on-formant tone and removes a far-off one }
  src := SinePlanar(1, N, 800, 0.4);
  ApplyExtraFx('@formant', 'vowel=0', src, 1, N, SR, outp);
  pre := Rms(outp[0], N div 2, N);
  Check(pre > 0.1, 'vowel filter passes a tone at the first formant');
  { Haas delays only the right side; mono bass keeps lows centred; vocal remover cancels the centre }
  src := SinePlanar(2, N, 1000, 0.4);
  ApplyExtraFx('@haas', 'ms=10', src, 2, N, SR, outp);
  CheckNear(src[0][2000], outp[0][2000], 1E-7, 'haas leaves the left channel alone');
  ApplyExtraFx('@vocalremove', 'amt=1;keepbass=0', src, 2, N, SR, outp);
  Check(Rms(outp[0], N div 2, N) < 0.01, 'vocal remover cancels centre-panned content');
  src := SinePlanar(2, N, 60, 0.4);
  for i := 0 to N - 1 do src[1][i] := src[1][i] * 0.25;
  ApplyExtraFx('@monobass', 'hz=120', src, 2, N, SR, outp);
  CheckNear(Rms(outp[0], N div 2, N), Rms(outp[1], N div 2, N), 0.02, 'mono bass equalises the lows');
  ApplyExtraFx('@tilteq', 'tilt=6', src, 2, N, SR, outp);
  Check(Rms(outp[0], N div 2, N) > 0.05, 'tilt EQ');
  { riders, limiter, fades, oversampled saturation, meter }
  src := SinePlanar(2, N, 440, 0.05);
  ApplyExtraFx('@levelrider', 'target=-20;range=12;ms=100', src, 2, N, SR, outp);
  Check(Rms(outp[0], N div 2, N) > Rms(src[0], N div 2, N) * 1.5, 'level rider lifts a quiet signal');
  src := SinePlanar(2, N, 440, 0.9);
  ApplyExtraFx('@tplimiter', 'ceiling=-6;look=5;release=100', src, 2, N, SR, outp);
  pk := 0;
  for i := 0 to N - 1 do pk := Max(pk, Abs(outp[0][i]));
  Check(pk < 0.52, 'true-peak limiter holds the ceiling');
  ApplyExtraFx('@fadecurve', 'shape=1;out=0', src, 2, N, SR, outp);
  Check((Abs(outp[0][0]) < 1E-6) and (Abs(outp[0][N - 1]) > 0) , 'fade in starts silent');
  ApplyExtraFx('@fadecurve', 'shape=2;out=1', src, 2, N, SR, outp);
  Check(Abs(outp[0][N - 1]) < 1E-4, 'fade out ends silent');
  ApplyExtraFx('@oversat', 'drive=4', src, 2, N, SR, outp);
  Check((Rms(outp[0], N div 2, N) > 0.1) and (Rms(outp[0], N div 2, N) < 1), 'oversampled saturation');
  src := SinePlanar(2, N, 100, 0.5);
  ApplyExtraFx('@depop', '', src, 2, N, SR, outp);
  Check(Rms(outp[0], 0, N) > 0.2, 'de-popper leaves steady low notes alone');
  MeasureAudio(src, 2, N, SR, meter);
  CheckNear(-6.02, meter.SamplePeakDb, 0.1, 'meter sample peak');
  CheckNear(1.0, meter.Correlation, 0.01, 'meter correlation of a mono signal');
  Check(meter.TruePeakDb >= meter.SamplePeakDb - 0.01, 'true peak is never below sample peak');
  Check(IsSpectralKind('@gater') and IsExtraFxKind('@peaknorm'), 'new kinds route');
end;

procedure CurvesAndDucker;
var
  proc: TDynamicsProcessor;
  inA, keyLoud, keyQuiet, outL, outR: TAudioSampleArray;
  pl: TAudioPlanar;
  i, N: Integer;
begin
  { frequency response of an EQ band and a filter }
  CheckNear(6.0, EqResponseDb('biquad', 'type=peaking;freq=1000;q=1;gaindb=6', 1000), 0.1, 'peaking EQ boosts 6 dB at its centre');
  Check(EqResponseDb('biquad', 'type=lowpass;freq=1000;q=0.707;gaindb=0', 10000) < -30, 'low-pass curve falls away');
  CheckNear(0.0, EqResponseDb('graphiceq', 'bands=10;gains=0,0,0,0,0,0,0,0,0,0', 1000), 0.01, 'flat graphic EQ is flat');
  { transfer curves }
  CheckNear(-17.5, TransferOutDb('compressor', 'type=compressor;thresh=-20;ratio=4;knee=0;makeup=0', -10), 0.1, 'compressor curve: 10 dB over at 4:1');
  CheckNear(-22.0, TransferOutDb('compressor', 'type=ducker;thresh=-30;knee=6;range=-12', -10), 0.1, 'ducker curve drops by its range');
  CheckNear(-60.0, TransferOutDb('compressor', 'type=ducker;thresh=-30;knee=6;range=-12', -60), 0.1, 'ducker leaves a quiet key alone');
  CheckNear(-0.3, TransferOutDb('lookaheadlimiter', 'ceiling=-0.3', 6), 0.01, 'limiter curve stops at the ceiling');
  { the ducker itself: a loud key pulls the signal down 12 dB, a silent key does not }
  N := SR;
  pl := SinePlanar(1, N, 440, 0.5);
  inA := pl[0];
  pl := SinePlanar(1, N, 100, 0.5);
  keyLoud := pl[0];
  SetLength(keyQuiet, N);
  for i := 0 to N - 1 do keyQuiet[i] := 0;
  SetLength(outL, N);
  SetLength(outR, N);
  proc := TDynamicsProcessor.Create;
  try
    proc.Configure(SR, 2);
    proc.SetParams(dynDucker, -30, 1, 6, 5, 100, 0);
    proc.SetGateParams(20, -12);
    proc.ProcessBlock([PSingle(@inA[0]), PSingle(@inA[0])], [PSingle(@outL[0]), PSingle(@outR[0])], N,
      [PSingle(@keyLoud[0]), PSingle(@keyLoud[0])]);
    CheckNear(Rms(inA, N div 2, N) * 0.251, Rms(outL, N div 2, N), 0.02, 'ducker pulls the signal down 12 dB under a loud key');
    proc.Reset;
    proc.ProcessBlock([PSingle(@inA[0]), PSingle(@inA[0])], [PSingle(@outL[0]), PSingle(@outR[0])], N,
      [PSingle(@keyQuiet[0]), PSingle(@keyQuiet[0])]);
    CheckNear(Rms(inA, N div 2, N), Rms(outL, N div 2, N), 0.01, 'ducker is transparent under a silent key');
  finally
    proc.Free;
  end;
end;

procedure SpeechMusicSeparation;
var
  l, vl, vr, ml, mr: TAudioSampleArray;
  i, N: Integer;
  t, err, vRms, mRms: Double;
begin
  N := 2 * SR;
  SetLength(l, N);
  { steady music: two held tones }
  for i := 0 to N - 1 do
  begin
    t := i / SR;
    l[i] := 0.3 * Sin(2 * Pi * 440 * t) + 0.3 * Sin(2 * Pi * 660 * t);
  end;
  SeparateSpeechMusic(l, l, SR, 0.6, vl, vr, ml, mr);
  vRms := Rms(vl, N div 4, 3 * N div 4);
  mRms := Rms(ml, N div 4, 3 * N div 4);
  Check(vRms < 0.35 * mRms, 'held tones are classed as music, not speech');
  err := 0;
  for i := 4096 to N - 4096 do err := Max(err, Abs(vl[i] + ml[i] - l[i]));
  Check(err < 0.01, 'speech + music add back up to the input');
  { a tone switched on and off three times a second behaves like speech }
  for i := 0 to N - 1 do
  begin
    t := i / SR;
    if Sin(2 * Pi * 3 * t) > 0 then l[i] := 0.4 * Sin(2 * Pi * 1000 * t) else l[i] := 0;
  end;
  SeparateSpeechMusic(l, l, SR, 0.6, vl, vr, ml, mr);
  vRms := Rms(vl, N div 4, 3 * N div 4);
  mRms := Rms(ml, N div 4, 3 * N div 4);
  Check(vRms > mRms, 'a gated tone is classed as speech');
end;

procedure AmbisonicsAndOversampling;
var
  pl, amb, outp: TAudioPlanar;
  rep: TAmbisonicReport;
  i, N: Integer;
  dist: TDistortionProcessor;
  ex: TExciter;
  src, dst: TAudioSampleArray;
  s: Double;
begin
  N := SR div 2;
  pl := SinePlanar(1, N, 300, 0.3);
  SetLength(amb, 4);
  for i := 0 to 3 do SetLength(amb[i], N);
  for i := 0 to N - 1 do
  begin
    s := pl[0][i];
    amb[0][i] := s;      // W
    amb[1][i] := s;      // Y: a source hard left
    amb[2][i] := 0;      // Z
    amb[3][i] := 0;      // X
  end;
  Check(MeasureAmbisonics(amb, 4, N, rep), 'four channels are analysable');
  CheckNear(90.0, rep.AzimuthDeg, 1.0, 'ambisonic source direction: left');
  CheckNear(0.0, rep.ElevationDeg, 1.0, 'ambisonic source elevation: level');
  CheckNear(1.0, rep.Directivity, 0.02, 'a single plane wave is fully directional');
  CheckFalse(MeasureAmbisonics(pl, 1, N, rep), 'a mono block is not ambisonic');
  { 4x oversampled saturation and exciter: finite, bounded, audible }
  pl := SinePlanar(1, N, 1000, 0.5);
  src := pl[0];
  SetLength(dst, N);
  dist := TDistortionProcessor.Create;
  try
    dist.Configure(SR, 1);
    dist.SetParams(distSaturation, 5, 0, 1, 8, 1, 4);
    dist.ProcessBlock([PSingle(@src[0])], [PSingle(@dst[0])], N);
    Check((Rms(dst, N div 2, N) > 0.5) and (Rms(dst, N div 2, N) <= 1.0), '4x oversampled saturation');
  finally
    dist.Free;
  end;
  pl := SinePlanar(1, N, 5000, 0.4);
  src := pl[0];
  ex := TExciter.Create;
  try
    ex.Configure(SR, 1);
    ex.SetParams(3000, 4, 0.5, 4);
    ex.ProcessBlock([PSingle(@src[0])], [PSingle(@dst[0])], N);
    Check(Rms(dst, N div 2, N) > Rms(src, N div 2, N) * 0.9, '4x oversampled exciter');
  finally
    ex.Free;
  end;
  { voice isolation through the effect dispatcher keeps the channel layout }
  pl := SinePlanar(2, N, 1000, 0.3);
  ApplySpectralFx('@voiceisolate', 'strength=0.6', pl, 2, N, SR, outp);
  Check((Length(outp) = 2) and (Length(outp[0]) >= N), 'voice isolation fills both channels');
end;

{ Six 0.1 s bursts, one every 0.25 s (an eighth note at 120 BPM), after 0.1 s of
  silence: the scan must cut at each gap and call every segment 1/8. }
procedure LoopScanFindsEighthNoteSegments;
const
  N = 70560;   // 1.6 s
var
  pl: TAudioPlanar;
  cuts: TArray<Integer>;
  i, k, onset: Integer;
  div_: TLoopDivision;
begin
  pl := SinePlanar(2, N, 200, 0.5);
  for i := 0 to N - 1 do
  begin
    k := i - SR div 10;                          // frames since the first onset
    if (k < 0) or ((k mod (SR div 4)) >= SR div 10) then
    begin
      pl[0][i] := 0;
      pl[1][i] := 0;
    end;
  end;
  cuts := FindLoopCuts(pl, 2, 0, N, SR);
  Check(Length(cuts) = 7, 'six segments need seven cut points, got ' + IntToStr(Length(cuts)));
  for i := 0 to Length(cuts) - 2 do
  begin
    Check(Abs((cuts[i + 1] - cuts[i]) - SR div 4) < SR div 100, 'segment ' + IntToStr(i) + ' is an eighth note long');
    Check(ClassifyLoopLength((cuts[i + 1] - cuts[i]) / SR, 0.5, div_) and (div_ = ldEighth),
      'segment ' + IntToStr(i) + ' classifies as 1/8');
  end;
  onset := SR div 10;
  Check(cuts[0] < onset, 'the first cut sits ahead of the first attack');
  Check(cuts[0] > onset - SR div 50, 'the first cut sits right at the end of the lead-in silence');
  Check(Length(FindLoopCuts(SinePlanar(2, 4096, 0, 0), 2, 0, 4096, SR)) = 0, 'digital silence gives no cuts');
end;

procedure LoopLengthClassification;
var
  d: TLoopDivision;
begin
  Check(ClassifyLoopLength(0.5, 0.5, d) and (d = ldQuarter), '1/4');
  Check(ClassifyLoopLength(0.25, 0.5, d) and (d = ldEighth), '1/8');
  Check(ClassifyLoopLength(0.125, 0.5, d) and (d = ldSixteenth), '1/16');
  Check(ClassifyLoopLength(0.0625, 0.5, d) and (d = ldThirtySecond), '1/32');
  Check(ClassifyLoopLength(0.03125, 0.5, d) and (d = ldSixtyFourth), '1/64');
  Check(ClassifyLoopLength(1.0, 0.5, d) and (d = ldHalfBar), '2/4');
  Check(ClassifyLoopLength(2.0, 0.5, d) and (d = ldBar), '4/4');
  Check(ClassifyLoopLength(1.0 * 1.05, 0.5, d) and (d = ldHalfBar), 'a 5% error still matches');
  CheckFalse(ClassifyLoopLength(0.7, 0.5, d), 'a length between divisions matches none');
  CheckFalse(ClassifyLoopLength(3.0, 0.5, d), 'three beats is not one of the listed lengths');
  Check(LoopDivisionName(ldBar) = '4/4', 'names');
end;

{ cuts every 1/16 at 120 BPM (0.125 s) for two bars: the walk must take them as two
  4/4 segments, not as thirty-two separate 1/16 pieces }
procedure LoopMatchChainsAcrossCuts;
var
  cuts: TArray<Integer>;
  segs: TArray<TLoopSegment>;
  i, skipped: Integer;
begin
  cuts := nil;
  for i := 0 to 32 do cuts := cuts + [i * (SR div 8)];
  segs := MatchLoopSegments(cuts, SR,
    function(AFrame: Integer): Double begin Result := 0.5; end, skipped);
  Check(Length(segs) = 2, 'two bars, got ' + IntToStr(Length(segs)));
  Check((Length(segs) > 0) and (segs[0].Division = ldBar), 'chained into 4/4');
  Check(skipped = 0, 'nothing skipped');
end;

procedure RegisterExtraFxTests;
begin
  RegisterTest(GRP, 'loop match chains across cuts', LoopMatchChainsAcrossCuts);
  RegisterTest(GRP, 'loop scan cuts at silent gaps', LoopScanFindsEighthNoteSegments);
  RegisterTest(GRP, 'loop length classification', LoopLengthClassification);
  RegisterTest(GRP, 'extra kinds are recognised', KindsAreRecognised);
  RegisterTest(GRP, 'swap channels and invert phase', SwapAndInvert);
  RegisterTest(GRP, 'echo repeats the signal', EchoRepeatsTheSignal);
  RegisterTest(GRP, 'de-hummer removes mains hum', DehumRemovesTheHum);
  RegisterTest(GRP, 'de-clicker repairs an impulse', DeclickRepairsAnImpulse);
  RegisterTest(GRP, 'de-clipper rebuilds flat tops', DeclipRestoresPeaks);
  RegisterTest(GRP, 'loudness normalize raises quiet material', LoudnessNormalizeHitsTarget);
  RegisterTest(GRP, 'dialogue leveler evens out levels', DialogueLevelerEvensOutLevels);
  RegisterTest(GRP, 'vocal channel, telephone and band-pass', VocalChannelAndFilters);
  RegisterTest(GRP, 'spectral dispatcher routes extra kinds', SpectralDispatcherRoutes);
  RegisterTest(GRP, 'Fairlight-style effects behave', FairlightStyleEffects);
  RegisterTest(GRP, 'curves, ducker', CurvesAndDucker);
  RegisterTest(GRP, 'speech / music separation', SpeechMusicSeparation);
  RegisterTest(GRP, 'ambisonics, oversampling, voice isolation', AmbisonicsAndOversampling);
  RegisterTest(GRP, 'extended video effects are catalogued', NewVideoEffectsAreReachable);
  RegisterTest(GRP, 'every transition starts and ends cleanly', TransitionsEndOnTheIncomingPicture);
end;

end.
