unit UDAW.Audio.Engine;
{$I udaw.inc}

{ Phase 2 - TAudioEngine: the application-facing audio device engine.

  Responsibilities:
    * choose + own a backend (via UDAW.Audio.Backend.Factory)
    * open / start / stop / close a render (or duplex) stream, negotiating
      sample rate, channel count and block size from configuration
    * drive one IAudioSource into the output each block, off the UI thread
    * live metering (per-channel peak / RMS, xruns, CPU load, callback count)
    * device-change awareness and automatic device-loss recovery with backoff
    * persist the effective settings to [audio] in the config

  The render callback is real-time: it never allocates, never locks blocking
  (it uses TryEnter and falls back to the previous source), never logs. }

interface

uses
  SysUtils, Classes, Math,
  UDAW.Types, UDAW.Errors, UDAW.Logging, UDAW.Threading, UDAW.Config,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Device, UDAW.Audio.Source,
  UDAW.Audio.Ring, UDAW.Audio.Backend.Factory;

const
  TAP_RING_SIZE        = 4096;                // power of two (masking)
  CFG_SEC_AUDIO        = 'audio';
  CFG_AUDIO_BACKEND    = 'backend';           // auto | wasapi | directsound | software
  CFG_AUDIO_OUT_DEVICE = 'output_device';     // '' => the system default output; used by every playback path
  CFG_AUDIO_IN_DEVICE  = 'input_device';
  CFG_AUDIO_RATE       = 'sample_rate';
  CFG_AUDIO_BUFFER     = 'buffer_frames';
  CFG_AUDIO_OUT_CH     = 'output_channels';
  CFG_AUDIO_IN_CH      = 'input_channels';
  CFG_AUDIO_EXCLUSIVE  = 'exclusive';
  CFG_AUDIO_CAPTURE    = 'enable_input';
  CFG_AUDIO_AUTOSTART  = 'autostart';

  RECOVERY_MAX_ATTEMPTS = 20;

