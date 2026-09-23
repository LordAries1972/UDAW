unit Tests.Phase2;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 2 acceptance tests: audio types & conversion, TAudioBuffer maths,
  the SPSC audio ring, the signal generators, deterministic offline render
  (sine amplitude + frequency verification, sweep, clipping), the portable
  software backend (block delivery, timing, xrun accounting, duplex loopback,
  virtual-microphone capture), device-loss + recovery, and the TAudioEngine
  lifecycle end to end.

  Requires src/common and src/audio (and src/audio/backend) on the search path. }

interface

procedure RegisterPhase2Tests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Types, UDAW.Errors, UDAW.Threading, UDAW.Config, UDAW.Logging,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Ring, UDAW.Audio.Source,
  UDAW.Audio.Offline, UDAW.Audio.Device, UDAW.Audio.Backend.Software,
  UDAW.Audio.Backend.Factory, UDAW.Audio.Engine;

{ ---------------- helpers ---------------- }

function TempConfigPath: string;
var
  d: string;
begin
  {$IFDEF FPC}
  d := GetTempDir;
  {$ELSE}
  d := GetEnvironmentVariable('TEMP');
  if d = '' then d := GetCurrentDir;
  {$ENDIF}
  d := IncludeTrailingPathDelimiter(d) + 'udaw-p2' + PathDelim +
    FormatDateTime('yyyymmdd-hhnnsszzz', Now) + '-' + IntToStr(Random(100000)) + PathDelim;
  ForceDirectories(d);
  Result := d + 'audio.ini';
end;

{ ---------------- types / conversion ---------------- }

procedure Test_DeviceFormat_Sizes;
begin
  CheckEqualInt(2, DeviceFormatBytes(dfInt16), 'int16 bytes');
  CheckEqualInt(3, DeviceFormatBytes(dfInt24Packed), 'int24 bytes');
  CheckEqualInt(4, DeviceFormatBytes(dfInt32), 'int32 bytes');
  CheckEqualInt(4, DeviceFormatBytes(dfFloat32), 'float32 bytes');
  CheckEqualInt(8, DeviceFormatBytes(dfFloat64), 'float64 bytes');
  CheckEqualInt(2, ChannelLayoutCount(clStereo), 'stereo count');
  CheckEqualInt(6, ChannelLayoutCount(cl51), '5.1 count');
  Check(IsStandardSampleRate(48000), '48k standard');
  CheckFalse(IsStandardSampleRate(45000), '45k not standard');
  Check(ValidSampleRate(45000), '45k still valid (custom)');
end;

procedure Test_Interleave_Roundtrip_Int16;
var
  planar: TAudioPlanar;
  bytes: array of Byte;
  back: TAudioPlanar;
  i: Integer;
begin
  EnsurePlanar(planar, 2, 4);
  planar[0][0] := 0.0;   planar[1][0] := 1.0;
  planar[0][1] := -1.0;  planar[1][1] := 0.5;
  planar[0][2] := 0.25;  planar[1][2] := -0.25;
  planar[0][3] := 0.999; planar[1][3] := -0.999;

  SetLength(bytes, 4 * 2 * 2);
  EncodeInterleaved(planar, 2, 4, dfInt16, bytes[0]);
  EnsurePlanar(back, 2, 4);
  DecodeInterleaved(bytes[0], dfInt16, 2, 4, back);

  for i := 0 to 3 do
  begin
    CheckNear(planar[0][i], back[0][i], 0.001, 'L frame ' + IntToStr(i));
    CheckNear(planar[1][i], back[1][i], 0.001, 'R frame ' + IntToStr(i));
  end;
end;

procedure Test_Interleave_Roundtrip_Float32;
var
  planar, back: TAudioPlanar;
  bytes: array of Byte;
  i: Integer;
