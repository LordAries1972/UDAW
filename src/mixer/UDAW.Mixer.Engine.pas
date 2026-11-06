unit UDAW.Mixer.Engine;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 9 - Mixer: the real-time mix processor (plan section 10).

  TMixerProcessor renders a TMixerModel one block at a time. Prepare (off the
  audio thread) validates the routing, topologically orders the strips so every
  producer is processed before its consumer, and preallocates every buffer,
  insert processor and meter. ProcessBlock is real-time safe: it allocates
  nothing, locks nothing and touches no disk - it only sums, scales and walks
  the ordered plan.

  Per strip, in order:
    input source (via IMixInputProvider, for input / audio-track strips)
      + inbound bus feeds and sends deposited by earlier strips
      -> trim gain (click-free) -> polarity invert
      -> insert chain (hosted Phase 3/4 DSP nodes, in series, bypass-aware)
      -> pre-fader sends
      -> stereo width (M/S) -> constant-power pan
      -> fader * VCA-group trim * mute/solo gate (click-free)
      -> peak / RMS / LUFS metering (written back onto the model strip)
      -> post-fader sends
      -> summed into its output-target bus (or the master output).

  The master strip's post-fader signal is the mix. Sidechain detector input and
  the Phase 10 dynamics inserts plug into the same insert-host seam without
  changing this file. }

interface

uses
  SysUtils, Math,
  UDAW.Errors, UDAW.Threading,
  UDAW.Audio.Types, UDAW.Audio.Buffer,
  UDAW.DSP.Math, UDAW.DSP.Meter,
  UDAW.Audio.Graph.Nodes, UDAW.Mixer.PluginHost,
  UDAW.Mixer.Model, UDAW.Mixer.Automation, UDAW.Mixer.Modulation;

