unit UDAW.Recording.Engine;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 8 - Recording: the capture orchestrator (plan section 22).

  TRecordingEngine turns a stream of captured input blocks into one or more
  take containers on disk, applying, with sample accuracy:

    * pre-roll        - transport rolls, nothing is written, for context
    * count-in        - N metronome beats before the record gate can open
    * punch-in / -out  - record only inside a timeline window
    * loop recording   - each pass over the loop range becomes its own take
    * latency compensation - each take's timeline position is pulled earlier by
                             the round-trip I/O latency so it lines up with what
                             was played against it
    * input monitoring  - ApplyMonitorMix folds the live input into an output
                          block at the configured monitor gain

  The engine never buffers audio itself - every captured frame is handed
  straight to a TRecordingChunkWriter (REC_WRITER_FLUSH_FRAMES-bounded RAM,
  disk-streamed). It is GUI-free and clock-free: ProcessCaptureBlock advances an
  internal transport counter by exactly the frames it is given, so the same code
  drives a live capture ring and a deterministic offline test. }

interface

uses
  SysUtils, Classes, Math, Generics.Collections,
  UDAW.Errors, UDAW.Audio.Types,
  UDAW.Codec.WAV,
  UDAW.Recording.Types, UDAW.Recording.ChunkFile;

type
  TRecordingTakeEvent = procedure(ASender: TObject; const ATake: TRecordedTake) of object;

  TRecordingEngine = class
  private
    FRecordingRoot: string;
    FSettings: TRecordSettings;
    FState: TRecordState;

    FTransportSamples: Int64;      // frames since Start
    FStartTimelineSamples: Int64;  // timeline position (frames) at transport = 0
    FLeadInSamples: Int64;         // pre-roll + count-in

    FPunchInSamples: Int64;
    FPunchOutSamples: Int64;
    FLoopStartSamples: Int64;
    FLoopEndSamples: Int64;

    FWriter: TRecordingChunkWriter;
    FCurrentPass: Integer;
    FSessionStamp: string;

    FTakes: TList<TRecordedTake>;
    FLastGateOpen: Boolean;

    FScratch: TAudioSampleArray;   // planar -> interleaved staging

    FOnTakeStarted: TRecordingTakeEvent;
    FOnTakeFinished: TRecordingTakeEvent;

    procedure RecomputeSampleWindows;
    function GateAt(ATransportSample: Int64; out AWrappedTimelineSample: Int64;
      out APass: Integer): Boolean;
    procedure OpenTake(AWrappedTimelineSample: Int64; APass: Integer);
    procedure FinishTake;
    procedure WriteRunInterleaved(const ABlock; AStartFrame, AFrameCount, AChannels: Integer);
  public
    constructor Create(const ARecordingRoot: string);
    destructor Destroy; override;

    procedure Configure(const ASettings: TRecordSettings);
    procedure Arm;
    procedure Disarm;

    { Begin rolling the transport with the timeline playhead at APlayheadSeconds.
      Requires the engine to be armed. }
    procedure Start(APlayheadSeconds: Double);

    { Feed one block of captured input. Interleaved Float32, Settings.Channels
      channels. Advances the transport by AFrames and writes whatever falls
      inside the record gate to the current take. }
    procedure ProcessCaptureBlock(const AInterleaved; AFrames: Integer);
    procedure ProcessCapturePlanar(const ASrc: TAudioPlanar; AFrames: Integer);

    { Stop: finish the current take (if any) and return to rsArmed. }
    procedure Stop;

    { Input monitoring: add the just-captured block into ADst (interleaved,
      ADstChannels channels) at the configured monitor gain. No-op when
      InputMonitoring is off. Channels are mapped up to min(src, dst). }
    procedure ApplyMonitorMix(const ACapturedInterleaved; AFrames, ACaptureChannels: Integer;
      var ADstInterleaved; ADstChannels: Integer);

    function State: TRecordState;
    function TransportSeconds: Double;
    function TransportSamples: Int64;
    function RecordGateOpen: Boolean;
    function CurrentTakeFrames: Int64;
    function TakeCount: Integer;
    function GetTake(AIndex: Integer): TRecordedTake;
    function LastTake: TRecordedTake;
    procedure ClearTakes;

    function Describe: string;

    property Settings: TRecordSettings read FSettings;
    property RecordingRoot: string read FRecordingRoot;
    property OnTakeStarted: TRecordingTakeEvent read FOnTakeStarted write FOnTakeStarted;
    property OnTakeFinished: TRecordingTakeEvent read FOnTakeFinished write FOnTakeFinished;
  end;

