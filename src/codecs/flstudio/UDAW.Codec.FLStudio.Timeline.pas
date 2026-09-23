unit UDAW.Codec.FLStudio.Timeline;
{$I udaw.inc}

{ TImportFlpProjectCommand: an undoable "import an FL Studio Playlist onto the
  timeline" step - unlike the single-file importers (TImportMp3Command /
  TImportFlacCommand, which this unit's Execute/Undo/Redo/Description shape
  otherwise mirrors), one FLP can contribute MANY tracks and clips, and the
  whole playlist lands as a single undo step: one TTimelineTrack per distinct
  FL Studio playlist track that carried at least one importable audio-sample
  clip, one (deduplicated) TMediaSource per distinct resolved sample file,
  and one TTimelineClip per placed block. Undo removes exactly what this
  command added - every clip, any source that command orphaned, and any
  track this command created that is empty again afterwards (a track the
  user has since added other clips to is left alone).

  UDAW.Codec.FLStudio does the binary parsing and reports, per playlist
  block, only a TrackIndex/StartSeconds/LengthSeconds/ResolvedFilePath - it
  has no audio-decoding knowledge of its own. This unit is what turns a
  resolved sample path into something the timeline can actually play: it
  probes the file with this project's own WAV / MP3 / FLAC readers (in that
  order) to get the SampleRate/Channels/FrameCount a TMediaSource needs. A
  resolved sample in a format none of those three decode (e.g. OGG, which
  this project does not have a decoder for) is skipped with a warning - never
  imported with fabricated audio properties. }

interface

uses
  SysUtils,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Timeline.Model,
  UDAW.Codec.FLStudio,
  UDAW.Codec.WAV, UDAW.Codec.MP3, UDAW.Codec.FLAC;

type
  TImportFlpProjectCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FPath: string;
    FStartOffsetSeconds: Double;   // added to every clip's FLP-relative start

    { resolved on first Execute, reused by Redo }
    FResolved: Boolean;
    FProjectName: string;
    FTempo: Double;
    FWarnings: TArray<string>;
    FClips: TArray<TFlpAudioClip>;         // importable clips only (probe succeeded)
    FClipSampleRate: TArray<Integer>;
    FClipChannels: TArray<Integer>;
    FClipFrameCount: TArray<Int64>;
    FClipTrackSlot: TArray<Integer>;       // index into FTrackFlpIndex/FTrackIds

    { one row per distinct FLP playlist track carrying an importable clip }
    FTrackFlpIndex: TArray<Integer>;
    FTrackNames: TArray<string>;
    FTrackIds: TArray<Integer>;            // created (or re-created) track ids

    { one row per entry in FClips }
    FClipSourceId: TArray<Integer>;
    FClipSourceCreated: TArray<Boolean>;
    FClipId: TArray<Integer>;

    procedure ResolveFile;
    function DoApply: Boolean;
    function GetTrackCount: Integer;
    function GetClipCount: Integer;
  public
    { AStartOffsetSeconds shifts every FLP block's own (tick-derived) start
      time so the whole imported arrangement can be dropped at the playhead,
      the same way the single-file importers place their one clip there. }
    constructor Create(ADoc: TProjectDocument; const AFilePath: string;
      AStartOffsetSeconds: Double = 0);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;

    property ImportedTempo: Double read FTempo;
    property ImportedTrackCount: Integer read GetTrackCount;
    property ImportedClipCount: Integer read GetClipCount;
    property Warnings: TArray<string> read FWarnings;
  end;

implementation

const
  IMP_SUBSYS = 'Codec.FLStudio.Import';

procedure AppendWarn(var AWarnings: TArray<string>; const AMsg: string);
begin
  SetLength(AWarnings, Length(AWarnings) + 1);
  AWarnings[High(AWarnings)] := AMsg;
end;

{ Probes a resolved sample file with this project's own decoders (WAV, then
  MP3, then FLAC - the formats it can actually play). Never raises: a
  malformed or unsupported file simply fails the probe so the caller can skip
  that one clip with a warning instead of losing the whole import. }
function ProbeSampleFile(const APath: string; out ASampleRate, AChannels: Integer;
  out AFrameCount: Int64): Boolean;
var
  wav: TWavInfo;
  mp3Info: TMP3StreamInfo;
  flacInfo: TFLACStreamInfo;
begin
  Result := False;
  ASampleRate := 0; AChannels := 0; AFrameCount := 0;
  if (APath = '') or not FileExists(APath) then Exit;
  try
    if FileLooksLikeWav(APath) then
    begin
      wav := ReadWavInfo(APath);
      ASampleRate := wav.SampleRate;
      AChannels := wav.Channels;
      AFrameCount := wav.FrameCount;
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
  except
    Result := False;   // any decoder hiccup on a foreign file -> skip, don't crash
  end;
