unit UDAW.Codec.MP3.Source;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 15 follow-up - a real IAudioSource for MP3 so a Layer III file can be
  auditioned through the audio engine and scrubbed from an arbitrary position,
  instead of only being decoded to a one-shot buffer by the UI.

  TMP3StreamSource decodes the file through the incremental TMP3StreamDecoder
  (so the reservoir + IMDCT-overlap pre-roll seek path is what actually runs)
  during Prepare - off the real-time thread, exactly where TWavPlayerSource
  loads its file - then serves frames from memory.  Render is allocation-free,
  lock-free and IO-free, adapts the file's sample rate to the buffer's with the
  same linear interpolation TWavPlayerSource uses, and honours SeekSeconds /
  SeekFrames issued from any thread (the new read position is picked up on the
  next Render).

  A future low-memory variant can drive TMP3StreamDecoder from a feeder thread
  into a TAudioRing; the decoder already supports frame-at-a-time pull and
  reservoir-correct SeekToSample for that. }

interface

uses
  SysUtils, Classes, Math,
  UDAW.Errors, UDAW.Threading, UDAW.Audio.Types, UDAW.Audio.Buffer,
  UDAW.Audio.Source, UDAW.Codec.MP3.Decoder, UDAW.Codec.WAV;

type
  TMP3StreamSource = class(TInterfacedObject, IAudioSource)
  private
    FName: string;
    FData: TAudioPlanar;      // [ch][frame] at FSrcRate, fully decoded
    FSrcFrames: Integer;
    FSrcChannels: Integer;
    FSrcRate: Integer;
    FLoop: Boolean;
    FPos: Double;             // fractional read position, in source frames
    FEngineRate: Integer;     // device/output rate from Prepare (authoritative)
    FSeekReqFrame: Integer;   // pending absolute source frame (guarded by flag)
    FSeekPending: Integer;    // 0/1, set by SeekFrames, cleared by Render
    FAtEnd: Boolean;
    procedure DecodeAll(const AData: TBytes);
  public
    { AData / AFileName is sniffed, not trusted by extension, by the decoder. }
    constructor CreateFromData(const AData: TBytes; ALoop: Boolean = False);
    constructor CreateFromFile(const AFileName: string; ALoop: Boolean = False);

    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;

    { Jump the read head.  Safe to call from the UI thread while Render runs on
      the audio thread; the move is applied at the top of the next Render. }
    procedure SeekSeconds(ASeconds: Double);
    procedure SeekFrames(AFrame: Int64);

    property AtEnd: Boolean read FAtEnd;
    property Loop: Boolean read FLoop write FLoop;
    property SourceFrames: Integer read FSrcFrames;
    property SourceChannels: Integer read FSrcChannels;
    property SourceRate: Integer read FSrcRate;
    property EngineRate: Integer read FEngineRate;
    function PositionSeconds: Double;
    function DurationSeconds: Double;

    { diagnostic: write the fully-decoded PCM (exactly what Render reads from,
      before any rate adaptation) to a Float32 WAV.  AMaxFrames <= 0 writes the
      whole file; otherwise only the first AMaxFrames frames. }
    procedure SaveDecodedWav(const AFileName: string; AMaxFrames: Integer = 0);
  end;

implementation

const
  SRC_SUBSYS = 'Codec.MP3.Source';

{ ---------------------------------------------------------------- }

constructor TMP3StreamSource.CreateFromData(const AData: TBytes; ALoop: Boolean);
begin
  inherited Create;
  FLoop := ALoop;
  DecodeAll(AData);
end;

constructor TMP3StreamSource.CreateFromFile(const AFileName: string; ALoop: Boolean);
var
  fs: TFileStream;
  data: TBytes;
begin
  inherited Create;
  FLoop := ALoop;
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, SRC_SUBSYS, 'MP3 file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(data, fs.Size);
    if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
  finally
    fs.Free;
  end;
  DecodeAll(data);
  FName := Format('mp3 "%s" (%d Hz, %d ch, %d frames)',
    [ExtractFileName(AFileName), FSrcRate, FSrcChannels, FSrcFrames]);
end;

procedure TMP3StreamSource.DecodeAll(const AData: TBytes);
var
  dec: TMP3StreamDecoder;
  frame: TAudioPlanar;
  ch, i, produced: Integer;
  outPos, capacity: Int64;
begin
  dec := TMP3StreamDecoder.Create;
  try
    dec.Open(AData);
    FSrcChannels := dec.Channels;
    FSrcRate := dec.SampleRate;

    capacity := dec.TotalSamples + 4608;
    if capacity < 4608 then capacity := 4608;
    SetLength(FData, FSrcChannels);
    for ch := 0 to FSrcChannels - 1 do
      SetLength(FData[ch], capacity);

    SetLength(frame, FSrcChannels);
    for ch := 0 to FSrcChannels - 1 do
      SetLength(frame[ch], MP3_MAX_FRAME_SAMPLES);

    outPos := 0;
    while dec.DecodeNext(frame, produced) do
    begin
      if produced <= 0 then Continue;
      if outPos + produced > capacity then
      begin
        capacity := outPos + produced + 8192;
        for ch := 0 to FSrcChannels - 1 do
          SetLength(FData[ch], capacity);
      end;
      for ch := 0 to FSrcChannels - 1 do
        for i := 0 to produced - 1 do
          FData[ch][outPos + i] := frame[ch][i];
      Inc(outPos, produced);
    end;

    for ch := 0 to FSrcChannels - 1 do
      SetLength(FData[ch], outPos);
    FSrcFrames := outPos;
  finally
    dec.Free;
  end;

  if FName = '' then
    FName := Format('mp3 stream (%d Hz, %d ch, %d frames)',
      [FSrcRate, FSrcChannels, FSrcFrames]);
  Reset;