type
  { Supplies the dry audio for input / audio-track strips. The engine hands a
    cleared buffer already sized to the block; the provider fills it (or leaves
    it silent). Never called on strips that only sum buses. }
  IMixInputProvider = interface
    ['{7F1B4B90-3E2A-4C71-9D0E-6A4C4F8D21A5}']
    procedure RenderStripInput(AStripId: Integer; ABuffer: TAudioBuffer);
  end;

  TMixSendRT = record
    Send: TMixSend;          // model ref (gain / mode / enabled read live)
    TargetPlanIndex: Integer;
  end;

  TMixStripRT = class
  private
    FStrip: TMixStrip;       // model ref, not owned
    FInbox: TAudioBuffer;    // feeds + sends left here by earlier strips
    FAccum: TAudioBuffer;
    FWorkA: TAudioBuffer;
    FWorkB: TAudioBuffer;
    FInserts: array of TAudioNode;
    FInsertScPlanIndex: array of Integer;   // per insert: sidechain source plan index, or -1
    FSends: array of TMixSendRT;
    FOutputPlanIndex: Integer;   // -1 => this is the master
    FScTap: TAudioBuffer;        // this strip's post-fader signal, for consumers keying off it
    FProducesScTap: Boolean;
    FIsAudio: Boolean;
    FIsMaster: Boolean;
    FLastTrimLin: Double;
    FLastFaderLin: Double;
    FLastPanL, FLastPanR: Double;
    FLastWidth: Double;
    FPeakL, FPeakR: TPeakMeter;
    FRms: TRmsMeter;
    FLoud: TLoudnessMeter;
    FTpL, FTpR: TTruePeakMeter;     // master only
    FCorr: TCorrelationMeter;       // master only
  public
    constructor Create(AStrip: TMixStrip; AChannels, AMaxFrames, ASampleRate: Integer);
    destructor Destroy; override;
  end;

  TMixerProcessor = class
  private
    FModel: TMixerModel;         // not owned
    FLock: TUDAWLock;
    FPlan: array of TMixStripRT;
    FMasterOut: TAudioBuffer;
    FInputScratch: TAudioBuffer;
    FProvider: IMixInputProvider;
    FSampleRate: Integer;
    FMaxFrames: Integer;
    FChannels: Integer;
    FPrepared: Boolean;
    FLastError: string;
    FAutomation: TAutomationSet;   // not owned; see SetAutomation
    FModulation: TModulationSet;   // not owned; see SetModulation
    FPlayheadSeconds: Double;
    procedure FreePlan;
    procedure BuildOrder(out AOrder: TArray<Integer>);
    procedure ProcessStrip(ARt: TMixStripRT; AFrames: Integer);
  public
    constructor Create(AModel: TMixerModel);
    destructor Destroy; override;

    procedure SetInputProvider(AProvider: IMixInputProvider);
    { Mixer automation read pass (UDAW.Mixer.Automation). ASet is not
      owned - pass the TMixerModel's own Automation set, or nil to disable
      reading automation. Call SetPlayheadSeconds each block from whatever
      drives playback (the Timeline's PlayheadSeconds, or a test harness) so
      strips in amRead/amTouch/amLatch pick up their breakpoints; amOff and
      amWrite are unaffected (amWrite is a recording mode, not a read mode -
      capturing a live fader move into breakpoints is the UI's job, see the
      Mixer tab). }
    procedure SetAutomation(ASet: TAutomationSet);
    { Modulator system (UDAW.Mixer.Modulation): LFO/random/step/follower/macro
      sources summed onto fader, pan and hosted-plugin parameters each block.
      Not owned - pass TMixerModel.Modulation, or nil to disable. }
    procedure SetModulation(ASet: TModulationSet);
    procedure SetPlayheadSeconds(ASeconds: Double);

    { Validate routing, order the strips and (re)allocate. Raises EUDAWError
      (errInvalidState / errConfig) on an invalid model. Off the RT thread. }
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    { Pushes an edited graphic-EQ insert (gains and bypass) into the running plan without a
      re-Prepare, so a slider moved during playback is heard at once. }
    procedure UpdateGraphicEqLive(AStripId, AInsertIndex: Integer; const AParams: string;
      ABypass: Boolean);

    { RT: render one block of the master mix into AOut. Silence until Prepare. }
    procedure ProcessBlock(AOut: TAudioBuffer);

    { Offline helper for tests / bounce: render ATotalFrames into a planar
      buffer, block by block. }
    function RenderToPlanar(ATotalFrames: Integer;
      ABlockFrames: Integer = UDAW_DEFAULT_BUFFER_FRAMES): TAudioPlanar;

    function IsPrepared: Boolean;
    function StripRTCount: Integer;
    property SampleRate: Integer read FSampleRate;
    property Channels: Integer read FChannels;
    property MaxFrames: Integer read FMaxFrames;
    property LastError: string read FLastError;
  end;

function MixerInsertKindAllowed(AKind: TNodeKind): Boolean;

implementation

const
  { insert host: only self-contained per-channel processors are legal inserts.
    input/source/bus/output nodes route rather than process and are rejected. }
  INSERT_GLIDE_MS = 15.0;

function InsertKindAllowed(AKind: TNodeKind): Boolean;
begin
  Result := AKind in [nkGain, nkPan, nkBiquad, nkFilterChain, nkDCBlock,
                      nkDelay, nkChannelMap, nkMeter,
                      nkCompressor, nkModulation, nkDistortion, nkReverb,
                      nkGraphicEQ, nkVST2, nkCLAP, nkVST3, nkPython,
                      nkParametricEQ, nkStereoWidth, nkTransientShaper,
                      nkExciter, nkPitchShift, nkLookaheadLimiter,
                      nkMultibandComp, nkMastering];
end;

function MixerInsertKindAllowed(AKind: TNodeKind): Boolean;
begin
  Result := InsertKindAllowed(AKind);
end;

{ Placement law: a mono-ish source (input / audio track) is positioned with a
  constant-power PAN; a stereo sub-mix (bus / aux / master) uses a unity-at-
  centre BALANCE so buses and the master stay transparent by default. }
procedure StripPlacementGains(AKind: TMixStripKind; APos: Double; out AL, AR: Single);
begin
  if APos < -1 then APos := -1 else if APos > 1 then APos := 1;
  if AKind in [skInput, skAudioTrack] then
    PanGains(APos, plConstantPower, AL, AR)
  else
  begin
    AL := 1.0;
    AR := 1.0;
    if APos < 0 then AR := 1.0 + APos
    else if APos > 0 then AL := 1.0 - APos;
  end;
end;

{ ================= TMixStripRT ================= }

constructor TMixStripRT.Create(AStrip: TMixStrip; AChannels, AMaxFrames, ASampleRate: Integer);
begin
  inherited Create;
  FStrip := AStrip;
  FIsAudio := AStrip.IsAudioStrip;
  FIsMaster := AStrip.Kind = skMaster;
  FInbox := TAudioBuffer.Create(AChannels, AMaxFrames, ASampleRate);
  FAccum := TAudioBuffer.Create(AChannels, AMaxFrames, ASampleRate);
  FWorkA := TAudioBuffer.Create(AChannels, AMaxFrames, ASampleRate);
  FWorkB := TAudioBuffer.Create(AChannels, AMaxFrames, ASampleRate);
  FInbox.Clear;
  FLastTrimLin := DbToLinear(AStrip.TrimGainDb);
  FLastFaderLin := DbToLinear(AStrip.FaderDb);
  FLastPanL := 1.0;
  FLastPanR := 1.0;
  FLastWidth := AStrip.StereoWidth;
  FPeakL.Init(ASampleRate, 20.0, MIX_METER_HOLD_MS_DEFAULT,
    MIX_METER_HOLD_DECAY_DEFAULT);
  FPeakR.Init(ASampleRate, 20.0, MIX_METER_HOLD_MS_DEFAULT,
    MIX_METER_HOLD_DECAY_DEFAULT);
  FRms.Init(ASampleRate, 300.0);
  FLoud := TLoudnessMeter.Create(ASampleRate, 2);
  if AStrip.Kind = skMaster then
  begin
    FTpL.Init(ASampleRate);
    FTpR.Init(ASampleRate);
    FCorr.Init(ASampleRate);
  end;
  FScTap := TAudioBuffer.Create(AChannels, AMaxFrames, ASampleRate);
  FScTap.Clear;
  FOutputPlanIndex := -1;
end;

destructor TMixStripRT.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FInserts) do
    FInserts[i].Free;
  SetLength(FInserts, 0);
  FScTap.Free;
  FLoud.Free;
  FWorkB.Free;
  FWorkA.Free;
  FAccum.Free;
  FInbox.Free;
  inherited Destroy;