implementation

{ ================= TRecordingEngine ================= }

constructor TRecordingEngine.Create(const ARecordingRoot: string);
begin
  inherited Create;
  if Trim(ARecordingRoot) = '' then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS, 'recording root path is empty');
  FRecordingRoot := ExcludeTrailingPathDelimiter(ARecordingRoot);
  FSettings := TRecordSettings.Default;
  FState := rsIdle;
  FTakes := TList<TRecordedTake>.Create;
end;

destructor TRecordingEngine.Destroy;
begin
  { a live take on teardown is abandoned, not finalised - recovery can offer it }
  FWriter.Free;
  FTakes.Free;
  inherited Destroy;
end;

procedure TRecordingEngine.Configure(const ASettings: TRecordSettings);
var
  s: TRecordSettings;
begin
  if FState in [rsRolling, rsRecording, rsFinalizing] then
    RaiseUDAW(errInvalidState, RECORDING_SUBSYS,
      'cannot reconfigure while the transport is rolling');
  s := ASettings;
  s.Validate;
  FSettings := s;
end;

procedure TRecordingEngine.Arm;
begin
  FSettings.Validate;
  if FState = rsIdle then
    FState := rsArmed;
end;

procedure TRecordingEngine.Disarm;
begin
  if FState in [rsRolling, rsRecording] then
    Stop;
  FState := rsIdle;
end;

procedure TRecordingEngine.RecomputeSampleWindows;
var
  sr: Integer;
begin
  sr := FSettings.SampleRate;
  FLeadInSamples := FSettings.PreRollSamples + FSettings.CountInSamples;
  FPunchInSamples := Round(FSettings.PunchInSeconds * sr);
  FPunchOutSamples := Round(FSettings.PunchOutSeconds * sr);
  FLoopStartSamples := Round(FSettings.LoopStartSeconds * sr);
  FLoopEndSamples := Round(FSettings.LoopEndSeconds * sr);
end;

procedure TRecordingEngine.Start(APlayheadSeconds: Double);
var
  id: TGUID;
begin
  if FState <> rsArmed then
    RaiseUDAW(errInvalidState, RECORDING_SUBSYS, 'Start requires the engine to be armed');
  FSettings.Validate;
  RecomputeSampleWindows;

  FTransportSamples := 0;
  FStartTimelineSamples := Round(APlayheadSeconds * FSettings.SampleRate);
  if FStartTimelineSamples < 0 then FStartTimelineSamples := 0;
  FCurrentPass := 0;
  FLastGateOpen := False;
  FSessionStamp := FormatDateTime('yyyymmdd"-"hhnnss"-"zzz', Now);
  CreateGUID(id);
  FSessionStamp := FSessionStamp + '-' + GUIDToString(id);
  FState := rsRolling;
end;

function TRecordingEngine.GateAt(ATransportSample: Int64;
  out AWrappedTimelineSample: Int64; out APass: Integer): Boolean;
var
  raw, loopLen, over: Int64;
  gate: Boolean;
begin
  raw := FStartTimelineSamples + ATransportSample;
  APass := 0;
  AWrappedTimelineSample := raw;

  if FSettings.LoopRecord then
  begin
    loopLen := FLoopEndSamples - FLoopStartSamples;
    if (loopLen > 0) and (raw >= FLoopEndSamples) then
    begin
      over := raw - FLoopStartSamples;
      APass := over div loopLen;
      AWrappedTimelineSample := FLoopStartSamples + (over mod loopLen);
    end;
  end;

  gate := ATransportSample >= FLeadInSamples;
  case FSettings.PunchMode of
    pmPunchIn:
      gate := gate and (AWrappedTimelineSample >= FPunchInSamples);
    pmPunchInOut:
      gate := gate and (AWrappedTimelineSample >= FPunchInSamples) and
                       (AWrappedTimelineSample < FPunchOutSamples);
  end;
  Result := gate;
end;

procedure TRecordingEngine.OpenTake(AWrappedTimelineSample: Int64; APass: Integer);
var
  dir: string;
  startSamples: Int64;
  nm: string;
  started: TRecordedTake;
