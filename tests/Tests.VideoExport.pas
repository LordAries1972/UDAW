unit Tests.VideoExport;
{ Video export (MP4 / MKV) of a Timeline that holds a video channel. Windows
  only: the picture is decoded and encoded by Windows Media Foundation. }
interface
procedure RegisterVideoExportTests;
implementation
uses SysUtils, Classes, Math, UDAW.Testing, UDAW.Paths, UDAW.Jobs,
  UDAW.Audio.Types, UDAW.Project.Document, UDAW.Timeline.Model,
  UDAW.Mixer.Model, UDAW.Timeline.Export, UDAW.Codec.WAV,
  UDAW.Codec.MP4.Atoms, UDAW.Codec.MP4.Container, UDAW.Codec.MKV.Writer,
  UDAW.Timeline.VideoExport, UDAW.Timeline.VideoFxCache;

const
  FIXTURE = 'fixtures\video_testsrc.mp4';

function FixturePath: string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\tests\' + FIXTURE);
  if not FileExists(Result) then Result := ExpandFileName('tests\' + FIXTURE);
end;

function ReadBytes(const Name: string): TBytes;
var f: TFileStream;
begin
  f := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, f.Size);
    if f.Size > 0 then f.ReadBuffer(Result[0], Length(Result));
  finally f.Free; end;
end;

function Contains(const AData: TBytes; const AText: AnsiString): Boolean;
var i, j: Integer;
begin
  Result := False;
  for i := 0 to Length(AData) - Length(AText) do
  begin
    j := 1;
    while (j <= Length(AText)) and (AData[i + j - 1] = Byte(AText[j])) do Inc(j);
    if j > Length(AText) then Exit(True);
  end;
end;

{ A project with a 2 s video clip and a 2 s tone on an audio track. }
function MakeProject(const AFolder: string): TProjectDocument;
var
  pcm: TAudioPlanar;
  i: Integer;
  vsrc, asrc: TMediaSource;
  vt, at: TTimelineTrack;
begin
  EnsurePlanar(pcm, 2, 96000);
  for i := 0 to 95999 do
  begin
    pcm[0][i] := 0.3 * Sin(2 * Pi * 440 * i / 48000);
    pcm[1][i] := pcm[0][i];
  end;
  SaveWavFile(AFolder + 'tone.wav', pcm, 2, 48000, 96000);
  Result := TProjectDocument.CreateNew('Video export regression');
  Result.Author := 'Test Author';
  vsrc := Result.Timeline.AddSource(FixturePath, 1000, 1, 2000, mkVideoFile);
  asrc := Result.Timeline.AddSource(AFolder + 'tone.wav', 48000, 2, 96000);
  vt := Result.Timeline.AddTrack(tkVideo, 'Picture');
  at := Result.Timeline.AddTrack(tkAudio, 'Tone');
  Result.Timeline.AddClip(vt.Id, vsrc.Id, 'Picture', 0, 0, 2);
  { sound already at the project tempo: the file may then claim that tempo }
  Result.Timeline.AddClip(at.Id, asrc.Id, 'Tone', 0, 0, 2).SourceBPM := Result.TempoBPM;
end;

procedure ExportJobTo(ADoc: TProjectDocument; const ADest: string; AExpectOk: Boolean;
  out AMessage: string);
var
  manager: TJobManager;
  job: TTimelineExportJob;
begin
  manager := TJobManager.Create(1);
  try
    job := nil;
    try
      job := TTimelineExportJob.Create(ADoc, ADest);
      manager.Submit(job, False);
      Check(manager.WaitAll(120000), 'export finishes');
      if AExpectOk then Check(job.Status = jsSucceeded, job.ErrorMessage)
      else Check(job.Status = jsFailed, 'export is refused');
      AMessage := job.ErrorMessage;
    finally job.Free; end;
  finally manager.Free; end;
end;

procedure VideoExportFormats;
var
  doc: TProjectDocument;
  folder, dest, msg: string;
  reader: TMP4Reader;
  data: TBytes;
  vt, at: TMP4Track;