end;

procedure TMP3StreamSource.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  { file already resident; Render adapts the rate.  Capture the engine/device
    rate handed in here - it is the authoritative output rate and does not
    depend on the render buffer carrying a SampleRate. }
  if ASampleRate > 0 then
    FEngineRate := ASampleRate;
end;

procedure TMP3StreamSource.SaveDecodedWav(const AFileName: string; AMaxFrames: Integer);
var
  ch, n, minLen: Integer;
  slice: TAudioPlanar;
  i: Integer;
begin
  if FSrcChannels <= 0 then
    RaiseUDAW(errInvalidState, SRC_SUBSYS, 'no channels decoded');
  if FSrcFrames <= 0 then
    RaiseUDAW(errInvalidState, SRC_SUBSYS, 'no frames decoded');
  if Length(FData) < FSrcChannels then
    RaiseUDAWFmt(errInvalidState, SRC_SUBSYS,
      'FData has %d channels, expected %d', [Length(FData), FSrcChannels]);

  minLen := MaxInt;
  for ch := 0 to FSrcChannels - 1 do
  begin
    if FData[ch] = nil then
      RaiseUDAWFmt(errInvalidState, SRC_SUBSYS, 'decoded channel %d is empty', [ch]);
    if Length(FData[ch]) < minLen then minLen := Length(FData[ch]);
  end;

  n := FSrcFrames;
  if n > minLen then n := minLen;
  if (AMaxFrames > 0) and (n > AMaxFrames) then n := AMaxFrames;
  if n <= 0 then
    RaiseUDAW(errInvalidState, SRC_SUBSYS, 'nothing to write');

  { copy the slice into a compact planar buffer so the writer sees exactly
    n frames per channel (avoids any over-read on a mismatched length) }
  SetLength(slice, FSrcChannels);
  for ch := 0 to FSrcChannels - 1 do
  begin
    SetLength(slice[ch], n);
    for i := 0 to n - 1 do
      slice[ch][i] := FData[ch][i];
  end;

  SaveWavFile(AFileName, slice, FSrcChannels, FSrcRate, n, wsfFloat32);
end;

procedure TMP3StreamSource.Reset;
begin
  FPos := 0;
  AtomicSet32(FSeekPending, 0);
  FAtEnd := FSrcFrames = 0;
end;

function TMP3StreamSource.Name: string;
begin
  Result := FName;
end;

procedure TMP3StreamSource.SeekSeconds(ASeconds: Double);
begin
  if FSrcRate <= 0 then Exit;
  SeekFrames(Round(ASeconds * FSrcRate));
end;

procedure TMP3StreamSource.SeekFrames(AFrame: Int64);
begin
  if AFrame < 0 then AFrame := 0;
  if (FSrcFrames > 0) and (AFrame > FSrcFrames) then AFrame := FSrcFrames;
  { publish the target, then raise the flag; Render reads flag-then-target }
  AtomicSet32(FSeekReqFrame, Integer(AFrame));
  AtomicSet32(FSeekPending, 1);
end;

function TMP3StreamSource.PositionSeconds: Double;
begin
  if FSrcRate > 0 then Result := FPos / FSrcRate else Result := 0;
end;

function TMP3StreamSource.DurationSeconds: Double;
begin
  if FSrcRate > 0 then Result := FSrcFrames / FSrcRate else Result := 0;
end;

procedure TMP3StreamSource.Render(ABuffer: TAudioBuffer);
var
  i, ch, i0, i1, srcCh: Integer;
  ratio, frac, a, b: Double;
  d: PAudioSample;
begin
  ABuffer.Clear;

  if AtomicSet32(FSeekPending, 0) = 1 then
  begin
    FPos := AtomicRead32(FSeekReqFrame);
    FAtEnd := (FSrcFrames = 0) or (FPos >= FSrcFrames);
  end;

  if (FSrcFrames <= 0) or (FSrcChannels <= 0) then
  begin
    FAtEnd := True;
    Exit;
  end;

  { output rate: the render buffer's, else the rate Prepare captured, else 1:1 }
  if ABuffer.SampleRate > 0 then
    ratio := FSrcRate / ABuffer.SampleRate
  else if FEngineRate > 0 then
    ratio := FSrcRate / FEngineRate
  else
    ratio := 1.0;

  for i := 0 to ABuffer.FrameCount - 1 do
  begin
    if FPos >= FSrcFrames then
    begin
      if FLoop then
        FPos := FPos - FSrcFrames * Floor(FPos / FSrcFrames)
      else
      begin
        FAtEnd := True;
        Break;
      end;
    end;

    i0 := Floor(FPos);
    frac := FPos - i0;
    i1 := i0 + 1;
    if i1 >= FSrcFrames then
    begin
      if FLoop then i1 := 0 else i1 := FSrcFrames - 1;
    end;

    for ch := 0 to ABuffer.ChannelCount - 1 do
    begin
      if ch < FSrcChannels then srcCh := ch
      else srcCh := FSrcChannels - 1;
      a := FData[srcCh][i0];
      b := FData[srcCh][i1];
      d := ABuffer.ChannelPtr(ch);
      Inc(d, i);
      d^ := Single(a + (b - a) * frac);
    end;

    FPos := FPos + ratio;
    if (not FLoop) and (FPos >= FSrcFrames) then
      FAtEnd := True;
  end;
end;

end.
