unit UDAW.Voice.Capture;
{$I udaw.inc}

{ Phase 25 - the "listen" step of the voice pipeline. Captures a fixed
  duration of the audio engine's live input to a mono/multichannel 16-bit
  WAV file, reusing the Phase 2 capture-ring hook (TAudioEngine.
  SetCaptureRing - present since Phase 2 but, until this unit, never
  actually wired up to a consumer; Phase 8's recording engine has its own
  ProcessCapturePlanar/ProcessCaptureBlock feed instead) and the Phase 6
  WAV writer (SaveWavFile) to persist the result - no new capture or codec
  path, just draining that existing ring to a file for a short one-shot
  grab instead of a transport-synced multitrack take. }

interface

uses
  UDAW.Audio.Engine, UDAW.Audio.Types, UDAW.Audio.Ring;

{ Blocks the calling thread for approximately ADurationSeconds while
  draining AEngine's capture ring to AWavPath. AEngine must already be open
  with a capture-capable stream (Granted.CaptureChannels > 0) - typically
  true right after TAudioEngine.Open on a full-duplex device.

  Returns False (without raising) if no capture frames arrived at all
  within a generous safety deadline - e.g. the device has no input, or the
  engine isn't running - since "no microphone available" is an expected,
  recoverable condition for the caller to report, not a bug. }
function CaptureVoiceToWavFile(AEngine: TAudioEngine; const AWavPath: string;
  ADurationSeconds: Double): Boolean;