begin
  if not FileExists(FixturePath) then Fail('missing fixture ' + FixturePath);
  folder := IncludeTrailingPathDelimiter(Paths.Temp) + 'video-export-tests' + PathDelim;
  ForceDirectories(folder);
  doc := MakeProject(folder);
  try
    { ---- MP4: picture + sound, tagged ---- }
    dest := folder + 'out.mp4';
    DeleteFile(dest);
    ExportJobTo(doc, dest, True, msg);
    reader := TMP4Reader.Create(Mp4ReadMoovBox(dest));
    try
      vt := reader.FirstVideoTrack;
      at := reader.FirstAudioTrack;
      Check(vt <> nil, 'MP4 has a picture track');
      Check(at <> nil, 'MP4 has a sound track');
      CheckEqualInt(160, vt.VideoWidth, 'picture width');
      CheckEqualInt(90, vt.VideoHeight, 'picture height');
      CheckEqualInt(50, vt.Table.SampleCount, '2 s at 25 fps');
      CheckNear(2.0, at.DurationSeconds, 0.1, 'sound lasts as long as the picture');
      Check(Contains(ReadBytes(dest), 'tmpo'), 'tempo tag on a video export');
      Check(reader.Tree.Root.Path('moov/udta/cprt') <> nil, 'copyright atom on a video export');
    finally reader.Free; end;

    { ---- MKV: same content in a Matroska container ---- }
    dest := folder + 'out.mkv';
    DeleteFile(dest);
    ExportJobTo(doc, dest, True, msg);
    data := ReadBytes(dest);
    Check((Length(data) > 100) and (data[0] = $1A) and (data[1] = $45) and (data[2] = $DF) and (data[3] = $A3),
      'MKV starts with the EBML header');
    Check(Contains(data, 'V_MPEG4/ISO/AVC'), 'MKV carries H.264');
    Check(Contains(data, 'A_AAC'), 'MKV carries AAC');
    Check(Contains(data, 'matroska'), 'MKV doc type');
    Check(Contains(data, 'Test Author'), 'MKV author tag');

    { ---- audio-only formats ignore the picture and export the sound ---- }
    DeleteFile(folder + 'out.wav');
    ExportJobTo(doc, folder + 'out.wav', True, msg);
    Check(FileExists(folder + 'out.wav'), 'WAV export of a video timeline renders the audio: ' + msg);
  finally doc.Free; end;
end;

procedure VideoExportRefusals;
var
  doc: TProjectDocument;
  folder, msg: string;
  i: Integer;
begin
  folder := IncludeTrailingPathDelimiter(Paths.Temp) + 'video-export-tests' + PathDelim;
  ForceDirectories(folder);
  doc := MakeProject(folder);
  try
    { MKV needs video: with the picture channel muted the timeline is audio only }
    for i := 0 to doc.Timeline.TrackCount - 1 do
      if doc.Timeline.GetTrack(i).Kind = tkVideo then doc.Timeline.GetTrack(i).Muted := True;
    ExportJobTo(doc, folder + 'novideo.mkv', False, msg);
    Check(Pos('video', LowerCase(msg)) > 0, 'MKV without video says why: ' + msg);
    { ...and a muted picture channel lets the audio export proceed }
    DeleteFile(folder + 'audio.wav');
    ExportJobTo(doc, folder + 'audio.wav', True, msg);
    Check(FileExists(folder + 'audio.wav'), 'audio export with muted video');
  finally doc.Free; end;
end;

