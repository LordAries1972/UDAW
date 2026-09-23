unit Tests.TimelineExport;
interface
procedure RegisterTimelineExportTests;
implementation
uses SysUtils, Classes, Math, UDAW.Testing, UDAW.Paths, UDAW.Jobs,
  UDAW.Audio.Types, UDAW.Project.Document, UDAW.Timeline.Model,
  UDAW.Mixer.Model, UDAW.Timeline.Export, UDAW.Codec.WAV,
  UDAW.Codec.MP3, UDAW.Codec.MP4, UDAW.Codec.MP4.Atoms,
  UDAW.Media.Attribution, UDAW.Media.Progress, UDAW.Timeline.Waveform;

function ReadBytes(const Name: string): TBytes;
var f: TFileStream;
begin
  f := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, f.Size);
    if f.Size > 0 then f.ReadBuffer(Result[0], Length(Result));
  finally f.Free; end;
end;

procedure ExportFormats;
const Exts: array[0..4] of string = ('.wav', '.mp3', '.mp4', '.m4a', '.pcm');
var
  doc: TProjectDocument;
  manager: TJobManager;
  job: TTimelineExportJob;
  pcm, decoded: TAudioPlanar;
  src: TMediaSource;
  track: TTimelineTrack;
  strip: TMixStrip;
  folder, source, dest: string;
  i, k, ch, sr: Integer;
  data: TBytes;
  m3: TMP3DecodeResult;
  m4: TMP4DecodeResult;
  tree: TMP4AtomTree;
  scope: TMediaProgressScope;
  cache: TWaveformCache;
  midpoint: Boolean;
begin
  folder := IncludeTrailingPathDelimiter(Paths.Temp) + 'timeline-export-tests' + PathDelim;
  ForceDirectories(folder);
  source := folder + 'source.wav';
  EnsurePlanar(pcm, 2, 4800);
  for i := 0 to 4799 do
  begin
    pcm[0][i] := 0.4 * Sin(2 * Pi * 440 * i / 48000);
    pcm[1][i] := pcm[0][i];
  end;
  SaveWavFile(source, pcm, 2, 48000, 4800);
  doc := TProjectDocument.CreateNew('Export regression');
  manager := TJobManager.Create(1);
  try
    src := doc.Timeline.AddSource(source, 48000, 2, 4800);
    track := doc.Timeline.AddTrack(tkAudio, 'Signal');
    doc.Timeline.AddClip(track.Id, src.Id, 'Tone', 0, 0, 0.1);
    strip := doc.Mixer.AddStrip(skAudioTrack, 'Routed signal');
    strip.InputSourceId := track.Id;
    strip.OutputTargetId := doc.Mixer.MasterStrip.Id;
    strip.FaderDb := -6;
    doc.Timeline.PlayheadSeconds := 0.05;
    doc.Timeline.LoopEnabled := True;
    doc.Timeline.LoopLengthSeconds := 0.025;
    for k := 0 to High(Exts) do
    begin
      dest := folder + 'mix' + Exts[k];
      DeleteFile(dest + '.txt');
      job := TTimelineExportJob.Create(doc, dest);
      try
        manager.Submit(job, False);
        Check(manager.WaitAll(60000), 'export finishes');
        Check(job.Status = jsSucceeded, job.ErrorMessage);
        CheckNear(0.05, doc.Timeline.PlayheadSeconds, 1e-9, 'snapshot preserves playhead');
        Check(doc.Timeline.LoopEnabled, 'snapshot preserves loop');
        data := ReadBytes(dest);
        if k = 4 then
        begin
          CheckEqualInt(4800 * 4, Length(data), 'raw PCM has no metadata bytes');
          Check(Pos(UDAW_MEDIA_COPYRIGHT, TEncoding.UTF8.GetString(ReadBytes(dest + '.txt'))) > 0,
            'raw PCM companion attribution');
        end
        else
        begin
          Check(Pos(UDAW_MEDIA_COPYRIGHT, TEncoding.ANSI.GetString(data)) > 0, 'embedded attribution');
          if k = 0 then decoded := LoadWavFile(dest, ch, sr)
          else if k = 1 then
          begin
            Check(Mp3Decode(data, m3), 'MP3 decodes');
            CheckEqualStr(UDAW_MEDIA_COPYRIGHT, Mp3ReadMetadata(data).Copyright, 'TCOP copyright');
            decoded := m3.Pcm;
          end
          else
          begin
            Check(Mp4DecodeAudio(data, m4), 'MP4/M4A decodes');
            decoded := m4.Data;
            tree := TMP4AtomTree.Create(data);
            try Check(tree.Root.Path('moov/udta/cprt') <> nil, 'MP4 copyright atom');
            finally tree.Free; end;
          end;
          Check(Length(decoded[0]) >= 4800, 'whole arrangement exported despite loop');
          if k = 0 then
            CheckNear(pcm[0][4700] * Power(10, -6/20) / Sqrt(2), decoded[0][4700], 0.04,
              'mixer fader and smoothed track pan reach export');
        end;
      finally job.Free; end;
      if (k >= 1) and (k <= 3) then
      begin
        midpoint := False;
        scope := TMediaProgressScope.Create(
          procedure(Fraction: Double; const Detail: string)
          begin
            if (Fraction > 0) and (Fraction < 1) and
               (Pos('Decoding', Detail) = 1) and (Pos('elapsed', Detail) > 0) then
              midpoint := True;
          end);
        try
          cache := BuildWaveformCacheFromFile(dest);
          cache.Free;
        finally scope.Free; end;
        Check(midpoint, 'compressed import reports real decode midpoint and elapsed time');
      end;
    end;
  finally manager.Free; doc.Free; end;
