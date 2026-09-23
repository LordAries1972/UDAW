unit UDAW.Project.Recovery;
{$I udaw.inc}

{ Phase 5 - Project System: autosave + crash recovery (plan sections 56/57).

  TProjectRecoveryManager watches a single open project and, on its own
  schedule, snapshots it into a small rotating set of backups next to the
  project file:

    MySong.udawproj.autosave.1   (newest)
    MySong.udawproj.autosave.2
    MySong.udawproj.autosave.3   (oldest kept)

  The primary project file itself is NEVER touched by autosave - only
  SaveProjectToFile (an explicit user Save) writes it. Autosave always writes
  a *snapshot* (TProjectDocument.Clone) so it never races an edit happening on
  the live document while the write is in flight, and it can run on a
  TJobManager worker rather than the UI thread.

  Crash detection uses a tiny "open marker" file written when a project is
  opened/created and deleted on a clean Close/Save-and-close. If the marker
  is still present the next time the same project path is opened, the
  previous session ended without a clean shutdown, and DetectRecovery reports
  the newest available autosave (or the primary file itself if it is newer
  than every autosave) as a candidate to restore. }

interface

uses
  SysUtils, Classes,
  UDAW.Errors, UDAW.Config,
  UDAW.Project.Document, UDAW.Project.Serialization;

type
  TAutosaveInterval = (aiOff, ai1Min, ai2Min, ai5Min, ai10Min, aiCustom);

  TRecoveryCandidate = record
    FileName: string;
    ModifiedUTC: TDateTime;
    IsAutosave: Boolean;
  end;

  TAutosaveEvent = procedure(ASender: TObject; const AFileName: string) of object;

  TProjectRecoveryManager = class
  private
    FProjectFileName: string;
    FInterval: TAutosaveInterval;
    FCustomMinutes: Integer;
    FMaxBackups: Integer;
    FLastAutosaveUTC: TDateTime;
    FMarkerOpen: Boolean;
    FOnAutosaved: TAutosaveEvent;
    function MarkerFileName: string;
    function BackupFileName(AIndex: Integer): string;
    function IntervalMinutes: Integer;
  public
    constructor Create(AMaxBackups: Integer = 3);
    destructor Destroy; override;

    { Call once a project has been assigned a file name (new-but-unsaved
      projects use a synthetic path under the recovery cache so they still
      get autosaved and recovered). Writes the open marker. }
    procedure BeginSession(const AProjectFileName: string);
    { Call on a clean Save-and-keep-open, Close, or app shutdown. Removes the
      open marker so the next BeginSession does not report a false crash. }
    procedure EndSessionClean;

    property Interval: TAutosaveInterval read FInterval write FInterval;
    property CustomMinutes: Integer read FCustomMinutes write FCustomMinutes;
    property OnAutosaved: TAutosaveEvent read FOnAutosaved write FOnAutosaved;

    { True once IntervalMinutes have elapsed since the last autosave (or since
      BeginSession, if none has happened yet) and autosave is not Off. }
    function DueForAutosave(ANowUTC: TDateTime): Boolean;
    { Snapshots ADoc and rotates it into the newest backup slot. Never writes
      to FProjectFileName. Safe to call from a background job. }
    procedure AutosaveNow(ADoc: TProjectDocument);
    { UI-thread convenience: check DueForAutosave and, if so, AutosaveNow. }
    procedure Tick(ADoc: TProjectDocument; ANowUTC: TDateTime);

    { True if a previous session for this project path ended without calling
      EndSessionClean (or never called it because the app crashed). }
    function HasUncleanShutdown(const AProjectFileName: string): Boolean;
    { Every available recovery candidate for AProjectFileName (autosaves plus
      the primary file itself, if it exists), newest first. }
    function ListRecoveryCandidates(const AProjectFileName: string): TArray<TRecoveryCandidate>;
    { Loads the newest recovery candidate. Raises EUDAWError if none exist. }
    function RecoverNewest(const AProjectFileName: string): TProjectDocument;

    function AutosaveCount(const AProjectFileName: string): Integer;
    function AutosaveFileName(const AProjectFileName: string; AIndex: Integer): string;
  end;

function AutosaveIntervalMinutes(AInterval: TAutosaveInterval; ACustomMinutes: Integer): Integer;
function AutosaveIntervalName(AInterval: TAutosaveInterval): string;
procedure RememberRecentProject(ACfg: TConfig; const AFileName: string);

implementation

