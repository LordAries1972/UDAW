unit UDAW.Audio.Buffer;
{$I udaw.inc}

{ Phase 2 - TAudioBuffer: the planar Float32 block passed through the whole
  engine, plus a preallocated buffer pool for non-real-time producers.

  TAudioBuffer owns FChannelCount contiguous Single arrays, each at least
  FCapacityFrames long. FFrameCount (<= FCapacityFrames) is the live length.
  Growing storage happens off the real-time path; once a buffer has reached its
  working size it is reused without reallocation - the real-time callback only
  calls Clear / SetActiveFrames / mix operations. }

interface

uses
  SysUtils,
  UDAW.Types, UDAW.Errors, UDAW.Threading, UDAW.Audio.Types;

type
  TAudioBuffer = class
  private
    FData: TAudioPlanar;          // [channel][frame], each row >= FCapacityFrames
    FChannelCount: Integer;
    FCapacityFrames: Integer;
    FFrameCount: Integer;
    FSampleRate: Integer;
    FStreamPosition: Int64;       // frame index of frame 0 within its stream
    FTimestampNs: Int64;
    procedure Grow(AChannels, AFrames: Integer);
  public
    constructor Create(AChannelCount: Integer = 2;
      ACapacityFrames: Integer = UDAW_DEFAULT_BUFFER_FRAMES;
      ASampleRate: Integer = UDAW_DEFAULT_SAMPLE_RATE);
    destructor Destroy; override;

    { Reconfigure. Grows storage if needed; sets FrameCount := AFrames. }
    procedure Configure(AChannelCount, AFrames, ASampleRate: Integer);
    { Set the live length without touching storage (AFrames <= CapacityFrames). }
    procedure SetActiveFrames(AFrames: Integer);

    procedure Clear;                                   // zero [0..FrameCount)
    procedure ClearChannel(AChannel: Integer);
    function ChannelPtr(AChannel: Integer): PAudioSample;

    { dst := src (matching channel count; frames = min of the two). }
    procedure CopyFrom(ASource: TAudioBuffer);
    { dst += src * AGain. }
    procedure MixFrom(ASource: TAudioBuffer; AGain: Single = 1.0);
    { dst += src. }
    procedure AddFrom(ASource: TAudioBuffer);
    { dst *= AScalar (all channels). }
    procedure ApplyGain(AGain: Single);
    procedure ApplyGainChannel(AChannel: Integer; AGain: Single);

    function PeakChannel(AChannel: Integer): Single;
    function Peak: Single;
    function RmsChannel(AChannel: Integer): Single;
    function HasNonFinite: Boolean;

    { Fill from an interleaved device block (bytes) in AFmt. }
    procedure LoadInterleaved(const ASrc; AFmt: TAudioDeviceFormat;
      ASrcChannels, AFrames: Integer);
    { Write the live frames to an interleaved device block (bytes) in AFmt. }
    procedure StoreInterleaved(var ADst; AFmt: TAudioDeviceFormat;
      ADstChannels, AFrames: Integer);

    property ChannelCount: Integer read FChannelCount;
    property CapacityFrames: Integer read FCapacityFrames;
    property FrameCount: Integer read FFrameCount;
    property SampleRate: Integer read FSampleRate write FSampleRate;
    property StreamPosition: Int64 read FStreamPosition write FStreamPosition;
    property TimestampNs: Int64 read FTimestampNs write FTimestampNs;
  end;

  { Fixed-size pool of identically-shaped buffers for NON-real-time producers
    (import, waveform, offline render). Acquire returns nil when exhausted -
    callers must cope, never block. The real-time path uses buffers owned by
    the stream, not the pool. }
  TAudioBufferPool = class
  private
    FLock: TUDAWLock;
    FAll: array of TAudioBuffer;
    FFree: array of TAudioBuffer;
    FFreeCount: Integer;
    FChannels: Integer;
    FFrames: Integer;
    FSampleRate: Integer;
  public
    constructor Create(ACount, AChannels, AFrames, ASampleRate: Integer);
    destructor Destroy; override;
    function Acquire: TAudioBuffer;
    procedure Release(ABuffer: TAudioBuffer);
    function AvailableCount: Integer;
    function PoolSize: Integer;
  end;

implementation

{ ---------------- TAudioBuffer ---------------- }

constructor TAudioBuffer.Create(AChannelCount, ACapacityFrames, ASampleRate: Integer);
begin
  inherited Create;
  if AChannelCount < 1 then AChannelCount := 1;
  if ACapacityFrames < 1 then ACapacityFrames := 1;
  FSampleRate := ASampleRate;
  Grow(AChannelCount, ACapacityFrames);
  FChannelCount := AChannelCount;
  FFrameCount := ACapacityFrames;
end;

destructor TAudioBuffer.Destroy;
begin
  SetLength(FData, 0);
  inherited Destroy;
end;

procedure TAudioBuffer.Grow(AChannels, AFrames: Integer);
var
  ch: Integer;
