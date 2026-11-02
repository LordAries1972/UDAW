unit Tests.Phase10;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 10 acceptance tests: the core DSP effect suite.

  Covers the five new processors (dynamics: compressor / limiter / gate /
  expander / de-esser; modulation: tremolo / auto-pan / chorus / phaser;
  distortion: saturation / hard-clip / bit-crush; algorithmic reverb; graphic
  EQ), their graph-node wrappers and text-param round-trips, integration
  through a compiled audio graph, and the mixer insert host including external
  sidechain routing.

  Requires src/common, src/audio, src/audio/dsp, src/audio/graph, src/timeline,
  src/project and src/mixer on the search path. }

interface

procedure RegisterPhase10Tests;

implementation

uses
  SysUtils, Math,
  UDAW.Testing,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Source, UDAW.Audio.Offline,
  UDAW.Audio.Graph, UDAW.Audio.Graph.Nodes, UDAW.Audio.Graph.Serializer,
  UDAW.DSP.Dynamics, UDAW.DSP.Modulation, UDAW.DSP.Distortion,
  UDAW.DSP.Reverb, UDAW.DSP.GraphicEQ,
  UDAW.Mixer.Model, UDAW.Mixer.Engine;

const
  SR = 48000;

{ ---- signal helpers ---- }

function MakeSine(AFreq, AAmp: Double; AFrames, AChannels: Integer): TAudioPlanar;
var
  ch, i: Integer;
begin
  SetLength(Result, AChannels);
  for ch := 0 to AChannels - 1 do
  begin
    SetLength(Result[ch], AFrames);
    for i := 0 to AFrames - 1 do
      Result[ch][i] := Single(AAmp * Sin(2 * Pi * AFreq * i / SR));
  end;
end;

function MakeDC(AValue: Double; AFrames, AChannels: Integer): TAudioPlanar;
var
  ch, i: Integer;
begin
  SetLength(Result, AChannels);
  for ch := 0 to AChannels - 1 do
  begin
    SetLength(Result[ch], AFrames);
    for i := 0 to AFrames - 1 do
      Result[ch][i] := Single(AValue);
  end;
end;

function ClonePlanar(const A: TAudioPlanar): TAudioPlanar;
var
  ch: Integer;
begin
  SetLength(Result, Length(A));
  for ch := 0 to High(A) do
    Result[ch] := Copy(A[ch]);
end;

function Ptrs(const A: TAudioPlanar): TArray<PSingle>;
var
  ch: Integer;
begin
  SetLength(Result, Length(A));
  for ch := 0 to High(A) do
    Result[ch] := @A[ch][0];
end;

function RmsOf(const A: TAudioPlanar; ACh, AFrom, ATo: Integer): Double;
var
  i: Integer;
  acc: Double;
begin
  acc := 0;
  for i := AFrom to ATo - 1 do
    acc := acc + Sqr(Double(A[ACh][i]));
  if ATo - AFrom <= 0 then Exit(0);
  Result := Sqrt(acc / (ATo - AFrom));
end;

function PeakOf(const A: TAudioPlanar; ACh, AFrom, ATo: Integer): Double;
var
  i: Integer;
  m: Double;
begin
  m := 0;
  for i := AFrom to ATo - 1 do
    if Abs(Double(A[ACh][i])) > m then m := Abs(Double(A[ACh][i]));
  Result := m;
end;

function MaxAbsDiff(const A, B: TAudioPlanar; ACh: Integer): Double;
var
  i, n: Integer;
  m, d: Double;
begin
  m := 0;
  n := Min(Length(A[ACh]), Length(B[ACh]));
  for i := 0 to n - 1 do
  begin
    d := Abs(Double(A[ACh][i]) - Double(B[ACh][i]));
    if d > m then m := d;
  end;
  Result := m;
end;

{ largest |L-R| difference across a stereo planar buffer }
function MaxAbsDiffCh(const A: TAudioPlanar): Double;
var
  i, n: Integer;
  m, d: Double;
begin
  m := 0;
  if Length(A) < 2 then Exit(0);
  n := Min(Length(A[0]), Length(A[1]));
  for i := 0 to n - 1 do
  begin
    d := Abs(Double(A[0][i]) - Double(A[1][i]));
    if d > m then m := d;
  end;
  Result := m;
end;

function AllFinite(const A: TAudioPlanar): Boolean;
var
  ch, i: Integer;
  v: Single;
begin
  for ch := 0 to High(A) do
    for i := 0 to High(A[ch]) do
    begin
      v := A[ch][i];
      if IsNan(v) or IsInfinite(v) then Exit(False);
    end;
  Result := True;
end;

{ ================= dynamics ================= }

