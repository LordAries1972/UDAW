unit UDAW.Tracker.Commands;
{$I udaw.inc}

{ Phase 11 - Tracker Engine: undo/redo commands for TTrackerModule, built on
  the Phase 5 TDAWCommand / TCommandManager.

    * fine-grained: set / clear one pattern cell (stores the previous cell),
      set the module speed / BPM (mergeable);
    * structural: add / remove pattern, resize a pattern, order-table edits
      and add / remove instrument - captured as a text snapshot before and
      after and restored through the Phase 11 serializer (so, as with the
      mixer, pattern / instrument object references do not survive a
      structural undo - callers work in index space). }

interface

uses
  SysUtils,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Tracker.Types, UDAW.Tracker.Pattern, UDAW.Tracker.Serialization;

type
  TTrackerCommand = class abstract(TDAWCommand)
  protected
    FDoc: TProjectDocument;
    function M: TTrackerModule;
  public
    constructor Create(ADoc: TProjectDocument);
  end;

  TSetTrackerCellCommand = class(TTrackerCommand)
  private
    FPattern, FRow, FChannel: Integer;
    FOld, FNew: TTrackerCell;
  public
    constructor Create(ADoc: TProjectDocument; APattern, ARow, AChannel: Integer;
      const ACell: TTrackerCell);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  TSetTrackerTransportCommand = class(TTrackerCommand)
  private
    FIsSpeed: Boolean;
    FOld, FNew: Integer;
  public
    constructor Create(ADoc: TProjectDocument; AIsSpeed: Boolean; ANewValue: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TTrackerStructuralCommand = class abstract(TTrackerCommand)
  private
    FBefore, FAfter: string;
  protected
    function Mutate: Boolean; virtual; abstract;
  public
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
  end;

  TAddTrackerPatternCommand = class(TTrackerStructuralCommand)
  private
    FRows: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; ARows: Integer);
    function Description: string; override;
  end;

  TRemoveTrackerPatternCommand = class(TTrackerStructuralCommand)
  private
    FIndex: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AIndex: Integer);
    function Description: string; override;
  end;

  TResizeTrackerPatternCommand = class(TTrackerStructuralCommand)
  private
    FIndex, FRows: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AIndex, ARows: Integer);
    function Description: string; override;
  end;

  TTrackerOrderEditKind = (toeSet, toeInsert, toeDelete, toeAppend);

  TEditTrackerOrderCommand = class(TTrackerStructuralCommand)
  private
    FKind: TTrackerOrderEditKind;
    FIndex, FPatternIndex: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AKind: TTrackerOrderEditKind;
      AIndex, APatternIndex: Integer);
    function Description: string; override;
  end;

  TAddTrackerInstrumentCommand = class(TTrackerStructuralCommand)
  private
    FName: string;
    FSineFreq, FSineSeconds: Double;   // > 0 => fill with a sine
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; const AName: string;
      ASineFreq: Double = 0; ASineSeconds: Double = 0);
    function Description: string; override;
  end;

  TRemoveTrackerInstrumentCommand = class(TTrackerStructuralCommand)
  private
    FIndex1Based: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AIndex1Based: Integer);
    function Description: string; override;
  end;

  { Phase 12 - replace the project's tracker module with one imported from
    .MOD bytes. Undo restores the previous module (text snapshot). }
  TImportModCommand = class(TTrackerStructuralCommand)
  private
    FData: TBytes;
    FLabel: string;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; const AData: TBytes;
      const ALabel: string = 'MOD');
    function Description: string; override;
  end;

  { Phase 13 - replace the project's tracker module with one imported from
    .XM bytes. Undo restores the previous module (text snapshot). }
  TImportXmCommand = class(TTrackerStructuralCommand)
  private
    FData: TBytes;
    FLabel: string;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; const AData: TBytes;
      const ALabel: string = 'XM');
    function Description: string; override;
  end;

  { Phase 14 - replace the project's tracker module with one imported from
    .MPTM / .IT bytes. Undo restores the previous module (text snapshot). }
  TImportMptmCommand = class(TTrackerStructuralCommand)
  private
    FData: TBytes;
    FLabel: string;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; const AData: TBytes;
      const ALabel: string = 'MPTM');
    function Description: string; override;
  end;

  { Tracker > New > Tracker: discard the project's current tracker module
    and replace it with a fresh, empty one. Undo restores the previous
    module (text snapshot), same as an import. }
  TNewTrackerModuleCommand = class(TTrackerStructuralCommand)
  protected
    function Mutate: Boolean; override;
  public
    function Description: string; override;
  end;