end;

{ ================= TMixerProcessor ================= }

constructor TMixerProcessor.Create(AModel: TMixerModel);
begin
  inherited Create;
  if AModel = nil then
    RaiseUDAW(errInvalidArgument, MIXER_SUBSYS, 'TMixerProcessor: model is nil');
  FModel := AModel;
  FLock := TUDAWLock.Create('mixerproc');
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FMaxFrames := UDAW_DEFAULT_BUFFER_FRAMES;
  FChannels := 2;
end;

destructor TMixerProcessor.Destroy;
begin
  FreePlan;
  FMasterOut.Free;
  FInputScratch.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TMixerProcessor.FreePlan;
var
  i: Integer;
begin
  for i := 0 to High(FPlan) do
    FPlan[i].Free;
  SetLength(FPlan, 0);
  FPrepared := False;
end;

procedure TMixerProcessor.SetInputProvider(AProvider: IMixInputProvider);
begin
  FLock.Enter;
  try
    FProvider := AProvider;
  finally
    FLock.Leave;
  end;
end;

procedure TMixerProcessor.SetAutomation(ASet: TAutomationSet);
begin
  FLock.Enter;
  try
    FAutomation := ASet;
  finally
    FLock.Leave;
  end;
end;

procedure TMixerProcessor.SetModulation(ASet: TModulationSet);
begin
  FLock.Enter;
  try
    FModulation := ASet;
  finally
    FLock.Leave;
  end;
end;

procedure TMixerProcessor.SetPlayheadSeconds(ASeconds: Double);
begin
  FPlayheadSeconds := ASeconds;
end;

procedure TMixerProcessor.BuildOrder(out AOrder: TArray<Integer>);
var
  n, i, j, qh, qt, u, ec: Integer;
  indeg, queue: array of Integer;
  edgeFrom, edgeTo: array of Integer;   // producer -> consumer
  s, tgt: TMixStrip;

  procedure AddEdge(AFrom, ATo: Integer);
  begin
    if (AFrom < 0) or (ATo < 0) or (AFrom = ATo) then Exit;
    if ec >= Length(edgeFrom) then
    begin
      SetLength(edgeFrom, (ec + 8) * 2);
      SetLength(edgeTo, Length(edgeFrom));
    end;
    edgeFrom[ec] := AFrom;
    edgeTo[ec] := ATo;
    Inc(ec);
  end;

  function OutputConsumer(AStrip: TMixStrip): Integer;
  var
    t: TMixStrip;
  begin
    if AStrip.Kind = skMaster then Exit(-1);
    if AStrip.OutputTargetId = 0 then Exit(FModel.IndexOfMaster);
    t := FModel.StripById(AStrip.OutputTargetId);
    if t = nil then Exit(FModel.IndexOfMaster);
    Result := FModel.IndexOfStripId(t.Id);
  end;

begin
  n := FModel.StripCount;
  SetLength(indeg, n);
  SetLength(queue, n);
  SetLength(AOrder, 0);
  for i := 0 to n - 1 do indeg[i] := 0;
  ec := 0;

  for i := 0 to n - 1 do
  begin
    s := FModel.GetStrip(i);
    AddEdge(i, OutputConsumer(s));
    for j := 0 to s.SendCount - 1 do
    begin
      tgt := FModel.StripById(s.GetSend(j).TargetStripId);
      if tgt <> nil then AddEdge(i, FModel.IndexOfStripId(tgt.Id));
    end;
    { external sidechain: the key source must run before this strip }
    for j := 0 to s.InsertCount - 1 do
      if s.GetInsert(j).SidechainStripId <> 0 then
        AddEdge(FModel.IndexOfStripId(s.GetInsert(j).SidechainStripId), i);
  end;

  for i := 0 to ec - 1 do
    Inc(indeg[edgeTo[i]]);

  qh := 0; qt := 0;
  for i := 0 to n - 1 do
    if indeg[i] = 0 then begin queue[qt] := i; Inc(qt); end;
  while qh < qt do
  begin
    u := queue[qh]; Inc(qh);
    SetLength(AOrder, Length(AOrder) + 1);
    AOrder[High(AOrder)] := u;
    for i := 0 to ec - 1 do
      if edgeFrom[i] = u then
      begin
        Dec(indeg[edgeTo[i]]);
        if indeg[edgeTo[i]] = 0 then begin queue[qt] := edgeTo[i]; Inc(qt); end;
      end;
  end;

  if Length(AOrder) <> n then
    RaiseUDAW(errInvalidState, MIXER_SUBSYS,
      'mixer routing contains a cycle (output / send / sidechain feedback)');
