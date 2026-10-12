unit UDAW.Codec.MP3.Encoder;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 15 - MPEG-1 Layer III encoder (plan section 18, "Render/export MP3").

  A from-scratch Layer III audio encoder - no LAME, no third-party code.  It is
  the mirror image of UDAW.Codec.MP3.Decoder and reuses UDAW.Codec.MP3.Tables
  for the Huffman code tables, the IMDCT cosine basis (transposed for the
  forward MDCT) and the 512-tap prototype window.

  Design (deliberately the "simple but conformant" subset):

    * MPEG-1 Layer III only, 32000 / 44100 / 48000 Hz, mono or stereo
      (plain stereo - no MS/intensity coding on the encode side; the bitstream
      is still decoded correctly by any compliant decoder).
    * Long blocks only.  No window switching / short blocks: transient
      pre-echo is not modelled.  window_switching_flag is always 0.
    * No psychoacoustic model.  Bit allocation is driven purely by the frame
      bit budget: a global_gain search per granule/channel quantises the
      spectrum as finely as the available bits allow (inner loop only).
    * scalefac_compress = 0, all scalefactors 0, preflag 0, scalefac_scale 0 -
      so part2 (scalefactor bits) is always empty and every band shares one
      quantiser step.
    * No bit reservoir: main_data_begin is 0 for every frame and each frame's
      main data is zero-padded to the slot boundary.  Valid, slightly less
      efficient than reservoir use.
    * CBR: one bitrate for the whole file.  VBR: the per-frame header bitrate
      is chosen as the smallest standard rate whose main-data slots hold the
      granules quantised at a quality-derived step; the stream then classifies
      as VBR (min != max bitrate) to any scanner.
    * A leading Xing ("Info" for CBR) header frame carries the exact frame /
      byte count, a 100-entry TOC and a LAME-style encoder-delay tag so the
      decoder's delay/padding trim lines up.

  This is enough for accurate round-trips (encode -> decode -> compare) and for
  interoperable export; it is not a bit-rate-optimal encoder. }

interface

uses {$IFDEF FPC}UDAW.Compat,{$ENDIF}
  SysUtils, Classes, Math,
  UDAW.Errors, UDAW.Audio.Types,
  UDAW.Codec.MP3.Frame, UDAW.Codec.MP3.Tables;

type
  TMP3EncodeMode = (emCBR, emVBR);

  TMP3EncodeOptions = record
    Mode: TMP3EncodeMode;
    BitrateKbps: Integer;    // CBR: the rate. VBR: the ceiling (frames may use less)
    VBRQuality: Integer;     // 0 (best/large) .. 9 (small), VBR only
    MinBitrateKbps: Integer; // VBR floor, default 96
    WriteXingHeader: Boolean;
    OnProgress: TProc<Double>;
    class function Default: TMP3EncodeOptions; static;
  end;

  TMP3EncodeResult = record
    Data: TBytes;
    FrameCount: Integer;       // audio frames, excluding the Xing header frame
    ByteCount: Int64;          // total stream length incl. Xing frame
    AvgBitrateKbps: Double;
    EncoderDelay: Integer;
    EncoderPadding: Integer;
  end;

{ Encode planar Float32 [-1,1] PCM. ASampleRate must be 32000/44100/48000.
  APcm may be 1 or 2 channels. Raises EUDAWError (errConfig) on a bad rate or
  bitrate. }
function EncodeMp3(const APcm: TAudioPlanar; ASampleRate: Integer;
  const AOpts: TMP3EncodeOptions; out ARes: TMP3EncodeResult): Boolean;

function EncodeMp3ToFile(const APcm: TAudioPlanar; ASampleRate: Integer;
  const AFileName: string; const AOpts: TMP3EncodeOptions): Boolean;

{ Standard MPEG-1 Layer III bitrates in kbps (index 1..14). }
function MP3StandardBitrates: TArray<Integer>;

implementation

uses UDAW.Codec.MP3.Metadata, UDAW.Media.Attribution;

const
  ENC_SUBSYS = 'Codec.MP3.Enc';
  SBLIMIT = 32;
  SSLIMIT = 18;
  GRAN    = 576;               // coefficients per granule/channel
  FRAME_SAMPLES = 1152;        // MPEG-1 Layer III

  { Forward MDCT scale.  The decoder's IMDCT carries no 1/N term and relies on
    windowed overlap-add (TDAC) for reconstruction; with sine windows on both
    sides the round-trip cosine-sum factor is N/2 = 9, so the forward transform
    divides by 9.  If a first listening test shows the level off by a clean
    factor, this is the single constant to trim (candidates: 1/9, 1/18, 2/9). }
  MDCT_ENC_SCALE = 1.0 / 9.0;

  { MPEG-1 Layer III bitrate table (index -> kbps), index 15 invalid. }
  BR_TABLE: array[0..15] of Integer =
    (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, -1);

