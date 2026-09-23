unit Tests.Phase9;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 9 acceptance tests: the mixer.

  Covers the model (strip kinds, routing validation incl. cycles / bad targets,
  reference cleanup on strip removal, mute/solo gating, VCA-group trim, deep
  clone independence), the versioned text serializer (round-trip, rejects,
  embedding in the project file at v3, pre-v3 files gaining a synthesised
  master), the RT mix processor (silence, constant-power pan, fader
  attenuation, mute / solo, bus summing + bus fader, pre- vs post-fader sends,
  insert-chain processing, polarity cancellation, VCA scaling) and the
  undo/redo commands (add/remove strip with reference restore, mergeable fader
  moves, rejected illegal routing).

  Requires src/common, src/audio, src/audio/dsp, src/audio/graph, src/timeline,
  src/project and src/mixer on the search path. }

interface

procedure RegisterPhase9Tests;

implementation

uses
  SysUtils, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Audio.Types, UDAW.Audio.Buffer,
  UDAW.Project.Document, UDAW.Project.Serialization, UDAW.Project.Commands,
  UDAW.Mixer.Model, UDAW.Mixer.Automation, UDAW.Mixer.Serialization, UDAW.Mixer.Engine,
  UDAW.Mixer.Commands;

const
  SR = 48000;

type
  { Renders a per-strip DC constant onto every channel. }
  TConstProvider = class(TInterfacedObject, IMixInputProvider)
  private
    FIds: array of Integer;
    FVals: array of Single;
  public
    procedure SetStrip(AId: Integer; AValue: Single);
    procedure RenderStripInput(AStripId: Integer; ABuffer: TAudioBuffer);
  end;

procedure TConstProvider.SetStrip(AId: Integer; AValue: Single);
begin
  SetLength(FIds, Length(FIds) + 1);
  SetLength(FVals, Length(FVals) + 1);
  FIds[High(FIds)] := AId;
  FVals[High(FVals)] := AValue;
end;

procedure TConstProvider.RenderStripInput(AStripId: Integer; ABuffer: TAudioBuffer);
var
  i, ch, n: Integer;
  v: Single;
  p: PSingle;
begin
  v := 0;
  for i := 0 to High(FIds) do
    if FIds[i] = AStripId then v := FVals[i];
  if v = 0 then Exit;
  n := ABuffer.FrameCount;
  for ch := 0 to ABuffer.ChannelCount - 1 do
  begin
    p := PSingle(ABuffer.ChannelPtr(ch));
    for i := 0 to n - 1 do
      p[i] := v;
  end;
end;

{ RMS of the last AFrac fraction of one channel of a planar render. }
function TailRms(const APlanar: TAudioPlanar; ACh: Integer; AFrac: Double): Double;
var
  n, start, i: Integer;
  acc: Double;
begin
  n := Length(APlanar[ACh]);
  start := Trunc(n * (1.0 - AFrac));
  if start < 0 then start := 0;
  acc := 0;
  for i := start to n - 1 do
    acc := acc + Sqr(Double(APlanar[ACh][i]));
  if n - start <= 0 then Exit(0);
  Result := Sqrt(acc / (n - start));
end;

function TailPeak(const APlanar: TAudioPlanar; ACh: Integer; AFrac: Double): Double;
var
  n, start, i: Integer;
  m, a: Double;
begin
  n := Length(APlanar[ACh]);
  start := Trunc(n * (1.0 - AFrac));
  m := 0;
  for i := start to n - 1 do
  begin
    a := Abs(Double(APlanar[ACh][i]));
    if a > m then m := a;
  end;
  Result := m;
end;

{ ================= model ================= }

procedure Test_Model_Defaults;
var
  m: TMixerModel;
  err: string;
begin
  m := TMixerModel.Create;
  try
    m.InitDefault;
    CheckEqualInt(1, m.StripCount, 'InitDefault has one strip');
    Check(m.MasterStrip <> nil, 'there is a master strip');
    CheckEqualInt(1, m.MasterCount, 'exactly one master');
    Check(m.ValidateRouting(err), 'default routing valid: ' + err);
  finally
    m.Free;
  end;
end;

procedure Test_Model_AddAndRoute;
var
  m: TMixerModel;
  trk, bus, aux: TMixStrip;
  err: string;
begin
  m := TMixerModel.Create;
  try
    m.InitDefault;
    trk := m.AddStrip(skAudioTrack, 'Drums');
    bus := m.AddStrip(skBus, 'Drum Bus');
    aux := m.AddStrip(skAux, 'Reverb');
    trk.OutputTargetId := bus.Id;
    bus.OutputTargetId := 0;                 // straight to master
    trk.AddSend(aux.Id, -12, smPostFader);
    aux.OutputTargetId := 0;
    Check(m.ValidateRouting(err), 'track->bus->master + aux send valid: ' + err);
  finally
    m.Free;
  end;
