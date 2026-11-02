unit UDAW.Recording.Writer;
{$I udaw.inc}

{ Phase 8 - Recording: the dedicated Recording Writer Thread (plan section 53
  "Recommended logical threads ... Recording Writer Thread"; section 22
  "Recording must use disk streaming").

  The real-time audio capture callback does exactly one thing with the input it
  is handed: TAudioRing.WriteFrames (wait-free, no allocation, no disk). This
  thread is the consumer: it blocks on a signal, drains the ring in
  bounded-size chunks, and calls TRecordingEngine.ProcessCaptureBlock - which is
  where the punch / loop / latency logic runs and where TRecordingChunkWriter
  streams the bytes to disk. Nothing between the callback and the platter ever
  holds more than one drain chunk plus the engine's REC_WRITER_FLUSH_FRAMES
  staging buffer.

  Stop() drains whatever is still in the ring before the thread exits, so the
  tail of a take is never lost. Disk errors are caught, counted and exposed via
  LastError rather than crashing the audio path. }

interface

uses
  SysUtils, Classes,
  UDAW.Errors, UDAW.Threading, UDAW.Audio.Types, UDAW.Audio.Ring,
  UDAW.Recording.Types, UDAW.Recording.Engine;

const
  REC_DRAIN_CHUNK_FRAMES = 4096;
  REC_WRITER_IDLE_WAIT_MS = 20;

type
  TRecordingWriterThread = class(TUDAWThread)
  private
    FEngine: TRecordingEngine;
    FRing: TAudioRing;
    FChannels: Integer;
    FWake: TUDAWSignal;
    FStopRequested: Integer;
    FFramesConsumed: Int64;
    FDrainCalls: Int64;
    FErrorCount: Integer;
    FLastError: string;
    FLastErrorLock: TUDAWLock;
    FScratch: TAudioSampleArray;
    function DrainOnce: Integer;      // frames pulled this call
    procedure NoteError(const AWhat: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AEngine: TRecordingEngine; ARing: TAudioRing);
    destructor Destroy; override;

    { Nudge the thread to drain now (call after the capture callback has written
      to the ring). Safe from the audio thread - just sets an event. }
    procedure Nudge;
    { Cooperative stop: signals the thread, waits for it to drain the ring and
      exit. Safe to call once. }
    procedure Stop;

    function FramesConsumed: Int64;
    function DrainCalls: Int64;
    function RingOverruns: Integer;
    function ErrorCount: Integer;
    function LastError: string;
  end;

implementation

constructor TRecordingWriterThread.Create(AEngine: TRecordingEngine; ARing: TAudioRing);
begin
  if AEngine = nil then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS, 'writer thread: nil engine');
  if ARing = nil then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS, 'writer thread: nil ring');
  FEngine := AEngine;
  FRing := ARing;
  FChannels := ARing.Channels;
  FWake := TUDAWSignal.Create(False, False);
  FLastErrorLock := TUDAWLock.Create('rec-writer-err');
  SetLength(FScratch, REC_DRAIN_CHUNK_FRAMES * FChannels);
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TRecordingWriterThread.Destroy;
begin
  Stop;
  FWake.Free;
  FLastErrorLock.Free;
  inherited Destroy;
end;

procedure TRecordingWriterThread.NoteError(const AWhat: string);
begin
  FLastErrorLock.Enter;
  try
    FLastError := AWhat;
  finally
    FLastErrorLock.Leave;
  end;
  AtomicInc32(FErrorCount);
end;

function TRecordingWriterThread.DrainOnce: Integer;
var
  got: Integer;
begin
  Result := 0;
  got := FRing.ReadFrames(FScratch[0], REC_DRAIN_CHUNK_FRAMES, {ZeroPad=} False);
  if got <= 0 then Exit;
  Inc(FDrainCalls);
  try
    FEngine.ProcessCaptureBlock(FScratch[0], got);
  except
    on E: Exception do
      NoteError(E.Message);
  end;
  Inc(FFramesConsumed, got);
  Result := got;
end;

procedure TRecordingWriterThread.Execute;
begin
  {$IFDEF FPC}NameThreadForDebugging('udaw-rec-writer');
  {$ELSE}TThread.NameThreadForDebugging('udaw-rec-writer');{$ENDIF}
  while AtomicRead32(FStopRequested) = 0 do
  begin
    FWake.Wait(REC_WRITER_IDLE_WAIT_MS);
    while DrainOnce > 0 do
      ;   // keep draining until the ring is empty
  end;
  { final drain so the tail of the take reaches disk }
  while DrainOnce > 0 do
    ;
  try
    FEngine.Stop;
  except
    on E: Exception do NoteError(E.Message);
  end;
end;

procedure TRecordingWriterThread.Nudge;
begin
  FWake.Signal;
end;

procedure TRecordingWriterThread.Stop;
begin
  if AtomicRead32(FStopRequested) <> 0 then
  begin
    if not Finished then WaitFor;
    Exit;
  end;
  AtomicSet32(FStopRequested, 1);
  FWake.Signal;
  WaitFor;
end;

function TRecordingWriterThread.FramesConsumed: Int64;
begin
  Result := FFramesConsumed;
end;

function TRecordingWriterThread.DrainCalls: Int64;
begin
  Result := FDrainCalls;
end;

function TRecordingWriterThread.RingOverruns: Integer;
begin
  Result := FRing.Overruns;
end;

function TRecordingWriterThread.ErrorCount: Integer;
begin
  Result := AtomicRead32(FErrorCount);
end;

function TRecordingWriterThread.LastError: string;
begin
  FLastErrorLock.Enter;
  try
    Result := FLastError;
  finally
    FLastErrorLock.Leave;
  end;
end;

end.
