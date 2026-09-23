unit UDAW.Audio.Graph;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 4 - the master audio processing graph.

  TAudioGraph owns a set of TAudioNode objects and the connections between
  them. Editing (add / remove / connect / disconnect) happens on any non-audio
  thread under FEditLock. Nothing the RT thread touches is mutated in place:
  a successful Compile builds a fresh immutable TCompiledGraph (topologically
  ordered steps + preallocated scratch buffers) and publishes it with a single
  atomic store into a double-buffered slot. The render callback reads the
  active slot index once per block and walks that plan; it never allocates,
  locks or blocks.

  Validation rejects: a graph without exactly one Output node, connections to
  a generator/input node, channel counts a node cannot run, an Output with no
  upstream (a "missing source"), duplicate edges, self-edges, dangling
  endpoints, and any cycle (illegal feedback / circular dependency).

  A graph is played through the device engine by handing AsSource to
  TAudioEngine.SetSource, and rendered deterministically offline with
  RenderSourceOffline(graph.AsSource, ...). }

interface

uses
  SysUtils, Classes,
  UDAW.Errors, UDAW.Threading,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Source,
  UDAW.Audio.Graph.Nodes;

type
  TGraphConn = record
    FromId: Integer;
    ToId: Integer;
  end;

  { ---- compiled (immutable, RT-read-only) plan ---- }

  TGraphStep = record
    Node: TAudioNode;
    Sources: array of Integer;   // indices of earlier steps to sum into the input
    IsInput: Boolean;
    IsOutput: Boolean;
  end;

  TCompiledGraph = class
  private
    FSteps: array of TGraphStep;
    FBuffers: array of TAudioBuffer;   // one output buffer per step
    FMix: TAudioBuffer;                // shared fan-in scratch
    FChannels, FMaxFrames, FSampleRate: Integer;
    FOutStep: Integer;
  public
    constructor Create(AChannels, AMaxFrames, ASampleRate, AStepCount: Integer);
    destructor Destroy; override;
    { RT-safe: render one block. AExternalIn may be nil. }
    procedure Render(AOut, AExternalIn: TAudioBuffer);
    function StepCount: Integer;
    function StepNode(AIndex: Integer): TAudioNode;
    function DescribeStep(AIndex: Integer): string;
  end;

  TAudioGraph = class
  private
    FEditLock: TUDAWLock;
    FNodes: array of TAudioNode;
    FRetired: array of TAudioNode;     // removed nodes awaiting a safe free
    FConns: array of TGraphConn;
    FChannels: Integer;
    FSampleRate: Integer;
    FMaxFrames: Integer;
    FNextId: Integer;
    FPlans: array[0..1] of TCompiledGraph;
    FActiveIdx: Integer;               // atomic; -1 = no plan yet
    FExternalInput: TAudioBuffer;      // not owned
    FSourceAdapter: IAudioSource;
    FLastError: string;
    FDirty: Boolean;
    FCompileGen: Int64;

    function IndexOfNode(AId: Integer): Integer;
    function FindConn(AFromId, AToId: Integer): Integer;
    function OutputCount: Integer;
    function HasCycle(out AWhere: string): Boolean;
    function BuildPlan(out AError: string): TCompiledGraph;
    procedure FreeRetired;
    procedure FreeAllPlans;
  public
    constructor Create(AChannels: Integer = 2);
    destructor Destroy; override;

    { ---- structural editing (off the RT thread) ---- }
    function AddNode(AKind: TNodeKind; const AName: string = ''): TAudioNode;
    { Add a node keeping an explicit id (used by the serializer so CONN records
      resolve). Ids must be unique; FNextId advances past AId. }
    function AddNodeWithId(AId: Integer; AKind: TNodeKind; const AName: string): TAudioNode;
    procedure RemoveNode(AId: Integer);
    procedure Connect(AFromId, AToId: Integer);
    procedure Disconnect(AFromId, AToId: Integer);
    procedure ClearGraph;

    { Validate without mutating anything. }
    function Validate(out AError: string): Boolean;
    { Validate, build a fresh plan and atomically publish it. Returns False and
      sets LastError on any validation failure (the previous plan keeps
      running). }
    function Compile: Boolean;

    { Size every node's runtime state to this geometry, then Compile. Called by
      the engine via the source adapter, and directly by offline renders. }
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;

    { RT: render the active plan into AOut. Silence if nothing is compiled. }
    procedure Process(AOut: TAudioBuffer);
    procedure SetExternalInput(ABuffer: TAudioBuffer);

    function AsSource: IAudioSource;

    { ---- introspection ---- }
    function NodeCount: Integer;
    function GetNode(AIndex: Integer): TAudioNode;
    function NodeById(AId: Integer): TAudioNode;
    function ConnectionCount: Integer;
    function GetConnection(AIndex: Integer): TGraphConn;
    function CompiledStepCount: Integer;
    function CompiledStepText(AIndex: Integer): string;
    { Structured view of one compiled step - for the graph visualiser. }
    function CompiledStep(AIndex: Integer; out AKindId, AName: string;
      out ASources: TArray<Integer>): Boolean;
    { Live level of a compiled step that is a meter tap (dBFS RMS), or
      METER_MIN_DB when the step is not a meter. }
    function CompiledStepLevelDb(AIndex: Integer): Double;
    function IsCompiled: Boolean;
    function Describe: string;

    property Channels: Integer read FChannels;
    property SampleRate: Integer read FSampleRate;
    property MaxFrames: Integer read FMaxFrames;
    property LastError: string read FLastError;
    property Dirty: Boolean read FDirty;
    property CompileGeneration: Int64 read FCompileGen;
  end;

  { IAudioSource adapter so a graph can drive the device engine. }
  TGraphSource = class(TInterfacedObject, IAudioSource)
  private
    FGraph: TAudioGraph;   // not owned
  public
    constructor Create(AGraph: TAudioGraph);
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;
  end;

