unit UDAW.Codec.FLAC.Encoder;
{$I udaw.inc}

{ FLAC encoder: from scratch, mirroring the decoder's bit-level conventions
  (UDAW.Codec.FLAC.Frame's TFlacBitReader / CRC-8 / CRC-16) but writing rather
  than reading. Subframes use only the fixed predictors (orders 0-4, chosen
  per subframe by lowest sum-of-absolute-residual, the same heuristic
  reference encoders use for the fixed case) plus CONSTANT for silent/DC
  subframes - there is no LPC and no stereo decorrelation (mid/side), so
  compression is well short of a state-of-the-art encoder, but every frame it
  produces is exactly, losslessly decodable: this trades ratio for a much
  smaller amount of new bit-level code to get right.

  Residual coding always uses a single Rice partition per subframe (partition
  order 0) with the Rice parameter chosen by exact bit-count search - simpler
  than the reference encoder's partitioned search, still always correct.

  Sample rate and bits-per-sample are both written as "0 = take it from
  STREAMINFO" (both header fields have that escape), which sidesteps needing
  the frame header's lookup tables entirely; block size has no such escape,
  so every frame writes an explicit 16-bit block-size-1 field. }

interface

uses {$IFDEF FPC}UDAW.Compat,{$ENDIF}
  SysUtils, Classes, Math,
  UDAW.Errors, UDAW.Audio.Types,
  UDAW.Codec.FLAC.Frame,
  UDAW.Codec.WAV;

{ Encodes AWavFile (any format UDAW.Codec.WAV can read) to a new FLAC file at
  AOutputFile, at a fixed 24-bit depth (matching the intermediate WAV the
  Timeline exporter renders for MP3/MP4 too - see UDAW.Timeline.Export).
  AProgress, when given, is called with 0..1 as frames are encoded. }
procedure FlacEncodeFile(const AWavFile, AOutputFile: string; AProgress: TProc<Double> = nil);

implementation

const
  FLAC_ENCODE_BITS = 24;
  FLAC_ENCODE_SCALE = 8388608.0;   // 2^23 - matches UDAW.Codec.WAV's wsfPCM24 float scale exactly
  FLAC_ENCODE_MIN = -8388608;
  FLAC_ENCODE_MAX = 8388607;
  FLAC_BLOCK = 4096;

type
  { MSB-first bit writer - the encode-side mirror of TFlacBitReader. Bits are
    accumulated one at a time into FCur/FBitsInCur and only committed to
    FBytes once a full byte is formed; AlignToByte pads and commits whatever
    is pending, which is what makes ByteLength/Snapshot meaningful (they only
    ever look at fully-committed bytes). }
  TFlacBitWriter = record
  private
    FBytes: TBytes;
    FCount: Integer;
    FCur: Byte;
    FBitsInCur: Integer;
    procedure Grow;
  public
    procedure Init;
    procedure WriteBit(ABit: Cardinal);
    procedure WriteBits(AValue: Cardinal; ACount: Integer);
    procedure WriteBitsBig(AValue: UInt64; ACount: Integer);
    procedure WriteSigned(AValue: Int64; ACount: Integer);
    procedure WriteUnary(AQuotient: Cardinal);
    procedure AlignToByte;
    function ByteLength: Integer;
    function Snapshot(AFrom, ALen: Integer): TBytes;
    function ToBytes: TBytes;
  end;

procedure TFlacBitWriter.Init;
begin
  SetLength(FBytes, 4096);
  FCount := 0;
  FCur := 0;
  FBitsInCur := 0;
end;

procedure TFlacBitWriter.Grow;
begin
  if FCount >= Length(FBytes) then
    SetLength(FBytes, Length(FBytes) * 2);
end;

procedure TFlacBitWriter.WriteBit(ABit: Cardinal);
begin
  FCur := Byte((FCur shl 1) or (ABit and 1));
  Inc(FBitsInCur);
  if FBitsInCur = 8 then
  begin
    Grow;
    FBytes[FCount] := FCur;
    Inc(FCount);
    FCur := 0;
    FBitsInCur := 0;
  end;
end;

procedure TFlacBitWriter.WriteBits(AValue: Cardinal; ACount: Integer);
var
  i: Integer;
begin
  for i := ACount - 1 downto 0 do
    WriteBit((AValue shr i) and 1);
end;

procedure TFlacBitWriter.WriteBitsBig(AValue: UInt64; ACount: Integer);
var
  i: Integer;
begin
  for i := ACount - 1 downto 0 do
    WriteBit(Cardinal((AValue shr i) and 1));
end;

procedure TFlacBitWriter.WriteSigned(AValue: Int64; ACount: Integer);
begin
  WriteBitsBig(UInt64(AValue) and ((UInt64(1) shl ACount) - 1), ACount);
end;

procedure TFlacBitWriter.WriteUnary(AQuotient: Cardinal);
var
  i: Cardinal;
begin
  for i := 1 to AQuotient do WriteBit(0);
  WriteBit(1);
end;

procedure TFlacBitWriter.AlignToByte;
begin
  while FBitsInCur <> 0 do WriteBit(0);
end;

function TFlacBitWriter.ByteLength: Integer;
begin
  Result := FCount;
end;

function TFlacBitWriter.Snapshot(AFrom, ALen: Integer): TBytes;
begin
  SetLength(Result, ALen);
  if ALen > 0 then Move(FBytes[AFrom], Result[0], ALen);
end;

function TFlacBitWriter.ToBytes: TBytes;
begin
  AlignToByte;
  SetLength(Result, FCount);
  if FCount > 0 then Move(FBytes[0], Result[0], FCount);
end;

{ ================= frame/sample-number UTF-8-style code ================= }

const
  UTF8_LEAD: array[2..7] of Byte = ($C0, $E0, $F0, $F8, $FC, $FE);
  UTF8_DATABITS: array[2..7] of Integer = (5, 4, 3, 2, 1, 0);

procedure WriteUtf8Value(var W: TFlacBitWriter; AValue: UInt64);
var
  n, i, dataBits: Integer;
  lead: Byte;
begin
  if AValue < $80 then
  begin
    W.WriteBits(Cardinal(AValue), 8);
    Exit;
  end;
  if AValue < (UInt64(1) shl 11) then n := 2
  else if AValue < (UInt64(1) shl 16) then n := 3
  else if AValue < (UInt64(1) shl 21) then n := 4
  else if AValue < (UInt64(1) shl 26) then n := 5
  else if AValue < (UInt64(1) shl 31) then n := 6
  else n := 7;

  dataBits := UTF8_DATABITS[n];
  lead := UTF8_LEAD[n];
  if dataBits > 0 then
    lead := lead or Byte((AValue shr (6 * (n - 1))) and ((1 shl dataBits) - 1));
  W.WriteBits(lead, 8);
  for i := n - 2 downto 0 do
    W.WriteBits(Cardinal($80 or ((AValue shr (6 * i)) and $3F)), 8);
end;

{ ================= fixed-predictor residual + Rice coding ================= }

function ZigZag(AValue: Int64): UInt64;
begin
  if AValue >= 0 then Result := UInt64(AValue) shl 1
  else Result := (UInt64(-AValue) shl 1) - 1;
end;

function ComputeFixedResidual(const S: TArray<Integer>; AOrder: Integer): TArray<Int64>;
var
  i, n: Integer;
begin
  n := Length(S);
  SetLength(Result, Max(0, n - AOrder));
  case AOrder of
    0: for i := 0 to n - 1 do Result[i] := S[i];
    1: for i := 1 to n - 1 do Result[i - 1] := Int64(S[i]) - S[i - 1];
    2: for i := 2 to n - 1 do Result[i - 2] := Int64(S[i]) - 2 * S[i - 1] + S[i - 2];
    3: for i := 3 to n - 1 do Result[i - 3] := Int64(S[i]) - 3 * S[i - 1] + 3 * S[i - 2] - S[i - 3];
    4: for i := 4 to n - 1 do Result[i - 4] := Int64(S[i]) - 4 * S[i - 1] + 6 * S[i - 2] - 4 * S[i - 3] + S[i - 4];
  end;
end;

{ Exact search (0..30) for the Rice parameter minimising total encoded bits
  (n*(k+1) unary/stop bits plus the folded value's high bits), clamped to 14 -
  the largest value the format's 4-bit non-escape parameter field can hold. }
function BestRiceParam(const AResidual: TArray<Int64>): Integer;
var
  k, bestK, i: Integer;
  total, bestTotal: Int64;
  folded: UInt64;
begin
  bestK := 0;
  bestTotal := High(Int64);
  for k := 0 to 30 do
  begin
    total := 0;
    for i := 0 to High(AResidual) do
    begin
      folded := ZigZag(AResidual[i]);
      Inc(total, Int64(folded shr k) + 1);
      if total >= bestTotal then Break;
    end;
    if total < bestTotal then
    begin
      bestTotal := total;
      bestK := k;
    end;
  end;
  Result := Min(bestK, 14);
end;

procedure WriteResidual(var W: TFlacBitWriter; const AResidual: TArray<Int64>);
var
  k, i: Integer;
  folded: UInt64;
begin
  k := BestRiceParam(AResidual);
  W.WriteBits(0, 2);           // residual coding method: 4-bit Rice parameters
  W.WriteBits(0, 4);           // partition order 0 - a single partition
  W.WriteBits(Cardinal(k), 4);
  for i := 0 to High(AResidual) do
  begin
    folded := ZigZag(AResidual[i]);
    W.WriteUnary(Cardinal(folded shr k));
    if k > 0 then
      W.WriteBits(Cardinal(folded and ((UInt64(1) shl k) - 1)), k);
  end;
end;

procedure WriteSubframe(var W: TFlacBitWriter; const ASamples: TArray<Integer>; ABitsPerSample: Integer);
var
  n, i, order, maxOrder, bestOrder: Integer;
  allEqual: Boolean;
  sum, bestSum: Int64;
  residual, bestResidual: TArray<Int64>;
begin
  n := Length(ASamples);
  allEqual := True;
  for i := 1 to n - 1 do
    if ASamples[i] <> ASamples[0] then
    begin
      allEqual := False;
      Break;
    end;
  if allEqual then
  begin
    W.WriteBits(0, 1);            // zero padding bit
    W.WriteBits(0, 6);            // SUBFRAME_CONSTANT
    W.WriteBits(0, 1);            // no wasted bits
    if n > 0 then W.WriteSigned(ASamples[0], ABitsPerSample);
    Exit;
  end;

  maxOrder := Min(4, Max(0, n - 1));
  bestOrder := 0;
  bestSum := High(Int64);
  bestResidual := nil;
  for order := 0 to maxOrder do
  begin
    residual := ComputeFixedResidual(ASamples, order);
    sum := 0;
    for i := 0 to High(residual) do
      Inc(sum, Abs(residual[i]));
    if sum < bestSum then
    begin
      bestSum := sum;
      bestOrder := order;
      bestResidual := residual;
    end;
  end;

  W.WriteBits(0, 1);                          // zero padding bit
  W.WriteBits(Cardinal(8 + bestOrder), 6);    // SUBFRAME_FIXED, order bestOrder
  W.WriteBits(0, 1);                          // no wasted bits
  for i := 0 to bestOrder - 1 do
    W.WriteSigned(ASamples[i], ABitsPerSample);   // warmup samples, verbatim
  WriteResidual(W, bestResidual);
end;

{ ================= frame / stream assembly ================= }

procedure WriteFrame(var W: TFlacBitWriter; const AChannels: TArray<TArray<Integer>>;
  AFrameIndex, ABlockSize, ABitsPerSample, AChannelCount: Integer);
var
  frameStart: Integer;
  c: Integer;
  hdr: TBytes;
  crc8: Byte;
  crc16: Word;
begin
  frameStart := W.ByteLength;   // always byte-aligned here: the previous frame ended on a CRC-16 byte boundary

  W.WriteBits(FLAC_SYNC_CODE, 14);
  W.WriteBits(0, 1);                                 // mandatory reserved bit
  W.WriteBits(0, 1);                                 // fixed blocking (not variable)
  W.WriteBits(7, 4);                                 // block size code 7: explicit 16-bit value follows
  W.WriteBits(0, 4);                                 // sample rate code 0: from STREAMINFO
  W.WriteBits(Cardinal(AChannelCount - 1), 4);       // independent channels, no mid/side
  W.WriteBits(0, 3);                                 // bits-per-sample code 0: from STREAMINFO
  W.WriteBits(0, 1);                                 // mandatory reserved bit
  WriteUtf8Value(W, UInt64(AFrameIndex));            // fixed-blocking stream -> frame number
  W.WriteBits(Cardinal(ABlockSize - 1), 16);         // explicit block size (code 7 above)

  hdr := W.Snapshot(frameStart, W.ByteLength - frameStart);
  crc8 := Flac_CRC8(hdr, 0, Length(hdr));
  W.WriteBits(crc8, 8);

  for c := 0 to AChannelCount - 1 do
    WriteSubframe(W, AChannels[c], ABitsPerSample);

  W.AlignToByte;   // frame footer's CRC-16 is byte-aligned; residual coding rarely ends on one

  hdr := W.Snapshot(frameStart, W.ByteLength - frameStart);
  crc16 := Flac_CRC16(hdr, 0, Length(hdr));
  W.WriteBits(Cardinal(crc16), 16);
end;

function BuildStreamInfoBlock(AMinBlock, AMaxBlock, ASampleRate, AChannels, ABitsPerSample: Integer;
  ATotalSamples: Int64): TBytes;
var
  w: TFlacBitWriter;
  i: Integer;
begin
  w.Init;
  w.WriteBits(Cardinal(AMinBlock), 16);
  w.WriteBits(Cardinal(AMaxBlock), 16);
  w.WriteBits(0, 24);   // min frame size: unknown
  w.WriteBits(0, 24);   // max frame size: unknown
  w.WriteBits(Cardinal(ASampleRate), 20);
  w.WriteBits(Cardinal(AChannels - 1), 3);
  w.WriteBits(Cardinal(ABitsPerSample - 1), 5);
  w.WriteBitsBig(UInt64(ATotalSamples), 36);
  for i := 0 to 15 do w.WriteBits(0, 8);   // MD5: unknown - all-zero is spec-legal
  Result := w.ToBytes;   // exactly 34 bytes
end;

procedure FlacEncodeFile(const AWavFile, AOutputFile: string; AProgress: TProc<Double>);
var
  planar: TAudioPlanar;
  ch, sr, frameCount, i, c, done, n, frameIdx, minBlock, maxBlock: Integer;
  samples: TArray<TArray<Integer>>;
  blockChannels: TArray<TArray<Integer>>;
  streamInfo, outBytes: TBytes;
  w: TFlacBitWriter;
  v: Double;
  fs: TFileStream;
begin
  planar := LoadWavFile(AWavFile, ch, sr);
  if (ch <= 0) or (sr <= 0) then
    RaiseUDAW(errIO, FLAC_SUBSYS, 'Cannot read source audio to encode as FLAC.');
  if ch > 8 then
    RaiseUDAW(errInvalidArgument, FLAC_SUBSYS, 'FLAC supports at most 8 channels.');

  frameCount := Length(planar[0]);

  SetLength(samples, ch);
  for c := 0 to ch - 1 do
  begin
    SetLength(samples[c], frameCount);
    for i := 0 to frameCount - 1 do
    begin
      v := planar[c][i] * FLAC_ENCODE_SCALE;
      if v > FLAC_ENCODE_MAX then v := FLAC_ENCODE_MAX
      else if v < FLAC_ENCODE_MIN then v := FLAC_ENCODE_MIN;
      samples[c][i] := Round(v);
    end;
  end;

  if frameCount <= 0 then
  begin
    minBlock := 0;
    maxBlock := 0;
  end
  else if frameCount <= FLAC_BLOCK then
  begin
    minBlock := frameCount;
    maxBlock := frameCount;
  end
  else
  begin
    maxBlock := FLAC_BLOCK;
    if frameCount mod FLAC_BLOCK = 0 then minBlock := FLAC_BLOCK
    else minBlock := frameCount mod FLAC_BLOCK;
  end;

  streamInfo := BuildStreamInfoBlock(minBlock, maxBlock, sr, ch, FLAC_ENCODE_BITS, frameCount);

  w.Init;
  w.WriteBits(Ord('f'), 8);
  w.WriteBits(Ord('L'), 8);
  w.WriteBits(Ord('a'), 8);
  w.WriteBits(Ord('C'), 8);
  w.WriteBits(1, 1);              // last metadata block
  w.WriteBits(FLAC_BLOCK_STREAMINFO, 7);
  w.WriteBits(34, 24);
  for i := 0 to High(streamInfo) do w.WriteBits(streamInfo[i], 8);

  SetLength(blockChannels, ch);
  done := 0;
  frameIdx := 0;
  while done < frameCount do
  begin
    n := Min(FLAC_BLOCK, frameCount - done);
    for c := 0 to ch - 1 do
    begin
      SetLength(blockChannels[c], n);
      Move(samples[c][done], blockChannels[c][0], n * SizeOf(Integer));
    end;
    WriteFrame(w, blockChannels, frameIdx, n, FLAC_ENCODE_BITS, ch);
    Inc(done, n);
    Inc(frameIdx);
    if Assigned(AProgress) then AProgress(done / frameCount);
  end;

  outBytes := w.ToBytes;
  fs := TFileStream.Create(AOutputFile, fmCreate);
  try
    if Length(outBytes) > 0 then fs.WriteBuffer(outBytes[0], Length(outBytes));
  finally
    fs.Free;
  end;
end;

end.
