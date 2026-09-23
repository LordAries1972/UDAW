unit UDAW.Composer.Commands;
{$I udaw.inc}

{ AI Composition, Phase 1 - Internal Data Model (docs/AIPlan.md section 17
  Phase 1's "Implement timeline command and Undo support", and section 12
  "AI Revision System": "Keep a complete Undo transaction" / "The AI should
  never rebuild the entire project when only one section was requested").

  These TDAWCommand descendants edit a project's TSongSpec/TLyricDocument
  (owned by TProjectDocument - UDAW.Project.Document) through the existing
  TCommandManager (UDAW.Project.Commands) - no new undo manager is
  introduced. TSetSongSpecCommand replaces the whole spec/lyrics pair in
  one undo step (a fresh AI generation, or a revision the AI chose to
  answer with a full rewrite); the targeted commands let a small revision
  ("shorten the intro to four bars") cost one small undo step instead of
  discarding the rest of the arrangement.

  This unit is intentionally separate from the TIMELINE/MIDI/MIXER command
  units it sits alongside - it mutates the *specification* (musical
  intent), never the realised timeline/MIDI/mixer content; a later phase's
  arrangement engine is what turns a validated TSongSpec into those other
  commands. }

interface

uses
  SysUtils, Math,
  UDAW.Errors,
  UDAW.Project.Commands, UDAW.Project.Document,
  UDAW.MIDI.Serialization, UDAW.MIDI.Sequence, UDAW.MIDI.PianoRoll,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics, UDAW.Composer.VocalGuide;

type
  TComposerCommand = class abstract(TDAWCommand)
  protected
    FDoc: TProjectDocument;
  public
    constructor Create(ADoc: TProjectDocument);
  end;

  { Replaces the document's entire TSongSpec/TLyricDocument pair (adopts
    both - the caller must not free them after a successful Perform). Used
    for a brand-new generation or an AI revision that rewrote the whole
    spec. }
  TSetSongSpecCommand = class(TComposerCommand)
  private
    FNewSpec: TSongSpec;
    FNewLyrics: TLyricDocument;
    FOldSpec: TSongSpec;
    FOldLyrics: TLyricDocument;
    FDescription: string;
  public
    constructor Create(ADoc: TProjectDocument; ANewSpec: TSongSpec; ANewLyrics: TLyricDocument;
      const ADescription: string = 'Generate song specification');
    destructor Destroy; override;
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { Edits one section's placement/energy in place - "shorten the intro to
    four bars" costs one small undo step instead of a whole-spec replace. }
  TUpdateSongSectionCommand = class(TComposerCommand)
  private
    FSectionId: string;
    FNewStartBar, FNewLengthBars: Integer;
    FNewEnergy: Double;
    FOldStartBar, FOldLengthBars: Integer;
    FOldEnergy: Double;
    FFound: Boolean;
  public
    constructor Create(ADoc: TProjectDocument; const ASectionId: string;
      ANewStartBar, ANewLengthBars: Integer; ANewEnergy: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { Adds (or replaces, if one already exists for the section) a chord
    progression entry - adopts AEntry on success. }
  TSetChordProgressionCommand = class(TComposerCommand)
  private
    FEntry: TChordProgressionEntry;
    FReplacedIndex: Integer; // -1 if this was a pure add
    FReplaced: TChordProgressionEntry;
  public
    constructor Create(ADoc: TProjectDocument; AEntry: TChordProgressionEntry);
    destructor Destroy; override;
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { Sets (creating the lyric section if needed) the text/timing of one
    lyric line, addressed by section id + line index. Passing AIndex = the
    section's current line count appends a new line. }
  TSetLyricLineCommand = class(TComposerCommand)
  private
    FSectionId: string;
    FIndex: Integer;
    FNewText: string;
    FNewStartBar, FNewDurationBars: Integer;
    FOldText: string;
    FOldStartBar, FOldDurationBars: Integer;
    FWasNewLine: Boolean;
    FCreatedSection: Boolean;
  public
    constructor Create(ADoc: TProjectDocument; const ASectionId: string; AIndex: Integer;
      const ANewText: string; ANewStartBar, ANewDurationBars: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { Manual-timing tool (AIPlan.md section 7 step 9 / "manual timing
    corrections"): removes one lyric line, addressed by section id + index. }
  TRemoveLyricLineCommand = class(TComposerCommand)
  private
    FSectionId: string;
    FIndex: Integer;
    FRemoved: TLyricLine;
    FRemovedSection: Boolean;
  public
    constructor Create(ADoc: TProjectDocument; const ASectionId: string; AIndex: Integer);
    destructor Destroy; override;
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { AIPlan.md section 17 PHASE 5 "Generate vocal guide notes": (re)generates
    the guide-vocal MIDI notes for AVocalTrackId's clip from the document's
    current TLyricDocument, one undo step. Any prior guide notes on that
    track are replaced (so regenerating after an edit does not pile up
    stale notes); an instrumental section (no matching TLyricSection) is
    simply skipped, as VocalGuide.GenerateVocalGuide already does. }
  TGenerateVocalGuideCommand = class(TComposerCommand)
  private
    FVocalTrackId: string;
    FNoteRangeLow, FNoteRangeHigh: Integer;
    FBeforeMidi: TMidiProject;
    FAfterMidi: TMidiProject;
    FGenerated: Integer;
    function FindOrCreateClip(const ATrackName: string; out ATrackSeqIndex: Integer): TMidiSequence;
  public
    constructor Create(ADoc: TProjectDocument; const AVocalTrackId: string;
      ANoteRangeLow: Integer = 57; ANoteRangeHigh: Integer = 74);
    destructor Destroy; override;
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    property Generated: Integer read FGenerated;
  end;

implementation

const
  SUBSYS = 'Composer.Commands';

{ TComposerCommand }

constructor TComposerCommand.Create(ADoc: TProjectDocument);
begin
  inherited Create;
  if ADoc = nil then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'a composer command requires a project document');
  FDoc := ADoc;
end;

{ TSetSongSpecCommand }

constructor TSetSongSpecCommand.Create(ADoc: TProjectDocument; ANewSpec: TSongSpec;
  ANewLyrics: TLyricDocument; const ADescription: string);
begin
  inherited Create(ADoc);
  FNewSpec := ANewSpec;
  FNewLyrics := ANewLyrics;
  FDescription := ADescription;
end;

destructor TSetSongSpecCommand.Destroy;
begin
  FNewSpec.Free;
  FNewLyrics.Free;
  FOldSpec.Free;
  FOldLyrics.Free;
  inherited Destroy;
end;

function TSetSongSpecCommand.Execute: Boolean;
begin
  if FOldSpec = nil then
  begin
    FOldSpec := FDoc.SongSpec.Clone;
    FOldLyrics := FDoc.Lyrics.Clone;
  end;
  FDoc.ReplaceSongSpec(FNewSpec.Clone);
  FDoc.ReplaceLyrics(FNewLyrics.Clone);
  Result := True;
end;

procedure TSetSongSpecCommand.Undo;
begin
  FDoc.ReplaceSongSpec(FOldSpec.Clone);
  FDoc.ReplaceLyrics(FOldLyrics.Clone);
end;

function TSetSongSpecCommand.Description: string;
begin
  Result := FDescription;
end;

{ TUpdateSongSectionCommand }

constructor TUpdateSongSectionCommand.Create(ADoc: TProjectDocument; const ASectionId: string;
  ANewStartBar, ANewLengthBars: Integer; ANewEnergy: Double);
begin
  inherited Create(ADoc);
  FSectionId := ASectionId;
  FNewStartBar := ANewStartBar;
  FNewLengthBars := ANewLengthBars;
  FNewEnergy := ANewEnergy;
  FFound := False;
end;

function TUpdateSongSectionCommand.Execute: Boolean;
var
  sec: TSongSection;
begin
  sec := FDoc.SongSpec.SectionById(FSectionId);
  if sec = nil then Exit(False);
  FOldStartBar := sec.StartBar;
  FOldLengthBars := sec.LengthBars;
  FOldEnergy := sec.Energy;
  FFound := True;
  sec.StartBar := FNewStartBar;
  sec.LengthBars := FNewLengthBars;
  sec.Energy := FNewEnergy;
  FDoc.Touch;
  Result := True;
end;

procedure TUpdateSongSectionCommand.Undo;
var
  sec: TSongSection;
begin
  if not FFound then Exit;
  sec := FDoc.SongSpec.SectionById(FSectionId);
  if sec = nil then Exit;
  sec.StartBar := FOldStartBar;
  sec.LengthBars := FOldLengthBars;
  sec.Energy := FOldEnergy;
  FDoc.Touch;
end;

function TUpdateSongSectionCommand.Description: string;
begin
  Result := Format('Update section "%s"', [FSectionId]);
end;

{ TSetChordProgressionCommand }

constructor TSetChordProgressionCommand.Create(ADoc: TProjectDocument; AEntry: TChordProgressionEntry);
begin
  inherited Create(ADoc);
  FEntry := AEntry;
  FReplacedIndex := -1;
end;

destructor TSetChordProgressionCommand.Destroy;
begin
  FEntry.Free;
  FReplaced.Free;
  inherited Destroy;
end;

function TSetChordProgressionCommand.Execute: Boolean;
var
  i: Integer;
begin
  FReplacedIndex := -1;
  for i := 0 to FDoc.SongSpec.Harmony.Count - 1 do
    if SameText(FDoc.SongSpec.Harmony[i].SectionId, FEntry.SectionId) then
    begin
      FReplacedIndex := i;
      Break;
    end;
  if FReplacedIndex >= 0 then
  begin
    FReplaced := FDoc.SongSpec.Harmony[FReplacedIndex].Clone;
    FDoc.SongSpec.Harmony.Extract(FDoc.SongSpec.Harmony[FReplacedIndex]).Free;
  end;
  FDoc.SongSpec.AddChordProgression(FEntry.Clone);
  FDoc.Touch;
  Result := True;
end;

procedure TSetChordProgressionCommand.Undo;
var
  i: Integer;
begin
  for i := FDoc.SongSpec.Harmony.Count - 1 downto 0 do
    if SameText(FDoc.SongSpec.Harmony[i].SectionId, FEntry.SectionId) then
    begin
      FDoc.SongSpec.Harmony.Delete(i);
      Break;
    end;
  if FReplaced <> nil then
    FDoc.SongSpec.AddChordProgression(FReplaced.Clone);
  FDoc.Touch;
end;

function TSetChordProgressionCommand.Description: string;
begin
  Result := Format('Set chord progression for section "%s"', [FEntry.SectionId]);
end;

{ TSetLyricLineCommand }

constructor TSetLyricLineCommand.Create(ADoc: TProjectDocument; const ASectionId: string;
  AIndex: Integer; const ANewText: string; ANewStartBar, ANewDurationBars: Integer);
begin
  inherited Create(ADoc);
  FSectionId := ASectionId;
  FIndex := AIndex;
  FNewText := ANewText;
  FNewStartBar := ANewStartBar;
  FNewDurationBars := ANewDurationBars;
end;

function TSetLyricLineCommand.Execute: Boolean;
var
  lsec: TLyricSection;
  line: TLyricLine;
begin
  lsec := FDoc.Lyrics.SectionById(FSectionId);
  FCreatedSection := lsec = nil;
  if lsec = nil then
    lsec := FDoc.Lyrics.AddSection(TLyricSection.Create(FSectionId));

  FWasNewLine := FIndex >= lsec.Lines.Count;
  if FWasNewLine then
  begin
    lsec.AddLine(TLyricLine.Create(FNewText, FNewStartBar, FNewDurationBars));
  end
  else
  begin
    line := lsec.Lines[FIndex];
    FOldText := line.Text;
    FOldStartBar := line.StartBar;
    FOldDurationBars := line.DurationBars;
    line.Text := FNewText;
    line.StartBar := FNewStartBar;
    line.DurationBars := FNewDurationBars;
  end;
  FDoc.Touch;
  Result := True;
end;

procedure TSetLyricLineCommand.Undo;
var
  lsec: TLyricSection;
begin
  lsec := FDoc.Lyrics.SectionById(FSectionId);
  if lsec = nil then Exit;
  if FWasNewLine then
    lsec.Lines.Delete(lsec.Lines.Count - 1)
  else if (FIndex >= 0) and (FIndex < lsec.Lines.Count) then
  begin
    lsec.Lines[FIndex].Text := FOldText;
    lsec.Lines[FIndex].StartBar := FOldStartBar;
    lsec.Lines[FIndex].DurationBars := FOldDurationBars;
  end;
  if FCreatedSection and (lsec.Lines.Count = 0) then
    FDoc.Lyrics.Sections.Remove(lsec);
  FDoc.Touch;
end;

function TSetLyricLineCommand.Description: string;
begin
  Result := Format('Edit lyric line in section "%s"', [FSectionId]);
end;

{ TRemoveLyricLineCommand }

constructor TRemoveLyricLineCommand.Create(ADoc: TProjectDocument; const ASectionId: string;
  AIndex: Integer);
begin
  inherited Create(ADoc);
  FSectionId := ASectionId;
  FIndex := AIndex;
end;

destructor TRemoveLyricLineCommand.Destroy;
begin
  FRemoved.Free;
  inherited Destroy;
end;

function TRemoveLyricLineCommand.Execute: Boolean;
var
  lsec: TLyricSection;
begin
  lsec := FDoc.Lyrics.SectionById(FSectionId);
  if (lsec = nil) or (FIndex < 0) or (FIndex >= lsec.Lines.Count) then Exit(False);
  FRemoved.Free;
  FRemoved := lsec.Lines[FIndex].Clone;
  lsec.Lines.Delete(FIndex);
  FRemovedSection := lsec.Lines.Count = 0;
  if FRemovedSection then
    FDoc.Lyrics.Sections.Remove(lsec);
  FDoc.Touch;
  Result := True;
end;

procedure TRemoveLyricLineCommand.Undo;
var
  lsec: TLyricSection;
begin
  if FRemoved = nil then Exit;
  lsec := FDoc.Lyrics.SectionById(FSectionId);
  if lsec = nil then
    lsec := FDoc.Lyrics.AddSection(TLyricSection.Create(FSectionId));
  lsec.Lines.Insert(Min(FIndex, lsec.Lines.Count), FRemoved.Clone);
  FDoc.Touch;
end;

function TRemoveLyricLineCommand.Description: string;
begin
  Result := Format('Remove lyric line from section "%s"', [FSectionId]);
end;

{ TGenerateVocalGuideCommand }

constructor TGenerateVocalGuideCommand.Create(ADoc: TProjectDocument; const AVocalTrackId: string;
  ANoteRangeLow, ANoteRangeHigh: Integer);
begin
  inherited Create(ADoc);
  if Trim(AVocalTrackId) = '' then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'a vocal guide command requires a track id');
  FVocalTrackId := AVocalTrackId;
  FNoteRangeLow := ANoteRangeLow;
  FNoteRangeHigh := ANoteRangeHigh;
end;

destructor TGenerateVocalGuideCommand.Destroy;
begin
  FBeforeMidi.Free;
  FAfterMidi.Free;
  inherited Destroy;
end;

function TGenerateVocalGuideCommand.FindOrCreateClip(const ATrackName: string;
  out ATrackSeqIndex: Integer): TMidiSequence;
var
  i, j: Integer;
  seq: TMidiSequence;
begin
  for i := 0 to FDoc.Midi.ClipCount - 1 do
  begin
    seq := FDoc.Midi.Clip(i);
    if SameText(FDoc.Midi.ClipName(i), ATrackName) then
    begin
      for j := 0 to seq.TrackCount - 1 do
        if SameText(seq.GetTrack(j).Name, ATrackName) then
        begin
          ATrackSeqIndex := j;
          Exit(seq);
        end;
      ATrackSeqIndex := seq.TrackCount;
      seq.AddTrack(ATrackName);
      Exit(seq);
    end;
  end;
  seq := FDoc.Midi.NewClip(ATrackName);
  seq.AddTrack(ATrackName);
  ATrackSeqIndex := 0;
  Result := seq;
end;

function TGenerateVocalGuideCommand.Execute: Boolean;
var
  trkSpec: TSongTrackSpec;
  seq: TMidiSequence;
  trackSeqIdx, i: Integer;
  pr: TPianoRoll;
  ids: TArray<Integer>;
begin
  trkSpec := FDoc.SongSpec.TrackById(FVocalTrackId);
  if (trkSpec = nil) or (trkSpec.Kind <> stkMidi) then Exit(False);

  FBeforeMidi.Free;
  FBeforeMidi := FDoc.Midi.Clone;

  seq := FindOrCreateClip(trkSpec.Name, trackSeqIdx);
  pr := TPianoRoll.Create(seq, trackSeqIdx);
  try
    { drop any previously-generated guide notes before regenerating }
    ids := nil;
    for i := 0 to seq.GetTrack(trackSeqIdx).NoteCount - 1 do
      ids := ids + [seq.GetTrack(trackSeqIdx).Notes[i].Id];
    for i := 0 to High(ids) do
      pr.DeleteNote(ids[i]);

    FGenerated := 0;
    for i := 0 to FDoc.SongSpec.Sections.Count - 1 do
      Inc(FGenerated, GenerateVocalGuide(FDoc.SongSpec, FDoc.Lyrics,
        FDoc.SongSpec.Sections[i].Id, pr, seq.PPQ,
        Max(0, trkSpec.MidiChannel), FNoteRangeLow, FNoteRangeHigh,
        Cardinal(FDoc.SongSpec.GenerationSeed) + Cardinal(i) + 1));
  finally
    pr.Free;
  end;

  FDoc.Touch;
  FAfterMidi.Free;
  FAfterMidi := FDoc.Midi.Clone;
  Result := True;
end;

procedure TGenerateVocalGuideCommand.Undo;
begin
  if FBeforeMidi = nil then Exit;
  FDoc.ReplaceMidi(FBeforeMidi.Clone);
  FDoc.Touch;
end;

function TGenerateVocalGuideCommand.Description: string;
begin
  Result := Format('Generate vocal guide for track "%s"', [FVocalTrackId]);
end;

end.