begin
  EnsurePlanar(planar, 3, 5);
  for i := 0 to 4 do
  begin
    planar[0][i] := Sin(i * 0.7);
    planar[1][i] := Cos(i * 0.9);
    planar[2][i] := (i - 2) / 4;
  end;
  SetLength(bytes, 5 * 3 * 4);
  EncodeInterleaved(planar, 3, 5, dfFloat32, bytes[0]);
  EnsurePlanar(back, 3, 5);
  DecodeInterleaved(bytes[0], dfFloat32, 3, 5, back);
  for i := 0 to 4 do
  begin
    CheckNear(planar[0][i], back[0][i], 1e-6, 'ch0 ' + IntToStr(i));
    CheckNear(planar[1][i], back[1][i], 1e-6, 'ch1 ' + IntToStr(i));
    CheckNear(planar[2][i], back[2][i], 1e-6, 'ch2 ' + IntToStr(i));
  end;
end;

procedure Test_Interleave_Int24;
var
  planar, back: TAudioPlanar;
  bytes: array of Byte;
begin
  EnsurePlanar(planar, 1, 3);
  planar[0][0] := 0.5;
  planar[0][1] := -0.75;
  planar[0][2] := 0.0;
  SetLength(bytes, 3 * 1 * 3);
  EncodeInterleaved(planar, 1, 3, dfInt24Packed, bytes[0]);
  EnsurePlanar(back, 1, 3);
  DecodeInterleaved(bytes[0], dfInt24Packed, 1, 3, back);
  CheckNear(0.5, back[0][0], 1e-4, '24-bit +0.5');
  CheckNear(-0.75, back[0][1], 1e-4, '24-bit -0.75');
  CheckNear(0.0, back[0][2], 1e-6, '24-bit 0');
end;

procedure Test_Clamp_On_Encode;
var
  planar, back: TAudioPlanar;
  bytes: array of Byte;
begin
  EnsurePlanar(planar, 1, 2);
  planar[0][0] := 3.0;    // over-range
  planar[0][1] := -3.0;
  SetLength(bytes, 2 * 4);
  EncodeInterleaved(planar, 1, 2, dfFloat32, bytes[0]);
  EnsurePlanar(back, 1, 2);
  DecodeInterleaved(bytes[0], dfFloat32, 1, 2, back);
  CheckNear(1.0, back[0][0], 1e-6, 'clamped to +1');
  CheckNear(-1.0, back[0][1], 1e-6, 'clamped to -1');
end;

{ ---------------- TAudioBuffer ---------------- }

procedure Test_Buffer_MixAndGain;
var
  a, b: TAudioBuffer;
begin
  a := TAudioBuffer.Create(2, 64, 48000);
  b := TAudioBuffer.Create(2, 64, 48000);
  try
    a.Configure(2, 8, 48000);
    b.Configure(2, 8, 48000);
    a.Clear; b.Clear;
    b.ChannelPtr(0)[0] := 0.5;
    b.ChannelPtr(1)[0] := -0.25;
    a.MixFrom(b, 2.0);
    CheckNear(1.0, a.ChannelPtr(0)[0], 1e-6, 'mix gain applied L');
    CheckNear(-0.5, a.ChannelPtr(1)[0], 1e-6, 'mix gain applied R');
    a.ApplyGain(0.5);
    CheckNear(0.5, a.ChannelPtr(0)[0], 1e-6, 'apply gain L');   // 1.0 * 0.5
    CheckNear(0.5, a.PeakChannel(0), 1e-6, 'peak reflects scaled sample');
    CheckNear(0.25, a.PeakChannel(1), 1e-6, 'R scaled: 0.5 * 0.5');
  finally
    a.Free; b.Free;
  end;
end;

procedure Test_Buffer_NoReallocOnReuse;
var
  buf: TAudioBuffer;
  capBefore: Integer;
begin
  buf := TAudioBuffer.Create(2, 512, 48000);
  try
    capBefore := buf.CapacityFrames;
    buf.Configure(2, 128, 48000);
    buf.SetActiveFrames(64);
    buf.Configure(2, 480, 48000);
    CheckEqualInt(capBefore, buf.CapacityFrames, 'capacity unchanged when staying <= capacity');
  finally
    buf.Free;
  end;