type
  TAudioEngineState = (aesIdle, aesOpen, aesRunning, aesLost, aesRecovering, aesFailed);

  TAudioEngineEvent = procedure(Sender: TObject; AKind: TAudioStreamEventKind;
    const AMessage: string) of object;

  TAudioEngine = class
  private
    FConfig: TConfig;
    FBackend: IAudioBackend;
    FBackendKey: string;               // the Settings backend id FBackend was created for
    FStream: IAudioStream;
    FState: Integer;                         // atomic TAudioEngineState
    FControlLock: TUDAWLock;                 // serialises open/close/reopen
    FSourceLock: TUDAWLock;                  // guards FSource swap
    FSource: IAudioSource;
    FOverlays: array[0..1] of IAudioSource;  // rendered on top of FSource: 0 Foley pads, 1 system sounds; guarded by FSourceLock
    FOverlayBuf: TAudioBuffer;               // scratch the overlay renders into before it is added

    FRequest: TAudioStreamRequest;
    FGranted: TAudioStreamGranted;

    FOutPeak, FOutRms: array of Single;      // per channel, written by RT thread
    FInPeak: array of Single;
    FTapRing: array[0..TAP_RING_SIZE - 1] of Single; // mono output tap, RT thread writes
    FTapHead: Integer;                       // next write slot; RT thread writes
    FClipCount: Int64;                       // written only by the RT thread
    FCaptureMismatchCount: Int64;            // written only by the RT thread
    FCaptureScratch: TAudioSampleArray;      // RT-thread-only interleave scratch

    FOnEvent: TAudioEngineEvent;
    FRecoveryThread: TThread;
    FRecoveryStop: Integer;

    FCaptureRing: TAudioRing;                // optional: engine -> consumer
    FMonitorEnabled: Boolean;                // RT-thread-read, UI-thread-written
    FMonitorGainDb: Double;

    procedure SetState(AState: TAudioEngineState);
    procedure RenderCallback(AInput, AOutput: TAudioBuffer; const ATime: TAudioStreamTime);
    procedure StreamEvent(AKind: TAudioStreamEventKind; const AMessage: string);
    procedure BackendDeviceChange(AKind: TAudioStreamEventKind; const AMessage: string);
    procedure BeginRecovery;
    procedure StopRecovery;
    function BuildRequestFromConfig: TAudioStreamRequest;
    procedure RefreshGranted;
    procedure PersistGranted;
    procedure AllocMeters(AOutCh, AInCh: Integer);
  public
    constructor Create(AConfig: TConfig);
    destructor Destroy; override;

    { Open (and optionally start) the configured device. Never raises for a
      device problem - logs, sets aesFailed and returns False so the DAW keeps
      running without audio. Raises only on a programming error. }
    function Open(AAutoStart: Boolean = True): Boolean;
    procedure Start;
    procedure Stop;
    procedure Close;
    { Close the current stream and Open again from (possibly changed) config. }
    function Reopen: Boolean;

    procedure SetSource(ASource: IAudioSource);   // thread-safe
    { Extra sources mixed on top of whatever SetSource plays (or on silence), through the same
      output device. Slot 0 is the Foley pads, slot 1 the Windows system sounds. nil removes one. }
    procedure SetOverlay(ASource: IAudioSource; ASlot: Integer = 0);
    procedure ClearSource;

    { Report that the current output device has gone away (called by a platform
      layer, or by a "reset audio device" UI action). Starts the same bounded
      backoff recovery the backend's own device-lost event triggers. }
    procedure NotifyDeviceLost(const AReason: string);
    { Convenience: play a steady sine (used by the settings "Test" button and
      the playback acceptance test). Pass 0 amplitude to silence. }
    procedure SetTestTone(AFreqHz: Double = 440.0; AAmplitude: Single = 0.25);

    function EnumerateOutputs: TAudioDeviceList;
    function EnumerateInputs: TAudioDeviceList;

    { Metering (safe to poll from the UI thread). }
    function State: TAudioEngineState;
    function Granted: TAudioStreamGranted;
    function Stats: TAudioStreamStats;
    function OutputChannels: Integer;
    function OutputPeak(AChannel: Integer): Single;
    { Copies the most recent ACount (<= TAP_RING_SIZE) mono output samples,
      oldest first, for UI spectrum display. Unsynchronised by design: a
      torn read only glitches one visual frame. }
    procedure CopyRecentOutput(ADest: PSingle; ACount: Integer);
    function OutputRms(AChannel: Integer): Single;
    function InputPeak(AChannel: Integer): Single;
    function ClipCount: Int64;
    { Frames dropped because the granted input channel count did not match
      the capture ring's channel count (e.g. the device's format changed
      between arming and starting a recording). Zero in the normal case. }
    function CaptureMismatchCount: Int64;
    function BackendName: string;
    function Describe: string;

    { Attach a ring the engine fills with captured input (duplex only). The
      engine does not own it. }
    procedure SetCaptureRing(ARing: TAudioRing);
    { Fold live captured input straight into the output mix (for hearing what
      you're about to record). AGainDb is applied on top of the existing
      output; call with AEnabled=False to turn monitoring back off. Safe to
      call from the UI thread at any time - the RT callback only ever reads
      these two fields. }
    procedure SetInputMonitoring(AEnabled: Boolean; AGainDb: Double = 0);

    property OnEvent: TAudioEngineEvent read FOnEvent write FOnEvent;
    property Config: TConfig read FConfig;
  end;

function AudioEngineStateName(AState: TAudioEngineState): string;

implementation

const
  SUBSYS = 'AudioEngine';

function AudioEngineStateName(AState: TAudioEngineState): string;
begin
  case AState of
    aesIdle:       Result := 'idle';
    aesOpen:       Result := 'open';
    aesRunning:    Result := 'running';
    aesLost:       Result := 'lost';
    aesRecovering: Result := 'recovering';
    aesFailed:     Result := 'failed';
  else
    Result := '?';
  end;
end;

{ ---------------- recovery thread ---------------- }

type
  TRecoveryThread = class(TUDAWThread)
  private
    FEngine: TAudioEngine;
  protected
    procedure Execute; override;
  public
    constructor Create(AEngine: TAudioEngine);
  end;

constructor TRecoveryThread.Create(AEngine: TAudioEngine);
begin
  FEngine := AEngine;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TRecoveryThread.Execute;
var
  attempt: Integer;
  delayMs: Integer;
  ok: Boolean;
begin
  {$IFDEF FPC}NameThreadForDebugging('udaw-audio-recover');
  {$ELSE}TThread.NameThreadForDebugging('udaw-audio-recover');{$ENDIF}
  attempt := 0;
  delayMs := 250;
  while (AtomicRead32(FEngine.FRecoveryStop) = 0) and (attempt < RECOVERY_MAX_ATTEMPTS) do
  begin
    Sleep(delayMs);
    if AtomicRead32(FEngine.FRecoveryStop) <> 0 then Break;
    Inc(attempt);
    ok := False;
    try
      ok := FEngine.Reopen;
    except
      on E: Exception do
        Logger.Warn(SUBSYS, Format('recovery attempt %d failed: %s', [attempt, E.Message]));
    end;
    if ok and (FEngine.State = aesRunning) then
    begin
      Logger.Info(SUBSYS, Format('device recovered after %d attempt(s)', [attempt]));
      FEngine.StreamEvent(aseRecovered, 'audio device recovered');
      Exit;
    end;
    if delayMs < 4000 then
      delayMs := delayMs * 2;
  end;
  if AtomicRead32(FEngine.FRecoveryStop) = 0 then
  begin
    Logger.Error(SUBSYS, 'device recovery gave up');
    FEngine.SetState(aesFailed);
    FEngine.StreamEvent(aseDeviceLost, 'audio device could not be recovered');
  end;
end;

{ ---------------- TAudioEngine ---------------- }

constructor TAudioEngine.Create(AConfig: TConfig);
begin
  inherited Create;
  FConfig := AConfig;
  FControlLock := TUDAWLock.Create('audioeng-ctl');
  FSourceLock := TUDAWLock.Create('audioeng-src');
  SetState(aesIdle);
end;

destructor TAudioEngine.Destroy;
begin
  StopRecovery;
  Close;
  FSource := nil;
  FOverlays[0] := nil;
  FOverlays[1] := nil;
  FOverlayBuf.Free;
  FControlLock.Free;
  FSourceLock.Free;
  inherited Destroy;
end;

procedure TAudioEngine.SetState(AState: TAudioEngineState);
begin
  AtomicSet32(FState, Ord(AState));
end;

function TAudioEngine.State: TAudioEngineState;
begin
  Result := TAudioEngineState(AtomicRead32(FState));
end;

procedure TAudioEngine.AllocMeters(AOutCh, AInCh: Integer);
var
  i: Integer;
begin
  if AOutCh < 0 then AOutCh := 0;
  if AInCh < 0 then AInCh := 0;
  SetLength(FOutPeak, AOutCh);
  SetLength(FOutRms, AOutCh);
  SetLength(FInPeak, AInCh);
  for i := 0 to AOutCh - 1 do begin FOutPeak[i] := 0; FOutRms[i] := 0; end;
  for i := 0 to AInCh - 1 do FInPeak[i] := 0;
  SetLength(FCaptureScratch,
    ClampBufferFrames(FGranted.BufferFrames) * (AInCh + 1) + 16);
end;

function TAudioEngine.BuildRequestFromConfig: TAudioStreamRequest;
var
  r: TAudioStreamRequest;
  wantCapture: Boolean;
begin
  r := TAudioStreamRequest.Defaults;
  r.RenderDeviceId := FConfig.GetString(CFG_SEC_AUDIO, CFG_AUDIO_OUT_DEVICE, '');
  r.CaptureDeviceId := FConfig.GetString(CFG_SEC_AUDIO, CFG_AUDIO_IN_DEVICE, '');
  r.SampleRate := FConfig.GetInt(CFG_SEC_AUDIO, CFG_AUDIO_RATE, 0);
  if (r.SampleRate <> 0) and not ValidSampleRate(r.SampleRate) then
    r.SampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  { 0 is Settings' "Device default": the engine's own default size, not the clamp's minimum }
  r.BufferFrames := FConfig.GetInt(CFG_SEC_AUDIO, CFG_AUDIO_BUFFER, UDAW_DEFAULT_BUFFER_FRAMES);
  if r.BufferFrames <= 0 then r.BufferFrames := UDAW_DEFAULT_BUFFER_FRAMES;
  r.BufferFrames := ClampBufferFrames(r.BufferFrames);
  r.RenderChannels := FConfig.GetInt(CFG_SEC_AUDIO, CFG_AUDIO_OUT_CH, 2);
  r.CaptureChannels := FConfig.GetInt(CFG_SEC_AUDIO, CFG_AUDIO_IN_CH, 2);
  if FConfig.GetBool(CFG_SEC_AUDIO, CFG_AUDIO_EXCLUSIVE, False) then
    r.ShareMode := asmExclusive
  else
    r.ShareMode := asmShared;
  wantCapture := FConfig.GetBool(CFG_SEC_AUDIO, CFG_AUDIO_CAPTURE, False);
  if wantCapture then
    r.Direction := adDuplex
  else
    r.Direction := adRender;
  Result := r;
end;

procedure TAudioEngine.RefreshGranted;
begin
  if FStream = nil then Exit;
  FGranted := FStream.Granted;
  AllocMeters(FGranted.RenderChannels, FGranted.CaptureChannels);
  FSourceLock.Enter;
  try
    if (FSource <> nil) and (FGranted.SampleRate > 0) then
      FSource.Prepare(FGranted.SampleRate, FGranted.BufferFrames,
        FGranted.RenderChannels);
  finally
    FSourceLock.Leave;
  end;
end;

procedure TAudioEngine.PersistGranted;
begin
  if FConfig = nil then Exit;
  { What the device granted is only a starting point: it fills in a setting that was never chosen,
    but never replaces one the user set in Settings (a requested 256 must stay 256 even when the
    device rounds it, and "Device default" must stay 0) }
  if FConfig.GetString(CFG_SEC_AUDIO, CFG_AUDIO_BACKEND, '#') = '#' then
    FConfig.SetString(CFG_SEC_AUDIO, CFG_AUDIO_BACKEND, 'auto');
  if FConfig.GetString(CFG_SEC_AUDIO, CFG_AUDIO_RATE, '#') = '#' then
    FConfig.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_RATE, FGranted.SampleRate);
  if FConfig.GetString(CFG_SEC_AUDIO, CFG_AUDIO_BUFFER, '#') = '#' then
    FConfig.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_BUFFER, FGranted.BufferFrames);
  if FConfig.GetString(CFG_SEC_AUDIO, CFG_AUDIO_OUT_CH, '#') = '#' then
    FConfig.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_OUT_CH, FGranted.RenderChannels);
  if (FGranted.CaptureChannels > 0) and (FConfig.GetString(CFG_SEC_AUDIO, CFG_AUDIO_IN_CH, '#') = '#') then
    FConfig.SetInt(CFG_SEC_AUDIO, CFG_AUDIO_IN_CH, FGranted.CaptureChannels);
  if FConfig.GetString(CFG_SEC_AUDIO, CFG_AUDIO_EXCLUSIVE, '#') = '#' then
    FConfig.SetBool(CFG_SEC_AUDIO, CFG_AUDIO_EXCLUSIVE, FGranted.ShareMode = asmExclusive);
  try
    FConfig.Save;
  except
    on E: Exception do
      Logger.Warn(SUBSYS, 'could not persist audio config: ' + E.Message);
  end;