implementation

uses
  UDAW.Tracker.Instrument, UDAW.Codec.ProTracker, UDAW.Codec.XM, UDAW.Codec.MPTM;

{ ================= TTrackerCommand ================= }

constructor TTrackerCommand.Create(ADoc: TProjectDocument);
begin
  inherited Create;
  FDoc := ADoc;
end;

function TTrackerCommand.M: TTrackerModule;
begin
  Result := FDoc.Tracker;
end;

{ ================= TSetTrackerCellCommand ================= }

constructor TSetTrackerCellCommand.Create(ADoc: TProjectDocument;
  APattern, ARow, AChannel: Integer; const ACell: TTrackerCell);
begin
  inherited Create(ADoc);
  FPattern := APattern;
  FRow := ARow;
  FChannel := AChannel;
  FNew := ACell;
end;

function TSetTrackerCellCommand.Execute: Boolean;
var
  p: TTrackerPattern;
begin
  p := M.GetPattern(FPattern);
  if p = nil then Exit(False);
  FOld := p.GetCell(FRow, FChannel);
  p.SetCell(FRow, FChannel, FNew);
  FDoc.Touch;
  Result := True;
end;

procedure TSetTrackerCellCommand.Undo;
var
  p: TTrackerPattern;
begin
  p := M.GetPattern(FPattern);
  if p <> nil then
  begin
    p.SetCell(FRow, FChannel, FOld);
    FDoc.Touch;
  end;
end;

function TSetTrackerCellCommand.Description: string;
begin
  Result := Format('Edit pattern %d row %d ch %d', [FPattern, FRow, FChannel]);
end;

{ ================= TSetTrackerTransportCommand ================= }

constructor TSetTrackerTransportCommand.Create(ADoc: TProjectDocument;
  AIsSpeed: Boolean; ANewValue: Integer);
begin
  inherited Create(ADoc);
  FIsSpeed := AIsSpeed;
  if AIsSpeed then
    FNew := ClampInt(ANewValue, TRK_MIN_SPEED, TRK_MAX_SPEED)
  else
    FNew := ClampInt(ANewValue, TRK_MIN_BPM, TRK_MAX_BPM);
end;

function TSetTrackerTransportCommand.Execute: Boolean;
begin
  if FIsSpeed then FOld := M.InitialSpeed else FOld := M.InitialBPM;
  if FOld = FNew then Exit(False);
  if FIsSpeed then M.InitialSpeed := FNew else M.InitialBPM := FNew;
  FDoc.Touch;
  Result := True;
end;

procedure TSetTrackerTransportCommand.Undo;
begin
  if FIsSpeed then M.InitialSpeed := FOld else M.InitialBPM := FOld;
  FDoc.Touch;
end;

function TSetTrackerTransportCommand.Description: string;
begin
  if FIsSpeed then Result := Format('Set tracker speed to %d', [FNew])
  else Result := Format('Set tracker BPM to %d', [FNew]);
end;

function TSetTrackerTransportCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  nx: TSetTrackerTransportCommand;
begin
  Result := (ANext is TSetTrackerTransportCommand);
  if not Result then Exit;
  nx := TSetTrackerTransportCommand(ANext);
  Result := (nx.FDoc = FDoc) and (nx.FIsSpeed = FIsSpeed)
    and (MsSinceStamp <= COMMAND_MERGE_WINDOW_MS);
  if Result then
  begin
    FNew := nx.FNew;
    if FIsSpeed then FDoc.Tracker.InitialSpeed := FNew
    else FDoc.Tracker.InitialBPM := FNew;
    FDoc.Touch;
    Restamp;
  end;
end;

{ ================= TTrackerStructuralCommand ================= }

function TTrackerStructuralCommand.Execute: Boolean;
begin
  FBefore := TrackerModuleToString(M);
  if not Mutate then
  begin
    if TrackerModuleToString(M) <> FBefore then
      FDoc.ReplaceTracker(TrackerModuleFromString(FBefore));
    Exit(False);
  end;
  FAfter := TrackerModuleToString(M);
  if FAfter = FBefore then Exit(False);
  FDoc.Touch;
  Result := True;
end;

procedure TTrackerStructuralCommand.Undo;
begin
  FDoc.ReplaceTracker(TrackerModuleFromString(FBefore));
  FDoc.Touch;
end;

function TTrackerStructuralCommand.Redo: Boolean;
begin
  FDoc.ReplaceTracker(TrackerModuleFromString(FAfter));
  FDoc.Touch;
  Result := True;
end;

{ ================= TAddTrackerPatternCommand ================= }

constructor TAddTrackerPatternCommand.Create(ADoc: TProjectDocument; ARows: Integer);
begin
  inherited Create(ADoc);
  FRows := ARows;
end;

function TAddTrackerPatternCommand.Mutate: Boolean;
begin
  M.AddPattern(FRows);
  Result := True;
end;

function TAddTrackerPatternCommand.Description: string;
begin
  Result := Format('Add pattern (%d rows)', [FRows]);
end;

{ ================= TRemoveTrackerPatternCommand ================= }

constructor TRemoveTrackerPatternCommand.Create(ADoc: TProjectDocument; AIndex: Integer);
begin
  inherited Create(ADoc);
  FIndex := AIndex;
end;

function TRemoveTrackerPatternCommand.Mutate: Boolean;
begin
  if (FIndex < 0) or (FIndex >= M.PatternCount) then Exit(False);
  M.RemovePattern(FIndex);
  Result := True;
end;

function TRemoveTrackerPatternCommand.Description: string;
begin
  Result := Format('Remove pattern %d', [FIndex]);
end;

{ ================= TResizeTrackerPatternCommand ================= }

constructor TResizeTrackerPatternCommand.Create(ADoc: TProjectDocument; AIndex, ARows: Integer);
begin
  inherited Create(ADoc);
  FIndex := AIndex;
  FRows := ARows;
end;

function TResizeTrackerPatternCommand.Mutate: Boolean;
var
  p: TTrackerPattern;
begin
  p := M.GetPattern(FIndex);
  if p = nil then Exit(False);
  if p.Rows = FRows then Exit(False);
  p.Resize(FRows);
  Result := True;
end;

function TResizeTrackerPatternCommand.Description: string;
begin
  Result := Format('Resize pattern %d to %d rows', [FIndex, FRows]);
end;

{ ================= TEditTrackerOrderCommand ================= }

constructor TEditTrackerOrderCommand.Create(ADoc: TProjectDocument;
  AKind: TTrackerOrderEditKind; AIndex, APatternIndex: Integer);
begin
  inherited Create(ADoc);
  FKind := AKind;
  FIndex := AIndex;
  FPatternIndex := APatternIndex;
end;

function TEditTrackerOrderCommand.Mutate: Boolean;
begin
  case FKind of
    toeSet:    M.SetOrder(FIndex, FPatternIndex);
    toeInsert: M.InsertOrder(FIndex, FPatternIndex);
    toeDelete:
      begin
        if M.OrderLength <= 1 then Exit(False);
        M.DeleteOrder(FIndex);
      end;
    toeAppend: M.AppendOrder(FPatternIndex);
  end;
  Result := True;