procedure Test_Dyn_CompressorReducesLoudPassesQuiet;
var
  d: TDynamicsProcessor;
  loud, quiet, o: TAudioPlanar;
  n: Integer;
begin
  n := SR div 2;
  d := TDynamicsProcessor.Create;
  try
    d.Configure(SR, 1);
    d.SetParams(dynCompressor, -24.0, 4.0, 3.0, 5.0, 80.0, 0.0);

    loud := MakeSine(200, 0.5, n, 1);       // ~ -6 dBFS, well above -24
    o := ClonePlanar(loud);
    d.Reset;
    d.ProcessBlock(Ptrs(loud), Ptrs(o), n, []);
    Check(PeakOf(o, 0, n div 2, n) < PeakOf(loud, 0, n div 2, n) * 0.85,
      'a loud sine above threshold is compressed');
    Check(d.CurrentGainReductionDb > 1.0, 'gain reduction is reported');

    quiet := MakeSine(200, 0.02, n, 1);     // ~ -34 dBFS, below -24
    o := ClonePlanar(quiet);
    d.Reset;
    d.ProcessBlock(Ptrs(quiet), Ptrs(o), n, []);
    CheckNear(PeakOf(quiet, 0, n div 2, n), PeakOf(o, 0, n div 2, n), 1.0E-3,
      'a quiet sine below threshold passes through');
  finally
    d.Free;
  end;
end;

procedure Test_Dyn_LimiterCeiling;
var
  d: TDynamicsProcessor;
  sig, o: TAudioPlanar;
  n: Integer;
  ceilingLin: Double;
begin
  n := SR div 2;
  d := TDynamicsProcessor.Create;
  try
    d.Configure(SR, 1);
    d.SetParams(dynLimiter, -6.0, 60.0, 1.0, 1.0, 50.0, 0.0);
    sig := MakeSine(300, 0.95, n, 1);
    o := ClonePlanar(sig);
    d.Reset;
    d.ProcessBlock(Ptrs(sig), Ptrs(o), n, []);
    ceilingLin := DbToLinear(-6.0);
    Check(PeakOf(o, 0, n div 2, n) < ceilingLin * 1.35,
      'limiter holds the signal near its -6 dB ceiling');
  finally
    d.Free;
  end;
end;

procedure Test_Dyn_GateClosesOnQuietTail;
var
  d: TDynamicsProcessor;
  sig, o: TAudioPlanar;
  n, i, half: Integer;
begin
  n := SR;                       // 1 s: loud first half, quiet second half
  half := n div 2;
  d := TDynamicsProcessor.Create;
  try
    d.Configure(SR, 1);
    d.SetParams(dynGate, -30.0, 4.0, 2.0, 1.0, 40.0, 0.0);
    d.SetGateParams(10.0, -50.0);
    sig := MakeSine(220, 0.4, n, 1);
    for i := half to n - 1 do
      sig[0][i] := sig[0][i] * 0.003;      // -50 dB tail
    o := ClonePlanar(sig);
    d.Reset;
    d.ProcessBlock(Ptrs(sig), Ptrs(o), n, []);
    Check(RmsOf(o, 0, 1000, half - 1000) > 0.2, 'gate stays open on the loud part');
    Check(RmsOf(o, 0, half + SR div 5, n) < RmsOf(sig, 0, half + SR div 5, n) * 0.5,
      'gate attenuates the quiet tail below the threshold');
  finally
    d.Free;
  end;
end;

procedure Test_Dyn_ExpanderPullsDownLowLevel;
var
  d: TDynamicsProcessor;
  hi, lo, oHi, oLo: TAudioPlanar;
  n: Integer;
  grHi, grLo: Double;
begin
  n := SR div 2;
  d := TDynamicsProcessor.Create;
  try
    d.Configure(SR, 1);
    d.SetParams(dynExpander, -24.0, 3.0, 2.0, 5.0, 100.0, 0.0);
    d.SetGateParams(0.0, -40.0);

    hi := MakeSine(200, 0.3, n, 1);         // above threshold
    oHi := ClonePlanar(hi);
    d.Reset;
    d.ProcessBlock(Ptrs(hi), Ptrs(oHi), n, []);
    grHi := PeakOf(hi, 0, n div 2, n) / Max(1.0E-9, PeakOf(oHi, 0, n div 2, n));

    lo := MakeSine(200, 0.03, n, 1);        // below threshold
    oLo := ClonePlanar(lo);
    d.Reset;
    d.ProcessBlock(Ptrs(lo), Ptrs(oLo), n, []);
    grLo := PeakOf(lo, 0, n div 2, n) / Max(1.0E-9, PeakOf(oLo, 0, n div 2, n));

    Check(grLo > grHi * 2.0, 'the expander attenuates the low-level signal much more');
  finally
    d.Free;
  end;
