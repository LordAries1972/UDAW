unit UDAW.Codec.Ableton.Timeline;
{$I udaw.inc}

{ TImportAlsProjectCommand: an undoable "import a whole Ableton Live Set onto
  the timeline" step - one undo entry creates every audio track and clip the
  parsed project yields (mirrors UDAW.Codec.MP3.Timeline.TImportMp3Command's
  Execute/Undo/Redo/Description/ResolveFile/DoApply shape, but for N tracks
  and M clips per track instead of one clip).

  Execute parses the file (UDAW.Codec.Ableton.AlsParseFile - gzip+XML sniff,
  never the extension), then for every parsed AudioTrack adds a new
  TTimelineTrack and, for every clip on it whose sample resolved to a real
  file, probes that file's own format (content-sniffed against WAV/MP3/
  FLAC/MP4 in turn - Ableton itself most commonly stores WAV, but a project
  can reference anything the DAW already knows how to decode) and adds a
  TMediaSource + non-destructive TTimelineClip for it. Undo removes exactly
  the tracks/clips/sources this command created (sources only if nothing
  else references them, via the same RemoveUnusedSources sweep the other
  Import*Command units use); Redo re-creates all of it with the original
  ids so a later redo of a dependent edit still resolves.

  MIDI tracks, automation, warp markers and device chains are not
  represented in this DAW's project model and are never attempted here -
  AlsParseFile's warnings (surfaced via the Warnings property) are the
  record of what was left out and why, one line per issue, mirroring the
  ModExportIssues / XmExportIssues / MptmExportIssues pattern the tracker
  codecs use for lossy import/export caveats. }

interface

uses
  SysUtils, StrUtils,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Timeline.Model,
  UDAW.Codec.Ableton,
  UDAW.Codec.WAV,
  UDAW.Codec.MP3,
  UDAW.Codec.FLAC,
  UDAW.Codec.MP4;