end;

function TEditTrackerOrderCommand.Description: string;
begin
  Result := 'Edit order table';
end;

{ ================= TAddTrackerInstrumentCommand ================= }

constructor TAddTrackerInstrumentCommand.Create(ADoc: TProjectDocument;
  const AName: string; ASineFreq, ASineSeconds: Double);
begin
  inherited Create(ADoc);
  FName := AName;
  FSineFreq := ASineFreq;
  FSineSeconds := ASineSeconds;
end;

function TAddTrackerInstrumentCommand.Mutate: Boolean;
var
  ins: TTrackerInstrument;
begin
  ins := M.AddInstrument(FName);
  if (FSineFreq > 0) and (FSineSeconds > 0) then
    ins.MakeSine(FSineFreq, FSineSeconds);
  Result := True;
end;

function TAddTrackerInstrumentCommand.Description: string;
begin
  Result := Format('Add instrument "%s"', [FName]);
end;

{ ================= TRemoveTrackerInstrumentCommand ================= }

constructor TRemoveTrackerInstrumentCommand.Create(ADoc: TProjectDocument; AIndex1Based: Integer);
begin
  inherited Create(ADoc);
  FIndex1Based := AIndex1Based;
end;

function TRemoveTrackerInstrumentCommand.Mutate: Boolean;
begin
  if (FIndex1Based < 1) or (FIndex1Based > M.InstrumentCount) then Exit(False);
  M.RemoveInstrument(FIndex1Based);
  Result := True;
end;

function TRemoveTrackerInstrumentCommand.Description: string;
begin
  Result := Format('Remove instrument %d', [FIndex1Based]);
end;

{ ================= TImportModCommand ================= }

constructor TImportModCommand.Create(ADoc: TProjectDocument; const AData: TBytes;
  const ALabel: string);
begin
  inherited Create(ADoc);
  FData := Copy(AData);
  FLabel := ALabel;
end;

function TImportModCommand.Mutate: Boolean;
var
  imported: TTrackerModule;
begin
  imported := ModToModule(FData);   // raises EUDAWError on a bad file
  FDoc.ReplaceTracker(imported);
  Result := True;
end;

function TImportModCommand.Description: string;
begin
  Result := Format('Import %s module', [FLabel]);
end;

{ ================= TImportXmCommand ================= }

constructor TImportXmCommand.Create(ADoc: TProjectDocument; const AData: TBytes;
  const ALabel: string);
begin
  inherited Create(ADoc);
  FData := Copy(AData);
  FLabel := ALabel;
end;

function TImportXmCommand.Mutate: Boolean;
begin
  FDoc.ReplaceTracker(XmToModule(FData));   // raises EUDAWError on a bad file
  Result := True;
end;

function TImportXmCommand.Description: string;
begin
  Result := Format('Import %s module', [FLabel]);
end;

{ ================= TImportMptmCommand ================= }

constructor TImportMptmCommand.Create(ADoc: TProjectDocument; const AData: TBytes;
  const ALabel: string);
begin
  inherited Create(ADoc);
  FData := Copy(AData);
  FLabel := ALabel;
end;

function TImportMptmCommand.Mutate: Boolean;
begin
  FDoc.ReplaceTracker(MptmToModule(FData));   // raises EUDAWError on a bad file
  Result := True;
end;

function TImportMptmCommand.Description: string;
begin
  Result := Format('Import %s module', [FLabel]);
end;

{ ================= TNewTrackerModuleCommand ================= }

function TNewTrackerModuleCommand.Mutate: Boolean;
var
  fresh: TTrackerModule;
begin
  fresh := TTrackerModule.Create;
  fresh.InitDefault;
  FDoc.ReplaceTracker(fresh);
  Result := True;
end;

function TNewTrackerModuleCommand.Description: string;
begin
  Result := 'New tracker';
end;

end.
