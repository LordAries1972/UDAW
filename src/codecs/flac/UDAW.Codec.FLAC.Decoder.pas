unit UDAW.Codec.FLAC.Decoder;
{$I udaw.inc}
{$POINTERMATH ON}

{ FLAC decode-only support - the audio decoder.

  Built on UDAW.Codec.FLAC.Frame (metadata + frame-header layer), this unit
  implements the full subframe pipeline: CONSTANT, VERBATIM, FIXED predictors
  (orders 0-4) and LPC (arbitrary order up to 32, quantised coefficients +
  shift), partitioned-Rice residual decoding (both 4-bit and 5-bit parameter
  variants, with the raw-bits escape code), wasted-bits-per-sample handling,
  the three stereo-decorrelation modes (left/side, right/side, mid/side) and
  reconstruction back to independent channels, and the frame footer's CRC-16
  check.

  FLAC carries no explicit frame length in its header, so frames are found by
  fully decoding each one in turn: the point the bit reader reaches right
  after a frame's CRC-16 is exactly where the next frame's sync code begins.
  A CRC-16 mismatch is logged (CrcMismatches) rather than raising - real-world
  files occasionally carry a truncated or slightly corrupt final frame, and
  failing the whole decode over that would throw away otherwise-good audio.

  Output is the engine-wide planar Float32 layout, scaled by the stream's
  bits-per-sample so a lossless round-trip of the integer samples is exact
  modulo that one, unavoidable, int-to-float quantisation step. }

interface

uses
  UDAW.Media.Progress, SysUtils, Classes, Math,
  UDAW.Errors, UDAW.Audio.Types,
  UDAW.Codec.FLAC.Frame;

type
  TFLACDecodeResult = record
    Channels: Integer;
    SampleRate: Integer;
    BitsPerSample: Integer;
    TotalFrames: Int64;            // PCM sample-frames (per channel) produced
    Pcm: TAudioPlanar;              // [ch][frame]
    StreamInfo: TFlacStreamInfo;
    DecodedFrames: Int64;           // FLAC frames (blocks) successfully decoded
    CrcMismatches: Int64;           // frame-footer CRC-16 mismatches (ignored)
    HeaderCrcMismatches: Int64;     // frame-header CRC-8 mismatches (ignored)
  end;

{ Decode an entire in-memory FLAC stream. Raises EUDAWError (errConfig) if no
  STREAMINFO / no decodable frame is found. }
function DecodeFlac(const AData: TBytes; out ARes: TFLACDecodeResult): Boolean;
function DecodeFlacFile(const AFileName: string; out ARes: TFLACDecodeResult): Boolean;

implementation

const
  DEC_SUBSYS = 'Codec.FLAC.Dec';
  FLAC_MAX_CHANNELS = 8;
  FLAC_MAX_BLOCKSIZE = 65536;      // guard rail - real streams stay well under this

type
  TInt64Array = array of Int64;
  { A named dynamic-array-of-dynamic-array type. DecodeOneFlacFrame needs to
    SetLength its per-channel planar buffer; a parameter written inline as
    "var X: array of TInt64Array" is an *open array* parameter, a distinct
    (non-resizable) construct despite the identical syntax, and SetLength on
    it fails with E2008. A named type in the parameter declaration makes it a
    genuine dynamic-array reference instead. }
  TFlacChannelPlanar = array of TInt64Array;

{ ===================== arithmetic-right-shift helper =====================

  Delphi/FPC's `shr` on a signed integer type is a *logical* shift (fills
  vacated high bits with 0), never an arithmetic one - so it must not be used
  to apply an LPC predictor's shift to a (possibly negative) accumulator.
  This is the standard two's-complement identity for arithmetic shift-right of
  a negative value: NOT ( (NOT V) shr Sh ). }
function AShr64(V: Int64; Sh: Integer): Int64; {$IFDEF FPC}inline;{$ENDIF}
begin
  if Sh <= 0 then Exit(V);
  if Sh >= 64 then begin if V < 0 then Exit(-1) else Exit(0); end;
  if V >= 0 then Result := Int64(UInt64(V) shr Sh)
  else Result := not Int64(UInt64(not V) shr Sh);
end;

function ZigZagDecode(AU: UInt64): Int64; {$IFDEF FPC}inline;{$ENDIF}
begin
  if (AU and 1) = 0 then Result := Int64(AU shr 1)
  else Result := -Int64((AU + 1) shr 1);
end;

{ ===================== residual (partitioned Rice) ===================== }

function ReadResidual(var ABr: TFlacBitReader; ABlockSize, AOrder: Integer;
  var AResidual: TInt64Array): Boolean;
