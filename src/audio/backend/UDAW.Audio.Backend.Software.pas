unit UDAW.Audio.Backend.Software;
{$I udaw.inc}

{ Phase 2 - cross-platform software audio backend.

  This is a REAL backend, not a stub. It drives the engine's render/capture
  callback from a dedicated high-priority thread paced against the monotonic
  host clock at the negotiated sample rate and block size. It is used:

    * on every platform, as the guaranteed-present fallback and for headless /
      CI runs where opening real hardware is undesirable;
    * as the deterministic substrate for the Phase 2 acceptance tests
      (block delivery, timing, xrun accounting, device-loss recovery);
    * as the offline / faster-than-real-time render path (see
      UDAW.Audio.Offline), by running the same callback with pacing disabled.

  Capabilities that mirror real hardware:
    * negotiable sample rate / channel count / block size
    * duplex loopback: audio written to the render buffer is presented to the
      capture buffer one block later (so "play a sine, capture it back" works)
    * an injectable virtual capture source (a signal generator standing in for
      a microphone) for capture-path verification
    * missed-deadline detection => XRunCount
    * SimulateDeviceLoss => aseDeviceLost, stream enters assLost; the engine's
      recovery logic reopens it exactly as it would for a real device. }

interface

uses
  {$IFDEF UDAW_WINDOWS}Winapi.Windows, Winapi.MMSystem,{$ENDIF}
  SysUtils, Classes,
  UDAW.Types, UDAW.Errors, UDAW.Logging, UDAW.Threading,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Device, UDAW.Audio.Source;

type
  TSoftwareBackend = class;

  TSoftwareStream = class(TInterfacedObject, IAudioStream)
  private
    FBackend: TSoftwareBackend;
    FCallback: TAudioStreamCallback;
    FEventHandler: TAudioStreamEvent;
    FGranted: TAudioStreamGranted;
    FState: Integer;                 // atomic TAudioStreamState
    FThread: TThread;
    FStopReq: Integer;               // atomic
    FPaced: Boolean;

    FRenderBuf: TAudioBuffer;
    FCaptureBuf: TAudioBuffer;
    FLoopback: TAudioBuffer;         // previous block's render output
    FCaptureSource: IAudioSource;    // optional virtual mic

    FStats: TAudioStreamStats;
    FStatsLock: TUDAWLock;
    FCallbackIndex: Int64;
    FStreamFrames: Int64;

    procedure SetState(AState: TAudioStreamState);
    procedure Tick(AHostMs: Double);
    procedure RunLoop;
    procedure FireEvent(AKind: TAudioStreamEventKind; const AMsg: string);
  public
    constructor Create(ABackend: TSoftwareBackend; const ARequest: TAudioStreamRequest;
      ACallback: TAudioStreamCallback; APaced: Boolean);
    destructor Destroy; override;

    { IAudioStream }
    procedure Start;
    procedure Stop;
    procedure Close;
    function State: TAudioStreamState;
    function Granted: TAudioStreamGranted;
    function Stats: TAudioStreamStats;
    procedure ResetStats;
    procedure SetEventHandler(AHandler: TAudioStreamEvent);
    function BackendName: string;

    { test / offline hooks }
    procedure InjectCaptureSource(ASource: IAudioSource);
    procedure SimulateDeviceLoss;
    procedure RenderOneBlock;       // offline: run callback once, no pacing
    property PacedMode: Boolean read FPaced write FPaced;
  end;

  TSoftwareBackend = class(TInterfacedObject, IAudioBackend)
  private
    FDeviceChange: TAudioStreamEvent;
    FDefaultRenderChannels: Integer;
    FDefaultCaptureChannels: Integer;
    FDefaultRate: Integer;
    FDefaultBuffer: Integer;
    FPacedDefault: Boolean;
  public
    constructor Create(APaced: Boolean = True);
    { IAudioBackend }
    function Id: TAudioBackendId;
    function Name: string;
    function IsAvailable: Boolean;
    function EnumerateDevices(ADirection: TAudioDirection): TAudioDeviceList;
    function DefaultDeviceId(ADirection: TAudioDirection): string;
    function OpenStream(const ARequest: TAudioStreamRequest;
      ACallback: TAudioStreamCallback): IAudioStream;
    procedure SetDeviceChangeHandler(AHandler: TAudioStreamEvent);

    { announce a synthetic hot-plug to registered listeners }
    procedure NotifyDeviceChange(const AMessage: string);
    property DefaultRate: Integer read FDefaultRate write FDefaultRate;
    property DefaultBuffer: Integer read FDefaultBuffer write FDefaultBuffer;
    property PacedDefault: Boolean read FPacedDefault write FPacedDefault;
  end;

