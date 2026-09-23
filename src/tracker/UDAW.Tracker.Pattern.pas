unit UDAW.Tracker.Pattern;
{$I udaw.inc}

{ Phase 11 - Tracker Engine: the pattern grid and the module that owns
  patterns, instruments and the order list.

  TTrackerPattern is a rows x channels grid of TTrackerCell. TTrackerModule is
  the whole song: name, channel count, initial speed / BPM, global volume,
  an ordered instrument list, a pattern list, and the order table (a sequence
  of pattern indices plus a restart position). It has no audio or GUI
  dependency - UDAW.Tracker.Player renders it, UDAW.Tracker.Serialization
  round-trips it inside the project file, UDAW.Tracker.Commands edits it
  undoably. }

interface

uses
  SysUtils, Math, Generics.Collections,
  UDAW.Errors,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument;

type
  TTrackerCellArray = array of TTrackerCell;

  TTrackerPattern = class
  private
    FRows: Integer;
    FChannels: Integer;
    FCells: TTrackerCellArray;   // FRows * FChannels, row-major
    function Index(ARow, AChannel: Integer): Integer;
  public
    constructor Create(ARows, AChannels: Integer);
    function Clone: TTrackerPattern;

    procedure Resize(ARows: Integer);
    procedure SetChannels(AChannels: Integer);
    function GetCell(ARow, AChannel: Integer): TTrackerCell;
    procedure SetCell(ARow, AChannel: Integer; const ACell: TTrackerCell);
    procedure ClearCell(ARow, AChannel: Integer);
    procedure ClearAll;
    function IsRowEmpty(ARow: Integer): Boolean;

    property Rows: Integer read FRows;
    property Channels: Integer read FChannels;
  end;

  TTrackerModule = class
  private
    FName: string;
    FChannels: Integer;
    FInitialSpeed: Integer;
    FInitialBPM: Integer;
    FGlobalVolume: Single;
    FRestartPos: Integer;
    FOrder: array of Integer;
    FPatterns: TObjectList<TTrackerPattern>;
    FInstruments: TObjectList<TTrackerInstrument>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    { A minimal usable module: one empty pattern in the order, default speed. }
    procedure InitDefault;
    function Clone: TTrackerModule;

    { ---- patterns ---- }
    function AddPattern(ARows: Integer = TRK_DEFAULT_ROWS): TTrackerPattern;
    procedure RemovePattern(AIndex: Integer);
    function PatternCount: Integer;
    function GetPattern(AIndex: Integer): TTrackerPattern;

    { ---- instruments (1-based ids; slot 0 is "none") ---- }
    function AddInstrument(const AName: string): TTrackerInstrument;
    procedure RemoveInstrument(AIndex1Based: Integer);
    function InstrumentCount: Integer;
    function GetInstrument(AIndex1Based: Integer): TTrackerInstrument;   // nil for 0 / out of range

    { ---- order table ---- }
    function OrderLength: Integer;
    function GetOrder(AIndex: Integer): Integer;
    procedure SetOrder(AIndex, APatternIndex: Integer);
    procedure InsertOrder(AIndex, APatternIndex: Integer);
    procedure DeleteOrder(AIndex: Integer);
    procedure AppendOrder(APatternIndex: Integer);

    procedure SetChannels(AChannels: Integer);

    function Describe: string;

    property Name: string read FName write FName;
    property Channels: Integer read FChannels;
    property InitialSpeed: Integer read FInitialSpeed write FInitialSpeed;
    property InitialBPM: Integer read FInitialBPM write FInitialBPM;
    property GlobalVolume: Single read FGlobalVolume write FGlobalVolume;
    property RestartPos: Integer read FRestartPos write FRestartPos;
  end;

implementation

{ ================= TTrackerPattern ================= }

constructor TTrackerPattern.Create(ARows, AChannels: Integer);
var
  i: Integer;
begin
  inherited Create;
  FRows := ClampInt(ARows, TRK_MIN_ROWS, TRK_MAX_ROWS);
  FChannels := ClampInt(AChannels, TRK_MIN_CHANNELS, TRK_MAX_CHANNELS);
  SetLength(FCells, FRows * FChannels);
  for i := 0 to High(FCells) do
    FCells[i] := TTrackerCell.Empty;
end;

function TTrackerPattern.Clone: TTrackerPattern;
begin
  Result := TTrackerPattern.Create(FRows, FChannels);
  Result.FCells := Copy(FCells);
end;

function TTrackerPattern.Index(ARow, AChannel: Integer): Integer;
begin
  Result := ARow * FChannels + AChannel;
end;

procedure TTrackerPattern.Resize(ARows: Integer);
var
  newRows, r, c: Integer;
  old: TTrackerCellArray;
