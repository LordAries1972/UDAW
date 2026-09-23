unit Tests.Phase4;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 4 acceptance tests: the master audio graph.

  Covers graph construction and introspection; the full validation surface
  (no / duplicate Output, illegal feedback cycle, connecting into a generator,
  Output with no upstream = missing source, channel mismatch); deterministic
  offline rendering through gain / summing / bypass+mute / biquad / delay /
  meter-tap nodes built on the Phase 3 DSP; the versioned text serializer
  (round-trip + version rejection); the IAudioSource adapter that plays a
  graph through the device engine; and the compile / plan-swap / node-retire
  path under repeated recompilation.

  Requires src/common, src/audio, src/audio/dsp and src/audio/graph on the
  search path. }

interface

procedure RegisterPhase4Tests;

implementation

uses
  SysUtils, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Source, UDAW.Audio.Offline,
  UDAW.DSP.Filters,
  UDAW.Audio.Graph.Nodes, UDAW.Audio.Graph, UDAW.Audio.Graph.Serializer;

const
  SR = 48000;

{ ---------------- helpers ---------------- }

function BuildToneGain(out AGraph: TAudioGraph;
  AFreq: Double; AAmp: Single; AGainDb: Double): Integer;
var
  s, gn, o: TAudioNode;
begin
  AGraph := TAudioGraph.Create(2);
  s := AGraph.AddNode(nkSource, 'Osc');
  TGraphSourceNode(s).SetTone(osSine, AFreq, AAmp);
  gn := AGraph.AddNode(nkGain, 'Trim');
  TGainNode(gn).GainDb := AGainDb;
  o := AGraph.AddNode(nkOutput, 'Master');
  AGraph.Connect(s.Id, gn.Id);
  AGraph.Connect(gn.Id, o.Id);
  Result := gn.Id;
end;

function RenderGraph(AGraph: TAudioGraph; ASeconds: Double): TOfflineResult;
begin
  Result := RenderSourceOffline(AGraph.AsSource, SR, 2,
    Round(ASeconds * SR), 480);
end;

{ ================= construction ================= }

procedure Test_Graph_BuildAndCompile;
var
  g: TAudioGraph;
  err: string;
begin
  BuildToneGain(g, 440, 0.5, 0.0);
  try
    CheckEqualInt(3, g.NodeCount, 'three nodes');
    CheckEqualInt(2, g.ConnectionCount, 'two connections');
    Check(g.Validate(err), 'valid graph: ' + err);
    Check(g.Compile, 'compile succeeds: ' + g.LastError);
    CheckEqualInt(3, g.CompiledStepCount, 'one step per node');
    { source must be ordered before the output }
    Check(g.CompiledStepText(0).Contains('source'), 'source is first step');
    Check(g.CompiledStepText(2).Contains('output'), 'output is last step');
    Check(g.IsCompiled, 'reports compiled');
  finally
    g.Free;
  end;
end;

procedure Test_Graph_Introspection;
var
  g: TAudioGraph;
  n: TAudioNode;
begin
  BuildToneGain(g, 440, 0.5, -3.0);
  try
    n := g.NodeById(2);
    Check(n <> nil, 'node 2 exists');
    CheckEqualStr('gain', NodeKindId(n.Kind), 'node 2 is a gain');
    Check(g.NodeById(999) = nil, 'unknown id -> nil');
    Check(g.Describe.Contains('audio graph:'), 'Describe renders');
  finally
    g.Free;
  end;
end;

{ ================= validation ================= }

procedure Test_Graph_Validate_NoOutput;
var
  g: TAudioGraph;
  err: string;
begin
  g := TAudioGraph.Create(2);
  try
    g.AddNode(nkSource);
    CheckFalse(g.Validate(err), 'no Output node must fail');
    Check(err.ToLower.Contains('output'), 'error names Output: ' + err);
    CheckFalse(g.Compile, 'compile refuses');
  finally
    g.Free;
  end;
end;

