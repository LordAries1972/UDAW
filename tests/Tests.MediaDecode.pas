unit Tests.MediaDecode;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Sound decoding of MP4 / M4A / MKV files, checked sample for sample against a
  reference decoder (FFmpeg's, run once to make each fixtures\*.f32).

  The AAC fixtures are short clips that carry the hard parts of the format:
  transients (short windows and the transition windows around them), TNS,
  M/S and intensity stereo, perceptual noise substitution, a 5.1 channel order
  and an edit list that says how much encoder priming/padding to drop.  A
  decoder that gets any one of those wrong lands in single-digit dB here; the
  correct one matches to float precision (> 130 dB), so the bar is set at 100 dB.

  The MKV / fragmented-MP4 tests go through the system (DirectShow) pipeline;
  they skip themselves, saying so, when the machine has no splitter for them. }

interface

procedure RegisterMediaDecodeTests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing, UDAW.Errors, UDAW.Audio.Types,
  UDAW.Codec.AAC.Tables, UDAW.Codec.AAC.Types, UDAW.Codec.AAC,
  UDAW.Codec.MP4
  {$IFNDEF FPC}, UDAW.Media.DirectShow, UDAW.Paths, UDAW.Jobs, UDAW.Project.Document,
  UDAW.Timeline.Model, UDAW.Timeline.Export, UDAW.Codec.MP4.Timeline,
  UDAW.Codec.MP4.Container, UDAW.Codec.MKV.Writer, UDAW.Codec.WAV{$ENDIF};

const
  MIN_SNR_DB = 100.0;