end;

procedure Test_Dyn_DeEsserTargetsHighs;
var
  d: TDynamicsProcessor;
  hiF, loF, o: TAudioPlanar;
  n: Integer;
  grHigh, grLow: Double;
begin
  n := SR div 2;
  d := TDynamicsProcessor.Create;
  try
    d.Configure(SR, 1);
    d.SetParams(dynDeEsser, -30.0, 6.0, 3.0, 2.0, 60.0, 0.0);
    d.SetDeEsserFreq(6000.0);

    hiF := MakeSine(8000, 0.4, n, 1);
    o := ClonePlanar(hiF);
    d.Reset;
    d.ProcessBlock(Ptrs(hiF), Ptrs(o), n, []);
    grHigh := PeakOf(hiF, 0, n div 2, n) / Max(1.0E-9, PeakOf(o, 0, n div 2, n));

    loF := MakeSine(200, 0.4, n, 1);
    o := ClonePlanar(loF);
    d.Reset;
    d.ProcessBlock(Ptrs(loF), Ptrs(o), n, []);
    grLow := PeakOf(loF, 0, n div 2, n) / Max(1.0E-9, PeakOf(o, 0, n div 2, n));

    Check(grHigh > 1.3, 'de-esser ducks a loud sibilant tone');
    Check(grHigh > grLow * 2.0, 'de-esser barely touches an equally loud low tone');
  finally
    d.Free;
  end;
end;

procedure Test_Dyn_MakeupAddsLevel;
var
  d: TDynamicsProcessor;
  sig, o0, o6: TAudioPlanar;
  n: Integer;
begin
  n := SR div 4;
  d := TDynamicsProcessor.Create;
  try
    d.Configure(SR, 1);
    sig := MakeSine(200, 0.05, n, 1);       // below threshold, no compression

    d.SetParams(dynCompressor, -12.0, 4.0, 0.0, 5.0, 80.0, 0.0);
    o0 := ClonePlanar(sig); d.Reset;
    d.ProcessBlock(Ptrs(sig), Ptrs(o0), n, []);

    d.SetParams(dynCompressor, -12.0, 4.0, 0.0, 5.0, 80.0, 6.0206);
    o6 := ClonePlanar(sig); d.Reset;
    d.ProcessBlock(Ptrs(sig), Ptrs(o6), n, []);

    CheckNear(2.0, PeakOf(o6, 0, 0, n) / Max(1.0E-9, PeakOf(o0, 0, 0, n)), 0.05,
      '+6 dB makeup doubles the output level');
  finally
    d.Free;
  end;
end;

{ ================= modulation ================= }

procedure Test_Mod_TremoloModulatesAmplitude;
var
  m: TModulationProcessor;
  sig, o: TAudioPlanar;
  n, i, w: Integer;
  minR, maxR, r: Double;
begin
  n := SR;
  m := TModulationProcessor.Create;
  try
    m.Configure(SR, 1);
    m.SetParams(modTremolo, 8.0, 1.0, 1.0, 0.0, 4, 0.0);
    sig := MakeDC(0.5, n, 1);
    o := ClonePlanar(sig);
    m.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    minR := 1.0E9; maxR := 0;
    i := SR div 4;
    while i < n - SR div 20 do
    begin
      r := 0;
      for w := 0 to (SR div 200) - 1 do r := r + Abs(o[0][i + w]);
      r := r / (SR div 200);
      if r < minR then minR := r;
      if r > maxR then maxR := r;
      Inc(i, SR div 100);
    end;
    Check(minR < 0.08, 'tremolo dips near silence at full depth');
    Check(maxR > 0.42, 'tremolo returns to near full level');
  finally
    m.Free;
  end;
end;

procedure Test_Mod_AutoPanAntiPhase;
var
  m: TModulationProcessor;
  sig, o: TAudioPlanar;
  n, i: Integer;
  sawLhigh, sawRhigh: Boolean;
begin
  n := SR;
  m := TModulationProcessor.Create;
  try
    m.Configure(SR, 2);
    m.SetParams(modAutoPan, 4.0, 0.9, 1.0, 0.0, 4, 0.0);
    sig := MakeDC(0.5, n, 2);
    o := ClonePlanar(sig);
    m.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    sawLhigh := False;
    sawRhigh := False;
    for i := SR div 4 to n - 1 do
    begin
      if (Abs(o[0][i]) > 0.45) and (Abs(o[1][i]) < 0.2) then sawLhigh := True;
      if (Abs(o[1][i]) > 0.45) and (Abs(o[0][i]) < 0.2) then sawRhigh := True;
    end;
    Check(sawLhigh and sawRhigh, 'auto-pan sweeps the image left and right in anti-phase');
  finally
    m.Free;
  end;