procedure Test_Graph_Validate_TwoOutputs;
var
  g: TAudioGraph;
  err: string;
begin
  g := TAudioGraph.Create(2);
  try
    g.AddNode(nkOutput);
    g.AddNode(nkOutput);
    CheckFalse(g.Validate(err), 'two Output nodes must fail');
  finally
    g.Free;
  end;
end;

procedure Test_Graph_Validate_Cycle;
var
  g: TAudioGraph;
  s, a, b, o: TAudioNode;
  err: string;
begin
  g := TAudioGraph.Create(2);
  try
    s := g.AddNode(nkSource);
    a := g.AddNode(nkGain, 'A');
    b := g.AddNode(nkGain, 'B');
    o := g.AddNode(nkOutput);
    g.Connect(s.Id, a.Id);
    g.Connect(a.Id, b.Id);
    g.Connect(b.Id, a.Id);      // illegal feedback
    g.Connect(b.Id, o.Id);
    CheckFalse(g.Validate(err), 'cycle must fail');
    Check(err.ToLower.Contains('cycle'), 'error names the cycle: ' + err);
  finally
    g.Free;
  end;
end;

procedure Test_Graph_Validate_ConnectIntoGenerator;
var
  g: TAudioGraph;
  s, o: TAudioNode;
  raised: Boolean;
begin
  g := TAudioGraph.Create(2);
  try
    s := g.AddNode(nkSource);
    o := g.AddNode(nkOutput);
    raised := False;
    try
      g.Connect(o.Id, s.Id);    // target is a generator - rejected at connect time
    except
      on E: EUDAWError do raised := True;
    end;
    Check(raised, 'connecting into a source raises EUDAWError');
  finally
    g.Free;
  end;
end;

procedure Test_Graph_Validate_MissingSource;
var
  g: TAudioGraph;
  err: string;
begin
  g := TAudioGraph.Create(2);
  try
    g.AddNode(nkSource);
    g.AddNode(nkOutput);        // never connected to anything
    CheckFalse(g.Validate(err), 'Output with no upstream must fail');
    Check(err.ToLower.Contains('missing source'), 'error is a missing source: ' + err);
  finally
    g.Free;
  end;
end;

procedure Test_Graph_Validate_ChannelMismatch;
var
  g: TAudioGraph;
  s, m, o: TAudioNode;
  err: string;
begin
  g := TAudioGraph.Create(1);   // mono graph
  try
    s := g.AddNode(nkSource);
    m := g.AddNode(nkChannelMap, 'Swap');
    TChannelMapNode(m).Mode := cmSwapLR;   // needs a stereo pair
    o := g.AddNode(nkOutput);
    g.Connect(s.Id, m.Id);
    g.Connect(m.Id, o.Id);
    CheckFalse(g.Validate(err), 'swap map in a mono graph must fail');
    Check(err.ToLower.Contains('channel mismatch'), 'names channel mismatch: ' + err);
  finally
    g.Free;
  end;
end;

{ ================= rendering ================= }

procedure Test_Graph_Render_Gain;
var
  g: TAudioGraph;
  r: TOfflineResult;
begin
  BuildToneGain(g, 1000, 0.5, -6.0);       // -6 dB => x0.501187
  try
    r := RenderGraph(g, 0.5);
    CheckNear(0.25059, ChannelPeak(r, 0), 0.01, 'peak = 0.5 * -6 dB');
    CheckNear(0.17720, ChannelRms(r, 0), 0.01, 'rms  = peak / sqrt2');
    CheckNear(1000.0, EstimateFrequency(r, 0), 5.0, 'frequency preserved');
  finally
    g.Free;
  end;
end;

procedure Test_Graph_Render_Sum;
var
  g: TAudioGraph;
  s1, s2, o: TAudioNode;
  r: TOfflineResult;
