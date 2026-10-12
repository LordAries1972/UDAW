unit UDAW.Timeline.Export;
{$I udaw.inc}
{$POINTERMATH ON}

interface

uses SysUtils, Classes, Math, UDAW.Jobs, UDAW.Project.Document;

type
  TTimelineExportJob = class(TJob)
  private
    FProject: TProjectDocument;
    FFileName: string;
    FRangeStart, FRangeEnd: Double;   // FRangeEnd <= FRangeStart = whole timeline
  protected
    function Execute: Boolean; override;
  public
    constructor Create(AProject: TProjectDocument; const AFileName: string); overload;
    { Export only [ARangeStart, ARangeEnd] seconds of the mix (the Timeline range selection). }
    constructor Create(AProject: TProjectDocument; const AFileName: string;
      ARangeStart, ARangeEnd: Double); overload;
    destructor Destroy; override;
  end;

implementation

uses UDAW.Errors, UDAW.Timeline.Model, UDAW.Audio.Types, UDAW.Audio.Buffer,
  UDAW.Timeline.Playback, UDAW.Mixer.Engine, UDAW.Codec.WAV,
  UDAW.Codec.MP3, UDAW.Codec.MP3.Metadata, UDAW.Codec.MP3.Frame, UDAW.Codec.MP4, UDAW.Codec.MP4.Container,
  UDAW.Codec.FLAC.Encoder, UDAW.DSP.Dither,
  UDAW.Media.Attribution, UDAW.Media.Progress, UDAW.Media.Transcode
  {$IF DEFINED(UDAW_WINDOWS) AND NOT DEFINED(FPC)}
  , UDAW.Timeline.VideoExport, UDAW.Codec.MKV.Writer
  {$IFEND}
  {$IFDEF UDAW_WINDOWS}
  , Winapi.Windows
  {$ENDIF};

{ True when an un-muted video clip with a video source touches
  [AStart, AStart + ADuration). Kept here (not in the Windows-only video
  unit) so every build refuses a video timeline instead of silently
  dropping the picture. }
function HasVideoInRange(ATl: TTimeline; AStart, ADuration: Double): Boolean;
var
  i, j: Integer;
  trk: TTimelineTrack;
  clip: TTimelineClip;
  src: TMediaSource;
begin
  Result := False;
  for i := 0 to ATl.TrackCount - 1 do
  begin
    trk := ATl.GetTrack(i);
    if (trk.Kind <> tkVideo) or trk.Muted then Continue;
    for j := 0 to trk.ClipCount - 1 do
    begin
      clip := trk.GetClip(j);
      if clip.Muted or clip.IsMidiClip then Continue;
      src := ATl.SourceById(clip.SourceId);
      if (src = nil) or (src.Kind <> mkVideoFile) then Continue;
      if (ADuration > 0) and ((clip.EndSeconds <= AStart) or (clip.StartSeconds >= AStart + ADuration)) then
        Continue;
      Exit(True);
    end;
  end;
end;

constructor TTimelineExportJob.Create(AProject: TProjectDocument; const AFileName: string);
var
  i: Integer;
begin
  inherited Create('Export timeline: ' + ExtractFileName(AFileName));
  FFileName := ExpandFileName(AFileName);
  for i := 0 to AProject.Timeline.SourceCount - 1 do
    if SameFileName(FFileName, ExpandFileName(AProject.Timeline.GetSource(i).Path)) then
      RaiseUDAW(errInvalidArgument, 'Timeline.Export', 'Choose a destination other than a source media file.');
  FProject := AProject.Clone;
  FRangeStart := 0;
  FRangeEnd := 0;
end;

constructor TTimelineExportJob.Create(AProject: TProjectDocument; const AFileName: string;
  ARangeStart, ARangeEnd: Double);
begin
  Create(AProject, AFileName);
  FRangeStart := Max(0.0, ARangeStart);
  FRangeEnd := ARangeEnd;
end;

destructor TTimelineExportJob.Destroy;
begin
  FProject.Free;
  inherited;
end;

function TTimelineExportJob.Execute: Boolean;
const
  BLOCK = 1024;