end;

function TAudioEngine.Open(AAutoStart: Boolean): Boolean;
var
  backendId: string;
begin
  { Result is set on every completing path: True on success, False in the
    exception handler below; a failure before the inner try re-raises. }
  FControlLock.Enter;
  try
    if FStream <> nil then
    begin
      FStream.Close;
      FStream := nil;
    end;

    backendId := LowerCase(Trim(FConfig.GetString(CFG_SEC_AUDIO, CFG_AUDIO_BACKEND, 'auto')));
    { choosing another backend in Settings replaces the one in use (the stream is already closed) }
    if (FBackend <> nil) and (FBackendKey <> backendId) then
      FBackend := nil;
    if FBackend = nil then
    begin
      FBackendKey := backendId;
      FBackend := CreateAudioBackend(backendId);
      FBackend.SetDeviceChangeHandler(BackendDeviceChange);
    end;

    FRequest := BuildRequestFromConfig;
    try
      FStream := FBackend.OpenStream(FRequest, RenderCallback);
      FStream.SetEventHandler(StreamEvent);
      RefreshGranted;
      SetState(aesOpen);
      Result := True;
      if AAutoStart then
        Start;
      { some backends (WASAPI) only finish negotiating on their worker thread,
        so re-read the granted format once the stream is actually going }
      RefreshGranted;
      Logger.Info(SUBSYS, Format('opened [%s] %s', [FBackend.Name, FGranted.Describe]));
      PersistGranted;
    except
      on E: Exception do
      begin
        Logger.Error(SUBSYS, 'failed to open audio device: ' + E.Message);
        FStream := nil;
        SetState(aesFailed);
        Result := False;
      end;
    end;
  finally
    FControlLock.Leave;
  end;
