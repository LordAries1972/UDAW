unit UDAW.Codec.MP4.Source;
{$I udaw.inc}
{$POINTERMATH ON}

{ MP4/M4A playback follow-up: a real IAudioSource for MP4 so a PCM-in-MP4 or
  MP3-in-MP4 file (AAC-LC is reported but not yet decodable - see
  UDAW.Codec.AAC / docs/Phase16b-AAC.md) can be auditioned through the audio
  engine, mirroring UDAW.Codec.MP3.Source.TMP3StreamSource almost exactly:
  the whole track is decoded up front (via Mp4DecodeAudio/Mp4DecodeAudioFile),
  off the real-time thread, then Render serves frames from memory with the
  same linear rate-adaptation and lock-free Seek*. }

interface

uses
  SysUtils, Classes, Math,
  UDAW.Errors, UDAW.Threading, UDAW.Audio.Types, UDAW.Audio.Buffer,
  UDAW.Audio.Source, UDAW.Codec.MP4, UDAW.DSP.Resampler;

type
  TMP4StreamSource = class(TInterfacedObject, IAudioSource)
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
    FCodecName: string;
    FContainerBrand: string;
    FResampledTo: Integer;    // 0 = not yet resampled; else the rate FData is now at
    FFileRate: Integer;       // the file's own native rate, fixed at decode time
    procedure DecodeAll(const AData: TBytes);
  public
    { AData / AFileName is sniffed, not trusted by extension, by the decoder.
      Raises EUDAWError if the carried codec cannot be decoded here (e.g. an
      AAC-LC .m4a before Phase 16b's tables land). }
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
    property SourceRate: Integer read FFileRate;
    property EngineRate: Integer read FEngineRate;
    property CodecName: string read FCodecName;
    property ContainerBrand: string read FContainerBrand;
    function PositionSeconds: Double;
    function DurationSeconds: Double;
  end;

implementation

const
  SRC_SUBSYS = 'Codec.MP4.Source';

{ ---------------------------------------------------------------- }

constructor TMP4StreamSource.CreateFromData(const AData: TBytes; ALoop: Boolean);
begin
  inherited Create;
  FLoop := ALoop;
  DecodeAll(AData);
end;

constructor TMP4StreamSource.CreateFromFile(const AFileName: string; ALoop: Boolean);
var
  fs: TFileStream;
  data: TBytes;
begin
  inherited Create;
  FLoop := ALoop;
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, SRC_SUBSYS, 'MP4 file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(data, fs.Size);
    if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
  finally
    fs.Free;
  end;
  DecodeAll(data);
  FName := Format('mp4 "%s" (%s, %d Hz, %d ch, %d frames)',
    [ExtractFileName(AFileName), FCodecName, FSrcRate, FSrcChannels, FSrcFrames]);
end;

procedure TMP4StreamSource.DecodeAll(const AData: TBytes);
var
  res: TMP4DecodeResult;
begin
  if not Mp4DecodeAudio(AData, res) then
    RaiseUDAW(errIO, SRC_SUBSYS, 'MP4 decode produced no audio');

  FData := res.Data;
  FSrcChannels := res.Channels;
  FSrcRate := res.SampleRate;
  FFileRate := res.SampleRate;
  FSrcFrames := res.Frames;
  FCodecName := res.CodecName;
  FContainerBrand := res.ContainerBrand;

  if FName = '' then
    FName := Format('mp4 stream (%s, %d Hz, %d ch, %d frames)',
      [FCodecName, FSrcRate, FSrcChannels, FSrcFrames]);
  Reset;
end;

procedure TMP4StreamSource.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
var
  resampled: TAudioPlanar;
  savedPos: Double;
begin
  { file already resident; Render adapts the rate.  Capture the engine/device
    rate handed in here - it is the authoritative output rate and does not
    depend on the render buffer carrying a SampleRate. }
  if ASampleRate > 0 then
    FEngineRate := ASampleRate;

  { Render's per-sample linear interpolation is a cheap way to adapt an
    arbitrary ratio, but linear interpolation is a poor anti-alias filter:
    on a real-world mismatch like file 44100 Hz / device 48000 Hz it audibly
    crackles and rings ("bleeps") on transients. Since the whole file is
    already resident in memory (DecodeAll's whole design), do the rate
    conversion properly exactly once here with the project's windowed-sinc
    resampler (UDAW.DSP.Resampler, Phase 3 - already used elsewhere for
    mastering-grade SRC) instead of on every Render call. Once FData is at
    the engine's own rate, Render's ratio degenerates to ~1.0 and no further
    interpolation error is introduced during playback. }
  if (ASampleRate > 0) and (FSrcFrames > 0) and (FSrcRate > 0) and
     (ASampleRate <> FResampledTo) and (ASampleRate <> FSrcRate) then
  begin
    savedPos := FPos;
    resampled := ResamplePlanar(FData, FSrcFrames, FSrcRate, ASampleRate, rqSinc);
    FData := resampled;
    if Length(FData) > 0 then
      FSrcFrames := Length(FData[0])
    else
      FSrcFrames := 0;
    FPos := savedPos * (ASampleRate / FSrcRate);
    FSrcRate := ASampleRate;
    FResampledTo := ASampleRate;
  end;
end;

procedure TMP4StreamSource.Reset;
begin
  FPos := 0;
  AtomicSet32(FSeekPending, 0);
  FAtEnd := FSrcFrames = 0;
end;

function TMP4StreamSource.Name: string;
begin
  Result := FName;
end;

procedure TMP4StreamSource.SeekSeconds(ASeconds: Double);
begin
  if FSrcRate <= 0 then Exit;
  SeekFrames(Round(ASeconds * FSrcRate));
end;

procedure TMP4StreamSource.SeekFrames(AFrame: Int64);
begin
  if AFrame < 0 then AFrame := 0;
  if (FSrcFrames > 0) and (AFrame > FSrcFrames) then AFrame := FSrcFrames;
  { publish the target, then raise the flag; Render reads flag-then-target }
  AtomicSet32(FSeekReqFrame, Integer(AFrame));
  AtomicSet32(FSeekPending, 1);
end;

function TMP4StreamSource.PositionSeconds: Double;
begin
  if FSrcRate > 0 then Result := FPos / FSrcRate else Result := 0;
end;

function TMP4StreamSource.DurationSeconds: Double;
begin
  if FSrcRate > 0 then Result := FSrcFrames / FSrcRate else Result := 0;
end;

procedure TMP4StreamSource.Render(ABuffer: TAudioBuffer);
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