end;

procedure ExportFailureAndCancellation;
var
  doc: TProjectDocument;
  manager: TJobManager;
  job: TTimelineExportJob;
  track: TTimelineTrack;
  src: TMediaSource;
  dest: string;
  sentinel: TStringList;
begin
  dest := IncludeTrailingPathDelimiter(Paths.Temp) + 'failed-export.wav';
  sentinel := TStringList.Create;
  doc := TProjectDocument.CreateNew;
  manager := TJobManager.Create(1);
  try
    sentinel.Text := 'preserve existing destination';
    sentinel.SaveToFile(dest);
    track := doc.Timeline.AddTrack(tkAudio, 'Missing');
    src := doc.Timeline.AddSource(dest + '.missing', 48000, 2, 4800);
    doc.Timeline.AddClip(track.Id, src.Id, 'Missing', 0, 0, 0.1);
    job := TTimelineExportJob.Create(doc, dest);
    try
      manager.Submit(job, False);
      Check(manager.WaitAll(10000), 'failure completes');
      Check(job.Status = jsFailed, 'missing source is a visible failure');
      Check(Pos('preserve existing destination', TEncoding.ANSI.GetString(ReadBytes(dest))) > 0,
        'failed export preserves destination');
    finally job.Free; end;
    job := TTimelineExportJob.Create(doc, dest);
    try
      job.Cancel;
      manager.Submit(job, False);
      Check(manager.WaitAll(10000), 'cancel completes');
      Check(job.Status = jsCancelled, 'job honours cancellation');
      Check(Pos('preserve existing destination', TEncoding.ANSI.GetString(ReadBytes(dest))) > 0,
        'cancel preserves destination');
    finally job.Free; end;
  finally manager.Free; doc.Free; sentinel.Free; end;
end;

procedure RegisterTimelineExportTests;
begin
  RegisterTest('timeline.export', 'five formats, mixer, snapshot and attribution', ExportFormats);
  RegisterTest('timeline.export', 'failure, cancellation and destination preservation', ExportFailureAndCancellation);
end;
end.