end;

procedure Test_Buffer_Rms;
var
  buf: TAudioBuffer;
  i: Integer;
begin
  buf := TAudioBuffer.Create(1, 1000, 48000);
  try
    buf.Configure(1, 1000, 48000);
    for i := 0 to 999 do
      buf.ChannelPtr(0)[i] := Sin(2 * Pi * i / 100);   // 10 full cycles
    CheckNear(0.70710678, buf.RmsChannel(0), 0.01, 'sine RMS ~ 1/sqrt(2)');
  finally
    buf.Free;
  end;
end;

{ ---------------- TAudioRing ---------------- }

procedure Test_Ring_Basic;
var
  ring: TAudioRing;
  src, dst: array of Single;
  i, got: Integer;
begin
  ring := TAudioRing.Create(2, 100);   // rounds to 128 frames
  try
    CheckEqualInt(128, Integer(ring.CapacityFrames), 'rounded to power of two');
    CheckEqualInt(0, ring.FramesAvailable, 'starts empty');

    SetLength(src, 10 * 2);
    for i := 0 to High(src) do src[i] := i + 1;
    CheckEqualInt(10, ring.WriteFrames(src[0], 10), 'wrote 10 frames');
    CheckEqualInt(10, ring.FramesAvailable, '10 frames available');

    SetLength(dst, 10 * 2);
    got := ring.ReadFrames(dst[0], 10, False);
    CheckEqualInt(10, got, 'read 10 frames');
    for i := 0 to High(dst) do
      CheckNear(i + 1, dst[i], 1e-6, 'interleaved sample ' + IntToStr(i));
    CheckEqualInt(0, ring.FramesAvailable, 'empty again');
  finally
    ring.Free;
  end;
end;

procedure Test_Ring_UnderrunZeroPad;
var
  ring: TAudioRing;
  src, dst: array of Single;
  got, i: Integer;
begin
  ring := TAudioRing.Create(1, 64);
  try
    SetLength(src, 4);
    for i := 0 to 3 do src[i] := 5;
    ring.WriteFrames(src[0], 4);
    SetLength(dst, 10);
    for i := 0 to 9 do dst[i] := -1;
    got := ring.ReadFrames(dst[0], 10, True);
    CheckEqualInt(4, got, 'only 4 frames were available');
    CheckNear(5, dst[3], 1e-6, 'real data present');
    CheckNear(0, dst[4], 1e-6, 'remainder zero padded');
    CheckEqualInt(1, ring.Underruns, 'underrun counted');
  finally
    ring.Free;
  end;
end;

type
  TRingFeeder = class(TThread)
  public
    Ring: TAudioRing;
    TotalFrames: Integer;
    procedure Execute; override;
  end;

procedure TRingFeeder.Execute;
var
  block: array[0..63] of Single;   // up to 32 stereo frames
  sent, n, i, wrote: Integer;
begin
  sent := 0;
  while sent < TotalFrames do
  begin
    n := TotalFrames - sent;
    if n > 32 then n := 32;
    for i := 0 to n * 2 - 1 do
      block[i] := (sent * 2 + i);            // global interleaved sample index
    wrote := Ring.WriteFrames(block[0], n);  // may be a short (partial) write
    if wrote > 0 then
      Inc(sent, wrote)
    else
      TThread.Yield;
  end;
end;

procedure Test_Ring_ThreadedOrder;
const
  TOTAL = 40000;
var
  ring: TAudioRing;
  feeder: TRingFeeder;
  got: Integer;
  one: array[0..1] of Single;
  expected: Double;