end;

procedure Test_Model_RejectsCycle;
var
  m: TMixerModel;
  a, b: TMixStrip;
  err: string;
begin
  m := TMixerModel.Create;
  try
    m.InitDefault;
    a := m.AddStrip(skBus, 'A');
    b := m.AddStrip(skBus, 'B');
    a.OutputTargetId := b.Id;
    b.OutputTargetId := a.Id;
    CheckFalse(m.ValidateRouting(err), 'A<->B output cycle rejected');
  finally
    m.Free;
  end;
end;

procedure Test_Model_RejectsNonBusTarget;
var
  m: TMixerModel;
  t1, t2: TMixStrip;
  err: string;
begin
  m := TMixerModel.Create;
  try
    m.InitDefault;
    t1 := m.AddStrip(skAudioTrack, 'T1');
    t2 := m.AddStrip(skAudioTrack, 'T2');
    t1.OutputTargetId := t2.Id;             // a track is not a bus
    CheckFalse(m.ValidateRouting(err), 'routing a track into a track is rejected');
  finally
    m.Free;
  end;
end;

procedure Test_Model_RemoveStripCleansRefs;
var
  m: TMixerModel;
  trk, bus, aux: TMixStrip;
  err: string;
begin
  m := TMixerModel.Create;
  try
    m.InitDefault;
    trk := m.AddStrip(skAudioTrack, 'T');
    bus := m.AddStrip(skBus, 'B');
    aux := m.AddStrip(skAux, 'A');
    trk.OutputTargetId := bus.Id;
    trk.AddSend(aux.Id, -6, smPostFader);
    trk.AddSend(bus.Id, -6, smPreFader);

    m.RemoveStrip(bus.Id);
    CheckEqualInt(0, trk.OutputTargetId, 'output target falls back to master');
    Check(trk.SendToStrip(bus.Id) = nil, 'send to the removed bus is gone');
    Check(trk.SendToStrip(aux.Id) <> nil, 'unrelated send survives');
    Check(m.ValidateRouting(err), 'model still valid after removal: ' + err);
  finally
    m.Free;
  end;
end;

procedure Test_Model_SoloGate;
var
  m: TMixerModel;
  t1, t2: TMixStrip;
begin
  m := TMixerModel.Create;
  try
    m.InitDefault;
    t1 := m.AddStrip(skAudioTrack, 'T1');
    t2 := m.AddStrip(skAudioTrack, 'T2');
    CheckFalse(m.AnySolo, 'no solo initially');
    t1.Soloed := True;
    Check(m.AnySolo, 'solo now active');
    CheckNear(1.0, m.GateGain(t1), 1e-9, 'soloed strip passes');
    CheckNear(0.0, m.GateGain(t2), 1e-9, 'non-soloed strip is gated');
    CheckNear(1.0, m.GateGain(m.MasterStrip), 1e-9, 'master is never solo-gated');
    t1.Muted := True;
    CheckNear(0.0, m.GateGain(t1), 1e-9, 'mute beats solo');
  finally
    m.Free;
  end;
end;

procedure Test_Model_VCATrim;
var
  m: TMixerModel;
  trk, vca, vca2: TMixStrip;
begin
  m := TMixerModel.Create;
  try
    m.InitDefault;
    trk := m.AddStrip(skAudioTrack, 'T');
    vca := m.AddStrip(skVCA, 'V1');
    vca2 := m.AddStrip(skVCA, 'V2');
    vca.FaderDb := -6;
    vca2.FaderDb := -3;
    trk.VCAGroupId := vca.Id;
    CheckNear(-6.0, m.VCATrimDb(trk), 1e-9, 'single VCA trim');
    vca.VCAGroupId := vca2.Id;               // nest V1 under V2
    CheckNear(-9.0, m.VCATrimDb(trk), 1e-9, 'nested VCA trims sum');
  finally
    m.Free;
  end;
end;

procedure Test_Model_CloneIndependent;
var
  m, c: TMixerModel;
  trk: TMixStrip;
begin
  m := TMixerModel.Create;
  try
    m.InitDefault;
    trk := m.AddStrip(skAudioTrack, 'T');
    trk.FaderDb := -4;
    trk.AddInsert(TMixInsert.Make('gain', 'db=-6'));
    c := m.Clone;
    try
      trk.FaderDb := 3;
      CheckNear(-4.0, c.StripById(trk.Id).FaderDb, 1e-9, 'clone keeps its own fader');
      CheckEqualInt(1, c.StripById(trk.Id).InsertCount, 'clone copied the insert');
    finally
      c.Free;
    end;
  finally
    m.Free;
  end;