begin
  g := TAudioGraph.Create(2);
  try
    s1 := g.AddNode(nkSource, 'Lo');
    TGraphSourceNode(s1).SetTone(osSine, 200, 0.3);
    s2 := g.AddNode(nkSource, 'Hi');
    TGraphSourceNode(s2).SetTone(osSine, 900, 0.3);
    o := g.AddNode(nkOutput);
    g.Connect(s1.Id, o.Id);
    g.Connect(s2.Id, o.Id);                 // fan-in is summed
    r := RenderGraph(g, 0.5);
    Check(ChannelPeak(r, 0) > 0.30, 'sum exceeds a single source peak');
    Check(ChannelPeak(r, 0) <= 0.61, 'sum within 0.3 + 0.3');
    Check(ChannelRms(r, 0) > 0.21, 'summed RMS above one source');
  finally
    g.Free;
  end;
end;

procedure Test_Graph_Render_BypassMute;
var
  g: TAudioGraph;
  gainId: Integer;
  r: TOfflineResult;
begin
  gainId := BuildToneGain(g, 1000, 0.5, 0.0);
  try
    TGainNode(g.NodeById(gainId)).Mute := True;
    r := RenderGraph(g, 0.2);
    CheckNear(0.0, ChannelPeak(r, 0), 1e-6, 'muted node => silence');

    TGainNode(g.NodeById(gainId)).Mute := False;
    TGainNode(g.NodeById(gainId)).Bypass := True;
    TGainNode(g.NodeById(gainId)).GainDb := -60;   // ignored while bypassed
    r := RenderGraph(g, 0.2);
    CheckNear(0.5, ChannelPeak(r, 0), 0.02, 'bypassed node passes the signal through');
  finally
    g.Free;
  end;
end;

procedure Test_Graph_Render_Lowpass;
var
  g: TAudioGraph;
  s, f, o: TAudioNode;
  rHi, rLo: TOfflineResult;
begin
  g := TAudioGraph.Create(2);
  try
    s := g.AddNode(nkSource);
    f := g.AddNode(nkBiquad, 'LP');
    TBiquadNode(f).SetFilter(bqLowpass, 500, 0.70710678, 0);
    o := g.AddNode(nkOutput);
    g.Connect(s.Id, f.Id);
    g.Connect(f.Id, o.Id);

    TGraphSourceNode(s).SetTone(osSine, 6000, 0.5);
    rHi := RenderGraph(g, 0.3);
    Check(ChannelPeak(rHi, 0) < 0.06, 'tone well above cutoff is killed');

    TGraphSourceNode(s).SetTone(osSine, 100, 0.5);
    rLo := RenderGraph(g, 0.3);
    Check(ChannelPeak(rLo, 0) > 0.4, 'tone below cutoff passes');
  finally
    g.Free;
  end;
end;

procedure Test_Graph_Render_Delay;
var
  g: TAudioGraph;
  s, d, o: TAudioNode;
  r: TOfflineResult;
  i, dsamp, nonZero: Integer;
begin
  g := TAudioGraph.Create(2);
  try
    s := g.AddNode(nkSource);
    TGraphSourceNode(s).SetTone(osSine, 1000, 0.5);
    d := g.AddNode(nkDelay, 'Slap');
    TDelayNode(d).TimeMs := 20;
    TDelayNode(d).Feedback := 0.0;
    TDelayNode(d).Mix := 1.0;               // 100% wet
    o := g.AddNode(nkOutput);
    g.Connect(s.Id, d.Id);
    g.Connect(d.Id, o.Id);

    r := RenderGraph(g, 0.25);
    dsamp := Round(0.020 * SR);
    nonZero := 0;
    for i := 0 to dsamp - 4 do
      if Abs(r.Planar[0][i]) > 1e-4 then Inc(nonZero);
    CheckEqualInt(0, nonZero, 'output silent until the delay time elapses');
    { a wet-only delayed sine keeps the source amplitude once it is running }
    CheckNear(0.3535, ChannelRms(r, 0), 0.03, 'delayed sine keeps its RMS');
  finally
    g.Free;
  end;
end;

