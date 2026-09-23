unit UDAW.MIDI.Commands;
{$I udaw.inc}

{ Phase 17 - MIDI: undo / redo commands for the project's TMidiProject, built on
  the Phase 5 TDAWCommand / TCommandManager (same pattern as the tracker and
  mixer command sets).

    * fine-grained, addressed by clip index + track index + the note's stable
      Id: add / delete / move / resize / set-velocity.  Move, resize and
      set-velocity are mergeable so a drag collapses to one undo step.
    * structural, captured as a full-project text snapshot before/after and
      restored through the Phase 17 serializer (so note-object references do
      not survive a structural undo - callers work in index / Id space):
      add / remove clip, add / remove track, quantize, humanize, set-tempo. }

interface

uses
  SysUtils, Math,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.MIDI.Types, UDAW.MIDI.Sequence, UDAW.MIDI.PianoRoll,
  UDAW.MIDI.Serialization, UDAW.Timeline.Model;

type
  TMidiCommand = class abstract(TDAWCommand)
  protected
    FDoc: TProjectDocument;
    function MP: TMidiProject;
    function ClipSeq(AClip: Integer): TMidiSequence;
    function Track(AClip, ATrack: Integer): TMidiTrackSeq;
  public
    constructor Create(ADoc: TProjectDocument);
  end;

  { ---- fine grained ---- }

  TAddMidiNoteCommand = class(TMidiCommand)
  private
    FClip, FTrack: Integer;
    FStartTick, FLengthTick: Int64;
    FNote, FVelocity, FChannel: Integer;
    FNewId: Integer;
    FSaved: TMidiNote;
    FHaveSaved: Boolean;
  public
    constructor Create(ADoc: TProjectDocument; AClip, ATrack: Integer;
      AStartTick, ALengthTick: Int64; ANote, AVelocity, AChannel: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;
    property NewNoteId: Integer read FNewId;
  end;

  TDeleteMidiNoteCommand = class(TMidiCommand)
  private
    FClip, FTrack, FId: Integer;
    FSaved: TMidiNote;
    FHad: Boolean;
  public
    constructor Create(ADoc: TProjectDocument; AClip, ATrack, ANoteId: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  TMoveMidiNoteCommand = class(TMidiCommand)
  private
    FClip, FTrack, FId: Integer;
    FDeltaTick: Int64;
    FDeltaNote: Integer;
    FOldStart: Int64;
    FOldNote: Integer;
    FApplied: Boolean;
  public
    constructor Create(ADoc: TProjectDocument; AClip, ATrack, ANoteId: Integer;
      ADeltaTick: Int64; ADeltaNote: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TResizeMidiNoteCommand = class(TMidiCommand)
  private
    FClip, FTrack, FId: Integer;
    FDeltaLen: Int64;
    FFromStart: Boolean;
    FOldStart, FOldLen: Int64;
  public
    constructor Create(ADoc: TProjectDocument; AClip, ATrack, ANoteId: Integer;
      ADeltaLenTick: Int64; AFromStart: Boolean);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TSetMidiVelocityCommand = class(TMidiCommand)
  private
    FClip, FTrack, FId, FNewVel, FOldVel: Integer;
  public
    constructor Create(ADoc: TProjectDocument; AClip, ATrack, ANoteId, ANewVelocity: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  { ---- structural (text snapshot) ---- }

  TMidiStructuralCommand = class abstract(TMidiCommand)
  private
    FBefore, FAfter: string;
    FDesc: string;
  protected
    function Mutate: Boolean; virtual; abstract;
    procedure Restore(const ASnapshot: string);
  public
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;
  end;

  TAddMidiClipCommand = class(TMidiStructuralCommand)
  private
    FName: string;
    FPPQ: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; const AName: string; APPQ: Integer);
  end;

  TRemoveMidiClipCommand = class(TMidiStructuralCommand)
  private
    FClip: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AClip: Integer);
  end;

  TAddMidiTrackCommand = class(TMidiStructuralCommand)
  private
    FClip: Integer;
    FName: string;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AClip: Integer; const AName: string);
  end;

  TRemoveMidiTrackCommand = class(TMidiStructuralCommand)
  private
    FClip, FTrack: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AClip, ATrack: Integer);
  end;

  TQuantizeMidiCommand = class(TMidiStructuralCommand)
  private
    FClip, FTrack: Integer;
    FGridTicks: Int64;
    FStrength, FSwing: Double;
    FAlsoLength, FSelectedOnly: Boolean;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AClip, ATrack: Integer;
      AGridTicks: Int64; AStrength, ASwing: Double; AAlsoLength, ASelectedOnly: Boolean);
  end;

  THumanizeMidiCommand = class(TMidiStructuralCommand)
  private
    FClip, FTrack: Integer;
    FTimingTicks: Int64;
    FVelAmount: Integer;
    FSeed: Cardinal;
    FSelectedOnly: Boolean;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AClip, ATrack: Integer;
      ATimingTicks: Int64; AVelAmount: Integer; ASeed: Cardinal; ASelectedOnly: Boolean);
  end;

  TSetMidiTempoCommand = class(TMidiStructuralCommand)
  private
    FClip: Integer;
    FTick: Int64;
    FBPM: Double;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AClip: Integer; ATick: Int64; ABPM: Double);
  end;

  { ---- Phase 38: commit a live MIDI capture to the Timeline ---- }

  { Mirrors UDAW.Recording.Commands.TCommitTakeCommand's shape for a captured
    MIDI performance: registers ASeq as a stable-id clip in the project's
    TMidiProject (adopting it) and drops one non-destructive TTimelineClip
    referencing it (see UDAW.Timeline.Model's negative-SourceId MIDI-clip
    convention) onto the target track, creating a tkMidi track first when
    ATrackId = 0.

    Undo removes only the TIMELINE clip (and the track, if this command
    created it) - the MIDI-project clip itself is left in place, exactly the
    way TCommitTakeCommand leaves its TMediaSource registrations: harmless,
    and Redo re-attaches the same still-existing MIDI clip instead of losing
    the captured performance if the user edits something else in between. }
  TCommitMidiTakeCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FTrackId: Integer;              // 0 => create a new tkMidi track
    FTrackName: string;
    FSeq: TMidiSequence;            // owned here only until adopted by FDoc.Midi
    FClipName: string;
    FTimelineStartSeconds: Double;
    FLengthSeconds: Double;         // <= 0 => use the captured sequence's own duration
    FCreatedTrackId: Integer;
    FMidiClipId: Integer;           // stable id in FDoc.Midi once added
    FTimelineClipId: Integer;
    FExecuted: Boolean;
    function ResolveTrackId: Integer;
  public
    { ASeq is adopted (freed by this command if Execute never succeeds, owned
      by FDoc.Midi from the moment it does). }
    constructor Create(ADoc: TProjectDocument; ATrackId: Integer; ASeq: TMidiSequence;
      const AClipName: string; ATimelineStartSeconds: Double;
      const ATrackName: string = ''; ALengthSeconds: Double = 0);
    destructor Destroy; override;
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;

    property CreatedTrackId: Integer read FCreatedTrackId;
    property MidiClipId: Integer read FMidiClipId;
    property TimelineClipId: Integer read FTimelineClipId;
  end;

