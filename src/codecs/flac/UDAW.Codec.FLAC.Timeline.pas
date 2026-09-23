unit UDAW.Codec.FLAC.Timeline;
{$I udaw.inc}

{ TImportFlacCommand: an undoable "import a FLAC file onto the timeline" step,
  a structural mirror of UDAW.Codec.MP3.Timeline.TImportMp3Command - same
  fields, same Execute/Redo/Undo/Description/ResolveFile/DoApply shape, same
  property names - just probing via FlacSniffFile/FlacProbeFile instead of the
  MP3 equivalents.

  Execute probes the file (header sniff, never the extension), registers a
  TMediaSource for it (de-duplicated by the timeline), and adds one clip
  referencing that source.  Undo removes the clip and any source the import
  brought in that nothing else now uses.  Redo re-creates both with their
  original ids so a later redo of a dependent edit still resolves. }

interface

uses
  SysUtils,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Timeline.Model,
  UDAW.Codec.FLAC;

type
  TImportFlacCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FTrackId: Integer;
    FPath: string;
    FStartSeconds: Double;
    FMaxLenSeconds: Double;         // <= 0 means "whole file"
    { resolved on first Execute, reused by Redo }
    FResolved: Boolean;
    FSampleRate, FChannels: Integer;
    FFrameCount: Int64;
    FLenSeconds: Double;
    FClipName: string;
    { created ids }
    FSourceId: Integer;
    FSourceCreated: Boolean;        // this command is what added the source
    FClipId: Integer;
    procedure ResolveFile;
    function DoApply: Boolean;
  public
    { ATrackId must be an existing audio track.  AMaxLenSeconds <= 0 imports the
      whole file; otherwise the clip length is clamped. }
    constructor Create(ADoc: TProjectDocument; ATrackId: Integer;
      const AFilePath: string; AStartSeconds: Double; AMaxLenSeconds: Double = 0);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;

    property CreatedClipId: Integer read FClipId;
    property SourceId: Integer read FSourceId;
    property ImportedSampleRate: Integer read FSampleRate;
    property ImportedChannels: Integer read FChannels;
    property ImportedLengthSeconds: Double read FLenSeconds;
  end;

implementation

const
  IMP_SUBSYS = 'Codec.FLAC.Import';

constructor TImportFlacCommand.Create(ADoc: TProjectDocument; ATrackId: Integer;
  const AFilePath: string; AStartSeconds: Double; AMaxLenSeconds: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FTrackId := ATrackId;
  FPath := AFilePath;
  FStartSeconds := AStartSeconds;
  FMaxLenSeconds := AMaxLenSeconds;
  FClipId := -1;
  FSourceId := -1;
end;

procedure TImportFlacCommand.ResolveFile;
var
  info: TFLACStreamInfo;
begin
  if FResolved then Exit;
  if not FileExists(FPath) then
    RaiseUDAWFmt(errFileNotFound, IMP_SUBSYS, 'FLAC file not found: %s', [FPath]);
  if not FlacSniffFile(FPath) then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'not a FLAC file: %s', [FPath]);
  if not FlacProbeFile(FPath, info) then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'could not read FLAC stream: %s', [FPath]);

  FSampleRate := info.SampleRate;
  FChannels := info.Channels;
  FFrameCount := info.TotalSamples;
  FLenSeconds := info.DurationSeconds;
  if (FMaxLenSeconds > 0) and (FLenSeconds > FMaxLenSeconds) then
    FLenSeconds := FMaxLenSeconds;
  if FLenSeconds < 0.001 then FLenSeconds := 0.001;
  FClipName := ExtractFileName(FPath);
  FResolved := True;
end;

function TImportFlacCommand.DoApply: Boolean;
var
  tl: TTimeline;
  beforeCount: Integer;
  src: TMediaSource;
  clip: TTimelineClip;
begin
  tl := FDoc.Timeline;
  if tl.TrackById(FTrackId) = nil then
    RaiseUDAWFmt(errInvalidArgument, IMP_SUBSYS, 'no timeline track with id %d', [FTrackId]);

  beforeCount := tl.SourceCount;
  if (FSourceId >= 0) and (tl.SourceById(FSourceId) <> nil) then
    src := tl.SourceById(FSourceId)
  else if FSourceId >= 0 then
    src := tl.AddSourceWithId(FSourceId, FPath, FSampleRate, FChannels, FFrameCount)
  else
    src := tl.AddSource(FPath, FSampleRate, FChannels, FFrameCount);
  FSourceId := src.Id;
  FSourceCreated := tl.SourceCount > beforeCount;

  if FClipId >= 0 then
    clip := tl.AddClipWithId(FClipId, FTrackId, FSourceId, FClipName,
      FStartSeconds, 0, FLenSeconds)
  else
    clip := tl.AddClip(FTrackId, FSourceId, FClipName, FStartSeconds, 0, FLenSeconds);
  FClipId := clip.Id;

  FDoc.Touch;
  Result := True;
end;

function TImportFlacCommand.Execute: Boolean;
begin
  ResolveFile;
  Result := DoApply;
end;

function TImportFlacCommand.Redo: Boolean;
begin
  Result := DoApply;
end;

procedure TImportFlacCommand.Undo;
var
  tl: TTimeline;
begin
  tl := FDoc.Timeline;
  if (FClipId >= 0) and (tl.ClipById(FClipId) <> nil) then
    tl.RemoveClip(FClipId);
  if FSourceCreated and (FSourceId >= 0) and (tl.SourceUseCount(FSourceId) = 0) then
    tl.RemoveUnusedSources;
  FDoc.Touch;
end;

function TImportFlacCommand.Description: string;
begin
  Result := Format('Import FLAC "%s"', [ExtractFileName(FPath)]);
end;

end.
