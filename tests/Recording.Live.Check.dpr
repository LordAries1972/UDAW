program RecordingLiveCheck;
{$APPTYPE CONSOLE}
uses
  SysUtils, Classes,
  UDAW.Config, UDAW.Audio.Engine, UDAW.Audio.Types, UDAW.Audio.Ring,
  UDAW.Recording.Engine, UDAW.Recording.Types, UDAW.Recording.Writer,
  UDAW.Codec.WAV;
var
  cfg: TConfig;
  audio: TAudioEngine;
  rec: TRecordingEngine;
  ring: TAudioRing;
  writer: TRecordingWriterThread;
  settings: TRecordSettings;
  take: TRecordedTake;
  wav: TWavInfo;
  root: string;
begin
  cfg := nil; audio := nil; rec := nil; ring := nil; writer := nil;
  try
    root := ExpandFileName('build/recording-live-check');
    ForceDirectories(root);
    cfg := TConfig.Create(root + '/audio.ini');
    cfg.SetString(CFG_SEC_AUDIO, CFG_AUDIO_BACKEND, 'wasapi');
    cfg.SetBool(CFG_SEC_AUDIO, CFG_AUDIO_CAPTURE, True);
    cfg.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_IN_CH, 1);
    audio := TAudioEngine.Create(cfg);
    if not audio.Open(True) then raise Exception.Create('WASAPI input could not open');
    WriteLn(audio.Describe);
    if audio.Granted.CaptureChannels <= 0 then raise Exception.Create('No live input channels');
    audio.Stop;
    settings := TRecordSettings.Default;
    settings.SampleRate := audio.Granted.SampleRate;
    settings.Channels := audio.Granted.CaptureChannels;
    if settings.Channels = 1 then settings.ChannelMode := rcmMono
    else if settings.Channels = 2 then settings.ChannelMode := rcmStereo
    else settings.ChannelMode := rcmMultichannel;
    rec := TRecordingEngine.Create(root + '/takes');
    rec.Configure(settings);
    rec.Arm;
    rec.Start(7.25);
    ring := TAudioRing.Create(settings.Channels, settings.SampleRate * 4);
    writer := TRecordingWriterThread.Create(rec, ring);
    audio.SetCaptureRing(ring);
    audio.Start;
    Sleep(2200);
    audio.Stop;
    audio.SetCaptureRing(nil);
    writer.Stop;
    if writer.ErrorCount <> 0 then raise Exception.Create(writer.LastError);
    if writer.RingOverruns <> 0 then raise Exception.Create('Capture overrun');
    if rec.TakeCount <> 1 then raise Exception.Create('No completed live take');
    take := rec.LastTake;
    wav := ReadWavInfo(take.WavFile);
    if take.FrameCount <> writer.FramesConsumed then raise Exception.Create('Tail frames lost');
    if wav.FrameCount <> take.FrameCount then raise Exception.Create('WAV length mismatch');
    if wav.FrameCount < settings.SampleRate then raise Exception.Create('Less than one second captured');
    if Abs(take.TimelineStartSeconds - 7.25) > 0.00001 then raise Exception.Create('Insertion position changed');
    WriteLn('PASS: real WASAPI capture, ', wav.FrameCount, ' frames at ', wav.SampleRate,
      ' Hz; complete WAV; insertion 7.25 s; zero overruns/errors.');
  except
    on E: Exception do begin WriteLn('FAIL: ', E.Message); ExitCode := 1; end;
  end;
  if audio <> nil then begin audio.Stop; audio.SetCaptureRing(nil); end;
  writer.Free; ring.Free; rec.Free; audio.Free; cfg.Free;
end.