const
  SW_RENDER_ID  = 'software:render:0';
  SW_CAPTURE_ID = 'software:capture:0';

implementation

const
  SUBSYS = 'AudioSW';

{ Monotonic high-resolution clock in milliseconds (fractional). GetTickCount64
  only advances every ~15.6 ms on Windows, which is far too coarse to pace short
  audio blocks, so use QPC there. }
{$IFDEF UDAW_WINDOWS}
var
  GQpcFreq: Int64 = 0;

function MonoMs: Double;
var
  c: Int64;
begin
  if GQpcFreq = 0 then
    QueryPerformanceFrequency(GQpcFreq);
  QueryPerformanceCounter(c);
  Result := (c * 1000.0) / GQpcFreq;
end;
{$ELSE}
function MonoMs: Double;
begin
  Result := TThread.GetTickCount64;
end;
{$ENDIF}

{ ---------------- TSoftwareStream worker thread ---------------- }

type
  TSoftwareWorker = class(TThread)
  private
    FStream: TSoftwareStream;
  protected
    procedure Execute; override;
  public
    constructor Create(AStream: TSoftwareStream);
  end;

constructor TSoftwareWorker.Create(AStream: TSoftwareStream);
begin
  FStream := AStream;
  FreeOnTerminate := False;
  inherited Create(False);
  {$IFDEF FPC}
  Priority := tpHighest;
  {$ELSE}
  Priority := tpTimeCritical;
  {$ENDIF}
end;

procedure TSoftwareWorker.Execute;
begin
  {$IFDEF FPC}
  NameThreadForDebugging('udaw-audio-sw');
  {$ELSE}
  TThread.NameThreadForDebugging('udaw-audio-sw');
  {$ENDIF}
  FStream.RunLoop;
end;

{ ---------------- TSoftwareStream ---------------- }

constructor TSoftwareStream.Create(ABackend: TSoftwareBackend;
  const ARequest: TAudioStreamRequest; ACallback: TAudioStreamCallback;
  APaced: Boolean);
var
  rate, buf, rch, cch: Integer;
begin
  inherited Create;
  FBackend := ABackend;
  FCallback := ACallback;
  FPaced := APaced;
  FStatsLock := TUDAWLock.Create('sw-stats');

  rate := ARequest.SampleRate;
  if rate <= 0 then rate := ABackend.DefaultRate;
  if not ValidSampleRate(rate) then rate := UDAW_DEFAULT_SAMPLE_RATE;

  buf := ARequest.BufferFrames;
  if buf <= 0 then buf := ABackend.DefaultBuffer;
  buf := ClampBufferFrames(buf);

  rch := ARequest.RenderChannels;
  if rch <= 0 then rch := 2;
  cch := ARequest.CaptureChannels;
  if cch <= 0 then cch := 2;

  FillChar(FGranted, SizeOf(FGranted), 0);
  FGranted.Direction := ARequest.Direction;
  FGranted.SampleRate := rate;
  FGranted.BufferFrames := buf;
  FGranted.ShareMode := ARequest.ShareMode;
  FGranted.RenderFormat := dfFloat32;
  FGranted.CaptureFormat := dfFloat32;

  if ARequest.Direction in [adRender, adDuplex] then
  begin
    FGranted.RenderChannels := rch;
    FGranted.RenderDeviceId := SW_RENDER_ID;
    FGranted.RenderDeviceName := 'UDAW Software Output';
    FGranted.OutputLatencyFrames := buf * 2;
    FRenderBuf := TAudioBuffer.Create(rch, buf, rate);
    FLoopback := TAudioBuffer.Create(rch, buf, rate);
    FLoopback.Clear;
  end;
  if ARequest.Direction in [adCapture, adDuplex] then
  begin
    FGranted.CaptureChannels := cch;
    FGranted.CaptureDeviceId := SW_CAPTURE_ID;
    FGranted.CaptureDeviceName := 'UDAW Software Loopback';
    FGranted.InputLatencyFrames := buf * 2;
    FCaptureBuf := TAudioBuffer.Create(cch, buf, rate);
  end;

  FStats.SampleRate := rate;
  FStats.BufferFrames := buf;
  SetState(assStopped);