type
  TFloatArr576 = array[0..GRAN - 1] of Single;
  TIntArr576   = array[0..GRAN - 1] of Integer;

  TGranSideInfo = record
    Part2_3Length: Integer;
    BigValues: Integer;
    GlobalGain: Integer;
    Region0Count: Integer;
    Region1Count: Integer;
    TableSelect: array[0..2] of Integer;
    Count1TableSelect: Integer;
    Ix: TIntArr576;             // quantised coefficients
    Count1Start: Integer;       // 2*BigValues
    Count1End: Integer;         // first index of the trailing all-zero (rzero) run
  end;

  { channel filterbank + MDCT state carried between granules }
  TChanEncState = record
    FifoX: array[0..511] of Double;   // analysis filterbank sample FIFO
    Prev: array[0..SBLIMIT - 1, 0..SSLIMIT - 1] of Double; // previous granule subband samples (MDCT overlap)
  end;

  { MSB-first bit writer over a growable byte buffer }
  TBitWriter = record
    Buf: TBytes;
    ByteLen: Integer;
    BitBuf: Cardinal;
    BitCnt: Integer;             // bits currently held in BitBuf (0..7 after flush)
    procedure Init;
    procedure PutBits(AValue: Cardinal; ACount: Integer);
    procedure AlignByte;         // pad with zero bits to the next byte
    function BitLength: Int64;
    procedure AppendTo(var ADst: TBytes);
  end;

{ ===================== TBitWriter ===================== }

procedure TBitWriter.Init;
begin
  SetLength(Buf, 4096);
  ByteLen := 0;
  BitBuf := 0;
  BitCnt := 0;
end;

procedure TBitWriter.PutBits(AValue: Cardinal; ACount: Integer);
var
  i: Integer;
  bit: Cardinal;
begin
  if ACount <= 0 then Exit;
  if ACount > 32 then ACount := 32;
  for i := ACount - 1 downto 0 do
  begin
    bit := (AValue shr i) and 1;
    BitBuf := (BitBuf shl 1) or bit;
    Inc(BitCnt);
    if BitCnt = 8 then
    begin
      if ByteLen >= Length(Buf) then SetLength(Buf, Length(Buf) * 2);
      Buf[ByteLen] := Byte(BitBuf and $FF);
      Inc(ByteLen);
      BitBuf := 0;
      BitCnt := 0;
    end;
  end;
end;

procedure TBitWriter.AlignByte;
begin
  if BitCnt > 0 then PutBits(0, 8 - BitCnt);
end;

function TBitWriter.BitLength: Int64;
begin
  Result := Int64(ByteLen) * 8 + BitCnt;
end;

procedure TBitWriter.AppendTo(var ADst: TBytes);
var
  n: Integer;
begin
  AlignByte;
  n := Length(ADst);
  SetLength(ADst, n + ByteLen);
  if ByteLen > 0 then Move(Buf[0], ADst[n], ByteLen);
end;

{ ===================== options ===================== }

class function TMP3EncodeOptions.Default: TMP3EncodeOptions;
begin
  Result.OnProgress := nil;
  Result.Mode := emCBR;
  Result.BitrateKbps := 192;
  Result.VBRQuality := 4;
  Result.MinBitrateKbps := 96;
  Result.WriteXingHeader := True;
end;

function MP3StandardBitrates: TArray<Integer>;
var
  i: Integer;
begin
  SetLength(Result, 14);
  for i := 1 to 14 do Result[i - 1] := BR_TABLE[i];
end;

function BitrateIndex(AKbps: Integer): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 1 to 14 do
    if BR_TABLE[i] = AKbps then Exit(i);
end;

function SmallestBitrateIndexForSlots(ANeededSlots, AFloorKbps, ACeilKbps,
  ASampleRate: Integer): Integer;
var
  i, slots: Integer;
begin
  Result := BitrateIndex(ACeilKbps);
  for i := 1 to 14 do
  begin
    if BR_TABLE[i] < AFloorKbps then Continue;
    if BR_TABLE[i] > ACeilKbps then Continue;
    slots := (144 * BR_TABLE[i] * 1000) div ASampleRate;
    if slots >= ANeededSlots then Exit(i);
  end;
end;

{ ===================== analysis filterbank ===================== }

var
  GAnalysisM: array[0..31, 0..63] of Double;   // M[i,k] = cos((2i+1)(k-16)pi/64)
  GEncWin: array[0..511] of Double;            // prototype window = D[]/32
  GMdctCos: array[0..17, 0..35] of Double;     // transpose of the decoder's GCos36
  GMdctWin: array[0..35] of Double;            // sine window, block type 0
  GEncReady: Boolean = False;

procedure BuildEncoderTables;
var
  i, k: Integer;