end;

procedure TMixerProcessor.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
var
  order: TArray<Integer>;
  err: string;
  i, k, pi_: Integer;
  s: TMixStrip;
  rt: TMixStripRT;
  ins: TMixInsert;
  kind: TNodeKind;
  node: TAudioNode;
  modelIndexToPlanIndex: array of Integer;
begin
  FLock.Enter;
  try
    if not FModel.ValidateRouting(err) then
    begin
      FLastError := err;
      RaiseUDAWFmt(errInvalidState, MIXER_SUBSYS, 'mixer model invalid: %s', [err]);
    end;

    if ASampleRate > 0 then FSampleRate := ASampleRate;
    if AMaxFrames > 0 then FMaxFrames := ClampBufferFrames(AMaxFrames);
    if (AChannels > 0) and (AChannels <= UDAW_MAX_CHANNELS) then FChannels := AChannels;

    FreePlan;
    FreeAndNil(FMasterOut);
    FreeAndNil(FInputScratch);
    FMasterOut := TAudioBuffer.Create(FChannels, FMaxFrames, FSampleRate);
    FMasterOut.Clear;
    FInputScratch := TAudioBuffer.Create(FChannels, FMaxFrames, FSampleRate);

    BuildOrder(order);

    SetLength(FPlan, Length(order));
    SetLength(modelIndexToPlanIndex, FModel.StripCount);
    for i := 0 to High(modelIndexToPlanIndex) do
      modelIndexToPlanIndex[i] := -1;

    for i := 0 to High(order) do
    begin
      s := FModel.GetStrip(order[i]);
      rt := TMixStripRT.Create(s, FChannels, FMaxFrames, FSampleRate);
      rt.FPeakL.Init(FSampleRate, 20.0, FModel.MeterHoldMs,
        FModel.MeterHoldDecayDbPerSec);
      rt.FPeakR.Init(FSampleRate, 20.0, FModel.MeterHoldMs,
        FModel.MeterHoldDecayDbPerSec);
      FPlan[i] := rt;
      modelIndexToPlanIndex[order[i]] := i;

      { inserts }
      SetLength(rt.FInserts, s.InsertCount);
      for k := 0 to s.InsertCount - 1 do
      begin
        ins := s.GetInsert(k);
        if not NodeKindFromId(ins.Kind, kind) then
          RaiseUDAWFmt(errConfig, MIXER_SUBSYS,
            'strip "%s" insert %d: unknown processor kind "%s"', [s.Name, k, ins.Kind]);
        if not InsertKindAllowed(kind) then
          RaiseUDAWFmt(errConfig, MIXER_SUBSYS,
            'strip "%s" insert %d: "%s" is a routing node, not an insert processor',
            [s.Name, k, ins.Kind]);
        node := CreateNode(k + 1, kind, '');
        rt.FInserts[k] := node;
        node.DeserializeParams(ins.Params);
        node.Bypass := ins.Bypass;
        node.Configure(FSampleRate, FMaxFrames, FChannels);
      end;
      SetLength(rt.FInsertScPlanIndex, s.InsertCount);
    end;

    { resolve output + send target plan indices now that every strip is placed }
    for i := 0 to High(FPlan) do
    begin
      rt := FPlan[i];
      s := rt.FStrip;
      if rt.FIsMaster then
        rt.FOutputPlanIndex := -1
      else if s.OutputTargetId = 0 then
        rt.FOutputPlanIndex := modelIndexToPlanIndex[FModel.IndexOfMaster]
      else
        rt.FOutputPlanIndex := modelIndexToPlanIndex[FModel.IndexOfStripId(s.OutputTargetId)];

      SetLength(rt.FSends, s.SendCount);
      for k := 0 to s.SendCount - 1 do
      begin
        rt.FSends[k].Send := s.GetSend(k);
        pi_ := FModel.IndexOfStripId(s.GetSend(k).TargetStripId);
        if pi_ >= 0 then
          rt.FSends[k].TargetPlanIndex := modelIndexToPlanIndex[pi_]
        else
          rt.FSends[k].TargetPlanIndex := -1;
      end;

      { resolve external-sidechain source per insert; mark the source strip }
      for k := 0 to High(rt.FInsertScPlanIndex) do
      begin
        rt.FInsertScPlanIndex[k] := -1;
        if s.GetInsert(k).SidechainStripId <> 0 then
        begin
          pi_ := FModel.IndexOfStripId(s.GetInsert(k).SidechainStripId);
          if (pi_ >= 0) and (modelIndexToPlanIndex[pi_] >= 0) then
          begin
            rt.FInsertScPlanIndex[k] := modelIndexToPlanIndex[pi_];
            FPlan[modelIndexToPlanIndex[pi_]].FProducesScTap := True;
          end;
        end;
      end;
    end;

    FLastError := '';
    FPrepared := True;
  finally
    FLock.Leave;
  end;