implementation

const
  CMD_SUBSYS = 'MIDI.Commands';

function AllIds(ATrk: TMidiTrackSeq; ASelectedOnly: Boolean): TArray<Integer>;
var
  i, n: Integer;
begin
  SetLength(Result, ATrk.NoteCount);
  n := 0;
  for i := 0 to ATrk.NoteCount - 1 do
    if (not ASelectedOnly) or ATrk.Notes[i].Selected then
    begin
      Result[n] := ATrk.Notes[i].Id;
      Inc(n);
    end;
  SetLength(Result, n);
end;

{ ============================ TMidiCommand ====================== }

constructor TMidiCommand.Create(ADoc: TProjectDocument);
begin
  inherited Create;
  if ADoc = nil then
    RaiseUDAW(errInvalidArgument, CMD_SUBSYS, 'MIDI command needs a project document');
  FDoc := ADoc;
end;

function TMidiCommand.MP: TMidiProject;
begin
  Result := FDoc.Midi;
end;

function TMidiCommand.ClipSeq(AClip: Integer): TMidiSequence;
begin
  Result := MP.Clip(AClip);
  if Result = nil then
    RaiseUDAWFmt(errInvalidArgument, CMD_SUBSYS, 'MIDI: no clip %d', [AClip]);
end;

function TMidiCommand.Track(AClip, ATrack: Integer): TMidiTrackSeq;
begin
  Result := ClipSeq(AClip).GetTrack(ATrack);
  if Result = nil then
    RaiseUDAWFmt(errInvalidArgument, CMD_SUBSYS, 'MIDI: no track %d in clip %d', [ATrack, AClip]);
