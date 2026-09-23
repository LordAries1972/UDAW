unit UDAW.Recording.Commands;
{$I udaw.inc}

{ Phase 8 - Recording: commit a recorded/comped performance to the timeline as
  one undoable step (plan section 22 - recording produces non-destructive clips;
  section 28 - all editing is undoable).

  TCommitTakeCommand takes the TRecordedClipSpec list a take or a comp flattens
  to (UDAW.Recording.Takes) and, in a single TDAWCommand:
    * registers each distinct recorded .wav as a TMediaSource on the timeline
      (deduped by the model), and
    * drops one non-destructive TTimelineClip per spec onto the target track,
      creating the track first when ATrackId = 0.
  Undo removes exactly those clips (and the track, if this command created it);
  the media-source registrations are left in place - they are harmless, shared,
  and re-used verbatim on Redo. }

interface

uses
  SysUtils,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Timeline.Model,
  UDAW.Recording.Takes;

type
  TCommitTakeCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FTrackId: Integer;          // 0 => create a new audio track
    FTrackName: string;
    FSpecs: TRecordedClipSpecArray;
    FCreatedTrackId: Integer;   // <> 0 only when this command made the track
    FClipIds: TArray<Integer>;
    FSourceIds: TArray<Integer>;
    FExecuted: Boolean;
    function ResolveTrackId: Integer;
    procedure PlaceClips(AReuseIds: Boolean);
  public
    { ASpecs is copied. ATrackId = 0 asks the command to add an audio track
      named ATrackName (or an auto name) and commit onto it. }
    constructor Create(ADoc: TProjectDocument; ATrackId: Integer;
      const ASpecs: TRecordedClipSpecArray; const ATrackName: string = '');
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;

    property CreatedTrackId: Integer read FCreatedTrackId;
    property ClipIds: TArray<Integer> read FClipIds;
  end;

implementation

constructor TCommitTakeCommand.Create(ADoc: TProjectDocument; ATrackId: Integer;
  const ASpecs: TRecordedClipSpecArray; const ATrackName: string);
var
  i: Integer;
begin
  inherited Create;
  if ADoc = nil then
    RaiseUDAW(errInvalidArgument, 'Recording.Cmd', 'nil document');
  FDoc := ADoc;
  FTrackId := ATrackId;
  FTrackName := ATrackName;
  SetLength(FSpecs, Length(ASpecs));
  for i := 0 to High(ASpecs) do
    FSpecs[i] := ASpecs[i];
  FCreatedTrackId := 0;
end;

function TCommitTakeCommand.ResolveTrackId: Integer;
var
  trk: TTimelineTrack;
  nm: string;
begin
  if FTrackId <> 0 then
  begin
    if FDoc.Timeline.TrackById(FTrackId) = nil then
      RaiseUDAWFmt(errInvalidArgument, 'Recording.Cmd', 'no track with id %d', [FTrackId]);
    Exit(FTrackId);
  end;
  if FCreatedTrackId <> 0 then
  begin
    { redo path - recreate the same track with the same id }
    trk := FDoc.Timeline.AddTrackWithId(FCreatedTrackId, tkAudio, FTrackName);
    Exit(trk.Id);
  end;
  if Trim(FTrackName) <> '' then nm := FTrackName
  else nm := Format('Audio %d', [FDoc.Timeline.TrackCount + 1]);
  trk := FDoc.Timeline.AddTrack(tkAudio, nm);
  FCreatedTrackId := trk.Id;
  FTrackName := nm;
  Result := trk.Id;
end;

procedure TCommitTakeCommand.PlaceClips(AReuseIds: Boolean);
var
  i, trackId: Integer;
  src: TMediaSource;
  clip: TTimelineClip;
begin
  trackId := ResolveTrackId;
  SetLength(FClipIds, Length(FSpecs));
  SetLength(FSourceIds, Length(FSpecs));
  for i := 0 to High(FSpecs) do
  begin
    src := FDoc.Timeline.AddSource(FSpecs[i].SourceWavFile, FSpecs[i].SampleRate,
      FSpecs[i].Channels, FSpecs[i].SourceFrameCount, mkAudioFile);
    FSourceIds[i] := src.Id;
    if AReuseIds and (i <= High(FClipIds)) and (FClipIds[i] > 0) then
      clip := FDoc.Timeline.AddClipWithId(FClipIds[i], trackId, src.Id,
        FSpecs[i].Name, FSpecs[i].TimelineStartSeconds,
        FSpecs[i].SourceOffsetSeconds, FSpecs[i].LengthSeconds)
    else
      clip := FDoc.Timeline.AddClip(trackId, src.Id, FSpecs[i].Name,
        FSpecs[i].TimelineStartSeconds, FSpecs[i].SourceOffsetSeconds,
        FSpecs[i].LengthSeconds);
    FClipIds[i] := clip.Id;
  end;
end;

function TCommitTakeCommand.Execute: Boolean;
begin
  if Length(FSpecs) = 0 then Exit(False);
  PlaceClips({AReuseIds=} FExecuted);
  FExecuted := True;
  FDoc.Touch;
  Result := True;
end;

procedure TCommitTakeCommand.Undo;
var
  i: Integer;
begin
  for i := 0 to High(FClipIds) do
    if (FClipIds[i] > 0) and (FDoc.Timeline.ClipById(FClipIds[i]) <> nil) then
      FDoc.Timeline.RemoveClip(FClipIds[i]);
  if (FCreatedTrackId <> 0) and (FDoc.Timeline.TrackById(FCreatedTrackId) <> nil) then
    FDoc.Timeline.RemoveTrack(FCreatedTrackId);
  FDoc.Touch;
end;

function TCommitTakeCommand.Redo: Boolean;
begin
  Result := Execute;
end;

function TCommitTakeCommand.Description: string;
begin
  if Length(FSpecs) = 1 then
    Result := Format('Commit take "%s" to timeline', [FSpecs[0].Name])
  else
    Result := Format('Commit %d recorded clips to timeline', [Length(FSpecs)]);
end;

end.