{ Start/Poll/Stop capture at the engine's native channel count and sample
  rate - no downmix/resample, unlike CaptureVoiceToWavFile above (that one
  trades fidelity for what System.Speech's recognizer accepts; this one is
  for reference-quality recordings, e.g. the AI tab's Suno Recordings list).
  Poll must be called periodically (a UI timer tick is fine) while recording
  is in progress - it just drains whatever the ring currently holds, so it
  never blocks and is safe to call from the UI thread. }
type
  TLiveCapture = class
  private
    FEngine: TAudioEngine;
    FRing: TAudioRing;
    FChannels, FSampleRate: Integer;
    FAccum: TAudioSampleArray; // interleaved
    FFrames: Integer;
    FScratch: TAudioSampleArray;
  public
    constructor Create(AEngine: TAudioEngine; AMaxSeconds: Double = 900.0);
    destructor Destroy; override;
    procedure Poll;
    function DurationSeconds: Double;
    { Detaches from the engine and saves whatever was captured. Returns False
      (without raising, WAV not written) if nothing was ever captured. }
    function SaveAndStop(const AWavPath: string): Boolean;
    property Channels: Integer read FChannels;
    property SampleRate: Integer read FSampleRate;
  end;

implementation

uses
  SysUtils, DateUtils, Math,
  UDAW.Errors, UDAW.Codec.WAV, UDAW.DSP.Resampler;

const
  SUBSYS = 'Voice.Capture';
  { System.Speech's SpeechRecognitionEngine.SetInputToWaveFile only accepts a
    narrow set of PCM formats (mono, 16-bit, one of a handful of "telephone/
    radio quality" sample rates) - anything else, e.g. the stereo/48kHz format
    a typical audio interface negotiates, fails with COMException "One of the
    identified items was in an invalid format." So the voice-command WAV is
    always downmixed to mono and resampled to this rate before it is handed
    to TranscribeWavFile, regardless of what the engine's input device is
    actually running at. }
  VOICE_RECO_SAMPLE_RATE = 16000;

function CaptureVoiceToWavFile(AEngine: TAudioEngine; const AWavPath: string;
  ADurationSeconds: Double): Boolean;
var
  channels, sampleRate, totalFrames, gotFrames, chunkFrames, n: Integer;
  ring: TAudioRing;
  scratch, accum: TAudioSampleArray;
  planar, mono, reco: TAudioPlanar;
  ch, f: Integer;
  started: TDateTime;
  deadlineMs: Integer;
  acc: Single;
begin
  if AEngine = nil then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'no audio engine');

  channels := AEngine.Granted.CaptureChannels;
  sampleRate := AEngine.Granted.SampleRate;
  if channels <= 0 then channels := 1;
  if sampleRate <= 0 then sampleRate := 48000;
  if ADurationSeconds <= 0 then ADurationSeconds := 0.1;

  totalFrames := Round(ADurationSeconds * sampleRate);
  chunkFrames := sampleRate div 20; // ~50ms polls
  if chunkFrames < 256 then chunkFrames := 256;

  ring := TAudioRing.Create(channels, totalFrames + sampleRate);
  AEngine.SetCaptureRing(ring);
  try
    SetLength(scratch, chunkFrames * channels);
    SetLength(accum, totalFrames * channels);
    gotFrames := 0;
    started := Now;
    deadlineMs := Round(ADurationSeconds * 1000) + 5000; // generous safety margin
    while (gotFrames < totalFrames) and (MilliSecondsBetween(Now, started) < deadlineMs) do
    begin
      Sleep(20);
      n := ring.ReadFrames(scratch[0], Min(chunkFrames, totalFrames - gotFrames), False);
      if n > 0 then
      begin
        Move(scratch[0], accum[gotFrames * channels], n * channels * SizeOf(Single));
        Inc(gotFrames, n);
      end;
    end;
  finally
    AEngine.SetCaptureRing(nil);
    ring.Free;
  end;

  if gotFrames <= 0 then Exit(False);

  SetLength(planar, channels);
  for ch := 0 to channels - 1 do
    SetLength(planar[ch], gotFrames);
  for f := 0 to gotFrames - 1 do
    for ch := 0 to channels - 1 do
      planar[ch][f] := accum[f * channels + ch];

  { downmix to mono - speech recognizers reject multichannel input }
  SetLength(mono, 1);
  SetLength(mono[0], gotFrames);
  if channels = 1 then
    mono[0] := Copy(planar[0], 0, gotFrames)
  else
    for f := 0 to gotFrames - 1 do
    begin
      acc := 0;
      for ch := 0 to channels - 1 do
        acc := acc + planar[ch][f];
      mono[0][f] := acc / channels;
    end;

  { resample to a rate System.Speech's SetInputToWaveFile actually accepts }
  if sampleRate <> VOICE_RECO_SAMPLE_RATE then
    reco := ResamplePlanar(mono, gotFrames, sampleRate, VOICE_RECO_SAMPLE_RATE, rqSinc)
  else
    reco := mono;

  SaveWavFile(AWavPath, reco, 1, VOICE_RECO_SAMPLE_RATE, Length(reco[0]), wsfPCM16, False);
  Result := True;
end;

constructor TLiveCapture.Create(AEngine: TAudioEngine; AMaxSeconds: Double);
var
  chunkFrames: Integer;
begin
  inherited Create;
  if AEngine = nil then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'no audio engine');
  FEngine := AEngine;
  FChannels := AEngine.Granted.CaptureChannels;
  FSampleRate := AEngine.Granted.SampleRate;
  if FChannels <= 0 then FChannels := 1;
  if FSampleRate <= 0 then FSampleRate := 48000;
  if AMaxSeconds <= 0 then AMaxSeconds := 900.0;

  chunkFrames := FSampleRate div 2; // drained well before this fills at any sane poll interval
  SetLength(FScratch, chunkFrames * FChannels);
  FFrames := 0;
  SetLength(FAccum, 0);

  FRing := TAudioRing.Create(FChannels, Round(AMaxSeconds * FSampleRate));
  FEngine.SetCaptureRing(FRing);
end;

destructor TLiveCapture.Destroy;
begin
  if FRing <> nil then
  begin
    FEngine.SetCaptureRing(nil);
    FRing.Free;
  end;
  inherited Destroy;
end;

procedure TLiveCapture.Poll;
var
  n, chunkFrames: Integer;
begin
  if FRing = nil then Exit;
  chunkFrames := Length(FScratch) div FChannels;
  repeat
    n := FRing.ReadFrames(FScratch[0], chunkFrames, False);
    if n > 0 then
    begin
      SetLength(FAccum, (FFrames + n) * FChannels);
      Move(FScratch[0], FAccum[FFrames * FChannels], n * FChannels * SizeOf(Single));
      Inc(FFrames, n);
    end;
  until n < chunkFrames;
end;

function TLiveCapture.DurationSeconds: Double;
begin
  Result := FFrames / FSampleRate;
end;

function TLiveCapture.SaveAndStop(const AWavPath: string): Boolean;
var
  planar: TAudioPlanar;
  ch, f: Integer;
begin
  Poll; // final drain before detaching
  FEngine.SetCaptureRing(nil);
  FreeAndNil(FRing);
  Result := FFrames > 0;
  if not Result then Exit;

  SetLength(planar, FChannels);
  for ch := 0 to FChannels - 1 do
    SetLength(planar[ch], FFrames);
  for f := 0 to FFrames - 1 do
    for ch := 0 to FChannels - 1 do
      planar[ch][f] := FAccum[f * FChannels + ch];

  SaveWavFile(AWavPath, planar, FChannels, FSampleRate, FFrames, wsfPCM16, False);
end;

end.