begin
  ring := TAudioRing.Create(2, 2048);
  feeder := TRingFeeder.Create(True);
  feeder.FreeOnTerminate := False;
  feeder.Ring := ring;
  feeder.TotalFrames := TOTAL;
  try
    feeder.Start;
    got := 0;
    while got < TOTAL do
    begin
      if ring.ReadFrames(one[0], 1, False) = 1 then
      begin
        expected := got * 2;
        CheckNear(expected, one[0], 1e-3, 'ordered L @' + IntToStr(got));
        CheckNear(expected + 1, one[1], 1e-3, 'ordered R @' + IntToStr(got));
        Inc(got);
      end
      else
        TThread.Yield;
    end;
    feeder.WaitFor;
    CheckEqualInt(TOTAL, got, 'consumed every frame produced');
  finally
    feeder.Free;
    ring.Free;
  end;
end;

{ ---------------- generators + offline render ---------------- }

procedure Test_Offline_SineAmplitudeAndFrequency;
var
  res: TOfflineResult;
  tone: IAudioSource;
begin
  tone := TToneSource.Create(osSine, 1000.0, 0.5);
  res := RenderSourceOffline(tone, 48000, 2, 48000, 512);   // 1 second
  CheckNear(0.5, ChannelPeak(res, 0), 0.01, 'sine peak = amplitude');
  CheckNear(0.3535, ChannelRms(res, 0), 0.01, 'sine RMS = amp/sqrt(2)');
  CheckNear(1000.0, EstimateFrequency(res, 0), 2.0, 'measured frequency ~ 1000 Hz');
  CheckNear(EstimateFrequency(res, 0), EstimateFrequency(res, 1),
    1.0, 'both channels coherent');
end;

procedure Test_Offline_Sine_44100;
var
  res: TOfflineResult;
begin
  res := RenderSourceOffline(TToneSource.Create(osSine, 440.0, 0.8),
    44100, 1, 44100, 441);
  CheckNear(440.0, EstimateFrequency(res, 0), 1.5, '440 Hz at 44.1 kHz');
  CheckNear(0.8, ChannelPeak(res, 0), 0.01, 'amplitude 0.8');
end;

procedure Test_Offline_SweepMonotonic;
var
  res: TOfflineResult;
  fLow, fHigh: Double;
  half: Integer;
  loRes, hiRes: TOfflineResult;
  ch: Integer;
begin
  res := RenderSourceOffline(TSweepSource.Create(100, 8000, 1.0, 0.5, True),
    48000, 1, 48000, 480);
  { crude check: first-half average |x| rate of zero crossings < second half }
  half := res.Frames div 2;
  SetLength(loRes.Planar, 1); SetLength(hiRes.Planar, 1);
  loRes.Channels := 1; hiRes.Channels := 1;
  loRes.SampleRate := 48000; hiRes.SampleRate := 48000;
  loRes.Frames := half; hiRes.Frames := res.Frames - half;
  SetLength(loRes.Planar[0], half);
  SetLength(hiRes.Planar[0], res.Frames - half);
  for ch := 0 to half - 1 do loRes.Planar[0][ch] := res.Planar[0][ch];
  for ch := 0 to res.Frames - half - 1 do hiRes.Planar[0][ch] := res.Planar[0][half + ch];
  fLow := EstimateFrequency(loRes, 0);
  fHigh := EstimateFrequency(hiRes, 0);
  Check(fHigh > fLow * 2, 'sweep frequency rises over time');
end;

procedure Test_Offline_ClipCounting;
var
  res: TOfflineResult;
begin
  res := RenderSourceOffline(TToneSource.Create(osSquare, 500.0, 1.5),
    48000, 1, 4800, 480);
  { square at amp 1.5 -> every sample magnitude 1.5 >= 1.0 }
  CheckEqualInt(4800, CountAtOrAbove(res, 0, 1.0), 'all samples exceed full scale');
end;

procedure Test_Mixer_SumsSources;
var
  mix: TSourceMixer;
  res: TOfflineResult;
begin
  mix := TSourceMixer.Create(1.0);
  mix.Add(TToneSource.Create(osSine, 200, 0.3), 1.0);
  mix.Add(TToneSource.Create(osSine, 200, 0.3), 1.0);   // same phase -> adds to 0.6
  res := RenderSourceOffline(mix, 48000, 2, 24000, 512);
  CheckNear(0.6, ChannelPeak(res, 0), 0.02, 'two coherent sines sum');
