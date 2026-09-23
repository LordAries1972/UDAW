unit UDAW.Recording.Types;
{$I udaw.inc}

{ Phase 8 - Recording: shared value types.

  No behaviour lives here - just the enums and the two records every other
  recording unit passes around: TRecordSettings (what the user configured for a
  recording pass) and TRecordedTake (what one finished pass produced on disk).

  All time-critical quantities are kept in SAMPLES at the take's own sample rate
  so the engine's punch / pre-roll / count-in / loop / latency-compensation
  arithmetic is exact and never accumulates floating-point drift. Seconds are
  offered as convenience accessors only. }

interface

uses
  SysUtils,
  UDAW.Errors,
  UDAW.Codec.WAV;

const
  RECORDING_SUBSYS = 'Recording';

  { On-disk take container. }
  REC_META_NAME       = 'take.meta';
  REC_AUDIO_NAME      = 'audio.pcm';       // raw interleaved Float32, canonical
  REC_INDEX_NAME      = 'audio.idx';       // append-only flush journal
  REC_MARKER_NAME     = 'take.inprogress'; // present until a clean Finalize
  REC_META_VERSION    = 1;

  { Writer memory ceiling: frames buffered before a forced flush to disk. This
    is the whole of a take's RAM footprint regardless of length (plan 22:
    "Never accumulate an unlimited recording entirely in RAM"). }
  REC_WRITER_FLUSH_FRAMES = 1 shl 15;   // 32768 frames

type
  { How many input channels a pass captures and how they are laid out. }
  TRecordChannelMode = (rcmMono, rcmStereo, rcmMultichannel);

  { Punch behaviour for a pass. }
  TPunchMode = (
    pmOff,        // record for the whole pass, from Start until Stop
    pmPunchIn,    // silent until the punch-in point, then record to Stop
    pmPunchInOut  // record only between the punch-in and punch-out points
  );

  { Engine state machine. }
  TRecordState = (
    rsIdle,        // not armed
    rsArmed,       // armed, transport not rolling
    rsRolling,     // transport rolling inside pre-roll / count-in, not yet writing
    rsRecording,   // writing captured audio to a take
    rsFinalizing   // Stop requested, flushing the last take
  );

  { On-disk lifecycle of a take container. }
  TTakeStatus = (tsRecording, tsFinalized, tsRecovered);

  TRecordSettings = record
    SampleRate: Integer;
    ChannelMode: TRecordChannelMode;
    Channels: Integer;              // resolved channel count (1 / 2 / N)
    TakeFormat: TWavSampleFormat;       // container format on Finalize (pcm store is always float32)
    InputMonitoring: Boolean;
    MonitorGainDb: Double;

    PreRollSeconds: Double;         // playback lead-in, not recorded
    CountInBeats: Integer;          // metronome bars/beats before recording, not recorded
    TempoBPM: Double;               // for CountIn -> samples

    PunchMode: TPunchMode;
    PunchInSeconds: Double;         // timeline seconds
    PunchOutSeconds: Double;        // timeline seconds

    LoopRecord: Boolean;
    LoopStartSeconds: Double;
    LoopEndSeconds: Double;

    { Round-trip latency to remove from a take's timeline position so what was
      played against lines up with what was recorded. }
    InputLatencyFrames: Integer;
    OutputLatencyFrames: Integer;

    class function Default: TRecordSettings; static;
    function TotalLatencyFrames: Integer;
    function CountInSamples: Int64;
    function PreRollSamples: Int64;
    procedure Validate;
    function Describe: string;
  end;

  TRecordedTake = record
    Id: string;                    // session id (folder name)
    SessionDir: string;            // absolute path of the take container
    WavFile: string;               // '' until finalised / recovered to a WAV
    Name: string;
    SampleRate: Integer;
    Channels: Integer;
    FrameCount: Int64;
    Status: TTakeStatus;
    TimelineStartSeconds: Double;  // where the take sits on the timeline (latency-compensated)
    SourceOffsetSeconds: Double;   // usually 0
    PassIndex: Integer;            // 0-based; loop recording produces 1..N per region
    StartedUTC: TDateTime;
    function LengthSeconds: Double;
    function Describe: string;
  end;

  TRecordedTakeArray = array of TRecordedTake;

function RecordChannelModeName(AMode: TRecordChannelMode): string;
function ChannelsForMode(AMode: TRecordChannelMode; AMultiCount: Integer): Integer;
function PunchModeName(AMode: TPunchMode): string;
function RecordStateName(AState: TRecordState): string;
function TakeStatusName(AStatus: TTakeStatus): string;
function TakeStatusId(AStatus: TTakeStatus): string;
function TakeStatusFromId(const AId: string; out AStatus: TTakeStatus): Boolean;

implementation

uses
  Math;

function RecordChannelModeName(AMode: TRecordChannelMode): string;
begin
  case AMode of
    rcmMono:         Result := 'Mono';
    rcmStereo:       Result := 'Stereo';
    rcmMultichannel: Result := 'Multichannel';
  else
    Result := '?';
  end;
end;

function ChannelsForMode(AMode: TRecordChannelMode; AMultiCount: Integer): Integer;
begin
  case AMode of
    rcmMono:   Result := 1;
    rcmStereo: Result := 2;
  else
    if AMultiCount < 1 then Result := 1
    else Result := AMultiCount;
  end;
end;

