unit UDAW.Project.Commands;
{$I udaw.inc}

{ Phase 5 - Project System: Command Pattern undo/redo (plan section 28).

  TDAWCommand is the base every mutating operation on a TProjectDocument goes
  through - Execute / Undo / (Redo, default = re-Execute). TCommandManager
  holds the undo/redo stacks and is the only thing allowed to call Execute /
  Undo / Redo: application code always goes through Manager.Do(command).

  Commands can absorb a follow-up command of the same kind within a short
  time window (AbsorbNext) so a burst of edits - a fader dragged through a
  hundred intermediate values, a tempo nudged repeatedly - collapses into one
  undo step, exactly as the plan's example calls for.

  This unit ships two concrete families:
    * project-metadata commands (name / tempo / time signature), and
    * audio-graph commands (add/remove node, connect/disconnect, set a
      node's parameters) built directly on the Phase 4 TAudioGraph edit API.
  Later phases (tracks, clips, patterns, mixer) add their own TDAWCommand
  descendants against the same TCommandManager - no change needed here. }

interface

uses
  SysUtils, Generics.Collections,
  UDAW.Errors,
  UDAW.Audio.Graph, UDAW.Audio.Graph.Nodes,
  UDAW.Timeline.Time,
  UDAW.Project.Document;

const
  COMMAND_MERGE_WINDOW_MS = 800;
  COMMAND_HISTORY_LIMIT   = 500;

type
  TDAWCommand = class abstract
  private
    FStampTime: TDateTime;
  protected
    procedure Restamp;
    function MsSinceStamp: Int64;
  public
    constructor Create;
    { Perform the edit. Returning False means "nothing to do" - the manager
      discards the command without pushing it onto the undo stack. May raise
      EUDAWError, in which case the manager also discards it. }
    function Execute: Boolean; virtual; abstract;
    procedure Undo; virtual; abstract;
    { Re-apply after an Undo. The default re-runs Execute, which is correct
      for every command in this unit; override only if Execute is not
      naturally idempotent for a given command. }
    function Redo: Boolean; virtual;
    function Description: string; virtual; abstract;
    { Called on the command already at the top of the undo stack, with the
      just-Do()'d command as ANext. Returning True means Self has absorbed
      ANext's effect (Self already re-applied it) and the manager discards
      ANext entirely instead of pushing it. }
    function AbsorbNext(ANext: TDAWCommand): Boolean; virtual;
  end;

  TDAWCommandClass = class of TDAWCommand;

  TCommandChangedEvent = procedure(ASender: TObject) of object;

  TCommandManager = class
  private
    FUndoStack: TObjectList<TDAWCommand>;
    FRedoStack: TObjectList<TDAWCommand>;
    FOnChanged: TCommandChangedEvent;
    procedure ClearRedo;
    procedure Changed;
  public
    constructor Create;
    destructor Destroy; override;

    { Executes ACommand (or lets the top-of-stack command absorb it), pushes
      it onto the undo stack, and clears the redo stack. ACommand is always
      consumed (executed-and-kept, absorbed-and-freed, or freed on failure) -
      the caller never frees it itself. Returns False if the command reported
      nothing to do. }
    function Perform(ACommand: TDAWCommand): Boolean;
    function CanUndo: Boolean;
    function CanRedo: Boolean;
    procedure Undo;
    procedure Redo;
    procedure Clear;
    { Drops what was undone (the redo stack) - for a cancelled job whose commands were
      rolled back and must not be redoable, since the files they used are deleted. }
    procedure DiscardRedo;
    function UndoDescription: string;
    function RedoDescription: string;
    function UndoCount: Integer;
    function RedoCount: Integer;
    { AIndex = 0 is the next command that would be undone/redone, 1 the one
      after that, etc. Used to populate a history list in the UI. }
    function UndoDescriptionAt(AIndex: Integer): string;
    function RedoDescriptionAt(AIndex: Integer): string;
    { Undo/Redo ACount commands in one go (ACount = 1 behaves like a single
      Undo/Redo call). Used when the user picks an older entry from a history
      list: jumping to entry AIndex means undoing/redoing AIndex + 1 steps. }
    procedure UndoMultiple(ACount: Integer);
    procedure RedoMultiple(ACount: Integer);
    property OnChanged: TCommandChangedEvent read FOnChanged write FOnChanged;
  end;

  { ---------------- project metadata commands ---------------- }

  TSetProjectNameCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FOldValue, FNewValue: string;
  public
    constructor Create(ADoc: TProjectDocument; const ANewValue: string);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TSetProjectAuthorCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FOldValue, FNewValue: string;
  public
    constructor Create(ADoc: TProjectDocument; const ANewValue: string);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  TSetTempoCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FOldValue, FNewValue: Double;
  public
    constructor Create(ADoc: TProjectDocument; ANewValue: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  { replace the whole tempo map (add / move / retune / delete a tempo point);
    a drag of one point merges into a single undo step }
  TSetTempoMapCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FOldMap, FNewMap: TTempoPoints;
    FLabel: string;
  public
    constructor Create(ADoc: TProjectDocument; const ANewMap: TTempoPoints; const ALabel: string);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TSetTimeSignatureCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FOldNum, FOldDen, FNewNum, FNewDen: Integer;
  public
    constructor Create(ADoc: TProjectDocument; ANewNum, ANewDen: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  { ---------------- audio-graph commands (Phase 4 TAudioGraph) ---------------- }

  TAddGraphNodeCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FKind: TNodeKind;
    FName: string;
    FCreatedId: Integer;
  public
    constructor Create(ADoc: TProjectDocument; AKind: TNodeKind; const AName: string);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;
    property CreatedId: Integer read FCreatedId;
  end;

  TRemoveGraphNodeCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FNodeId: Integer;
    FKind: TNodeKind;
    FName: string;
    FParams: string;
    FBypass, FMute: Boolean;
    FConnsIn: TArray<Integer>;    // FromId -> this node
    FConnsOut: TArray<Integer>;   // this node -> ToId
  public
    constructor Create(ADoc: TProjectDocument; ANodeId: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  TConnectNodesCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FFromId, FToId: Integer;
  public
    constructor Create(ADoc: TProjectDocument; AFromId, AToId: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  TDisconnectNodesCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FFromId, FToId: Integer;
  public
    constructor Create(ADoc: TProjectDocument; AFromId, AToId: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { Generic "change this node's parameter string" command - works for every
    node type via SerializeParams/DeserializeParams, so a fader, an EQ knob
    or a delay time all reuse the same command and the same merge behaviour. }
  TSetNodeParamsCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FNodeId: Integer;
    FOldParams, FNewParams: string;
  public
    constructor Create(ADoc: TProjectDocument; ANodeId: Integer; const ANewParams: string);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

implementation

uses
  DateUtils;

{ ================= TDAWCommand ================= }

constructor TDAWCommand.Create;
begin
  inherited Create;
  Restamp;
end;

procedure TDAWCommand.Restamp;
begin
  FStampTime := Now;
end;

function TDAWCommand.MsSinceStamp: Int64;
begin
  Result := MilliSecondsBetween(Now, FStampTime);
end;

function TDAWCommand.Redo: Boolean;
begin
  Result := Execute;
end;

function TDAWCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
begin
  Result := False;
end;

{ ================= TCommandManager ================= }

constructor TCommandManager.Create;
begin
  inherited Create;
  FUndoStack := TObjectList<TDAWCommand>.Create(True);
  FRedoStack := TObjectList<TDAWCommand>.Create(True);
end;

destructor TCommandManager.Destroy;
begin
  FUndoStack.Free;
  FRedoStack.Free;
  inherited Destroy;
end;

procedure TCommandManager.ClearRedo;
begin
  FRedoStack.Clear;
end;

procedure TCommandManager.Changed;
begin
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

function TCommandManager.Perform(ACommand: TDAWCommand): Boolean;
var
  top: TDAWCommand;
begin
  if ACommand = nil then Exit(False);

  if FUndoStack.Count > 0 then
  begin
    top := FUndoStack[FUndoStack.Count - 1];
    if top.AbsorbNext(ACommand) then
    begin
      ACommand.Free;
      ClearRedo;
      Changed;
      Exit(True);
    end;
  end;

  try
    Result := ACommand.Execute;
  except
    ACommand.Free;
    raise;
  end;

  if not Result then
  begin
    ACommand.Free;
    Exit(False);
  end;

  FUndoStack.Add(ACommand);
  while FUndoStack.Count > COMMAND_HISTORY_LIMIT do
    FUndoStack.Delete(0);
  ClearRedo;
  Changed;
end;

function TCommandManager.CanUndo: Boolean;
begin
  Result := FUndoStack.Count > 0;
end;

function TCommandManager.CanRedo: Boolean;
begin
  Result := FRedoStack.Count > 0;
end;

procedure TCommandManager.Undo;
var
  cmd: TDAWCommand;
begin
  if not CanUndo then Exit;
  cmd := FUndoStack[FUndoStack.Count - 1];
  FUndoStack.Extract(cmd);
  cmd.Undo;
  FRedoStack.Add(cmd);
  Changed;
end;

procedure TCommandManager.Redo;
var
  cmd: TDAWCommand;
begin
  if not CanRedo then Exit;
  cmd := FRedoStack[FRedoStack.Count - 1];
  FRedoStack.Extract(cmd);
  if cmd.Redo then
    FUndoStack.Add(cmd)
  else
    cmd.Free;
  Changed;
end;

procedure TCommandManager.DiscardRedo;
begin
  ClearRedo;
  Changed;
end;

procedure TCommandManager.Clear;
begin
  FUndoStack.Clear;
  FRedoStack.Clear;
  Changed;
end;

function TCommandManager.UndoDescription: string;
begin
  if CanUndo then
    Result := FUndoStack[FUndoStack.Count - 1].Description
  else
    Result := '';
end;

function TCommandManager.RedoDescription: string;
begin
  if CanRedo then
    Result := FRedoStack[FRedoStack.Count - 1].Description
  else
    Result := '';
end;

function TCommandManager.UndoCount: Integer;
begin
  Result := FUndoStack.Count;
end;

function TCommandManager.RedoCount: Integer;
begin
  Result := FRedoStack.Count;
end;

function TCommandManager.UndoDescriptionAt(AIndex: Integer): string;
var
  i: Integer;
begin
  i := FUndoStack.Count - 1 - AIndex;
  if (i < 0) or (i >= FUndoStack.Count) then Exit('');
  Result := FUndoStack[i].Description;
end;

function TCommandManager.RedoDescriptionAt(AIndex: Integer): string;
var
  i: Integer;
begin
  i := FRedoStack.Count - 1 - AIndex;
  if (i < 0) or (i >= FRedoStack.Count) then Exit('');
  Result := FRedoStack[i].Description;
end;

procedure TCommandManager.UndoMultiple(ACount: Integer);
var
  i: Integer;
begin
  for i := 1 to ACount do
  begin
    if not CanUndo then Break;
    Undo;
  end;
end;

procedure TCommandManager.RedoMultiple(ACount: Integer);
var
  i: Integer;
begin
  for i := 1 to ACount do
  begin
    if not CanRedo then Break;
    Redo;
  end;
end;

{ ================= TSetProjectNameCommand ================= }

constructor TSetProjectNameCommand.Create(ADoc: TProjectDocument; const ANewValue: string);
begin
  inherited Create;
  FDoc := ADoc;
  FOldValue := ADoc.Name;
  FNewValue := ANewValue;
end;

function TSetProjectNameCommand.Execute: Boolean;
begin
  if FNewValue = FDoc.Name then Exit(False);
  FDoc.Name := FNewValue;
  Result := True;
end;

procedure TSetProjectNameCommand.Undo;
begin
  FDoc.Name := FOldValue;
end;

function TSetProjectNameCommand.Description: string;
begin
  Result := Format('Rename project to "%s"', [FNewValue]);
end;

function TSetProjectNameCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
begin
  Result := (ANext is TSetProjectNameCommand) and
    (TSetProjectNameCommand(ANext).FDoc = FDoc) and
    (MsSinceStamp <= COMMAND_MERGE_WINDOW_MS);
  if Result then
  begin
    FNewValue := TSetProjectNameCommand(ANext).FNewValue;
    FDoc.Name := FNewValue;
    Restamp;
  end;
end;

{ ================= TSetProjectAuthorCommand ================= }

constructor TSetProjectAuthorCommand.Create(ADoc: TProjectDocument; const ANewValue: string);
begin
  inherited Create;
  FDoc := ADoc;
  FOldValue := ADoc.Author;
  FNewValue := Trim(ANewValue);
end;

function TSetProjectAuthorCommand.Execute: Boolean;
begin
  if FNewValue = FDoc.Author then Exit(False);
  FDoc.Author := FNewValue;
  Result := True;
end;

procedure TSetProjectAuthorCommand.Undo;
begin
  FDoc.Author := FOldValue;
end;

function TSetProjectAuthorCommand.Description: string;
begin
  Result := Format('Set author to "%s"', [FNewValue]);
end;

{ ================= TSetTempoCommand ================= }

constructor TSetTempoCommand.Create(ADoc: TProjectDocument; ANewValue: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FOldValue := ADoc.TempoBPM;
  FNewValue := ANewValue;
end;

function TSetTempoCommand.Execute: Boolean;
begin
  if FNewValue = FDoc.TempoBPM then Exit(False);
  FDoc.TempoBPM := FNewValue;
  Result := True;
end;

procedure TSetTempoCommand.Undo;
begin
  FDoc.TempoBPM := FOldValue;
end;

function TSetTempoCommand.Description: string;
begin
  Result := Format('Set tempo to %.2f BPM', [FNewValue]);
end;

function TSetTempoCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
begin
  Result := (ANext is TSetTempoCommand) and
    (TSetTempoCommand(ANext).FDoc = FDoc) and
    (MsSinceStamp <= COMMAND_MERGE_WINDOW_MS);
  if Result then
  begin
    FNewValue := TSetTempoCommand(ANext).FNewValue;
    FDoc.TempoBPM := FNewValue;
    Restamp;
  end;
end;

{ ================= TSetTempoMapCommand ================= }

constructor TSetTempoMapCommand.Create(ADoc: TProjectDocument; const ANewMap: TTempoPoints;
  const ALabel: string);
begin
  inherited Create;
  FDoc := ADoc;
  FNewMap := Copy(ANewMap);
  FLabel := ALabel;
end;

function MapsEqual(const A, B: TTempoPoints): Boolean;
var
  i: Integer;
begin
  Result := Length(A) = Length(B);
  if Result then
    for i := 0 to High(A) do
      if (Abs(A[i].Seconds - B[i].Seconds) > 1e-9) or (Abs(A[i].Bpm - B[i].Bpm) > 1e-9) then
        Exit(False);
end;

function TSetTempoMapCommand.Execute: Boolean;
begin
  FOldMap := Copy(FDoc.TempoMap);
  FDoc.TempoMap := FNewMap;
  Result := not MapsEqual(FOldMap, FDoc.TempoMap);
end;

procedure TSetTempoMapCommand.Undo;
begin
  FDoc.TempoMap := FOldMap;
end;

function TSetTempoMapCommand.Description: string;
begin
  Result := FLabel;
end;

function TSetTempoMapCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
begin
  Result := (ANext is TSetTempoMapCommand) and (TSetTempoMapCommand(ANext).FDoc = FDoc) and
    (TSetTempoMapCommand(ANext).FLabel = FLabel) and (MsSinceStamp <= COMMAND_MERGE_WINDOW_MS);
  if Result then
  begin
    FNewMap := Copy(TSetTempoMapCommand(ANext).FNewMap);
    FDoc.TempoMap := FNewMap;
    Restamp;
  end;
end;

{ ================= TSetTimeSignatureCommand ================= }

constructor TSetTimeSignatureCommand.Create(ADoc: TProjectDocument; ANewNum, ANewDen: Integer);
begin
  inherited Create;
  FDoc := ADoc;
  FOldNum := ADoc.TimeSigNum;
  FOldDen := ADoc.TimeSigDen;
  FNewNum := ANewNum;
  FNewDen := ANewDen;
end;

function TSetTimeSignatureCommand.Execute: Boolean;
begin
  if (FNewNum = FDoc.TimeSigNum) and (FNewDen = FDoc.TimeSigDen) then Exit(False);
  FDoc.TimeSigNum := FNewNum;
  FDoc.TimeSigDen := FNewDen;
  Result := True;
end;

procedure TSetTimeSignatureCommand.Undo;
begin
  FDoc.TimeSigNum := FOldNum;
  FDoc.TimeSigDen := FOldDen;
end;

function TSetTimeSignatureCommand.Description: string;
begin
  Result := Format('Set time signature to %d/%d', [FNewNum, FNewDen]);
end;

function TSetTimeSignatureCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
begin
  Result := (ANext is TSetTimeSignatureCommand) and
    (TSetTimeSignatureCommand(ANext).FDoc = FDoc) and
    (MsSinceStamp <= COMMAND_MERGE_WINDOW_MS);
  if Result then
  begin
    FNewNum := TSetTimeSignatureCommand(ANext).FNewNum;
    FNewDen := TSetTimeSignatureCommand(ANext).FNewDen;
    FDoc.TimeSigNum := FNewNum;
    FDoc.TimeSigDen := FNewDen;
    Restamp;
  end;
end;

{ ================= TAddGraphNodeCommand ================= }

constructor TAddGraphNodeCommand.Create(ADoc: TProjectDocument; AKind: TNodeKind;
  const AName: string);
begin
  inherited Create;
  FDoc := ADoc;
  FKind := AKind;
  FName := AName;
  FCreatedId := -1;
end;

function TAddGraphNodeCommand.Execute: Boolean;
var
  n: TAudioNode;
begin
  n := FDoc.Graph.AddNode(FKind, FName);
  FCreatedId := n.Id;
  FName := n.Name;
  FDoc.Touch;
  Result := True;
end;

procedure TAddGraphNodeCommand.Undo;
begin
  FDoc.Graph.RemoveNode(FCreatedId);
  FDoc.Touch;
end;

function TAddGraphNodeCommand.Redo: Boolean;
begin
  FDoc.Graph.AddNodeWithId(FCreatedId, FKind, FName);
  FDoc.Touch;
  Result := True;
end;

function TAddGraphNodeCommand.Description: string;
begin
  Result := Format('Add %s node "%s"', [NodeKindId(FKind), FName]);
end;

{ ================= TRemoveGraphNodeCommand ================= }

constructor TRemoveGraphNodeCommand.Create(ADoc: TProjectDocument; ANodeId: Integer);
begin
  inherited Create;
  FDoc := ADoc;
  FNodeId := ANodeId;
end;

function TRemoveGraphNodeCommand.Execute: Boolean;
var
  n: TAudioNode;
  i, cIn, cOut: Integer;
  c: TGraphConn;
begin
  n := FDoc.Graph.NodeById(FNodeId);
  if n = nil then Exit(False);

  FKind := n.Kind;
  FName := n.Name;
  FParams := n.SerializeParams;
  FBypass := n.Bypass;
  FMute := n.Mute;

  SetLength(FConnsIn, 0);
  SetLength(FConnsOut, 0);
  cIn := 0; cOut := 0;
  for i := 0 to FDoc.Graph.ConnectionCount - 1 do
  begin
    c := FDoc.Graph.GetConnection(i);
    if c.ToId = FNodeId then
    begin
      SetLength(FConnsIn, cIn + 1);
      FConnsIn[cIn] := c.FromId;
      Inc(cIn);
    end;
    if c.FromId = FNodeId then
    begin
      SetLength(FConnsOut, cOut + 1);
      FConnsOut[cOut] := c.ToId;
      Inc(cOut);
    end;
  end;

  FDoc.Graph.RemoveNode(FNodeId);
  FDoc.Touch;
  Result := True;
end;

procedure TRemoveGraphNodeCommand.Undo;
var
  n: TAudioNode;
  i: Integer;
begin
  n := FDoc.Graph.AddNodeWithId(FNodeId, FKind, FName);
  n.DeserializeParams(FParams);
  n.Bypass := FBypass;
  n.Mute := FMute;
  for i := 0 to High(FConnsIn) do
    if FDoc.Graph.NodeById(FConnsIn[i]) <> nil then
      FDoc.Graph.Connect(FConnsIn[i], FNodeId);
  for i := 0 to High(FConnsOut) do
    if FDoc.Graph.NodeById(FConnsOut[i]) <> nil then
      FDoc.Graph.Connect(FNodeId, FConnsOut[i]);
  FDoc.Touch;
end;

function TRemoveGraphNodeCommand.Description: string;
begin
  Result := Format('Remove node "%s"', [FName]);
end;

{ ================= TConnectNodesCommand ================= }

constructor TConnectNodesCommand.Create(ADoc: TProjectDocument; AFromId, AToId: Integer);
begin
  inherited Create;
  FDoc := ADoc;
  FFromId := AFromId;
  FToId := AToId;
end;

function TConnectNodesCommand.Execute: Boolean;
begin
  FDoc.Graph.Connect(FFromId, FToId);
  FDoc.Touch;
  Result := True;
end;

procedure TConnectNodesCommand.Undo;
begin
  FDoc.Graph.Disconnect(FFromId, FToId);
  FDoc.Touch;
end;

function TConnectNodesCommand.Description: string;
begin
  Result := Format('Connect node %d -> %d', [FFromId, FToId]);
end;

{ ================= TDisconnectNodesCommand ================= }

constructor TDisconnectNodesCommand.Create(ADoc: TProjectDocument; AFromId, AToId: Integer);
begin
  inherited Create;
  FDoc := ADoc;
  FFromId := AFromId;
  FToId := AToId;
end;

function TDisconnectNodesCommand.Execute: Boolean;
begin
  if FDoc.Graph.NodeById(FFromId) = nil then Exit(False);
  FDoc.Graph.Disconnect(FFromId, FToId);
  FDoc.Touch;
  Result := True;
end;

procedure TDisconnectNodesCommand.Undo;
begin
  FDoc.Graph.Connect(FFromId, FToId);
  FDoc.Touch;
end;

function TDisconnectNodesCommand.Description: string;
begin
  Result := Format('Disconnect node %d -> %d', [FFromId, FToId]);
end;

{ ================= TSetNodeParamsCommand ================= }

constructor TSetNodeParamsCommand.Create(ADoc: TProjectDocument; ANodeId: Integer;
  const ANewParams: string);
begin
  inherited Create;
  FDoc := ADoc;
  FNodeId := ANodeId;
  FNewParams := ANewParams;
end;

function TSetNodeParamsCommand.Execute: Boolean;
var
  n: TAudioNode;
begin
  n := FDoc.Graph.NodeById(FNodeId);
  if n = nil then Exit(False);
  FOldParams := n.SerializeParams;
  if FOldParams = FNewParams then Exit(False);
  n.DeserializeParams(FNewParams);
  FDoc.Touch;
  Result := True;
end;

procedure TSetNodeParamsCommand.Undo;
var
  n: TAudioNode;
begin
  n := FDoc.Graph.NodeById(FNodeId);
  if n <> nil then
  begin
    n.DeserializeParams(FOldParams);
    FDoc.Touch;
  end;
end;

function TSetNodeParamsCommand.Description: string;
begin
  Result := Format('Change parameters of node %d', [FNodeId]);
end;

function TSetNodeParamsCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  n: TAudioNode;
begin
  Result := (ANext is TSetNodeParamsCommand) and
    (TSetNodeParamsCommand(ANext).FDoc = FDoc) and
    (TSetNodeParamsCommand(ANext).FNodeId = FNodeId) and
    (MsSinceStamp <= COMMAND_MERGE_WINDOW_MS);
  if Result then
  begin
    FNewParams := TSetNodeParamsCommand(ANext).FNewParams;
    n := FDoc.Graph.NodeById(FNodeId);
    if n <> nil then
      n.DeserializeParams(FNewParams);
    FDoc.Touch;
    Restamp;
  end;
end;

end.