end;

{ ---------------- software backend ---------------- }

type
  TCapturingSink = class
  public
    Blocks: Integer;
    Frames: Int64;
    LastOutPeak: Single;
    LastInPeak: Single;
    Tone: IAudioSource;
    procedure Cb(AInput, AOutput: TAudioBuffer; const ATime: TAudioStreamTime);
  end;

procedure TCapturingSink.Cb(AInput, AOutput: TAudioBuffer; const ATime: TAudioStreamTime);
begin
  if AOutput <> nil then
  begin
    if Tone <> nil then Tone.Render(AOutput);
    LastOutPeak := AOutput.Peak;
    Inc(Frames, AOutput.FrameCount);
  end;
  if AInput <> nil then
    LastInPeak := AInput.Peak;
  Inc(Blocks);
end;

procedure Test_Software_Enumerate;
var
  be: IAudioBackend;
  outs, ins: TAudioDeviceList;
begin
  be := TSoftwareBackend.Create(True);
  outs := be.EnumerateDevices(adRender);
  ins := be.EnumerateDevices(adCapture);
  CheckEqualInt(1, Length(outs), 'one software output device');
  CheckEqualInt(1, Length(ins), 'one software capture device');
  Check(outs[0].IsDefault, 'output marked default');
  Check(outs[0].SupportsRate(48000), 'supports 48k');
  CheckEqualStr(be.DefaultDeviceId(adRender), outs[0].Id, 'default id matches');
end;

procedure Test_Software_PacedBlocksAndTiming;
var
  be: TSoftwareBackend;
  sink: TCapturingSink;
  stream: IAudioStream;
  req: TAudioStreamRequest;
  st: TAudioStreamStats;
begin
  be := TSoftwareBackend.Create(True);
  sink := TCapturingSink.Create;
  sink.Tone := TToneSource.Create(osSine, 440, 0.5);
  try
    req := TAudioStreamRequest.Defaults;
    req.SampleRate := 48000;
    req.BufferFrames := 480;             // 10 ms blocks
    req.RenderChannels := 2;
    stream := be.OpenStream(req, sink.Cb);
    CheckEqualInt(48000, stream.Granted.SampleRate, 'granted 48k');
    CheckEqualInt(480, stream.Granted.BufferFrames, 'granted 480 frame block');
    stream.Start;
    Sleep(500);                          // ~50 blocks of 10 ms
    stream.Stop;
    st := stream.Stats;
    Check(st.CallbackCount >= 30, 'at least ~30 paced callbacks in 500 ms (' +
      IntToStr(st.CallbackCount) + ')');
    Check(st.CallbackCount <= 80, 'not wildly too many callbacks');
    Check(sink.LastOutPeak > 0.4, 'sine actually reached the output buffer');
    CheckEqualInt(0, Integer(st.XRunCount), 'no xruns on an idle machine');
  finally
    stream := nil;
    sink.Free;
  end;
end;

procedure Test_Software_DuplexLoopback;
var
  be: TSoftwareBackend;
  sink: TCapturingSink;
  stream: IAudioStream;
  req: TAudioStreamRequest;
begin
  be := TSoftwareBackend.Create(True);
  sink := TCapturingSink.Create;
  sink.Tone := TToneSource.Create(osSine, 300, 0.6);
  try
    req := TAudioStreamRequest.Defaults;
    req.Direction := adDuplex;
    req.SampleRate := 48000;
    req.BufferFrames := 256;
    stream := be.OpenStream(req, sink.Cb);
    stream.Start;
    Sleep(300);
    stream.Stop;
    Check(sink.LastInPeak > 0.4,
      'audio played out was captured back via loopback (in peak=' +
      FormatFloat('0.00', sink.LastInPeak) + ')');
  finally
    stream := nil;
    sink.Free;
  end;
end;

procedure Test_Software_VirtualMicrophone;
var
  be: TSoftwareBackend;
  sink: TCapturingSink;
  stream: IAudioStream;
  sws: TSoftwareStream;
  req: TAudioStreamRequest;