var
  player: TTimelinePlayer;
  mixer: TMixerProcessor;
  buf: TAudioBuffer;
  writer: TWavWriter;
  stream: TFileStream;
  blockPcm: TAudioPlanar;
  dither: array[0..1] of TDitherer;
  frames, done: Int64;
  sr, n, ch, i: Integer;
  ext, temp, backup, sidecar, waveTemp, rawTemp, videoTemp: string;
  videoMode: Boolean;
  guid: TGUID;
  raw: array[0..BLOCK * 2 - 1] of SmallInt;
  info: TStringList;
  published, hadOld, hadSidecar: Boolean;
  progress: TMediaProgressScope;
  probe: TMP4ProbeInfo;
  mp3Info: TMP3StreamInfo;
  mp3Data: TBytes;
  fs: TFileStream;
  summary: string;
  unconformed: Integer;
  stampBpm: Double;
  verifyReader: TMP4Reader;
  mp4Out: string;
begin
  dither[0] := nil;
  dither[1] := nil;
  Result := False;
  summary := '';
  player := nil; mixer := nil; buf := nil; writer := nil; stream := nil;
  ext := LowerCase(ExtractFileExt(FFileName));
  if (ext <> '.wav') and (ext <> '.pcm') and (ext <> '.mp3') and
     (ext <> '.mp4') and (ext <> '.m4a') and (ext <> '.flac') and (ext <> '.mkv') then
    RaiseUDAW(errInvalidArgument, 'Timeline.Export', 'Choose WAV, PCM, MP3, MP4, M4A, FLAC or MKV.');
  { A timeline with video clips exports as a video file (MP4 / MKV); MKV is
    video-only, and a video timeline cannot go to an audio-only format. }
  videoMode := HasVideoInRange(FProject.Timeline, FRangeStart,
    IfThen(FRangeEnd > FRangeStart, FRangeEnd - FRangeStart, FProject.Timeline.TotalDurationSeconds));
  {$IF NOT (DEFINED(UDAW_WINDOWS) AND NOT DEFINED(FPC))}
  if videoMode then
    RaiseUDAW(errConfig, 'Timeline.Export',
      'This Timeline contains video, and video export (MP4 / MKV) is only available in the Windows build. ' +
      'Remove the video channel to export the audio mix.');
  {$IFEND}
  if (ext = '.mkv') and not videoMode then
    RaiseUDAW(errInvalidArgument, 'Timeline.Export', 'MKV export needs a video clip on the Timeline.');
  if videoMode and (ext <> '.mp4') and (ext <> '.mkv') then
    RaiseUDAW(errInvalidArgument, 'Timeline.Export',
      'This Timeline contains video: export it as MP4 or MKV (other formats would drop the picture).');
  sr := FProject.SampleRate;
  { Compressed exports are always rendered and encoded at 48 kHz (the standard
    MP3/AAC/video rate), regardless of the project rate. }
  if (ext = '.mp3') or (ext = '.mp4') or (ext = '.m4a') or (ext = '.mkv') then sr := 48000;
  if FRangeEnd > FRangeStart then
    frames := Ceil((FRangeEnd - FRangeStart) * sr)
  else
    frames := Ceil(FProject.Timeline.TotalDurationSeconds * sr);
  if (sr <= 0) or (frames <= 0) then
    RaiseUDAW(errInvalidArgument, 'Timeline.Export', 'The timeline has no duration to export.');
  CreateGUID(guid);
  temp := FFileName + '.' + GUIDToString(guid) + '.partial' + ext;
  backup := temp + '.previous';
  waveTemp := temp + '.wav';
  rawTemp := temp + '.pcm16';
  videoTemp := temp + '.video.mp4';
  sidecar := FFileName + '.txt';
  published := False;
  hadOld := False;
  hadSidecar := False;
  try
    ThrowIfCancelled;
    SetProgress(0.0, 'Stage 1/6: Preparing export (' + UpperCase(Copy(ext, 2, 4)) + ', ' + IntToStr(sr) + ' Hz)');
    if FRangeEnd > FRangeStart then
      FProject.Timeline.PlayheadSeconds := FRangeStart
    else
      FProject.Timeline.PlayheadSeconds := 0;
    FProject.Timeline.LoopEnabled := False;
    player := TTimelinePlayer.Create(FProject.Timeline);
    mixer := TMixerProcessor.Create(FProject.Mixer);
    player.AttachMixer(mixer, FProject.Mixer);
    { Same as live playback (StartTimelinePlayback): without this every MIDI
      clip on a tkMidi track was silently missing from the export. }
    player.AttachMidi(FProject.Midi);
    player.SetStretchTempo(FProject.TempoBPM);   // same tempo conforming as live playback
    SetProgress(0.005, 'Stage 2/6: Decoding timeline sources');
    progress := TMediaProgressScope.Create(
      procedure(Fraction: Double; const Detail: string)
      begin
        ThrowIfCancelled;
        SetProgress(Fraction * 0.1, 'Stage 2/6: Decoding sources - ' + Detail);
      end);
    try
    player.EnsureSourcesLoaded(
      procedure(Fraction: Double)
      begin
        ThrowIfCancelled;
        SetProgress(Fraction * 0.1, Format('Stage 2/6: Decoding timeline sources %.0f%%', [Fraction * 100]));
      end);
    finally progress.Free; end;
    SetProgress(0.1, 'Stage 3/6: Validating sources and preparing mixer');
    player.ValidateLoadedSources;
    player.Prepare(sr, BLOCK, 2);
    if not mixer.IsPrepared then
      RaiseUDAW(errConfig, 'Timeline.Export', 'Mixer cannot render: ' + mixer.LastError);
    SetProgress(0.1, 'Stage 4/6: Rendering mix - starting');
    buf := TAudioBuffer.Create(2, BLOCK, sr);
    EnsurePlanar(blockPcm, 2, BLOCK);
    if videoMode then
      stream := TFileStream.Create(rawTemp, fmCreate)
    else if (ext = '.mp3') or (ext = '.mp4') or (ext = '.m4a') or (ext = '.flac') then
      writer := TWavWriter.Create(waveTemp, wsfPCM24, 2, sr)
    else if ext = '.wav' then writer := TWavWriter.Create(temp, wsfPCM24, 2, sr)
    else stream := TFileStream.Create(temp, fmCreate);
    { TPDF dither before quantising: 16-bit for the raw PCM path, 24-bit for
      the WAV/intermediate path (never truncate/round without it) }
    for ch := 0 to 1 do
      if stream <> nil then dither[ch] := TDitherer.Create(16, dsTPDF)
      else dither[ch] := TDitherer.Create(24, dsTPDF);
    done := 0;
    while done < frames do
    begin
      ThrowIfCancelled;
      n := Integer(Min(Int64(BLOCK), frames - done));
      buf.SetActiveFrames(n);
      player.RenderBlock(buf);
      if buf.HasNonFinite then
        RaiseUDAW(errIO, 'Timeline.Export', 'The mix produced invalid audio samples.');
      for ch := 0 to 1 do
        begin
          Move(buf.ChannelPtr(ch)^, blockPcm[ch][0], n * SizeOf(Single));
          dither[ch].Process(@blockPcm[ch][0], n, ch);
        end;
      if writer <> nil then writer.WriteFrames(blockPcm, n)
      else if stream <> nil then
      begin
        for i := 0 to n - 1 do
          for ch := 0 to 1 do
            raw[i * 2 + ch] := Round(Max(-1.0, Min(1.0, blockPcm[ch][i])) * 32767);
        stream.WriteBuffer(raw[0], n * 4);
      end;
      Inc(done, n);
      SetProgress(0.1 + 0.6 * done / frames,
        Format('Stage 4/6: Rendering mix %.0f%% (%.1f / %.1f s)',
          [100.0 * done / frames, done / sr, frames / sr]));
    end;
    { The Windows MP3 encoder emits whole 1152-sample frames only and drops the
      final partial one, which cut the end off the program (4800 samples came
      back as 4608). One frame of trailing silence guarantees every program
      sample lands in a complete frame. }
    if (writer <> nil) and (ext = '.mp3') then
      for n := 1 to 2 do
      begin
        for ch := 0 to 1 do FillChar(blockPcm[ch][0], BLOCK * SizeOf(Single), 0);
        writer.WriteFrames(blockPcm, BLOCK);
      end;
    FreeAndNil(writer);
    FreeAndNil(stream);
    FreeAndNil(dither[0]);
    FreeAndNil(dither[1]);
    ThrowIfCancelled;
    SetProgress(0.7, 'Stage 5/6: Render complete - starting ' + UpperCase(Copy(ext, 2, 4)) + ' output');
    { Clips are only time-stretched to the project tempo when they carry a
      SourceBPM (Clip Tempo...). If any sound clip has none, that audio plays
      at its own native tempo, so claiming the project BPM in a tag would be
      false. (Picture clips carry no tempo of their own and are not counted.) }
    unconformed := 0;
    for i := 0 to FProject.Timeline.TrackCount - 1 do
      if FProject.Timeline.GetTrack(i).Kind <> tkVideo then
        for n := 0 to FProject.Timeline.GetTrack(i).ClipCount - 1 do
          with FProject.Timeline.GetTrack(i).GetClip(n) do
            if (not IsMidiClip) and (SourceBPM <= 0) then Inc(unconformed);
    if unconformed = 0 then stampBpm := FProject.TempoBPM else stampBpm := 0;
    if videoMode then
    begin
      mp4Out := temp;
      if ext = '.mkv' then mp4Out := videoTemp;
      {$IF DEFINED(UDAW_WINDOWS) AND NOT DEFINED(FPC)}
      ExportTimelineVideoMp4(FProject.Timeline, rawTemp, mp4Out, sr,
        FRangeStart, frames / sr, FProject.TempoBPM,
        procedure(Fraction: Double)
        begin
          ThrowIfCancelled;
          SetProgress(0.7 + Fraction * IfThen(ext = '.mkv', 0.2, 0.28),
            Format('Stage 5/6: Encoding video %.0f%%', [Fraction * 100]));
        end);
      if ext = '.mkv' then
      begin
        SetProgress(0.9, 'Stage 5/6: Writing MKV container');
        RemuxMp4ToMkv(videoTemp, temp, stampBpm, FProject.Author,
          procedure(Fraction: Double)
          begin
            ThrowIfCancelled;
            SetProgress(0.9 + Fraction * 0.08, Format('Stage 5/6: Writing MKV container %.0f%%', [Fraction * 100]));
          end);
      end;
      SetProgress(0.98, 'Stage 5/6: Verifying video file');
      begin
        { The result must hold both a picture and a sound track of the right length. }
        verifyReader := TMP4Reader.Create(Mp4ReadMoovBox(mp4Out));
        try
          if (verifyReader.FirstVideoTrack = nil) or (verifyReader.FirstVideoTrack.Table.SampleCount = 0) then
            RaiseUDAW(errIO, 'Timeline.Export', 'The encoded file has no picture. Export aborted.');
          if (verifyReader.FirstAudioTrack = nil) or
             (Abs(verifyReader.FirstAudioTrack.DurationSeconds - frames / sr) > Max(0.5, 0.02 * frames / sr)) then
            RaiseUDAW(errIO, 'Timeline.Export', 'The encoded sound does not match the timeline length. Export aborted.');
          summary := Format('%d x %d, %d video frames, %.2f s',
            [verifyReader.FirstVideoTrack.VideoWidth, verifyReader.FirstVideoTrack.VideoHeight,
             verifyReader.FirstVideoTrack.Table.SampleCount, frames / sr]);
        finally verifyReader.Free; end;
      end;
      if ext = '.mp4' then StampMp4File(temp, stampBpm, FProject.Author);
      if unconformed = 0 then
        summary := summary + Format(', tempo %.2f BPM', [FProject.TempoBPM]);
      {$ELSE}
      RaiseUDAW(errConfig, 'Timeline.Export', 'Video export is available on Windows only.');
      {$IFEND}
    end
    else if (ext = '.mp3') or (ext = '.mp4') or (ext = '.m4a') then
    begin
      EncodeCompressedFile(waveTemp, temp, ext,
        procedure(Fraction: Double)
        begin
          ThrowIfCancelled;
          SetProgress(0.7 + Fraction * 0.28, Format('Stage 5/6: Encoding %s audio %.0f%%', [UpperCase(Copy(ext, 2, 3)), Fraction * 100]));
        end,
        stampBpm,   // only stamped when the audio really was conformed to it
        FProject.Author);
      SetProgress(0.98, 'Stage 5/6: Verifying encoded file');
      { The encoded file must last as long as the rendered mix (frames / sr).
        A mismatch means the encoder mis-stamped the rate/tempo - refuse to
        publish a wrong-speed file and say exactly what was found. }
      summary := '';
      if (ext = '.mp4') or (ext = '.m4a') then
      begin
        if Mp4ProbeFile(temp, probe) and probe.HasAudio then
        begin
          if (Abs(probe.DurationSeconds - frames / sr) > Max(0.15, 0.01 * frames / sr)) or
             (probe.SampleRate <> sr) then
            RaiseUDAW(errIO, 'Timeline.Export', Format(
              'Encoded audio is %.2f s @ %d Hz but the timeline mix is %.2f s @ %d Hz. Export aborted.',
              [probe.DurationSeconds, probe.SampleRate, frames / sr, sr]));
          if probe.DurationSeconds > 0 then
            summary := Format('%d Hz, %.3f fps (AAC frames), %.2f s',
              [probe.SampleRate, probe.SampleCount / probe.DurationSeconds, probe.DurationSeconds]);
        end;
      end
      else
      begin
        fs := TFileStream.Create(temp, fmOpenRead or fmShareDenyNone);
        try
          SetLength(mp3Data, fs.Size);
          if fs.Size > 0 then fs.ReadBuffer(mp3Data[0], fs.Size);
        finally fs.Free; end;
        if ScanMp3Stream(mp3Data, mp3Info) and (mp3Info.DurationSeconds > 0) then
        begin
          if (Abs(mp3Info.DurationSeconds - frames / sr) > Max(0.15, 0.01 * frames / sr)) or
             (mp3Info.SampleRate <> sr) then
            RaiseUDAW(errIO, 'Timeline.Export', Format(
              'Encoded audio is %.2f s @ %d Hz but the timeline mix is %.2f s @ %d Hz. Export aborted.',
              [mp3Info.DurationSeconds, mp3Info.SampleRate, frames / sr, sr]));
          summary := Format('%d Hz, %.3f fps (MP3 frames), %.2f s',
            [mp3Info.SampleRate, mp3Info.FrameCount / mp3Info.DurationSeconds, mp3Info.DurationSeconds]);
        end;
      end;
      if summary <> '' then
      begin
        if unconformed = 0 then
          summary := summary + Format(', tempo %.2f BPM', [FProject.TempoBPM])
        else
          summary := summary + Format(', tempo NOT conformed: %d clip(s) have no source BPM ' +
            '(set Clip Tempo...) so they keep their own tempo, not %.2f', [unconformed, FProject.TempoBPM]);
      end;
    end
    else if ext = '.flac' then
    begin
      FlacEncodeFile(waveTemp, temp,
        procedure(Fraction: Double)
        begin
          ThrowIfCancelled;
          SetProgress(0.7 + Fraction * 0.28, Format('Stage 5/6: Encoding FLAC audio %.0f%%', [Fraction * 100]));
        end);
    end;
    ThrowIfCancelled;
    if ext = '.pcm' then
    begin
      info := TStringList.Create;
      try
        info.Add(UDAW_MEDIA_COPYRIGHT);
        info.Add(Format('Signed 16-bit little-endian PCM; stereo interleaved; %d Hz; %d frames', [sr, frames]));
        info.SaveToFile(temp + '.txt', TEncoding.UTF8);
      finally
        info.Free;
      end;
    end;
    SetProgress(0.99, 'Stage 6/6: Saving completed export to destination');
    if (ext = '.pcm') and FileExists(sidecar) then
    begin
      if not RenameFile(sidecar, backup + '.txt') then
        RaiseUDAW(errIO, 'Timeline.Export', 'Cannot replace PCM metadata.');
      hadSidecar := True;
    end;
    if FileExists(FFileName) then
    begin
      if not RenameFile(FFileName, backup) then
        RaiseUDAW(errIO, 'Timeline.Export', 'Cannot replace destination file.');
      hadOld := True;
    end;
    if not RenameFile(temp, FFileName) then
      RaiseUDAW(errIO, 'Timeline.Export', 'Cannot publish the completed export.');
    published := True;
    if (ext = '.pcm') and not RenameFile(temp + '.txt', sidecar) then
      RaiseUDAW(errIO, 'Timeline.Export', 'Cannot publish PCM metadata.');
    Result := True;
    if summary <> '' then
      SetProgress(1, 'Saved ' + FFileName + ' [' + summary + ']')
    else
      SetProgress(1, 'Saved ' + FFileName);
  finally
    dither[0].Free;
    dither[1].Free;
    writer.Free;
    stream.Free;
    buf.Free;
    player.Free;
    mixer.Free;
    if not Result then
    begin
      if published then SysUtils.DeleteFile(FFileName);
      if hadOld and not RenameFile(backup, FFileName) then
        RaiseUDAW(errIO, 'Timeline.Export', 'Previous output retained at ' + backup);
      if hadSidecar and not RenameFile(backup + '.txt', sidecar) then
        RaiseUDAW(errIO, 'Timeline.Export', 'Previous metadata retained at ' + backup + '.txt');
    end
    else
    begin
      if hadOld then SysUtils.DeleteFile(backup);
      if hadSidecar then SysUtils.DeleteFile(backup + '.txt');
    end;
    SysUtils.DeleteFile(temp + '.tagged');
    SysUtils.DeleteFile(waveTemp);
    SysUtils.DeleteFile(rawTemp);
    SysUtils.DeleteFile(videoTemp);
    SysUtils.DeleteFile(temp);
    SysUtils.DeleteFile(temp + '.txt');
  end;
end;

end.
