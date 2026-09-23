unit Tests.PhaseFLAC;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ FLAC decoder acceptance tests.

  Every test stream is built byte-by-byte (bit-by-bit, really - via a small
  MSB-first TBitWriter local to this unit) in memory, mirroring the style of
  Tests.Phase15: no reference audio files, no external tools.  Because FLAC is
  lossless, the single most important property under test is that decoding
  reproduces the exact integer samples that were encoded (modulo only the
  unavoidable int-to-float scaling) - so most tests hand-encode a tiny stream
  with known sample values and check the decoded floats against them to within
  the quantisation step of the stream's bit depth. }

interface

procedure RegisterPhaseFLACTests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Paths,
  UDAW.Audio.Types,
  UDAW.Codec.WAV,
  UDAW.Codec.FLAC.Frame,
  UDAW.Codec.FLAC.Decoder,
  UDAW.Codec.FLAC.Encoder,
  UDAW.Codec.FLAC;

const
  GRP = 'phaseflac.flac';

{ ==================== tiny MSB-first bit writer ==================== }

type
  TBitWriter = record
  private
    FBytes: TBytes;
    FLen: Integer;
    FCur: Byte;
    FBitCount: Integer;    // bits already placed into FCur (0..7)
  public
    procedure Init;
    procedure WriteBit(ABit: Integer);
    procedure WriteBits(AValue: UInt64; ACount: Integer);
    procedure WriteUnary(AQuotient: Cardinal);
    procedure WriteSigned(AValue: Int64; ANBits: Integer);
    procedure AlignByte;
    function FlushedBytes: TBytes;    // valid only when byte-aligned
  end;

procedure TBitWriter.Init;
begin
  FBytes := nil;
  FLen := 0;
  FCur := 0;
  FBitCount := 0;
end;

procedure TBitWriter.WriteBit(ABit: Integer);
begin
  FCur := (FCur shl 1) or Byte(ABit and 1);
  Inc(FBitCount);
  if FBitCount = 8 then
  begin
    if FLen >= Length(FBytes) then SetLength(FBytes, Length(FBytes) + 256);
    FBytes[FLen] := FCur;
    Inc(FLen);
    FCur := 0;
    FBitCount := 0;
  end;
end;

procedure TBitWriter.WriteBits(AValue: UInt64; ACount: Integer);
var
  i: Integer;
begin
  for i := ACount - 1 downto 0 do
    WriteBit(Integer((AValue shr i) and 1));
end;

procedure TBitWriter.WriteUnary(AQuotient: Cardinal);
var
  i: Cardinal;
begin
  for i := 1 to AQuotient do WriteBit(0);
  WriteBit(1);
end;

