unit UDAW.AI.Revision;
{$I udaw.inc}

{ AI Composition, Phase 8 - Conversational Revision (docs/AIPlan.md section 17
  "PHASE 8 - CONVERSATIONAL REVISION" and section 12 "AI REVISION SYSTEM").

  TAIRevisionSession is the conversational counterpart to the Phase 27/28
  TAIMixingSession/TAIMasteringSession: it turns one natural-language
  instruction into a proposed TSongSpec (via ICompositionProvider, Phase 3),
  computes the structured change set the proposal represents
  (UDAW.Composer.RevisionHistory.DiffSongSpecs - "Preview structured change
  sets"), and offers the same never-destructive Preview / Compare / Apply /
  Reject workflow: Preview performs the whole revision as ONE
  TSetSongSpecCommand (UDAW.Composer.Commands, already undo-safe), Compare
  toggles it on/off, Reject undoes it, Apply just stops tracking it.

  Every call to Propose is recorded on FHistory (accepted or rejected once
  resolved) - AIPlan.md section 14 "Revision history" / "Accepted and
  rejected suggestions" - and Propose itself always calls
  UDAW.AI.Composer.MergeLockedAndOutOfScope so a Locked section/track, or one
  outside AScopeSectionIds/AScopeTrackIds, can never change no matter what
  the AI returned ("Preserve locked content" / "Modify selected tracks or
  regions"). }

interface

uses
  SysUtils,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics, UDAW.Composer.Commands,
  UDAW.Composer.RevisionHistory,
  UDAW.AI.Composer;

type
  TAIRevisionSession = class
  private
    FDoc: TProjectDocument;
    FCommands: TCommandManager;
    FProvider: ICompositionProvider;
    FHistory: TRevisionHistory;
    FPendingChanges: TArray<TSongSpecChange>;
    FPendingEntry: TRevisionHistoryEntry;
    FPendingCommand: TSetSongSpecCommand; // staged by Propose, not yet performed
    FAppliedCount: Integer;   // 0 or 1: TSetSongSpecCommand pushed by Preview
    FShowingOriginal: Boolean;
    FLastError: string;
  public
    constructor Create(ADoc: TProjectDocument; ACommands: TCommandManager;
      AProvider: ICompositionProvider);
    destructor Destroy; override;

    { Sends AInstruction to the AI provider as a revision of the project's
      current TSongSpec/TLyricDocument, merges locked/out-of-scope content
      back in, diffs the result against the current spec and stages it as
      the pending proposal (does not touch the project yet - call Preview
      for that). Returns False (GetLastError set) if the provider failed or
      returned nothing usable; the project is left untouched either way. }
    function Propose(const AInstruction: string): Boolean; overload;
    function Propose(const AInstruction: string; const AScopeTrackIds: TArray<string>;
      const AScopeSectionIds: TArray<string>): Boolean; overload;

    property PendingChanges: TArray<TSongSpecChange> read FPendingChanges;
    function HasPendingProposal: Boolean;
    function HasPendingPreview: Boolean;
    function GetLastError: string;

    { Applies the pending proposal to the project as one undo-safe command so
      it can be heard/seen immediately. }
    procedure Preview;
    { Toggles between the previewed revision and the original. }
    procedure CompareToggle;
    { Keeps the previewed revision (already on the undo stack) and marks the
      pending history entry Accepted. }
    procedure Apply;
    { Undoes the previewed revision (if any) and marks the pending history
      entry rejected. }
    procedure Reject;

    property History: TRevisionHistory read FHistory;
  end;

implementation

constructor TAIRevisionSession.Create(ADoc: TProjectDocument; ACommands: TCommandManager;
  AProvider: ICompositionProvider);
begin
  inherited Create;
  FDoc := ADoc;
  FCommands := ACommands;
  FProvider := AProvider;
  FHistory := TRevisionHistory.Create;
end;

destructor TAIRevisionSession.Destroy;
begin
  FPendingCommand.Free; // no-op if already handed to FCommands (never re-owned after Preview)
  FHistory.Free;
  inherited Destroy;
end;

function TAIRevisionSession.GetLastError: string;
begin
  Result := FLastError;
end;

function TAIRevisionSession.HasPendingProposal: Boolean;
begin
  Result := FPendingEntry <> nil;
end;

function TAIRevisionSession.HasPendingPreview: Boolean;
begin
  Result := FAppliedCount > 0;
end;

function TAIRevisionSession.Propose(const AInstruction: string): Boolean;
begin
  Result := Propose(AInstruction, nil, nil);
end;

function TAIRevisionSession.Propose(const AInstruction: string;
  const AScopeTrackIds, AScopeSectionIds: TArray<string>): Boolean;
var
  revisedSpec: TSongSpec;
  revisedLyrics: TLyricDocument;
begin
  Result := False;
  FLastError := '';

  if FAppliedCount > 0 then
    Reject; { don't stack a second proposal on an unresolved preview }

  if FPendingEntry <> nil then
  begin
    if not FPendingEntry.Resolved then
    begin
      FPendingEntry.Resolved := True;
      FPendingEntry.Accepted := False; // superseded by a new instruction, never previewed
    end;
    FPendingEntry := nil;
  end;
  FreeAndNil(FPendingCommand); // any unpreviewed proposal this call replaces

  if FProvider = nil then
  begin
    FLastError := 'no AI provider configured';
    Exit;
  end;

  FProvider.SubmitRevisionRequest(FDoc.SongSpec, FDoc.Lyrics, AInstruction,
    revisedSpec, revisedLyrics, AScopeTrackIds, AScopeSectionIds);

  if revisedSpec = nil then
  begin
    FLastError := FProvider.GetLastError;
    if FLastError = '' then FLastError := 'the AI did not return a usable revision';
    Exit;
  end;

  FPendingChanges := DiffSongSpecs(FDoc.SongSpec, revisedSpec);
  FPendingEntry := FHistory.Add(AInstruction, FPendingChanges, FProvider.ProviderId, '');

  { Stash the proposal in one command, but do not perform it yet - Preview
    does that. TSetSongSpecCommand adopts revisedSpec/revisedLyrics and
    frees them on destruction whether or not it was ever performed. }
  FPendingCommand := TSetSongSpecCommand.Create(FDoc, revisedSpec, revisedLyrics,
    Format('AI revision: %s', [AInstruction]));

  Result := True;
end;

procedure TAIRevisionSession.Preview;
var
  cmd: TSetSongSpecCommand;
begin
  if FAppliedCount > 0 then Exit;   // already previewing
  if FPendingCommand = nil then Exit;
  FShowingOriginal := False;
  cmd := FPendingCommand;
  FPendingCommand := nil; // FCommands.Perform takes ownership (success or failure)
  if FCommands.Perform(cmd) then
    FAppliedCount := 1;
end;

procedure TAIRevisionSession.CompareToggle;
begin
  if FAppliedCount = 0 then Exit;
  if FShowingOriginal then
  begin
    FCommands.Redo;
    FShowingOriginal := False;
  end
  else
  begin
    FCommands.Undo;
    FShowingOriginal := True;
  end;
end;

procedure TAIRevisionSession.Apply;
begin
  if FShowingOriginal then CompareToggle;
  FAppliedCount := 0;
  if FPendingEntry <> nil then
  begin
    FPendingEntry.Resolved := True;
    FPendingEntry.Accepted := True;
    FPendingEntry := nil;
  end;
  FPendingChanges := [];
end;

procedure TAIRevisionSession.Reject;
begin
  if FShowingOriginal then
  begin
    FAppliedCount := 0;
  end
  else if FAppliedCount > 0 then
  begin
    FCommands.Undo;
    FAppliedCount := 0;
  end
  else
    FreeAndNil(FPendingCommand); // proposal was never previewed - just drop it
  if FPendingEntry <> nil then
  begin
    FPendingEntry.Resolved := True;
    FPendingEntry.Accepted := False;
    FPendingEntry := nil;
  end;
  FPendingChanges := [];
end;

end.