end;

procedure TMixerProcessor.UpdateGraphicEqLive(AStripId, AInsertIndex: Integer;
  const AParams: string; ABypass: Boolean);
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to High(FPlan) do
      if FPlan[i].FStrip.Id = AStripId then
      begin
        if (AInsertIndex >= 0) and (AInsertIndex <= High(FPlan[i].FInserts)) and
           (FPlan[i].FInserts[AInsertIndex] is TGraphicEQNode) then
        begin
          TGraphicEQNode(FPlan[i].FInserts[AInsertIndex]).ApplyGainsLive(AParams);
          FPlan[i].FInserts[AInsertIndex].Bypass := ABypass;
        end;
        Break;
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TMixerProcessor.Reset;
var
  i, k: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to High(FPlan) do
    begin
      FPlan[i].FInbox.Clear;
      FPlan[i].FScTap.Clear;
      FPlan[i].FLastTrimLin := DbToLinear(FPlan[i].FStrip.TrimGainDb);
      FPlan[i].FLastFaderLin := DbToLinear(FPlan[i].FStrip.FaderDb);
      FPlan[i].FLastPanL := 1.0;
      FPlan[i].FLastPanR := 1.0;
      FPlan[i].FLastWidth := FPlan[i].FStrip.StereoWidth;
      FPlan[i].FPeakL.Reset;
      FPlan[i].FPeakR.Reset;
      FPlan[i].FRms.Reset;
      FPlan[i].FLoud.Reset;
      if FPlan[i].FIsMaster then
      begin
        FPlan[i].FTpL.Reset;
        FPlan[i].FTpR.Reset;
        FPlan[i].FCorr.Reset;
      end;
      FPlan[i].FStrip.ResetMeters;
      for k := 0 to High(FPlan[i].FInserts) do
        FPlan[i].FInserts[k].Reset;
    end;
    if FMasterOut <> nil then FMasterOut.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TMixerProcessor.ProcessStrip(ARt: TMixStripRT; AFrames: Integer);
var
  s: TMixStrip;
  n, ch, k, i: Integer;
  cur, other: TAudioBuffer;
  targetLin, glide, newLin: Double;
  panPos: Double;
  tl, tr: Single;
  nl, nr, w, wStart, wEnd: Double;
  pL, pR: PSingle;
  mid, sideS: Double;
  frameL, frameR: array[0..1] of Single;
  provider: IMixInputProvider;
  tgt: TMixStripRT;
  sendLin: Double;
  autoVal, gateGain: Double;
  faderDb: Double;
  readAuto: Boolean;
  lane: TAutomationLane;
  modOn: Boolean;
  modV, pk, sm: Double;
  mi: Integer;
  plug: TPluginHostBase;