implementation

const
  PLAN_RETIRE_MS = 20;   { one edit is rare; wait out any in-flight RT block
                           before freeing the plan / nodes it referenced. }

{ small helper - keeps Describe readable }
function BoolToStrTag(AValue: Boolean; const ATag: string): string;
begin
  if AValue then Result := ATag else Result := '';
end;

{ ================= TCompiledGraph ================= }

constructor TCompiledGraph.Create(AChannels, AMaxFrames, ASampleRate, AStepCount: Integer);
var
  i: Integer;
begin
  inherited Create;
  if AChannels < 1 then AChannels := 1;
  if AMaxFrames < 1 then AMaxFrames := 1;
  FChannels := AChannels;
  FMaxFrames := AMaxFrames;
  FSampleRate := ASampleRate;
  FOutStep := -1;
  SetLength(FSteps, AStepCount);
  SetLength(FBuffers, AStepCount);
  for i := 0 to AStepCount - 1 do
    FBuffers[i] := TAudioBuffer.Create(AChannels, AMaxFrames, ASampleRate);
  FMix := TAudioBuffer.Create(AChannels, AMaxFrames, ASampleRate);
end;

destructor TCompiledGraph.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FBuffers) do
    FBuffers[i].Free;
  SetLength(FBuffers, 0);
  FMix.Free;
  inherited Destroy;
end;

procedure TCompiledGraph.Render(AOut, AExternalIn: TAudioBuffer);
var
  i, j, n: Integer;
begin
  n := AOut.FrameCount;
  if Length(FSteps) = 0 then
  begin
    AOut.Clear;
    Exit;
  end;
  if n > FMaxFrames then n := FMaxFrames;
  FMix.SetActiveFrames(n);

  for i := 0 to High(FSteps) do
  begin
    FBuffers[i].SetActiveFrames(n);

    { build this step's summed input into FMix }
    if FSteps[i].IsInput then
    begin
      if AExternalIn <> nil then
        FMix.CopyFrom(AExternalIn)
      else
        FMix.Clear;
    end
    else
    begin
      FMix.Clear;
      for j := 0 to High(FSteps[i].Sources) do
        FMix.AddFrom(FBuffers[FSteps[i].Sources[j]]);
    end;

    { produce this step's output }
    if FSteps[i].Node.Mute then
      FBuffers[i].Clear
    else if FSteps[i].Node.Bypass then
      FBuffers[i].CopyFrom(FMix)
    else
      FSteps[i].Node.Process(FMix, FBuffers[i]);
  end;

  if (FOutStep >= 0) and (FOutStep <= High(FBuffers)) then
    AOut.CopyFrom(FBuffers[FOutStep])
  else
    AOut.Clear;
end;

function TCompiledGraph.StepCount: Integer;
begin
  Result := Length(FSteps);
end;

function TCompiledGraph.StepNode(AIndex: Integer): TAudioNode;
begin
  if (AIndex >= 0) and (AIndex <= High(FSteps)) then
    Result := FSteps[AIndex].Node
  else
    Result := nil;
end;

function TCompiledGraph.DescribeStep(AIndex: Integer): string;
var
  s: string;
  j: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FSteps)) then Exit('');
  s := '';
  for j := 0 to High(FSteps[AIndex].Sources) do
  begin
    if s <> '' then s := s + ',';
    s := s + IntToStr(FSteps[AIndex].Sources[j]);
  end;
  if FSteps[AIndex].IsInput then s := '(external in)'
  else if s = '' then s := '(silence)';
  Result := Format('%2d  %-12s  %-16s  <- %s',
    [AIndex, NodeKindId(FSteps[AIndex].Node.Kind), FSteps[AIndex].Node.Name, s]);