end;

{ ============================ add note ========================= }

constructor TAddMidiNoteCommand.Create(ADoc: TProjectDocument; AClip, ATrack: Integer;
  AStartTick, ALengthTick: Int64; ANote, AVelocity, AChannel: Integer);
begin
  inherited Create(ADoc);
  FClip := AClip; FTrack := ATrack;
  FStartTick := AStartTick; FLengthTick := ALengthTick;
  FNote := ANote; FVelocity := AVelocity; FChannel := AChannel;
end;

function TAddMidiNoteCommand.Execute: Boolean;
var
  pr: TPianoRoll;
  t: TMidiTrackSeq;
  idx: Integer;
begin
  pr := TPianoRoll.Create(ClipSeq(FClip), FTrack);
  try
    FNewId := pr.AddNote(FStartTick, FLengthTick, FNote, FVelocity, FChannel);
  finally
    pr.Free;
  end;
  t := Track(FClip, FTrack);
  idx := t.IndexOfNoteId(FNewId);
  if idx >= 0 then
  begin
    FSaved := t.Notes[idx];
    FHaveSaved := True;
  end;
  FDoc.Touch;
  Result := True;
end;

procedure TAddMidiNoteCommand.Undo;
var
  t: TMidiTrackSeq;
  idx: Integer;
begin
  t := Track(FClip, FTrack);
  idx := t.IndexOfNoteId(FNewId);
  if idx >= 0 then t.RemoveNoteAt(idx);
  FDoc.Touch;
end;

function TAddMidiNoteCommand.Redo: Boolean;
var
  t: TMidiTrackSeq;
begin
  if FHaveSaved then
  begin
    t := Track(FClip, FTrack);
    if t.IndexOfNoteId(FNewId) < 0 then
    begin
      t.AddNote(FSaved);        // re-insert with the SAME Id
      t.SortNotes;
    end;
    FDoc.Touch;
    Result := True;
  end
  else
    Result := Execute;
end;

function TAddMidiNoteCommand.Description: string;
begin
  Result := Format('add note %s', [MidiNoteName(FNote)]);
end;

{ ============================ delete note ===================== }

constructor TDeleteMidiNoteCommand.Create(ADoc: TProjectDocument; AClip, ATrack, ANoteId: Integer);
begin
  inherited Create(ADoc);
  FClip := AClip; FTrack := ATrack; FId := ANoteId;
end;

function TDeleteMidiNoteCommand.Execute: Boolean;
var
  t: TMidiTrackSeq;
  idx: Integer;
begin
  t := Track(FClip, FTrack);
  idx := t.IndexOfNoteId(FId);
  FHad := idx >= 0;
  if FHad then
  begin
    FSaved := t.Notes[idx];
    t.RemoveNoteAt(idx);
    FDoc.Touch;
  end;
  Result := FHad;
end;

procedure TDeleteMidiNoteCommand.Undo;
var
  t: TMidiTrackSeq;
begin
  if not FHad then Exit;
  t := Track(FClip, FTrack);
  t.AddNote(FSaved);         // keeps the original Id
  t.SortNotes;
  FDoc.Touch;
end;

function TDeleteMidiNoteCommand.Description: string;
begin
  Result := 'delete note';
end;

{ ============================ move note ====================== }

constructor TMoveMidiNoteCommand.Create(ADoc: TProjectDocument; AClip, ATrack, ANoteId: Integer;
  ADeltaTick: Int64; ADeltaNote: Integer);
begin
  inherited Create(ADoc);
  FClip := AClip; FTrack := ATrack; FId := ANoteId;
  FDeltaTick := ADeltaTick; FDeltaNote := ADeltaNote;
end;

function TMoveMidiNoteCommand.Execute: Boolean;
var
  t: TMidiTrackSeq;
  idx: Integer;
  n: TMidiNote;
