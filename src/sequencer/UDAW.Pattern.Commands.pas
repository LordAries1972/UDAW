unit UDAW.Pattern.Commands;
{$I udaw.inc}

{ Undo / redo for the project's pattern library (UDAW.Pattern.Model), and the link
  between a pattern and the Timeline.

  A pattern is placed on the Timeline as a MIDI clip rendered from it (channel-10
  notes, which the drum machine plays). The pattern keeps that clip's id, so
  PatternsSyncMidi re-renders it - and resizes every untouched instance on the
  Timeline - whenever the pattern changes.

    * TPatternEditCommand   any edit of the library, as a before / after snapshot
    * TPlacePatternCommand  puts a pattern on the Timeline at a position }

interface

uses
  SysUtils, Math,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Timeline.Model, UDAW.MIDI.Types, UDAW.MIDI.Sequence, UDAW.MIDI.Serialization,
  UDAW.Pattern.Model;

type
  TPatternEditProc = reference to procedure(ALib: TPatternLibrary);

  TPatternEditCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FDesc: string;
    FEdit: TPatternEditProc;
    FBefore, FAfter: string;
    FRan: Boolean;
    FApplied: Boolean;           // the edit was made live (a mouse drag); Execute only records it
    procedure Restore(const ASnapshot: string; const AFrom: string);
  public
    { AEdit runs once, on Execute, against the document's library }
    constructor Create(ADoc: TProjectDocument; const ADescription: string; const AEdit: TPatternEditProc);
    { the library was already edited in place (a drag); ABefore is its text from before the
      edit. Execute then just records it as one undo step. }
    constructor CreateApplied(ADoc: TProjectDocument; const ADescription, ABefore: string);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;
    { a quick run of the same kind of edit (a wheel turned over a step) is one undo step }
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TPlacePatternCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FPatternId: Integer;
    FTrackId: Integer;              // 0 => create a new tkMidi track
    FStartSeconds: Double;
    FCreatedTrackId: Integer;
    FMidiClipId: Integer;
    FTimelineClipId: Integer;
    FPatternName: string;
    FExecuted: Boolean;
    function ResolveTrackId: Integer;
  public
    constructor Create(ADoc: TProjectDocument; APatternId, ATrackId: Integer; AStartSeconds: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;
    property TimelineClipId: Integer read FTimelineClipId;
  end;

{ re-renders every pattern that is on the Timeline into its MIDI clip and resizes the
  untouched instances; ABefore (the library before an edit) supplies the old lengths }
procedure PatternsSyncMidi(ADoc: TProjectDocument; ABefore: TPatternLibrary = nil);

implementation

const
  PATTERN_PPQ = 480;
  CMD_SUBSYS = 'Pattern.Cmd';

procedure PatternsSyncMidi(ADoc: TProjectDocument; ABefore: TPatternLibrary);
var
  i, ti, ci: Integer;
  p, old: TPattern;
  trk: TTimelineTrack;
  clip: TTimelineClip;
  oldLen, newLen: Double;
begin
  for i := 0 to ADoc.Patterns.Count - 1 do
  begin
    p := ADoc.Patterns[i];
    if p.MidiClipId = 0 then Continue;
    if ADoc.Midi.ClipById(p.MidiClipId) = nil then
    begin
      p.MidiClipId := 0;          // the MIDI clip was deleted: nothing to keep in step
      Continue;
    end;
    ADoc.Midi.ReplaceClipById(p.MidiClipId, p.ToMidi(PATTERN_PPQ, ADoc.TempoBPM));
    newLen := p.DurationSeconds(ADoc.TempoBPM);
    oldLen := newLen;
    if ABefore <> nil then
    begin
      old := ABefore.ById(p.Id);
      if old <> nil then oldLen := old.DurationSeconds(ADoc.TempoBPM);
    end;
    if Abs(oldLen - newLen) < 0.0005 then Continue;
    { an instance still at the pattern's old length follows the new one }
    for ti := 0 to ADoc.Timeline.TrackCount - 1 do
    begin
      trk := ADoc.Timeline.GetTrack(ti);
      for ci := 0 to trk.ClipCount - 1 do
      begin
        clip := trk.GetClip(ci);
        if clip.IsMidiClip and (clip.MidiClipId = p.MidiClipId) and
           (Abs(clip.LengthSeconds - oldLen) < 0.001) then
          clip.LengthSeconds := newLen;
      end;
    end;
  end;
  ADoc.Touch;
end;

{ ============================ TPatternEditCommand =============== }

constructor TPatternEditCommand.Create(ADoc: TProjectDocument; const ADescription: string;
  const AEdit: TPatternEditProc);
begin
  inherited Create;
  if ADoc = nil then RaiseUDAW(errInvalidArgument, CMD_SUBSYS, 'nil document');
  FDoc := ADoc;
  FDesc := ADescription;
  FEdit := AEdit;
end;

constructor TPatternEditCommand.CreateApplied(ADoc: TProjectDocument; const ADescription, ABefore: string);
begin
  inherited Create;
  if ADoc = nil then RaiseUDAW(errInvalidArgument, CMD_SUBSYS, 'nil document');
  FDoc := ADoc;
  FDesc := ADescription;
  FApplied := True;
  FBefore := ABefore;
end;

function TPatternEditCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  n: TPatternEditCommand;
  before: TPatternLibrary;
begin
  Result := False;
  if not FRan or not (ANext is TPatternEditCommand) then Exit;
  n := TPatternEditCommand(ANext);
  if n.FApplied or (n.FDoc <> FDoc) or (n.FDesc <> FDesc) or not Assigned(n.FEdit) or
     (MsSinceStamp > COMMAND_MERGE_WINDOW_MS) then Exit;
  before := PatternLibraryFromString(FAfter);
  try
    n.FEdit(FDoc.Patterns);
    FAfter := PatternLibraryToString(FDoc.Patterns);
    PatternsSyncMidi(FDoc, before);
  finally
    before.Free;
  end;
  Restamp;
  Result := True;
end;

procedure TPatternEditCommand.Restore(const ASnapshot: string; const AFrom: string);
var
  prev: TPatternLibrary;
begin
  { the library being left supplies the lengths the instances are measured against }
  prev := PatternLibraryFromString(AFrom);
  try
    FDoc.ReplacePatterns(PatternLibraryFromString(ASnapshot));
    PatternsSyncMidi(FDoc, prev);
  finally
    prev.Free;
  end;
end;

function TPatternEditCommand.Execute: Boolean;
var
  before: TPatternLibrary;
begin
  if FRan then
  begin
    Restore(FAfter, FBefore);
    Exit(True);
  end;
  if not FApplied then FBefore := PatternLibraryToString(FDoc.Patterns);
  before := PatternLibraryFromString(FBefore);
  try
    if Assigned(FEdit) then FEdit(FDoc.Patterns);
    FAfter := PatternLibraryToString(FDoc.Patterns);
    FEdit := nil;
    if FAfter = FBefore then Exit(False);   // nothing changed
    FRan := True;
    PatternsSyncMidi(FDoc, before);
  finally
    before.Free;
  end;
  Result := True;
end;

procedure TPatternEditCommand.Undo;
begin
  Restore(FBefore, FAfter);
end;

function TPatternEditCommand.Redo: Boolean;
begin
  Restore(FAfter, FBefore);
  Result := True;
end;

function TPatternEditCommand.Description: string;
begin
  Result := FDesc;
end;

{ ============================ TPlacePatternCommand ============== }

constructor TPlacePatternCommand.Create(ADoc: TProjectDocument; APatternId, ATrackId: Integer;
  AStartSeconds: Double);
begin
  inherited Create;
  if ADoc = nil then RaiseUDAW(errInvalidArgument, CMD_SUBSYS, 'nil document');
  FDoc := ADoc;
  FPatternId := APatternId;
  FTrackId := ATrackId;
  FStartSeconds := Max(0, AStartSeconds);
end;

function TPlacePatternCommand.ResolveTrackId: Integer;
var
  trk: TTimelineTrack;
  nm: string;
begin
  if FTrackId <> 0 then
  begin
    if FDoc.Timeline.TrackById(FTrackId) = nil then
      RaiseUDAWFmt(errInvalidArgument, CMD_SUBSYS, 'no track with id %d', [FTrackId]);
    Exit(FTrackId);
  end;
  if FCreatedTrackId <> 0 then
  begin
    trk := FDoc.Timeline.AddTrackWithId(FCreatedTrackId, tkMidi, 'Patterns');
    Exit(trk.Id);
  end;
  nm := Format('Patterns %d', [FDoc.Timeline.TrackCount + 1]);
  trk := FDoc.Timeline.AddTrack(tkMidi, nm);
  FCreatedTrackId := trk.Id;
  Result := trk.Id;
end;

function TPlacePatternCommand.Execute: Boolean;
var
  p: TPattern;
  trackId: Integer;
  len: Double;
  clip: TTimelineClip;
begin
  p := FDoc.Patterns.ById(FPatternId);
  if p = nil then Exit(False);
  if p.TotalHits = 0 then Exit(False);      // an empty pattern would place a silent clip
  FPatternName := p.Name;
  if (p.MidiClipId = 0) or (FDoc.Midi.ClipById(p.MidiClipId) = nil) then
  begin
    if (FMidiClipId <> 0) and (FDoc.Midi.ClipById(FMidiClipId) <> nil) then
      p.MidiClipId := FMidiClipId           // redo: the clip made the first time is still there
    else
    begin
      p.MidiClipId := FDoc.Midi.AddClipStable(p.Name, p.ToMidi(PATTERN_PPQ, FDoc.TempoBPM));
    end;
  end;
  FMidiClipId := p.MidiClipId;
  len := p.DurationSeconds(FDoc.TempoBPM);
  trackId := ResolveTrackId;
  if FExecuted and (FTimelineClipId > 0) then
    clip := FDoc.Timeline.AddClipWithId(FTimelineClipId, trackId, EncodeMidiSourceId(FMidiClipId),
      p.Name, FStartSeconds, 0, len)
  else
    clip := FDoc.Timeline.AddClip(trackId, EncodeMidiSourceId(FMidiClipId),
      p.Name, FStartSeconds, 0, len);
  FTimelineClipId := clip.Id;
  FExecuted := True;
  FDoc.Touch;
  Result := True;
end;

procedure TPlacePatternCommand.Undo;
begin
  if (FTimelineClipId > 0) and (FDoc.Timeline.ClipById(FTimelineClipId) <> nil) then
    FDoc.Timeline.RemoveClip(FTimelineClipId);
  if (FCreatedTrackId <> 0) and (FDoc.Timeline.TrackById(FCreatedTrackId) <> nil) then
    FDoc.Timeline.RemoveTrack(FCreatedTrackId);
  { the rendered MIDI clip stays, like a committed MIDI take: redo re-attaches it }
  FDoc.Touch;
end;

function TPlacePatternCommand.Redo: Boolean;
begin
  Result := Execute;
end;

function TPlacePatternCommand.Description: string;
begin
  Result := Format('Place pattern "%s" on the Timeline', [FPatternName]);
end;

end.
