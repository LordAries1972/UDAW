unit UDAW.Codec.MP4.Timeline;
{$I udaw.inc}

{ MP4/M4A/MKV timeline follow-up: TImportMp4Command - an undoable "import a
  media file onto the timeline" step, mirroring UDAW.Codec.MP3.Timeline's
  TImportMp3Command.

  Resolve probes the file (header sniff, never the extension - Mp4ProbeFile) and
  decodes EVERY sound stream it holds (a film can carry several languages or a
  commentary besides the main mix) into a float WAV in the cache folder.  The
  timeline sources point at those cached WAVs, not at the container (a stream
  with more than two channels, such as 5.1, is split into one mono WAV and one
  track per channel; mono and stereo stay a single clip), so audio
  effects, range edits and renders always work on plain, already-decoded sound
  and never have to open the video file again.  A cached WAV is reused while the
  media file is unchanged.

    - sound   -> one clip per stream, on that stream's own track
                 (AudioTrackIds[n] >= 0).  A stream this build cannot decode is
                 skipped when the file has other sound or video, and refused
                 when nothing else could be imported.
    - picture -> a clip on VideoTrackId (when >= 0) backed by a mkVideoFile
                 source on the original file, starting at the same timeline
                 position as the sound so the channels stay in step.

  Callers call Resolve first to learn what the file holds (to create only the
  tracks that will be used), then set the track ids and Perform the command.
  Undo removes the clips and any source the import brought in that nothing else
  now uses (the cached WAVs stay, so a redo is instant).  Redo re-creates them
  with their original ids so a later redo of a dependent edit still resolves. }

interface

uses
  {$IFNDEF FPC}Winapi.Windows,{$ENDIF}   // first, so SysUtils' file routines win; lets RenameFile inline
  SysUtils, Classes,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Timeline.Model,
  UDAW.Codec.MP4;