begin
  t := Track(FClip, FTrack);
  idx := t.IndexOfNoteId(FId);
  Result := idx >= 0;
  if not Result then Exit;
  n := t.Notes[idx];
  FOldStart := n.StartTick;
  FOldNote := n.Note;
  n.StartTick := Max(Int64(0), n.StartTick + FDeltaTick);
  n.Note := n.Note + FDeltaNote;
  if n.Note < 0 then n.Note := 0 else if n.Note > 127 then n.Note := 127;
  t.UpdateNote(idx, n);
  t.SortNotes;
  FApplied := True;
  FDoc.Touch;
end;

procedure TMoveMidiNoteCommand.Undo;
var
  t: TMidiTrackSeq;
  idx: Integer;
  n: TMidiNote;
begin
  if not FApplied then Exit;
  t := Track(FClip, FTrack);
  idx := t.IndexOfNoteId(FId);
  if idx < 0 then Exit;
  n := t.Notes[idx];
  n.StartTick := FOldStart;
  n.Note := FOldNote;
  t.UpdateNote(idx, n);
  t.SortNotes;
  FDoc.Touch;
end;

function TMoveMidiNoteCommand.Description: string;
begin
  Result := 'move note';
end;

function TMoveMidiNoteCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  o: TMoveMidiNoteCommand;
  t: TMidiTrackSeq;
  idx: Integer;
  n: TMidiNote;
begin
  Result := False;
  if not (ANext is TMoveMidiNoteCommand) then Exit;
  o := TMoveMidiNoteCommand(ANext);
  if (o.FClip <> FClip) or (o.FTrack <> FTrack) or (o.FId <> FId) then Exit;

  { TCommandManager.Perform frees an absorbed command WITHOUT calling its
    Execute (the merged command is expected to represent the whole effect
    on its own) - so the incoming delta has to be applied here, not just
    folded into FDeltaTick/FDeltaNote for later. Mirrors
    TMoveTimelineClipCommand.AbsorbNext, which calls Timeline.MoveClip
    itself for the same reason. }
  t := Track(FClip, FTrack);
  idx := t.IndexOfNoteId(FId);
  if idx < 0 then Exit;
  n := t.Notes[idx];
  n.StartTick := Max(Int64(0), n.StartTick + o.FDeltaTick);
  n.Note := n.Note + o.FDeltaNote;
  if n.Note < 0 then n.Note := 0 else if n.Note > 127 then n.Note := 127;
  t.UpdateNote(idx, n);
  t.SortNotes;
  FDoc.Touch;

  FDeltaTick := FDeltaTick + o.FDeltaTick;
  FDeltaNote := FDeltaNote + o.FDeltaNote;
  Result := True;
end;

{ ============================ resize note ==================== }

constructor TResizeMidiNoteCommand.Create(ADoc: TProjectDocument; AClip, ATrack, ANoteId: Integer;
  ADeltaLenTick: Int64; AFromStart: Boolean);
begin
  inherited Create(ADoc);
  FClip := AClip; FTrack := ATrack; FId := ANoteId;
  FDeltaLen := ADeltaLenTick; FFromStart := AFromStart;
end;

function TResizeMidiNoteCommand.Execute: Boolean;
var
  pr: TPianoRoll;
  t: TMidiTrackSeq;
  idx: Integer;
begin
  t := Track(FClip, FTrack);
  idx := t.IndexOfNoteId(FId);
  Result := idx >= 0;
  if not Result then Exit;
  FOldStart := t.Notes[idx].StartTick;
  FOldLen := t.Notes[idx].LengthTick;
  pr := TPianoRoll.Create(ClipSeq(FClip), FTrack);
  try
    pr.ResizeNote(FId, FDeltaLen, FFromStart);
  finally
    pr.Free;
  end;
  FDoc.Touch;
end;

procedure TResizeMidiNoteCommand.Undo;
var
  t: TMidiTrackSeq;
  idx: Integer;
  n: TMidiNote;
begin
  t := Track(FClip, FTrack);
  idx := t.IndexOfNoteId(FId);
  if idx < 0 then Exit;
  n := t.Notes[idx];
  n.StartTick := FOldStart;
  n.LengthTick := FOldLen;
  t.UpdateNote(idx, n);
  t.SortNotes;
  FDoc.Touch;
end;

function TResizeMidiNoteCommand.Description: string;
begin
  Result := 'resize note';
end;

function TResizeMidiNoteCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  o: TResizeMidiNoteCommand;
  pr: TPianoRoll;
begin
  Result := False;
  if not (ANext is TResizeMidiNoteCommand) then Exit;
  o := TResizeMidiNoteCommand(ANext);
  if (o.FClip <> FClip) or (o.FTrack <> FTrack) or (o.FId <> FId) or
     (o.FFromStart <> FFromStart) then Exit;

  { see TMoveMidiNoteCommand.AbsorbNext: the absorbed command's Execute
    never runs, so its incremental resize has to be applied here. }
  pr := TPianoRoll.Create(ClipSeq(FClip), FTrack);
  try
    pr.ResizeNote(FId, o.FDeltaLen, FFromStart);
  finally
    pr.Free;
  end;
  FDoc.Touch;

  FDeltaLen := FDeltaLen + o.FDeltaLen;
  Result := True;
end;

{ ============================ set velocity ================== }

constructor TSetMidiVelocityCommand.Create(ADoc: TProjectDocument; AClip, ATrack, ANoteId,
  ANewVelocity: Integer);
begin
  inherited Create(ADoc);
  FClip := AClip; FTrack := ATrack; FId := ANoteId; FNewVel := ANewVelocity;
end;

function TSetMidiVelocityCommand.Execute: Boolean;
var
  t: TMidiTrackSeq;
  idx: Integer;
  n: TMidiNote;
begin
  t := Track(FClip, FTrack);
  idx := t.IndexOfNoteId(FId);
  Result := idx >= 0;
  if not Result then Exit;
  n := t.Notes[idx];
  FOldVel := n.Velocity;
  n.Velocity := Max(1, Min(127, FNewVel));
  t.UpdateNote(idx, n);
  FDoc.Touch;
end;

procedure TSetMidiVelocityCommand.Undo;
var
  t: TMidiTrackSeq;
  idx: Integer;
  n: TMidiNote;
begin
  t := Track(FClip, FTrack);
  idx := t.IndexOfNoteId(FId);
  if idx < 0 then Exit;
  n := t.Notes[idx];
  n.Velocity := FOldVel;
  t.UpdateNote(idx, n);
  FDoc.Touch;
end;

function TSetMidiVelocityCommand.Description: string;
begin
  Result := Format('set velocity %d', [FNewVel]);
end;

function TSetMidiVelocityCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  o: TSetMidiVelocityCommand;
  t: TMidiTrackSeq;
  idx: Integer;
  n: TMidiNote;
begin
  Result := False;
  if not (ANext is TSetMidiVelocityCommand) then Exit;
  o := TSetMidiVelocityCommand(ANext);
  if (o.FClip <> FClip) or (o.FTrack <> FTrack) or (o.FId <> FId) then Exit;

  { see TMoveMidiNoteCommand.AbsorbNext: the absorbed command's Execute
    never runs, so its new velocity has to be applied here. }
  t := Track(FClip, FTrack);
  idx := t.IndexOfNoteId(FId);
  if idx < 0 then Exit;
  n := t.Notes[idx];
  n.Velocity := Max(1, Min(127, o.FNewVel));
  t.UpdateNote(idx, n);
  FDoc.Touch;

  FNewVel := o.FNewVel;
  Result := True;
end;

{ ============================ structural base ============== }

function TMidiStructuralCommand.Description: string;
begin
  Result := FDesc;
end;

procedure TMidiStructuralCommand.Restore(const ASnapshot: string);
begin
  FDoc.ReplaceMidi(MidiProjectFromString(ASnapshot));
  FDoc.Touch;
end;

function TMidiStructuralCommand.Execute: Boolean;
begin
  FBefore := MidiProjectToString(MP);
  Result := Mutate;
  if Result then
  begin
    FAfter := MidiProjectToString(MP);
    FDoc.Touch;
  end
  else
    FBefore := '';
end;

procedure TMidiStructuralCommand.Undo;
begin
  if FBefore <> '' then Restore(FBefore);
end;

function TMidiStructuralCommand.Redo: Boolean;
begin
  if FAfter <> '' then
  begin
    Restore(FAfter);
    Result := True;
  end
  else
    Result := Execute;
end;

{ ---- add clip ---- }