begin
  be := TSoftwareBackend.Create(True);
  sink := TCapturingSink.Create;
  try
    req := TAudioStreamRequest.Defaults;
    req.Direction := adCapture;
    req.SampleRate := 48000;
    req.BufferFrames := 256;
    stream := be.OpenStream(req, sink.Cb);
    sws := stream as TSoftwareStream;
    sws.InjectCaptureSource(TToneSource.Create(osSine, 1000, 0.7));
    stream.Start;
    Sleep(250);
    stream.Stop;
    Check(sink.Blocks > 5, 'capture callbacks delivered');
    CheckNear(0.7, sink.LastInPeak, 0.05, 'virtual mic signal captured at amplitude');
  finally
    stream := nil;
    sink.Free;
  end;
end;

procedure Test_Software_DeviceLossAndReopen;
var
  be: TSoftwareBackend;
  sink: TCapturingSink;
  stream: IAudioStream;
  sws: TSoftwareStream;
  req: TAudioStreamRequest;
begin
  be := TSoftwareBackend.Create(True);
  sink := TCapturingSink.Create;
  sink.Tone := TToneSource.Create(osSine, 440, 0.4);
  try
    req := TAudioStreamRequest.Defaults;
    req.SampleRate := 48000;
    req.BufferFrames := 256;
    stream := be.OpenStream(req, sink.Cb);
    sws := stream as TSoftwareStream;
    stream.Start;
    Sleep(120);
    Check(stream.State = assRunning, 'running before loss');
    sws.SimulateDeviceLoss;
    Check(stream.State = assLost, 'state is lost after simulated removal');
    { a fresh stream stands in for the recovered device }
    stream := nil;
    stream := be.OpenStream(req, sink.Cb);
    stream.Start;
    Sleep(120);
    Check(stream.State = assRunning, 'reopened stream runs');
  finally
    stream := nil;
    sink.Free;
  end;
end;

{ ---------------- factory ---------------- }

procedure Test_Factory_SoftwareForced;
var
  be: IAudioBackend;
begin
  be := CreateAudioBackend('software');
  Check(be <> nil, 'factory returns a backend');
  CheckEqualBool(True, be.Id = abSoftware, 'forced software backend');
  Check(be.IsAvailable, 'software backend always available');
end;

procedure Test_Factory_Auto;
var
  be: IAudioBackend;
begin
  be := CreateAudioBackend('auto');
  Check(be <> nil, 'auto backend chosen');
  Check(Length(be.EnumerateDevices(adRender)) >= 1, 'auto backend enumerates at least one output');
end;

{ ---------------- engine ---------------- }

procedure Test_Engine_Lifecycle;
var
  cfg: TConfig;
  eng: TAudioEngine;
  st: TAudioStreamStats;
begin
  cfg := TConfig.Create(TempConfigPath);
  try
    cfg.SetString(CFG_SEC_AUDIO, CFG_AUDIO_BACKEND, 'software');
    cfg.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_RATE, 48000);
    cfg.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_BUFFER, 480);
    eng := TAudioEngine.Create(cfg);
    try
      Check(eng.Open(True), 'engine opened');
      Check(eng.State = aesRunning, 'engine running after open+autostart');
      CheckEqualInt(48000, eng.Granted.SampleRate, 'engine negotiated 48k');
      eng.SetTestTone(440, 0.3);
      Sleep(300);
      st := eng.Stats;
      Check(st.CallbackCount > 10, 'engine callbacks ran');
      Check(eng.OutputPeak(0) > 0.2, 'engine meter shows the test tone');
      CheckEqualInt(0, Integer(st.XRunCount), 'engine had no xruns');
      eng.Stop;
      Check(eng.State = aesOpen, 'engine stopped -> open');
      eng.Close;
      Check(eng.State = aesIdle, 'engine closed -> idle');
    finally
      eng.Free;
    end;
  finally
    cfg.Free;
  end;
end;

