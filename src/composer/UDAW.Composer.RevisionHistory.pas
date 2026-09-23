unit UDAW.Composer.RevisionHistory;
{$I udaw.inc}

{ AI Composition, Phase 8 - Conversational Revision (docs/AIPlan.md section 17
  "PHASE 8 - CONVERSATIONAL REVISION": "Preview structured change sets" and
  "Record complete revision history").

  DiffSongSpecs compares two TSongSpec snapshots (the spec before a revision
  instruction and the spec the AI proposed in reply to it) and produces a
  flat list of human-readable TSongSpecChange records - added/removed/
  modified sections, tracks and chord progressions, plus top-level meta
  changes. This is the "structured change set" AIPlan.md asks a revision to
  be previewable as, instead of only being able to show the whole rewritten
  specification.

  TRevisionHistory is an ordered, in-memory log of every revision instruction
  a project's AI Composer session has run, each entry carrying its own diff
  and whether the user accepted or rejected it - AIPlan.md section 14's
  "Revision history" / "Accepted and rejected suggestions". It lives on the
  session (UDAW.AI.Revision.TAIRevisionSession), not the project file: the
  underlying edits themselves are already permanent, undo-safe project
  history via TSetSongSpecCommand (UDAW.Composer.Commands) once accepted;
  this list is the conversational record of *why* each one happened. }

interface

uses
  SysUtils, Generics.Collections,
  UDAW.Composer.SongSpec;

type
  TSongSpecChangeKind = (
    scMetaChanged,
    scSectionAdded, scSectionRemoved, scSectionModified,
    scTrackAdded, scTrackRemoved, scTrackModified,
    scHarmonyChanged);

  TSongSpecChange = record
    Kind: TSongSpecChangeKind;
    TargetId: string;
    Description: string;
  end;

{ Compares AOld (may be nil, meaning "no prior spec") against ANew (must not
  be nil) and returns every difference found, most-relevant order (meta,
  then sections, then tracks, then harmony). Section/track identity is by
  Id; a track/section whose Id is not present in ANew is "removed", one not
  present in AOld is "added", otherwise it is compared field-by-field. }
function DiffSongSpecs(AOld, ANew: TSongSpec): TArray<TSongSpecChange>;

function ChangeKindId(AKind: TSongSpecChangeKind): string;

