unit Tests.Phase39;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 39 - competitive-gap features: delay, dither, spectral tools (denoise,
  stems, convolution, auto-tune), synth + sampler, step sequencer / arpeggiator
  / metronome, audio-to-MIDI, warp markers, the modulator system and the
  CLAP/VST3 host's failure handling. Everything here is offline DSP checked
  against signals whose correct answer is known (sine tones, deltas, noise). }

interface

procedure RegisterPhase39Tests;

implementation

uses
  SysUtils, Math, Classes,
  UDAW.Testing, UDAW.Audio.Types,
  UDAW.DSP.Delay, UDAW.DSP.Dither, UDAW.DSP.Spectral, UDAW.DSP.AudioToMidi,
  UDAW.Sequencer.Patterns, UDAW.Synth.Instruments,
  UDAW.Timeline.Warp, UDAW.Timeline.SpectralFx,
  UDAW.Mixer.Automation, UDAW.Mixer.Modulation,
  UDAW.Mixer.CLAP, UDAW.Mixer.VST3;

const
  GRP = 'phase39.competitive_gap';
  SR = 44100;

function Tone(AHz: Double; AFrames: Integer; AAmp: Double = 0.5): TAudioSampleArray;
var
  i: Integer;
begin
  SetLength(Result, AFrames);
  for i := 0 to AFrames - 1 do
    Result[i] := Single(AAmp * Sin(2.0 * Pi * AHz * i / SR));
end;

function Rms(const A: array of Single; AFrom, ATo: Integer): Double;
var
  i: Integer;
begin
  Result := 0;
  if ATo <= AFrom then Exit;
  for i := AFrom to ATo - 1 do Result := Result + Sqr(A[i]);
  Result := Sqrt(Result / (ATo - AFrom));
end;

{ ---------------- delay ---------------- }

procedure Test_Delay_EchoArrivesAtSetTime;
var
  d: TDelay;
  inL, inR, outL, outR: TAudioSampleArray;
  pin, pout: array of PSingle;
  i, at: Integer;
begin
  d := TDelay.Create;
  try
    d.Configure(SR, 2);
    d.SetParams(100.0, 0.0, 1.0, 20000.0, False);
    SetLength(inL, 8000); SetLength(inR, 8000);
    SetLength(outL, 8000); SetLength(outR, 8000);
    inL[0] := 1.0; inR[0] := 1.0;
    SetLength(pin, 2); SetLength(pout, 2);
    pin[0] := @inL[0]; pin[1] := @inR[0];
    pout[0] := @outL[0]; pout[1] := @outR[0];
    d.ProcessBlock(pin, pout, 8000);
    at := Round(0.1 * SR);
    Check(Abs(outL[at]) > 0.2, 'delay: echo present at 100 ms');
    for i := 100 to at - 100 do
      if Abs(outL[i]) > 0.01 then
      begin
        Check(False, 'delay: silence before the echo');
        Break;
      end;
  finally
    d.Free;
  end;
end;

{ ---------------- dither ---------------- }

procedure Test_Dither_QuantisesToGridWithinOneLsb;
var
  dz: TDitherer;
  buf: array[0..1023] of Single;
  i: Integer;
  maxErr, scale: Double;
  orig: array[0..1023] of Single;
begin
  dz := TDitherer.Create(16, dsTPDF);
  try
    for i := 0 to 1023 do
    begin
      buf[i] := Single(0.3 * Sin(i * 0.05));
      orig[i] := buf[i];
    end;
    dz.Process(@buf[0], 1024, 0);
    scale := 32768.0;
    maxErr := 0;
    for i := 0 to 1023 do
    begin
      maxErr := Max(maxErr, Abs(buf[i] - orig[i]) * scale);
      CheckNear(Round(buf[i] * scale), buf[i] * scale, 0.01, 'dither: on the 16-bit grid');
    end;
    Check(maxErr <= 2.01, 'dither: error within 2 LSB');
  finally
    dz.Free;
  end;