end;

{ ================= TAudioGraph ================= }

constructor TAudioGraph.Create(AChannels: Integer);
begin
  inherited Create;
  if AChannels < 1 then AChannels := 1
  else if AChannels > UDAW_MAX_CHANNELS then AChannels := UDAW_MAX_CHANNELS;
  FEditLock := TUDAWLock.Create('audiograph');
  FChannels := AChannels;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FMaxFrames := UDAW_DEFAULT_BUFFER_FRAMES;
  FNextId := 1;
  FActiveIdx := -1;
  FDirty := True;
end;

destructor TAudioGraph.Destroy;
var
  i: Integer;
begin
  FSourceAdapter := nil;
  FreeAllPlans;
  for i := 0 to High(FNodes) do
    FNodes[i].Free;
  SetLength(FNodes, 0);
  FreeRetired;
  FEditLock.Free;
  inherited Destroy;
end;

procedure TAudioGraph.FreeAllPlans;
var
  i: Integer;
begin
  AtomicSet32(FActiveIdx, -1);
  for i := 0 to 1 do
    FreeAndNil(FPlans[i]);
end;

procedure TAudioGraph.FreeRetired;
var
  i: Integer;
begin
  for i := 0 to High(FRetired) do
    FRetired[i].Free;
  SetLength(FRetired, 0);
end;

function TAudioGraph.IndexOfNode(AId: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FNodes) do
    if FNodes[i].Id = AId then Exit(i);
  Result := -1;
end;

function TAudioGraph.FindConn(AFromId, AToId: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FConns) do
    if (FConns[i].FromId = AFromId) and (FConns[i].ToId = AToId) then Exit(i);
  Result := -1;
end;

function TAudioGraph.OutputCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FNodes) do
    if FNodes[i].Kind = nkOutput then Inc(Result);
end;

function TAudioGraph.AddNode(AKind: TNodeKind; const AName: string): TAudioNode;
begin
  FEditLock.Enter;
  try
    Result := CreateNode(FNextId, AKind, AName);
    Inc(FNextId);
    SetLength(FNodes, Length(FNodes) + 1);
    FNodes[High(FNodes)] := Result;
    FDirty := True;
  finally
    FEditLock.Leave;
  end;
end;

function TAudioGraph.AddNodeWithId(AId: Integer; AKind: TNodeKind;
  const AName: string): TAudioNode;
begin
  FEditLock.Enter;
  try
    if IndexOfNode(AId) >= 0 then
      RaiseUDAWFmt(errInvalidArgument, GRAPH_SUBSYS,
        'AddNodeWithId: id %d already in use', [AId]);
    Result := CreateNode(AId, AKind, AName);
    SetLength(FNodes, Length(FNodes) + 1);
    FNodes[High(FNodes)] := Result;
    if AId >= FNextId then FNextId := AId + 1;
    FDirty := True;
  finally
    FEditLock.Leave;
  end;
end;

procedure TAudioGraph.RemoveNode(AId: Integer);
var
  idx, i, w: Integer;