type
  TImportAlsProjectCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FPath: string;
    FStartSeconds: Double;    // arrangement-origin offset on the DAW timeline
    { resolved on first Execute, reused by Redo }
    FResolved: Boolean;
    FProject: TAbletonProject;
    FWarnings: TArray<string>;      // from AlsParseFile - stable across Redo
    FApplyWarnings: TArray<string>; // per-DoApply sample-probe failures
    FAudioTrackCount: Integer;
    { created ids, index-parallel to FProject.Tracks restricted to the
      Kind = atkAudio entries (in order), so Undo removes exactly what this
      command added and Redo recreates the same ids. }
    FTrackIds: TArray<Integer>;
    FClipIds: TArray<TArray<Integer>>;
    FSourceIds: TArray<TArray<Integer>>;
    FSourceCreated: TArray<TArray<Boolean>>;
    function GetWarnings: TArray<string>;
    function GetImportedTempo: Double;
    procedure ResolveFile;
    function DoApply: Boolean;
  public
    { AStartSeconds shifts the whole imported arrangement's origin on the
      DAW timeline (0 = the set's own bar 1 lands at the playhead's/
      timeline's zero). }
    constructor Create(ADoc: TProjectDocument; const AFilePath: string;
      AStartSeconds: Double = 0);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;

    { Every recoverable issue found during parsing or clip import, in order:
      skipped MIDI/other tracks, unresolved samples, unsupported sample
      formats, missing tempo, unrepresented automation/warp features, etc. }
    property Warnings: TArray<string> read GetWarnings;
    property ImportedTempo: Double read GetImportedTempo;
    property AudioTrackCount: Integer read FAudioTrackCount;
  end;

implementation

const
  IMP_SUBSYS = 'Codec.Ableton.Import';

{ Content-sniffs ASourcePath against every audio format this DAW already
  decodes (WAV / MP3 / FLAC / MP4-AAC) and returns the stream facts
  TMediaSource needs. Ableton predominantly stores WAV, but nothing stops a
  project referencing an MP3/FLAC/MP4 sample, so all four are tried in turn
  - by content, matching the header-sniff convention every codec in this
  project follows, never by extension. }
function AlsProbeAudioFile(const APath: string; out ASampleRate, AChannels: Integer;
  out AFrameCount: Int64; out AWarning: string): Boolean;
var
  wavInfo: TWavInfo;
  mp3Info: TMP3StreamInfo;
  flacInfo: TFLACStreamInfo;
  mp4Info: TMP4ProbeInfo;
begin
  Result := False;
  AWarning := '';
  ASampleRate := 0;
  AChannels := 0;
  AFrameCount := 0;
  try
    if not FileExists(APath) then
    begin
      AWarning := Format('sample file no longer exists: %s', [APath]);
      Exit;
    end;

    if FileLooksLikeWav(APath) then
    begin
      wavInfo := ReadWavInfo(APath);
      ASampleRate := wavInfo.SampleRate;
      AChannels := wavInfo.Channels;
      AFrameCount := wavInfo.FrameCount;
      Exit(True);
    end;
    if Mp3SniffFile(APath) and Mp3ProbeFile(APath, mp3Info) then
    begin
      ASampleRate := mp3Info.SampleRate;
      AChannels := mp3Info.Channels;
      AFrameCount := mp3Info.TotalSamples;
      Exit(True);
    end;
    if FlacSniffFile(APath) and FlacProbeFile(APath, flacInfo) then
    begin
      ASampleRate := flacInfo.SampleRate;
      AChannels := flacInfo.Channels;
      AFrameCount := flacInfo.TotalSamples;
      Exit(True);
    end;
    if Mp4SniffFile(APath) and Mp4ProbeFile(APath, mp4Info) and
       mp4Info.HasAudio and mp4Info.Decodable then
    begin
      ASampleRate := mp4Info.SampleRate;
      AChannels := mp4Info.Channels;
      AFrameCount := mp4Info.SampleCount;
      Exit(True);
    end;

    AWarning := Format(
      'sample "%s" is not a recognised/decodable audio format (checked WAV/MP3/FLAC/MP4); clip skipped',
      [ExtractFileName(APath)]);
  except
    on E: Exception do
    begin
      Result := False;
      AWarning := Format('could not read sample "%s": %s', [ExtractFileName(APath), E.Message]);
    end;
  end;
end;

constructor TImportAlsProjectCommand.Create(ADoc: TProjectDocument;
  const AFilePath: string; AStartSeconds: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FPath := AFilePath;
  FStartSeconds := AStartSeconds;
end;

function TImportAlsProjectCommand.GetWarnings: TArray<string>;
var
  i: Integer;
begin
  SetLength(Result, Length(FWarnings) + Length(FApplyWarnings));
  for i := 0 to High(FWarnings) do
    Result[i] := FWarnings[i];
  for i := 0 to High(FApplyWarnings) do
    Result[Length(FWarnings) + i] := FApplyWarnings[i];
end;

function TImportAlsProjectCommand.GetImportedTempo: Double;
begin
  Result := FProject.Tempo;
end;

procedure TImportAlsProjectCommand.ResolveFile;
var
  i: Integer;
begin
  if FResolved then Exit;
  if not FileExists(FPath) then
    RaiseUDAWFmt(errFileNotFound, IMP_SUBSYS, 'Ableton Live Set not found: %s', [FPath]);
  if not AlsSniffFile(FPath) then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'not a GZIP-compressed Ableton Live Set: %s', [FPath]);
  if not AlsParseFile(FPath, FProject, FWarnings) then
    RaiseUDAWFmt(errParse, IMP_SUBSYS, 'could not parse Ableton Live Set: %s', [FPath]);

  FAudioTrackCount := 0;
  for i := 0 to High(FProject.Tracks) do
    if FProject.Tracks[i].Kind = atkAudio then Inc(FAudioTrackCount);

  FResolved := True;
end;

function TImportAlsProjectCommand.DoApply: Boolean;
var
  tl: TTimeline;
  ti, ci, audioIdx: Integer;
  track: TAbletonTrack;
  clip: TAbletonClip;
  trackId: Integer;
  beforeSrcCount: Integer;
  src: TMediaSource;
  clipObj: TTimelineClip;
  sr, ch: Integer;
  frames: Int64;
  probeWarn: string;
  applyWarn: TArray<string>;
begin
  tl := FDoc.Timeline;

  if Length(FTrackIds) = 0 then
  begin
    SetLength(FTrackIds, FAudioTrackCount);
    SetLength(FClipIds, FAudioTrackCount);
    SetLength(FSourceIds, FAudioTrackCount);
    SetLength(FSourceCreated, FAudioTrackCount);
    for ti := 0 to FAudioTrackCount - 1 do
      FTrackIds[ti] := -1;
  end;

  SetLength(applyWarn, 0);
  audioIdx := -1;
  for ti := 0 to High(FProject.Tracks) do
  begin
    track := FProject.Tracks[ti];
    if track.Kind <> atkAudio then Continue;
    Inc(audioIdx);

    if (FTrackIds[audioIdx] >= 0) and (tl.TrackById(FTrackIds[audioIdx]) <> nil) then
      trackId := FTrackIds[audioIdx]
    else if FTrackIds[audioIdx] >= 0 then
    begin
      tl.AddTrackWithId(FTrackIds[audioIdx], tkAudio, track.Name);
      trackId := FTrackIds[audioIdx];
    end
    else
      trackId := tl.AddTrack(tkAudio, track.Name).Id;
    FTrackIds[audioIdx] := trackId;

    if Length(FClipIds[audioIdx]) <> Length(track.Clips) then
    begin
      SetLength(FClipIds[audioIdx], Length(track.Clips));
      SetLength(FSourceIds[audioIdx], Length(track.Clips));
      SetLength(FSourceCreated[audioIdx], Length(track.Clips));
      for ci := 0 to High(FClipIds[audioIdx]) do
      begin
        FClipIds[audioIdx][ci] := -1;
        FSourceIds[audioIdx][ci] := -1;
      end;
    end;

    for ci := 0 to High(track.Clips) do
    begin
      clip := track.Clips[ci];

      if not AlsProbeAudioFile(clip.ResolvedFilePath, sr, ch, frames, probeWarn) then
      begin
        if probeWarn <> '' then
        begin
          SetLength(applyWarn, Length(applyWarn) + 1);
          applyWarn[High(applyWarn)] := Format('track "%s": %s', [track.Name, probeWarn]);
        end;
        Continue;
      end;

      beforeSrcCount := tl.SourceCount;
      if (FSourceIds[audioIdx][ci] >= 0) and (tl.SourceById(FSourceIds[audioIdx][ci]) <> nil) then
        src := tl.SourceById(FSourceIds[audioIdx][ci])
      else if FSourceIds[audioIdx][ci] >= 0 then
        src := tl.AddSourceWithId(FSourceIds[audioIdx][ci], clip.ResolvedFilePath, sr, ch, frames)
      else
        src := tl.AddSource(clip.ResolvedFilePath, sr, ch, frames);
      FSourceIds[audioIdx][ci] := src.Id;
      FSourceCreated[audioIdx][ci] := tl.SourceCount > beforeSrcCount;

      if FClipIds[audioIdx][ci] >= 0 then
        clipObj := tl.AddClipWithId(FClipIds[audioIdx][ci], trackId, src.Id, clip.Name,
          FStartSeconds + clip.StartSeconds, 0, clip.LengthSeconds)
      else
        clipObj := tl.AddClip(trackId, src.Id, clip.Name,
          FStartSeconds + clip.StartSeconds, 0, clip.LengthSeconds);
      FClipIds[audioIdx][ci] := clipObj.Id;

      if (clip.FadeInSeconds > 0) or (clip.FadeOutSeconds > 0) then
        tl.SetClipFades(clipObj.Id, clip.FadeInSeconds, clip.FadeOutSeconds);
    end;
  end;

  FApplyWarnings := applyWarn;
  FDoc.Touch;
  Result := True;
end;

function TImportAlsProjectCommand.Execute: Boolean;
begin
  ResolveFile;
  Result := DoApply;
end;

function TImportAlsProjectCommand.Redo: Boolean;
begin
  Result := DoApply;
end;

procedure TImportAlsProjectCommand.Undo;
var
  tl: TTimeline;
  ti, ci: Integer;
begin
  tl := FDoc.Timeline;

  for ti := 0 to High(FClipIds) do
    for ci := 0 to High(FClipIds[ti]) do
      if (FClipIds[ti][ci] >= 0) and (tl.ClipById(FClipIds[ti][ci]) <> nil) then
        tl.RemoveClip(FClipIds[ti][ci]);

  for ti := 0 to High(FSourceIds) do
    for ci := 0 to High(FSourceIds[ti]) do
      if FSourceCreated[ti][ci] and (FSourceIds[ti][ci] >= 0) and
         (tl.SourceUseCount(FSourceIds[ti][ci]) = 0) then
        tl.RemoveUnusedSources;

  for ti := 0 to High(FTrackIds) do
    if (FTrackIds[ti] >= 0) and (tl.TrackById(FTrackIds[ti]) <> nil) then
      tl.RemoveTrack(FTrackIds[ti]);

  FDoc.Touch;
end;

function TImportAlsProjectCommand.Description: string;
begin
  Result := Format('Import Ableton project "%s" (%d track%s)',
    [ExtractFileName(FPath), FAudioTrackCount, IfThen(FAudioTrackCount = 1, '', 's')]);
end;

end.