end;

destructor TSoftwareStream.Destroy;
begin
  Close;
  FRenderBuf.Free;
  FCaptureBuf.Free;
  FLoopback.Free;
  FStatsLock.Free;
  inherited Destroy;
end;

procedure TSoftwareStream.SetState(AState: TAudioStreamState);
begin
  AtomicSet32(FState, Ord(AState));
end;

function TSoftwareStream.State: TAudioStreamState;
begin
  Result := TAudioStreamState(AtomicRead32(FState));
end;

function TSoftwareStream.Granted: TAudioStreamGranted;
begin
  Result := FGranted;
end;

function TSoftwareStream.Stats: TAudioStreamStats;
begin
  FStatsLock.Enter;
  try
    Result := FStats;
  finally
    FStatsLock.Leave;
  end;
end;

procedure TSoftwareStream.ResetStats;
begin
  FStatsLock.Enter;
  try
    FStats.CallbackCount := 0;
    FStats.FramesProcessed := 0;
    FStats.XRunCount := 0;
    FStats.LastBlockFrames := 0;
    FStats.CpuLoad := 0;
    FStats.PeakCpuLoad := 0;
  finally
    FStatsLock.Leave;
  end;
end;

procedure TSoftwareStream.SetEventHandler(AHandler: TAudioStreamEvent);
begin
  FEventHandler := AHandler;
end;

function TSoftwareStream.BackendName: string;
begin
  Result := 'software';
end;

procedure TSoftwareStream.InjectCaptureSource(ASource: IAudioSource);
begin
  FCaptureSource := ASource;
  if (ASource <> nil) and (FCaptureBuf <> nil) then
    ASource.Prepare(FGranted.SampleRate, FGranted.BufferFrames, FCaptureBuf.ChannelCount);
end;

procedure TSoftwareStream.FireEvent(AKind: TAudioStreamEventKind; const AMsg: string);
begin
  if Assigned(FEventHandler) then
    try
      FEventHandler(AKind, AMsg);
    except
      { an event consumer must never break the audio backend }
    end;
end;

procedure TSoftwareStream.Start;
begin
  if State = assRunning then Exit;
  if State = assLost then
    RaiseUDAW(errInvalidState, SUBSYS, 'stream is lost; reopen it');
  AtomicSet32(FStopReq, 0);
  FCallbackIndex := 0;
  FStreamFrames := 0;
  if FLoopback <> nil then FLoopback.Clear;
  SetState(assRunning);
  if FPaced then
    FThread := TSoftwareWorker.Create(Self);
  Logger.Info(SUBSYS, Format('stream started: %s', [FGranted.Describe]));
end;

procedure TSoftwareStream.Stop;
begin
  if State <> assRunning then
  begin
    if State = assLost then SetState(assStopped);
    Exit;
  end;
  AtomicSet32(FStopReq, 1);
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  if State = assRunning then
    SetState(assStopped);
  Logger.Info(SUBSYS, 'stream stopped');
end;

procedure TSoftwareStream.Close;
begin
  Stop;
  if State <> assClosed then
    SetState(assClosed);
end;

procedure TSoftwareStream.SimulateDeviceLoss;
begin
  AtomicSet32(FStopReq, 1);
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  SetState(assLost);
  Logger.Warn(SUBSYS, 'simulated device loss');
  FireEvent(aseDeviceLost, 'software device removed (simulated)');