{$IFDEF MSWINDOWS}
uses
  Windows;   // expands the inline RenameFile (H2443)
{$ENDIF}

const
  AUTOSAVE_EXT   = '.autosave.';
  OPEN_MARKER_EXT = '.open';

procedure RememberRecentProject(ACfg: TConfig; const AFileName: string);
var paths: TStringList; i: Integer; path, fullPath: string;
begin
  if (ACfg = nil) or (Trim(AFileName) = '') then Exit;
  fullPath := ExpandFileName(AFileName);
  paths := TStringList.Create;
  try
    paths.CaseSensitive := False;
    paths.Add(fullPath);
    for i := 0 to 9 do
    begin
      path := ACfg.GetString('project', 'recent_' + IntToStr(i), '');
      if (path <> '') and (paths.IndexOf(path) < 0) and (paths.Count < 10) then paths.Add(path);
    end;
    for i := 0 to 9 do
      if i < paths.Count then ACfg.SetString('project', 'recent_' + IntToStr(i), paths[i])
      else ACfg.DeleteKey('project', 'recent_' + IntToStr(i));
    ACfg.SetString('project', 'last_project', fullPath);
  finally paths.Free; end;
end;

function FileModifiedUTC(const AFileName: string): TDateTime;
begin
  {$IFDEF FPC}
  { the legacy Integer-returning overload is the one FPC/Lazarus provides;
    -1 means "does not exist". }
  if FileAge(AFileName) = -1 then
    Result := 0
  else
    Result := FileDateToDateTime(FileAge(AFileName));
  {$ELSE}
  if not FileAge(AFileName, Result) then
    Result := 0;
  {$ENDIF}
end;

function AutosaveIntervalMinutes(AInterval: TAutosaveInterval; ACustomMinutes: Integer): Integer;
begin
  case AInterval of
    aiOff:    Result := 0;
    ai1Min:   Result := 1;
    ai2Min:   Result := 2;
    ai5Min:   Result := 5;
    ai10Min:  Result := 10;
    aiCustom: if ACustomMinutes > 0 then Result := ACustomMinutes else Result := 5;
  else
    Result := 0;
  end;
end;

function AutosaveIntervalName(AInterval: TAutosaveInterval): string;
begin
  case AInterval of
    aiOff:    Result := 'Off';
    ai1Min:   Result := 'Every 1 minute';
    ai2Min:   Result := 'Every 2 minutes';
    ai5Min:   Result := 'Every 5 minutes';
    ai10Min:  Result := 'Every 10 minutes';
    aiCustom: Result := 'Custom';
  else
    Result := '?';
  end;
end;

{ ================= TProjectRecoveryManager ================= }

constructor TProjectRecoveryManager.Create(AMaxBackups: Integer);
begin
  inherited Create;
  if AMaxBackups < 1 then AMaxBackups := 1;
  FMaxBackups := AMaxBackups;
  FInterval := ai5Min;
  FCustomMinutes := 5;
end;

destructor TProjectRecoveryManager.Destroy;
begin
  inherited Destroy;
end;

function TProjectRecoveryManager.MarkerFileName: string;
begin
  Result := FProjectFileName + OPEN_MARKER_EXT;
end;

function TProjectRecoveryManager.BackupFileName(AIndex: Integer): string;
begin
  Result := FProjectFileName + AUTOSAVE_EXT + IntToStr(AIndex);
end;

function TProjectRecoveryManager.IntervalMinutes: Integer;
begin
  Result := AutosaveIntervalMinutes(FInterval, FCustomMinutes);
end;

procedure TProjectRecoveryManager.BeginSession(const AProjectFileName: string);
var
  sl: TStringList;
begin
  if Trim(AProjectFileName) = '' then
    RaiseUDAW(errInvalidArgument, PROJECT_SUBSYS, 'BeginSession: empty project file name');
  FProjectFileName := AProjectFileName;
  FLastAutosaveUTC := Now;

  ForceDirectories(ExtractFilePath(FProjectFileName));
  sl := TStringList.Create;
  try
    sl.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    sl.SaveToFile(MarkerFileName);
  finally
    sl.Free;
  end;
  FMarkerOpen := True;
end;

procedure TProjectRecoveryManager.EndSessionClean;
begin
  if (FProjectFileName <> '') and FileExists(MarkerFileName) then
    SysUtils.DeleteFile(MarkerFileName);
  FMarkerOpen := False;
end;

function TProjectRecoveryManager.DueForAutosave(ANowUTC: TDateTime): Boolean;
var
  mins: Integer;