end;

constructor TImportFlpProjectCommand.Create(ADoc: TProjectDocument;
  const AFilePath: string; AStartOffsetSeconds: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FPath := AFilePath;
  FStartOffsetSeconds := AStartOffsetSeconds;
end;

function TImportFlpProjectCommand.GetTrackCount: Integer;
begin
  Result := Length(FTrackIds);
end;

function TImportFlpProjectCommand.GetClipCount: Integer;
begin
  Result := Length(FClips);
end;

procedure TImportFlpProjectCommand.ResolveFile;
var
  proj: TFlpProject;
  warnings: TArray<string>;
  i, j, n, foundSlot: Integer;
  ok: Boolean;
  sr, cc: Integer;
  frames: Int64;
  keepClips: TArray<TFlpAudioClip>;
  keepSR, keepCh: TArray<Integer>;
  keepFrames: TArray<Int64>;
  trackIdxSeen: TArray<Integer>;
  trackNameFor: TArray<string>;
  tmpI: Integer;
  tmpS: string;
begin
  if FResolved then Exit;
  if not FileExists(FPath) then
    RaiseUDAWFmt(errFileNotFound, IMP_SUBSYS, 'FLP file not found: %s', [FPath]);
  if not FlpSniffFile(FPath) then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'not an FL Studio project: %s', [FPath]);
  if not FlpParseFile(FPath, proj, warnings) then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'could not read FL Studio project: %s', [FPath]);

  FWarnings := warnings;
  FTempo := proj.Tempo;
  FProjectName := ExtractFileName(FPath);

  { keep only clips whose resolved sample this project can actually decode }
  SetLength(keepClips, 0);
  SetLength(keepSR, 0);
  SetLength(keepCh, 0);
  SetLength(keepFrames, 0);
  n := 0;
  for i := 0 to High(proj.Clips) do
  begin
    ok := ProbeSampleFile(proj.Clips[i].ResolvedFilePath, sr, cc, frames);
    if not ok then
    begin
      AppendWarn(FWarnings, Format(
        'sample "%s" is not a WAV/MP3/FLAC file this DAW can decode - skipped',
        [ExtractFileName(proj.Clips[i].ResolvedFilePath)]));
      Continue;
    end;
    SetLength(keepClips, n + 1);
    SetLength(keepSR, n + 1);
    SetLength(keepCh, n + 1);
    SetLength(keepFrames, n + 1);
    keepClips[n] := proj.Clips[i];
    keepSR[n] := sr;
    keepCh[n] := cc;
    keepFrames[n] := frames;
    Inc(n);
  end;
  FClips := keepClips;
  FClipSampleRate := keepSR;
  FClipChannels := keepCh;
  FClipFrameCount := keepFrames;

  { distinct FLP playlist tracks among the surviving clips, ascending index }
  SetLength(trackIdxSeen, 0);
  SetLength(trackNameFor, 0);
  for i := 0 to High(FClips) do
  begin
    foundSlot := -1;
    for j := 0 to High(trackIdxSeen) do
      if trackIdxSeen[j] = FClips[i].TrackIndex then
      begin
        foundSlot := j;
        Break;
      end;
    if foundSlot < 0 then
    begin
      SetLength(trackIdxSeen, Length(trackIdxSeen) + 1);
      SetLength(trackNameFor, Length(trackNameFor) + 1);
      trackIdxSeen[High(trackIdxSeen)] := FClips[i].TrackIndex;
      trackNameFor[High(trackNameFor)] := FClips[i].TrackName;
    end;
  end;
  for i := 1 to High(trackIdxSeen) do
  begin
    tmpI := trackIdxSeen[i];
    tmpS := trackNameFor[i];
    j := i - 1;
    while (j >= 0) and (trackIdxSeen[j] > tmpI) do
    begin
      trackIdxSeen[j + 1] := trackIdxSeen[j];
      trackNameFor[j + 1] := trackNameFor[j];
      Dec(j);
    end;
    trackIdxSeen[j + 1] := tmpI;
    trackNameFor[j + 1] := tmpS;
  end;

  SetLength(FTrackFlpIndex, Length(trackIdxSeen));
  SetLength(FTrackNames, Length(trackIdxSeen));
  SetLength(FTrackIds, Length(trackIdxSeen));
  for i := 0 to High(trackIdxSeen) do
  begin
    FTrackFlpIndex[i] := trackIdxSeen[i];
    FTrackNames[i] := trackNameFor[i];
    FTrackIds[i] := -1;
  end;

  SetLength(FClipTrackSlot, Length(FClips));
  for i := 0 to High(FClips) do
  begin
    FClipTrackSlot[i] := 0;
    for j := 0 to High(FTrackFlpIndex) do
      if FTrackFlpIndex[j] = FClips[i].TrackIndex then
      begin
        FClipTrackSlot[i] := j;
        Break;
      end;
  end;

  SetLength(FClipSourceId, Length(FClips));
  SetLength(FClipSourceCreated, Length(FClips));
  SetLength(FClipId, Length(FClips));
  for i := 0 to High(FClips) do
  begin
    FClipSourceId[i] := -1;
    FClipSourceCreated[i] := False;
    FClipId[i] := -1;
  end;

  FResolved := True;