procedure Test_Graph_MeterTap;
var
  g: TAudioGraph;
  s, m, o: TAudioNode;
  r: TOfflineResult;
  mn: TMeterNode;
begin
  g := TAudioGraph.Create(2);
  try
    s := g.AddNode(nkSource);
    TGraphSourceNode(s).SetTone(osSine, 1000, 0.5);
    m := g.AddNode(nkMeter, 'Tap');
    o := g.AddNode(nkOutput);
    g.Connect(s.Id, m.Id);
    g.Connect(m.Id, o.Id);

    r := RenderGraph(g, 0.6);
    mn := TMeterNode(m);
    CheckNear(0.5, ChannelPeak(r, 0), 0.02, 'meter passes audio through unchanged');
    CheckNear(-6.02, mn.PeakDb, 1.0, 'tap peak ~ -6 dBFS');
    CheckNear(-9.03, mn.RmsDb, 1.5, 'tap RMS ~ -9 dBFS');
    Check((mn.MomentaryLufs > -30) and (mn.MomentaryLufs < 0), 'tap LUFS in a sane range');
  finally
    g.Free;
  end;
end;

{ ================= serializer ================= }

procedure Test_Graph_Serialize_RoundTrip;
var
  g, g2: TAudioGraph;
  text: string;
  r1, r2: TOfflineResult;
begin
  g := TAudioGraph.Create(2);
  try
    with TGraphSourceNode(g.AddNode(nkSource, 'Osc')) do SetTone(osSaw, 220, 0.4);
    TBiquadNode(g.AddNode(nkBiquad, 'Tone')).SetFilter(bqLowpass, 1200, 0.7, 0);
    TGainNode(g.AddNode(nkGain, 'Trim')).GainDb := -4.5;
    g.AddNode(nkOutput, 'Master');
    g.Connect(1, 2); g.Connect(2, 3); g.Connect(3, 4);

    text := GraphToString(g);
    Check(text.StartsWith('UDAWGRAPH 1'), 'header written');

    g2 := GraphFromString(text);
    try
      CheckEqualInt(g.NodeCount, g2.NodeCount, 'node count round-trips');
      CheckEqualInt(g.ConnectionCount, g2.ConnectionCount, 'conn count round-trips');
      CheckEqualStr('biquad', NodeKindId(g2.NodeById(2).Kind), 'kind round-trips');
      CheckNear(-4.5, TGainNode(g2.NodeById(3)).GainDb, 1e-6, 'gain param round-trips');
      Check(g2.Compile, 'reloaded graph compiles: ' + g2.LastError);

      r1 := RenderGraph(g, 0.3);
      r2 := RenderGraph(g2, 0.3);
      CheckNear(ChannelRms(r1, 0), ChannelRms(r2, 0), 1e-4, 'reloaded graph renders identically');
    finally
      g2.Free;
    end;
  finally
    g.Free;
  end;
end;

procedure Test_Graph_Serialize_RejectVersion;
var
  raised: Boolean;
  g: TAudioGraph;