end;

{ ---------------- patterns ---------------- }

procedure Test_Patterns_EuclideanArpAndMetronome;
var
  sp: TStepPattern;
  arp: TArpeggiator;
  met: TMetronome;
  notes: TSeqNotes;
begin
  sp := TStepPattern.Create(16);
  try
    sp.Euclidean(4, 0);
    notes := sp.Render(1);
    CheckEqualInt(4, Length(notes), 'euclid: 4 pulses in 16 steps');
    CheckNear(0.0, notes[0].Beat, 1e-9, 'euclid: first hit on step 0');
    CheckNear(1.0, notes[1].Beat, 1e-9, 'euclid: even spacing (every 4 steps = 1 beat)');
  finally
    sp.Free;
  end;
  arp := TArpeggiator.Create;
  try
    arp.Mode := amUp;
    notes := arp.Render([60, 64, 67], 100, 0, 1.0);
    CheckEqualInt(4, Length(notes), 'arp: 1 beat at 1/16 = 4 notes');
    CheckEqualInt(60, notes[0].Key, 'arp up: starts lowest');
    CheckEqualInt(64, notes[1].Key, 'arp up: second is middle');
    arp.Mode := amDown;
    notes := arp.Render([60, 64, 67], 100, 0, 1.0);
    CheckEqualInt(67, notes[0].Key, 'arp down: starts highest');
    arp.Mode := amUp;
    arp.Octaves := 2;
    notes := arp.Render([60], 100, 0, 0.5);
    CheckEqualInt(72, notes[1].Key, 'arp octave range adds +12');
  finally
    arp.Free;
  end;
  met := TMetronome.Create;
  try
    met.CountInBars := 1;
    notes := met.Render(4);
    CheckEqualInt(8, Length(notes), 'metronome: 4 beats + 1 bar count-in');
    CheckNear(-4.0, notes[0].Beat, 1e-9, 'metronome: count-in starts negative');
    CheckEqualInt(76, notes[0].Key, 'metronome: downbeat accent');
    CheckEqualInt(77, notes[1].Key, 'metronome: other beats');
  finally
    met.Free;
  end;
end;

{ ---------------- spectral ---------------- }

procedure Test_Spectral_DenoiseReducesNoiseKeepsTone;
var
  n, i: Integer;
  x: TAudioSampleArray;
  y: TAudioSampleArray;
  seed: Cardinal;
  noiseRmsBefore, noiseRmsAfter, toneRmsAfter: Double;
begin
  n := SR * 2;
  SetLength(x, n);
  seed := 12345;
  for i := 0 to n - 1 do
  begin
    seed := Cardinal((UInt64(seed) * 1664525 + 1013904223) and $FFFFFFFF);
    x[i] := Single(((seed shr 8) / 16777216.0 - 0.5) * 0.1);
    if i > SR then x[i] := x[i] + Single(0.4 * Sin(2 * Pi * 1000 * i / SR));
  end;
  noiseRmsBefore := Rms(x, 1000, SR div 2);
  SpectralDenoise(x, SR, 0, SR div 2, 20.0, y);
  noiseRmsAfter := Rms(y, 1000, SR div 2);
  toneRmsAfter := Rms(y, SR + 5000, n - 5000);
  Check(noiseRmsAfter < noiseRmsBefore * 0.5, 'denoise: noise-only section reduced by at least 6 dB');
  Check(toneRmsAfter > 0.4 * 0.7071 * 0.8, 'denoise: the 1 kHz tone survives');
end;

procedure Test_Spectral_ConvolveWithDeltaIsIdentity;
var
  x, ir, y: TAudioSampleArray;
  i: Integer;
begin
  x := Tone(440, 6000, 0.5);
  SetLength(ir, 100);
  ir[0] := 1.0;
  ConvolveIR(x, ir, y);
  CheckEqualInt(6000 + 100 - 1, Length(y), 'convolve: output length');
  for i := 0 to 5999 do
    if Abs(y[i] - x[i]) > 1e-3 then
    begin
      Check(False, 'convolve: delta IR reproduces the input');
      Exit;
    end;