begin
  newRows := ClampInt(ARows, TRK_MIN_ROWS, TRK_MAX_ROWS);
  if newRows = FRows then Exit;
  old := FCells;
  SetLength(FCells, newRows * FChannels);
  for r := 0 to newRows - 1 do
    for c := 0 to FChannels - 1 do
      if r < FRows then
        FCells[r * FChannels + c] := old[r * FChannels + c]
      else
        FCells[r * FChannels + c] := TTrackerCell.Empty;
  FRows := newRows;
end;

procedure TTrackerPattern.SetChannels(AChannels: Integer);
var
  newCh, r, c: Integer;
  old: TTrackerCellArray;
  oldCh: Integer;
begin
  newCh := ClampInt(AChannels, TRK_MIN_CHANNELS, TRK_MAX_CHANNELS);
  if newCh = FChannels then Exit;
  old := FCells;
  oldCh := FChannels;
  SetLength(FCells, FRows * newCh);
  for r := 0 to FRows - 1 do
    for c := 0 to newCh - 1 do
      if c < oldCh then
        FCells[r * newCh + c] := old[r * oldCh + c]
      else
        FCells[r * newCh + c] := TTrackerCell.Empty;
  FChannels := newCh;
end;

function TTrackerPattern.GetCell(ARow, AChannel: Integer): TTrackerCell;
begin
  if (ARow < 0) or (ARow >= FRows) or (AChannel < 0) or (AChannel >= FChannels) then
    Exit(TTrackerCell.Empty);
  Result := FCells[Index(ARow, AChannel)];
end;

procedure TTrackerPattern.SetCell(ARow, AChannel: Integer; const ACell: TTrackerCell);
begin
  if (ARow < 0) or (ARow >= FRows) or (AChannel < 0) or (AChannel >= FChannels) then
    Exit;
  FCells[Index(ARow, AChannel)] := ACell;
end;

procedure TTrackerPattern.ClearCell(ARow, AChannel: Integer);
begin
  SetCell(ARow, AChannel, TTrackerCell.Empty);
end;

procedure TTrackerPattern.ClearAll;
var
  i: Integer;
begin
  for i := 0 to High(FCells) do
    FCells[i] := TTrackerCell.Empty;
end;

function TTrackerPattern.IsRowEmpty(ARow: Integer): Boolean;
var
  c: Integer;
begin
  for c := 0 to FChannels - 1 do
    if not FCells[Index(ARow, c)].IsEmpty then Exit(False);
  Result := True;
end;

{ ================= TTrackerModule ================= }

constructor TTrackerModule.Create;
begin
  inherited Create;
  FPatterns := TObjectList<TTrackerPattern>.Create(True);
  FInstruments := TObjectList<TTrackerInstrument>.Create(True);
  FName := 'Untitled';
  FChannels := TRK_DEFAULT_CHANNELS;
  FInitialSpeed := TRK_DEFAULT_SPEED;
  FInitialBPM := TRK_DEFAULT_BPM;
  FGlobalVolume := 1.0;
  FRestartPos := 0;
end;

destructor TTrackerModule.Destroy;
begin
  FInstruments.Free;
  FPatterns.Free;
  inherited Destroy;
end;

procedure TTrackerModule.Clear;
begin
  FPatterns.Clear;
  FInstruments.Clear;
  SetLength(FOrder, 0);
  FRestartPos := 0;
end;

procedure TTrackerModule.InitDefault;
begin
  Clear;
  AddPattern(TRK_DEFAULT_ROWS);
  AppendOrder(0);
end;

function TTrackerModule.Clone: TTrackerModule;
var
  i: Integer;
begin
  Result := TTrackerModule.Create;
  Result.FName := FName;
  Result.FChannels := FChannels;
  Result.FInitialSpeed := FInitialSpeed;
  Result.FInitialBPM := FInitialBPM;
  Result.FGlobalVolume := FGlobalVolume;
  Result.FRestartPos := FRestartPos;
  Result.FOrder := Copy(FOrder);
  for i := 0 to FPatterns.Count - 1 do
    Result.FPatterns.Add(FPatterns[i].Clone);
  for i := 0 to FInstruments.Count - 1 do
    Result.FInstruments.Add(FInstruments[i].Clone);
end;

function TTrackerModule.AddPattern(ARows: Integer): TTrackerPattern;
begin
  Result := TTrackerPattern.Create(ARows, FChannels);
  FPatterns.Add(Result);
end;