type
  TImportedAudioStream = record
    TrackId: Integer;               // timeline track, < 0 = skip this stream
    CachePath: string;              // decoded float WAV in the cache folder
    SampleRate, Channels: Integer;
    FrameCount: Int64;
    LenSeconds: Double;
    CodecName: string;
    ClipName: string;
    SourceId: Integer;
    SourceCreated: Boolean;         // this command is what added the source
    ClipId: Integer;
  end;

  TImportMp4Command = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FVideoTrackId: Integer;         // video track, < 0 = import no picture
    FFirstTrackId: Integer;         // AudioTrackId set before Resolve (stream 0)
    FPath: string;
    FStartSeconds: Double;
    FMaxLenSeconds: Double;         // <= 0 means "whole file"
    { resolved on first Resolve/Execute, reused by Redo }
    FResolved: Boolean;
    FStreams: array of TImportedAudioStream;   // the decoded sound streams
    FHasVideo: Boolean;
    FVideoLenSeconds: Double;
    FVideoWidth, FVideoHeight: Integer;
    FClipName: string;
    FVideoCodecName: string;
    FAudioSkipNote: string;
    { created ids }
    FVideoSourceId: Integer;
    FVideoSourceCreated: Boolean;
    FVideoClipId: Integer;
    procedure ResolveFile;
    function DoApply: Boolean;
    function CachePathFor(AStream, AChannel: Integer): string;
    function GetHasAudio: Boolean;
    function GetAudioTrackId: Integer;
    procedure SetAudioTrackId(AValue: Integer);
    function GetStreamCount: Integer;
    function GetStream(AIndex: Integer): TImportedAudioStream;
  public
    { ATrackId must be an existing audio track, or -1 to import no sound.  It is
      the track of the first sound stream; set the others with SetStreamTrack.
      AMaxLenSeconds <= 0 imports the whole file; otherwise the clip lengths
      are clamped. }
    constructor Create(ADoc: TProjectDocument; ATrackId: Integer;
      const AFilePath: string; AStartSeconds: Double; AMaxLenSeconds: Double = 0);
    { Probes and decodes the file now (raises like Execute would) so the streams
      are known before any track is created. }
    procedure Resolve;
    { which track the sound stream AIndex goes on; -1 skips that stream }
    procedure SetStreamTrack(AIndex, ATrackId: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;

    { the first sound stream - what a single-stream caller needs }
    property AudioTrackId: Integer read GetAudioTrackId write SetAudioTrackId;
    property VideoTrackId: Integer read FVideoTrackId write FVideoTrackId;
    property HasAudio: Boolean read GetHasAudio;
    property HasVideo: Boolean read FHasVideo;
    property AudioStreamCount: Integer read GetStreamCount;
    property AudioStreams[AIndex: Integer]: TImportedAudioStream read GetStream;
    property AudioSkipNote: string read FAudioSkipNote;
    function CreatedClipId: Integer;
    property CreatedVideoClipId: Integer read FVideoClipId;
    function SourceId: Integer;
    property VideoSourceId: Integer read FVideoSourceId;
    function ImportedSampleRate: Integer;
    function ImportedChannels: Integer;
    function ImportedLengthSeconds: Double;
    function ImportedCodecName: string;
    property ImportedVideoCodecName: string read FVideoCodecName;
    property ImportedVideoLengthSeconds: Double read FVideoLenSeconds;
    property ImportedVideoWidth: Integer read FVideoWidth;
    property ImportedVideoHeight: Integer read FVideoHeight;
  end;

implementation

uses
  Math,
  UDAW.Audio.Types, UDAW.Paths, UDAW.Codec.WAV;

const
  IMP_SUBSYS = 'Codec.MP4.Import';
  IMP_CACHE_FOLDER = 'video-audio';

constructor TImportMp4Command.Create(ADoc: TProjectDocument; ATrackId: Integer;
  const AFilePath: string; AStartSeconds: Double; AMaxLenSeconds: Double);
begin
  inherited Create;
  FDoc := ADoc;
  FFirstTrackId := ATrackId;
  FVideoTrackId := -1;
  FPath := AFilePath;
  FStartSeconds := AStartSeconds;
  FMaxLenSeconds := AMaxLenSeconds;
  FVideoSourceId := -1;
  FVideoClipId := -1;
end;

{ A name unique to this file's identity: path + size + write time, so editing or
  replacing the media file never serves a stale decode. }
function TImportMp4Command.CachePathFor(AStream, AChannel: Integer): string;
var
  sr: TSearchRec;
  stamp, baseName: string;
  i: Integer;
  h1, h2: Int64;
begin
  stamp := LowerCase(ExpandFileName(FPath));
  if FindFirst(FPath, faAnyFile, sr) = 0 then
  begin
    stamp := stamp + '|' + IntToStr(sr.Size) + '|' + IntToStr(Round(sr.TimeStamp * 86400000));
    FindClose(sr);
  end;
  { two 32-bit multiplicative hashes, masked each step so nothing overflows }
  h1 := 5381;
  h2 := 52711;
  for i := 1 to Length(stamp) do
  begin
    h1 := ((h1 * 33) and $FFFFFFFF) xor Ord(stamp[i]);
    h2 := ((h2 * 31) and $FFFFFFFF) xor (Ord(stamp[i]) * 7);
  end;
  baseName := ChangeFileExt(ExtractFileName(FPath), '');
  for i := 1 to Length(baseName) do
    if CharInSet(baseName[i], ['\', '/', ':', '*', '?', '"', '<', '>', '|']) then
      baseName[i] := '_';
  if Length(baseName) > 60 then SetLength(baseName, 60);
  Result := IMP_CACHE_FOLDER + PathDelim + baseName + '_' +
    IntToHex(h1, 8) + IntToHex(h2, 8) + '_a' + IntToStr(AStream + 1);
  if AChannel >= 0 then Result := Result + '_c' + IntToStr(AChannel + 1);
  Result := CacheFile(Result + '.wav');
end;

procedure TImportMp4Command.ResolveFile;
const
  SURROUND_51: array[0..5] of string = ('L', 'R', 'C', 'LFE', 'Ls', 'Rs');
  { the engine's order for 8 channels: L R C LFE, then the side and the
    back/wide pair (a decoder that follows the Windows layout delivers the
    back pair before the side pair, so these two labels are positional) }
  SURROUND_71: array[0..7] of string = ('L', 'R', 'C', 'LFE', 'Ls / Lb', 'Rs / Rb',
    'Lb / Lc', 'Rb / Rc');
var
  info: TMP4ProbeInfo;
  i, n, c, goodCount: Integer;
  res: TMP4DecodeResult;
  wi: TWavInfo;
  note: string;
  good: array of TImportedAudioStream;
  one: TAudioPlanar;

  { one clip's worth of cached sound: AChannel < 0 = the stream's whole WAV,
    otherwise that single channel of a multichannel stream }
  procedure AddPart(AStream, AChannel, ATotalChannels: Integer; const APath: string;
    ARate, AChans: Integer; AFrames: Int64; const ACodec: string);
  var
    st: TImportedAudioStream;
    nm: string;
  begin
    FillChar(st, SizeOf(st), 0);
    st.TrackId := -1;
    st.SourceId := -1;
    st.ClipId := -1;
    st.CachePath := APath;
    st.SampleRate := ARate;
    st.Channels := AChans;
    st.FrameCount := AFrames;
    st.CodecName := ACodec;
    if st.CodecName = '' then st.CodecName := info.CodecName;
    st.LenSeconds := AFrames / ARate;
    if (FMaxLenSeconds > 0) and (st.LenSeconds > FMaxLenSeconds) then
      st.LenSeconds := FMaxLenSeconds;
    if st.LenSeconds < 0.001 then st.LenSeconds := 0.001;
    if n > 1 then st.ClipName := Format('%s (audio %d)', [FClipName, AStream + 1])
    else st.ClipName := FClipName;
    if AChannel >= 0 then
    begin
      if (ATotalChannels = 6) and (AChannel <= High(SURROUND_51)) then
        nm := SURROUND_51[AChannel]
      else if (ATotalChannels = 8) and (AChannel <= High(SURROUND_71)) then
        nm := SURROUND_71[AChannel]
      else
        nm := 'ch ' + IntToStr(AChannel + 1);
      st.ClipName := st.ClipName + ' - ' + nm;
    end;
    SetLength(good, goodCount + 1);
    good[goodCount] := st;
    Inc(goodCount);
  end;

  { written whole or not at all: a half file must never be found later }
  procedure SaveAtomic(const APath: string; const AData: TAudioPlanar;
    AChans, ARate, AFrames: Integer);
  var
    tmp: string;
  begin
    tmp := APath + '.tmp';
    SaveWavFile(tmp, AData, AChans, ARate, AFrames, wsfFloat32);
    if not RenameFile(tmp, APath) then
    begin
      DeleteFile(tmp);
      RaiseUDAWFmt(errIO, IMP_SUBSYS, 'could not write cache file %s', [APath]);
    end;
  end;

  { the cache already holds this stream (whole, or one WAV per channel) }
  function TryCached(AStream: Integer): Boolean;
  var
    p: string;
    k, found: Integer;
  begin
    Result := False;
    p := CachePathFor(AStream, -1);
    try
      if FileExists(p) then
      begin
        wi := ReadWavInfo(p);
        if wi.FrameCount > 0 then
        begin
          AddPart(AStream, -1, wi.Channels, p, wi.SampleRate, wi.Channels, wi.FrameCount, '');
          Exit(True);
        end;
      end;
      found := 0;
      while FileExists(CachePathFor(AStream, found)) do Inc(found);
      if found < 3 then Exit;
      for k := 0 to found - 1 do
      begin
        wi := ReadWavInfo(CachePathFor(AStream, k));
        if wi.FrameCount <= 0 then Exit;
      end;
      for k := 0 to found - 1 do
      begin
        wi := ReadWavInfo(CachePathFor(AStream, k));
        AddPart(AStream, k, found, CachePathFor(AStream, k), wi.SampleRate, 1, wi.FrameCount, '');
      end;
      Result := True;
    except
      on E: EUDAWError do
        Result := False;                    // torn or damaged: decode again
    end;
  end;

begin
  if FResolved then Exit;
  if not FileExists(FPath) then
    RaiseUDAWFmt(errFileNotFound, IMP_SUBSYS, 'media file not found: %s', [FPath]);
  if not Mp4SniffFile(FPath) then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'not an MP4/M4A/MKV file: %s', [FPath]);
  if not Mp4ProbeFile(FPath, info) then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'could not read media container: %s', [FPath]);
  if not (info.HasAudio or info.HasVideo) then
    RaiseUDAWFmt(errConfig, IMP_SUBSYS, 'file has no sound or video track: %s', [FPath]);

  FHasVideo := info.HasVideo;
  FClipName := ExtractFileName(FPath);

  { every sound stream -> cached WAV(s): mono and stereo stay one clip, a
    multichannel stream (5.1 ...) is split into one mono WAV and track per channel }
  goodCount := 0;
  note := '';
  n := Max(1, info.AudioStreamCount);
  if info.HasAudio then
  begin
    ForceDirectories(CacheFile(IMP_CACHE_FOLDER));
    for i := 0 to n - 1 do
    begin
      if TryCached(i) then Continue;
      try
        if not Mp4DecodeAudioStreamFile(FPath, i, res) or (res.Frames <= 0) then
        begin
          note := note + Format('sound stream %d produced no audio; ', [i + 1]);
          Continue;
        end;
        if res.Channels > 2 then
        begin
          for c := 0 to res.Channels - 1 do
          begin
            SetLength(one, 1);
            one[0] := res.Data[c];
            SaveAtomic(CachePathFor(i, c), one, 1, res.SampleRate, res.Frames);
          end;
          for c := 0 to res.Channels - 1 do
            AddPart(i, c, res.Channels, CachePathFor(i, c), res.SampleRate, 1, res.Frames,
              res.CodecName);
        end
        else
        begin
          SaveAtomic(CachePathFor(i, -1), res.Data, res.Channels, res.SampleRate, res.Frames);
          AddPart(i, -1, res.Channels, CachePathFor(i, -1), res.SampleRate, res.Channels,
            res.Frames, res.CodecName);
        end;
        res.Data := nil;
        one := nil;
      except
        on E: EUDAWError do
          note := note + Format('sound stream %d: %s; ', [i + 1, E.Message]);
      end;
    end;
    if (goodCount = 0) and (not info.HasVideo) then
      RaiseUDAWFmt(errNotImplemented, IMP_SUBSYS,
        'the sound in %s cannot be decoded by this build: %s', [FPath, note]);
    if goodCount = 0 then
      FAudioSkipNote := 'sound could not be decoded - sound skipped (' + Trim(note) + ')'
    else if note <> '' then
      FAudioSkipNote := 'some sound streams were skipped: ' + Trim(note);
  end;
  SetLength(FStreams, goodCount);
  for i := 0 to goodCount - 1 do FStreams[i] := good[i];
  if (goodCount > 0) then FStreams[0].TrackId := FFirstTrackId;

  if FHasVideo then
  begin
    FVideoCodecName := info.VideoCodecName;
    FVideoWidth := info.VideoWidth;
    FVideoHeight := info.VideoHeight;
    FVideoLenSeconds := info.VideoDurationSeconds;
    if FVideoLenSeconds <= 0 then FVideoLenSeconds := info.DurationSeconds;
    if (FMaxLenSeconds > 0) and (FVideoLenSeconds > FMaxLenSeconds) then
      FVideoLenSeconds := FMaxLenSeconds;
    if FVideoLenSeconds < 0.001 then FVideoLenSeconds := 0.001;
  end;

  FResolved := True;
end;

procedure TImportMp4Command.Resolve;
begin
  ResolveFile;
end;

function TImportMp4Command.GetHasAudio: Boolean;
begin
  Result := Length(FStreams) > 0;
end;

function TImportMp4Command.GetStreamCount: Integer;
begin
  Result := Length(FStreams);
end;

function TImportMp4Command.GetStream(AIndex: Integer): TImportedAudioStream;
begin
  Result := FStreams[AIndex];
end;

function TImportMp4Command.GetAudioTrackId: Integer;
begin
  if Length(FStreams) > 0 then Result := FStreams[0].TrackId
  else Result := FFirstTrackId;
end;

procedure TImportMp4Command.SetAudioTrackId(AValue: Integer);
begin
  FFirstTrackId := AValue;
  if Length(FStreams) > 0 then FStreams[0].TrackId := AValue;
end;

procedure TImportMp4Command.SetStreamTrack(AIndex, ATrackId: Integer);
begin
  if (AIndex >= 0) and (AIndex < Length(FStreams)) then
    FStreams[AIndex].TrackId := ATrackId;
  if AIndex = 0 then FFirstTrackId := ATrackId;
end;

function TImportMp4Command.CreatedClipId: Integer;
begin
  if Length(FStreams) > 0 then Result := FStreams[0].ClipId else Result := -1;
end;

function TImportMp4Command.SourceId: Integer;
begin
  if Length(FStreams) > 0 then Result := FStreams[0].SourceId else Result := -1;
end;

function TImportMp4Command.ImportedSampleRate: Integer;
begin
  if Length(FStreams) > 0 then Result := FStreams[0].SampleRate else Result := 0;
end;

function TImportMp4Command.ImportedChannels: Integer;
begin
  if Length(FStreams) > 0 then Result := FStreams[0].Channels else Result := 0;
end;

function TImportMp4Command.ImportedLengthSeconds: Double;
begin
  if Length(FStreams) > 0 then Result := FStreams[0].LenSeconds else Result := 0;
end;

function TImportMp4Command.ImportedCodecName: string;
begin
  if Length(FStreams) > 0 then Result := FStreams[0].CodecName else Result := '';
end;

function TImportMp4Command.DoApply: Boolean;
var
  tl: TTimeline;
  beforeCount, i: Integer;
  src: TMediaSource;
  clip: TTimelineClip;
  doAny, doVideo: Boolean;
begin
  tl := FDoc.Timeline;
  doVideo := FHasVideo and (FVideoTrackId >= 0);
  doAny := doVideo;
  for i := 0 to High(FStreams) do
    if FStreams[i].TrackId >= 0 then
    begin
      doAny := True;
      if tl.TrackById(FStreams[i].TrackId) = nil then
        RaiseUDAWFmt(errInvalidArgument, IMP_SUBSYS, 'no timeline track with id %d',
          [FStreams[i].TrackId]);
    end;
  if not doAny then
    RaiseUDAWFmt(errInvalidArgument, IMP_SUBSYS,
      'nothing to import from %s (no track chosen for its streams)', [FPath]);
  if doVideo and (tl.TrackById(FVideoTrackId) = nil) then
    RaiseUDAWFmt(errInvalidArgument, IMP_SUBSYS, 'no timeline track with id %d', [FVideoTrackId]);

  { sound: each stream's cached WAV is the source, never the container }
  for i := 0 to High(FStreams) do
  begin
    if FStreams[i].TrackId < 0 then Continue;
    if not FileExists(FStreams[i].CachePath) then
      RaiseUDAWFmt(errFileNotFound, IMP_SUBSYS,
        'the decoded sound cache %s is gone - import the file again', [FStreams[i].CachePath]);
    beforeCount := tl.SourceCount;
    if (FStreams[i].SourceId >= 0) and (tl.SourceById(FStreams[i].SourceId) <> nil) then
      src := tl.SourceById(FStreams[i].SourceId)
    else if FStreams[i].SourceId >= 0 then
      src := tl.AddSourceWithId(FStreams[i].SourceId, FStreams[i].CachePath,
        FStreams[i].SampleRate, FStreams[i].Channels, FStreams[i].FrameCount)
    else
      src := tl.AddSource(FStreams[i].CachePath, FStreams[i].SampleRate,
        FStreams[i].Channels, FStreams[i].FrameCount);
    FStreams[i].SourceId := src.Id;
    FStreams[i].SourceCreated := tl.SourceCount > beforeCount;

    if FStreams[i].ClipId >= 0 then
      clip := tl.AddClipWithId(FStreams[i].ClipId, FStreams[i].TrackId, src.Id,
        FStreams[i].ClipName, FStartSeconds, 0, FStreams[i].LenSeconds)
    else
      clip := tl.AddClip(FStreams[i].TrackId, src.Id, FStreams[i].ClipName,
        FStartSeconds, 0, FStreams[i].LenSeconds);
    FStreams[i].ClipId := clip.Id;
  end;

  if doVideo then
  begin
    { A video source records its length in milliseconds (rate 1000, 1 channel),
      the same convention the Luma import uses; it is never de-duplicated. }
    beforeCount := tl.SourceCount;
    if (FVideoSourceId >= 0) and (tl.SourceById(FVideoSourceId) <> nil) then
      src := tl.SourceById(FVideoSourceId)
    else if FVideoSourceId >= 0 then
      src := tl.AddSourceWithId(FVideoSourceId, FPath, 1000, 1,
        Round(FVideoLenSeconds * 1000), mkVideoFile)
    else
      src := tl.AddSource(FPath, 1000, 1, Round(FVideoLenSeconds * 1000), mkVideoFile);
    FVideoSourceId := src.Id;
    FVideoSourceCreated := tl.SourceCount > beforeCount;

    if FVideoClipId >= 0 then
      clip := tl.AddClipWithId(FVideoClipId, FVideoTrackId, FVideoSourceId, FClipName,
        FStartSeconds, 0, FVideoLenSeconds)
    else
      clip := tl.AddClip(FVideoTrackId, FVideoSourceId, FClipName, FStartSeconds, 0,
        FVideoLenSeconds);
    FVideoClipId := clip.Id;
  end;

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
  i: Integer;
  anyUnused: Boolean;
begin
  tl := FDoc.Timeline;
  for i := 0 to High(FStreams) do
    if (FStreams[i].ClipId >= 0) and (tl.ClipById(FStreams[i].ClipId) <> nil) then
      tl.RemoveClip(FStreams[i].ClipId);
  if (FVideoClipId >= 0) and (tl.ClipById(FVideoClipId) <> nil) then
    tl.RemoveClip(FVideoClipId);
  anyUnused := FVideoSourceCreated and (FVideoSourceId >= 0) and
    (tl.SourceUseCount(FVideoSourceId) = 0);
  for i := 0 to High(FStreams) do
    if FStreams[i].SourceCreated and (FStreams[i].SourceId >= 0) and
       (tl.SourceUseCount(FStreams[i].SourceId) = 0) then
      anyUnused := True;
  if anyUnused then tl.RemoveUnusedSources;
  FDoc.Touch;
end;

function TImportMp4Command.Description: string;
begin
  Result := Format('Import MP4 "%s"', [ExtractFileName(FPath)]);
end;

end.