end;

procedure TSoftwareStream.Tick(AHostMs: Double);
var
  t: TAudioStreamTime;
  inBuf, outBuf: TAudioBuffer;
  n, ch: Integer;
  t0, t1: Double;
  periodMs, load: Double;
begin
  n := FGranted.BufferFrames;
  t.CallbackIndex := FCallbackIndex;
  t.StreamFrames := FStreamFrames;
  t.HostTimeNs := Round(AHostMs * 1.0E6);
  t.SampleRate := FGranted.SampleRate;

  outBuf := nil;
  inBuf := nil;

  if FRenderBuf <> nil then
  begin
    FRenderBuf.SetActiveFrames(n);
    FRenderBuf.Clear;
    FRenderBuf.StreamPosition := FStreamFrames;
    outBuf := FRenderBuf;
  end;

  if FCaptureBuf <> nil then
  begin
    FCaptureBuf.SetActiveFrames(n);
    FCaptureBuf.StreamPosition := FStreamFrames;
    if FCaptureSource <> nil then
    begin
      FCaptureBuf.Clear;
      FCaptureSource.Render(FCaptureBuf);
    end
    else if (FLoopback <> nil) then
    begin
      { duplex loopback: present the previous block's output }
      FCaptureBuf.Clear;
      for ch := 0 to FCaptureBuf.ChannelCount - 1 do
        if ch < FLoopback.ChannelCount then
          Move(FLoopback.ChannelPtr(ch)^, FCaptureBuf.ChannelPtr(ch)^,
            n * SizeOf(TAudioSample));
    end
    else
      FCaptureBuf.Clear;
    inBuf := FCaptureBuf;
  end;

  t0 := MonoMs;
  if Assigned(FCallback) then
    try
      FCallback(inBuf, outBuf, t);
    except
      on E: Exception do
        Logger.Error(SUBSYS, 'render callback raised: ' + E.Message);
    end;
  t1 := MonoMs;

  { capture the just-rendered output for next block's loopback }
  if (FLoopback <> nil) and (FRenderBuf <> nil) then
  begin
    FLoopback.SetActiveFrames(n);
    FLoopback.CopyFrom(FRenderBuf);
  end;

  Inc(FCallbackIndex);
  Inc(FStreamFrames, n);

  periodMs := (1000.0 * n) / FGranted.SampleRate;
  if periodMs <= 0 then periodMs := 1;
  load := (t1 - t0) / periodMs;

  FStatsLock.Enter;
  try
    FStats.CallbackCount := FCallbackIndex;
    FStats.FramesProcessed := FStreamFrames;
    FStats.LastBlockFrames := n;
    FStats.CpuLoad := FStats.CpuLoad * 0.9 + load * 0.1;
    if load > FStats.PeakCpuLoad then FStats.PeakCpuLoad := load;
  finally
    FStatsLock.Leave;
  end;
end;

procedure TSoftwareStream.RenderOneBlock;
begin
  if State <> assRunning then
    RaiseUDAW(errInvalidState, SUBSYS, 'RenderOneBlock: stream not running');
  Tick(MonoMs);
end;

procedure TSoftwareStream.RunLoop;
var
  nowMs: Double;
  nextDueMs: Double;
  periodMs: Double;
  lateMs: Double;
  raisedTimer: Boolean;
begin
  periodMs := (1000.0 * FGranted.BufferFrames) / FGranted.SampleRate;
  if periodMs <= 0 then periodMs := 1;

  { Ask for 1 ms scheduler resolution for the life of the stream (Windows 11 may
    ignore this for a background process - the yield-spin below compensates). }
  {$IFDEF UDAW_WINDOWS}
  raisedTimer := timeBeginPeriod(1) = TIMERR_NOERROR;
  {$ELSE}
  raisedTimer := False;
  {$ENDIF}
  try
    nextDueMs := MonoMs + periodMs;

    while AtomicRead32(FStopReq) = 0 do
    begin
      nowMs := MonoMs;
      { Hybrid wait: coarse Sleep(1) while far from the deadline, then a short
        yield-spin for the last ~2 ms. Windows 11 may ignore a background
        process's timeBeginPeriod request, so Sleep(1) can overshoot to ~15 ms;
        the spin keeps block cadence accurate on the fallback path. }
      if nextDueMs - nowMs > 2 then
      begin
        Sleep(1);
        Continue;
      end;
      if nextDueMs - nowMs > 0 then
      begin
        Sleep(0);
        Continue;
      end;

      lateMs := nowMs - nextDueMs;
      { count an xrun only when a whole extra block period has slipped past,
        with a little tolerance for ordinary scheduler jitter }
      if lateMs > periodMs * 1.5 then
      begin
        FStatsLock.Enter;
        try
          FStats.XRunCount := FStats.XRunCount + Trunc(lateMs / periodMs);
        finally
          FStatsLock.Leave;
        end;
        nextDueMs := nowMs + periodMs;   // resync so we do not spiral
      end
      else
        nextDueMs := nextDueMs + periodMs;

      Tick(nowMs);
    end;
  finally
    {$IFDEF UDAW_WINDOWS}
    if raisedTimer then
      timeEndPeriod(1);
    {$ENDIF}
  end;
end;

{ ---------------- TSoftwareBackend ---------------- }

constructor TSoftwareBackend.Create(APaced: Boolean);
begin
  inherited Create;
  FPacedDefault := APaced;
  FDefaultRenderChannels := 2;
  FDefaultCaptureChannels := 2;
  FDefaultRate := UDAW_DEFAULT_SAMPLE_RATE;
  FDefaultBuffer := UDAW_DEFAULT_BUFFER_FRAMES;
end;

function TSoftwareBackend.Id: TAudioBackendId;
begin
  Result := abSoftware;
end;

function TSoftwareBackend.Name: string;
begin
  Result := 'Software (portable)';
end;

function TSoftwareBackend.IsAvailable: Boolean;
begin
  Result := True;
end;

function TSoftwareBackend.EnumerateDevices(ADirection: TAudioDirection): TAudioDeviceList;
var
  d: TAudioDeviceInfo;
begin
  SetLength(Result, 1);
  FillChar(d, SizeOf(d), 0);
  d.BackendId := abSoftware;
  d.IsDefault := True;
  d.MinChannels := 1;
  d.MaxChannels := UDAW_MAX_CHANNELS;
  d.DefaultSampleRate := FDefaultRate;
  d.SupportedSampleRates := TArray<Integer>.Create(
    22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000);
  d.DefaultBufferFrames := FDefaultBuffer;
  d.MinBufferFrames := UDAW_MIN_BUFFER_FRAMES;
  d.MaxBufferFrames := UDAW_MAX_BUFFER_FRAMES;
  if ADirection = adCapture then
  begin
    d.Id := SW_CAPTURE_ID;
    d.Name := 'UDAW Software Loopback';
    d.Direction := adCapture;
  end
  else
  begin
    d.Id := SW_RENDER_ID;
    d.Name := 'UDAW Software Output';
    d.Direction := adRender;
  end;
  Result[0] := d;
end;

function TSoftwareBackend.DefaultDeviceId(ADirection: TAudioDirection): string;
begin
  if ADirection = adCapture then Result := SW_CAPTURE_ID else Result := SW_RENDER_ID;
end;

function TSoftwareBackend.OpenStream(const ARequest: TAudioStreamRequest;
  ACallback: TAudioStreamCallback): IAudioStream;
begin
  if not Assigned(ACallback) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'OpenStream: callback is nil');
  Result := TSoftwareStream.Create(Self, ARequest, ACallback, FPacedDefault);
end;

procedure TSoftwareBackend.SetDeviceChangeHandler(AHandler: TAudioStreamEvent);
begin
  FDeviceChange := AHandler;
end;

procedure TSoftwareBackend.NotifyDeviceChange(const AMessage: string);
begin
  if Assigned(FDeviceChange) then
    FDeviceChange(aseDeviceChanged, AMessage);
end;

end.