end;

procedure Test_Spectral_StemsSumBackToInput;
var
  n, i: Integer;
  l, r: TAudioSampleArray;
  st: TStemSet;
  maxErr: Double;
begin
  n := SR;
  l := Tone(220, n, 0.3);
  r := Tone(220, n, 0.3);
  for i := 0 to n - 1 do
  begin
    if (i mod 11025) < 300 then
    begin
      l[i] := l[i] + 0.4;
      r[i] := r[i] - 0.4;
    end;
  end;
  SplitStems(l, r, SR, st);
  maxErr := 0;
  for i := 4096 to n - 4096 do
    maxErr := Max(maxErr, Abs(st.Drums[0][i] + st.Bass[0][i] + st.Vocals[0][i] + st.Other[0][i] - l[i]));
  Check(maxErr < 0.02, 'stems: the four stems add back to the source');
end;

procedure Test_Spectral_AutoTunePullsToScale;
var
  x, y: TAudioSampleArray;
  pc: TPitchCorrector;
  hz: Double;
  zc, i, a, b: Integer;
begin
  { 452 Hz is ~ +0.46 semitone above A4; chromatic snap should land near 440 }
  x := Tone(452, SR * 2, 0.5);
  pc := TPitchCorrector.Create;
  try
    pc.SetChromatic;
    pc.Process(x, SR, y);
  finally
    pc.Free;
  end;
  a := SR div 2;
  b := SR + SR div 2;
  zc := 0;
  for i := a + 1 to b do
    if (y[i - 1] < 0) and (y[i] >= 0) then Inc(zc);
  hz := zc / ((b - a) / SR);
  Check(Abs(hz - 440.0) < 6.0, Format('autotune: corrected to ~440 Hz (got %.1f)', [hz]));
end;

procedure Test_SpectralFx_ScaleTextParsing;
var
  pc: TPitchCorrector;
begin
  pc := TPitchCorrector.Create;
  try
    Check(ParseScaleText('C major', pc), 'scale text: C major parses');
    Check(pc.ScaleMask[0] and pc.ScaleMask[4] and not pc.ScaleMask[1], 'scale text: C major mask');
    Check(ParseScaleText('A minor', pc), 'scale text: A minor parses');
    Check(pc.ScaleMask[9] and pc.ScaleMask[0] and not pc.ScaleMask[1], 'scale text: A minor mask');
    CheckFalse(ParseScaleText('nonsense', pc), 'scale text: garbage rejected');
  finally
    pc.Free;
  end;
end;

{ ---------------- synth / sampler ---------------- }

procedure Test_Synth_RendersNoteAtRequestedPitch;
var
  syn: TSubtractiveSynth;
  notes: TSeqNotes;
  l, r: TAudioSampleArray;
  i, zc, a, b: Integer;
  hz: Double;
begin
  syn := TSubtractiveSynth.Create(SR);
  try
    syn.Patch := TSynthPatch.Default;
    syn.Patch.CutoffHz := 8000;
    syn.Patch.FilterEnvAmount := 0;
    syn.Patch.Osc2Detune := 0;   { a detuned 2nd oscillator makes zero-crossing counts meaningless }
    SetLength(notes, 1);
    notes[0].Beat := 0; notes[0].Length := 2.0; notes[0].Key := 69; notes[0].Velocity := 110;
    syn.Render(notes, 120, 0.2, l, r);
    Check(Rms(l, SR div 4, SR div 2) > 0.01, 'synth: audible output');
    a := SR div 4;
    b := SR div 4 + SR div 2;
    zc := 0;
    for i := a + 1 to b do
      if (l[i - 1] < 0) and (l[i] >= 0) then Inc(zc);
    hz := zc / ((b - a) / SR);
    Check(Abs(hz - 440.0) < 12.0, Format('synth: A4 near 440 Hz (got %.1f)', [hz]));
  finally
    syn.Free;
  end;