begin
  mins := IntervalMinutes;
  if mins <= 0 then Exit(False);
  Result := (ANowUTC - FLastAutosaveUTC) >= (mins / (24 * 60));
end;

procedure TProjectRecoveryManager.AutosaveNow(ADoc: TProjectDocument);
var
  snapshot: TProjectDocument;
  i: Integer;
  target, source: string;
begin
  if FProjectFileName = '' then Exit;

  { rotate: drop the oldest, shift the rest up, write the fresh snapshot into
    slot 1. Never touches FProjectFileName itself. }
  target := BackupFileName(FMaxBackups);
  if FileExists(target) then
    SysUtils.DeleteFile(target);
  for i := FMaxBackups downto 2 do
  begin
    source := BackupFileName(i - 1);
    if FileExists(source) then
      RenameFile(source, BackupFileName(i));
  end;

  snapshot := ADoc.Clone;
  try
    SaveProjectToFile(snapshot, BackupFileName(1));
  finally
    snapshot.Free;
  end;

  FLastAutosaveUTC := Now;
  if Assigned(FOnAutosaved) then
    FOnAutosaved(Self, BackupFileName(1));
end;

procedure TProjectRecoveryManager.Tick(ADoc: TProjectDocument; ANowUTC: TDateTime);
begin
  if (ADoc = nil) or (FProjectFileName = '') then Exit;
  if not ADoc.Dirty then Exit;   { nothing changed since the last save/autosave }
  if DueForAutosave(ANowUTC) then
    AutosaveNow(ADoc);
end;

function TProjectRecoveryManager.HasUncleanShutdown(const AProjectFileName: string): Boolean;
begin
  Result := FileExists(AProjectFileName + OPEN_MARKER_EXT);
end;

function TProjectRecoveryManager.ListRecoveryCandidates(
  const AProjectFileName: string): TArray<TRecoveryCandidate>;
var
  list: TArray<TRecoveryCandidate>;
  n, i, j: Integer;
  fn: string;
  best: TRecoveryCandidate;
  bestIdx: Integer;
begin
  SetLength(list, 0);
  n := 0;
  for i := 1 to FMaxBackups do
  begin
    fn := AProjectFileName + AUTOSAVE_EXT + IntToStr(i);
    if FileExists(fn) then
    begin
      SetLength(list, n + 1);
      list[n].FileName := fn;
      list[n].ModifiedUTC := FileModifiedUTC(fn);
      list[n].IsAutosave := True;
      Inc(n);
    end;
  end;
  if FileExists(AProjectFileName) then
  begin
    SetLength(list, n + 1);
    list[n].FileName := AProjectFileName;
    list[n].ModifiedUTC := FileModifiedUTC(AProjectFileName);
    list[n].IsAutosave := False;
    Inc(n);
  end;

  { newest first - simple selection sort, n is tiny (<= FMaxBackups + 1) }
  for i := 0 to n - 2 do
  begin
    bestIdx := i;
    best := list[i];
    for j := i + 1 to n - 1 do
      if list[j].ModifiedUTC > best.ModifiedUTC then
      begin
        best := list[j];
        bestIdx := j;
      end;
    if bestIdx <> i then
    begin
      list[bestIdx] := list[i];
      list[i] := best;
    end;
  end;
  Result := list;
end;

function TProjectRecoveryManager.RecoverNewest(const AProjectFileName: string): TProjectDocument;
var
  candidates: TArray<TRecoveryCandidate>;
begin
  candidates := ListRecoveryCandidates(AProjectFileName);
  if Length(candidates) = 0 then
    RaiseUDAWFmt(errFileNotFound, PROJECT_SUBSYS,
      'no recovery data found for "%s"', [AProjectFileName]);
  Result := LoadProjectFromFile(candidates[0].FileName);
  { the recovered document represents unsaved work - mark it dirty against
    the primary project path so the user is prompted to save it }
  Result.FileName := AProjectFileName;
  if candidates[0].IsAutosave then
    Result.Touch;
end;

function TProjectRecoveryManager.AutosaveCount(const AProjectFileName: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to FMaxBackups do
    if FileExists(AProjectFileName + AUTOSAVE_EXT + IntToStr(i)) then
      Inc(Result);
end;

function TProjectRecoveryManager.AutosaveFileName(const AProjectFileName: string;
  AIndex: Integer): string;
begin
  Result := AProjectFileName + AUTOSAVE_EXT + IntToStr(AIndex);
end;

end.