end;

procedure TAudioEngine.Start;
begin
  FControlLock.Enter;
  try
    if FStream = nil then Exit;
    if FStream.State = assRunning then
    begin
      SetState(aesRunning);
      Exit;
    end;
    FStream.Start;
    if FStream.State in [assRunning] then
      SetState(aesRunning)
    else if FStream.State = assLost then
      SetState(aesLost);
  finally
    FControlLock.Leave;
  end;
end;

procedure TAudioEngine.Stop;
begin
  FControlLock.Enter;
  try
    if FStream <> nil then
      FStream.Stop;
    if State = aesRunning then
      SetState(aesOpen);
  finally
    FControlLock.Leave;
  end;
end;

procedure TAudioEngine.Close;
begin
  StopRecovery;
  FControlLock.Enter;
  try
    if FStream <> nil then
    begin
      FStream.Close;
      FStream := nil;
    end;
    if State <> aesFailed then
      SetState(aesIdle);
  finally
    FControlLock.Leave;
  end;
end;

function TAudioEngine.Reopen: Boolean;
begin
  Result := Open(True);
end;

procedure TAudioEngine.SetSource(ASource: IAudioSource);
var
  sr, bf, ch: Integer;
begin
  FSourceLock.Enter;
  try
    FSource := ASource;
    if ASource <> nil then
    begin
      { Always Prepare the freshly-attached source, even before the device
        has finished (or started) negotiating a format: if FGranted is still
        zeroed (stream not yet Open'd, or Open'd but RefreshGranted hasn't
        run on this thread yet) this used to skip Prepare entirely, leaving
        the source's internal per-block state (e.g. TTrackerPlayer's channel
        array, only allocated in ResetChannels/Reset, which Prepare calls)
        uninitialised - RenderCallback would then dutifully call Render every
        block, but the source would render nothing forever, with no error:
        silent playback that looks identical to "nothing is wired up".
        Falling back to sane defaults here means Prepare always runs at
        least once; RefreshGranted (called from Open/Reopen once the real
        format is known) re-Prepares with the actual negotiated values. }
      sr := FGranted.SampleRate;
      bf := FGranted.BufferFrames;
      ch := FGranted.RenderChannels;
      if sr <= 0 then sr := UDAW_DEFAULT_SAMPLE_RATE;
      if bf <= 0 then bf := UDAW_DEFAULT_BUFFER_FRAMES;
      if ch <= 0 then ch := 2;
      ASource.Prepare(sr, bf, ch);
    end;
  finally
    FSourceLock.Leave;
  end;