begin
  FEditLock.Enter;
  try
    idx := IndexOfNode(AId);
    if idx < 0 then Exit;

    { drop every connection that touches the node }
    w := 0;
    for i := 0 to High(FConns) do
      if (FConns[i].FromId <> AId) and (FConns[i].ToId <> AId) then
      begin
        FConns[w] := FConns[i];
        Inc(w);
      end;
    SetLength(FConns, w);

    { retire (not free) - the active plan may still reference it until the
      next Compile publishes a plan that does not }
    SetLength(FRetired, Length(FRetired) + 1);
    FRetired[High(FRetired)] := FNodes[idx];
    for i := idx to High(FNodes) - 1 do
      FNodes[i] := FNodes[i + 1];
    SetLength(FNodes, Length(FNodes) - 1);
    FDirty := True;
  finally
    FEditLock.Leave;
  end;
end;

procedure TAudioGraph.Connect(AFromId, AToId: Integer);
var
  fi, ti: Integer;
begin
  FEditLock.Enter;
  try
    fi := IndexOfNode(AFromId);
    ti := IndexOfNode(AToId);
    if (fi < 0) or (ti < 0) then
      RaiseUDAWFmt(errInvalidArgument, GRAPH_SUBSYS,
        'Connect: node %d or %d does not exist', [AFromId, AToId]);
    if AFromId = AToId then
      RaiseUDAWFmt(errInvalidState, GRAPH_SUBSYS,
        'Connect: node %d cannot connect to itself', [AFromId]);
    if not FNodes[ti].AcceptsInput then
      RaiseUDAWFmt(errInvalidState, GRAPH_SUBSYS,
        'Connect: node "%s" (%s) does not accept an input connection',
        [FNodes[ti].Name, NodeKindId(FNodes[ti].Kind)]);
    if FindConn(AFromId, AToId) >= 0 then Exit;   // idempotent
    SetLength(FConns, Length(FConns) + 1);
    FConns[High(FConns)].FromId := AFromId;
    FConns[High(FConns)].ToId := AToId;
    FDirty := True;
  finally
    FEditLock.Leave;
  end;
end;

procedure TAudioGraph.Disconnect(AFromId, AToId: Integer);
var
  ci, i: Integer;
begin
  FEditLock.Enter;
  try
    ci := FindConn(AFromId, AToId);
    if ci < 0 then Exit;
    for i := ci to High(FConns) - 1 do
      FConns[i] := FConns[i + 1];
    SetLength(FConns, Length(FConns) - 1);
    FDirty := True;
  finally
    FEditLock.Leave;
  end;
end;

procedure TAudioGraph.ClearGraph;
var
  i: Integer;
begin
  FEditLock.Enter;
  try
    FreeAllPlans;
    for i := 0 to High(FNodes) do
    begin
      SetLength(FRetired, Length(FRetired) + 1);
      FRetired[High(FRetired)] := FNodes[i];
    end;
    SetLength(FNodes, 0);
    SetLength(FConns, 0);
    FNextId := 1;
    FDirty := True;
  finally
    FEditLock.Leave;
  end;
end;

function TAudioGraph.HasCycle(out AWhere: string): Boolean;
var
  n, i, u, v, qh, qt, produced: Integer;
  indeg, queue: array of Integer;
begin
  AWhere := '';
  n := Length(FNodes);
  if n = 0 then Exit(False);
  SetLength(indeg, n);
  SetLength(queue, n);
  for i := 0 to n - 1 do indeg[i] := 0;
  for i := 0 to High(FConns) do
  begin
    v := IndexOfNode(FConns[i].ToId);
    if v >= 0 then Inc(indeg[v]);
  end;
  qh := 0; qt := 0;
  for i := 0 to n - 1 do
    if indeg[i] = 0 then begin queue[qt] := i; Inc(qt); end;
  produced := 0;
  while qh < qt do
  begin
    u := queue[qh]; Inc(qh);
    Inc(produced);
    for i := 0 to High(FConns) do
      if FConns[i].FromId = FNodes[u].Id then
      begin
        v := IndexOfNode(FConns[i].ToId);
        if v >= 0 then
        begin
          Dec(indeg[v]);
          if indeg[v] = 0 then begin queue[qt] := v; Inc(qt); end;
        end;
      end;
  end;
  Result := produced <> n;
  if Result then
  begin
    for i := 0 to n - 1 do
      if indeg[i] > 0 then
      begin
        AWhere := FNodes[i].Name;
        Break;
      end;
  end;
end;

function TAudioGraph.Validate(out AError: string): Boolean;
var
  i, fi, ti, oc, inbound: Integer;
  where: string;