function PunchModeName(AMode: TPunchMode): string;
begin
  case AMode of
    pmOff:         Result := 'Off';
    pmPunchIn:     Result := 'Punch-in';
    pmPunchInOut:  Result := 'Punch in/out';
  else
    Result := '?';
  end;
end;

function RecordStateName(AState: TRecordState): string;
begin
  case AState of
    rsIdle:       Result := 'idle';
    rsArmed:      Result := 'armed';
    rsRolling:    Result := 'rolling';
    rsRecording:  Result := 'recording';
    rsFinalizing: Result := 'finalizing';
  else
    Result := '?';
  end;
end;

function TakeStatusName(AStatus: TTakeStatus): string;
begin
  case AStatus of
    tsRecording: Result := 'recording';
    tsFinalized: Result := 'finalized';
    tsRecovered: Result := 'recovered';
  else
    Result := '?';
  end;
end;

function TakeStatusId(AStatus: TTakeStatus): string;
begin
  Result := TakeStatusName(AStatus);
end;

function TakeStatusFromId(const AId: string; out AStatus: TTakeStatus): Boolean;
var
  s: TTakeStatus;
begin
  for s := Low(TTakeStatus) to High(TTakeStatus) do
    if SameText(AId, TakeStatusName(s)) then
    begin
      AStatus := s;
      Exit(True);
    end;
  Result := False;
end;

{ ================= TRecordSettings ================= }

class function TRecordSettings.Default: TRecordSettings;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.SampleRate := 48000;
  Result.ChannelMode := rcmStereo;
  Result.Channels := 2;
  Result.TakeFormat := wsfFloat32;
  Result.InputMonitoring := False;
  Result.MonitorGainDb := 0;
  Result.PreRollSeconds := 0;
  Result.CountInBeats := 0;
  Result.TempoBPM := 120;
  Result.PunchMode := pmOff;
  Result.PunchInSeconds := 0;
  Result.PunchOutSeconds := 0;
  Result.LoopRecord := False;
  Result.LoopStartSeconds := 0;
  Result.LoopEndSeconds := 0;
  Result.InputLatencyFrames := 0;
  Result.OutputLatencyFrames := 0;
end;

function TRecordSettings.TotalLatencyFrames: Integer;
begin
  Result := InputLatencyFrames + OutputLatencyFrames;
  if Result < 0 then Result := 0;
end;

function TRecordSettings.CountInSamples: Int64;
var
  beatSeconds: Double;
begin
  if (CountInBeats <= 0) or (TempoBPM <= 0) then Exit(0);
  beatSeconds := 60.0 / TempoBPM;
  Result := Round(CountInBeats * beatSeconds * SampleRate);
end;

function TRecordSettings.PreRollSamples: Int64;
begin
  if PreRollSeconds <= 0 then Exit(0);
  Result := Round(PreRollSeconds * SampleRate);
end;

procedure TRecordSettings.Validate;
begin
  if (SampleRate < 8000) or (SampleRate > 768000) then
    RaiseUDAWFmt(errInvalidArgument, RECORDING_SUBSYS,
      'sample rate %d out of range', [SampleRate]);
  if Channels < 1 then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS, 'channel count must be >= 1');
  if Channels > 32 then
    RaiseUDAWFmt(errInvalidArgument, RECORDING_SUBSYS,
      'channel count %d exceeds 32', [Channels]);
  if WavSampleFormatBytes(TakeFormat) = 0 then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS, 'unsupported take format');
  if (PunchMode = pmPunchInOut) and (PunchOutSeconds <= PunchInSeconds) then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS,
      'punch-out must be after punch-in');
  if LoopRecord and (LoopEndSeconds <= LoopStartSeconds) then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS,
      'loop end must be after loop start');
  if PreRollSeconds < 0 then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS, 'pre-roll cannot be negative');
  if CountInBeats < 0 then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS, 'count-in cannot be negative');
end;

function TRecordSettings.Describe: string;
begin
  Result := Format(
    '%d Hz  %s (%d ch)  %s  |  pre-roll %.2fs  count-in %d beat(s)  |  punch %s',
    [SampleRate, RecordChannelModeName(ChannelMode), Channels,
     WavSampleFormatName(TakeFormat), PreRollSeconds, CountInBeats,
     PunchModeName(PunchMode)]);
  if PunchMode <> pmOff then
    Result := Result + Format(' [%.3f..%.3f]', [PunchInSeconds, PunchOutSeconds]);
  if LoopRecord then
    Result := Result + Format('  |  loop-record [%.3f..%.3f]',
      [LoopStartSeconds, LoopEndSeconds]);
  if InputMonitoring then
    Result := Result + Format('  |  monitor %.1f dB', [MonitorGainDb]);
  if TotalLatencyFrames > 0 then
    Result := Result + Format('  |  latency comp %d frames', [TotalLatencyFrames]);
end;

{ ================= TRecordedTake ================= }

function TRecordedTake.LengthSeconds: Double;
begin
  if SampleRate > 0 then
    Result := FrameCount / SampleRate
  else
    Result := 0;
end;

function TRecordedTake.Describe: string;
begin
  Result := Format('take "%s"  pass %d  %s  %d ch @ %d Hz  %d frames (%.3f s)  @ %.3f s  [%s]',
    [Name, PassIndex, Id, Channels, SampleRate, FrameCount, LengthSeconds,
     TimelineStartSeconds, TakeStatusName(Status)]);
end;

end.