procedure Test_Engine_RecoversFromDeviceLoss;
var
  cfg: TConfig;
  eng: TAudioEngine;
  waited: Integer;
  baseline: Int64;
begin
  cfg := TConfig.Create(TempConfigPath);
  try
    cfg.SetString(CFG_SEC_AUDIO, CFG_AUDIO_BACKEND, 'software');
    cfg.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_BUFFER, 256);
    eng := TAudioEngine.Create(cfg);
    try
      Check(eng.Open(True), 'engine opened');
      eng.SetTestTone(440, 0.3);
      Sleep(200);
      Check(eng.State = aesRunning, 'running before loss');
      Check(eng.Stats.CallbackCount > 5, 'audio flowing before loss');

      { report the device as gone - engine must enter recovery then heal }
      eng.NotifyDeviceLost('unit test forced loss');
      Check(eng.State in [aesLost, aesRecovering], 'engine reacts to device loss');

      waited := 0;
      while (eng.State <> aesRunning) and (waited < 8000) do
      begin
        Sleep(100); Inc(waited, 100);
      end;
      Check(eng.State = aesRunning, 'engine recovered to running (' +
        AudioEngineStateName(eng.State) + ')');

      baseline := eng.Stats.CallbackCount;
      Sleep(300);
      Check(eng.Stats.CallbackCount > baseline, 'audio flowing again after recovery');
      Check(eng.OutputPeak(0) > 0.2, 'the test tone resumed on the recovered device');
    finally
      eng.Free;
    end;
  finally
    cfg.Free;
  end;
end;

procedure Test_Engine_LongRunStability;
var
  cfg: TConfig;
  eng: TAudioEngine;
  st: TAudioStreamStats;
  elapsed: Integer;
begin
  { A compressed stand-in for the hour-long soak: 3 s of continuous paced
    rendering must produce a monotonic callback count and zero xruns. }
  cfg := TConfig.Create(TempConfigPath);
  try
    cfg.SetString(CFG_SEC_AUDIO, CFG_AUDIO_BACKEND, 'software');
    cfg.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_BUFFER, 240);
    eng := TAudioEngine.Create(cfg);
    try
      Check(eng.Open(True), 'engine opened for soak');
      eng.SetSource(TToneSource.Create(osSine, 220, 0.2));
      elapsed := 0;
      while elapsed < 3000 do
      begin
        Sleep(250);
        Inc(elapsed, 250);
      end;
      st := eng.Stats;
      { 3 s of 5 ms blocks is 600 ideally; anything well above the ~15.6 ms
        Windows scheduler floor (=192) proves the hybrid pacing holds cadence. }
      Check(st.CallbackCount > 300, 'sustained sub-10ms callback cadence (' +
        IntToStr(st.CallbackCount) + ' in 3 s)');
      Check(st.FramesProcessed >= Int64(st.CallbackCount) * 240,
        'frame count consistent with block count');
      Check(st.XRunCount <= 5, 'few scheduling hiccups over the run');
      Check(eng.ClipCount = 0, 'no clipping at amplitude 0.2');
      eng.Close;
    finally
      eng.Free;
    end;
  finally
    cfg.Free;
  end;
end;

{ ---------------- opt-in WASAPI hardware smoke ----------------
  Off by default (would make sound and needs a real output device). Enable with
  the UDAW_WASAPI_TEST environment variable to play a 1.5 s sine through the
  actual default Windows endpoint and assert the stream ran cleanly. }