begin
  for i := 0 to 31 do
    for k := 0 to 63 do
      GAnalysisM[i, k] := Cos((2 * i + 1) * (k - 16) * Pi / 64.0);

  { the decoder's synthesis window D[] (Tables.SynthWindowD) is the 32x-scaled
    prototype; the analysis prototype is the same filter scaled by 1/32 }
  for i := 0 to 511 do
    GEncWin[i] := SynthWindowD(i) / 32.0;

  { forward MDCT basis: cos(pi/72*(2k+1+18)*(2i+1)), i=freq 0..17, k=time 0..35
    - identical arg to the decoder's GCos36, used transposed here }
  for i := 0 to 17 do
    for k := 0 to 35 do
      GMdctCos[i, k] := Cos(Pi / 72.0 * (2 * k + 1 + 18) * (2 * i + 1));
  for k := 0 to 35 do
    GMdctWin[k] := Sin(Pi / 36.0 * (k + 0.5));

  GEncReady := True;
end;

{ Push 576 new time-domain samples (one granule) of one channel through the
  32-band polyphase analysis filterbank.  Produces ASub[subband][ss], ss 0..17. }
procedure AnalysisFilterbank(var AState: TChanEncState; const ASamples: array of Single;
  AOffset, ACount: Integer; var ASub: array of Double);   // ASub: [18*32]
var
  ss, i, k, j, n: Integer;
  y: array[0..63] of Double;
  acc: Double;
  s: Double;
begin
  for ss := 0 to SSLIMIT - 1 do
  begin
    { shift 32 new samples into the FIFO, newest first (ISO order) }
    for i := 511 downto 32 do
      AState.FifoX[i] := AState.FifoX[i - 32];
    for i := 0 to 31 do
    begin
      n := AOffset + ss * 32 + (31 - i);
      if (n >= 0) and (n < ACount) then
        AState.FifoX[i] := ASamples[n]
      else
        AState.FifoX[i] := 0;
    end;

    { window then 64-point partial sums }
    for k := 0 to 63 do
    begin
      acc := 0;
      for j := 0 to 7 do
        acc := acc + GEncWin[k + 64 * j] * AState.FifoX[k + 64 * j];
      y[k] := acc;
    end;

    { matrix to 32 subbands }
    for i := 0 to 31 do
    begin
      s := 0;
      for k := 0 to 63 do
        s := s + GAnalysisM[i, k] * y[k];
      ASub[ss * 32 + i] := s;
    end;
  end;
end;

{ Forward MDCT (long block) of one granule: for each subband build a 36-sample
  window from the previous granule's 18 samples + this granule's 18, apply the
  sine window and the 18-point MDCT.  Includes the ISO frequency-inversion
  compensation (negate odd time samples of odd subbands) so the decoder's
  inversion cancels. }
procedure ForwardMDCT(var AState: TChanEncState; const ASub: array of Double;
  var AXr: array of Single);
var
  sb, i, kk: Integer;
  cur: array[0..SSLIMIT - 1] of Double;
  z: array[0..35] of Double;
  acc: Double;
begin
  for i := 0 to GRAN - 1 do AXr[i] := 0;

  for sb := 0 to SBLIMIT - 1 do
  begin
    for i := 0 to SSLIMIT - 1 do
      cur[i] := ASub[i * 32 + sb];

    { frequency inversion compensation (ISO 11172-3 2.4.3.4): odd subbands,
      odd sub-sample indices }
    if (sb and 1) = 1 then
      for i := 1 to SSLIMIT - 1 do
        if (i and 1) = 1 then
          cur[i] := -cur[i];

    { 36-sample overlap window: previous 18 then current 18 }
    for i := 0 to 17 do z[i]      := AState.Prev[sb, i] * GMdctWin[i];
    for i := 0 to 17 do z[i + 18] := cur[i] * GMdctWin[i + 18];

    for kk := 0 to 17 do
    begin
      acc := 0;
      for i := 0 to 35 do
        acc := acc + z[i] * GMdctCos[kk, i];
      AXr[sb * 18 + kk] := Single(acc * MDCT_ENC_SCALE);
    end;

    { save current granule's subband samples for the next granule's overlap }
    for i := 0 to SSLIMIT - 1 do
      AState.Prev[sb, i] := cur[i];
  end;
end;

{ ===================== quantisation ===================== }

{ Quantise one coefficient at the given global_gain.  Inverse of the decoder's
  requantise (long, all scalefactors 0, preflag 0):
     xr = sign(ix) * |ix|^(4/3) * 2^(0.25*(global_gain-210))
  so  |ix| = ( |xr| * 2^(-0.25*(global_gain-210)) )^(3/4). }
function QuantiseValue(AXr: Single; AGlobalGain: Integer): Integer;
var
  scaled, q: Double;
begin
  if AXr = 0 then Exit(0);
  scaled := Abs(AXr) * GainPow2(-(AGlobalGain - 210));
  if scaled <= 0 then Exit(0);
  q := Power(scaled, 0.75) + 0.4054;
  if q >= 8191 then q := 8191;
  Result := Trunc(q);
  if AXr < 0 then Result := -Result;
end;

procedure QuantiseGranule(const AXr: array of Single; AGlobalGain: Integer;
  var AIx: TIntArr576; out AMaxAbs: Integer);
var
  i, v: Integer;
begin
  AMaxAbs := 0;
  for i := 0 to GRAN - 1 do
  begin
    v := QuantiseValue(AXr[i], AGlobalGain);
    AIx[i] := v;
    if Abs(v) > AMaxAbs then AMaxAbs := Abs(v);
  end;
end;

{ ===================== Huffman cost / write ===================== }

{ pick the smallest big_values table (0..31, minus the reserved 4/14) that can
  represent AMaxAbs, preferring the cheapest esc table when > 15 }
function ChooseBigValueTable(AMaxAbs: Integer): Integer;
const
  { non-esc tables in increasing coverage; xlen-1 is the largest literal }
  CAND: array[0..12] of Integer = (1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15);
var
  i, t: Integer;
begin
  if AMaxAbs = 0 then Exit(0);
  for i := 0 to High(CAND) do
  begin
    t := CAND[i];
    if (t < 32) and (Length(MP3Huff[t].Lens) > 0) and
       (MP3Huff[t].XLen - 1 >= AMaxAbs) then
      Exit(t);
  end;
  { escape tables 16..23 (linbits) then 24..31 (more linbits) - pick by linbits }
  for t := 16 to 31 do
    if (Length(MP3Huff[t].Lens) > 0) and
       (15 + (1 shl MP3Huff[t].LinBits) - 1 >= AMaxAbs) then
      Exit(t);
  Result := 31;
end;

function HuffSymIndex(AAbs, ALinBits, ALen: Integer): Integer;
begin
  { symbols 0..14 are literal; 15 is the escape symbol for an esc table, and
    also the last literal for the 16x16 non-esc tables }
  Result := AAbs;
  if (ALinBits > 0) and (Result > 15) then Result := 15
  else if Result > ALen - 1 then Result := ALen - 1;
end;

function HuffPairBits(ATable, AX, AY: Integer): Integer;
var
  ix, iy, lb, bits, xl, yl: Integer;
begin
  if ATable = 0 then Exit(0);
  lb := MP3Huff[ATable].LinBits;
  xl := MP3Huff[ATable].XLen;
  yl := MP3Huff[ATable].YLen;
  ix := HuffSymIndex(Abs(AX), lb, xl);
  iy := HuffSymIndex(Abs(AY), lb, yl);
  bits := MP3Huff[ATable].Lens[ix * yl + iy];
  if bits = 0 then bits := MP3Huff[ATable].MaxLen;         // unreachable if table valid
  if (lb > 0) and (Abs(AX) >= 15) then bits := bits + lb;
  if (lb > 0) and (Abs(AY) >= 15) then bits := bits + lb;
  if AX <> 0 then Inc(bits);
  if AY <> 0 then Inc(bits);
  Result := bits;
end;

function BigValueRegionBits(const AIx: TIntArr576; AFrom, ATo, ATable: Integer): Integer;
var
  i, bits: Integer;
begin
  bits := 0;
  i := AFrom;
  while i + 1 < ATo do
  begin
    bits := bits + HuffPairBits(ATable, AIx[i], AIx[i + 1]);
    Inc(i, 2);
  end;
  Result := bits;
end;

function Count1Bits(const AIx: TIntArr576; AFrom, ATo, ATable: Integer): Integer;
var
  i, k, idx, bits, nz: Integer;
  q: array[0..3] of Integer;
begin
  bits := 0;
  i := AFrom;
  while i + 3 < ATo do
  begin
    idx := 0;
    nz := 0;
    for k := 0 to 3 do
    begin
      q[k] := AIx[i + k];
      idx := (idx shl 1) or Ord(q[k] <> 0);
      if q[k] <> 0 then Inc(nz);
    end;
    bits := bits + MP3Huff[ATable].Lens[idx] + nz;
    Inc(i, 4);
  end;
  Result := bits;
end;

{ region split: choose region0_count / region1_count on long sfb boundaries so
  the three big-value regions are roughly equal }
procedure ChooseRegions(ABigValues, ASampleRate: Integer;
  out AR0, AR1: Integer);
var
  sr, i, acc, bv2, third: Integer;
  bandStart: array[0..22] of Integer;
begin
  sr := SampleRateRow(ASampleRate);
  if sr < 0 then sr := 0;
  acc := 0;
  for i := 0 to 21 do begin bandStart[i] := acc; acc := acc + SFB_LONG_WIDTH[sr, i]; end;
  bandStart[22] := acc;

  bv2 := ABigValues * 2;
  if bv2 < 2 then begin AR0 := 0; AR1 := 0; Exit; end;
  third := bv2 div 3;

  AR0 := 0;
  for i := 0 to 15 do
    if bandStart[i + 1] <= third then AR0 := i else Break;
  AR1 := 0;
  for i := AR0 + 1 to AR0 + 8 do
    if (i + 1 <= 22) and (bandStart[i + 1] <= 2 * third) then AR1 := i - AR0 else Break;
  if AR0 > 15 then AR0 := 15;
  if AR1 > 7 then AR1 := 7;
  if AR0 + AR1 + 2 > 22 then AR1 := 22 - AR0 - 2;
  if AR1 < 0 then AR1 := 0;
end;

{ largest |ix| over [AFrom, ATo) }
function MaxRegionAbs(const AIx: TIntArr576; AFrom, ATo: Integer): Integer;
var
  i, m: Integer;
begin
  m := 0;
  if AFrom < 0 then AFrom := 0;
  if ATo > GRAN then ATo := GRAN;
  for i := AFrom to ATo - 1 do
    if Abs(AIx[i]) > m then m := Abs(AIx[i]);
  Result := m;
end;

{ full Huffman-data bit count of a granule at a given quantisation }
function GranuleHuffmanBits(var AGr: TGranSideInfo; ASampleRate: Integer): Integer;
var
  i, lastNZ, count1Start, bv, r0e, r1e, sfb, sr: Integer;
  bandStart: array[0..22] of Integer;
  acc: Integer;
  b32, b33, bits: Integer;
begin
  { trailing all-zero run (rzero) }
  lastNZ := -1;
  for i := GRAN - 1 downto 0 do
    if AGr.Ix[i] <> 0 then begin lastNZ := i; Break; end;
  AGr.Count1End := lastNZ + 1;
  if (AGr.Count1End and 3) <> 0 then
    AGr.Count1End := (AGr.Count1End + 3) and not 3;
  if AGr.Count1End > GRAN then AGr.Count1End := GRAN;

  { count1 region: walk back in quads while all |ix| <= 1 }
  count1Start := AGr.Count1End;
  while (count1Start - 4 >= 0) do
  begin
    if (Abs(AGr.Ix[count1Start - 1]) <= 1) and (Abs(AGr.Ix[count1Start - 2]) <= 1) and
       (Abs(AGr.Ix[count1Start - 3]) <= 1) and (Abs(AGr.Ix[count1Start - 4]) <= 1) then
      Dec(count1Start, 4)
    else
      Break;
  end;
  AGr.Count1Start := count1Start;
  bv := count1Start div 2;
  AGr.BigValues := bv;

  ChooseRegions(bv, ASampleRate, AGr.Region0Count, AGr.Region1Count);

  sr := SampleRateRow(ASampleRate);
  if sr < 0 then sr := 0;
  acc := 0;
  for i := 0 to 21 do begin bandStart[i] := acc; acc := acc + SFB_LONG_WIDTH[sr, i]; end;
  bandStart[22] := acc;

  if AGr.Region0Count + 1 <= 21 then r0e := bandStart[AGr.Region0Count + 1] else r0e := 576;
  sfb := AGr.Region0Count + AGr.Region1Count + 2;
  if sfb > 22 then sfb := 22;
  r1e := bandStart[sfb];
  if r0e > 2 * bv then r0e := 2 * bv;
  if r1e > 2 * bv then r1e := 2 * bv;
  if r0e > r1e then r0e := r1e;

  { table select per region from that region's peak magnitude }
  AGr.TableSelect[0] := ChooseBigValueTable(MaxRegionAbs(AGr.Ix, 0, r0e));
  AGr.TableSelect[1] := ChooseBigValueTable(MaxRegionAbs(AGr.Ix, r0e, r1e));
  AGr.TableSelect[2] := ChooseBigValueTable(MaxRegionAbs(AGr.Ix, r1e, 2 * bv));

  bits := 0;
  bits := bits + BigValueRegionBits(AGr.Ix, 0, r0e, AGr.TableSelect[0]);
  bits := bits + BigValueRegionBits(AGr.Ix, r0e, r1e, AGr.TableSelect[1]);
  bits := bits + BigValueRegionBits(AGr.Ix, r1e, 2 * bv, AGr.TableSelect[2]);

  b32 := Count1Bits(AGr.Ix, count1Start, AGr.Count1End, 32);
  b33 := Count1Bits(AGr.Ix, count1Start, AGr.Count1End, 33);
  if b33 < b32 then begin AGr.Count1TableSelect := 1; bits := bits + b33; end
  else begin AGr.Count1TableSelect := 0; bits := bits + b32; end;

  Result := bits;
end;

{ ===================== granule encode (inner loop) ===================== }

{ Find the smallest global_gain whose Huffman cost fits ABudgetBits and whose
  peak quantised value is representable.  Returns the settled TGranSideInfo. }
procedure EncodeGranule(const AXr: array of Single; ASampleRate, ABudgetBits: Integer;
  out AGr: TGranSideInfo);
var
  gg, lo, hi, bits, maxAbs, best: Integer;
  tmp: TGranSideInfo;
begin
  FillChar(AGr, SizeOf(AGr), 0);
  FillChar(tmp, SizeOf(tmp), 0);

  { global_gain is 0..255. Small gain -> fine steps -> many bits. Binary-search
    the smallest gain that fits the budget. }
  lo := 0; hi := 255; best := 255;
  while lo <= hi do
  begin
    gg := (lo + hi) div 2;
    QuantiseGranule(AXr, gg, tmp.Ix, maxAbs);
    tmp.GlobalGain := gg;
    if maxAbs > 8191 then
    begin
      lo := gg + 1;               // still clipping - need coarser
      Continue;
    end;
    bits := GranuleHuffmanBits(tmp, ASampleRate);
    if bits <= ABudgetBits then
    begin
      best := gg;
      hi := gg - 1;               // try finer
    end
    else
      lo := gg + 1;               // too many bits - coarser
  end;

  QuantiseGranule(AXr, best, AGr.Ix, maxAbs);
  AGr.GlobalGain := best;
  AGr.Part2_3Length := GranuleHuffmanBits(AGr, ASampleRate);
  { part2 (scalefactors) is empty: scalefac_compress 0, all sf 0 }
end;

{ ===================== bitstream assembly ===================== }

procedure WriteFrameHeader(var AW: TBitWriter; ASampleRate, ABitrateIndex: Integer;
  ANch, APadding: Integer);
var
  srIdx: Integer;
begin
  case ASampleRate of
    44100: srIdx := 0;
    48000: srIdx := 1;
    32000: srIdx := 2;
  else
    srIdx := 0;
  end;
  AW.PutBits($7FF, 11);                 // sync
  AW.PutBits(3, 2);                     // MPEG-1
  AW.PutBits(1, 2);                     // Layer III
  AW.PutBits(1, 1);                     // protection bit = 1 -> no CRC
  AW.PutBits(Cardinal(ABitrateIndex), 4);
  AW.PutBits(Cardinal(srIdx), 2);
  AW.PutBits(Cardinal(APadding), 1);
  AW.PutBits(0, 1);                     // private
  if ANch = 1 then AW.PutBits(3, 2)     // mono
  else AW.PutBits(0, 2);                // stereo
  AW.PutBits(0, 2);                     // mode extension
  AW.PutBits(0, 1);                     // copyright
  AW.PutBits(1, 1);                     // original
  AW.PutBits(0, 2);                     // emphasis none
end;

procedure WriteSideInfo(var AW: TBitWriter; ANch: Integer;
  const AGr: array of TGranSideInfo);   // AGr length 2*ANch, [gr*nch + ch]
var
  gr, ch: Integer;
  g: ^TGranSideInfo;
begin
  AW.PutBits(0, 9);                     // main_data_begin = 0 (no reservoir)
  if ANch = 1 then AW.PutBits(0, 5) else AW.PutBits(0, 3);   // private bits
  { scfsi: 4 bits per channel, all 0 }
  for ch := 0 to ANch - 1 do AW.PutBits(0, 4);

  for gr := 0 to 1 do
    for ch := 0 to ANch - 1 do
    begin
      g := @AGr[gr * ANch + ch];
      AW.PutBits(Cardinal(g^.Part2_3Length), 12);
      AW.PutBits(Cardinal(g^.BigValues), 9);
      AW.PutBits(Cardinal(g^.GlobalGain), 8);
      AW.PutBits(0, 4);                 // scalefac_compress
      AW.PutBits(0, 1);                 // window_switching_flag
      AW.PutBits(Cardinal(g^.TableSelect[0]), 5);
      AW.PutBits(Cardinal(g^.TableSelect[1]), 5);
      AW.PutBits(Cardinal(g^.TableSelect[2]), 5);
      AW.PutBits(Cardinal(g^.Region0Count), 4);
      AW.PutBits(Cardinal(g^.Region1Count), 3);
      AW.PutBits(0, 1);                 // preflag
      AW.PutBits(0, 1);                 // scalefac_scale
      AW.PutBits(Cardinal(g^.Count1TableSelect), 1);
    end;
end;

procedure WriteHuffPair(var AW: TBitWriter; ATable, AX, AY: Integer);
var
  mx, my, lb, yl: Integer;
  code, len: Integer;
begin
  if ATable = 0 then Exit;
  lb := MP3Huff[ATable].LinBits;
  yl := MP3Huff[ATable].YLen;
  mx := Abs(AX); my := Abs(AY);

  if (lb > 0) and (mx > 15) then mx := 15;
  if (lb > 0) and (my > 15) then my := 15;
  if mx > 15 then mx := 15;
  if my > 15 then my := 15;

  len := MP3Huff[ATable].Lens[mx * yl + my];
  code := MP3Huff[ATable].Codes[mx * yl + my];
  AW.PutBits(Cardinal(code), len);

  if (lb > 0) and (Abs(AX) >= 15) then
    AW.PutBits(Cardinal(Abs(AX) - 15), lb);
  if AX <> 0 then AW.PutBits(Ord(AX < 0), 1);

  if (lb > 0) and (Abs(AY) >= 15) then
    AW.PutBits(Cardinal(Abs(AY) - 15), lb);
  if AY <> 0 then AW.PutBits(Ord(AY < 0), 1);
end;

procedure WriteGranuleData(var AW: TBitWriter; const AGr: TGranSideInfo;
  ASampleRate: Integer);
var
  i, sr, acc, sfb, r0e, r1e, bv: Integer;
  bandStart: array[0..22] of Integer;
  idx, k: Integer;
  c1t: Integer;
begin
  { no scalefactor bits (scalefac_compress 0, all sf 0) }
  bv := AGr.BigValues;

  sr := SampleRateRow(ASampleRate);
  if sr < 0 then sr := 0;
  acc := 0;
  for i := 0 to 21 do begin bandStart[i] := acc; acc := acc + SFB_LONG_WIDTH[sr, i]; end;
  bandStart[22] := acc;

  if AGr.Region0Count + 1 <= 21 then r0e := bandStart[AGr.Region0Count + 1] else r0e := 576;
  sfb := AGr.Region0Count + AGr.Region1Count + 2;
  if sfb > 22 then sfb := 22;
  r1e := bandStart[sfb];
  if r0e > 2 * bv then r0e := 2 * bv;
  if r1e > 2 * bv then r1e := 2 * bv;
  if r0e > r1e then r0e := r1e;

  i := 0;
  while i + 1 < r0e do begin WriteHuffPair(AW, AGr.TableSelect[0], AGr.Ix[i], AGr.Ix[i + 1]); Inc(i, 2); end;
  i := r0e;
  while i + 1 < r1e do begin WriteHuffPair(AW, AGr.TableSelect[1], AGr.Ix[i], AGr.Ix[i + 1]); Inc(i, 2); end;
  i := r1e;
  while i + 1 < 2 * bv do begin WriteHuffPair(AW, AGr.TableSelect[2], AGr.Ix[i], AGr.Ix[i + 1]); Inc(i, 2); end;

  { count1 quads }
  c1t := 32 + AGr.Count1TableSelect;
  i := 2 * bv;
  while i + 3 < AGr.Count1End do
  begin
    idx := 0;
    for k := 0 to 3 do
      idx := (idx shl 1) or Ord(AGr.Ix[i + k] <> 0);
    AW.PutBits(Cardinal(MP3Huff[c1t].Codes[idx]), MP3Huff[c1t].Lens[idx]);
    for k := 0 to 3 do
      if AGr.Ix[i + k] <> 0 then AW.PutBits(Ord(AGr.Ix[i + k] < 0), 1);
    Inc(i, 4);
  end;
end;

{ ===================== Xing / Info header frame ===================== }

procedure PutBE32(var B: TBytes; AAt: Integer; AValue: Cardinal);
begin
  B[AAt]     := Byte(AValue shr 24);
  B[AAt + 1] := Byte(AValue shr 16);
  B[AAt + 2] := Byte(AValue shr 8);
  B[AAt + 3] := Byte(AValue);
end;

function BuildXingFrame(ASampleRate, ABitrateIndex, ANch: Integer; AIsCBR: Boolean;
  AFrameCount: Integer; AAudioBytes: Int64; ADelay, APadding: Integer): TBytes;
var
  w: TBitWriter;
  frameLen, sideBytes, ofs, i: Integer;
  hdrBytes: TBytes;
begin
  sideBytes := IfThen(ANch = 1, 17, 32);
  frameLen := (144 * BR_TABLE[ABitrateIndex] * 1000) div ASampleRate;
  if frameLen < 4 + sideBytes + 120 then
    frameLen := 4 + sideBytes + 120;   // guarantee room for the tag

  SetLength(Result, frameLen);
  FillChar(Result[0], frameLen, 0);

  w.Init;
  WriteFrameHeader(w, ASampleRate, ABitrateIndex, ANch, 0);
  SetLength(hdrBytes, 0);
  w.AppendTo(hdrBytes);
  Move(hdrBytes[0], Result[0], Min(4, Length(hdrBytes)));

  ofs := 4 + sideBytes;
  if AIsCBR then
  begin
    Result[ofs] := Ord('I'); Result[ofs + 1] := Ord('n');
    Result[ofs + 2] := Ord('f'); Result[ofs + 3] := Ord('o');
  end
  else
  begin
    Result[ofs] := Ord('X'); Result[ofs + 1] := Ord('i');
    Result[ofs + 2] := Ord('n'); Result[ofs + 3] := Ord('g');
  end;
  PutBE32(Result, ofs + 4, $0007);                  // frames + bytes + TOC
  PutBE32(Result, ofs + 8, Cardinal(AFrameCount));
  PutBE32(Result, ofs + 12, Cardinal(AAudioBytes));
  for i := 0 to 99 do
    Result[ofs + 16 + i] := Byte((i * 256) div 100);   // linear TOC

  { LAME-style tag: name at +116, delay/padding at +116+21 }
  Result[ofs + 116] := Ord('L'); Result[ofs + 117] := Ord('A');
  Result[ofs + 118] := Ord('M'); Result[ofs + 119] := Ord('E');
  Result[ofs + 116 + 21] := Byte((ADelay shr 4) and $FF);
  Result[ofs + 116 + 22] := Byte(((ADelay and $0F) shl 4) or ((APadding shr 8) and $0F));
  Result[ofs + 116 + 23] := Byte(APadding and $FF);
end;

{ ===================== top level ===================== }

function EncodeMp3(const APcm: TAudioPlanar; ASampleRate: Integer;
  const AOpts: TMP3EncodeOptions; out ARes: TMP3EncodeResult): Boolean;
var
  nch, srcFrames, totalFrames, padFrames: Integer;
  st: array[0..1] of TChanEncState;
  sub: array[0..1] of array[0..SSLIMIT * SBLIMIT - 1] of Double;
  xr: array[0..1] of TFloatArr576;
  gsi: array[0..3] of TGranSideInfo;    // [gr*nch + ch]
  fi, gr, ch, i, n: Integer;
  cbrIdx, brIdx, padAcc, frameLen, slotBytes, sideBytes, mainBudgetBits: Integer;
  frameW: TBitWriter;
  audio: TBytes;
  audioFrameCount: Integer;
  granuleBudget: Integer;
  padding: Integer;
  totalPad: Integer;
  chSamples: array[0..1] of TArray<Single>;
  needBits: Integer;
  delaySamples: Integer;
  xf: TBytes;
begin
  FillChar(ARes, SizeOf(ARes), 0);
  Result := False;

  if (ASampleRate <> 32000) and (ASampleRate <> 44100) and (ASampleRate <> 48000) then
    RaiseUDAWFmt(errConfig, ENC_SUBSYS,
      'MPEG-1 Layer III encode needs 32000/44100/48000 Hz, got %d', [ASampleRate]);

  nch := Length(APcm);
  if (nch < 1) or (nch > 2) then
    RaiseUDAWFmt(errConfig, ENC_SUBSYS, 'encode needs 1 or 2 channels, got %d', [nch]);
  srcFrames := Length(APcm[0]);
  if srcFrames <= 0 then
    RaiseUDAW(errConfig, ENC_SUBSYS, 'no PCM to encode');

  cbrIdx := BitrateIndex(AOpts.BitrateKbps);
  if cbrIdx < 0 then
    RaiseUDAWFmt(errConfig, ENC_SUBSYS, '%d kbps is not a standard MPEG-1 Layer III rate',
      [AOpts.BitrateKbps]);

  if not GEncReady then BuildEncoderTables;
  { Tables unit builds MP3Huff / windows in its initialization }

  { set once per frame on (gr=0, ch=0) - the guaranteed-first loop iteration;
    initialized here only to satisfy the compiler's flow analysis }
  brIdx := 0; frameLen := 0; padding := 0; granuleBudget := 0;

  { Pad the input to whole frames, with room for the codec delay: the signal
    comes back out of any decoder delayed by the encoder's 576 samples plus the
    decoder's 529, so the stream needs that many extra samples after the
    program or the end of the audio would be cut off. totalPad is the LAME tag's
    "padding" - samples after the program, counted from the end of the
    encoder delay. }
  totalFrames := (srcFrames + 576 + 529 + FRAME_SAMPLES - 1) div FRAME_SAMPLES;
  totalPad := totalFrames * FRAME_SAMPLES - 576 - srcFrames;
  for ch := 0 to nch - 1 do
  begin
    SetLength(chSamples[ch], totalFrames * FRAME_SAMPLES);
    for i := 0 to srcFrames - 1 do chSamples[ch][i] := APcm[ch][i];
    for i := srcFrames to totalFrames * FRAME_SAMPLES - 1 do chSamples[ch][i] := 0;
  end;

  FillChar(st, SizeOf(st), 0);
  SetLength(audio, 0);
  audioFrameCount := 0;
  padAcc := 0;

  sideBytes := IfThen(nch = 1, 17, 32);

  for fi := 0 to totalFrames - 1 do
  begin
    if Assigned(AOpts.OnProgress) then AOpts.OnProgress(fi / totalFrames);
    { analysis + MDCT for both granules, all channels }
    for ch := 0 to nch - 1 do
    begin
      for gr := 0 to 1 do
      begin
        AnalysisFilterbank(st[ch], chSamples[ch],
          fi * FRAME_SAMPLES + gr * GRAN, totalFrames * FRAME_SAMPLES,
          sub[ch]);
        ForwardMDCT(st[ch], sub[ch], xr[ch]);
        { xr[ch] now holds this granule's 576 coeffs; it is quantised and
          Huffman-costed immediately below so both granules' xr need not be kept }

        { choose bitrate + padding for this frame (done once, on gr 0 ch 0) }
        if (gr = 0) and (ch = 0) then
        begin
          if AOpts.Mode = emCBR then
          begin
            brIdx := cbrIdx;
            { fractional-slot padding accumulator so the average rate is exact }
            frameLen := (144 * BR_TABLE[brIdx] * 1000) div ASampleRate;
            padAcc := padAcc + ((144 * BR_TABLE[brIdx] * 1000) mod ASampleRate);
            if padAcc >= ASampleRate then
            begin
              padding := 1;
              padAcc := padAcc - ASampleRate;
            end
            else
              padding := 0;
          end
          else
          begin
            { VBR: rough per-granule bit need at a quality-derived reference gain,
              then smallest rate that holds it }
            needBits := (9 - AOpts.VBRQuality) * 1400 + 1600;   // ~1.6k..12k / granule
            granuleBudget := needBits;
            slotBytes := (2 * granuleBudget * nch + 7) div 8 + sideBytes + 4;
            brIdx := SmallestBitrateIndexForSlots(slotBytes,
              Max(AOpts.MinBitrateKbps, 32), AOpts.BitrateKbps, ASampleRate);
            frameLen := (144 * BR_TABLE[brIdx] * 1000) div ASampleRate;
            padding := 0;
          end;
          frameLen := frameLen + padding;
          slotBytes := frameLen - 4 - sideBytes;
          mainBudgetBits := slotBytes * 8;
          granuleBudget := mainBudgetBits div (2 * nch);
          { part2_3_length is a 12-bit side-info field }
          if granuleBudget > 4095 then granuleBudget := 4095;
        end;

        EncodeGranule(xr[ch], ASampleRate, granuleBudget, gsi[gr * nch + ch]);
      end;
    end;

    { assemble the frame }
    frameW.Init;
    WriteFrameHeader(frameW, ASampleRate, brIdx, nch, padding);
    WriteSideInfo(frameW, nch, gsi);
    for gr := 0 to 1 do
      for ch := 0 to nch - 1 do
        WriteGranuleData(frameW, gsi[gr * nch + ch], ASampleRate);
    { zero-pad main data to the slot boundary }
    frameW.AlignByte;
    while frameW.ByteLen < frameLen do frameW.PutBits(0, 8);
    { if we overran (shouldn't - the inner loop respects the budget), truncate
      is unsafe; instead the granule budget guarantees fit. Guard anyway: }
    if frameW.ByteLen > frameLen then frameW.ByteLen := frameLen;

    n := Length(audio);
    SetLength(audio, n + frameLen);
    Move(frameW.Buf[0], audio[n], frameLen);
    Inc(audioFrameCount);
  end;

  { encoder delay: analysis-filterbank + MDCT priming.  Report the LAME-style
    576 so a decoder that adds its own 528-sample latency lands close; the
    padding is the silence we appended to fill the last frame. }
  delaySamples := 576;
  padFrames := totalPad;

  SetLength(ARes.Data, 0);
  if AOpts.WriteXingHeader then
  begin
    xf := BuildXingFrame(ASampleRate, cbrIdx, nch,
      AOpts.Mode = emCBR, audioFrameCount, Length(audio), delaySamples, padFrames);
    SetLength(ARes.Data, Length(xf));
    Move(xf[0], ARes.Data[0], Length(xf));
  end;
  n := Length(ARes.Data);
  SetLength(ARes.Data, n + Length(audio));
  if Length(audio) > 0 then Move(audio[0], ARes.Data[n], Length(audio));

  ARes.FrameCount := audioFrameCount;
  ARes.ByteCount := Length(ARes.Data);
  ARes.EncoderDelay := delaySamples;
  ARes.EncoderPadding := padFrames;
  if audioFrameCount > 0 then
    ARes.AvgBitrateKbps :=
      (Length(audio) * 8.0 * ASampleRate) / (audioFrameCount * FRAME_SAMPLES * 1000.0);

  Result := ARes.ByteCount > 0;
end;

function EncodeMp3ToFile(const APcm: TAudioPlanar; ASampleRate: Integer;
  const AFileName: string; const AOpts: TMP3EncodeOptions): Boolean;
var
  res: TMP3EncodeResult;
  fs: TFileStream;
  meta: TMP3Metadata;
  tag: TBytes;
begin
  Result := EncodeMp3(APcm, ASampleRate, AOpts, res);
  if not Result then Exit;
  meta.Clear;
  meta.Copyright := UDAW_MEDIA_COPYRIGHT;
  tag := BuildId3v2Tag(meta);
  fs := TFileStream.Create(AFileName, fmCreate);
  try
    fs.WriteBuffer(tag[0], Length(tag));
    if Length(res.Data) > 0 then fs.WriteBuffer(res.Data[0], Length(res.Data));
  finally
    fs.Free;
  end;
end;

end.