end;

procedure TAudioEngine.ClearSource;
begin
  SetSource(nil);
end;

procedure TAudioEngine.SetOverlay(ASource: IAudioSource; ASlot: Integer);
var
  sr, bf, ch: Integer;
begin
  FSourceLock.Enter;
  try
    if (ASlot < 0) or (ASlot > High(FOverlays)) then Exit;
    FOverlays[ASlot] := ASource;
    if ASource <> nil then
    begin
      sr := FGranted.SampleRate;
      bf := FGranted.BufferFrames;
      ch := FGranted.RenderChannels;
      if sr <= 0 then sr := UDAW_DEFAULT_SAMPLE_RATE;
      if bf <= 0 then bf := UDAW_DEFAULT_BUFFER_FRAMES;
      if ch <= 0 then ch := 2;
      if FOverlayBuf = nil then
        FOverlayBuf := TAudioBuffer.Create(ch, bf, sr);
      ASource.Prepare(sr, bf, ch);
    end;
  finally
    FSourceLock.Leave;
  end;
end;

procedure TAudioEngine.NotifyDeviceLost(const AReason: string);
begin
  StreamEvent(aseDeviceLost, AReason);
end;

procedure TAudioEngine.SetTestTone(AFreqHz: Double; AAmplitude: Single);
begin
  if AAmplitude <= 0 then
    ClearSource
  else
    SetSource(TToneSource.Create(osSine, AFreqHz, AAmplitude));