end;

{ ================= serialization ================= }

function BuildRichModel: TMixerModel;
var
  trk, bus, aux, vca: TMixStrip;
begin
  Result := TMixerModel.Create;
  Result.InitDefault;
  trk := Result.AddStrip(skAudioTrack, 'Drums');
  bus := Result.AddStrip(skBus, 'Drum Bus');
  aux := Result.AddStrip(skAux, 'Reverb');
  vca := Result.AddStrip(skVCA, 'Rhythm');
  trk.InputSourceId := 42;
  trk.TrimGainDb := 3;
  trk.PolarityInvert := True;
  trk.Pan := -0.3;
  trk.StereoWidth := 1.2;
  trk.FaderDb := -2.5;
  trk.RecordArmed := True;
  trk.AutomationMode := amRead;
  trk.OutputTargetId := bus.Id;
  trk.VCAGroupId := vca.Id;
  trk.AddInsert(TMixInsert.Make('gain', 'db=-6'));
  trk.AddInsert(TMixInsert.Make('biquad', 'type=peaking;freq=1200;q=1;gaindb=3', True));
  trk.AddSend(aux.Id, -12, smPostFader);
  trk.AddSend(bus.Id, -18, smPreFader, False);
  bus.OutputTargetId := 0;
  aux.OutputTargetId := 0;
end;

procedure Test_Serialize_RoundTrip;
var
  a, b: TMixerModel;
  sa: TMixStrip;
begin
  a := BuildRichModel;
  try
    b := MixerFromString(MixerToString(a));
    try
      CheckEqualInt(a.StripCount, b.StripCount, 'strip count round-trips');
      CheckEqualStr(a.Describe, b.Describe, 'Describe round-trips');
      sa := b.GetStrip(1);
      CheckEqualStr('Drums', sa.Name, 'strip name');
      CheckEqualInt(2, sa.InsertCount, 'inserts round-trip');
      Check(sa.GetInsert(1).Bypass, 'insert bypass flag round-trips');
      CheckEqualInt(2, sa.SendCount, 'sends round-trip');
      CheckEqualBool(True, sa.PolarityInvert, 'polarity round-trips');
      CheckNear(-0.3, sa.Pan, 1e-6, 'pan round-trips');
    finally
      b.Free;
    end;
  finally
    a.Free;
  end;
end;