begin
  if AChannels > Length(FData) then
    SetLength(FData, AChannels);
  for ch := 0 to Length(FData) - 1 do
    if Length(FData[ch]) < AFrames then
      SetLength(FData[ch], AFrames);
  if AFrames > FCapacityFrames then
    FCapacityFrames := AFrames;
end;

procedure TAudioBuffer.Configure(AChannelCount, AFrames, ASampleRate: Integer);
begin
  if AChannelCount < 1 then
    RaiseUDAW(errInvalidArgument, AUDIO_SUBSYS, 'TAudioBuffer.Configure: channels < 1');
  if AFrames < 0 then AFrames := 0;
  Grow(AChannelCount, AFrames);
  FChannelCount := AChannelCount;
  FFrameCount := AFrames;
  if ASampleRate > 0 then
    FSampleRate := ASampleRate;
end;

procedure TAudioBuffer.SetActiveFrames(AFrames: Integer);
begin
  if AFrames < 0 then AFrames := 0;
  if AFrames > FCapacityFrames then
    RaiseUDAWFmt(errInvalidState, AUDIO_SUBSYS,
      'TAudioBuffer.SetActiveFrames: %d > capacity %d', [AFrames, FCapacityFrames]);
  FFrameCount := AFrames;
end;

procedure TAudioBuffer.Clear;
var
  ch: Integer;
begin
  for ch := 0 to FChannelCount - 1 do
    if FFrameCount > 0 then
      FillChar(FData[ch][0], FFrameCount * SizeOf(TAudioSample), 0);
end;

procedure TAudioBuffer.ClearChannel(AChannel: Integer);
begin
  if (AChannel < 0) or (AChannel >= FChannelCount) then Exit;
  if FFrameCount > 0 then
    FillChar(FData[AChannel][0], FFrameCount * SizeOf(TAudioSample), 0);
end;

function TAudioBuffer.ChannelPtr(AChannel: Integer): PAudioSample;
begin
  if (AChannel < 0) or (AChannel >= FChannelCount) then
    RaiseUDAWFmt(errInvalidArgument, AUDIO_SUBSYS,
      'TAudioBuffer.ChannelPtr: channel %d out of range', [AChannel]);
  Result := @FData[AChannel][0];
end;

procedure TAudioBuffer.CopyFrom(ASource: TAudioBuffer);
var
  ch, n, chn: Integer;
begin
  if ASource = nil then Exit;
  n := FFrameCount;
  if ASource.FrameCount < n then n := ASource.FrameCount;
  chn := FChannelCount;
  if ASource.ChannelCount < chn then chn := ASource.ChannelCount;
  for ch := 0 to chn - 1 do
    if n > 0 then
      Move(ASource.FData[ch][0], FData[ch][0], n * SizeOf(TAudioSample));
end;

procedure TAudioBuffer.MixFrom(ASource: TAudioBuffer; AGain: Single);
var
  ch, i, n, chn: Integer;
  s, d: PAudioSample;
begin
  if ASource = nil then Exit;
  n := FFrameCount;
  if ASource.FrameCount < n then n := ASource.FrameCount;
  chn := FChannelCount;
  if ASource.ChannelCount < chn then chn := ASource.ChannelCount;
  for ch := 0 to chn - 1 do
  begin
    s := @ASource.FData[ch][0];
    d := @FData[ch][0];
    for i := 0 to n - 1 do
    begin
      d^ := d^ + s^ * AGain;
      Inc(s); Inc(d);
    end;
  end;
end;

procedure TAudioBuffer.AddFrom(ASource: TAudioBuffer);
begin
  MixFrom(ASource, 1.0);
end;

procedure TAudioBuffer.ApplyGain(AGain: Single);
var
  ch, i: Integer;
  d: PAudioSample;
begin
  for ch := 0 to FChannelCount - 1 do
  begin
    d := @FData[ch][0];
    for i := 0 to FFrameCount - 1 do
    begin
      d^ := d^ * AGain;
      Inc(d);
    end;
  end;
end;

procedure TAudioBuffer.ApplyGainChannel(AChannel: Integer; AGain: Single);
var
  i: Integer;
  d: PAudioSample;
begin
  if (AChannel < 0) or (AChannel >= FChannelCount) then Exit;
  d := @FData[AChannel][0];
  for i := 0 to FFrameCount - 1 do
  begin
    d^ := d^ * AGain;
    Inc(d);
  end;
end;

function TAudioBuffer.PeakChannel(AChannel: Integer): Single;
var
  i: Integer;
  d: PAudioSample;
  m, a: Single;
begin
  Result := 0;
  if (AChannel < 0) or (AChannel >= FChannelCount) then Exit;
  m := 0;
  d := @FData[AChannel][0];
  for i := 0 to FFrameCount - 1 do
  begin
    a := Abs(d^);
    if a > m then m := a;
    Inc(d);
  end;
  Result := m;
end;

function TAudioBuffer.Peak: Single;
var
  ch: Integer;
  m, p: Single;