end;

procedure Test_Mod_ChorusColoursButKeepsLevel;
var
  m: TModulationProcessor;
  sig, o: TAudioPlanar;
  n: Integer;
  ri, ro: Double;
begin
  n := SR;
  m := TModulationProcessor.Create;
  try
    m.Configure(SR, 2);
    m.SetParams(modChorus, 0.8, 0.7, 0.5, 0.0, 4, 90.0);
    sig := MakeSine(440, 0.4, n, 2);
    o := ClonePlanar(sig);
    m.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    ri := RmsOf(sig, 0, SR div 4, n);
    ro := RmsOf(o, 0, SR div 4, n);
    Check(AllFinite(o), 'chorus output is finite');
    Check(MaxAbsDiff(sig, o, 0) > 0.05, 'chorus changes the signal');
    Check((ro > ri * 0.5) and (ro < ri * 1.6), 'chorus keeps the level in the same ballpark');
  finally
    m.Free;
  end;
end;

procedure Test_Mod_PhaserStable;
var
  m: TModulationProcessor;
  sig, o: TAudioPlanar;
  n: Integer;
begin
  n := SR;
  m := TModulationProcessor.Create;
  try
    m.Configure(SR, 2);
    m.SetParams(modPhaser, 0.5, 0.9, 0.6, 0.7, 6, 0.0);
    sig := MakeSine(300, 0.5, n, 2);
    o := ClonePlanar(sig);
    m.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    Check(AllFinite(o), 'phaser with heavy feedback stays finite');
    Check(PeakOf(o, 0, 0, n) < 4.0, 'phaser output is bounded');
    Check(MaxAbsDiff(sig, o, 0) > 0.02, 'phaser alters the signal');
  finally
    m.Free;
  end;
end;

{ ================= distortion ================= }

procedure Test_Dist_SaturationBoundedAndNonLinear;
var
  p: TDistortionProcessor;
  sig, o, scaled: TAudioPlanar;
  n, i: Integer;
begin
  n := SR div 4;
  p := TDistortionProcessor.Create;
  try
    p.Configure(SR, 1);
    p.SetParams(distSaturation, 4.0, 0.0, 1.0, 8.0, 1);
    sig := MakeSine(220, 0.9, n, 1);
    o := ClonePlanar(sig);
    p.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    Check(PeakOf(o, 0, 0, n) <= 1.0001, 'tanh saturation cannot exceed full scale');
    scaled := ClonePlanar(sig);
    for i := 0 to n - 1 do scaled[0][i] := scaled[0][i] * 4.0;
    Check(MaxAbsDiff(o, scaled, 0) > 0.2, 'saturation is not just a linear gain');
  finally
    p.Free;
  end;
end;

procedure Test_Dist_HardClip;
var
  p: TDistortionProcessor;
  sig, o: TAudioPlanar;
  n, i, atCeil: Integer;
begin
  n := SR div 4;
  p := TDistortionProcessor.Create;
  try
    p.Configure(SR, 1);
    p.SetParams(distHardClip, 4.0, 0.0, 1.0, 8.0, 1);
    sig := MakeSine(220, 0.5, n, 1);
    o := ClonePlanar(sig);
    p.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    CheckNear(1.0, PeakOf(o, 0, 0, n), 1.0E-4, 'hard clip pins peaks at +/-1');
    atCeil := 0;
    for i := 0 to n - 1 do
      if Abs(o[0][i]) >= 0.999 then Inc(atCeil);
    Check(atCeil > n div 4, 'a large fraction of samples are clipped');
  finally
    p.Free;
  end;
end;

procedure Test_Dist_BitCrushQuantises;
var
  p: TDistortionProcessor;
  sig, o: TAudioPlanar;
  n, i, distinct: Integer;
  seen: array of Double;
  found: Boolean;
  j: Integer;
begin
  n := 4096;
  p := TDistortionProcessor.Create;
  try
    p.Configure(SR, 1);
    p.SetParams(distBitCrush, 1.0, 0.0, 1.0, 3.0, 1);   // 3 bits -> 8 levels
    sig := MakeSine(30, 0.95, n, 1);
    o := ClonePlanar(sig);
    p.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    SetLength(seen, 0);
    distinct := 0;
    for i := 0 to n - 1 do
    begin
      found := False;
      for j := 0 to High(seen) do
        if Abs(seen[j] - o[0][i]) < 1.0E-5 then begin found := True; Break; end;
      if not found then
      begin
        SetLength(seen, Length(seen) + 1);
        seen[High(seen)] := o[0][i];
        Inc(distinct);
      end;
    end;
    Check(distinct <= 10, '3-bit crush yields only a handful of output levels');
  finally
    p.Free;
  end;