constructor TAddMidiClipCommand.Create(ADoc: TProjectDocument; const AName: string; APPQ: Integer);
begin
  inherited Create(ADoc);
  FName := AName;
  FPPQ := APPQ;
  FDesc := 'add MIDI clip';
end;

function TAddMidiClipCommand.Mutate: Boolean;
begin
  MP.NewClip(FName, FPPQ);
  Result := True;
end;

{ ---- remove clip ---- }

constructor TRemoveMidiClipCommand.Create(ADoc: TProjectDocument; AClip: Integer);
begin
  inherited Create(ADoc);
  FClip := AClip;
  FDesc := 'remove MIDI clip';
end;

function TRemoveMidiClipCommand.Mutate: Boolean;
begin
  Result := (FClip >= 0) and (FClip < MP.ClipCount);
  if Result then MP.RemoveClip(FClip);
end;

{ ---- add track ---- }

constructor TAddMidiTrackCommand.Create(ADoc: TProjectDocument; AClip: Integer; const AName: string);
begin
  inherited Create(ADoc);
  FClip := AClip; FName := AName;
  FDesc := 'add MIDI track';
end;

function TAddMidiTrackCommand.Mutate: Boolean;
begin
  Result := ClipSeq(FClip) <> nil;
  if Result then ClipSeq(FClip).AddTrack(FName);
end;

{ ---- remove track ---- }

constructor TRemoveMidiTrackCommand.Create(ADoc: TProjectDocument; AClip, ATrack: Integer);
begin
  inherited Create(ADoc);
  FClip := AClip; FTrack := ATrack;
  FDesc := 'remove MIDI track';
end;

function TRemoveMidiTrackCommand.Mutate: Boolean;
var
  s: TMidiSequence;
begin
  s := ClipSeq(FClip);
  Result := (s <> nil) and (FTrack >= 0) and (FTrack < s.TrackCount);
  if Result then s.RemoveTrack(FTrack);
end;

{ ---- quantize ---- }

constructor TQuantizeMidiCommand.Create(ADoc: TProjectDocument; AClip, ATrack: Integer;
  AGridTicks: Int64; AStrength, ASwing: Double; AAlsoLength, ASelectedOnly: Boolean);
begin
  inherited Create(ADoc);
  FClip := AClip; FTrack := ATrack;
  FGridTicks := AGridTicks; FStrength := AStrength; FSwing := ASwing;
  FAlsoLength := AAlsoLength; FSelectedOnly := ASelectedOnly;
  FDesc := 'quantize';
end;

function TQuantizeMidiCommand.Mutate: Boolean;
var
  pr: TPianoRoll;
  t: TMidiTrackSeq;
begin
  t := Track(FClip, FTrack);
  pr := TPianoRoll.Create(ClipSeq(FClip), FTrack);
  try
    pr.Quantize(AllIds(t, FSelectedOnly), FGridTicks, FStrength, FSwing, FAlsoLength);
  finally
    pr.Free;
  end;
  Result := True;
end;

{ ---- humanize ---- }

constructor THumanizeMidiCommand.Create(ADoc: TProjectDocument; AClip, ATrack: Integer;
  ATimingTicks: Int64; AVelAmount: Integer; ASeed: Cardinal; ASelectedOnly: Boolean);
begin
  inherited Create(ADoc);
  FClip := AClip; FTrack := ATrack;
  FTimingTicks := ATimingTicks; FVelAmount := AVelAmount; FSeed := ASeed;
  FSelectedOnly := ASelectedOnly;
  FDesc := 'humanize';
end;

function THumanizeMidiCommand.Mutate: Boolean;
var
  pr: TPianoRoll;
  t: TMidiTrackSeq;
begin
  t := Track(FClip, FTrack);
  pr := TPianoRoll.Create(ClipSeq(FClip), FTrack);
  try
    pr.Humanize(AllIds(t, FSelectedOnly), FTimingTicks, FVelAmount, FSeed);
  finally
    pr.Free;
  end;
  Result := True;
end;

{ ---- set tempo ---- }

constructor TSetMidiTempoCommand.Create(ADoc: TProjectDocument; AClip: Integer;
  ATick: Int64; ABPM: Double);
begin
  inherited Create(ADoc);
  FClip := AClip; FTick := ATick; FBPM := ABPM;
  FDesc := 'set tempo';
end;