begin
  AError := '';
  FEditLock.Enter;
  try
    if (FChannels < 1) or (FChannels > UDAW_MAX_CHANNELS) then
    begin
      AError := Format('invalid channel count %d', [FChannels]);
      Exit(False);
    end;
    if Length(FNodes) = 0 then
    begin
      AError := 'graph is empty';
      Exit(False);
    end;

    oc := OutputCount;
    if oc <> 1 then
    begin
      AError := Format('graph needs exactly one Output node (found %d)', [oc]);
      Exit(False);
    end;

    for i := 0 to High(FNodes) do
      if not FNodes[i].SupportsChannels(FChannels) then
      begin
        AError := Format('channel mismatch: node "%s" (%s) cannot run at %d channels',
          [FNodes[i].Name, NodeKindId(FNodes[i].Kind), FChannels]);
        Exit(False);
      end;

    for i := 0 to High(FConns) do
    begin
      fi := IndexOfNode(FConns[i].FromId);
      ti := IndexOfNode(FConns[i].ToId);
      if (fi < 0) or (ti < 0) then
      begin
        AError := Format('dangling connection %d -> %d',
          [FConns[i].FromId, FConns[i].ToId]);
        Exit(False);
      end;
      if FConns[i].FromId = FConns[i].ToId then
      begin
        AError := Format('self connection on node "%s"', [FNodes[fi].Name]);
        Exit(False);
      end;
      if not FNodes[ti].AcceptsInput then
      begin
        AError := Format('node "%s" (%s) does not accept an input connection',
          [FNodes[ti].Name, NodeKindId(FNodes[ti].Kind)]);
        Exit(False);
      end;
    end;

    { the single Output must have something upstream (missing-source check) }
    for i := 0 to High(FNodes) do
      if FNodes[i].Kind = nkOutput then
      begin
        inbound := 0;
        for ti := 0 to High(FConns) do
          if FConns[ti].ToId = FNodes[i].Id then Inc(inbound);
        if inbound = 0 then
        begin
          AError := 'Output node has no input (missing source)';
          Exit(False);
        end;
      end;

    if HasCycle(where) then
    begin
      AError := Format('cycle detected (illegal feedback) involving node "%s"', [where]);
      Exit(False);
    end;

    Result := True;
  finally
    FEditLock.Leave;
  end;
end;

function TAudioGraph.BuildPlan(out AError: string): TCompiledGraph;
var
  n, i, u, v, qh, qt, k: Integer;
  indeg, queue, order, orderPos: array of Integer;
  plan: TCompiledGraph;
  cnt: Integer;
begin
  Result := nil;
  if not Validate(AError) then Exit;

  n := Length(FNodes);
  SetLength(indeg, n);
  SetLength(queue, n);
  SetLength(order, 0);
  SetLength(orderPos, n);
  for i := 0 to n - 1 do begin indeg[i] := 0; orderPos[i] := -1; end;
  for i := 0 to High(FConns) do
  begin
    v := IndexOfNode(FConns[i].ToId);
    if v >= 0 then Inc(indeg[v]);
  end;
  qh := 0; qt := 0;
  for i := 0 to n - 1 do
    if indeg[i] = 0 then begin queue[qt] := i; Inc(qt); end;
  while qh < qt do
  begin
    u := queue[qh]; Inc(qh);
    SetLength(order, Length(order) + 1);
    order[High(order)] := u;
    for i := 0 to High(FConns) do
      if FConns[i].FromId = FNodes[u].Id then
      begin
        v := IndexOfNode(FConns[i].ToId);
        if v >= 0 then
        begin
          Dec(indeg[v]);
          if indeg[v] = 0 then begin queue[qt] := v; Inc(qt); end;
        end;
      end;
  end;
  if Length(order) <> n then
  begin
    AError := 'cycle detected while ordering the graph';
    Exit;
  end;
  for i := 0 to n - 1 do
    orderPos[order[i]] := i;

  plan := TCompiledGraph.Create(FChannels, FMaxFrames, FSampleRate, n);
  try
    for i := 0 to n - 1 do
    begin
      plan.FSteps[i].Node := FNodes[order[i]];
      plan.FSteps[i].IsInput := FNodes[order[i]].Kind = nkInput;
      plan.FSteps[i].IsOutput := FNodes[order[i]].Kind = nkOutput;
      if plan.FSteps[i].IsOutput then
        plan.FOutStep := i;
      cnt := 0;
      SetLength(plan.FSteps[i].Sources, 0);
      for k := 0 to High(FConns) do
        if FConns[k].ToId = FNodes[order[i]].Id then
        begin
          v := IndexOfNode(FConns[k].FromId);
          if v >= 0 then
          begin
            SetLength(plan.FSteps[i].Sources, cnt + 1);
            plan.FSteps[i].Sources[cnt] := orderPos[v];
            Inc(cnt);
          end;
        end;
    end;
  except
    plan.Free;
    raise;
  end;
  Result := plan;