end;

procedure Test_Dist_BitCrushDownsampleHolds;
var
  p: TDistortionProcessor;
  sig, o: TAudioPlanar;
  n, i, blk: Integer;
  ok: Boolean;
begin
  n := 2048;
  blk := 4;
  p := TDistortionProcessor.Create;
  try
    p.Configure(SR, 1);
    p.SetParams(distBitCrush, 1.0, 0.0, 1.0, 16.0, blk);
    sig := MakeSine(60, 0.8, n, 1);
    o := ClonePlanar(sig);
    p.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    ok := True;
    for i := 0 to n - 1 do
      if (i mod blk <> 0) and (Abs(o[0][i] - o[0][i - (i mod blk)]) > 1.0E-6) then
        ok := False;
    Check(ok, 'sample-rate reduction holds each value for the downsample factor');
  finally
    p.Free;
  end;
end;

procedure Test_Dist_DryMix;
var
  p: TDistortionProcessor;
  sig, o: TAudioPlanar;
  n: Integer;
begin
  n := SR div 8;
  p := TDistortionProcessor.Create;
  try
    p.Configure(SR, 1);
    p.SetParams(distHardClip, 10.0, 0.0, 0.0, 8.0, 1);   // mix=0 -> fully dry
    sig := MakeSine(220, 0.9, n, 1);
    o := ClonePlanar(sig);
    p.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    Check(MaxAbsDiff(sig, o, 0) < 1.0E-5, 'mix=0 is a clean bypass');
  finally
    p.Free;
  end;
end;

{ ================= reverb ================= }

procedure Test_Reverb_TailAndDecay;
var
  r: TAlgoReverb;
  sig, o: TAudioPlanar;
  n: Integer;
  e100, e300: Double;
begin
  n := SR;             // 1 s: impulse at 0, silence after
  r := TAlgoReverb.Create;
  try
    r.Configure(SR);
    r.SetParams(0.85, 0.3, 1.0, 1.0, 5.0, 0.5, 0.9);   // 100% wet
    sig := MakeDC(0.0, n, 2);
    sig[0][0] := 1.0; sig[1][0] := 1.0;
    o := ClonePlanar(sig);
    r.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    Check(AllFinite(o), 'reverb output is finite');
    e100 := RmsOf(o, 0, Round(0.08 * SR), Round(0.12 * SR));
    e300 := RmsOf(o, 0, Round(0.45 * SR), Round(0.50 * SR));
    Check(e100 > 1.0E-4, 'there is a reverb tail long after the impulse');
    Check(e300 < e100, 'the tail decays over time');
  finally
    r.Free;
  end;
end;

procedure Test_Reverb_StereoDecorrelation;
var
  r: TAlgoReverb;
  sig, o: TAudioPlanar;
  n: Integer;
begin
  n := SR div 2;
  r := TAlgoReverb.Create;
  try
    r.Configure(SR);
    r.SetParams(0.8, 0.3, 1.0, 1.0, 5.0, 0.5, 0.9);
    sig := MakeDC(0.0, n, 2);
    sig[0][0] := 1.0; sig[1][0] := 1.0;      // identical mono impulse
    o := ClonePlanar(sig);
    r.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    Check(MaxAbsDiffCh(o) > 1.0E-3, 'left and right reverb tails are decorrelated');
  finally
    r.Free;
  end;
end;

procedure Test_Reverb_DryMixAndStability;
var
  r: TAlgoReverb;
  sig, o: TAudioPlanar;
  n: Integer;
  i, ch: Integer;
begin
  n := 2 * SR;
  r := TAlgoReverb.Create;
  try
    r.Configure(SR);

    { mix = 0 -> passthrough }
    r.SetParams(0.9, 0.2, 1.0, 0.0, 10.0, 0.5, 0.9);
    sig := MakeSine(440, 0.3, SR div 4, 2);
    o := ClonePlanar(sig);
    r.ProcessBlock(Ptrs(sig), Ptrs(o), SR div 4);
    Check(MaxAbsDiff(sig, o, 0) < 1.0E-5, 'reverb mix=0 is a clean bypass');

    { long noise burst stays bounded }
    r.Reset;
    r.SetParams(0.98, 0.1, 1.0, 0.5, 10.0, 0.6, 0.95);
    SetLength(sig, 2);
    for ch := 0 to 1 do
    begin
      SetLength(sig[ch], n);
      for i := 0 to n - 1 do
        sig[ch][i] := Single(0.3 * Sin(i * 0.7 + ch));
    end;
    o := ClonePlanar(sig);
    r.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    Check(AllFinite(o), 'reverb stays finite over 2 s of dense input');
    Check(PeakOf(o, 0, 0, n) < 4.0, 'reverb output stays bounded');
  finally
    r.Free;
  end;