var
  method, paramBits, partOrder, partitions, samplesPerPart: Integer;
  p, cnt, i, idx, riceParam, rawBits, escapeVal: Integer;
  u, q: UInt64;
begin
  Result := False;
  method := Integer(ABr.ReadBits(2));
  if method > 1 then Exit;              // 2,3 reserved
  if method = 0 then paramBits := 4 else paramBits := 5;
  escapeVal := (1 shl paramBits) - 1;

  partOrder := Integer(ABr.ReadBits(4));
  partitions := 1 shl partOrder;
  if partitions <= 0 then Exit;
  if (ABlockSize mod partitions) <> 0 then Exit;
  samplesPerPart := ABlockSize div partitions;
  if AOrder > samplesPerPart then Exit;

  SetLength(AResidual, ABlockSize - AOrder);
  idx := 0;
  for p := 0 to partitions - 1 do
  begin
    if p = 0 then cnt := samplesPerPart - AOrder else cnt := samplesPerPart;
    riceParam := Integer(ABr.ReadBits(paramBits));
    if riceParam = escapeVal then
    begin
      rawBits := Integer(ABr.ReadBits(5));
      for i := 1 to cnt do
      begin
        if idx >= Length(AResidual) then Exit;
        AResidual[idx] := ABr.ReadSigned(rawBits);
        Inc(idx);
      end;
    end
    else
    begin
      for i := 1 to cnt do
      begin
        if idx >= Length(AResidual) then Exit;
        { two separate bit-reader calls sequenced explicitly - do not fold into
          one expression via `or`: operand evaluation order for a binary
          operator is not guaranteed, and reading the k remainder bits before
          the unary quotient would silently corrupt every residual after it }
        q := ABr.ReadUnary;
        u := (q shl riceParam) or ABr.ReadBitsBig(riceParam);
        AResidual[idx] := ZigZagDecode(u);
        Inc(idx);
        if ABr.Overrun then Exit;
      end;
    end;
    if ABr.Overrun then Exit;
  end;
  Result := idx = Length(AResidual);
end;

{ ===================== subframe decode ===================== }

function DecodeSubframe(var ABr: TFlacBitReader; ABlockSize, ABps: Integer;
  var ASamples: TInt64Array): Boolean;
var
  zeroBit, subType, wastedFlag: Cardinal;
  wasted, order, i, j: Integer;
  effBps: Integer;
  residual: TInt64Array;
  precisionField, precision, shiftField, shift: Integer;
  coefs: array of Int64;
  sum: Int64;
begin
  Result := False;
  SetLength(ASamples, ABlockSize);

  zeroBit := ABr.ReadBits(1);
  if zeroBit <> 0 then Exit;             // padding bit must be 0
  subType := ABr.ReadBits(6);
  wastedFlag := ABr.ReadBits(1);
  wasted := 0;
  if wastedFlag = 1 then
    wasted := Integer(ABr.ReadUnary) + 1;
  if ABr.Overrun then Exit;

  effBps := ABps - wasted;
  if effBps <= 0 then Exit;

  if subType = 0 then
  begin
    { CONSTANT }
    var v: Int64 := ABr.ReadSigned(effBps);
    for i := 0 to ABlockSize - 1 do ASamples[i] := v;
    Result := not ABr.Overrun;
  end
  else if subType = 1 then
  begin
    { VERBATIM }
    for i := 0 to ABlockSize - 1 do
      ASamples[i] := ABr.ReadSigned(effBps);
    Result := not ABr.Overrun;
  end
  else if (subType >= 8) and (subType <= 12) then
  begin
    { FIXED predictor, order 0..4 }
    order := Integer(subType) - 8;
    if order > ABlockSize then Exit;
    for i := 0 to order - 1 do
      ASamples[i] := ABr.ReadSigned(effBps);
    if ABr.Overrun then Exit;
    if not ReadResidual(ABr, ABlockSize, order, residual) then Exit;
    for i := order to ABlockSize - 1 do
    begin
      case order of
        0: ASamples[i] := residual[i - order];
        1: ASamples[i] := ASamples[i-1] + residual[i - order];
        2: ASamples[i] := 2*ASamples[i-1] - ASamples[i-2] + residual[i - order];
        3: ASamples[i] := 3*ASamples[i-1] - 3*ASamples[i-2] + ASamples[i-3] + residual[i - order];
        4: ASamples[i] := 4*ASamples[i-1] - 6*ASamples[i-2] + 4*ASamples[i-3] - ASamples[i-4] + residual[i - order];
      end;
    end;
    Result := True;
  end
  else if subType >= 32 then
  begin
    { LPC, order = (subType and $1F) + 1 }
    order := (Integer(subType) and $1F) + 1;
    if (order > ABlockSize) or (order > 32) then Exit;
    for i := 0 to order - 1 do
      ASamples[i] := ABr.ReadSigned(effBps);
    if ABr.Overrun then Exit;

    precisionField := Integer(ABr.ReadBits(4));
    if precisionField = 15 then Exit;    // reserved / invalid marker
    precision := precisionField + 1;
    shiftField := Integer(ABr.ReadSigned(5));
    shift := shiftField;
    if shift < 0 then shift := 0;        // spec-legal field, never emitted by real encoders

    SetLength(coefs, order);
    for i := 0 to order - 1 do
      coefs[i] := ABr.ReadSigned(precision);
    if ABr.Overrun then Exit;

    if not ReadResidual(ABr, ABlockSize, order, residual) then Exit;

    for i := order to ABlockSize - 1 do
    begin
      sum := 0;
      for j := 0 to order - 1 do
        sum := sum + coefs[j] * ASamples[i - 1 - j];
      ASamples[i] := AShr64(sum, shift) + residual[i - order];
    end;
    Result := True;
  end
  else
    Exit;    // reserved subframe type (0x02..0x07, 0x0D..0x1F)

  { restore wasted bits (applies to every subframe type uniformly) }
  if Result and (wasted > 0) then
    for i := 0 to ABlockSize - 1 do
      ASamples[i] := ASamples[i] shl wasted;