end;

procedure TAudioEngine.SetCaptureRing(ARing: TAudioRing);
begin
  { All callers quiesce the stream before attaching/detaching a live ring. }
  FCaptureRing := ARing;
end;

procedure TAudioEngine.SetInputMonitoring(AEnabled: Boolean; AGainDb: Double);
begin
  FMonitorGainDb := AGainDb;
  FMonitorEnabled := AEnabled;   // written last: RT thread must never see a
                                  // stale/zero gain paired with Enabled=True
end;

procedure TAudioEngine.RenderCallback(AInput, AOutput: TAudioBuffer;
  const ATime: TAudioStreamTime);
var
  ch, i: Integer;
  gotSrc: Boolean;
  d: PAudioSample;
  v, mx, monG: Single;
  acc: Double;
  toWrite, offset, frame, blockFrames, monCh: Integer;
  inputSample: PAudioSample;
  monSrc: PAudioSample;
  monN: Integer;
  d2: PAudioSample;
  head: Integer;
  ov: Integer;
begin
  if AOutput <> nil then
  begin
    gotSrc := False;
    if FSourceLock.TryEnter then
    try
      if FSource <> nil then
      begin
        FSource.Render(AOutput);
        gotSrc := True;
      end;
      if FOverlayBuf <> nil then
        for ov := 0 to High(FOverlays) do
          if FOverlays[ov] <> nil then
          begin
            if not gotSrc then
            begin
              AOutput.Clear;
              gotSrc := True;
            end;
            FOverlayBuf.Configure(AOutput.ChannelCount, AOutput.FrameCount, AOutput.SampleRate);
            FOverlayBuf.SetActiveFrames(AOutput.FrameCount);
            FOverlayBuf.Clear;
            FOverlays[ov].Render(FOverlayBuf);
            AOutput.MixFrom(FOverlayBuf, 1.0);
          end;
    finally
      FSourceLock.Leave;
    end;

    if not gotSrc then
      AOutput.Clear;

    { Input monitoring: fold the live captured input straight into this same
      block's output, ahead of the clip-protection loop below so a hot
      monitored signal gets the same hard-clip/NaN scrub as everything else.
      Mono input is duplicated across every output channel; a multichannel
      input is mapped channel-for-channel, extra output channels left alone. }
    if FMonitorEnabled and (AInput <> nil) and (AInput.FrameCount > 0) and (AInput.ChannelCount > 0) then
    begin
      monG := Power(10, FMonitorGainDb / 20);
      monN := Min(AOutput.FrameCount, AInput.FrameCount);
      for ch := 0 to AOutput.ChannelCount - 1 do
      begin
        if ch < AInput.ChannelCount then monCh := ch
        else if AInput.ChannelCount = 1 then monCh := 0
        else Continue;
        d := AOutput.ChannelPtr(ch);
        monSrc := AInput.ChannelPtr(monCh);
        for i := 0 to monN - 1 do
        begin
          d^ := d^ + monSrc^ * monG;
          Inc(d);
          Inc(monSrc);
        end;
      end;
    end;

    { hard-clip protection + clip accounting; also scrubs NaN/Inf }
    for ch := 0 to AOutput.ChannelCount - 1 do
    begin
      d := AOutput.ChannelPtr(ch);
      mx := 0;
      acc := 0;
      for i := 0 to AOutput.FrameCount - 1 do
      begin
        v := d^;
        if (v <> v) or (v - v <> 0) then v := 0;
        if v > 1.0 then begin v := 1.0; Inc(FClipCount); end
        else if v < -1.0 then begin v := -1.0; Inc(FClipCount); end;
        d^ := v;
        if Abs(v) > mx then mx := Abs(v);
        acc := acc + Double(v) * Double(v);
        Inc(d);
      end;
      if ch < Length(FOutPeak) then
      begin
        FOutPeak[ch] := mx;
        if AOutput.FrameCount > 0 then
          FOutRms[ch] := Sqrt(acc / AOutput.FrameCount)
        else
          FOutRms[ch] := 0;
      end;
    end;

    { mono output tap for the UI spectrum (ch0, averaged with ch1 if present) }
    if AOutput.ChannelCount > 0 then
    begin
      d := AOutput.ChannelPtr(0);
      if AOutput.ChannelCount > 1 then d2 := AOutput.ChannelPtr(1) else d2 := d;
      head := FTapHead;
      for i := 0 to AOutput.FrameCount - 1 do
      begin
        FTapRing[head] := (d^ + d2^) * 0.5;
        head := (head + 1) and (TAP_RING_SIZE - 1);
        Inc(d);
        Inc(d2);
      end;
      FTapHead := head;
    end;
  end;

  if AInput <> nil then
  begin
    for ch := 0 to AInput.ChannelCount - 1 do
      if ch < Length(FInPeak) then
        FInPeak[ch] := AInput.PeakChannel(ch);

    if (FCaptureRing <> nil) and (AInput.FrameCount > 0) then
    begin
      if AInput.ChannelCount = FCaptureRing.Channels then
      begin
        blockFrames := Length(FCaptureScratch) div AInput.ChannelCount;
        offset := 0;
        while (offset < AInput.FrameCount) and (blockFrames > 0) do
        begin
          toWrite := AInput.FrameCount - offset;
          if toWrite > blockFrames then toWrite := blockFrames;
          for ch := 0 to AInput.ChannelCount - 1 do
          begin
            inputSample := AInput.ChannelPtr(ch);
            Inc(inputSample, offset);
            for frame := 0 to toWrite - 1 do
            begin
              FCaptureScratch[frame * AInput.ChannelCount + ch] := inputSample^;
              Inc(inputSample);
            end;
          end;
          FCaptureRing.WriteFrames(FCaptureScratch[0], toWrite);
          Inc(offset, toWrite);
        end;
      end
      else
        Inc(FCaptureMismatchCount);
    end;
  end;
