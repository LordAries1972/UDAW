unit UDAW.Timeline.Commands;
{$I udaw.inc}

{ Phase 7 - Timeline: undoable edits (plan section 28 - "All editing should be
  NON-DESTRUCTIVE by default").

  These are TDAWCommand descendants (the Phase 5 Command Pattern) that operate
  on the TTimeline owned by a TProjectDocument, so timeline edits share the one
  project-wide undo/redo stack with metadata and graph edits. Every command
  marks the document dirty via Doc.Touch.

  Rapid drags (moving a clip, dragging an edge, riding a clip's gain) collapse
  into one undo step through AbsorbNext, exactly like the metadata commands. }

interface

uses
  SysUtils,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Timeline.Model;

type
  { snapshot of a clip's full state, for exact restore on undo }
  TClipState = record
    Id: Integer;
    TrackId: Integer;
    SourceId: Integer;
    Name: string;
    StartSeconds, SourceOffsetSeconds, LengthSeconds, GainDb: Double;
    FadeInSeconds, FadeOutSeconds: Double;
    FadeInShape, FadeOutShape: TFadeShape;
    Reversed, Muted, Locked, Loop: Boolean;
    Color: Integer;
  end;

  TAddTimelineTrackCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FKind: TTrackKind;
    FName: string;
    FCreatedId: Integer;
  public
    constructor Create(ADoc: TProjectDocument; AKind: TTrackKind; const AName: string);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;
    property CreatedId: Integer read FCreatedId;
  end;

  TRemoveTimelineTrackCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FTrackId, FIndex: Integer;
    FKind: TTrackKind;
    FName: string;
    FColor, FHeight: Integer;
    FMuted, FSoloed, FArmed: Boolean;
    FGainDb, FPan: Double;
    FClips: TArray<TClipState>;
  public
    constructor Create(ADoc: TProjectDocument; ATrackId: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { Swaps a track's position in the timeline's track list ("Move Track Up" /
    "Move Track Down" in the timeline context menu). }
  TMoveTimelineTrackCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FTrackId: Integer;
    FOldIndex, FNewIndex: Integer;
  public
    constructor Create(ADoc: TProjectDocument; ATrackId, ANewIndex: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { Renames a track ("Rename Track..." in the timeline Edit menu / context
    menu). Mirrors TMoveTimelineTrackCommand's shape. }
  TRenameTimelineTrackCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FTrackId: Integer;
    FOldName, FNewName: string;
  public
    constructor Create(ADoc: TProjectDocument; ATrackId: Integer; const ANewName: string);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { Timeline-tab master playback volume (independent of the Mixer's master
    strip - see UDAW.Timeline.Playback's header comment). Mergeable so riding
    the slider during playback collapses into one undo step. }
  TSetTimelineMasterVolumeCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FOld, FNew: Double;
  public
    constructor Create(ADoc: TProjectDocument; ANewVolumeDb: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TAddTimelineClipCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FTrackId, FSourceId: Integer;
    FName: string;
    FStart, FOffset, FLength: Double;
    FCreatedId: Integer;
  public
    constructor Create(ADoc: TProjectDocument; ATrackId, ASourceId: Integer;
      const AName: string; AStart, AOffset, ALength: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;
    property CreatedId: Integer read FCreatedId;
  end;

  TRemoveTimelineClipCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FClipId: Integer;
    FState: TClipState;
  public
    constructor Create(ADoc: TProjectDocument; AClipId: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  TMoveTimelineClipCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FClipId: Integer;
    FOldStart, FNewStart: Double;
    FOldTrackId, FNewTrackId: Integer;
  public
    { ANewTrackId = 0 keeps the clip on its current track. }
    constructor Create(ADoc: TProjectDocument; AClipId: Integer;
      ANewStart: Double; ANewTrackId: Integer = 0);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TTrimTimelineClipCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FClipId: Integer;
    FEdge: TClipEdge;
    FNewSeconds: Double;
    FBefore: TClipState;
    FHaveBefore: Boolean;
  public
    constructor Create(ADoc: TProjectDocument; AClipId: Integer; AEdge: TClipEdge;
      ANewSeconds: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TSplitTimelineClipCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FClipId: Integer;
    FAtSeconds: Double;
    FRightId: Integer;
    FLeftBefore: TClipState;
  public
    constructor Create(ADoc: TProjectDocument; AClipId: Integer; AAtSeconds: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;
    property RightClipId: Integer read FRightId;
  end;

  TSetTimelineClipGainCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FClipId: Integer;
    FOldGain, FNewGain: Double;
    FHaveOld: Boolean;
  public
    constructor Create(ADoc: TProjectDocument; AClipId: Integer; ANewGainDb: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  { Rewrites which source (and offset into it) a clip plays from - used by
    an offline effect render (UDAW.UI.MainForm's TlApplyEffectToRange): the
    effect is rendered to a brand new WAV file/TMediaSource and this command
    is what actually points the clip at it, so the render is undoable like
    any other timeline edit. }
  TSetTimelineClipSourceCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FClipId: Integer;
    FOldSourceId, FNewSourceId: Integer;
    FOldOffset, FNewOffset: Double;
    FHaveOld: Boolean;
    { effect labels (regions, name/offset/length/colour, track title) are added
      by the caller right after Perform, so they are snapshotted here and put
      back on Undo - otherwise an undone effect stays in the collection list }
    FOldRegions, FRedoRegions: TArray<TClipEffectRegion>;
    FOldEffName, FRedoEffName, FOldTitle, FRedoTitle: string;
    FOldEffOff, FOldEffLen, FRedoEffOff, FRedoEffLen: Double;
    FOldColor, FRedoColor: Integer;
    FHaveRedo: Boolean;
    FOldHasOrig, FRedoHasOrig: Boolean;
    FOldOrigSrc, FRedoOrigSrc: Integer;
    FOldOrigDelta, FRedoOrigDelta: Double;
  public
    constructor Create(ADoc: TProjectDocument; AClipId, ANewSourceId: Integer;
      ANewOffsetSeconds: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { Toggles a clip's Reversed flag ("Reverse Selection" in the Timeline Edit
    menu). }
  { Sets TTimelineClip.SourceBPM (0 = off) so playback/export conform the clip
    to the project tempo. }
  TSetTimelineClipSourceBpmCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FClipId: Integer;
    FOldBpm, FNewBpm, FOldLen: Double;
    FHaveOld: Boolean;
  public
    constructor Create(ADoc: TProjectDocument; AClipId: Integer; ANewBpm: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  TSetTimelineClipReversedCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FClipId: Integer;
    FOldReversed, FNewReversed: Boolean;
    FHaveOld: Boolean;
  public
    constructor Create(ADoc: TProjectDocument; AClipId: Integer; ANewReversed: Boolean);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { Drags one fade handle (the diamond at the top of a clip's fade-in/out
    triangle in the Timeline tab). AEdge=ceStart drags the fade-in length,
    AEdge=ceEnd drags the fade-out length; both are clamped to the clip's
    length by TTimeline.SetClipFades. Mergeable like TTrimTimelineClipCommand
    so a single drag gesture collapses into one undo step. }
  TSetTimelineClipFadeCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FClipId: Integer;
    FEdge: TClipEdge;
    FNewSeconds: Double;
    FOldFadeIn, FOldFadeOut: Double;
    FHaveOld: Boolean;
    FOldRegions: TArray<TClipEffectRegion>;   // Fade In/Out Range adds a region right after Perform; Undo removes it again
  public
    constructor Create(ADoc: TProjectDocument; AClipId: Integer; AEdge: TClipEdge;
      ANewSeconds: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TAddTimelineMarkerCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FName: string;
    FSeconds: Double;
    FCreatedId: Integer;
  public
    constructor Create(ADoc: TProjectDocument; const AName: string; ASeconds: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;
    property CreatedId: Integer read FCreatedId;
  end;

implementation

uses
  DateUtils, Math;

const
  MERGE_MS = 800;

{ ---- clip state capture / restore ---- }

function CaptureClip(ATimeline: TTimeline; AClipId: Integer): TClipState;
var
  trk: TTimelineTrack;
  c: TTimelineClip;
begin
  c := ATimeline.ClipById(AClipId, trk);
  if c = nil then
    RaiseUDAWFmt(errInvalidArgument, 'Timeline.Cmd', 'no clip with id %d', [AClipId]);
  Result.Id := c.Id;
  Result.TrackId := trk.Id;
  Result.SourceId := c.SourceId;
  Result.Name := c.Name;
  Result.StartSeconds := c.StartSeconds;
  Result.SourceOffsetSeconds := c.SourceOffsetSeconds;
  Result.LengthSeconds := c.LengthSeconds;
  Result.GainDb := c.GainDb;
  Result.FadeInSeconds := c.FadeInSeconds;
  Result.FadeOutSeconds := c.FadeOutSeconds;
  Result.FadeInShape := c.FadeInShape;
  Result.FadeOutShape := c.FadeOutShape;
  Result.Reversed := c.Reversed;
  Result.Muted := c.Muted;
  Result.Locked := c.Locked;
  Result.Loop := c.Loop;
  Result.Color := c.Color;
end;

procedure ApplyClipState(ATimeline: TTimeline; const AState: TClipState);
var
  trk: TTimelineTrack;
  c: TTimelineClip;
begin
  c := ATimeline.ClipById(AState.Id, trk);
  if c = nil then
  begin
    ATimeline.AddClipWithId(AState.Id, AState.TrackId, AState.SourceId,
      AState.Name, AState.StartSeconds, AState.SourceOffsetSeconds, AState.LengthSeconds);
    c := ATimeline.ClipById(AState.Id, trk);
  end
  else if trk.Id <> AState.TrackId then
  begin
    ATimeline.MoveClip(AState.Id, AState.StartSeconds, AState.TrackId);
    c := ATimeline.ClipById(AState.Id, trk);
  end;
  if c = nil then
    RaiseUDAWFmt(errInvalidState, 'Timeline.Cmd', 'could not restore clip %d', [AState.Id]);
  c.Name := AState.Name;
  c.SourceId := AState.SourceId;
  c.StartSeconds := AState.StartSeconds;
  c.SourceOffsetSeconds := AState.SourceOffsetSeconds;
  c.LengthSeconds := AState.LengthSeconds;
  c.GainDb := AState.GainDb;
  c.FadeInSeconds := AState.FadeInSeconds;
  c.FadeOutSeconds := AState.FadeOutSeconds;
  c.FadeInShape := AState.FadeInShape;
  c.FadeOutShape := AState.FadeOutShape;
  c.Reversed := AState.Reversed;
  c.Muted := AState.Muted;
  c.Locked := AState.Locked;
  c.Loop := AState.Loop;
  c.Color := AState.Color;
  trk.SortClips;
end;

{ ================= TAddTimelineTrackCommand ================= }

constructor TAddTimelineTrackCommand.Create(ADoc: TProjectDocument; AKind: TTrackKind;
  const AName: string);
begin
  inherited Create;
  FDoc := ADoc;
  FKind := AKind;
  FName := AName;
  FCreatedId := -1;
end;

function TAddTimelineTrackCommand.Execute: Boolean;
var
  t: TTimelineTrack;
begin
  t := FDoc.Timeline.AddTrack(FKind, FName);
  FCreatedId := t.Id;
  FDoc.Touch;
  Result := True;
end;

procedure TAddTimelineTrackCommand.Undo;
begin
  FDoc.Timeline.RemoveTrack(FCreatedId);
  FDoc.Touch;
end;

function TAddTimelineTrackCommand.Redo: Boolean;
begin
  FDoc.Timeline.AddTrackWithId(FCreatedId, FKind, FName);
  FDoc.Touch;
  Result := True;
end;

function TAddTimelineTrackCommand.Description: string;
begin
  Result := Format('Add %s track "%s"', [TrackKindDisplay(FKind), FName]);
end;

{ ================= TMoveTimelineTrackCommand ================= }

constructor TMoveTimelineTrackCommand.Create(ADoc: TProjectDocument; ATrackId, ANewIndex: Integer);
begin
  inherited Create;
  FDoc := ADoc;
  FTrackId := ATrackId;
  FNewIndex := ANewIndex;
  FOldIndex := -1;
end;

function TMoveTimelineTrackCommand.Execute: Boolean;
begin
  FOldIndex := FDoc.Timeline.IndexOfTrack(FTrackId);
  if FOldIndex < 0 then Exit(False);
  FDoc.Timeline.MoveTrack(FTrackId, FNewIndex);
  FDoc.Touch;
  Result := True;
end;

procedure TMoveTimelineTrackCommand.Undo;
begin
  FDoc.Timeline.MoveTrack(FTrackId, FOldIndex);
  FDoc.Touch;
end;

function TMoveTimelineTrackCommand.Description: string;
begin
  Result := Format('Reorder track %d', [FTrackId]);
end;

{ ================= TRenameTimelineTrackCommand ================= }

constructor TRenameTimelineTrackCommand.Create(ADoc: TProjectDocument; ATrackId: Integer; const ANewName: string);
begin
  inherited Create;
  FDoc := ADoc;
  FTrackId := ATrackId;
  FNewName := ANewName;
end;

function TRenameTimelineTrackCommand.Execute: Boolean;
var
  trk: TTimelineTrack;
begin
  trk := FDoc.Timeline.TrackById(FTrackId);
  if trk = nil then Exit(False);
  FOldName := trk.Name;
  trk.Name := FNewName;
  FDoc.Touch;
  Result := True;
end;

procedure TRenameTimelineTrackCommand.Undo;
var
  trk: TTimelineTrack;
begin
  trk := FDoc.Timeline.TrackById(FTrackId);
  if trk = nil then Exit;
  trk.Name := FOldName;
  FDoc.Touch;
end;

function TRenameTimelineTrackCommand.Description: string;
begin
  Result := Format('Rename track to "%s"', [FNewName]);
end;

{ ================= TRemoveTimelineTrackCommand ================= }

constructor TRemoveTimelineTrackCommand.Create(ADoc: TProjectDocument; ATrackId: Integer);
begin
  inherited Create;
  FDoc := ADoc;
  FTrackId := ATrackId;
end;

function TRemoveTimelineTrackCommand.Execute: Boolean;
var
  tl: TTimeline;
  trk: TTimelineTrack;
  i: Integer;
begin
  tl := FDoc.Timeline;
  trk := tl.TrackById(FTrackId);
  if trk = nil then Exit(False);

  FIndex := tl.IndexOfTrack(FTrackId);
  FKind := trk.Kind;
  FName := trk.Name;
  FColor := trk.Color;
  FHeight := trk.Height;
  FMuted := trk.Muted;
  FSoloed := trk.Soloed;
  FArmed := trk.Armed;
  FGainDb := trk.GainDb;
  FPan := trk.Pan;
  SetLength(FClips, trk.ClipCount);
  for i := 0 to trk.ClipCount - 1 do
    FClips[i] := CaptureClip(tl, trk.GetClip(i).Id);

  tl.RemoveTrack(FTrackId);
  FDoc.Touch;
  Result := True;
end;

procedure TRemoveTimelineTrackCommand.Undo;
var
  tl: TTimeline;
  trk: TTimelineTrack;
  i: Integer;
begin
  tl := FDoc.Timeline;
  trk := tl.AddTrackWithId(FTrackId, FKind, FName);
  trk.Color := FColor;
  trk.Height := FHeight;
  trk.Muted := FMuted;
  trk.Soloed := FSoloed;
  trk.Armed := FArmed;
  trk.GainDb := FGainDb;
  trk.Pan := FPan;
  for i := 0 to High(FClips) do
    ApplyClipState(tl, FClips[i]);
  if (FIndex >= 0) and (FIndex < tl.TrackCount) then
    tl.MoveTrack(FTrackId, FIndex);
  FDoc.Touch;
end;

function TRemoveTimelineTrackCommand.Description: string;
begin
  Result := Format('Remove track "%s"', [FName]);
end;

{ ================= TSetTimelineMasterVolumeCommand ================= }

constructor TSetTimelineMasterVolumeCommand.Create(ADoc: TProjectDocument; ANewVolumeDb: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FNew := ANewVolumeDb;
end;

function TSetTimelineMasterVolumeCommand.Execute: Boolean;
begin
  FOld := FDoc.Timeline.MasterVolumeDb;
  FDoc.Timeline.MasterVolumeDb := FNew;
  if FDoc.Timeline.MasterVolumeDb = FOld then Exit(False);
  FDoc.Touch;
  Result := True;
end;

procedure TSetTimelineMasterVolumeCommand.Undo;
begin
  FDoc.Timeline.MasterVolumeDb := FOld;
  FDoc.Touch;
end;

function TSetTimelineMasterVolumeCommand.Description: string;
begin
  Result := 'Set Timeline master volume';
end;

function TSetTimelineMasterVolumeCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  n: TSetTimelineMasterVolumeCommand;
begin
  Result := (ANext is TSetTimelineMasterVolumeCommand) and
    (TSetTimelineMasterVolumeCommand(ANext).FDoc = FDoc) and
    (MsSinceStamp <= MERGE_MS);
  if Result then
  begin
    n := TSetTimelineMasterVolumeCommand(ANext);
    FNew := n.FNew;
    FDoc.Timeline.MasterVolumeDb := FNew;
    FDoc.Touch;
    Restamp;
  end;
end;

{ ================= TAddTimelineClipCommand ================= }

constructor TAddTimelineClipCommand.Create(ADoc: TProjectDocument; ATrackId, ASourceId: Integer;
  const AName: string; AStart, AOffset, ALength: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FTrackId := ATrackId;
  FSourceId := ASourceId;
  FName := AName;
  FStart := AStart;
  FOffset := AOffset;
  FLength := ALength;
  FCreatedId := -1;
end;

function TAddTimelineClipCommand.Execute: Boolean;
var
  c: TTimelineClip;
begin
  c := FDoc.Timeline.AddClip(FTrackId, FSourceId, FName, FStart, FOffset, FLength);
  FCreatedId := c.Id;
  FDoc.Touch;
  Result := True;
end;

procedure TAddTimelineClipCommand.Undo;
begin
  FDoc.Timeline.RemoveClip(FCreatedId);
  FDoc.Touch;
end;

function TAddTimelineClipCommand.Redo: Boolean;
begin
  FDoc.Timeline.AddClipWithId(FCreatedId, FTrackId, FSourceId, FName, FStart, FOffset, FLength);
  FDoc.Touch;
  Result := True;
end;

function TAddTimelineClipCommand.Description: string;
begin
  Result := Format('Add clip "%s"', [FName]);
end;

{ ================= TRemoveTimelineClipCommand ================= }

constructor TRemoveTimelineClipCommand.Create(ADoc: TProjectDocument; AClipId: Integer);
begin
  inherited Create;
  FDoc := ADoc;
  FClipId := AClipId;
end;

function TRemoveTimelineClipCommand.Execute: Boolean;
begin
  if FDoc.Timeline.ClipById(FClipId) = nil then Exit(False);
  FState := CaptureClip(FDoc.Timeline, FClipId);
  FDoc.Timeline.RemoveClip(FClipId);
  FDoc.Touch;
  Result := True;
end;

procedure TRemoveTimelineClipCommand.Undo;
begin
  ApplyClipState(FDoc.Timeline, FState);
  FDoc.Touch;
end;

function TRemoveTimelineClipCommand.Description: string;
begin
  Result := Format('Remove clip "%s"', [FState.Name]);
end;

{ ================= TMoveTimelineClipCommand ================= }

constructor TMoveTimelineClipCommand.Create(ADoc: TProjectDocument; AClipId: Integer;
  ANewStart: Double; ANewTrackId: Integer);
begin
  inherited Create;
  FDoc := ADoc;
  FClipId := AClipId;
  FNewStart := ANewStart;
  FNewTrackId := ANewTrackId;
end;

function TMoveTimelineClipCommand.Execute: Boolean;
var
  trk: TTimelineTrack;
  c: TTimelineClip;
begin
  c := FDoc.Timeline.ClipById(FClipId, trk);
  if c = nil then Exit(False);
  FOldStart := c.StartSeconds;
  FOldTrackId := trk.Id;
  if FNewTrackId = 0 then FNewTrackId := FOldTrackId;
  if (FNewStart = FOldStart) and (FNewTrackId = FOldTrackId) then Exit(False);
  FDoc.Timeline.MoveClip(FClipId, FNewStart, FNewTrackId);
  FDoc.Touch;
  Result := True;
end;

procedure TMoveTimelineClipCommand.Undo;
begin
  FDoc.Timeline.MoveClip(FClipId, FOldStart, FOldTrackId);
  FDoc.Touch;
end;

function TMoveTimelineClipCommand.Description: string;
begin
  Result := Format('Move clip %d', [FClipId]);
end;

function TMoveTimelineClipCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  n: TMoveTimelineClipCommand;
begin
  Result := (ANext is TMoveTimelineClipCommand) and
    (TMoveTimelineClipCommand(ANext).FDoc = FDoc) and
    (TMoveTimelineClipCommand(ANext).FClipId = FClipId) and
    (MsSinceStamp <= MERGE_MS);
  if Result then
  begin
    n := TMoveTimelineClipCommand(ANext);
    FNewStart := n.FNewStart;
    if n.FNewTrackId <> 0 then FNewTrackId := n.FNewTrackId;
    FDoc.Timeline.MoveClip(FClipId, FNewStart, FNewTrackId);
    FDoc.Touch;
    Restamp;
  end;
end;

{ ================= TTrimTimelineClipCommand ================= }

constructor TTrimTimelineClipCommand.Create(ADoc: TProjectDocument; AClipId: Integer;
  AEdge: TClipEdge; ANewSeconds: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FClipId := AClipId;
  FEdge := AEdge;
  FNewSeconds := ANewSeconds;
end;

function TTrimTimelineClipCommand.Execute: Boolean;
begin
  if FDoc.Timeline.ClipById(FClipId) = nil then Exit(False);
  if not FHaveBefore then
  begin
    FBefore := CaptureClip(FDoc.Timeline, FClipId);
    FHaveBefore := True;
  end;
  FDoc.Timeline.TrimClip(FClipId, FEdge, FNewSeconds);
  FDoc.Touch;
  Result := True;
end;

procedure TTrimTimelineClipCommand.Undo;
begin
  ApplyClipState(FDoc.Timeline, FBefore);
  FDoc.Touch;
end;

function TTrimTimelineClipCommand.Description: string;
begin
  if FEdge = ceStart then
    Result := Format('Trim clip %d start', [FClipId])
  else
    Result := Format('Trim clip %d end', [FClipId]);
end;

function TTrimTimelineClipCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  n: TTrimTimelineClipCommand;
begin
  Result := (ANext is TTrimTimelineClipCommand) and
    (TTrimTimelineClipCommand(ANext).FDoc = FDoc) and
    (TTrimTimelineClipCommand(ANext).FClipId = FClipId) and
    (TTrimTimelineClipCommand(ANext).FEdge = FEdge) and
    (MsSinceStamp <= MERGE_MS);
  if Result then
  begin
    n := TTrimTimelineClipCommand(ANext);
    FNewSeconds := n.FNewSeconds;
    FDoc.Timeline.TrimClip(FClipId, FEdge, FNewSeconds);
    FDoc.Touch;
    Restamp;
  end;
end;

{ ================= TSplitTimelineClipCommand ================= }

constructor TSplitTimelineClipCommand.Create(ADoc: TProjectDocument; AClipId: Integer;
  AAtSeconds: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FClipId := AClipId;
  FAtSeconds := AAtSeconds;
  FRightId := -1;
end;

function TSplitTimelineClipCommand.Execute: Boolean;
var
  right: TTimelineClip;
begin
  if FDoc.Timeline.ClipById(FClipId) = nil then Exit(False);
  FLeftBefore := CaptureClip(FDoc.Timeline, FClipId);
  if FRightId > 0 then
    right := FDoc.Timeline.SplitClip(FClipId, FAtSeconds, FRightId)
  else
    right := FDoc.Timeline.SplitClip(FClipId, FAtSeconds);
  FRightId := right.Id;
  FDoc.Touch;
  Result := True;
end;

procedure TSplitTimelineClipCommand.Undo;
begin
  { drop the right half, restore the left half exactly }
  if FDoc.Timeline.ClipById(FRightId) <> nil then
    FDoc.Timeline.RemoveClip(FRightId);
  ApplyClipState(FDoc.Timeline, FLeftBefore);
  FDoc.Touch;
end;

function TSplitTimelineClipCommand.Redo: Boolean;
begin
  Result := Execute;
end;

function TSplitTimelineClipCommand.Description: string;
begin
  Result := Format('Split clip %d', [FClipId]);
end;

{ ================= TSetTimelineClipGainCommand ================= }

constructor TSetTimelineClipGainCommand.Create(ADoc: TProjectDocument; AClipId: Integer;
  ANewGainDb: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FClipId := AClipId;
  FNewGain := ANewGainDb;
end;

function TSetTimelineClipGainCommand.Execute: Boolean;
var
  c: TTimelineClip;
begin
  c := FDoc.Timeline.ClipById(FClipId);
  if c = nil then Exit(False);
  if not FHaveOld then
  begin
    FOldGain := c.GainDb;
    FHaveOld := True;
  end;
  if c.GainDb = FNewGain then Exit(False);
  FDoc.Timeline.SetClipGain(FClipId, FNewGain);
  FDoc.Touch;
  Result := True;
end;

procedure TSetTimelineClipGainCommand.Undo;
begin
  FDoc.Timeline.SetClipGain(FClipId, FOldGain);
  FDoc.Touch;
end;

function TSetTimelineClipGainCommand.Description: string;
begin
  Result := Format('Set clip %d gain to %.1f dB', [FClipId, FNewGain]);
end;

function TSetTimelineClipGainCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
begin
  Result := (ANext is TSetTimelineClipGainCommand) and
    (TSetTimelineClipGainCommand(ANext).FDoc = FDoc) and
    (TSetTimelineClipGainCommand(ANext).FClipId = FClipId) and
    (MsSinceStamp <= MERGE_MS);
  if Result then
  begin
    FNewGain := TSetTimelineClipGainCommand(ANext).FNewGain;
    FDoc.Timeline.SetClipGain(FClipId, FNewGain);
    FDoc.Touch;
    Restamp;
  end;
end;

{ ================= TSetTimelineClipSourceCommand ================= }

constructor TSetTimelineClipSourceCommand.Create(ADoc: TProjectDocument; AClipId,
  ANewSourceId: Integer; ANewOffsetSeconds: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FClipId := AClipId;
  FNewSourceId := ANewSourceId;
  FNewOffset := ANewOffsetSeconds;
end;

function TSetTimelineClipSourceCommand.Execute: Boolean;
var
  c: TTimelineClip;
  trk: TTimelineTrack;
begin
  c := FDoc.Timeline.ClipById(FClipId, trk);
  if c = nil then Exit(False);
  if not FHaveOld then
  begin
    FOldSourceId := c.SourceId;
    FOldOffset := c.SourceOffsetSeconds;
    FOldRegions := Copy(c.EffectRegions);
    FOldEffName := c.EffectName;
    FOldEffOff := c.EffectOffsetSeconds;
    FOldEffLen := c.EffectLengthSeconds;
    FOldColor := c.Color;
    if trk <> nil then FOldTitle := trk.Title;
    FOldHasOrig := c.HasOrig;
    FOldOrigSrc := c.OrigSourceId;
    FOldOrigDelta := c.OrigDelta;
    { first rendered effect: remember the untouched audio for "Undo Effect" }
    if not c.HasOrig then
    begin
      c.HasOrig := True;
      c.OrigSourceId := FOldSourceId;
      c.OrigDelta := 0;
    end;
    { keep (original time) - (current time) exact across the source swap }
    c.OrigDelta := c.OrigDelta + FOldOffset - FNewOffset;
    FHaveOld := True;
  end
  else if FHaveRedo then
  begin
    { redo: put the labels the effect had back }
    c.EffectRegions := Copy(FRedoRegions);
    c.EffectName := FRedoEffName;
    c.EffectOffsetSeconds := FRedoEffOff;
    c.EffectLengthSeconds := FRedoEffLen;
    c.Color := FRedoColor;
    c.HasOrig := FRedoHasOrig;
    c.OrigSourceId := FRedoOrigSrc;
    c.OrigDelta := FRedoOrigDelta;
    if trk <> nil then trk.Title := FRedoTitle;
  end;
  FDoc.Timeline.SetClipSource(FClipId, FNewSourceId, FNewOffset);
  FDoc.Touch;
  Result := True;
end;

procedure TSetTimelineClipSourceCommand.Undo;
var
  c: TTimelineClip;
  trk: TTimelineTrack;
begin
  FDoc.Timeline.SetClipSource(FClipId, FOldSourceId, FOldOffset);
  c := FDoc.Timeline.ClipById(FClipId, trk);
  if c <> nil then
  begin
    FRedoRegions := Copy(c.EffectRegions);
    FRedoEffName := c.EffectName;
    FRedoEffOff := c.EffectOffsetSeconds;
    FRedoEffLen := c.EffectLengthSeconds;
    FRedoColor := c.Color;
    FRedoHasOrig := c.HasOrig;
    FRedoOrigSrc := c.OrigSourceId;
    FRedoOrigDelta := c.OrigDelta;
    c.HasOrig := FOldHasOrig;
    c.OrigSourceId := FOldOrigSrc;
    c.OrigDelta := FOldOrigDelta;
    if trk <> nil then FRedoTitle := trk.Title;
    FHaveRedo := True;
    c.EffectRegions := Copy(FOldRegions);
    c.EffectName := FOldEffName;
    c.EffectOffsetSeconds := FOldEffOff;
    c.EffectLengthSeconds := FOldEffLen;
    c.Color := FOldColor;
    if trk <> nil then trk.Title := FOldTitle;
  end;
  FDoc.Touch;
end;

function TSetTimelineClipSourceCommand.Description: string;
begin
  Result := Format('Apply effect to clip %d', [FClipId]);
end;

{ ================= TSetTimelineClipSourceBpmCommand ================= }

constructor TSetTimelineClipSourceBpmCommand.Create(ADoc: TProjectDocument;
  AClipId: Integer; ANewBpm: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FClipId := AClipId;
  if ANewBpm < 0 then ANewBpm := 0;
  FNewBpm := ANewBpm;
end;

function TSetTimelineClipSourceBpmCommand.Execute: Boolean;
var
  c: TTimelineClip;
  newF, oldF: Double;
begin
  c := FDoc.Timeline.ClipById(FClipId);
  if c = nil then Exit(False);
  if not FHaveOld then
  begin
    FOldBpm := c.SourceBPM;
    FHaveOld := True;
  end;
  if c.SourceBPM = FNewBpm then Exit(False);
  { The clip's length is in timeline seconds, so conforming it to the project
    tempo rescales it: a clip made at a slower tempo than the project ends
    sooner once sped up. Factor = source BPM / project BPM (1 when off). }
  FOldLen := c.LengthSeconds;
  if (FDoc.TempoBPM > 0) and (FNewBpm > 0) then newF := FNewBpm / FDoc.TempoBPM else newF := 1;
  if (FDoc.TempoBPM > 0) and (c.SourceBPM > 0) then oldF := c.SourceBPM / FDoc.TempoBPM else oldF := 1;
  c.LengthSeconds := FOldLen * newF / oldF;
  c.SourceBPM := FNewBpm;
  FDoc.Touch;
  Result := True;
end;

procedure TSetTimelineClipSourceBpmCommand.Undo;
var
  c: TTimelineClip;
begin
  c := FDoc.Timeline.ClipById(FClipId);
  if c <> nil then
  begin
    c.SourceBPM := FOldBpm;
    c.LengthSeconds := FOldLen;
  end;
  FDoc.Touch;
end;

function TSetTimelineClipSourceBpmCommand.Description: string;
begin
  Result := Format('Set clip %d source BPM', [FClipId]);
end;

{ ================= TSetTimelineClipReversedCommand ================= }

constructor TSetTimelineClipReversedCommand.Create(ADoc: TProjectDocument; AClipId: Integer;
  ANewReversed: Boolean);
begin
  inherited Create;
  FDoc := ADoc;
  FClipId := AClipId;
  FNewReversed := ANewReversed;
end;

function TSetTimelineClipReversedCommand.Execute: Boolean;
var
  c: TTimelineClip;
begin
  c := FDoc.Timeline.ClipById(FClipId);
  if c = nil then Exit(False);
  if not FHaveOld then
  begin
    FOldReversed := c.Reversed;
    FHaveOld := True;
  end;
  if c.Reversed = FNewReversed then Exit(False);
  FDoc.Timeline.SetClipReversed(FClipId, FNewReversed);
  FDoc.Touch;
  Result := True;
end;

procedure TSetTimelineClipReversedCommand.Undo;
begin
  FDoc.Timeline.SetClipReversed(FClipId, FOldReversed);
  FDoc.Touch;
end;

function TSetTimelineClipReversedCommand.Description: string;
begin
  Result := Format('Reverse clip %d', [FClipId]);
end;

{ ================= TSetTimelineClipFadeCommand ================= }

constructor TSetTimelineClipFadeCommand.Create(ADoc: TProjectDocument; AClipId: Integer;
  AEdge: TClipEdge; ANewSeconds: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FClipId := AClipId;
  FEdge := AEdge;
  FNewSeconds := ANewSeconds;
end;

function TSetTimelineClipFadeCommand.Execute: Boolean;
var
  c: TTimelineClip;
begin
  c := FDoc.Timeline.ClipById(FClipId);
  if c = nil then Exit(False);
  if not FHaveOld then
  begin
    FOldFadeIn := c.FadeInSeconds;
    FOldFadeOut := c.FadeOutSeconds;
    FOldRegions := Copy(c.EffectRegions);
    FHaveOld := True;
  end;
  if FEdge = ceStart then
    FDoc.Timeline.SetClipFades(FClipId, FNewSeconds, c.FadeOutSeconds)
  else
    FDoc.Timeline.SetClipFades(FClipId, c.FadeInSeconds, FNewSeconds);
  FDoc.Touch;
  Result := True;
end;

procedure TSetTimelineClipFadeCommand.Undo;
var
  c: TTimelineClip;
begin
  FDoc.Timeline.SetClipFades(FClipId, FOldFadeIn, FOldFadeOut);
  c := FDoc.Timeline.ClipById(FClipId);
  if c <> nil then c.EffectRegions := Copy(FOldRegions);
  FDoc.Touch;
end;

function TSetTimelineClipFadeCommand.Description: string;
begin
  if FEdge = ceStart then
    Result := Format('Set clip %d fade-in', [FClipId])
  else
    Result := Format('Set clip %d fade-out', [FClipId]);
end;

function TSetTimelineClipFadeCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  n: TSetTimelineClipFadeCommand;
begin
  Result := (ANext is TSetTimelineClipFadeCommand) and
    (TSetTimelineClipFadeCommand(ANext).FDoc = FDoc) and
    (TSetTimelineClipFadeCommand(ANext).FClipId = FClipId) and
    (TSetTimelineClipFadeCommand(ANext).FEdge = FEdge) and
    (MsSinceStamp <= MERGE_MS);
  if Result then
  begin
    n := TSetTimelineClipFadeCommand(ANext);
    FNewSeconds := n.FNewSeconds;
    Execute;
    Restamp;
  end;
end;

{ ================= TAddTimelineMarkerCommand ================= }

constructor TAddTimelineMarkerCommand.Create(ADoc: TProjectDocument; const AName: string;
  ASeconds: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FName := AName;
  FSeconds := ASeconds;
  FCreatedId := -1;
end;

function TAddTimelineMarkerCommand.Execute: Boolean;
begin
  FCreatedId := FDoc.Timeline.AddMarker(FName, FSeconds).Id;
  FDoc.Touch;
  Result := True;
end;

procedure TAddTimelineMarkerCommand.Undo;
begin
  FDoc.Timeline.RemoveMarker(FCreatedId);
  FDoc.Touch;
end;

function TAddTimelineMarkerCommand.Redo: Boolean;
begin
  FDoc.Timeline.AddMarkerWithId(FCreatedId, FName, FSeconds);
  FDoc.Touch;
  Result := True;
end;

function TAddTimelineMarkerCommand.Description: string;
begin
  Result := Format('Add marker "%s"', [FName]);
end;

end.