{ Mean byte value of a 24-bit BMP's pixel data. }
function MeanOfBmp(const APath: string): Double;
var
  d: TBytes;
  i: Integer;
  sum: Int64;
begin
  d := ReadBytes(APath);
  sum := 0;
  for i := 54 to High(d) do sum := sum + d[i];
  Result := sum / Max(1, Length(d) - 54);
end;

{ The effects are really in the exported picture: an Invert effect turns the
  mean level into its complement, and a Dip to Black turns the middle of the
  transition black. Compared against the same export without effects. }
procedure VideoExportRendersEffects;
var
  doc: TProjectDocument;
  folder, msg, err: string;
  trk: TTimelineTrack;
  plain, inverted, dipped: Double;
begin
  if not FileExists(FixturePath) then Fail('missing fixture ' + FixturePath);
  folder := IncludeTrailingPathDelimiter(Paths.Temp) + 'video-export-tests' + PathDelim;
  ForceDirectories(folder);
  doc := MakeProject(folder);
  try
    trk := doc.Timeline.GetTrack(0);
    DeleteFile(folder + 'plain.mp4');
    ExportJobTo(doc, folder + 'plain.mp4', True, msg);
    Check(SaveVideoFrameBmp(folder + 'plain.mp4', 0.5, folder + 'plain.bmp', err), err);
    Check(SaveVideoFrameBmp(folder + 'plain.mp4', 1.0, folder + 'plain1.bmp', err), err);
    plain := MeanOfBmp(folder + 'plain.bmp');

    doc.Timeline.AddVideoEffect(trk.Id, 'invert', 'Invert', 0, 2, 0, '');
    DeleteFile(folder + 'invert.mp4');
    ExportJobTo(doc, folder + 'invert.mp4', True, msg);
    Check(SaveVideoFrameBmp(folder + 'invert.mp4', 0.5, folder + 'invert.bmp', err), err);
    inverted := MeanOfBmp(folder + 'invert.bmp');
    CheckNear(255, plain + inverted, 20, 'Invert complements the picture level (' +
      FloatToStr(plain) + ' / ' + FloatToStr(inverted) + ')');

    doc.Timeline.RemoveVideoEffect(doc.Timeline.GetVideoEffect(0).Id);
    doc.Timeline.AddVideoEffect(trk.Id, 'dipblack', 'Dip to Black', 0.5, 1, 1, '');
    DeleteFile(folder + 'dip.mp4');
    ExportJobTo(doc, folder + 'dip.mp4', True, msg);
    Check(SaveVideoFrameBmp(folder + 'dip.mp4', 1.0, folder + 'dip.bmp', err), err);
    dipped := MeanOfBmp(folder + 'dip.bmp');
    Check(dipped < MeanOfBmp(folder + 'plain1.bmp') * 0.35, 'Dip to Black is dark in the middle (' +
      FloatToStr(dipped) + ')');
  finally doc.Free; end;
end;

{ The playback pre-render: a lean, silent copy of the picture with the effects
  baked in, found again by content hash so an unchanged video is not
  rendered twice. }
procedure VideoFxPreRenderAndCache;
var
  doc: TProjectDocument;
  folder, cacheDir, err: string;
  trk: TTimelineTrack;
  plan, plan2, plan3: TVideoFxPlan;
  reader: TMP4Reader;
  plain, fx: Double;
  t0, ms: UInt64;
  fs: TFileStream;
begin
  if not FileExists(FixturePath) then Fail('missing fixture ' + FixturePath);
  folder := IncludeTrailingPathDelimiter(Paths.Temp) + 'video-export-tests' + PathDelim;
  cacheDir := folder + 'fxcache';
  ForceDirectories(cacheDir);
  doc := MakeProject(folder);
  try
    trk := doc.Timeline.GetTrack(0);
    plan := PlanVideoFxRender(doc.Timeline, doc.TempoBPM, cacheDir);
    CheckFalse(plan.Needed, 'no effects, no pre-render');

    doc.Timeline.AddVideoEffect(trk.Id, 'invert', 'Invert', 0, 2, 0, '');
    plan := PlanVideoFxRender(doc.Timeline, doc.TempoBPM, cacheDir);
    Check(plan.Needed, 'an effect on the video needs a pre-render');
    CheckNear(2.0, plan.Duration, 1e-6, 'renders just the span that holds video');
    plan2 := PlanVideoFxRender(doc.Timeline, doc.TempoBPM, cacheDir);
    CheckEqualStr(plan.Key, plan2.Key, 'same picture, same cache name');
    doc.Timeline.GetVideoEffect(0).Params := 'amt=0.5';
    plan3 := PlanVideoFxRender(doc.Timeline, doc.TempoBPM, cacheDir);
    Check(plan3.Key <> plan.Key, 'a changed effect setting gives a new cache name');
    doc.Timeline.GetVideoEffect(0).Params := '';

    DeleteFile(plan.CachePath);
    CheckFalse(VideoFxCacheHit(plan), 'nothing cached yet');
    t0 := TThread.GetTickCount64;
    RenderTimelineVideoPreview(doc.Timeline, plan.CachePath, plan.Start, plan.Duration,
      doc.TempoBPM, 960, nil);
    ms := TThread.GetTickCount64 - t0;
    Check(FileExists(plan.CachePath), 'pre-render wrote the file');
    Check(ms < 20000, 'pre-render of 2 s is quick (' + IntToStr(ms) + ' ms)');
    reader := TMP4Reader.Create(Mp4ReadMoovBox(plan.CachePath));
    try
      Check(reader.FirstVideoTrack <> nil, 'rendered file has a picture');
      Check(reader.FirstAudioTrack = nil, 'rendered file is silent (no sound stream)');
      CheckEqualInt(160, reader.FirstVideoTrack.VideoWidth, 'picture width kept (below the cap)');
    finally reader.Free; end;

    { the effect really is in the pre-rendered picture }
    Check(SaveVideoFrameBmp(FixturePath, 0.5, folder + 'src.bmp', err), err);
    Check(SaveVideoFrameBmp(plan.CachePath, 0.5, folder + 'prer.bmp', err), err);
    plain := MeanOfBmp(folder + 'src.bmp');
    fx := MeanOfBmp(folder + 'prer.bmp');
    CheckNear(255, plain + fx, 25, 'pre-rendered picture is inverted');

    { stored file is found again; a truncated one is not trusted }
    Check(VideoFxCacheHit(plan), 'cache hit once the file exists');
    fs := TFileStream.Create(plan.CachePath + '.bad', fmCreate);
    fs.Free;
    plan3 := plan;
    plan3.CachePath := plan.CachePath + '.bad';
    CheckFalse(VideoFxCacheHit(plan3), 'an empty file is no cache hit');
    DeleteFile(plan.CachePath + '.bad');

    { audio-only edits must not change the key; a muted video channel needs nothing }
    trk.Muted := True;
    plan3 := PlanVideoFxRender(doc.Timeline, doc.TempoBPM, cacheDir);
    CheckFalse(plan3.Needed, 'muted video channel: nothing to render');
  finally doc.Free; end;
end;

procedure RegisterVideoExportTests;
begin
  RegisterTest('timeline.videoexport', 'playback pre-render is lean and cached by content', VideoFxPreRenderAndCache);
  RegisterTest('timeline.videoexport', 'effects are rendered into the exported picture', VideoExportRendersEffects);
  RegisterTest('timeline.videoexport', 'MP4 and MKV with picture, sound and tags', VideoExportFormats);
  RegisterTest('timeline.videoexport', 'refusals and muted video', VideoExportRefusals);
end;
end.