end;

{ ================= graphic EQ ================= }

procedure Test_GEQ_BandBoost;
var
  g: TGraphicEQ;
  s1k, s8k, o: TAudioPlanar;
  n: Integer;
begin
  n := SR div 2;
  g := TGraphicEQ.Create;
  try
    g.SetBandCount(10);
    g.Configure(SR, 1);
    g.SetBandGain(5, 12.0);                 // band 5 = 1 kHz on the ISO grid

    s1k := MakeSine(1000, 0.2, n, 1);
    o := ClonePlanar(s1k);
    g.Reset;
    g.ProcessBlock(Ptrs(s1k), Ptrs(o), n);
    Check(RmsOf(o, 0, n div 2, n) > RmsOf(s1k, 0, n div 2, n) * 1.8,
      'a +12 dB band boost lifts a tone at that centre frequency');

    s8k := MakeSine(8000, 0.2, n, 1);
    o := ClonePlanar(s8k);
    g.Reset;
    g.ProcessBlock(Ptrs(s8k), Ptrs(o), n);
    CheckNear(RmsOf(s8k, 0, n div 2, n), RmsOf(o, 0, n div 2, n),
      RmsOf(s8k, 0, n div 2, n) * 0.15, 'a distant band is barely affected');
  finally
    g.Free;
  end;
end;

procedure Test_GEQ_FlatIsTransparent;
var
  g: TGraphicEQ;
  sig, o: TAudioPlanar;
  n: Integer;
begin
  n := SR div 2;
  g := TGraphicEQ.Create;
  try
    g.SetBandCount(10);
    g.Configure(SR, 1);
    Check(g.BandCount = 10, 'ten bands');
    CheckNear(1000.0, g.BandFreq(5), 1.0, 'band 5 centre is 1 kHz');
    sig := MakeSine(500, 0.3, n, 1);
    o := ClonePlanar(sig);
    g.ProcessBlock(Ptrs(sig), Ptrs(o), n);
    CheckNear(RmsOf(sig, 0, n div 2, n), RmsOf(o, 0, n div 2, n),
      RmsOf(sig, 0, n div 2, n) * 0.03, 'a flat graphic EQ passes the signal');
  finally
    g.Free;
  end;
end;

{ ================= graph-node wrappers ================= }

procedure ParamRoundTrip(AKind: TNodeKind; const AParams: string);
var
  a, b: TAudioNode;
  s1, s2: string;
begin
  a := CreateNode(1, AKind, 'a');
  b := CreateNode(2, AKind, 'b');
  try
    a.DeserializeParams(AParams);
    a.Configure(SR, 480, 2);
    s1 := a.SerializeParams;
    b.DeserializeParams(s1);
    b.Configure(SR, 480, 2);
    s2 := b.SerializeParams;
    CheckEqualStr(s1, s2, NodeKindId(AKind) + ' params round-trip');
  finally
    a.Free;
    b.Free;
  end;
end;

procedure Test_Nodes_ParamRoundTrips;
begin
  ParamRoundTrip(nkCompressor, 'type=limiter;thresh=-8;ratio=20;knee=2;attack=1;release=60;makeup=3;hold=5;range=-40;scfreq=7000');
  ParamRoundTrip(nkModulation, 'type=flanger;rate=0.25;depth=0.8;mix=0.4;fb=0.5;stages=6;stereo=120');
  ParamRoundTrip(nkDistortion, 'type=bitcrush;drive=1.5;trim=-2;mix=0.75;bits=6;down=8');
  ParamRoundTrip(nkReverb, 'size=0.9;damp=0.2;width=0.8;mix=0.35;predelay=25;early=0.6;tail=0.85');
  ParamRoundTrip(nkGraphicEQ, 'bands=10;gains=0,0,3,0,-2,4,0,0,-1,0');
end;

procedure Test_Nodes_CompressorInGraph;
var
  g: TAudioGraph;
  src, comp, outp: TAudioNode;
  ref, comped: TOfflineResult;