procedure TBitWriter.WriteSigned(AValue: Int64; ANBits: Integer);
begin
  if ANBits <= 0 then Exit;
  { two's-complement reinterpretation of the low ANBits bits }
  WriteBits(UInt64(AValue) and ((UInt64(1) shl ANBits) - 1), ANBits);
end;

procedure TBitWriter.AlignByte;
begin
  while FBitCount <> 0 do WriteBit(0);
end;

function TBitWriter.FlushedBytes: TBytes;
begin
  SetLength(Result, FLen);
  if FLen > 0 then Move(FBytes[0], Result[0], FLen);
end;

{ ==================== FLAC bitstream builders ==================== }

function ZigZagEncode(AV: Int64): UInt64;
begin
  if AV >= 0 then Result := UInt64(AV) shl 1
  else Result := (UInt64(-AV) shl 1) - 1;
end;

function BuildStreamInfoBytes(AMinBlk, AMaxBlk, AMinFrame, AMaxFrame,
  ASampleRate, AChannels, ABps: Integer; ATotalSamples: Int64): TBytes;
var
  bw: TBitWriter;
  i: Integer;
begin
  bw.Init;
  bw.WriteBits(AMinBlk, 16);
  bw.WriteBits(AMaxBlk, 16);
  bw.WriteBits(AMinFrame, 24);
  bw.WriteBits(AMaxFrame, 24);
  bw.WriteBits(ASampleRate, 20);
  bw.WriteBits(AChannels - 1, 3);
  bw.WriteBits(ABps - 1, 5);
  bw.WriteBits(UInt64(ATotalSamples), 36);
  for i := 0 to 15 do bw.WriteBits(0, 8);   // MD5, unchecked by our decoder
  Result := bw.FlushedBytes;
end;

function BuildMetaBlockHeader(AIsLast: Boolean; ABlockType, ALength: Integer): TBytes;
begin
  SetLength(Result, 4);
  Result[0] := Byte((Ord(AIsLast) shl 7) or (ABlockType and $7F));
  Result[1] := Byte(ALength shr 16);
  Result[2] := Byte(ALength shr 8);
  Result[3] := Byte(ALength);
end;

{ Build a minimal one-block-header FLAC file prefix: magic + STREAMINFO
  (marked last, so audio starts immediately after it). }
function BuildFlacPrefix(ASampleRate, AChannels, ABps: Integer;
  ATotalSamples: Int64; ABlockSize: Integer = 4096): TBytes;
var
  si, hdr: TBytes;
begin
  si := BuildStreamInfoBytes(ABlockSize, ABlockSize, 0, 0, ASampleRate, AChannels,
    ABps, ATotalSamples);
  hdr := BuildMetaBlockHeader(True, FLAC_BLOCK_STREAMINFO, Length(si));
  SetLength(Result, 4 + Length(hdr) + Length(si));
  Result[0] := Ord('f'); Result[1] := Ord('L'); Result[2] := Ord('a'); Result[3] := Ord('C');
  Move(hdr[0], Result[4], Length(hdr));
  Move(si[0], Result[4 + Length(hdr)], Length(si));
end;

procedure AppendBytes(var ABuf: TBytes; const AAdd: TBytes);
var
  n: Integer;
begin
  n := Length(ABuf);
  SetLength(ABuf, n + Length(AAdd));
  if Length(AAdd) > 0 then Move(AAdd[0], ABuf[n], Length(AAdd));
end;

{ Frame-header bit fields: fixed-blocksize stream (frame number coded), block
  size given via the 8-bit escape (code 6) so any block size 1..256 can be
  used without needing the fixed lookup table, sample rate taken from
  STREAMINFO (code 0) unless ASrCode is supplied explicitly. }
procedure WriteFrameHeader(var ABw: TBitWriter; ABlockSize, AChannelCode, ABpsCode,
  AFrameNumber: Integer; ASrCode: Integer = 0);
var
  hdrBytes: TBytes;
  crc8: Byte;
begin
  ABw.WriteBits(FLAC_SYNC_CODE, 14);
  ABw.WriteBits(0, 1);              // reserved
  ABw.WriteBits(0, 1);              // fixed-blocksize stream
  ABw.WriteBits(6, 4);              // block size: 8-bit escape follows
  ABw.WriteBits(ASrCode, 4);
  ABw.WriteBits(AChannelCode, 4);
  ABw.WriteBits(ABpsCode, 3);
  ABw.WriteBits(0, 1);              // reserved
  ABw.WriteBits(AFrameNumber and $7F, 8);     // UTF-8-like: single byte, <128
  ABw.WriteBits(ABlockSize - 1, 8);           // block-size escape payload
  hdrBytes := ABw.FlushedBytes;               // byte-aligned by construction
  crc8 := Flac_CRC8(hdrBytes, 0, Length(hdrBytes));
  ABw.WriteBits(crc8, 8);
end;

procedure WriteSubframeHeader(var ABw: TBitWriter; ASubType: Integer);
begin
  ABw.WriteBit(0);                  // zero padding bit
  ABw.WriteBits(ASubType, 6);
  ABw.WriteBit(0);                  // no wasted bits
end;

procedure WriteResidualSinglePartition(var ABw: TBitWriter; const AResidual: array of Int64;
  ARiceK: Integer);
var
  i: Integer;
  u: UInt64;
begin
  ABw.WriteBits(0, 2);               // method 0: 4-bit rice parameters
  ABw.WriteBits(0, 4);               // partition order 0 -> single partition
  ABw.WriteBits(ARiceK, 4);
  for i := 0 to High(AResidual) do
  begin
    u := ZigZagEncode(AResidual[i]);
    ABw.WriteUnary(Cardinal(u shr ARiceK));
    if ARiceK > 0 then
      ABw.WriteBits(u and ((UInt64(1) shl ARiceK) - 1), ARiceK);
  end;
end;

procedure WriteSubframeConstant(var ABw: TBitWriter; AEffBps: Integer; AValue: Int64);
begin
  WriteSubframeHeader(ABw, 0);
  ABw.WriteSigned(AValue, AEffBps);
end;

procedure WriteSubframeVerbatim(var ABw: TBitWriter; AEffBps: Integer;
  const AValues: array of Int64);
var
  i: Integer;
begin
  WriteSubframeHeader(ABw, 1);
  for i := 0 to High(AValues) do
    ABw.WriteSigned(AValues[i], AEffBps);
end;

{ FIXED predictor subframe: AOrder in 0..4. AResidual must have
  (blockSize - AOrder) entries; AWarmup must have AOrder entries. }
procedure WriteSubframeFixed(var ABw: TBitWriter; AOrder, AEffBps: Integer;
  const AWarmup, AResidual: array of Int64; ARiceK: Integer);
var
  i: Integer;
begin
  WriteSubframeHeader(ABw, 8 + AOrder);
  for i := 0 to AOrder - 1 do
    ABw.WriteSigned(AWarmup[i], AEffBps);
  WriteResidualSinglePartition(ABw, AResidual, ARiceK);
end;

{ Finish a frame: byte-align, compute+append the CRC-16 footer, return bytes. }
function FinishFrame(var ABw: TBitWriter): TBytes;
var
  bodyBytes: TBytes;
  crc16: Word;
begin
  ABw.AlignByte;
  bodyBytes := ABw.FlushedBytes;
  crc16 := Flac_CRC16(bodyBytes, 0, Length(bodyBytes));
  ABw.WriteBits(crc16, 16);
  Result := ABw.FlushedBytes;
end;

{ ==================== tests: sniffing ==================== }

procedure Test_Sniff_RejectsGarbage;
var
  junk: TBytes;
begin
  SetLength(junk, 16);
  FillChar(junk[0], 16, $AA);
  CheckFalse(FlacSniffData(junk), 'random bytes are not FLAC');
  SetLength(junk, 2);
  CheckFalse(FlacSniffData(junk), 'too-short buffer is not FLAC');
  CheckFalse(FlacSniffData(nil), 'nil buffer is not FLAC');
end;

procedure Test_Sniff_AcceptsMagic;
var
  data: TBytes;
begin
  data := BuildFlacPrefix(44100, 2, 16, 1000);
  Check(FlacSniffData(data), 'fLaC magic + STREAMINFO sniffs as FLAC');
end;

procedure Test_Sniff_RejectsFlacExtensionOnGarbage;
var
  junk: TBytes;
  fn: string;
  fs: TFileStream;
begin
  { the sniffer must not trust the file name / extension }
  SetLength(junk, 32);
  FillChar(junk[0], 32, $00);
  fn := IncludeTrailingPathDelimiter(Paths.Temp) + 'udaw_flac_test_fake.flac';
  ForceDirectories(ExtractFilePath(fn));
  fs := TFileStream.Create(fn, fmCreate);
  try
    fs.WriteBuffer(junk[0], Length(junk));
  finally
    fs.Free;
  end;
  try
    CheckFalse(FlacSniffFile(fn), 'a .flac-named file with no magic must not sniff as FLAC');
  finally
    if FileExists(fn) then DeleteFile(fn);
  end;
end;

{ ==================== tests: probe (STREAMINFO only) ==================== }

procedure Test_Probe_StreamInfoFields;
var
  data: TBytes;
  info: TFLACStreamInfo;
begin
  data := BuildFlacPrefix(48000, 2, 24, 123456, 4096);
  Check(FlacProbe(data, info), 'probe reads STREAMINFO');
  CheckEqualInt(48000, info.SampleRate, 'sample rate');
  CheckEqualInt(2, info.Channels, 'channels');
  CheckEqualInt(24, info.BitsPerSample, 'bits per sample');
  CheckEqualInt(123456, info.TotalSamples, 'total samples');
  CheckNear(123456 / 48000, info.DurationSeconds, 1.0E-9, 'duration');
end;

{ ==================== tests: decode - mono CONSTANT ==================== }

procedure Test_Decode_MonoConstant;
var
  bw: TBitWriter;
  data, frame: TBytes;
  res: TFLACDecodeResult;
begin
  data := BuildFlacPrefix(44100, 1, 16, 4, 4);
  bw.Init;
  WriteFrameHeader(bw, 4, 0{mono, independent}, 4{16-bit}, 0, 9{44100});
  WriteSubframeConstant(bw, 16, 12345);
  frame := FinishFrame(bw);
  AppendBytes(data, frame);

  Check(FlacDecode(data, res), 'decodes the mono CONSTANT frame');
  CheckEqualInt(1, res.Channels, 'channels');
  CheckEqualInt(44100, res.SampleRate, 'sample rate');
  CheckEqualInt(16, res.BitsPerSample, 'bits per sample');
  CheckEqualInt(4, res.TotalFrames, 'sample-frame count');
  CheckNear(12345 / 32768.0, res.Pcm[0][0], 1.0E-6, 'constant sample 0');
  CheckNear(12345 / 32768.0, res.Pcm[0][3], 1.0E-6, 'constant sample 3');
  CheckEqualInt(0, res.CrcMismatches, 'no CRC mismatches on a well-formed stream');
  CheckEqualInt(0, res.HeaderCrcMismatches, 'no header CRC mismatches');
end;

{ ==================== tests: decode - FIXED order-1 mono ==================== }

procedure Test_Decode_MonoFixedOrder1;
var
  bw: TBitWriter;
  data, frame: TBytes;
  res: TFLACDecodeResult;
  warmup, residual: array of Int64;
  expect: array[0..3] of Int64;
begin
  { s = [100, 105, 98, 110]; order-1 predictor pred[i] = s[i-1] }
  expect[0] := 100; expect[1] := 105; expect[2] := 98; expect[3] := 110;
  SetLength(warmup, 1); warmup[0] := 100;
  SetLength(residual, 3);
  residual[0] := expect[1] - expect[0];   //   5
  residual[1] := expect[2] - expect[1];   //  -7
  residual[2] := expect[3] - expect[2];   //  12

  data := BuildFlacPrefix(44100, 1, 16, 4, 4);
  bw.Init;
  WriteFrameHeader(bw, 4, 0, 4, 0, 9);
  WriteSubframeFixed(bw, 1, 16, warmup, residual, 4);
  frame := FinishFrame(bw);
  AppendBytes(data, frame);

  Check(FlacDecode(data, res), 'decodes the FIXED order-1 frame');
  CheckNear(expect[0] / 32768.0, res.Pcm[0][0], 1.0E-6, 'sample 0');
  CheckNear(expect[1] / 32768.0, res.Pcm[0][1], 1.0E-6, 'sample 1');
  CheckNear(expect[2] / 32768.0, res.Pcm[0][2], 1.0E-6, 'sample 2');
  CheckNear(expect[3] / 32768.0, res.Pcm[0][3], 1.0E-6, 'sample 3');
end;

{ ==================== tests: decode - independent stereo ==================== }

procedure Test_Decode_IndependentStereo;
var
  bw: TBitWriter;
  data, frame: TBytes;
  res: TFLACDecodeResult;
  resL, resR: array of Int64;
  left, right: array[0..3] of Int64;
  i: Integer;
begin
  left[0] := 10; left[1] := 20; left[2] := 30; left[3] := 40;
  right[0] := -5; right[1] := -15; right[2] := -25; right[3] := -35;
  SetLength(resL, 4); SetLength(resR, 4);
  for i := 0 to 3 do begin resL[i] := left[i]; resR[i] := right[i]; end;   // order-0: residual == sample

  data := BuildFlacPrefix(44100, 2, 16, 4, 4);
  bw.Init;
  WriteFrameHeader(bw, 4, 1{independent, 2ch}, 4, 0, 9);
  WriteSubframeFixed(bw, 0, 16, [], resL, 5);
  WriteSubframeFixed(bw, 0, 16, [], resR, 5);
  frame := FinishFrame(bw);
  AppendBytes(data, frame);

  Check(FlacDecode(data, res), 'decodes independent stereo');
  CheckEqualInt(2, res.Channels, 'channels');
  for i := 0 to 3 do
  begin
    CheckNear(left[i] / 32768.0, res.Pcm[0][i], 1.0E-6, Format('left[%d]', [i]));
    CheckNear(right[i] / 32768.0, res.Pcm[1][i], 1.0E-6, Format('right[%d]', [i]));
  end;
end;

{ ==================== tests: stereo decorrelation modes ==================== }

procedure DecodeStereoModeFrame(AChannelCode: Integer; const ARaw0, ARaw1: array of Int64;
  AEffBps0, AEffBps1, ARiceK0, ARiceK1: Integer; out ARes: TFLACDecodeResult);
var
  bw: TBitWriter;
  data, frame: TBytes;
  r0, r1: array of Int64;
  i: Integer;
begin
  SetLength(r0, Length(ARaw0));
  SetLength(r1, Length(ARaw1));
  for i := 0 to High(ARaw0) do r0[i] := ARaw0[i];
  for i := 0 to High(ARaw1) do r1[i] := ARaw1[i];

  data := BuildFlacPrefix(44100, 2, 16, Length(ARaw0), Length(ARaw0));
  bw.Init;
  WriteFrameHeader(bw, Length(ARaw0), AChannelCode, 4, 0, 9);
  WriteSubframeFixed(bw, 0, AEffBps0, [], r0, ARiceK0);
  WriteSubframeFixed(bw, 0, AEffBps1, [], r1, ARiceK1);
  frame := FinishFrame(bw);
  AppendBytes(data, frame);

  Check(FlacDecode(data, ARes), 'decodes the stereo-mode frame');
end;

procedure Test_Decode_LeftSideStereo;
const
  left:  array[0..3] of Int64 = (1000, 2000, -500, 300);
  right: array[0..3] of Int64 = (900, 2100, -600, 250);
var
  side: array[0..3] of Int64;
  res: TFLACDecodeResult;
  i: Integer;
begin
  for i := 0 to 3 do side[i] := left[i] - right[i];
  DecodeStereoModeFrame(8{left/side}, left, side, 16, 17, 8, 6, res);
  for i := 0 to 3 do
  begin
    CheckNear(left[i] / 32768.0, res.Pcm[0][i], 1.0E-6, Format('left/side ch0[%d]', [i]));
    CheckNear(right[i] / 32768.0, res.Pcm[1][i], 1.0E-6, Format('left/side ch1[%d]', [i]));
  end;
end;

procedure Test_Decode_RightSideStereo;
const
  left:  array[0..3] of Int64 = (1000, 2000, -500, 300);
  right: array[0..3] of Int64 = (900, 2100, -600, 250);
var
  side: array[0..3] of Int64;
  res: TFLACDecodeResult;
  i: Integer;
begin
  for i := 0 to 3 do side[i] := left[i] - right[i];
  DecodeStereoModeFrame(9{right/side}, side, right, 17, 16, 8, 6, res);
  for i := 0 to 3 do
  begin
    CheckNear(left[i] / 32768.0, res.Pcm[0][i], 1.0E-6, Format('right/side ch0[%d]', [i]));
    CheckNear(right[i] / 32768.0, res.Pcm[1][i], 1.0E-6, Format('right/side ch1[%d]', [i]));
  end;
end;

procedure Test_Decode_MidSideStereo;
const
  left:  array[0..3] of Int64 = (1000, 2000, -500, 300);
  right: array[0..3] of Int64 = (900, 2100, -600, 250);
var
  mid, side: array[0..3] of Int64;
  res: TFLACDecodeResult;
  i: Integer;
begin
  for i := 0 to 3 do
  begin
    mid[i] := (left[i] + right[i]) div 2;    // encoder-side convention: floor((L+R)/2)
    side[i] := left[i] - right[i];
  end;
  DecodeStereoModeFrame(10{mid/side}, mid, side, 16, 17, 8, 6, res);
  for i := 0 to 3 do
  begin
    CheckNear(left[i] / 32768.0, res.Pcm[0][i], 1.0E-6, Format('mid/side ch0[%d]', [i]));
    CheckNear(right[i] / 32768.0, res.Pcm[1][i], 1.0E-6, Format('mid/side ch1[%d]', [i]));
  end;
end;

{ ==================== tests: VERBATIM subframe ==================== }

procedure Test_Decode_VerbatimSubframe;
var
  bw: TBitWriter;
  data, frame: TBytes;
  res: TFLACDecodeResult;
  values: array[0..3] of Int64;
  i: Integer;
begin
  values[0] := 1; values[1] := -1; values[2] := 32767; values[3] := -32768;
  data := BuildFlacPrefix(44100, 1, 16, 4, 4);
  bw.Init;
  WriteFrameHeader(bw, 4, 0, 4, 0, 9);
  WriteSubframeVerbatim(bw, 16, values);
  frame := FinishFrame(bw);
  AppendBytes(data, frame);

  Check(FlacDecode(data, res), 'decodes a VERBATIM subframe');
  for i := 0 to 3 do
    CheckNear(values[i] / 32768.0, res.Pcm[0][i], 1.0E-6, Format('verbatim[%d]', [i]));
end;

{ ==================== tests: CRC handling doesn't crash ==================== }

procedure Test_CrcMismatch_FooterIgnoredNotFatal;
var
  bw: TBitWriter;
  data, frame: TBytes;
  res: TFLACDecodeResult;
begin
  data := BuildFlacPrefix(44100, 1, 16, 4, 4);
  bw.Init;
  WriteFrameHeader(bw, 4, 0, 4, 0, 9);
  WriteSubframeConstant(bw, 16, 777);
  frame := FinishFrame(bw);
  frame[High(frame)] := frame[High(frame)] xor $FF;   // corrupt the CRC-16 footer
  AppendBytes(data, frame);

  Check(FlacDecode(data, res), 'a corrupt frame footer CRC must not fail the whole decode');
  CheckEqualInt(1, res.CrcMismatches, 'the corruption is counted');
  CheckNear(777 / 32768.0, res.Pcm[0][0], 1.0E-6, 'audio data itself is unaffected');
end;

procedure Test_CrcMismatch_HeaderIgnoredNotFatal;
var
  bw: TBitWriter;
  data, frame: TBytes;
  res: TFLACDecodeResult;
  headerCrcByteIndex: Integer;
begin
  data := BuildFlacPrefix(44100, 1, 16, 4, 4);
  bw.Init;
  WriteFrameHeader(bw, 4, 0, 4, 0, 9);
  WriteSubframeConstant(bw, 16, 42);
  frame := FinishFrame(bw);
  { header layout up to (not including) the CRC-8 byte:
      byte0-1: sync(14)+reserved(1)+blocking-strategy(1)
      byte2:   block-size-code(4)+sample-rate-code(4)
      byte3:   channel-code(4)+bps-code(3)+reserved(1)
      byte4:   frame-number (UTF-8-like, 1 byte since < 128)
      byte5:   block-size 8-bit escape payload (code 6 was used)
      byte6:   CRC-8 }
  headerCrcByteIndex := 6;
  frame[headerCrcByteIndex] := frame[headerCrcByteIndex] xor $FF;
  AppendBytes(data, frame);

  Check(FlacDecode(data, res), 'a corrupt frame header CRC must not fail the whole decode');
  CheckEqualInt(1, res.HeaderCrcMismatches, 'the corruption is counted');
  CheckNear(42 / 32768.0, res.Pcm[0][0], 1.0E-6, 'audio data itself is unaffected');
end;

procedure Test_TrailingGarbage_StopsCleanly;
var
  bw: TBitWriter;
  data, frame: TBytes;
  res: TFLACDecodeResult;
  junk: TBytes;
begin
  data := BuildFlacPrefix(44100, 1, 16, 4, 4);
  bw.Init;
  WriteFrameHeader(bw, 4, 0, 4, 0, 9);
  WriteSubframeConstant(bw, 16, 999);
  frame := FinishFrame(bw);
  AppendBytes(data, frame);
  SetLength(junk, 5);
  FillChar(junk[0], 5, $AB);
  AppendBytes(data, junk);

  Check(FlacDecode(data, res), 'trailing junk after a valid frame does not crash decoding');
  CheckEqualInt(4, res.TotalFrames, 'only the one real frame contributes samples');
  CheckNear(999 / 32768.0, res.Pcm[0][0], 1.0E-6, 'decoded data is unaffected by trailing junk');
end;

{ ==================== tests: frame-header rejection paths ==================== }

procedure Test_FrameHeader_RejectsBadSync;
var
  buf: TBytes;
  br: TFlacBitReader;
  si: TFlacStreamInfo;
  hdr: TFlacFrameHeader;
begin
  SetLength(buf, 8);
  FillChar(buf[0], 8, 0);
  FillChar(si, SizeOf(si), 0);
  si.SampleRate := 44100; si.Channels := 2; si.BitsPerSample := 16; si.Present := True;
  br.Init(@buf[0], Length(buf), 0);
  CheckFalse(ParseFlacFrameHeader(buf, br, si, hdr), 'all-zero bytes are not a valid frame sync');
end;

procedure Test_FrameHeader_ValidHeaderParses;
var
  bw: TBitWriter;
  buf: TBytes;
  br: TFlacBitReader;
  si: TFlacStreamInfo;
  hdr: TFlacFrameHeader;
begin
  FillChar(si, SizeOf(si), 0);
  si.SampleRate := 44100; si.Channels := 2; si.BitsPerSample := 16; si.Present := True;
  bw.Init;
  WriteFrameHeader(bw, 128, 8{left/side}, 6{24-bit}, 3, 0{from streaminfo});
  buf := bw.FlushedBytes;
  br.Init(@buf[0], Length(buf), 0);
  Check(ParseFlacFrameHeader(buf, br, si, hdr), 'well-formed header parses');
  Check(hdr.HeaderCrcOk, 'header CRC-8 checks out');
  CheckEqualInt(128, hdr.BlockSize, 'block size (8-bit escape)');
  CheckEqualInt(44100, hdr.SampleRate, 'sample rate resolved from STREAMINFO');
  CheckEqualInt(24, hdr.BitsPerSample, 'bits per sample code 6 -> 24');
  CheckEqualInt(2, hdr.Channels, 'left/side -> 2 channels');
  CheckEqualBool(True, hdr.ChannelAssign = fcaLeftSide, 'channel assignment decoded');
  CheckEqualInt(3, hdr.FrameOrSampleNumber, 'frame number');
end;

{ ==================== tests: encoder round-trip ==================== }

{ Encodes a synthetic multi-block stereo signal to FLAC via FlacEncodeFile,
  decodes it back, and checks: (1) every sample survives the 24-bit round
  trip to within one quantisation step, (2) the encoder's own frame/header
  CRCs are internally self-consistent (CrcMismatches/HeaderCrcMismatches are
  both 0 - proving the writer and Flac_CRC8/16 agree byte-for-byte with what
  the decoder recomputes), and (3) STREAMINFO's sample rate/channel count/
  frame count match the source exactly. FLAC_BLOCK (4096) is not exported, so
  a total well past it exercises the multi-frame path and the shorter final
  block, not just a single frame. }
procedure Test_Encoder_RoundTrip_StereoMultiBlock;
const
  FRAME_COUNT = 10000;      // > one 4096 block, non-multiple -> exercises a short final block
  SAMPLE_RATE = 44100;
var
  wavPath, flacPath: string;
  writer: TWavWriter;
  planar: TAudioPlanar;
  i: Integer;
  res: TFLACDecodeResult;
  maxErr, err: Double;
begin
  wavPath := IncludeTrailingPathDelimiter(Paths.Temp) + 'udaw_flac_enc_test.wav';
  flacPath := IncludeTrailingPathDelimiter(Paths.Temp) + 'udaw_flac_enc_test.flac';
  ForceDirectories(ExtractFilePath(wavPath));

  SetLength(planar, 2);
  SetLength(planar[0], FRAME_COUNT);
  SetLength(planar[1], FRAME_COUNT);
  for i := 0 to FRAME_COUNT - 1 do
  begin
    planar[0][i] := 0.6 * Sin(2 * Pi * 440 * i / SAMPLE_RATE);
    planar[1][i] := 0.3 * Sin(2 * Pi * 220 * i / SAMPLE_RATE) + 0.1 * ((i mod 7) - 3) / 3.0;
  end;

  writer := TWavWriter.Create(wavPath, wsfPCM24, 2, SAMPLE_RATE);
  try
    writer.WriteFrames(planar, FRAME_COUNT);
  finally
    writer.Free;
  end;

  try
    FlacEncodeFile(wavPath, flacPath);
    Check(FlacDecodeFile(flacPath, res), 'decodes the encoder''s own FLAC output');
    CheckEqualInt(2, res.Channels, 'channel count round-trips');
    CheckEqualInt(SAMPLE_RATE, res.SampleRate, 'sample rate round-trips');
    CheckEqualInt(FRAME_COUNT, res.TotalFrames, 'sample-frame count round-trips');
    CheckEqualInt(0, res.CrcMismatches, 'frame footer CRC-16 self-consistent');
    CheckEqualInt(0, res.HeaderCrcMismatches, 'frame header CRC-8 self-consistent');

    maxErr := 0;
    for i := 0 to FRAME_COUNT - 1 do
    begin
      err := Abs(res.Pcm[0][i] - planar[0][i]);
      if err > maxErr then maxErr := err;
      err := Abs(res.Pcm[1][i] - planar[1][i]);
      if err > maxErr then maxErr := err;
    end;
    { one 24-bit quantisation step is 1/8388608 - allow a small margin for
      the float rounding in both the WAV writer's and this test's own
      float->int scaling. }
    Check(maxErr < 4.0 / 8388608.0, Format('lossless round trip (max error %.9f)', [maxErr]));
  finally
    if FileExists(wavPath) then DeleteFile(wavPath);
    if FileExists(flacPath) then DeleteFile(flacPath);
  end;
end;

{ ---------------- registration ---------------- }

procedure RegisterPhaseFLACTests;
begin
  RegisterTest(GRP, 'sniff rejects garbage / too-short / nil', Test_Sniff_RejectsGarbage);
  RegisterTest(GRP, 'sniff accepts fLaC magic', Test_Sniff_AcceptsMagic);
  RegisterTest(GRP, 'sniff never trusts the .flac extension', Test_Sniff_RejectsFlacExtensionOnGarbage);
  RegisterTest(GRP, 'probe reads STREAMINFO fields', Test_Probe_StreamInfoFields);
  RegisterTest(GRP, 'decode - mono CONSTANT subframe', Test_Decode_MonoConstant);
  RegisterTest(GRP, 'decode - mono FIXED order-1 subframe', Test_Decode_MonoFixedOrder1);
  RegisterTest(GRP, 'decode - independent stereo (two FIXED order-0)', Test_Decode_IndependentStereo);
  RegisterTest(GRP, 'decode - left/side stereo decorrelation', Test_Decode_LeftSideStereo);
  RegisterTest(GRP, 'decode - right/side stereo decorrelation', Test_Decode_RightSideStereo);
  RegisterTest(GRP, 'decode - mid/side stereo decorrelation', Test_Decode_MidSideStereo);
  RegisterTest(GRP, 'decode - VERBATIM subframe', Test_Decode_VerbatimSubframe);
  RegisterTest(GRP, 'frame footer CRC-16 mismatch is logged, not fatal', Test_CrcMismatch_FooterIgnoredNotFatal);
  RegisterTest(GRP, 'frame header CRC-8 mismatch is logged, not fatal', Test_CrcMismatch_HeaderIgnoredNotFatal);
  RegisterTest(GRP, 'trailing garbage after the last frame stops cleanly', Test_TrailingGarbage_StopsCleanly);
  RegisterTest(GRP, 'frame header rejects a bad sync code', Test_FrameHeader_RejectsBadSync);
  RegisterTest(GRP, 'frame header parses a well-formed frame', Test_FrameHeader_ValidHeaderParses);
  RegisterTest(GRP, 'encoder round trip - stereo, multi-block, lossless', Test_Encoder_RoundTrip_StereoMultiBlock);
end;

end.
