unit UDAW.Codec.MP3.Timeline;
{$I udaw.inc}

{ Phase 15 follow-up - TImportMp3Command: an undoable "import an MP3 onto the
  timeline" step, so an MP3 lands as a non-destructive clip on the shared
  project undo/redo stack exactly like the WAV path the MainForm open-dialog
  builds inline.

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
  UDAW.Codec.MP3;

type
  TImportMp3Command = class(TDAWCommand)
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
  IMP_SUBSYS = 'Codec.MP3.Import';

constructor TImportMp3Command.Create(ADoc: TProjectDocument; ATrackId: Integer;
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

procedure TImportMp3Command.ResolveFile;
var
  info: TMP3StreamInfo;
begin
  if FResolved then Exit;
  if not FileExists(FPath) then
    RaiseUDAWFmt(errFileNotFound, IMP_SUBSYS, 'MP3 file not found: %s', [FPath]);
  if not Mp3SniffFile(FPath) then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'not an MPEG audio file: %s', [FPath]);
  if not Mp3ProbeFile(FPath, info) then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'could not read MP3 stream: %s', [FPath]);

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

function TImportMp3Command.DoApply: Boolean;
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

function TImportMp3Command.Execute: Boolean;
begin
  ResolveFile;
  Result := DoApply;
end;

function TImportMp3Command.Redo: Boolean;
begin
  Result := DoApply;
end;

procedure TImportMp3Command.Undo;
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

function TImportMp3Command.Description: string;
begin
  Result := Format('Import MP3 "%s"', [ExtractFileName(FPath)]);
end;

end.