begin
  raised := False;
  g := nil;
  try
    g := GraphFromString('UDAWGRAPH 9'#10'CHANNELS 2'#10'NODE 1 output "M" -'#10);
  except
    on E: EUDAWError do
      raised := E.Code = errConfig;
  end;
  g.Free;
  Check(raised, 'a future file version is rejected with errConfig');
end;

procedure Test_Graph_Serialize_RejectUnknownKind;
var
  raised: Boolean;
  g: TAudioGraph;
begin
  raised := False;
  g := nil;
  try
    g := GraphFromString('UDAWGRAPH 1'#10'NODE 1 quantum_flux "X" -'#10);
  except
    on E: EUDAWError do raised := True;
  end;
  g.Free;
  Check(raised, 'an unknown node kind is rejected');
end;

{ ================= engine adapter + recompile ================= }

procedure Test_Graph_SourceAdapter;
var
  g: TAudioGraph;
  src: IAudioSource;
  r: TOfflineResult;
begin
  BuildToneGain(g, 440, 0.5, 0.0);
  try
    src := g.AsSource;
    Check(src.Name.Contains('graph'), 'adapter names itself');
    r := RenderSourceOffline(src, SR, 2, SR div 4, 256);
    Check(ChannelPeak(r, 0) > 0.4, 'graph plays through the IAudioSource adapter');
    Check(g.AsSource = src, 'adapter instance is cached');
  finally
    g.Free;
  end;
end;

procedure Test_Graph_RecompileAndRetire;
var
  g: TAudioGraph;
  gainId, k, extraId: Integer;
  buf: TAudioBuffer;
  n: TAudioNode;
begin
  gainId := BuildToneGain(g, 500, 0.4, 0.0);
  try
    g.Prepare(SR, 256, 2);
    buf := TAudioBuffer.Create(2, 256, SR);
    try
      for k := 0 to 24 do
      begin
        { move a parameter and rebuild the plan }
        TGainNode(g.NodeById(gainId)).GainDb := -(k mod 12);
        Check(g.Compile, 'recompile ' + IntToStr(k) + ': ' + g.LastError);
        buf.SetActiveFrames(256);
        g.Process(buf);
        CheckFalse(buf.HasNonFinite, 'render stays finite after recompile ' + IntToStr(k));

        { add then drop a node so the retire path runs while a plan is live }
        n := g.AddNode(nkDCBlock, 'tmp');
        extraId := n.Id;
        g.Connect(gainId, extraId);
        Check(g.Compile, 'compile with extra node');
        g.Process(buf);
        g.RemoveNode(extraId);
        Check(g.Compile, 'compile after removing extra node');
        g.Process(buf);
        CheckFalse(buf.HasNonFinite, 'still finite after node retire ' + IntToStr(k));
      end;
    finally
      buf.Free;
    end;
  finally
    g.Free;
  end;
end;

{ ---------------- registration ---------------- }

procedure RegisterPhase4Tests;
begin
  RegisterTest('graph.build', 'build + compile',            @Test_Graph_BuildAndCompile);
  RegisterTest('graph.build', 'introspection',              @Test_Graph_Introspection);

  RegisterTest('graph.validate', 'no Output node',          @Test_Graph_Validate_NoOutput);
  RegisterTest('graph.validate', 'two Output nodes',        @Test_Graph_Validate_TwoOutputs);
  RegisterTest('graph.validate', 'illegal feedback cycle',  @Test_Graph_Validate_Cycle);
  RegisterTest('graph.validate', 'connect into generator',  @Test_Graph_Validate_ConnectIntoGenerator);
  RegisterTest('graph.validate', 'missing source',          @Test_Graph_Validate_MissingSource);
  RegisterTest('graph.validate', 'channel mismatch',        @Test_Graph_Validate_ChannelMismatch);

  RegisterTest('graph.render', 'gain node',                 @Test_Graph_Render_Gain);
  RegisterTest('graph.render', 'summed fan-in',             @Test_Graph_Render_Sum);
  RegisterTest('graph.render', 'bypass + mute',             @Test_Graph_Render_BypassMute);
  RegisterTest('graph.render', 'biquad lowpass',            @Test_Graph_Render_Lowpass);
  RegisterTest('graph.render', 'delay line',                @Test_Graph_Render_Delay);
  RegisterTest('graph.render', 'meter tap',                 @Test_Graph_MeterTap);

  RegisterTest('graph.serialize', 'round-trip',             @Test_Graph_Serialize_RoundTrip);
  RegisterTest('graph.serialize', 'reject file version',    @Test_Graph_Serialize_RejectVersion);
  RegisterTest('graph.serialize', 'reject unknown kind',    @Test_Graph_Serialize_RejectUnknownKind);

  RegisterTest('graph.engine', 'IAudioSource adapter',      @Test_Graph_SourceAdapter);
  RegisterTest('graph.engine', 'recompile + node retire',   @Test_Graph_RecompileAndRetire);
end;

end.