end;

{ ===================== one frame ===================== }

{ Decode exactly one FLAC frame starting at ABr's current position (which must
  sit at the frame's sync byte). On success ABr is left positioned at the next
  frame's first byte (or end of stream) and AChannels[ch] holds ABlockSize
  reconstructed integer samples per channel. }
function DecodeOneFlacFrame(const AData: TBytes; var ABr: TFlacBitReader;
  const AStreamInfo: TFlacStreamInfo; out AHdr: TFlacFrameHeader;
  var AChannels: TFlacChannelPlanar; out AHeaderCrcBad, AFooterCrcBad: Boolean): Boolean;
var
  ch, i, bpsCh0, bpsCh1: Integer;
  raw: array[0..FLAC_MAX_CHANNELS - 1] of TInt64Array;
  mid, side, midShifted: Int64;
  frameStartByte, crcEndByte: Integer;
  crc16Stored: Word;
  crc16Calc: Word;
begin
  Result := False;
  AHeaderCrcBad := False;
  AFooterCrcBad := False;
  frameStartByte := ABr.BytePos;

  if not ParseFlacFrameHeader(AData, ABr, AStreamInfo, AHdr) then Exit;
  if not AHdr.HeaderCrcOk then AHeaderCrcBad := True;
  if AHdr.Channels > FLAC_MAX_CHANNELS then Exit;
  if AHdr.BlockSize > FLAC_MAX_BLOCKSIZE then Exit;

  case AHdr.ChannelAssign of
    fcaLeftSide:  begin bpsCh0 := AHdr.BitsPerSample; bpsCh1 := AHdr.BitsPerSample + 1; end;
    fcaRightSide: begin bpsCh0 := AHdr.BitsPerSample + 1; bpsCh1 := AHdr.BitsPerSample; end;
    fcaMidSide:   begin bpsCh0 := AHdr.BitsPerSample; bpsCh1 := AHdr.BitsPerSample + 1; end;
  else
    bpsCh0 := AHdr.BitsPerSample;
    bpsCh1 := AHdr.BitsPerSample;
  end;

  for ch := 0 to AHdr.Channels - 1 do
  begin
    var chBps: Integer;
    if ch = 0 then chBps := bpsCh0
    else if ch = 1 then chBps := bpsCh1
    else chBps := AHdr.BitsPerSample;
    if not DecodeSubframe(ABr, AHdr.BlockSize, chBps, raw[ch]) then Exit;
  end;
  if ABr.Overrun then Exit;

  { stereo reconstruction }
  SetLength(AChannels, AHdr.Channels);
  for ch := 0 to AHdr.Channels - 1 do
    SetLength(AChannels[ch], AHdr.BlockSize);

  case AHdr.ChannelAssign of
    fcaIndependent:
      for ch := 0 to AHdr.Channels - 1 do
        for i := 0 to AHdr.BlockSize - 1 do
          AChannels[ch][i] := raw[ch][i];
    fcaLeftSide:
      for i := 0 to AHdr.BlockSize - 1 do
      begin
        AChannels[0][i] := raw[0][i];                       // left
        AChannels[1][i] := raw[0][i] - raw[1][i];            // right = left - side
      end;
    fcaRightSide:
      for i := 0 to AHdr.BlockSize - 1 do
      begin
        AChannels[1][i] := raw[1][i];                        // right
        AChannels[0][i] := raw[1][i] + raw[0][i];             // left = right + side
      end;
    fcaMidSide:
      for i := 0 to AHdr.BlockSize - 1 do
      begin
        mid := raw[0][i];
        side := raw[1][i];
        midShifted := (mid shl 1) or (side and 1);
        AChannels[0][i] := (midShifted + side) div 2;         // always exact (sum is even)
        AChannels[1][i] := (midShifted - side) div 2;
      end;
  end;

  { byte-align, then the frame footer's CRC-16 over [frameStartByte, crcEndByte) }
  ABr.AlignToByte;
  if ABr.Overrun then Exit;
  crc16Stored := Word(ABr.ReadBits(16));
  if ABr.Overrun then Exit;
  crcEndByte := ABr.BytePos - 2;
  crc16Calc := Flac_CRC16(AData, frameStartByte, crcEndByte - frameStartByte);
  if crc16Calc <> crc16Stored then AFooterCrcBad := True;

  Result := True;
end;

{ ===================== whole-stream decode ===================== }

function DecodeFlac(const AData: TBytes; out ARes: TFLACDecodeResult): Boolean;
var
  audioStart: Int64;
  br: TFlacBitReader;
  hdr: TFlacFrameHeader;
  channels: TFlacChannelPlanar;
  headerBad, footerBad: Boolean;
  ch, i: Integer;
  outPos, capacity: Int64;
  bps: Integer;
  scale: Double;
  len: Int64;
begin
  FillChar(ARes, SizeOf(ARes), 0);

  len := Length(AData);
  if not ScanFlacMetadata(AData, ARes.StreamInfo, audioStart) then
    RaiseUDAW(errConfig, DEC_SUBSYS, 'no FLAC STREAMINFO block found');

  ARes.Channels := ARes.StreamInfo.Channels;
  ARes.SampleRate := ARes.StreamInfo.SampleRate;
  ARes.BitsPerSample := ARes.StreamInfo.BitsPerSample;
  if (ARes.Channels <= 0) or (ARes.SampleRate <= 0) or (ARes.BitsPerSample <= 0) then
    RaiseUDAW(errConfig, DEC_SUBSYS, 'STREAMINFO reports an unusable stream shape');

  capacity := ARes.StreamInfo.TotalSamples;
  if capacity <= 0 then capacity := Max(len, 4096);       // unknown length: guess, grow later
  Inc(capacity, 65536);
  SetLength(ARes.Pcm, ARes.Channels);
  for ch := 0 to ARes.Channels - 1 do
    SetLength(ARes.Pcm[ch], capacity);

  br.Init(@AData[0], Integer(len), Integer(audioStart));
  outPos := 0;

  while br.BytePos + 2 <= len do
  begin
    if not DecodeOneFlacFrame(AData, br, ARes.StreamInfo, hdr, channels, headerBad, footerBad) then
      Break;                          // trailing junk / truncation - stop, keep what we have

    if headerBad then Inc(ARes.HeaderCrcMismatches);
    if footerBad then Inc(ARes.CrcMismatches);

    if hdr.Channels <> ARes.Channels then
      Break;                          // malformed - a real FLAC stream never changes channel count

    if outPos + hdr.BlockSize > capacity then
    begin
      capacity := outPos + hdr.BlockSize + 65536;
      for ch := 0 to ARes.Channels - 1 do
        SetLength(ARes.Pcm[ch], capacity);
    end;

    bps := ARes.BitsPerSample;
    scale := 1.0 / Double(Int64(1) shl (bps - 1));
    for ch := 0 to ARes.Channels - 1 do
      for i := 0 to hdr.BlockSize - 1 do
        ARes.Pcm[ch][outPos + i] := Single(channels[ch][i] * scale);

    Inc(outPos, hdr.BlockSize);
    Inc(ARes.DecodedFrames);
    if ARes.StreamInfo.TotalSamples > 0 then
      ReportMediaProgress('Decoding FLAC', outPos, ARes.StreamInfo.TotalSamples, ARes.SampleRate)
    else
      ReportMediaProgress('Decoding FLAC', br.BytePos, len);
  end;

  if ARes.DecodedFrames = 0 then
    RaiseUDAW(errConfig, DEC_SUBSYS, 'no decodable FLAC frames found');

  ARes.TotalFrames := outPos;
  for ch := 0 to ARes.Channels - 1 do
    SetLength(ARes.Pcm[ch], outPos);

  Result := ARes.TotalFrames > 0;
end;

function DecodeFlacFile(const AFileName: string; out ARes: TFLACDecodeResult): Boolean;
var
  fs: TFileStream;
  data: TBytes;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, DEC_SUBSYS, 'FLAC file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(data, fs.Size);
    if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
  finally
    fs.Free;
  end;
  Result := DecodeFlac(data, ARes);
end;

end.