end;

procedure TAudioEngine.StreamEvent(AKind: TAudioStreamEventKind; const AMessage: string);
begin
  case AKind of
    aseDeviceLost:
      begin
        Logger.Warn(SUBSYS, 'stream event: device lost - ' + AMessage);
        if State <> aesRecovering then
        begin
          SetState(aesLost);
          if FCaptureRing = nil then BeginRecovery;
        end;
      end;
    aseRecovered:
      SetState(aesRunning);
    aseXRunBurst:
      Logger.Warn(SUBSYS, 'xrun burst: ' + AMessage);
    aseFormatChanged:
      Logger.Info(SUBSYS, 'format changed: ' + AMessage);
  end;
  if Assigned(FOnEvent) then
    FOnEvent(Self, AKind, AMessage);
end;

procedure TAudioEngine.BackendDeviceChange(AKind: TAudioStreamEventKind;
  const AMessage: string);
begin
  Logger.Info(SUBSYS, 'backend device change: ' + AMessage);
  if Assigned(FOnEvent) then
    FOnEvent(Self, aseDeviceChanged, AMessage);
end;

procedure TAudioEngine.BeginRecovery;
begin
  if (FRecoveryThread <> nil) then
  begin
    if FRecoveryThread.Finished then
    begin
      FRecoveryThread.WaitFor;
      FreeAndNil(FRecoveryThread);
    end
    else
      Exit;   // recovery already in progress
  end;
  AtomicSet32(FRecoveryStop, 0);
  SetState(aesRecovering);
  Logger.Info(SUBSYS, 'starting device recovery');
  FRecoveryThread := TRecoveryThread.Create(Self);