begin
  m := 0;
  for ch := 0 to FChannelCount - 1 do
  begin
    p := PeakChannel(ch);
    if p > m then m := p;
  end;
  Result := m;
end;

function TAudioBuffer.RmsChannel(AChannel: Integer): Single;
var
  i: Integer;
  d: PAudioSample;
  acc: Double;
begin
  Result := 0;
  if (AChannel < 0) or (AChannel >= FChannelCount) or (FFrameCount = 0) then Exit;
  acc := 0;
  d := @FData[AChannel][0];
  for i := 0 to FFrameCount - 1 do
  begin
    acc := acc + Double(d^) * Double(d^);
    Inc(d);
  end;
  Result := Sqrt(acc / FFrameCount);
end;

function TAudioBuffer.HasNonFinite: Boolean;
var
  ch, i: Integer;
  d: PAudioSample;
  v: Single;
begin
  for ch := 0 to FChannelCount - 1 do
  begin
    d := @FData[ch][0];
    for i := 0 to FFrameCount - 1 do
    begin
      v := d^;
      if (v <> v) or (v - v <> 0) then
        Exit(True);
      Inc(d);
    end;
  end;
  Result := False;
end;

procedure TAudioBuffer.LoadInterleaved(const ASrc; AFmt: TAudioDeviceFormat;
  ASrcChannels, AFrames: Integer);
var
  ch: Integer;
begin
  Configure(ASrcChannels, AFrames, FSampleRate);
  if AFrames > 0 then
    DecodeInterleaved(ASrc, AFmt, ASrcChannels, AFrames, FData);
  for ch := ASrcChannels to FChannelCount - 1 do
    ClearChannel(ch);
end;

procedure TAudioBuffer.StoreInterleaved(var ADst; AFmt: TAudioDeviceFormat;
  ADstChannels, AFrames: Integer);
var
  tmp: TAudioPlanar;
  ch, i, n: Integer;
begin
  if AFrames <= 0 then Exit;
  n := AFrames;
  if n > FFrameCount then n := FFrameCount;
  if n <= 0 then Exit;

  if ADstChannels = FChannelCount then
    EncodeInterleaved(FData, ADstChannels, n, AFmt, ADst)
  else
  begin
    SetLength(tmp, ADstChannels);
    for ch := 0 to ADstChannels - 1 do
    begin
      SetLength(tmp[ch], n);
      if ch < FChannelCount then
        Move(FData[ch][0], tmp[ch][0], n * SizeOf(TAudioSample))
      else if FChannelCount > 0 then
        Move(FData[FChannelCount - 1][0], tmp[ch][0], n * SizeOf(TAudioSample))
      else
        for i := 0 to n - 1 do tmp[ch][i] := 0;
    end;
    EncodeInterleaved(tmp, ADstChannels, n, AFmt, ADst);
  end;
end;

{ ---------------- TAudioBufferPool ---------------- }

constructor TAudioBufferPool.Create(ACount, AChannels, AFrames, ASampleRate: Integer);
var
  i: Integer;
begin
  inherited Create;
  if ACount < 1 then ACount := 1;
  FLock := TUDAWLock.Create('audiopool');
  FChannels := AChannels;
  FFrames := AFrames;
  FSampleRate := ASampleRate;
  SetLength(FAll, ACount);
  SetLength(FFree, ACount);
  for i := 0 to ACount - 1 do
  begin
    FAll[i] := TAudioBuffer.Create(AChannels, AFrames, ASampleRate);
    FFree[i] := FAll[i];
  end;
  FFreeCount := ACount;
end;

destructor TAudioBufferPool.Destroy;
var
  i: Integer;
begin
  for i := 0 to Length(FAll) - 1 do
    FAll[i].Free;
  SetLength(FAll, 0);
  SetLength(FFree, 0);
  FLock.Free;
  inherited Destroy;
end;

function TAudioBufferPool.Acquire: TAudioBuffer;
begin
  FLock.Enter;
  try
    if FFreeCount = 0 then
      Exit(nil);
    Dec(FFreeCount);
    Result := FFree[FFreeCount];
    FFree[FFreeCount] := nil;
  finally
    FLock.Leave;
  end;
  Result.Configure(FChannels, FFrames, FSampleRate);
  Result.Clear;
end;

procedure TAudioBufferPool.Release(ABuffer: TAudioBuffer);
begin
  if ABuffer = nil then Exit;
  FLock.Enter;
  try
    if FFreeCount < Length(FFree) then
    begin
      FFree[FFreeCount] := ABuffer;
      Inc(FFreeCount);
    end;
  finally
    FLock.Leave;
  end;
end;

function TAudioBufferPool.AvailableCount: Integer;
begin
  FLock.Enter;
  try
    Result := FFreeCount;
  finally
    FLock.Leave;
  end;
end;

function TAudioBufferPool.PoolSize: Integer;
begin
  Result := Length(FAll);
end;

end.