end;

procedure Test_Sampler_TransposesByRatio;
var
  smp: TSampler;
  notes: TSeqNotes;
  l, r: TAudioSampleArray;
  i, zc, a, b: Integer;
  hz: Double;
begin
  smp := TSampler.Create(SR);
  try
    smp.Data := Tone(440, SR * 2, 0.5);
    smp.RootKey := 69;
    SetLength(notes, 1);
    notes[0].Beat := 0; notes[0].Length := 2.0; notes[0].Key := 81; notes[0].Velocity := 127;
    smp.Render(notes, 120, 0.1, l, r);
    a := 2000;
    b := 2000 + SR div 2;
    zc := 0;
    for i := a + 1 to b do
      if (l[i - 1] < 0) and (l[i] >= 0) then Inc(zc);
    hz := zc / ((b - a) / SR);
    Check(Abs(hz - 880.0) < 15.0, Format('sampler: +12 semitones doubles pitch (got %.1f)', [hz]));
  finally
    smp.Free;
  end;
end;

{ ---------------- audio to MIDI ---------------- }

procedure Test_AudioToMidi_MonoSineBecomesNote;
var
  x: TAudioSampleArray;
  opts: TA2MOptions;
  notes: TSeqNotes;
begin
  x := Tone(440, SR, 0.5);
  opts := TA2MOptions.Default;
  notes := AudioToMidi(x, SR, opts);
  Check(Length(notes) >= 1, 'audio-to-midi: at least one note');
  CheckEqualInt(69, notes[0].Key, 'audio-to-midi: 440 Hz is MIDI 69');
  Check(notes[0].Length > 1.0, 'audio-to-midi: sustained over the second (at 120 BPM ~2 beats)');
end;

procedure Test_AudioToMidi_PolyDetectsTwoNotes;
var
  a, b, x: TAudioSampleArray;
  i: Integer;
  opts: TA2MOptions;
  notes: TSeqNotes;
  has60, has67: Boolean;
begin
  a := Tone(261.63, SR, 0.3);
  b := Tone(392.0, SR, 0.3);
  SetLength(x, SR);
  for i := 0 to SR - 1 do x[i] := a[i] + b[i];
  opts := TA2MOptions.Default;
  opts.Mode := a2mPoly;
  notes := AudioToMidi(x, SR, opts);
  has60 := False;
  has67 := False;
  for i := 0 to High(notes) do
  begin
    if notes[i].Key = 60 then has60 := True;
    if notes[i].Key = 67 then has67 := True;
  end;
  Check(has60 and has67, 'audio-to-midi poly: C4 and G4 both found');
end;

{ ---------------- warp ---------------- }

procedure Test_Warp_NormalizeAndRenderKeepsLength;
var
  m: TWarpMarkers;
  inp, outp: TAudioPlanar;
  n, outFrames: Integer;
begin
  m := nil;
  AddWarpMarker(m, 1.0, 1.1);
  AddWarpMarker(m, 0.5, 0.55);
  AddWarpMarker(m, 0.51, 0.6);   { too close to the previous one: dropped }
  NormalizeWarpMarkers(m);
  CheckEqualInt(2, Length(m), 'warp: sorted and crowded marker dropped');
  CheckNear(0.5, m[0].SrcSec, 1e-9, 'warp: sorted by source time');
  n := SR * 3;
  SetLength(inp, 1);
  inp[0] := Tone(300, n, 0.5);
  RenderWarp(inp, 1, n, SR, m, outp, outFrames);
  CheckEqualInt(n, outFrames, 'warp: rendered length equals the input length');
  Check(Rms(outp[0], SR, SR * 2) > 0.2, 'warp: audio present after warping');
end;

procedure Test_Warp_AutoWarpSnapsOnsetsToBeats;
var
  onsets: TArray<Double>;
  m: TWarpMarkers;