end;

function TAudioGraph.Compile: Boolean;
var
  plan, old: TCompiledGraph;
  err: string;
  cur, slot: Integer;
begin
  FEditLock.Enter;
  try
    plan := BuildPlan(err);
    if plan = nil then
    begin
      FLastError := err;
      Exit(False);
    end;

    cur := AtomicRead32(FActiveIdx);
    if (cur < 0) or (cur > 1) then slot := 0 else slot := 1 - cur;
    old := FPlans[slot];

    FPlans[slot] := plan;
    AtomicSet32(FActiveIdx, slot);   // publish

    if old <> nil then
    begin
      Sleep(PLAN_RETIRE_MS);          // let any in-flight RT block on `old` finish
      old.Free;
    end;
    FreeRetired;                      // nodes the just-freed plan may have held

    FLastError := '';
    FDirty := False;
    Inc(FCompileGen);
    Result := True;
  finally
    FEditLock.Leave;
  end;
end;

procedure TAudioGraph.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
var
  i: Integer;
begin
  FEditLock.Enter;
  try
    if ASampleRate > 0 then FSampleRate := ASampleRate;
    if AMaxFrames > 0 then FMaxFrames := AMaxFrames;
    if (AChannels > 0) and (AChannels <= UDAW_MAX_CHANNELS) then
      FChannels := AChannels;
    for i := 0 to High(FNodes) do
      FNodes[i].Configure(FSampleRate, FMaxFrames, FChannels);
  finally
    FEditLock.Leave;
  end;
  Compile;
end;

procedure TAudioGraph.Reset;
var
  i: Integer;
begin
  FEditLock.Enter;
  try
    for i := 0 to High(FNodes) do
      FNodes[i].Reset;
  finally
    FEditLock.Leave;
  end;
end;

procedure TAudioGraph.Process(AOut: TAudioBuffer);
var
  idx: Integer;
  plan: TCompiledGraph;
begin
  idx := AtomicRead32(FActiveIdx);
  if (idx < 0) or (idx > 1) then
  begin
    AOut.Clear;
    Exit;
  end;
  plan := FPlans[idx];
  if plan = nil then
  begin
    AOut.Clear;
    Exit;
  end;
  plan.Render(AOut, FExternalInput);
end;

procedure TAudioGraph.SetExternalInput(ABuffer: TAudioBuffer);
begin
  FExternalInput := ABuffer;
end;

function TAudioGraph.AsSource: IAudioSource;
begin
  if FSourceAdapter = nil then
    FSourceAdapter := TGraphSource.Create(Self);
  Result := FSourceAdapter;
end;

function TAudioGraph.NodeCount: Integer;
begin
  Result := Length(FNodes);
end;

function TAudioGraph.GetNode(AIndex: Integer): TAudioNode;
begin
  if (AIndex >= 0) and (AIndex <= High(FNodes)) then
    Result := FNodes[AIndex]
  else
    Result := nil;
end;

function TAudioGraph.NodeById(AId: Integer): TAudioNode;
var
  i: Integer;
begin
  i := IndexOfNode(AId);
  if i >= 0 then Result := FNodes[i] else Result := nil;
end;

function TAudioGraph.ConnectionCount: Integer;
begin
  Result := Length(FConns);
end;

function TAudioGraph.GetConnection(AIndex: Integer): TGraphConn;
begin
  if (AIndex >= 0) and (AIndex <= High(FConns)) then
    Result := FConns[AIndex]
  else
  begin
    Result.FromId := 0;
    Result.ToId := 0;
  end;
end;

function TAudioGraph.CompiledStepCount: Integer;
var
  idx: Integer;
begin
  idx := AtomicRead32(FActiveIdx);
  if (idx >= 0) and (idx <= 1) and (FPlans[idx] <> nil) then
    Result := FPlans[idx].StepCount
  else
    Result := 0;