begin
  s := ARt.FStrip;
  modOn := (FModulation <> nil) and FModulation.HasRoutes;
  n := AFrames;
  readAuto := (FAutomation <> nil) and (s.AutomationMode in [amRead, amTouch, amLatch]);

  ARt.FInbox.SetActiveFrames(n);
  ARt.FAccum.SetActiveFrames(n);
  ARt.FWorkA.SetActiveFrames(n);
  ARt.FWorkB.SetActiveFrames(n);

  if not ARt.FIsAudio then
  begin
    { VCA strip - no audio path; its fader is read by TMixerModel.VCATrimDb }
    ARt.FInbox.Clear;
    Exit;
  end;

  ARt.FAccum.Clear;

  { 1. dry input for input / audio-track strips }
  if (s.Kind in [skInput, skAudioTrack]) then
  begin
    provider := FProvider;
    if provider <> nil then
    begin
      FInputScratch.SetActiveFrames(n);
      FInputScratch.Clear;
      provider.RenderStripInput(s.Id, FInputScratch);
      ARt.FAccum.AddFrom(FInputScratch);
    end;
  end;

  { 2. inbound bus feeds + sends left by earlier strips }
  ARt.FAccum.AddFrom(ARt.FInbox);
  ARt.FInbox.Clear;

  cur := ARt.FAccum;

  { 3. trim gain (click-free glide) }
  targetLin := DbToLinear(s.TrimGainDb);
  glide := n / (0.001 * INSERT_GLIDE_MS * FSampleRate + n);
  if glide > 1.0 then glide := 1.0;
  newLin := ARt.FLastTrimLin + (targetLin - ARt.FLastTrimLin) * glide;
  if (Abs(newLin - 1.0) > 1.0E-7) or (Abs(ARt.FLastTrimLin - 1.0) > 1.0E-7) then
    for ch := 0 to cur.ChannelCount - 1 do
      BlockScaleRamp(PSingle(cur.ChannelPtr(ch)), ARt.FLastTrimLin, newLin, n);
  ARt.FLastTrimLin := newLin;

  { 4. polarity invert }
  if s.PolarityInvert then
    for ch := 0 to cur.ChannelCount - 1 do
      BlockScale(PSingle(cur.ChannelPtr(ch)), -1.0, n);

  { 5. insert chain (ping-pong between WorkA / WorkB) }
  for k := 0 to High(ARt.FInserts) do
  begin
    if ARt.FInserts[k].Bypass then Continue;
    { hosted VST2 / VST3 plug-ins: the lane this strip is fed from (so a plug-in instrument gets that
      lane's MIDI), then modulation and automation of their parameters (sub-index = parameter index) }
    plug := PluginHostOf(ARt.FInserts[k]);
    if plug <> nil then
    begin
      PluginNodeSetLane(ARt.FInserts[k], s.InputSourceId);
      if modOn then
        for i := 0 to FModulation.RouteCount - 1 do
          if (FModulation.GetRoute(i).StripId = s.Id) and
             (FModulation.GetRoute(i).Param = apInsertParam) and
             (FModulation.GetRoute(i).TargetIndex = k) then
          begin
            modV := FModulation.Offset(s.Id, apInsertParam, k,
              FModulation.GetRoute(i).SubIndex, FPlayheadSeconds);
            plug.SetParam(FModulation.GetRoute(i).SubIndex,
              EnsureRange(FModulation.GetRoute(i).Base + modV, 0.0, 1.0));
          end;
      if readAuto then
        for i := 0 to FAutomation.LaneCount - 1 do
        begin
          lane := FAutomation.GetLane(i);
          if (lane.StripId = s.Id) and (lane.Param = apInsertParam) and
             (lane.TargetIndex = k) and (lane.PointCount > 0) then
            plug.SetParam(lane.SubIndex, lane.Evaluate(FPlayheadSeconds));
        end;
    end;
    { Python plug-in parameters: sub-index = the parameter's position, values 0..1 }
    if (ARt.FInserts[k] is TPythonNode) and (TPythonNode(ARt.FInserts[k]).Host <> nil) then
    begin
      if modOn then
        for i := 0 to FModulation.RouteCount - 1 do
          if (FModulation.GetRoute(i).StripId = s.Id) and
             (FModulation.GetRoute(i).Param = apInsertParam) and
             (FModulation.GetRoute(i).TargetIndex = k) then
          begin
            modV := FModulation.Offset(s.Id, apInsertParam, k,
              FModulation.GetRoute(i).SubIndex, FPlayheadSeconds);
            TPythonNode(ARt.FInserts[k]).Host.SetParamNorm(FModulation.GetRoute(i).SubIndex,
              EnsureRange(FModulation.GetRoute(i).Base + modV, 0.0, 1.0));
          end;
      if readAuto then
        for i := 0 to FAutomation.LaneCount - 1 do
        begin
          lane := FAutomation.GetLane(i);
          if (lane.StripId = s.Id) and (lane.Param = apInsertParam) and
             (lane.TargetIndex = k) and (lane.PointCount > 0) then
            TPythonNode(ARt.FInserts[k]).Host.SetParamNorm(lane.SubIndex,
              lane.Evaluate(FPlayheadSeconds));
        end;
    end;
    if (k <= High(ARt.FInsertScPlanIndex)) and (ARt.FInsertScPlanIndex[k] >= 0) then
      ARt.FInserts[k].SetSidechain(FPlan[ARt.FInsertScPlanIndex[k]].FScTap)
    else
      ARt.FInserts[k].SetSidechain(nil);
    if Odd(k) then other := ARt.FWorkB else other := ARt.FWorkA;
    { first insert reads from FAccum; keep alternating from there on }
    other.SetActiveFrames(n);
    ARt.FInserts[k].Process(cur, other);
    cur := other;
  end;

  { 5b. publish the post-insert / pre-fader signal for any strip keying a
    sidechain off it - so the key can still be faded down in the mix }
  if ARt.FProducesScTap then
  begin
    ARt.FScTap.SetActiveFrames(n);
    ARt.FScTap.CopyFrom(cur);
  end;

  { 6. pre-fader sends }
  for i := 0 to High(ARt.FSends) do
    if ARt.FSends[i].Send.Enabled and (ARt.FSends[i].Send.Mode = smPreFader)
       and (ARt.FSends[i].TargetPlanIndex >= 0) then
    begin
      autoVal := ARt.FSends[i].Send.GainDb;
      if readAuto then
        FAutomation.TryEvaluate(s.Id, apSendGain, FPlayheadSeconds, autoVal,
          ARt.FSends[i].Send.TargetStripId);
      sendLin := DbToLinear(autoVal);
      tgt := FPlan[ARt.FSends[i].TargetPlanIndex];
      tgt.FInbox.SetActiveFrames(n);
      tgt.FInbox.MixFrom(cur, sendLin);
    end;

  { 7. stereo width (M/S) then constant-power pan - stereo only }
  if cur.ChannelCount >= 2 then
  begin
    wEnd := s.StereoWidth;
    wStart := ARt.FLastWidth;
    if (Abs(wStart - 1.0) > 1.0E-6) or (Abs(wEnd - 1.0) > 1.0E-6) then
    begin
      pL := PSingle(cur.ChannelPtr(0));
      pR := PSingle(cur.ChannelPtr(1));
      for i := 0 to n - 1 do
      begin
        if n <= 1 then w := wEnd else w := wStart + (wEnd - wStart) * (i / (n - 1));
        mid := 0.5 * (pL[i] + pR[i]);
        sideS := 0.5 * (pL[i] - pR[i]) * w;
        pL[i] := Single(mid + sideS);
        pR[i] := Single(mid - sideS);
      end;
    end;
    ARt.FLastWidth := wEnd;

    panPos := s.Pan;
    if readAuto and FAutomation.TryEvaluate(s.Id, apPan, FPlayheadSeconds, autoVal) then
      panPos := autoVal;
    if modOn then
      panPos := EnsureRange(panPos + FModulation.Offset(s.Id, apPan, 0, 0, FPlayheadSeconds), -1.0, 1.0);
    StripPlacementGains(s.Kind, panPos, tl, tr);
    nl := ARt.FLastPanL + (tl - ARt.FLastPanL) * glide;
    nr := ARt.FLastPanR + (tr - ARt.FLastPanR) * glide;
    BlockScaleRamp(PSingle(cur.ChannelPtr(0)), ARt.FLastPanL, nl, n);
    BlockScaleRamp(PSingle(cur.ChannelPtr(1)), ARt.FLastPanR, nr, n);
    ARt.FLastPanL := nl;
    ARt.FLastPanR := nr;
  end;

  { 8. fader * VCA trim * mute/solo gate (click-free) }
  faderDb := s.FaderDb;
  if readAuto and FAutomation.TryEvaluate(s.Id, apFader, FPlayheadSeconds, autoVal) then
    faderDb := autoVal;
  if readAuto and FAutomation.TryEvaluate(s.Id, apMute, FPlayheadSeconds, autoVal) then
  begin
    if autoVal >= 0.5 then gateGain := 0.0 else gateGain := 1.0;
    if FModel.AnySolo and (not s.Soloed) and (s.Kind <> skMaster) then
      gateGain := 0.0;
  end
  else
    gateGain := FModel.GateGain(s);
  if modOn then
    faderDb := faderDb + FModulation.Offset(s.Id, apFader, 0, 0, FPlayheadSeconds);
  { envelope followers watching this strip see its pre-fader level }
  if (FModulation <> nil) and (cur.ChannelCount > 0) then
  begin
    pk := 0;
    pL := PSingle(cur.ChannelPtr(0));
    for i := 0 to n - 1 do
    begin
      sm := Abs(pL[i]);
      if sm > pk then pk := sm;
    end;
    for mi := 0 to FModulation.ModCount - 1 do
      if (FModulation.GetMod(mi).Kind = mkFollower) and
         (FModulation.GetMod(mi).FollowStripId = s.Id) then
        FModulation.GetMod(mi).FeedLevel(pk, n / Max(FSampleRate, 1));
  end;
  targetLin := DbToLinear(faderDb + FModel.VCATrimDb(s)) * gateGain;
  newLin := ARt.FLastFaderLin + (targetLin - ARt.FLastFaderLin) * glide;
  for ch := 0 to cur.ChannelCount - 1 do
    BlockScaleRamp(PSingle(cur.ChannelPtr(ch)), ARt.FLastFaderLin, newLin, n);
  ARt.FLastFaderLin := newLin;

  { 9. metering on the post-fader signal }
  ARt.FPeakL.PushBlock(PSingle(cur.ChannelPtr(0)), n);
  if cur.ChannelCount >= 2 then
    ARt.FPeakR.PushBlock(PSingle(cur.ChannelPtr(1)), n)
  else
    ARt.FPeakR.PushBlock(PSingle(cur.ChannelPtr(0)), n);
  ARt.FRms.PushBlock(PSingle(cur.ChannelPtr(0)), n);
  for i := 0 to n - 1 do
  begin
    frameL[0] := cur.ChannelPtr(0)[i];
    if cur.ChannelCount >= 2 then
    begin
      frameR[0] := cur.ChannelPtr(1)[i];
      frameL[1] := frameR[0];
    end
    else
      frameL[1] := frameL[0];
    ARt.FLoud.PushFrame(frameL);
  end;
  s.MeterPeakDbL := ARt.FPeakL.ValueDb;
  s.MeterPeakDbR := ARt.FPeakR.ValueDb;
  s.MeterRmsDb := ARt.FRms.ValueDb;
  s.MeterLufs := ARt.FLoud.Momentary;
  s.MeterLufsIntegrated := ARt.FLoud.Integrated;
  if ARt.FIsMaster then
  begin
    ARt.FTpL.PushBlock(PSingle(cur.ChannelPtr(0)), n);
    if cur.ChannelCount >= 2 then
    begin
      ARt.FTpR.PushBlock(PSingle(cur.ChannelPtr(1)), n);
      ARt.FCorr.PushBlock(PSingle(cur.ChannelPtr(0)), PSingle(cur.ChannelPtr(1)), n);
    end
    else
    begin
      ARt.FTpR.PushBlock(PSingle(cur.ChannelPtr(0)), n);
      ARt.FCorr.PushBlock(PSingle(cur.ChannelPtr(0)), PSingle(cur.ChannelPtr(0)), n);
    end;
    s.MeterTruePeakDb := Max(ARt.FTpL.ValueDb, ARt.FTpR.ValueDb);
    s.MeterCorrelation := ARt.FCorr.Value;
    s.MeterLufsShort := ARt.FLoud.ShortTerm;
  end;
  s.MeterHoldDbL := ARt.FPeakL.HoldDb;
  s.MeterHoldDbR := ARt.FPeakR.HoldDb;
  { latching clip LEDs: only the engine ever sets these True - see
    TMixStrip.ResetClip for the click-to-reset UI seam }
  if s.MeterPeakDbL >= 0.0 then s.ClipL := True;
  if s.MeterPeakDbR >= 0.0 then s.ClipR := True;

  { 10. post-fader sends }
  for i := 0 to High(ARt.FSends) do
    if ARt.FSends[i].Send.Enabled and (ARt.FSends[i].Send.Mode = smPostFader)
       and (ARt.FSends[i].TargetPlanIndex >= 0) then
    begin
      autoVal := ARt.FSends[i].Send.GainDb;
      if readAuto then
        FAutomation.TryEvaluate(s.Id, apSendGain, FPlayheadSeconds, autoVal,
          ARt.FSends[i].Send.TargetStripId);
      sendLin := DbToLinear(autoVal);
      tgt := FPlan[ARt.FSends[i].TargetPlanIndex];
      tgt.FInbox.SetActiveFrames(n);
      tgt.FInbox.MixFrom(cur, sendLin);
    end;

  { 11. hand the post-fader signal to the output-target bus / master }
  if ARt.FIsMaster then
    FMasterOut.CopyFrom(cur)
  else if ARt.FOutputPlanIndex >= 0 then
  begin
    tgt := FPlan[ARt.FOutputPlanIndex];
    tgt.FInbox.SetActiveFrames(n);
    tgt.FInbox.AddFrom(cur);
  end;
end;

procedure TMixerProcessor.ProcessBlock(AOut: TAudioBuffer);
var
  i, n: Integer;
begin
  if not FPrepared then
  begin
    AOut.Clear;
    Exit;
  end;
  n := AOut.FrameCount;
  if n > FMaxFrames then n := FMaxFrames;
  FMasterOut.SetActiveFrames(n);
  FMasterOut.Clear;
  for i := 0 to High(FPlan) do
    ProcessStrip(FPlan[i], n);
  AOut.CopyFrom(FMasterOut);
  if FSampleRate > 0 then
    FPlayheadSeconds := FPlayheadSeconds + n / FSampleRate;
end;

function TMixerProcessor.RenderToPlanar(ATotalFrames, ABlockFrames: Integer): TAudioPlanar;
var
  buf: TAudioBuffer;
  done, n, ch, i: Integer;
begin
  if ATotalFrames < 0 then ATotalFrames := 0;
  ABlockFrames := ClampBufferFrames(ABlockFrames);
  SetLength(Result, FChannels);
  for ch := 0 to FChannels - 1 do
    SetLength(Result[ch], ATotalFrames);
  buf := TAudioBuffer.Create(FChannels, ABlockFrames, FSampleRate);
  try
    Reset;
    done := 0;
    while done < ATotalFrames do
    begin
      n := ATotalFrames - done;
      if n > ABlockFrames then n := ABlockFrames;
      buf.SetActiveFrames(n);
      buf.Clear;
      ProcessBlock(buf);
      for ch := 0 to FChannels - 1 do
        for i := 0 to n - 1 do
          Result[ch][done + i] := buf.ChannelPtr(ch)[i];
      Inc(done, n);
    end;
  finally
    buf.Free;
  end;
end;

function TMixerProcessor.IsPrepared: Boolean;
begin
  Result := FPrepared;
end;

function TMixerProcessor.StripRTCount: Integer;
begin
  Result := Length(FPlan);
end;

end.