begin
  SetLength(onsets, 2);
  onsets[0] := 0.53;   { near beat 1 at 120 BPM = 0.5 s }
  onsets[1] := 1.02;   { near beat 2 = 1.0 s }
  m := AutoWarpMarkers(onsets, 120, 0.0);
  CheckEqualInt(2, Length(m), 'auto-warp: both onsets pinned');
  CheckNear(0.5, m[0].DstSec, 1e-9, 'auto-warp: onset 1 pinned to the beat');
  CheckNear(1.0, m[1].DstSec, 1e-9, 'auto-warp: onset 2 pinned to the beat');
end;

{ ---------------- modulation ---------------- }

procedure Test_Modulation_LfoRangeAndRoute;
var
  ms: TModulationSet;
  m: TModulator;
  r: TModRoute;
  v, lo, hi: Double;
  i: Integer;
begin
  ms := TModulationSet.Create;
  try
    m := ms.AddModulator(mkLfo, 'LFO 1');
    m.RateHz := 2.0;
    r.ModIndex := 0; r.StripId := 7; r.Param := apFader;
    r.TargetIndex := 0; r.SubIndex := 0; r.Amount := 3.0; r.Base := 0.5;
    ms.AddRoute(r);
    lo := 1e9; hi := -1e9;
    for i := 0 to 999 do
    begin
      v := ms.Offset(7, apFader, 0, 0, i * 0.001);
      lo := Min(lo, v);
      hi := Max(hi, v);
    end;
    Check((hi <= 3.0001) and (lo >= -3.0001), 'modulation: LFO stays within +-amount');
    Check(hi - lo > 5.0, 'modulation: LFO actually swings');
    CheckNear(0.0, ms.Offset(8, apFader, 0, 0, 0.1), 1e-12, 'modulation: other strips unaffected');
  finally
    ms.Free;
  end;
end;

procedure Test_Modulation_SerializeRoundTrip;
var
  a, b: TModulationSet;
  m: TModulator;
  r: TModRoute;
  lines: TStringList;
  i: Integer;
begin
  a := TModulationSet.Create;
  b := TModulationSet.Create;
  lines := TStringList.Create;
  try
    m := a.AddModulator(mkSteps, 'Steps 1');
    m.RateHz := 4; m.StepCount := 4;
    m.Steps[0] := 1; m.Steps[1] := -0.5; m.Steps[2] := 0.25; m.Steps[3] := 0;
    r.ModIndex := 0; r.StripId := 3; r.Param := apPan; r.TargetIndex := 0;
    r.SubIndex := 0; r.Amount := 0.75; r.Base := 0.5;
    a.AddRoute(r);
    a.Serialize(lines);
    for i := 0 to lines.Count - 1 do
      Check(b.TryParseLine(lines[i]), 'modulation: line parses: ' + lines[i]);
    CheckEqualInt(1, b.ModCount, 'modulation: modulator restored');
    CheckEqualInt(1, b.RouteCount, 'modulation: route restored');
    CheckNear(-0.5, b.GetMod(0).Steps[1], 1e-9, 'modulation: step values restored');
    CheckNear(a.Offset(3, apPan, 0, 0, 0.3), b.Offset(3, apPan, 0, 0, 0.3), 1e-9,
      'modulation: identical output after reload');
  finally
    lines.Free;
    b.Free;
    a.Free;
  end;
end;

procedure Test_Modulation_RemoveModulatorRewritesRoutes;
var
  ms: TModulationSet;
  r: TModRoute;
begin
  ms := TModulationSet.Create;
  try
    ms.AddModulator(mkMacro, 'A');
    ms.AddModulator(mkMacro, 'B');
    r.ModIndex := 1; r.StripId := 1; r.Param := apFader; r.TargetIndex := 0;
    r.SubIndex := 0; r.Amount := 1; r.Base := 0.5;
    ms.AddRoute(r);
    ms.RemoveModulator(0);
    CheckEqualInt(1, ms.RouteCount, 'modulation: route survives removal of an earlier modulator');
    CheckEqualInt(0, ms.GetRoute(0).ModIndex, 'modulation: route index shifted down');
  finally
    ms.Free;
  end;