begin
  startSamples := AWrappedTimelineSample - FSettings.TotalLatencyFrames;
  if startSamples < 0 then startSamples := 0;

  dir := IncludeTrailingPathDelimiter(FRecordingRoot) +
    Format('%s-t%d', [FSessionStamp, APass]);
  if APass > 0 then
    nm := Format('Take %s (pass %d)', [FSessionStamp, APass + 1])
  else
    nm := Format('Take %s', [FSessionStamp]);

  FWriter := TRecordingChunkWriter.Create(dir, FSettings.SampleRate,
    FSettings.Channels, nm, startSamples / FSettings.SampleRate, APass, 0);
  FCurrentPass := APass;
  FState := rsRecording;

  if Assigned(FOnTakeStarted) then
  begin
    FillChar(started, SizeOf(started), 0);
    started.Id := ExtractFileName(FWriter.SessionDir);
    started.SessionDir := FWriter.SessionDir;
    started.Name := FWriter.Name;
    started.SampleRate := FWriter.SampleRate;
    started.Channels := FWriter.Channels;
    started.Status := tsRecording;
    started.TimelineStartSeconds := FWriter.TimelineStartSeconds;
    started.PassIndex := FWriter.PassIndex;
    started.StartedUTC := Now;
    FOnTakeStarted(Self, started);
  end;
end;

procedure TRecordingEngine.FinishTake;
var
  reader: TRecordingChunkReader;
  take: TRecordedTake;
  wavPath, sessionDir: string;