procedure TTrackerModule.RemovePattern(AIndex: Integer);
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex >= FPatterns.Count) then Exit;
  if FPatterns.Count = 1 then
    RaiseUDAW(errInvalidState, TRK_SUBSYS, 'a module needs at least one pattern');
  FPatterns.Delete(AIndex);
  { fix up the order table: drop references, renumber higher indices }
  i := 0;
  while i < Length(FOrder) do
  begin
    if FOrder[i] = AIndex then
    begin
      DeleteOrder(i);
      Continue;
    end;
    if FOrder[i] > AIndex then Dec(FOrder[i]);
    Inc(i);
  end;
  if Length(FOrder) = 0 then AppendOrder(0);
end;

function TTrackerModule.PatternCount: Integer;
begin
  Result := FPatterns.Count;
end;

function TTrackerModule.GetPattern(AIndex: Integer): TTrackerPattern;
begin
  if (AIndex >= 0) and (AIndex < FPatterns.Count) then
    Result := FPatterns[AIndex]
  else
    Result := nil;
end;

function TTrackerModule.AddInstrument(const AName: string): TTrackerInstrument;
begin
  Result := TTrackerInstrument.Create(AName);
  FInstruments.Add(Result);
end;

procedure TTrackerModule.RemoveInstrument(AIndex1Based: Integer);
begin
  if (AIndex1Based >= 1) and (AIndex1Based <= FInstruments.Count) then
    FInstruments.Delete(AIndex1Based - 1);
end;

function TTrackerModule.InstrumentCount: Integer;
begin
  Result := FInstruments.Count;
end;

function TTrackerModule.GetInstrument(AIndex1Based: Integer): TTrackerInstrument;
begin
  if (AIndex1Based >= 1) and (AIndex1Based <= FInstruments.Count) then
    Result := FInstruments[AIndex1Based - 1]
  else
    Result := nil;
end;

function TTrackerModule.OrderLength: Integer;
begin
  Result := Length(FOrder);
end;

function TTrackerModule.GetOrder(AIndex: Integer): Integer;
begin
  if (AIndex >= 0) and (AIndex < Length(FOrder)) then
    Result := FOrder[AIndex]
  else
    Result := 0;
end;

procedure TTrackerModule.SetOrder(AIndex, APatternIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= Length(FOrder)) then Exit;
  FOrder[AIndex] := ClampInt(APatternIndex, 0, Max(0, FPatterns.Count - 1));
end;

procedure TTrackerModule.InsertOrder(AIndex, APatternIndex: Integer);
var
  i: Integer;
begin
  if AIndex < 0 then AIndex := 0;
  if AIndex > Length(FOrder) then AIndex := Length(FOrder);
  SetLength(FOrder, Length(FOrder) + 1);
  for i := High(FOrder) downto AIndex + 1 do
    FOrder[i] := FOrder[i - 1];
  FOrder[AIndex] := ClampInt(APatternIndex, 0, Max(0, FPatterns.Count - 1));
end;

procedure TTrackerModule.DeleteOrder(AIndex: Integer);
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex >= Length(FOrder)) then Exit;
  for i := AIndex to High(FOrder) - 1 do
    FOrder[i] := FOrder[i + 1];
  SetLength(FOrder, Length(FOrder) - 1);
  if FRestartPos >= Length(FOrder) then FRestartPos := 0;
end;

procedure TTrackerModule.AppendOrder(APatternIndex: Integer);
begin
  InsertOrder(Length(FOrder), APatternIndex);
end;

procedure TTrackerModule.SetChannels(AChannels: Integer);
var
  i: Integer;
begin
  AChannels := ClampInt(AChannels, TRK_MIN_CHANNELS, TRK_MAX_CHANNELS);
  if AChannels = FChannels then Exit;
  FChannels := AChannels;
  for i := 0 to FPatterns.Count - 1 do
    FPatterns[i].SetChannels(AChannels);
end;

function TTrackerModule.Describe: string;
var
  sb: TStringBuilder;
  i: Integer;
begin
  sb := TStringBuilder.Create;
  try
    sb.AppendLine(Format('module "%s": %d ch, speed %d, %d BPM, gvol %.2f',
      [FName, FChannels, FInitialSpeed, FInitialBPM, FGlobalVolume]));
    sb.Append('order: ');
    for i := 0 to High(FOrder) do
    begin
      if i > 0 then sb.Append(' ');
      sb.Append(FOrder[i]);
    end;
    sb.AppendLine(Format('   (restart @ %d)', [FRestartPos]));
    sb.AppendLine(Format('patterns: %d', [FPatterns.Count]));
    for i := 0 to FPatterns.Count - 1 do
      sb.AppendLine(Format('  #%d  %d rows x %d ch', [i, FPatterns[i].Rows, FPatterns[i].Channels]));
    sb.AppendLine(Format('instruments: %d', [FInstruments.Count]));
    for i := 0 to FInstruments.Count - 1 do
      sb.AppendLine(Format('  %2d  %s', [i + 1, FInstruments[i].Describe]));
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

end.