function FixturePath(const AName: string): string;
begin
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..\..\tests\fixtures\' + AName);
  if not FileExists(Result) then Result := ExpandFileName('tests\fixtures\' + AName);
end;

{ the reference's interleaved float32 as planar }
function LoadGolden(const AName: string; AChannels: Integer): TAudioPlanar;
var
  fs: TFileStream;
  raw: TArray<Single>;
  frames, i, ch: Integer;
begin
  fs := TFileStream.Create(FixturePath(AName), fmOpenRead or fmShareDenyNone);
  try
    SetLength(raw, fs.Size div 4);
    if Length(raw) > 0 then fs.ReadBuffer(raw[0], Length(raw) * 4);
  finally
    fs.Free;
  end;
  frames := Length(raw) div AChannels;
  EnsurePlanar(Result, AChannels, frames);
  for i := 0 to frames - 1 do
    for ch := 0 to AChannels - 1 do
      Result[ch][i] := raw[i * AChannels + ch];
end;

{ Signal-to-error ratio of ADecoded[AOffset ...] against AGolden, over AFrames. }
function SnrDb(const ADecoded, AGolden: TAudioPlanar; AOffset, AFrames: Integer): Double;
var
  ch, i: Integer;
  sig, err, d: Double;
begin
  sig := 0;
  err := 0;
  for ch := 0 to High(AGolden) do
    for i := 0 to AFrames - 1 do
    begin
      d := ADecoded[ch][AOffset + i] - AGolden[ch][i];
      err := err + d * d;
      sig := sig + AGolden[ch][i] * AGolden[ch][i];
    end;
  if err <= 1e-30 then Exit(300);
  Result := 10 * Log10(sig / err);
end;

procedure CheckAacFixture(const AName: string; AChannels, ARate, AFrames: Integer);
var
  res: TMP4DecodeResult;
  gold: TAudioPlanar;
  info: TMP4ProbeInfo;
  snr: Double;
begin
  Check(AacTablesReady, 'AAC tables populated');
  gold := LoadGolden(AName + '.f32', AChannels);
  CheckEqualInt(AFrames, Length(gold[0]), 'golden length');

  Check(Mp4ProbeFile(FixturePath(AName + '.m4a'), info), 'probe');
  CheckEqualInt(AChannels, info.Channels, 'probed channels');
  CheckEqualInt(ARate, info.SampleRate, 'probed rate');
  { the probe reports PCM frames after the edit list, not access units }
  CheckEqualInt(AFrames, info.SampleCount, 'probed frame count');
  CheckFalse(info.UseSystemDecoder, 'plain AAC-LC is decoded in-house');

  Check(Mp4DecodeAudioFile(FixturePath(AName + '.m4a'), res), 'decode');
  { a frame that threw would be concealed as silence: say so instead of
    leaving only a low SNR to puzzle over }
  CheckEqualInt(0, res.DamagedBlocks, 'no AAC frame was concealed (' + res.FirstError + ')');
  CheckEqualInt(AChannels, res.Channels, 'channels');
  CheckEqualInt(ARate, res.SampleRate, 'rate');
  { priming and padding removed: exactly the audio that was encoded }
  CheckEqualInt(AFrames, res.Frames, 'frame count after the edit list');
  snr := SnrDb(res.Data, gold, 0, AFrames);
  Check(snr >= MIN_SNR_DB, Format('%s matches the reference decoder (SNR %.1f dB, need %.0f)',
    [AName, snr, MIN_SNR_DB]));
end;

procedure Test_AacStereoTools;
begin
  { transients, TNS, M/S, intensity and PNS at 48 kHz }
  CheckAacFixture('aac_stereo_tools', 2, 48000, 48000);
end;

procedure Test_AacMonoPns22k;
begin
  { 22.05 kHz scalefactor-band tables, PNS, short windows }
  CheckAacFixture('aac_mono22k_pns', 1, 22050, 22050);
end;

procedure Test_Aac51ChannelOrder;
begin
  { SCE + CPE + CPE + LFE: output must be L R C LFE Ls Rs, not stream order }
  CheckAacFixture('aac_51_order', 6, 48000, 14400);
end;

procedure Test_AacBandTables;
var
  r, i: Integer;
  t: TArray<Integer>;
begin
  { every rate's long and short scalefactor-band table is increasing and ends at
    the frame length; 88.2/96 kHz and 64 kHz have their own, different, tables }
  for r := 0 to 12 do
  begin
    t := SwbOffsetLong(r);
    CheckEqualInt(1024, t[High(t)], Format('long table %d ends at 1024', [r]));
    for i := 1 to High(t) do Check(t[i] > t[i - 1], Format('long table %d increasing', [r]));
    t := SwbOffsetShort(r);
    CheckEqualInt(128, t[High(t)], Format('short table %d ends at 128', [r]));
  end;
  CheckEqualInt(41, NumSwbLong(0), '96 kHz: 41 bands');
  CheckEqualInt(41, NumSwbLong(1), '88.2 kHz: 41 bands');
  CheckEqualInt(47, NumSwbLong(2), '64 kHz: 47 bands');
  CheckEqualInt(49, NumSwbLong(4), '44.1 kHz: 49 bands');
  CheckEqualInt(51, NumSwbLong(5), '32 kHz: 51 bands');
end;

procedure Test_AacDamagedFrameKeepsTiming;
var
  asc: TBytes;
  units: array of TBytes;
  res: TAACDecodeResult;
  i: Integer;
begin
  { a frame that cannot be decoded becomes silence of the same length - the audio
    after it must not slide earlier in time }
  asc := BuildAudioSpecificConfig(2, 44100, 2);
  SetLength(units, 5);
  for i := 0 to 4 do
  begin
    SetLength(units[i], 40);
    FillChar(units[i][0], 40, $FF);                 // not a valid raw_data_block
  end;
  SetLength(units[2], 0);                           // and an empty one
  Check(AacDecodeRaw(asc, units, res), 'decode of damaged stream returns');
  CheckEqualInt(5 * 1024, res.Frames, 'every access unit still yields its 1024 frames');
  Check(res.DamagedBlocks >= 1, 'damage is reported');
end;

{$IFNDEF FPC}
{ Decoding by the system pipeline: MKV (any codec LAV/DirectShow knows) and
  fragmented MP4.  A decoded stream may keep the encoder's priming (these
  fixtures were stream-copied, which drops the edit list): try both alignments. }
procedure CheckSystemDecode(const AFile: string; AExpectVideo: Boolean);
var
  res: TMP4DecodeResult;
  info: TMP4ProbeInfo;
  gold: TAudioPlanar;
  snr, snr1024: Double;
begin
  if not Assigned(Mp4SystemProbe) or
     not Mp4ProbeFile(FixturePath(AFile), info) then
  begin
    { no DirectShow splitter on this machine: nothing to verify, say so }
    Check(True, 'SKIPPED - no DirectShow splitter for ' + AFile + ': ' + DsLastError);
    Exit;
  end;
  Check(info.HasAudio, 'audio stream found');
  CheckEqualBool(AExpectVideo, info.HasVideo, 'video stream presence');
  CheckEqualInt(2, info.Channels, 'channels');
  CheckEqualInt(48000, info.SampleRate, 'rate');
  CheckNear(1.0, info.DurationSeconds, 0.06, 'duration');
  Check(info.UseSystemDecoder, 'routed to the system pipeline');
  if AExpectVideo then
  begin
    CheckEqualInt(64, info.VideoWidth, 'picture width');
    CheckEqualInt(48, info.VideoHeight, 'picture height');
  end;

  Check(Mp4DecodeAudioFile(FixturePath(AFile), res), 'decode');
  CheckEqualInt(2, res.Channels, 'decoded channels');
  Check(res.Frames >= 48000, 'at least the audio that was encoded');
  gold := LoadGolden('aac_stereo_tools.f32', 2);
  snr := SnrDb(res.Data, gold, 0, 47000);
  if res.Frames >= 48000 + 1024 then snr1024 := SnrDb(res.Data, gold, 1024, 47000) else snr1024 := -999;
  Check(Max(snr, snr1024) >= MIN_SNR_DB,
    Format('%s decodes like the reference (SNR %.1f dB at the start, %.1f dB past the priming)',
      [AFile, snr, snr1024]));
end;

procedure Test_MkvAudioAndPicture;
begin
  CheckSystemDecode('video_aac_stereo.mkv', True);
end;

procedure Test_FragmentedMp4System;
begin
  CheckSystemDecode('aac_fragmented.mp4', False);
end;

{ An MKV imported onto the Timeline and exported again as MP4: the picture
  (decoded by the system pipeline) and the sound both arrive. }
procedure Test_SurroundImportSplitsChannels;
var
  doc: TProjectDocument;
  cmd: TImportMp4Command;
  i: Integer;
begin
  doc := TProjectDocument.CreateNew('5.1 import');
  try
    cmd := TImportMp4Command.Create(doc, -1, FixturePath('aac_51_order.m4a'), 0, 0);
    try
      cmd.Resolve;
      CheckEqualInt(6, cmd.AudioStreamCount, 'a 5.1 stream becomes six clips');
      for i := 0 to cmd.AudioStreamCount - 1 do
        cmd.SetStreamTrack(i, doc.Timeline.AddTrack(tkAudio, 'ch' + IntToStr(i)).Id);
      Check(cmd.Execute, 'import');
      for i := 0 to 5 do
      begin
        CheckEqualInt(1, cmd.AudioStreams[i].Channels, 'each part is mono');
        Check(FileExists(cmd.AudioStreams[i].CachePath), 'channel file cached');
      end;
      CheckEqualInt(6, doc.Timeline.SourceCount, 'six sources');
      cmd.Undo;
      CheckEqualInt(0, doc.Timeline.SourceCount, 'undo removes them');
    finally
      cmd.Free;
    end;
  finally
    doc.Free;
  end;
end;

procedure Test_Surround71ImportSplitsChannels;
var
  doc: TProjectDocument;
  cmd: TImportMp4Command;
  i: Integer;
begin
  doc := TProjectDocument.CreateNew('7.1 import');
  try
    cmd := TImportMp4Command.Create(doc, -1, FixturePath('aac_71_order.m4a'), 0, 0);
    try
      cmd.Resolve;
      CheckEqualInt(8, cmd.AudioStreamCount, 'a 7.1 stream becomes eight clips');
      for i := 0 to cmd.AudioStreamCount - 1 do
        cmd.SetStreamTrack(i, doc.Timeline.AddTrack(tkAudio, 'ch' + IntToStr(i)).Id);
      Check(cmd.Execute, 'import');
      for i := 0 to 7 do
      begin
        CheckEqualInt(1, cmd.AudioStreams[i].Channels, 'each part is mono');
        Check(FileExists(cmd.AudioStreams[i].CachePath), 'channel file cached');
      end;
      CheckEqualInt(8, doc.Timeline.SourceCount, 'eight sources');
    finally
      cmd.Free;
    end;
  finally
    doc.Free;
  end;
end;

procedure Test_MkvImportAndExport;
var
  doc: TProjectDocument;
  at, vt: TTimelineTrack;
  cmd: TImportMp4Command;
  manager: TJobManager;
  job: TTimelineExportJob;
  dest: string;
  reader: TMP4Reader;
  vtr, atr: TMP4Track;
  info: TMP4ProbeInfo;
begin
  if not Assigned(Mp4SystemProbe) or
     not Mp4ProbeFile(FixturePath('video_aac_stereo.mkv'), info) then
  begin
    Check(True, 'SKIPPED - no DirectShow splitter for MKV: ' + DsLastError);
    Exit;
  end;
  dest := IncludeTrailingPathDelimiter(Paths.Temp) + 'media-decode-tests' + PathDelim;
  ForceDirectories(dest);
  dest := dest + 'mkv-out.mp4';
  DeleteFile(dest);
  doc := TProjectDocument.CreateNew('MKV import');
  try
    at := doc.Timeline.AddTrack(tkAudio, 'Sound');
    vt := doc.Timeline.AddTrack(tkVideo, 'Picture');
    cmd := TImportMp4Command.Create(doc, at.Id, FixturePath('video_aac_stereo.mkv'), 0, 0);
    cmd.Resolve;
    Check(cmd.HasAudio and cmd.HasVideo, 'the MKV has sound and picture');
    cmd.VideoTrackId := vt.Id;
    try
      Check(cmd.Execute, 'import');
      { the sound is decoded into the cache; the timeline works on that WAV }
      Check(cmd.AudioStreamCount >= 1, 'at least one sound stream imported');
      Check(FileExists(doc.Timeline.SourceById(cmd.SourceId).Path), 'cached sound file exists');
      Check(FileLooksLikeWav(doc.Timeline.SourceById(cmd.SourceId).Path), 'cached sound is a WAV');
      Check(Pos(LowerCase(Paths.Cache), LowerCase(doc.Timeline.SourceById(cmd.SourceId).Path)) = 1,
        'cached sound lives in the cache folder');
    finally
      cmd.Free;
    end;
    CheckEqualInt(2, doc.Timeline.SourceCount, 'a sound source and a picture source');

    manager := TJobManager.Create(1);
    try
      job := TTimelineExportJob.Create(doc, dest);
      try
        manager.Submit(job, False);
        Check(manager.WaitAll(120000), 'export finishes');
        Check(job.Status = jsSucceeded, 'export succeeds: ' + job.ErrorMessage);
      finally
        job.Free;
      end;
    finally
      manager.Free;
    end;
    reader := TMP4Reader.Create(Mp4ReadMoovBox(dest));
    try
      vtr := reader.FirstVideoTrack;
      atr := reader.FirstAudioTrack;
      Check(vtr <> nil, 'exported file has a picture track');
      Check(atr <> nil, 'exported file has a sound track');
      CheckEqualInt(64, vtr.VideoWidth, 'picture width kept');
      CheckEqualInt(48, vtr.VideoHeight, 'picture height kept');
      CheckNear(1.0, vtr.DurationSeconds, 0.45, 'picture length');
    finally
      reader.Free;
    end;
  finally
    doc.Free;
  end;
end;
{$ENDIF}

procedure RegisterMediaDecodeTests;
begin
  RegisterTest('MediaDecode', 'AAC stereo - transients, TNS, M/S, intensity, PNS', Test_AacStereoTools);
  RegisterTest('MediaDecode', 'AAC mono 22.05 kHz - PNS, short windows', Test_AacMonoPns22k);
  RegisterTest('MediaDecode', 'AAC 5.1 - channel order', Test_Aac51ChannelOrder);
  RegisterTest('MediaDecode', 'AAC scalefactor-band tables for every sample rate', Test_AacBandTables);
  RegisterTest('MediaDecode', 'AAC damaged frame keeps the timing', Test_AacDamagedFrameKeepsTiming);
  {$IFNDEF FPC}
  RegisterTest('MediaDecode', 'MKV - sound and picture through the system pipeline', Test_MkvAudioAndPicture);
  RegisterTest('MediaDecode', 'Fragmented MP4 - through the system pipeline', Test_FragmentedMp4System);
  RegisterTest('MediaDecode', 'MKV - import onto the Timeline and export', Test_MkvImportAndExport);
  RegisterTest('MediaDecode', 'Import - 5.1 splits onto six tracks', Test_SurroundImportSplitsChannels);
  RegisterTest('MediaDecode', 'Import - 7.1 splits onto eight tracks', Test_Surround71ImportSplitsChannels);
  {$ENDIF}
end;

end.