end;

function TImportFlpProjectCommand.DoApply: Boolean;
var
  tl: TTimeline;
  i, slot: Integer;
  beforeCount: Integer;
  src: TMediaSource;
  clip: TTimelineClip;
  trk: TTimelineTrack;
begin
  tl := FDoc.Timeline;

  for i := 0 to High(FTrackIds) do
  begin
    if (FTrackIds[i] >= 0) and (tl.TrackById(FTrackIds[i]) <> nil) then Continue;
    if FTrackIds[i] >= 0 then
      trk := tl.AddTrackWithId(FTrackIds[i], tkAudio, FTrackNames[i])
    else
      trk := tl.AddTrack(tkAudio, FTrackNames[i]);
    FTrackIds[i] := trk.Id;
  end;

  for i := 0 to High(FClips) do
  begin
    slot := FClipTrackSlot[i];

    beforeCount := tl.SourceCount;
    if (FClipSourceId[i] >= 0) and (tl.SourceById(FClipSourceId[i]) <> nil) then
      src := tl.SourceById(FClipSourceId[i])
    else if FClipSourceId[i] >= 0 then
      src := tl.AddSourceWithId(FClipSourceId[i], FClips[i].ResolvedFilePath,
        FClipSampleRate[i], FClipChannels[i], FClipFrameCount[i])
    else
      src := tl.AddSource(FClips[i].ResolvedFilePath, FClipSampleRate[i],
        FClipChannels[i], FClipFrameCount[i]);
    FClipSourceId[i] := src.Id;
    FClipSourceCreated[i] := tl.SourceCount > beforeCount;

    if FClipId[i] >= 0 then
      clip := tl.AddClipWithId(FClipId[i], FTrackIds[slot], FClipSourceId[i],
        FClips[i].Name, FClips[i].StartSeconds + FStartOffsetSeconds, 0,
        FClips[i].LengthSeconds)
    else
      clip := tl.AddClip(FTrackIds[slot], FClipSourceId[i], FClips[i].Name,
        FClips[i].StartSeconds + FStartOffsetSeconds, 0, FClips[i].LengthSeconds);
    FClipId[i] := clip.Id;
  end;

  FDoc.Touch;
  Result := True;
end;

function TImportFlpProjectCommand.Execute: Boolean;
begin
  ResolveFile;
  if Length(FClips) = 0 then Exit(False);   // nothing importable - "nothing to do"
  Result := DoApply;
end;

function TImportFlpProjectCommand.Redo: Boolean;
begin
  Result := DoApply;
end;

procedure TImportFlpProjectCommand.Undo;
var
  tl: TTimeline;
  i: Integer;
  trk: TTimelineTrack;
  anySourceFreed: Boolean;
begin
  tl := FDoc.Timeline;

  for i := 0 to High(FClipId) do
    if (FClipId[i] >= 0) and (tl.ClipById(FClipId[i]) <> nil) then
      tl.RemoveClip(FClipId[i]);

  anySourceFreed := False;
  for i := 0 to High(FClipSourceId) do
    if FClipSourceCreated[i] and (FClipSourceId[i] >= 0) and
       (tl.SourceUseCount(FClipSourceId[i]) = 0) then
      anySourceFreed := True;
  if anySourceFreed then
    tl.RemoveUnusedSources;

  { drop tracks this import created that are empty again - never a track the
    user has since put other clips on }
  for i := 0 to High(FTrackIds) do
  begin
    if FTrackIds[i] < 0 then Continue;
    trk := tl.TrackById(FTrackIds[i]);
    if (trk <> nil) and (trk.ClipCount = 0) then
      tl.RemoveTrack(FTrackIds[i]);
  end;

  FDoc.Touch;
end;

function TImportFlpProjectCommand.Description: string;
begin
  Result := Format('Import FL Studio project "%s" (%d tracks)',
    [FProjectName, Length(FTrackIds)]);
end;

end.
