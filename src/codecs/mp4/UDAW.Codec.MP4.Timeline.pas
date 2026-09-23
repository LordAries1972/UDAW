unit UDAW.Codec.MP4.Timeline;
{$I udaw.inc}

{ MP4/M4A timeline follow-up: TImportMp4Command - an undoable "import an
  MP4/M4A onto the timeline" step, mirroring UDAW.Codec.MP3.Timeline's
  TImportMp3Command exactly.

  Execute probes the file (header sniff, never the extension - Mp4ProbeFile),
  refuses codecs this build cannot turn into PCM yet (AAC-LC until Phase 16b's
  tables land; fragmented MP4), registers a TMediaSource for it (de-duplicated
  by the timeline), and adds one clip referencing that source.  Undo removes
  the clip and any source the import brought in that nothing else now uses.
  Redo re-creates both with their original ids so a later redo of a dependent
  edit still resolves. }

interface

uses
  SysUtils,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Timeline.Model,
  UDAW.Codec.MP4;

type
  TImportMp4Command = class(TDAWCommand)
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
    FCodecName: string;
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
    property ImportedCodecName: string read FCodecName;
  end;

implementation

const
  IMP_SUBSYS = 'Codec.MP4.Import';

constructor TImportMp4Command.Create(ADoc: TProjectDocument; ATrackId: Integer;
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

procedure TImportMp4Command.ResolveFile;
var
  info: TMP4ProbeInfo;
begin
  if FResolved then Exit;
  if not FileExists(FPath) then
    RaiseUDAWFmt(errFileNotFound, IMP_SUBSYS, 'MP4 file not found: %s', [FPath]);
  if not Mp4SniffFile(FPath) then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'not an MP4/M4A file: %s', [FPath]);
  if not Mp4ProbeFile(FPath, info) then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'could not read MP4 container: %s', [FPath]);
  if not info.HasAudio then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'MP4 has no sound track: %s', [FPath]);
  if not info.Decodable then
    RaiseUDAWFmt(errNotImplemented, IMP_SUBSYS,
      'audio codec "%s" in %s cannot be decoded by this build yet', [info.CodecName, FPath]);

  FSampleRate := info.SampleRate;
  FChannels := info.Channels;
  FFrameCount := info.SampleCount;
  FLenSeconds := info.DurationSeconds;
  FCodecName := info.CodecName;
  if (FMaxLenSeconds > 0) and (FLenSeconds > FMaxLenSeconds) then
    FLenSeconds := FMaxLenSeconds;
  if FLenSeconds < 0.001 then FLenSeconds := 0.001;
  FClipName := ExtractFileName(FPath);
  FResolved := True;
end;

function TImportMp4Command.DoApply: Boolean;
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

function TImportMp4Command.Execute: Boolean;
begin
  ResolveFile;
  Result := DoApply;
end;

function TImportMp4Command.Redo: Boolean;
begin
  Result := DoApply;
end;

procedure TImportMp4Command.Undo;
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

function TImportMp4Command.Description: string;
begin
  Result := Format('Import MP4 "%s"', [ExtractFileName(FPath)]);
end;

end.