end;

function TAudioGraph.CompiledStepText(AIndex: Integer): string;
var
  idx: Integer;
begin
  idx := AtomicRead32(FActiveIdx);
  if (idx >= 0) and (idx <= 1) and (FPlans[idx] <> nil) then
    Result := FPlans[idx].DescribeStep(AIndex)
  else
    Result := '';
end;

function TAudioGraph.CompiledStep(AIndex: Integer; out AKindId, AName: string;
  out ASources: TArray<Integer>): Boolean;
var
  idx, j: Integer;
  plan: TCompiledGraph;
begin
  AKindId := '';
  AName := '';
  SetLength(ASources, 0);
  Result := False;
  idx := AtomicRead32(FActiveIdx);
  if (idx < 0) or (idx > 1) or (FPlans[idx] = nil) then Exit;
  plan := FPlans[idx];
  if (AIndex < 0) or (AIndex >= plan.StepCount) then Exit;
  AKindId := NodeKindId(plan.FSteps[AIndex].Node.Kind);
  AName := plan.FSteps[AIndex].Node.Name;
  SetLength(ASources, Length(plan.FSteps[AIndex].Sources));
  for j := 0 to High(plan.FSteps[AIndex].Sources) do
    ASources[j] := plan.FSteps[AIndex].Sources[j];
  Result := True;
end;

function TAudioGraph.CompiledStepLevelDb(AIndex: Integer): Double;
var
  idx: Integer;
  plan: TCompiledGraph;
  node: TAudioNode;
begin
  Result := -120.0;
  idx := AtomicRead32(FActiveIdx);
  if (idx < 0) or (idx > 1) or (FPlans[idx] = nil) then Exit;
  plan := FPlans[idx];
  if (AIndex < 0) or (AIndex >= plan.StepCount) then Exit;
  node := plan.FSteps[AIndex].Node;
  if node is TMeterNode then
    Result := TMeterNode(node).RmsDb;
end;

function TAudioGraph.IsCompiled: Boolean;
var
  idx: Integer;
begin
  idx := AtomicRead32(FActiveIdx);
  Result := (idx >= 0) and (idx <= 1) and (FPlans[idx] <> nil);
end;

function TAudioGraph.Describe: string;
var
  sb: TStringBuilder;
  i: Integer;
begin
  sb := TStringBuilder.Create;
  try
    sb.AppendLine(Format('audio graph: %d node(s), %d connection(s), %d ch @ %d Hz',
      [Length(FNodes), Length(FConns), FChannels, FSampleRate]));
    if FDirty then sb.AppendLine('  (needs Compile)');
    if FLastError <> '' then sb.AppendLine('  last error: ' + FLastError);
    sb.AppendLine('nodes:');
    for i := 0 to High(FNodes) do
      sb.AppendLine(Format('  #%d  %-12s  %-16s  %s%s%s',
        [FNodes[i].Id, NodeKindId(FNodes[i].Kind), FNodes[i].Name,
         FNodes[i].SerializeParams,
         BoolToStrTag(FNodes[i].Bypass, ' [bypass]'),
         BoolToStrTag(FNodes[i].Mute, ' [mute]')]));
    sb.AppendLine('connections:');
    for i := 0 to High(FConns) do
      sb.AppendLine(Format('  %d -> %d', [FConns[i].FromId, FConns[i].ToId]));
    if IsCompiled then
    begin
      sb.AppendLine(Format('compiled plan (generation %d):', [FCompileGen]));
      for i := 0 to CompiledStepCount - 1 do
        sb.AppendLine('  ' + CompiledStepText(i));
    end
    else
      sb.AppendLine('compiled plan: (none)');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ ================= TGraphSource ================= }

constructor TGraphSource.Create(AGraph: TAudioGraph);
begin
  inherited Create;
  FGraph := AGraph;
end;

procedure TGraphSource.Render(ABuffer: TAudioBuffer);
begin
  FGraph.Process(ABuffer);
end;

procedure TGraphSource.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  FGraph.Prepare(ASampleRate, AMaxFrames, AChannels);
end;

procedure TGraphSource.Reset;
begin
  FGraph.Reset;
end;

function TGraphSource.Name: string;
begin
  Result := Format('graph(%d nodes)', [FGraph.NodeCount]);
end;

end.