type
  { One AIPlan.md section 12 revision round-trip. Owns nothing external;
    Changes is a plain snapshot taken at the time the revision was proposed. }
  TRevisionHistoryEntry = class
  private
    FTimestamp: TDateTime;
    FInstruction: string;
    FChanges: TArray<TSongSpecChange>;
    FAccepted: Boolean;
    FResolved: Boolean; // False while still pending preview/compare
    FProviderId: string;
    FModelId: string;
  public
    constructor Create(const AInstruction: string; const AChanges: TArray<TSongSpecChange>;
      const AProviderId, AModelId: string);
    property Timestamp: TDateTime read FTimestamp;
    property Instruction: string read FInstruction;
    property Changes: TArray<TSongSpecChange> read FChanges;
    property Accepted: Boolean read FAccepted write FAccepted;
    property Resolved: Boolean read FResolved write FResolved;
    property ProviderId: string read FProviderId;
    property ModelId: string read FModelId;
    function Summary: string;
  end;

  { AIPlan.md section 14: "Revision history" / "Accepted and rejected
    suggestions" - an ordered, append-only (aside from Clear) log. }
  TRevisionHistory = class
  private
    FEntries: TObjectList<TRevisionHistoryEntry>;
  public
    constructor Create;
    destructor Destroy; override;
    function Add(const AInstruction: string; const AChanges: TArray<TSongSpecChange>;
      const AProviderId, AModelId: string): TRevisionHistoryEntry;
    procedure Clear;
    function Count: Integer;
    function Entry(AIndex: Integer): TRevisionHistoryEntry;
    property Entries: TObjectList<TRevisionHistoryEntry> read FEntries;
  end;

implementation

function ChangeKindId(AKind: TSongSpecChangeKind): string;
begin
  case AKind of
    scMetaChanged:      Result := 'meta_changed';
    scSectionAdded:      Result := 'section_added';
    scSectionRemoved:    Result := 'section_removed';
    scSectionModified:  Result := 'section_modified';
    scTrackAdded:        Result := 'track_added';
    scTrackRemoved:      Result := 'track_removed';
    scTrackModified:    Result := 'track_modified';
    scHarmonyChanged:    Result := 'harmony_changed';
  else
    Result := 'unknown';
  end;
end;

function DiffSongSpecs(AOld, ANew: TSongSpec): TArray<TSongSpecChange>;
var
  list: TList<TSongSpecChange>;
  c: TSongSpecChange;
  i: Integer;
  oldSec, newSec: TSongSection;
  oldTrk, newTrk: TSongTrackSpec;
  oldProg, newProg: TChordProgressionEntry;
  j: Integer;

  procedure Add(AKind: TSongSpecChangeKind; const ATargetId, ADescription: string);
  begin
    c.Kind := AKind;
    c.TargetId := ATargetId;
    c.Description := ADescription;
    list.Add(c);
  end;

  function ChordsText(const AChords: TArray<string>): string;
  var
    j: Integer;
  begin
    Result := '';
    for j := 0 to High(AChords) do
    begin
      if j > 0 then Result := Result + ' ';
      Result := Result + AChords[j];
    end;
  end;

begin
  list := TList<TSongSpecChange>.Create;
  try
    if ANew = nil then Exit(nil);

    { ---- meta ---- }
    if (AOld = nil)
      or (AOld.Meta.Title <> ANew.Meta.Title)
      or (AOld.Meta.Instrumental <> ANew.Meta.Instrumental)
      or (AOld.Meta.Tempo <> ANew.Meta.Tempo)
      or (AOld.Meta.Key <> ANew.Meta.Key)
      or (AOld.Meta.Scale <> ANew.Meta.Scale)
      or (AOld.Meta.TimeSigNum <> ANew.Meta.TimeSigNum)
      or (AOld.Meta.TimeSigDen <> ANew.Meta.TimeSigDen)
      or (AOld.Meta.DurationBars <> ANew.Meta.DurationBars) then
    begin
      if AOld = nil then
        Add(scMetaChanged, '', Format('"%s" - %s %.0f BPM, %d/%d, %d bars',
          [ANew.Meta.Title, ANew.Meta.Key + ' ' + ANew.Meta.Scale, ANew.Meta.Tempo,
           ANew.Meta.TimeSigNum, ANew.Meta.TimeSigDen, ANew.Meta.DurationBars]))
      else
        Add(scMetaChanged, '', Format('Title/key/tempo/signature/length changed: "%s" -> "%s", ' +
          '%s %s -> %s %s, %.0f -> %.0f BPM, %d/%d -> %d/%d, %d -> %d bars',
          [AOld.Meta.Title, ANew.Meta.Title, AOld.Meta.Key, AOld.Meta.Scale,
           ANew.Meta.Key, ANew.Meta.Scale, AOld.Meta.Tempo, ANew.Meta.Tempo,
           AOld.Meta.TimeSigNum, AOld.Meta.TimeSigDen, ANew.Meta.TimeSigNum, ANew.Meta.TimeSigDen,
           AOld.Meta.DurationBars, ANew.Meta.DurationBars]));
    end;

    { ---- sections: removed + modified ---- }
    if AOld <> nil then
      for i := 0 to AOld.Sections.Count - 1 do
      begin
        oldSec := AOld.Sections[i];
        newSec := ANew.SectionById(oldSec.Id);
        if newSec = nil then
          Add(scSectionRemoved, oldSec.Id, Format('Section "%s" removed', [oldSec.Name]))
        else if (newSec.StartBar <> oldSec.StartBar) or (newSec.LengthBars <> oldSec.LengthBars)
          or (Abs(newSec.Energy - oldSec.Energy) > 1e-6) or (newSec.Name <> oldSec.Name) then
          Add(scSectionModified, oldSec.Id, Format(
            'Section "%s": bars %d-%d (energy %.2f) -> "%s": bars %d-%d (energy %.2f)',
            [oldSec.Name, oldSec.StartBar, oldSec.EndBarExclusive - 1, oldSec.Energy,
             newSec.Name, newSec.StartBar, newSec.EndBarExclusive - 1, newSec.Energy]));
      end;
    { sections: added }
    for i := 0 to ANew.Sections.Count - 1 do
    begin
      newSec := ANew.Sections[i];
      if (AOld = nil) or (AOld.SectionById(newSec.Id) = nil) then
        Add(scSectionAdded, newSec.Id, Format('Section "%s" added (bars %d-%d)',
          [newSec.Name, newSec.StartBar, newSec.EndBarExclusive - 1]));
    end;

    { ---- tracks: removed + modified ---- }
    if AOld <> nil then
      for i := 0 to AOld.Tracks.Count - 1 do
      begin
        oldTrk := AOld.Tracks[i];
        newTrk := ANew.TrackById(oldTrk.Id);
        if newTrk = nil then
          Add(scTrackRemoved, oldTrk.Id, Format('Track "%s" removed', [oldTrk.Name]))
        else if (newTrk.Name <> oldTrk.Name) or (newTrk.Role <> oldTrk.Role)
          or (newTrk.Kind <> oldTrk.Kind) or (newTrk.PreferredInstrumentId <> oldTrk.PreferredInstrumentId)
          or (newTrk.FallbackCategory <> oldTrk.FallbackCategory) then
          Add(scTrackModified, oldTrk.Id, Format('Track "%s" (%s) -> "%s" (%s)',
            [oldTrk.Name, oldTrk.Role, newTrk.Name, newTrk.Role]));
      end;
    { tracks: added }
    for i := 0 to ANew.Tracks.Count - 1 do
    begin
      newTrk := ANew.Tracks[i];
      if (AOld = nil) or (AOld.TrackById(newTrk.Id) = nil) then
        Add(scTrackAdded, newTrk.Id, Format('Track "%s" added (role %s)', [newTrk.Name, newTrk.Role]));
    end;

    { ---- harmony: added/removed/modified by section id ---- }
    if AOld <> nil then
      for i := 0 to AOld.Harmony.Count - 1 do
      begin
        oldProg := AOld.Harmony[i];
        newProg := nil;
        for j := 0 to ANew.Harmony.Count - 1 do
          if SameText(ANew.Harmony[j].SectionId, oldProg.SectionId) then
          begin
            newProg := ANew.Harmony[j];
            Break;
          end;
        if newProg = nil then
          Add(scHarmonyChanged, oldProg.SectionId,
            Format('Chord progression for "%s" removed (%s)', [oldProg.SectionId, ChordsText(oldProg.Chords)]))
        else if ChordsText(newProg.Chords) <> ChordsText(oldProg.Chords) then
          Add(scHarmonyChanged, oldProg.SectionId, Format('Chords for "%s": %s -> %s',
            [oldProg.SectionId, ChordsText(oldProg.Chords), ChordsText(newProg.Chords)]));
      end;
    for i := 0 to ANew.Harmony.Count - 1 do
    begin
      newProg := ANew.Harmony[i];
      oldProg := nil;
      if AOld <> nil then
        for j := 0 to AOld.Harmony.Count - 1 do
          if SameText(AOld.Harmony[j].SectionId, newProg.SectionId) then
          begin
            oldProg := AOld.Harmony[j];
            Break;
          end;
      if oldProg = nil then
        Add(scHarmonyChanged, newProg.SectionId,
          Format('Chord progression for "%s" added (%s)', [newProg.SectionId, ChordsText(newProg.Chords)]));
    end;

    Result := list.ToArray;
  finally
    list.Free;
  end;
end;

{ TRevisionHistoryEntry }

constructor TRevisionHistoryEntry.Create(const AInstruction: string;
  const AChanges: TArray<TSongSpecChange>; const AProviderId, AModelId: string);
begin
  inherited Create;
  FTimestamp := Now;
  FInstruction := AInstruction;
  FChanges := Copy(AChanges);
  FProviderId := AProviderId;
  FModelId := AModelId;
  FResolved := False;
end;

function TRevisionHistoryEntry.Summary: string;
var
  i: Integer;
  status: string;
begin
  if not FResolved then status := 'pending'
  else if FAccepted then status := 'accepted'
  else status := 'rejected';
  Result := Format('[%s] "%s" (%s, %d change(s)):', [status, FInstruction,
    FormatDateTime('yyyy-mm-dd hh:nn', FTimestamp), Length(FChanges)]);
  for i := 0 to High(FChanges) do
    Result := Result + #10 + '  - ' + FChanges[i].Description;
end;

{ TRevisionHistory }

constructor TRevisionHistory.Create;
begin
  inherited Create;
  FEntries := TObjectList<TRevisionHistoryEntry>.Create(True);
end;

destructor TRevisionHistory.Destroy;
begin
  FEntries.Free;
  inherited Destroy;
end;

function TRevisionHistory.Add(const AInstruction: string; const AChanges: TArray<TSongSpecChange>;
  const AProviderId, AModelId: string): TRevisionHistoryEntry;
begin
  Result := TRevisionHistoryEntry.Create(AInstruction, AChanges, AProviderId, AModelId);
  FEntries.Add(Result);
end;

procedure TRevisionHistory.Clear;
begin
  FEntries.Clear;
end;

function TRevisionHistory.Count: Integer;
begin
  Result := FEntries.Count;
end;

function TRevisionHistory.Entry(AIndex: Integer): TRevisionHistoryEntry;
begin
  Result := FEntries[AIndex];
end;

end.