procedure Test_WASAPI_HardwareTone;
{$IFDEF MSWINDOWS}
var
  cfg: TConfig;
  eng: TAudioEngine;
  st: TAudioStreamStats;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  if GetEnvironmentVariable('UDAW_WASAPI_TEST') = '' then
  begin
    Writeln('       (set UDAW_WASAPI_TEST=1 to run the WASAPI hardware smoke)');
    Exit;
  end;
  cfg := TConfig.Create(TempConfigPath);
  try
    cfg.SetString(CFG_SEC_AUDIO, CFG_AUDIO_BACKEND, 'wasapi');
    eng := TAudioEngine.Create(cfg);
    try
      Check(eng.Open(True), 'WASAPI engine opened');
      Check(eng.State = aesRunning, 'WASAPI stream running');
      Check(eng.Granted.SampleRate >= 44100, 'negotiated a sane rate');
      eng.SetTestTone(440, 0.2);
      Sleep(1500);
      st := eng.Stats;
      Check(st.CallbackCount > 20, 'WASAPI callbacks ran (' +
        IntToStr(st.CallbackCount) + ')');
      Check(st.XRunCount = 0, 'no WASAPI xruns during a short tone');
      Check(eng.OutputPeak(0) > 0.1, 'tone reached the WASAPI render buffer');
      eng.Close;
    finally
      eng.Free;
    end;
  finally
    cfg.Free;
  end;
  {$ELSE}
  Writeln('       (WASAPI smoke is Windows-only)');
  {$ENDIF}
end;

{ ---------------- registration ---------------- }

procedure RegisterPhase2Tests;
begin
  RegisterTest('audio.types', 'device format sizes',       @Test_DeviceFormat_Sizes);
  RegisterTest('audio.types', 'interleave int16 roundtrip', @Test_Interleave_Roundtrip_Int16);
  RegisterTest('audio.types', 'interleave float32 roundtrip', @Test_Interleave_Roundtrip_Float32);
  RegisterTest('audio.types', 'interleave int24 roundtrip', @Test_Interleave_Int24);
  RegisterTest('audio.types', 'encode clamps out-of-range', @Test_Clamp_On_Encode);

  RegisterTest('audio.buffer', 'mix + gain',               @Test_Buffer_MixAndGain);
  RegisterTest('audio.buffer', 'no realloc on reuse',      @Test_Buffer_NoReallocOnReuse);
  RegisterTest('audio.buffer', 'sine RMS',                 @Test_Buffer_Rms);

  RegisterTest('audio.ring', 'basic write/read',           @Test_Ring_Basic);
  RegisterTest('audio.ring', 'underrun zero-pad',          @Test_Ring_UnderrunZeroPad);
  RegisterTest('audio.ring', 'threaded SPSC order',        @Test_Ring_ThreadedOrder);

  RegisterTest('audio.gen', 'offline sine amp+freq',       @Test_Offline_SineAmplitudeAndFrequency);
  RegisterTest('audio.gen', 'offline sine @44100',         @Test_Offline_Sine_44100);
  RegisterTest('audio.gen', 'offline sweep rises',         @Test_Offline_SweepMonotonic);
  RegisterTest('audio.gen', 'square over-range clips',     @Test_Offline_ClipCounting);
  RegisterTest('audio.gen', 'mixer sums sources',          @Test_Mixer_SumsSources);

  RegisterTest('audio.backend', 'software enumerate',      @Test_Software_Enumerate);
  RegisterTest('audio.backend', 'paced blocks + timing',   @Test_Software_PacedBlocksAndTiming);
  RegisterTest('audio.backend', 'duplex loopback capture', @Test_Software_DuplexLoopback);
  RegisterTest('audio.backend', 'virtual microphone',      @Test_Software_VirtualMicrophone);
  RegisterTest('audio.backend', 'device loss + reopen',    @Test_Software_DeviceLossAndReopen);

  RegisterTest('audio.factory', 'forced software',         @Test_Factory_SoftwareForced);
  RegisterTest('audio.factory', 'auto selection',          @Test_Factory_Auto);

  RegisterTest('audio.engine', 'open/start/stop/close',    @Test_Engine_Lifecycle);
  RegisterTest('audio.engine', 'recovers after loss',      @Test_Engine_RecoversFromDeviceLoss);
  RegisterTest('audio.engine', 'sustained render (soak)',  @Test_Engine_LongRunStability);

  RegisterTest('audio.wasapi', 'hardware tone (opt-in)',   @Test_WASAPI_HardwareTone);
end;

end.