end;

{ ---------------- plugin hosts ---------------- }

procedure Test_PluginHosts_RejectMissingModules;
var
  c: TCLAPHost;
  v: TVST3Host;
  raised: Boolean;
begin
  c := TCLAPHost.Create;
  try
    raised := False;
    try
      c.LoadOnly('Z:\definitely\missing\plugin.clap');
    except
      on ECLAPError do raised := True;
    end;
    Check(raised, 'CLAP: a missing module raises ECLAPError, no crash');
    CheckFalse(c.IsLoaded, 'CLAP: nothing loaded after failure');
  finally
    c.Free;
  end;
  v := TVST3Host.Create;
  try
    raised := False;
    try
      v.LoadOnly('Z:\definitely\missing\plugin.vst3');
    except
      on EVST3Error do raised := True;
    end;
    Check(raised, 'VST3: a missing module raises EVST3Error, no crash');
    CheckFalse(v.IsLoaded, 'VST3: nothing loaded after failure');
  finally
    v.Free;
  end;
end;

procedure RegisterPhase39Tests;
begin
  RegisterTest(GRP, 'Delay: echo arrives at the set time', Test_Delay_EchoArrivesAtSetTime);
  RegisterTest(GRP, 'Dither: output sits on the 16-bit grid within 2 LSB', Test_Dither_QuantisesToGridWithinOneLsb);
  RegisterTest(GRP, 'Patterns: Euclidean, arpeggiator and metronome', Test_Patterns_EuclideanArpAndMetronome);
  RegisterTest(GRP, 'Spectral: denoise cuts noise, keeps the tone', Test_Spectral_DenoiseReducesNoiseKeepsTone);
  RegisterTest(GRP, 'Spectral: convolution with a delta is the identity', Test_Spectral_ConvolveWithDeltaIsIdentity);
  RegisterTest(GRP, 'Spectral: the four stems sum back to the source', Test_Spectral_StemsSumBackToInput);
  RegisterTest(GRP, 'Spectral: auto-tune pulls 452 Hz to 440 Hz', Test_Spectral_AutoTunePullsToScale);
  RegisterTest(GRP, 'Spectral: scale text parsing', Test_SpectralFx_ScaleTextParsing);
  RegisterTest(GRP, 'Synth: A4 renders near 440 Hz', Test_Synth_RendersNoteAtRequestedPitch);
  RegisterTest(GRP, 'Sampler: +12 semitones doubles the pitch', Test_Sampler_TransposesByRatio);
  RegisterTest(GRP, 'Audio to MIDI: a mono sine becomes MIDI 69', Test_AudioToMidi_MonoSineBecomesNote);
  RegisterTest(GRP, 'Audio to MIDI: poly finds a C4+G4 dyad', Test_AudioToMidi_PolyDetectsTwoNotes);
  RegisterTest(GRP, 'Warp: markers normalise and render keeps the length', Test_Warp_NormalizeAndRenderKeepsLength);
  RegisterTest(GRP, 'Warp: auto-warp pins onsets to beats', Test_Warp_AutoWarpSnapsOnsetsToBeats);
  RegisterTest(GRP, 'Modulation: LFO range and routing', Test_Modulation_LfoRangeAndRoute);
  RegisterTest(GRP, 'Modulation: serialise/parse round trip', Test_Modulation_SerializeRoundTrip);
  RegisterTest(GRP, 'Modulation: removing a modulator rewrites route indices', Test_Modulation_RemoveModulatorRewritesRoutes);
  RegisterTest(GRP, 'Plugin hosts: missing CLAP/VST3 modules fail cleanly', Test_PluginHosts_RejectMissingModules);
end;

end.