begin
  if FWriter = nil then Exit;

  FWriter.Finalize(True);
  sessionDir := FWriter.SessionDir;
  { release the writer's exclusive file handles before the reader re-opens them }
  FreeAndNil(FWriter);

  wavPath := IncludeTrailingPathDelimiter(sessionDir) + 'take.wav';
  reader := TRecordingChunkReader.Create(sessionDir);
  try
    reader.FinalizeToWav(wavPath, FSettings.TakeFormat);
    DeleteFile(ChunkMarkerPath(sessionDir));
    take := reader.ToRecordedTake;
  finally
    reader.Free;
  end;
  take.WavFile := wavPath;
  take.Status := tsFinalized;

  FTakes.Add(take);
  if Assigned(FOnTakeFinished) then
    FOnTakeFinished(Self, take);
end;

procedure TRecordingEngine.WriteRunInterleaved(const ABlock; AStartFrame,
  AFrameCount, AChannels: Integer);
var
  p: PSingle;
begin
  if (FWriter = nil) or (AFrameCount <= 0) then Exit;
  p := PSingle(@ABlock);
  Inc(p, Int64(AStartFrame) * AChannels);
  FWriter.WriteInterleaved(p^, AFrameCount);
end;

procedure TRecordingEngine.ProcessCaptureBlock(const AInterleaved; AFrames: Integer);
var
  i: Integer;
  gateOpen: Boolean;
  wrapped: Int64;
  pass: Integer;
  runStart: Integer;
  runPass: Integer;
  runOpen: Boolean;

  procedure FlushRun(AEndExclusive: Integer);
  begin
    if runOpen and (AEndExclusive > runStart) then
      WriteRunInterleaved(AInterleaved, runStart, AEndExclusive - runStart, FSettings.Channels);
  end;

begin
  if AFrames <= 0 then Exit;
  if not (FState in [rsRolling, rsRecording]) then
  begin
    { still advance nothing - the engine is idle/armed/finalizing }
    Exit;
  end;

  runOpen := (FState = rsRecording) and (FWriter <> nil);
  runStart := 0;
  if runOpen then runPass := FCurrentPass else runPass := -1;

  for i := 0 to AFrames - 1 do
  begin
    gateOpen := GateAt(FTransportSamples + i, wrapped, pass);

    if gateOpen and (FWriter = nil) then
    begin
      { gate just opened - open a take starting at this frame }
      FlushRun(i);
      OpenTake(wrapped, pass);
      runOpen := True;
      runStart := i;
      runPass := pass;
    end
    else if gateOpen and (pass <> runPass) and (FWriter <> nil) then
    begin
      { loop wrap while recording - close this pass, open the next }
      FlushRun(i);
      FinishTake;
      OpenTake(wrapped, pass);
      runOpen := True;
      runStart := i;
      runPass := pass;
    end
    else if (not gateOpen) and (FWriter <> nil) then
    begin
      { gate closed (punch-out / past loop end with no wrap) }
      FlushRun(i);
      FinishTake;
      runOpen := False;
      FState := rsRolling;
    end;
  end;

  FlushRun(AFrames);
  Inc(FTransportSamples, AFrames);
  FLastGateOpen := GateAt(FTransportSamples - 1, wrapped, pass) and (FWriter <> nil);
end;

procedure TRecordingEngine.ProcessCapturePlanar(const ASrc: TAudioPlanar; AFrames: Integer);
var
  frame, ch, k: Integer;
begin
  if AFrames <= 0 then Exit;
  if Length(ASrc) < FSettings.Channels then
    RaiseUDAWFmt(errInvalidArgument, RECORDING_SUBSYS,
      'ProcessCapturePlanar: %d channels supplied, need %d',
      [Length(ASrc), FSettings.Channels]);
  if Length(FScratch) < Int64(AFrames) * FSettings.Channels then
    SetLength(FScratch, Int64(AFrames) * FSettings.Channels);
  k := 0;
  for frame := 0 to AFrames - 1 do
    for ch := 0 to FSettings.Channels - 1 do
    begin
      FScratch[k] := ASrc[ch][frame];
      Inc(k);
    end;
  ProcessCaptureBlock(FScratch[0], AFrames);
end;

procedure TRecordingEngine.Stop;
begin
  if FWriter <> nil then
  begin
    FState := rsFinalizing;
    FinishTake;
  end;
  if FState <> rsIdle then
    FState := rsArmed;
end;

procedure TRecordingEngine.ApplyMonitorMix(const ACapturedInterleaved; AFrames,
  ACaptureChannels: Integer; var ADstInterleaved; ADstChannels: Integer);
var
  src, dst: PSingle;
  g, mono: Single;
  frame, ch, mapCh: Integer;
begin
  if not FSettings.InputMonitoring then Exit;
  if (AFrames <= 0) or (ACaptureChannels <= 0) or (ADstChannels <= 0) then Exit;
  g := DbToLinear(FSettings.MonitorGainDb);
  src := PSingle(@ACapturedInterleaved);
  dst := PSingle(@ADstInterleaved);
  mapCh := Min(ACaptureChannels, ADstChannels);
  for frame := 0 to AFrames - 1 do
  begin
    mono := src^;   // first source channel of this frame
    for ch := 0 to ADstChannels - 1 do
    begin
      if ch < mapCh then
        dst^ := dst^ + (src + ch)^ * g
      else if ACaptureChannels = 1 then
        dst^ := dst^ + mono * g;
      Inc(dst);
    end;
    Inc(src, ACaptureChannels);
  end;
end;

function TRecordingEngine.State: TRecordState;
begin
  Result := FState;
end;

function TRecordingEngine.TransportSeconds: Double;
begin
  if FSettings.SampleRate > 0 then
    Result := FTransportSamples / FSettings.SampleRate
  else
    Result := 0;
end;

function TRecordingEngine.TransportSamples: Int64;
begin
  Result := FTransportSamples;
end;

function TRecordingEngine.RecordGateOpen: Boolean;
begin
  Result := (FState = rsRecording) and (FWriter <> nil);
end;

function TRecordingEngine.CurrentTakeFrames: Int64;
begin
  if FWriter <> nil then Result := FWriter.FramesWritten else Result := 0;
end;

function TRecordingEngine.TakeCount: Integer;
begin
  Result := FTakes.Count;
end;

function TRecordingEngine.GetTake(AIndex: Integer): TRecordedTake;
begin
  Result := FTakes[AIndex];
end;

function TRecordingEngine.LastTake: TRecordedTake;
begin
  if FTakes.Count = 0 then
    RaiseUDAW(errInvalidState, RECORDING_SUBSYS, 'no takes recorded yet');
  Result := FTakes[FTakes.Count - 1];
end;

procedure TRecordingEngine.ClearTakes;
begin
  FTakes.Clear;
end;

function TRecordingEngine.Describe: string;
var
  i: Integer;
begin
  Result := Format('recording engine: state=%s  transport=%.3f s  takes=%d'#10 +
    '  settings: %s',
    [RecordStateName(FState), TransportSeconds, FTakes.Count, FSettings.Describe]);
  for i := 0 to FTakes.Count - 1 do
    Result := Result + #10 + '  ' + FTakes[i].Describe;
  if FWriter <> nil then
    Result := Result + #10 + Format('  * live take: %d frames -> %s',
      [FWriter.FramesWritten, FWriter.SessionDir]);
end;

end.