procedure Test_Serialize_RejectsBadVersion;
begin
  try
    MixerFromString('UDAWMIXER 9'#10'NEXTID 1'#10).Free;
    Fail('unsupported mixer version should raise');
  except
    on E: EUDAWError do
      CheckEqualInt(Ord(errConfig), Ord(E.Code), 'errConfig for bad version');
  end;
end;

procedure Test_Serialize_AutomationSelectors;
var
  a, b: TMixerModel;
  trk, bus: TMixStrip;
  lane: TAutomationLane;
begin
  a := TMixerModel.Create;
  try
    a.InitDefault;
    a.MeterHoldMs := 2250;
    a.MeterHoldDecayDbPerSec := 7.5;
    trk := a.AddStrip(skAudioTrack, 'Automated');
    bus := a.AddStrip(skAux, 'FX');
    trk.AddSend(bus.Id, -6, smPostFader);
    trk.AddInsert(TMixInsert.Make('gain', 'db=0'));
    trk.AddInsert(TMixInsert.Make('gain', 'db=0'));
    trk.AddInsert(TMixInsert.Make('vst2', 'path=;state=;paramcount=18'));
    a.Automation.LaneFor(trk.Id, apMute, True).AddPoint(1.0, 1.0);
    a.Automation.LaneFor(trk.Id, apSendGain, True, bus.Id).AddPoint(2.0, -9.0);
    a.Automation.LaneFor(trk.Id, apInsertParam, True, 2, 17).AddPoint(3.0, 0.75);
    b := MixerFromString(MixerToString(a));
    try
      CheckEqualInt(3, b.Automation.LaneCount, 'all automation lanes round-trip');
      CheckNear(2250, b.MeterHoldMs, 1e-9, 'meter hold time round-trips');
      CheckNear(7.5, b.MeterHoldDecayDbPerSec, 1e-9, 'meter decay round-trips');
      lane := b.Automation.LaneFor(trk.Id, apSendGain, False, bus.Id);
      Check(lane <> nil, 'send destination selector round-trips');
      CheckNear(-9.0, lane.Evaluate(2.0), 1e-9, 'send automation value round-trips');
      lane := b.Automation.LaneFor(trk.Id, apInsertParam, False, 2, 17);
      Check(lane <> nil, 'insert and parameter selectors round-trip');
      CheckNear(0.75, lane.Evaluate(3.0), 1e-9, 'plugin automation value round-trips');
    finally
      b.Free;
    end;
  finally
    a.Free;
  end;
end;

procedure Test_Serialize_RejectsUnknownKind;
begin
  try
    MixerFromString('UDAWMIXER 1'#10'STRIP 1 wombat "X" out=0'#10).Free;
    Fail('unknown strip kind should raise');
  except
    on E: EUDAWError do
      CheckEqualInt(Ord(errConfig), Ord(E.Code), 'errConfig for unknown kind');
  end;
end;

procedure Test_Serialize_EmbeddedInProjectV3;
var
  doc, back: TProjectDocument;
  s: string;
begin
  doc := TProjectDocument.CreateNew('mix proj');
  try
    doc.Mixer.AddStrip(skAudioTrack, 'Gtr');
    doc.Mixer.AddStrip(skBus, 'Bus');
    s := ProjectToString(doc);
    Check(Pos('UDAWPROJECT ', s) = 1, 'project file has a versioned header');
    Check(Pos('MIXER-BEGIN', s) > 0, 'mixer section is written');
    back := ProjectFromString(s);
    try
      CheckEqualInt(3, back.Mixer.StripCount, 'mixer strips survive a project round-trip');
      Check(back.Mixer.MasterStrip <> nil, 'master survives');
    finally
      back.Free;
    end;
  finally
    doc.Free;
  end;
end;

procedure Test_Serialize_PreV3ProjectGainsMaster;
var
  v2, back: TProjectDocument;
  s: string;
  p: Integer;
begin
  { take a real serialized project and strip the MIXER section + drop version to 2 }
  v2 := TProjectDocument.CreateNew('old');
  try
    s := ProjectToString(v2);
  finally
    v2.Free;
  end;
  p := Pos('MIXER-BEGIN', s);
  if p > 0 then
    s := Copy(s, 1, p - 1);
  s := StringReplace(s, 'UDAWPROJECT 4', 'UDAWPROJECT 2', []);
  s := StringReplace(s, 'UDAWPROJECT 3', 'UDAWPROJECT 2', []);

  back := ProjectFromString(s);
  try
    CheckEqualInt(1, back.Mixer.StripCount, 'a pre-v3 project loads with one synthesised strip');
    Check(back.Mixer.MasterStrip <> nil, 'that strip is a master');
  finally
    back.Free;
  end;
end;

{ ================= engine ================= }

procedure Test_Engine_SilenceWithOnlyMaster;
var
  m: TMixerModel;
  proc: TMixerProcessor;
  outp: TAudioPlanar;
begin
  m := TMixerModel.Create;
  proc := nil;
  try
    m.InitDefault;
    proc := TMixerProcessor.Create(m);
    proc.Prepare(SR, 480, 2);
    outp := proc.RenderToPlanar(4800);
    CheckNear(0.0, TailPeak(outp, 0, 1.0), 1e-9, 'no sources -> silence L');
    CheckNear(0.0, TailPeak(outp, 1, 1.0), 1e-9, 'no sources -> silence R');
  finally
    proc.Free;
    m.Free;
  end;
end;

procedure Test_Engine_TrackToMasterPan;
var
  m: TMixerModel;
  proc: TMixerProcessor;
  prov: IMixInputProvider;
  cp: TConstProvider;
  trk: TMixStrip;
  outp: TAudioPlanar;
begin
  m := TMixerModel.Create;
  proc := nil;
  try
    m.InitDefault;
    trk := m.AddStrip(skAudioTrack, 'T');
    trk.OutputTargetId := 0;
    cp := TConstProvider.Create;
    cp.SetStrip(trk.Id, 0.25);
    prov := cp;
    proc := TMixerProcessor.Create(m);
    proc.SetInputProvider(prov);
    proc.Prepare(SR, 480, 2);
    outp := proc.RenderToPlanar(24000);
    { centre constant-power pan: 0.25 * cos(pi/4) on each channel }
    CheckNear(0.25 * 0.70710678, TailRms(outp, 0, 0.25), 2.0E-3, 'L at -3 dB pan law');
    CheckNear(0.25 * 0.70710678, TailRms(outp, 1, 0.25), 2.0E-3, 'R at -3 dB pan law');
  finally
    proc.Free;
    m.Free;
  end;
end;

procedure Test_Engine_FaderAttenuation;
var
  m: TMixerModel;
  proc: TMixerProcessor;
  prov: IMixInputProvider;
  cp: TConstProvider;
  trk: TMixStrip;
  ref, atten: Double;
  outp: TAudioPlanar;
begin
  m := TMixerModel.Create;
  proc := nil;
  try
    m.InitDefault;
    trk := m.AddStrip(skAudioTrack, 'T');
    cp := TConstProvider.Create;
    cp.SetStrip(trk.Id, 0.5);
    prov := cp;
    proc := TMixerProcessor.Create(m);
    proc.SetInputProvider(prov);

    proc.Prepare(SR, 480, 2);
    outp := proc.RenderToPlanar(24000);
    ref := TailRms(outp, 0, 0.2);

    trk.FaderDb := -6.0206;   // exactly half
    proc.Prepare(SR, 480, 2);
    outp := proc.RenderToPlanar(24000);
    atten := TailRms(outp, 0, 0.2);

    CheckNear(0.5, atten / ref, 0.01, '-6 dB fader halves the level');
  finally
    proc.Free;
    m.Free;
  end;
end;

procedure Test_Engine_AutomatedMute;
var
  m: TMixerModel;
  proc: TMixerProcessor;
  prov: IMixInputProvider;
  cp: TConstProvider;
  trk: TMixStrip;
  outp: TAudioPlanar;
begin
  m := TMixerModel.Create;
  proc := nil;
  try
    m.InitDefault;
    trk := m.AddStrip(skAudioTrack, 'Automated');
    trk.AutomationMode := amRead;
    m.Automation.LaneFor(trk.Id, apMute, True).AddPoint(0.0, 1.0);
    cp := TConstProvider.Create;
    cp.SetStrip(trk.Id, 0.25);
    prov := cp;
    proc := TMixerProcessor.Create(m);
    proc.SetInputProvider(prov);
    proc.SetAutomation(m.Automation);
    proc.Prepare(SR, 480, 2);
    outp := proc.RenderToPlanar(24000);
    CheckNear(0.0, TailPeak(outp, 0, 0.2), 1e-6, 'mute lane silences left output');
    CheckNear(0.0, TailPeak(outp, 1, 0.2), 1e-6, 'mute lane silences right output');
  finally
    proc.Free;
    m.Free;
  end;
end;

procedure Test_Engine_MuteAndSolo;
var
  m: TMixerModel;
  proc: TMixerProcessor;
  prov: IMixInputProvider;
  cp: TConstProvider;
  t1, t2: TMixStrip;
  both, muted, soloed: Double;
  outp: TAudioPlanar;
begin
  m := TMixerModel.Create;
  proc := nil;
  try
    m.InitDefault;
    t1 := m.AddStrip(skAudioTrack, 'T1');
    t2 := m.AddStrip(skAudioTrack, 'T2');
    cp := TConstProvider.Create;
    cp.SetStrip(t1.Id, 0.2);
    cp.SetStrip(t2.Id, 0.2);
    prov := cp;
    proc := TMixerProcessor.Create(m);
    proc.SetInputProvider(prov);

    proc.Prepare(SR, 480, 2);
    both := TailRms(proc.RenderToPlanar(24000), 0, 0.2);

    t2.Muted := True;
    proc.Prepare(SR, 480, 2);
    muted := TailRms(proc.RenderToPlanar(24000), 0, 0.2);
    CheckNear(0.5, muted / both, 0.02, 'muting one of two equal tracks halves the mix');

    t2.Muted := False;
    t1.Soloed := True;
    proc.Prepare(SR, 480, 2);
    outp := proc.RenderToPlanar(24000);
    soloed := TailRms(outp, 0, 0.2);
    CheckNear(muted, soloed, 2.0E-3, 'solo on T1 isolates it exactly like muting T2');
  finally
    proc.Free;
    m.Free;
  end;
end;

procedure Test_Engine_BusSumAndFader;
var
  m: TMixerModel;
  proc: TMixerProcessor;
  prov: IMixInputProvider;
  cp: TConstProvider;
  t1, t2, bus: TMixStrip;
  outp: TAudioPlanar;
  expected: Double;
begin
  m := TMixerModel.Create;
  proc := nil;
  try
    m.InitDefault;
    t1 := m.AddStrip(skAudioTrack, 'T1');
    t2 := m.AddStrip(skAudioTrack, 'T2');
    bus := m.AddStrip(skBus, 'Bus');
    t1.OutputTargetId := bus.Id;
    t2.OutputTargetId := bus.Id;
    bus.FaderDb := -6.0206;
    cp := TConstProvider.Create;
    cp.SetStrip(t1.Id, 0.2);
    cp.SetStrip(t2.Id, 0.2);
    prov := cp;
    proc := TMixerProcessor.Create(m);
    proc.SetInputProvider(prov);
    proc.Prepare(SR, 480, 2);
    outp := proc.RenderToPlanar(24000);
    { each track: 0.2 * 0.7071 into the bus; bus (balance identity) * 0.5 fader }
    expected := (2 * 0.2 * 0.70710678) * 0.5;
    CheckNear(expected, TailRms(outp, 0, 0.2), 3.0E-3, 'bus sums both tracks then applies its fader');
  finally
    proc.Free;
    m.Free;
  end;
end;

procedure Test_Engine_PreVsPostFaderSend;
var
  m: TMixerModel;
  proc: TMixerProcessor;
  prov: IMixInputProvider;
  cp: TConstProvider;
  trk, aux: TMixStrip;
  preLevel, postLevel: Double;
begin
  m := TMixerModel.Create;
  proc := nil;
  try
    m.InitDefault;
    trk := m.AddStrip(skAudioTrack, 'T');
    aux := m.AddStrip(skAux, 'FX');
    aux.OutputTargetId := 0;
    trk.Muted := True;                       // kill the direct + post-fader path
    trk.AddSend(aux.Id, 0.0, smPreFader);
    cp := TConstProvider.Create;
    cp.SetStrip(trk.Id, 0.3);
    prov := cp;
    proc := TMixerProcessor.Create(m);
    proc.SetInputProvider(prov);

    proc.Prepare(SR, 480, 2);
    preLevel := TailRms(proc.RenderToPlanar(24000), 0, 0.2);
    Check(preLevel > 0.2, 'a pre-fader send still feeds the aux when the strip is muted');

    trk.RemoveSend(aux.Id);
    trk.AddSend(aux.Id, 0.0, smPostFader);
    proc.Prepare(SR, 480, 2);
    postLevel := TailRms(proc.RenderToPlanar(24000), 0, 0.2);
    CheckNear(0.0, postLevel, 1.0E-4, 'a post-fader send is silent when the strip is muted');
  finally
    proc.Free;
    m.Free;
  end;
end;

procedure Test_Engine_InsertChainProcesses;
var
  m: TMixerModel;
  proc: TMixerProcessor;
  prov: IMixInputProvider;
  cp: TConstProvider;
  trk: TMixStrip;
  ref, withGain: Double;
begin
  m := TMixerModel.Create;
  proc := nil;
  try
    m.InitDefault;
    trk := m.AddStrip(skAudioTrack, 'T');
    cp := TConstProvider.Create;
    cp.SetStrip(trk.Id, 0.4);
    prov := cp;
    proc := TMixerProcessor.Create(m);
    proc.SetInputProvider(prov);

    proc.Prepare(SR, 480, 2);
    ref := TailRms(proc.RenderToPlanar(24000), 0, 0.2);

    trk.AddInsert(TMixInsert.Make('gain', 'db=-6.0206'));
    proc.Prepare(SR, 480, 2);
    withGain := TailRms(proc.RenderToPlanar(24000), 0, 0.2);
    CheckNear(0.5, withGain / ref, 0.01, 'a -6 dB gain insert halves the strip output');

    trk.SetInsert(0, TMixInsert.Make('gain', 'db=-6.0206', True));  // bypass it
    proc.Prepare(SR, 480, 2);
    CheckNear(ref, TailRms(proc.RenderToPlanar(24000), 0, 0.2), 3.0E-3,
      'a bypassed insert is transparent');
  finally
    proc.Free;
    m.Free;
  end;
end;

procedure Test_Engine_PolarityCancellation;
var
  m: TMixerModel;
  proc: TMixerProcessor;
  prov: IMixInputProvider;
  cp: TConstProvider;
  t1, t2: TMixStrip;
begin
  m := TMixerModel.Create;
  proc := nil;
  try
    m.InitDefault;
    t1 := m.AddStrip(skAudioTrack, 'T1');
    t2 := m.AddStrip(skAudioTrack, 'T2');
    t2.PolarityInvert := True;
    cp := TConstProvider.Create;
    cp.SetStrip(t1.Id, 0.3);
    cp.SetStrip(t2.Id, 0.3);
    prov := cp;
    proc := TMixerProcessor.Create(m);
    proc.SetInputProvider(prov);
    proc.Prepare(SR, 480, 2);
    CheckNear(0.0, TailPeak(proc.RenderToPlanar(24000), 0, 0.2), 1.0E-4,
      'a polarity-inverted duplicate cancels the original');
  finally
    proc.Free;
    m.Free;
  end;
end;

procedure Test_Engine_VCAScalesMember;
var
  m: TMixerModel;
  proc: TMixerProcessor;
  prov: IMixInputProvider;
  cp: TConstProvider;
  trk, vca: TMixStrip;
  ref, scaled: Double;
begin
  m := TMixerModel.Create;
  proc := nil;
  try
    m.InitDefault;
    trk := m.AddStrip(skAudioTrack, 'T');
    vca := m.AddStrip(skVCA, 'V');
    cp := TConstProvider.Create;
    cp.SetStrip(trk.Id, 0.4);
    prov := cp;
    proc := TMixerProcessor.Create(m);
    proc.SetInputProvider(prov);

    proc.Prepare(SR, 480, 2);
    ref := TailRms(proc.RenderToPlanar(24000), 0, 0.2);

    vca.FaderDb := -6.0206;
    trk.VCAGroupId := vca.Id;
    proc.Prepare(SR, 480, 2);
    scaled := TailRms(proc.RenderToPlanar(24000), 0, 0.2);
    CheckNear(0.5, scaled / ref, 0.01, 'a -6 dB VCA halves its member');
  finally
    proc.Free;
    m.Free;
  end;
end;

{ ================= commands ================= }

procedure Test_Cmd_AddRemoveStripUndoRedo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  add: TAddMixStripCommand;
  newId: Integer;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    add := TAddMixStripCommand.Create(doc, skAudioTrack, 'Vox');
    Check(mgr.Perform(add), 'add strip executes');
    newId := add.CreatedId;
    CheckEqualInt(2, doc.Mixer.StripCount, 'strip added');

    mgr.Undo;
    CheckEqualInt(1, doc.Mixer.StripCount, 'undo removes the strip');
    Check(doc.Mixer.StripById(newId) = nil, 'strip really gone');

    mgr.Redo;
    CheckEqualInt(2, doc.Mixer.StripCount, 'redo restores it');
    Check(doc.Mixer.StripById(newId) <> nil, 'with the same id');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Cmd_FaderMoveMerges;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  trk: TMixStrip;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    trk := doc.Mixer.AddStrip(skAudioTrack, 'T');
    mgr.Perform(TSetMixStripFloatCommand.Create(doc, trk.Id, mffFader, -3));
    mgr.Perform(TSetMixStripFloatCommand.Create(doc, trk.Id, mffFader, -6));
    mgr.Perform(TSetMixStripFloatCommand.Create(doc, trk.Id, mffFader, -9));
    CheckEqualInt(1, mgr.UndoCount, 'three fast fader moves collapse to one undo step');
    CheckNear(-9.0, trk.FaderDb, 1e-9, 'latest value stuck');
    mgr.Undo;
    CheckNear(0.0, trk.FaderDb, 1e-9, 'one undo returns to the pre-drag value');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Cmd_RouteRejectsCycle;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  a, b: TMixStrip;
  raised: Boolean;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    a := doc.Mixer.AddStrip(skBus, 'A');
    b := doc.Mixer.AddStrip(skBus, 'B');
    mgr.Perform(TSetMixStripRouteCommand.Create(doc, a.Id, b.Id));
    raised := False;
    try
      mgr.Perform(TSetMixStripRouteCommand.Create(doc, b.Id, a.Id));
    except
      on E: EUDAWError do raised := True;
    end;
    Check(raised, 'a routing command that would create a cycle is rejected');
    CheckEqualInt(0, b.OutputTargetId, 'B route unchanged after the rejection');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Cmd_RemoveStripUndoRestoresRefs;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  trkId, busId: Integer;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    trkId := doc.Mixer.AddStrip(skAudioTrack, 'T').Id;
    busId := doc.Mixer.AddStrip(skBus, 'B').Id;
    doc.Mixer.StripById(trkId).OutputTargetId := busId;

    { a structural command restores the model by text snapshot, so strip
      object references do not survive it - callers work in id space }
    mgr.Perform(TRemoveMixStripCommand.Create(doc, busId));
    CheckEqualInt(0, doc.Mixer.StripById(trkId).OutputTargetId, 'route fell back to master');

    mgr.Undo;
    Check(doc.Mixer.StripById(busId) <> nil, 'undo brings the bus back');
    CheckEqualInt(busId, doc.Mixer.StripById(trkId).OutputTargetId,
      'undo restores the track route into that bus');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

{ ---------------- registration ---------------- }

procedure Test_SourceEffects;
var model: TMixerModel; track, bus, aux: TMixStrip; ins: TMixInsert;
begin
  model := TMixerModel.Create;
  try
    model.InitDefault;
    track := model.AddStrip(skAudioTrack, 'track'); track.InputSourceId := 77;
    bus := model.AddStrip(skBus, 'bus');
    aux := model.AddStrip(skAux, 'aux');
    track.OutputTargetId := bus.Id;
    CheckFalse(model.SourceHasEffects(77), 'dry routing is not marked');
    ins := TMixInsert.Make('gain', 'db=3', True);
    bus.AddInsert(ins);
    CheckFalse(model.SourceHasEffects(77), 'bypassed effect is not marked');
    ins.Bypass := False; bus.SetInsert(0, ins);
    Check(model.SourceHasEffects(77), 'bus effect marks source clips');
    CheckFalse(model.SourceHasEffects(78), 'unrelated track is not marked');
    bus.DeleteInsert(0);
    aux.AddInsert(ins);
    track.AddSend(aux.Id, 0, smPostFader, False);
    CheckFalse(model.SourceHasEffects(77), 'disabled send is not marked');
    track.GetSend(0).Enabled := True;
    Check(model.SourceHasEffects(77), 'enabled effect send marks source clips');
    track.GetSend(0).Enabled := False;
    model.MasterStrip.AddInsert(ins);
    Check(model.SourceHasEffects(77), 'master insert affects linked clips');
  finally model.Free; end;
end;

procedure RegisterPhase9Tests;
begin
  RegisterTest('mixer.model', 'effect indication follows active routing', Test_SourceEffects);
  RegisterTest('mixer.model', 'defaults',                    @Test_Model_Defaults);
  RegisterTest('mixer.model', 'add + route',                 @Test_Model_AddAndRoute);
  RegisterTest('mixer.model', 'rejects output cycle',        @Test_Model_RejectsCycle);
  RegisterTest('mixer.model', 'rejects non-bus target',      @Test_Model_RejectsNonBusTarget);
  RegisterTest('mixer.model', 'remove strip cleans refs',    @Test_Model_RemoveStripCleansRefs);
  RegisterTest('mixer.model', 'solo / mute gate',            @Test_Model_SoloGate);
  RegisterTest('mixer.model', 'VCA-group trim (nested)',     @Test_Model_VCATrim);
  RegisterTest('mixer.model', 'clone is independent',        @Test_Model_CloneIndependent);

  RegisterTest('mixer.serialize', 'round-trip',              @Test_Serialize_RoundTrip);
  RegisterTest('mixer.serialize', 'automation selectors',    @Test_Serialize_AutomationSelectors);
  RegisterTest('mixer.serialize', 'rejects bad version',     @Test_Serialize_RejectsBadVersion);
  RegisterTest('mixer.serialize', 'rejects unknown kind',    @Test_Serialize_RejectsUnknownKind);
  RegisterTest('mixer.serialize', 'embedded in project v3',  @Test_Serialize_EmbeddedInProjectV3);
  RegisterTest('mixer.serialize', 'pre-v3 gains a master',   @Test_Serialize_PreV3ProjectGainsMaster);

  RegisterTest('mixer.engine', 'silence with only master',   @Test_Engine_SilenceWithOnlyMaster);
  RegisterTest('mixer.engine', 'track -> master pan law',    @Test_Engine_TrackToMasterPan);
  RegisterTest('mixer.engine', 'fader attenuation',          @Test_Engine_FaderAttenuation);
  RegisterTest('mixer.engine', 'automated mute',             @Test_Engine_AutomatedMute);
  RegisterTest('mixer.engine', 'mute + solo',               @Test_Engine_MuteAndSolo);
  RegisterTest('mixer.engine', 'bus sum + bus fader',        @Test_Engine_BusSumAndFader);
  RegisterTest('mixer.engine', 'pre- vs post-fader send',    @Test_Engine_PreVsPostFaderSend);
  RegisterTest('mixer.engine', 'insert chain + bypass',      @Test_Engine_InsertChainProcesses);
  RegisterTest('mixer.engine', 'polarity cancellation',      @Test_Engine_PolarityCancellation);
  RegisterTest('mixer.engine', 'VCA scales member',          @Test_Engine_VCAScalesMember);

  RegisterTest('mixer.commands', 'add/remove strip undo/redo', @Test_Cmd_AddRemoveStripUndoRedo);
  RegisterTest('mixer.commands', 'fader moves merge',          @Test_Cmd_FaderMoveMerges);
  RegisterTest('mixer.commands', 'route rejects cycle',        @Test_Cmd_RouteRejectsCycle);
  RegisterTest('mixer.commands', 'remove strip undo restores refs', @Test_Cmd_RemoveStripUndoRestoresRefs);
end;

end.