function TSetMidiTempoCommand.Mutate: Boolean;
begin
  ClipSeq(FClip).SetTempoAt(FTick, FBPM);
  Result := True;
end;

{ ---- commit a live MIDI capture to the Timeline ---- }

constructor TCommitMidiTakeCommand.Create(ADoc: TProjectDocument; ATrackId: Integer;
  ASeq: TMidiSequence; const AClipName: string; ATimelineStartSeconds: Double;
  const ATrackName: string; ALengthSeconds: Double);
begin
  inherited Create;
  if ADoc = nil then
    RaiseUDAW(errInvalidArgument, 'MIDI.Cmd', 'nil document');
  FDoc := ADoc;
  FTrackId := ATrackId;
  FTrackName := ATrackName;
  FSeq := ASeq;
  FClipName := AClipName;
  FTimelineStartSeconds := Max(0.0, ATimelineStartSeconds);
  FLengthSeconds := ALengthSeconds;
  FCreatedTrackId := 0;
  FMidiClipId := 0;
  FTimelineClipId := 0;
end;

destructor TCommitMidiTakeCommand.Destroy;
begin
  FSeq.Free;   // still owned only if Execute never adopted it (or never ran)
  inherited Destroy;
end;

function TCommitMidiTakeCommand.ResolveTrackId: Integer;
var
  trk: TTimelineTrack;
  nm: string;
begin
  if FTrackId <> 0 then
  begin
    if FDoc.Timeline.TrackById(FTrackId) = nil then
      RaiseUDAWFmt(errInvalidArgument, 'MIDI.Cmd', 'no track with id %d', [FTrackId]);
    Exit(FTrackId);
  end;
  if FCreatedTrackId <> 0 then
  begin
    { redo path - recreate the same track with the same id }
    trk := FDoc.Timeline.AddTrackWithId(FCreatedTrackId, tkMidi, FTrackName);
    Exit(trk.Id);
  end;
  if Trim(FTrackName) <> '' then nm := FTrackName
  else nm := Format('MIDI %d', [FDoc.Timeline.TrackCount + 1]);
  trk := FDoc.Timeline.AddTrack(tkMidi, nm);
  FCreatedTrackId := trk.Id;
  FTrackName := nm;
  Result := trk.Id;
end;

function TCommitMidiTakeCommand.Execute: Boolean;
var
  trackId: Integer;
  length_: Double;
  seq: TMidiSequence;
  clip: TTimelineClip;
begin
  if not FExecuted then
  begin
    if FSeq = nil then Exit(False);
    FMidiClipId := FDoc.Midi.AddClipStable(FClipName, FSeq);
    FSeq := nil;   // ownership transferred to FDoc.Midi
  end;

  seq := FDoc.Midi.ClipById(FMidiClipId);
  if seq = nil then Exit(False);   // the MIDI clip was deleted out from under us - nothing to place

  length_ := FLengthSeconds;
  if length_ <= 0 then length_ := seq.DurationSeconds;
  if length_ <= 0 then length_ := 1.0;

  trackId := ResolveTrackId;
  if FExecuted and (FTimelineClipId > 0) then
    clip := FDoc.Timeline.AddClipWithId(FTimelineClipId, trackId, EncodeMidiSourceId(FMidiClipId),
      FClipName, FTimelineStartSeconds, 0, length_)
  else
    clip := FDoc.Timeline.AddClip(trackId, EncodeMidiSourceId(FMidiClipId),
      FClipName, FTimelineStartSeconds, 0, length_);
  FTimelineClipId := clip.Id;
  FExecuted := True;
  FDoc.Touch;
  Result := True;
end;

procedure TCommitMidiTakeCommand.Undo;
begin
  if (FTimelineClipId > 0) and (FDoc.Timeline.ClipById(FTimelineClipId) <> nil) then
    FDoc.Timeline.RemoveClip(FTimelineClipId);
  if (FCreatedTrackId <> 0) and (FDoc.Timeline.TrackById(FCreatedTrackId) <> nil) then
    FDoc.Timeline.RemoveTrack(FCreatedTrackId);
  FDoc.Touch;
end;

function TCommitMidiTakeCommand.Redo: Boolean;
begin
  Result := Execute;
end;

function TCommitMidiTakeCommand.Description: string;
begin
  Result := Format('Commit recorded MIDI "%s" to timeline', [FClipName]);
end;

end.