begin
  g := TAudioGraph.Create(2);
  try
    src := g.AddNode(nkSource, 'osc');
    TGraphSourceNode(src).SetTone(osSine, 220, 0.9);
    comp := g.AddNode(nkCompressor, 'comp');
    comp.DeserializeParams('type=compressor;thresh=-30;ratio=8;knee=2;attack=2;release=60;makeup=0');
    outp := g.AddNode(nkOutput, 'out');
    g.Connect(src.Id, comp.Id);
    g.Connect(comp.Id, outp.Id);
    Check(g.Compile, 'graph with a compressor compiles: ' + g.LastError);
    comped := RenderSourceOffline(g.AsSource, SR, 2, SR div 2);

    comp.Bypass := True;
    g.Compile;
    ref := RenderSourceOffline(g.AsSource, SR, 2, SR div 2);

    { measure the settled tail, past the compressor's attack transient }
    Check(PeakOf(comped.Planar, 0, (SR div 2) div 2, SR div 2) <
          PeakOf(ref.Planar, 0, (SR div 2) div 2, SR div 2) * 0.8,
      'the compressor node reduces the peak of a loud source through the compiled graph');
  finally
    g.Free;
  end;
end;

procedure Test_Nodes_GraphSerializerRoundTrip;
var
  g, back: TAudioGraph;
  txt: string;
begin
  g := TAudioGraph.Create(2);
  try
    g.AddNode(nkSource, 'osc');
    g.AddNode(nkDistortion, 'drive').DeserializeParams('type=foldback;drive=3;mix=1');
    g.AddNode(nkReverb, 'verb').DeserializeParams('size=0.8;mix=0.4');
    g.AddNode(nkOutput, 'out');
    g.Connect(1, 2); g.Connect(2, 3); g.Connect(3, 4);
    txt := GraphToString(g);
  finally
    g.Free;
  end;
  back := GraphFromString(txt);
  try
    CheckEqualInt(4, back.NodeCount, 'all nodes survive the graph text round-trip');
    Check(Pos('distortion', GraphToString(back)) > 0, 'the distortion node is preserved');
    Check(Pos('reverb', GraphToString(back)) > 0, 'the reverb node is preserved');
  finally
    back.Free;
  end;
end;

{ ================= mixer integration ================= }

type
  TDualToneProvider = class(TInterfacedObject, IMixInputProvider)
  private
    FIds: array of Integer;
    FFreq, FAmp: array of Double;
  public
    procedure SetStrip(AId: Integer; AFreq, AAmp: Double);
    procedure SetAmp(AId: Integer; AAmp: Double);
    procedure RenderStripInput(AStripId: Integer; ABuffer: TAudioBuffer);
  end;

procedure TDualToneProvider.SetStrip(AId: Integer; AFreq, AAmp: Double);
begin
  SetLength(FIds, Length(FIds) + 1);
  SetLength(FFreq, Length(FFreq) + 1);
  SetLength(FAmp, Length(FAmp) + 1);
  FIds[High(FIds)] := AId; FFreq[High(FFreq)] := AFreq; FAmp[High(FAmp)] := AAmp;
end;

procedure TDualToneProvider.SetAmp(AId: Integer; AAmp: Double);
var
  i: Integer;
begin
  for i := 0 to High(FIds) do
    if FIds[i] = AId then FAmp[i] := AAmp;
end;

procedure TDualToneProvider.RenderStripInput(AStripId: Integer; ABuffer: TAudioBuffer);
var
  i, ch, n, idx: Integer;
  ph: Double;
  p: PSingle;
begin
  idx := -1;
  for i := 0 to High(FIds) do if FIds[i] = AStripId then idx := i;
  if idx < 0 then Exit;
  n := ABuffer.FrameCount;
  for ch := 0 to ABuffer.ChannelCount - 1 do
  begin
    p := PSingle(ABuffer.ChannelPtr(ch));
    for i := 0 to n - 1 do
    begin
      ph := 2 * Pi * FFreq[idx] * (ABuffer.StreamPosition + i) / SR;
      p[i] := Single(FAmp[idx] * Sin(ph));
    end;
  end;
end;

function MasterRms(AModel: TMixerModel; AProv: IMixInputProvider): Double;
var
  proc: TMixerProcessor;
  planar: TAudioPlanar;
begin
  proc := TMixerProcessor.Create(AModel);
  try
    proc.SetInputProvider(AProv);
    proc.Prepare(SR, 480, 2);
    planar := proc.RenderToPlanar(SR div 2);
    Result := 0;
    if (Length(planar) > 0) and (Length(planar[0]) > 0) then
    begin
      Result := RmsOf(planar, 0, Length(planar[0]) shr 1, Length(planar[0]));
    end;
  finally
    proc.Free;
  end;
end;

procedure Test_Mix_DistortionInsertChangesOutput;
var
  m: TMixerModel;
  trk: TMixStrip;
  prov: IMixInputProvider;
  p: TDualToneProvider;
  dry, wet: Double;
begin
  m := TMixerModel.Create;
  try
    m.InitDefault;
    trk := m.AddStrip(skAudioTrack, 'T');
    p := TDualToneProvider.Create;
    p.SetStrip(trk.Id, 300, 0.5);
    prov := p;
    dry := MasterRms(m, prov);
    trk.AddInsert(TMixInsert.Make('distortion', 'type=hardclip;drive=6;mix=1'));
    wet := MasterRms(m, prov);
    Check(Abs(wet - dry) > 0.01, 'a distortion insert audibly changes the strip output');
  finally
    m.Free;
  end;
end;

procedure Test_Mix_ExternalSidechainDucks;
var
  m: TMixerModel;
  keyStrip, victim: TMixStrip;
  p: TDualToneProvider;
  prov: IMixInputProvider;
  loudKey, quietKey: Double;
  ins: TMixInsert;
begin
  m := TMixerModel.Create;
  try
    m.InitDefault;
    keyStrip := m.AddStrip(skAudioTrack, 'Key');
    victim := m.AddStrip(skAudioTrack, 'Bass');
    p := TDualToneProvider.Create;
    p.SetStrip(keyStrip.Id, 1000, 0.6);
    p.SetStrip(victim.Id, 120, 0.4);
    prov := p;

    ins := TMixInsert.Make('compressor',
      'type=compressor;thresh=-30;ratio=10;knee=2;attack=2;release=80;makeup=0',
      False, keyStrip.Id);
    victim.AddInsert(ins);
    { silence the key strip's own contribution to the mix so we measure the bass }
    keyStrip.FaderDb := -120;

    loudKey := MasterRms(m, prov);
    p.SetAmp(keyStrip.Id, 0.0);
    quietKey := MasterRms(m, prov);

    Check(quietKey > loudKey * 1.3,
      'a loud external sidechain key ducks the compressed strip');
  finally
    m.Free;
  end;
end;

{ ---------------- registration ---------------- }

procedure RegisterPhase10Tests;
begin
  RegisterTest('dsp.dynamics', 'compressor: loud vs quiet',      @Test_Dyn_CompressorReducesLoudPassesQuiet);
  RegisterTest('dsp.dynamics', 'limiter ceiling',                @Test_Dyn_LimiterCeiling);
  RegisterTest('dsp.dynamics', 'gate closes quiet tail',         @Test_Dyn_GateClosesOnQuietTail);
  RegisterTest('dsp.dynamics', 'expander pulls down low level',  @Test_Dyn_ExpanderPullsDownLowLevel);
  RegisterTest('dsp.dynamics', 'de-esser targets highs',         @Test_Dyn_DeEsserTargetsHighs);
  RegisterTest('dsp.dynamics', 'makeup gain',                    @Test_Dyn_MakeupAddsLevel);

  RegisterTest('dsp.modulation', 'tremolo modulates amplitude',  @Test_Mod_TremoloModulatesAmplitude);
  RegisterTest('dsp.modulation', 'auto-pan anti-phase',          @Test_Mod_AutoPanAntiPhase);
  RegisterTest('dsp.modulation', 'chorus colours, keeps level',  @Test_Mod_ChorusColoursButKeepsLevel);
  RegisterTest('dsp.modulation', 'phaser stays stable',          @Test_Mod_PhaserStable);

  RegisterTest('dsp.distortion', 'saturation bounded + nonlinear', @Test_Dist_SaturationBoundedAndNonLinear);
  RegisterTest('dsp.distortion', 'hard clip',                    @Test_Dist_HardClip);
  RegisterTest('dsp.distortion', 'bit-crush quantises',          @Test_Dist_BitCrushQuantises);
  RegisterTest('dsp.distortion', 'bit-crush downsample holds',   @Test_Dist_BitCrushDownsampleHolds);
  RegisterTest('dsp.distortion', 'mix=0 bypass',                 @Test_Dist_DryMix);

  RegisterTest('dsp.reverb', 'tail + decay',                     @Test_Reverb_TailAndDecay);
  RegisterTest('dsp.reverb', 'stereo decorrelation',             @Test_Reverb_StereoDecorrelation);
  RegisterTest('dsp.reverb', 'dry mix + stability',              @Test_Reverb_DryMixAndStability);

  RegisterTest('dsp.graphiceq', 'band boost',                    @Test_GEQ_BandBoost);
  RegisterTest('dsp.graphiceq', 'flat is transparent',           @Test_GEQ_FlatIsTransparent);

  RegisterTest('dsp.nodes', 'effect param round-trips',          @Test_Nodes_ParamRoundTrips);
  RegisterTest('dsp.nodes', 'compressor node in a graph',        @Test_Nodes_CompressorInGraph);
  RegisterTest('dsp.nodes', 'graph serializer keeps new kinds',  @Test_Nodes_GraphSerializerRoundTrip);

  RegisterTest('dsp.mixer', 'distortion insert changes output',  @Test_Mix_DistortionInsertChangesOutput);
  RegisterTest('dsp.mixer', 'external sidechain ducks',          @Test_Mix_ExternalSidechainDucks);
end;

end.