end;

procedure TAudioEngine.StopRecovery;
begin
  AtomicSet32(FRecoveryStop, 1);
  if FRecoveryThread <> nil then
  begin
    FRecoveryThread.WaitFor;
    FreeAndNil(FRecoveryThread);
  end;
end;

function TAudioEngine.EnumerateOutputs: TAudioDeviceList;
begin
  if FBackend <> nil then
    Result := FBackend.EnumerateDevices(adRender)
  else
    SetLength(Result, 0);
end;

function TAudioEngine.EnumerateInputs: TAudioDeviceList;
begin
  if FBackend <> nil then
    Result := FBackend.EnumerateDevices(adCapture)
  else
    SetLength(Result, 0);
end;

function TAudioEngine.Granted: TAudioStreamGranted;
begin
  Result := FGranted;
end;

function TAudioEngine.Stats: TAudioStreamStats;
begin
  if FStream <> nil then
    Result := FStream.Stats
  else
    FillChar(Result, SizeOf(Result), 0);
end;

function TAudioEngine.OutputChannels: Integer;
begin
  Result := Length(FOutPeak);
end;

function TAudioEngine.OutputPeak(AChannel: Integer): Single;
begin
  if (AChannel >= 0) and (AChannel < Length(FOutPeak)) then
    Result := FOutPeak[AChannel]
  else
    Result := 0;
end;

procedure TAudioEngine.CopyRecentOutput(ADest: PSingle; ACount: Integer);
var
  i, idx: Integer;
begin
  if ACount > TAP_RING_SIZE then ACount := TAP_RING_SIZE;
  idx := (FTapHead - ACount) and (TAP_RING_SIZE - 1);
  for i := 0 to ACount - 1 do
  begin
    ADest^ := FTapRing[idx];
    Inc(ADest);
    idx := (idx + 1) and (TAP_RING_SIZE - 1);
  end;
end;

function TAudioEngine.OutputRms(AChannel: Integer): Single;
begin
  if (AChannel >= 0) and (AChannel < Length(FOutRms)) then
    Result := FOutRms[AChannel]
  else
    Result := 0;
end;

function TAudioEngine.InputPeak(AChannel: Integer): Single;
begin
  if (AChannel >= 0) and (AChannel < Length(FInPeak)) then
    Result := FInPeak[AChannel]
  else
    Result := 0;
end;

function TAudioEngine.ClipCount: Int64;
begin
  Result := FClipCount;
end;

function TAudioEngine.CaptureMismatchCount: Int64;
begin
  Result := FCaptureMismatchCount;
end;

function TAudioEngine.BackendName: string;
begin
  if FBackend <> nil then Result := FBackend.Name else Result := '(none)';
end;

function TAudioEngine.Describe: string;
var
  st: TAudioStreamStats;
begin
  st := Stats;
  Result := Format(
    'engine=%s backend=%s'#10 +
    '%s'#10 +
    'callbacks=%d frames=%d xruns=%d cpu=%.1f%% (peak %.1f%%) clips=%d',
    [AudioEngineStateName(State), BackendName, FGranted.Describe,
     st.CallbackCount, st.FramesProcessed, st.XRunCount,
     st.CpuLoad * 100, st.PeakCpuLoad * 100, FClipCount]);
end;

end.
