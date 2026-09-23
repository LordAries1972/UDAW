unit UDAW.Codec.MP3.Tables;
{$I udaw.inc}

{ Phase 15 - MP3 : constant data for MPEG-1 Layer III decode.

  Defined by ISO/IEC 11172-3 (the numbers are the format's public tables):
    * the Layer III Huffman code tables (Table B.7). The code lengths and symbol
      order are taken from FFmpeg's mpa_hufflens / mpa_huffsymbols (see
      UDAW.Codec.MP3.HuffData.inc); BuildHuffTables assigns canonical
      big-endian codewords and HuffmanTablesSelfCheck verifies each table is a
      complete prefix code (Kraft equality) - so a transcription error cannot
      pass silently. A fast canonical decode index is built alongside.
    * scalefactor-band widths for 32000/44100/48000 Hz (long / short);
    * requantisation power tables, IMDCT windows, alias-reduction butterfly
      coefficients, and the 512-tap polyphase synthesis window D[].

  MPEG-2/2.5 LSF tables are intentionally absent - Phase 15 decodes MPEG-1
  Layer III and reports LSF frames as unsupported. }

interface

uses
  UDAW.Codec.MP3.Frame;   // TBitReader

type
  TMP3HuffTable = record
    XLen, YLen: Integer;
    LinBits: Integer;
    IsCount1: Boolean;
    Codes: array of Cardinal;      // [x*YLen + y]  (reference form, self-checked) - up to 19 bits
    Lens:  array of Byte;          // [x*YLen + y]  bit length, 0 = symbol absent
    MaxLen: Integer;
    { binary decode tree: 2 ints per node (bit 0, bit 1). >=0 -> next node index;
      <0 -> leaf, packed symbol = (-v - 1), unpack x = sym shr 8, y = sym and $FF }
    Tree: array of Integer;
    procedure Decode(var ABr: TBitReader; out AX, AY: Integer);
  end;

var
  MP3Huff: array[0..33] of TMP3HuffTable;

const
  SFB_LONG_WIDTH: array[0..2, 0..21] of Word = (
    { 44100 } (4,4,4,4,4,4,6,6,8,8,10,12,16,20,24,28,34,42,50,54,76,158),
    { 48000 - ISO 11172-3 Table B.8 boundaries ...230,276,332,400,576;
      bands 19..21 were (54,54,192) which put the boundaries at
      ...330,384 and garbled the top third of the spectrum at 48 kHz }
    { 48000 } (4,4,4,4,4,4,6,6,6,8,10,12,16,18,22,28,34,40,46,56,68,176),
    { 32000 } (4,4,4,4,4,4,6,6,8,10,12,16,20,24,30,38,46,56,68,84,102,26));
  SFB_SHORT_WIDTH: array[0..2, 0..12] of Word = (
    { 44100 } (4,4,4,4,6,8,10,12,14,18,22,30,56),
    { 48000 } (4,4,4,4,6,6,10,12,14,16,20,26,66),
    { 32000 } (4,4,4,4,6,8,12,16,20,26,34,42,12));

  PRETAB: array[0..20] of Byte = (0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,2,2,3,3,3,2);

  SF_COMPRESS: array[0..15, 0..1] of Byte = (
    (0,0),(0,1),(0,2),(0,3),(3,0),(1,1),(1,2),(1,3),
    (2,1),(2,2),(2,3),(3,1),(3,2),(3,3),(4,2),(4,3));

  ALIAS_CS: array[0..7] of Single = (
    0.857492926, 0.881741997, 0.949628649, 0.983314592,
    0.995517816, 0.999160558, 0.999899195, 0.999993155);
  ALIAS_CA: array[0..7] of Single = (
   -0.514495755,-0.471731969,-0.313377454,-0.181913200,
   -0.094574193,-0.040965583,-0.014198569,-0.003699975);

function SampleRateRow(ASampleRate: Integer): Integer;   // 0/1/2 or -1

procedure IMDCT(const AIn: array of Single; ABlockType: Integer;
  var AOut: array of Single);      // AOut length 36 (pre-overlap)
function SynthWindowD(AIndex: Integer): Single;

function Pow43(AIndex: Integer): Double;
function GainPow2(AExp: Integer): Double;      // 2^(0.25*AExp)

function HuffmanTablesSelfCheck(out AError: string): Boolean;

implementation

uses
  SysUtils, Math;

{$I UDAW.Codec.MP3.HuffData.inc}

function SampleRateRow(ASampleRate: Integer): Integer;
begin
  case ASampleRate of
    44100: Result := 0;
    48000: Result := 1;
    32000: Result := 2;
  else
    Result := -1;
  end;
end;

{ ============================ pow tables ============================ }

var
  GPow43: array of Double;
  GGainPow2: array of Double;

function Pow43(AIndex: Integer): Double;
begin
  if AIndex < 0 then Exit(-Pow43(-AIndex));
  if AIndex < Length(GPow43) then Result := GPow43[AIndex]
  else Result := Power(AIndex, 4.0 / 3.0);
end;

function GainPow2(AExp: Integer): Double;
var
  i: Integer;
begin
  i := AExp + 320;
  if (i >= 0) and (i < Length(GGainPow2)) then Result := GGainPow2[i]
  else Result := Power(2.0, 0.25 * AExp);
end;

{ ============================ IMDCT + windows ====================== }

var
  GImdctWin: array[0..3, 0..35] of Single;
  GCos36: array[0..17, 0..35] of Single;
  GCos12: array[0..5, 0..11] of Single;
  GSynthD: array[0..511] of Single;

function SynthWindowD(AIndex: Integer): Single;
begin
  if (AIndex >= 0) and (AIndex <= 511) then Result := GSynthD[AIndex] else Result := 0;
end;

procedure BuildImdctWindows;
var
  i, k: Integer;
begin
  for i := 0 to 35 do GImdctWin[0, i] := Sin(Pi / 36 * (i + 0.5));
  for i := 0 to 17 do GImdctWin[1, i] := Sin(Pi / 36 * (i + 0.5));
  for i := 18 to 23 do GImdctWin[1, i] := 1.0;
  for i := 24 to 29 do GImdctWin[1, i] := Sin(Pi / 12 * (i - 18 + 0.5));
  for i := 30 to 35 do GImdctWin[1, i] := 0.0;
  for i := 0 to 5 do GImdctWin[3, i] := 0.0;
  for i := 6 to 11 do GImdctWin[3, i] := Sin(Pi / 12 * (i - 6 + 0.5));
  for i := 12 to 17 do GImdctWin[3, i] := 1.0;
  for i := 18 to 35 do GImdctWin[3, i] := Sin(Pi / 36 * (i + 0.5));
  for i := 0 to 11 do GImdctWin[2, i] := Sin(Pi / 12 * (i + 0.5));
  for i := 12 to 35 do GImdctWin[2, i] := 0.0;

  for i := 0 to 17 do
    for k := 0 to 35 do
      GCos36[i, k] := Cos(Pi / 72 * (2 * k + 1 + 18) * (2 * i + 1));
  for i := 0 to 5 do
    for k := 0 to 11 do
      GCos12[i, k] := Cos(Pi / 24 * (2 * k + 1 + 6) * (2 * i + 1));
end;

procedure IMDCT(const AIn: array of Single; ABlockType: Integer;
  var AOut: array of Single);
var
  i, k, sb: Integer;
  s: Double;
  win3: array[0..11] of Single;
begin
  for i := 0 to 35 do AOut[i] := 0;
  if ABlockType = 2 then
  begin
    for sb := 0 to 2 do
    begin
      for k := 0 to 11 do
      begin
        s := 0;
        for i := 0 to 5 do
          s := s + AIn[sb + 3 * i] * GCos12[i, k];
        win3[k] := s * GImdctWin[2, k];
      end;
      for k := 0 to 11 do
        AOut[6 * sb + k + 6] := AOut[6 * sb + k + 6] + win3[k];
    end;
  end
  else
  begin
    for k := 0 to 35 do
    begin
      s := 0;
      for i := 0 to 17 do
        s := s + AIn[i] * GCos36[i, k];
      AOut[k] := s * GImdctWin[ABlockType, k];
    end;
  end;
end;

procedure BuildSynthWindow;
const
  D: array[0..511] of Double = (
    0.000000000,-0.000015259,-0.000015259,-0.000015259,-0.000015259,-0.000015259,-0.000015259,-0.000030518,
   -0.000030518,-0.000030518,-0.000030518,-0.000045776,-0.000045776,-0.000061035,-0.000061035,-0.000076294,
   -0.000076294,-0.000091553,-0.000106812,-0.000106812,-0.000122070,-0.000137329,-0.000152588,-0.000167847,
   -0.000198364,-0.000213623,-0.000244141,-0.000259399,-0.000289917,-0.000320435,-0.000366211,-0.000396729,
   -0.000442505,-0.000473022,-0.000534058,-0.000579834,-0.000625610,-0.000686646,-0.000747681,-0.000808716,
   -0.000885010,-0.000961304,-0.001037598,-0.001113892,-0.001205444,-0.001296997,-0.001388550,-0.001480103,
   -0.001586914,-0.001693726,-0.001785278,-0.001907349,-0.002014160,-0.002120972,-0.002243042,-0.002349854,
   -0.002456665,-0.002578735,-0.002685547,-0.002792358,-0.002899170,-0.002990723,-0.003082275,-0.003173828,
    0.003250122, 0.003326416, 0.003387451, 0.003433228, 0.003463745, 0.003479004, 0.003479004, 0.003463745,
    0.003417969, 0.003372192, 0.003280640, 0.003173828, 0.003051758, 0.002883911, 0.002700806, 0.002487183,
    0.002227783, 0.001937866, 0.001617432, 0.001266479, 0.000869751, 0.000442505,-0.000030518,-0.000549316,
   -0.001098633,-0.001693726,-0.002334595,-0.003005981,-0.003723145,-0.004486084,-0.005294800,-0.006118774,
   -0.007003784,-0.007919312,-0.008865356,-0.009841919,-0.010848999,-0.011886597,-0.012939453,-0.014022827,
   -0.015121460,-0.016235352,-0.017349243,-0.018463135,-0.019577026,-0.020690918,-0.021789551,-0.022857666,
   -0.023910522,-0.024932861,-0.025909424,-0.026840210,-0.027725220,-0.028533936,-0.029281616,-0.029937744,
   -0.030532837,-0.031005859,-0.031387329,-0.031661987,-0.031814575,-0.031845093,-0.031738281,-0.031478882,
    0.031082153, 0.030517578, 0.029785156, 0.028884888, 0.027801514, 0.026535034, 0.025085449, 0.023422241,
    0.021575928, 0.019531250, 0.017257690, 0.014801025, 0.012115479, 0.009231567, 0.006134033, 0.002822876,
   -0.000686646,-0.004394531,-0.008316040,-0.012420654,-0.016708374,-0.021179199,-0.025817871,-0.030609131,
   -0.035552979,-0.040634155,-0.045837402,-0.051132202,-0.056533813,-0.061996460,-0.067520142,-0.073059082,
   -0.078628540,-0.084182739,-0.089706421,-0.095169067,-0.100540161,-0.105819702,-0.110946655,-0.115921021,
   -0.120697021,-0.125259399,-0.129562378,-0.133590698,-0.137298584,-0.140670776,-0.143676758,-0.146255493,
   -0.148422241,-0.150115967,-0.151306152,-0.151962280,-0.152069092,-0.151596069,-0.150497437,-0.148773193,
   -0.146362305,-0.143264771,-0.139450073,-0.134887695,-0.129577637,-0.123474121,-0.116577148,-0.108856201,
    0.100311279, 0.090927124, 0.080688477, 0.069595337, 0.057617187, 0.044784546, 0.031082153, 0.016510010,
    0.001068115,-0.015228271,-0.032379150,-0.050354004,-0.069168091,-0.088775635,-0.109161377,-0.130310059,
   -0.152206421,-0.174789429,-0.198059082,-0.221984863,-0.246505737,-0.271591187,-0.297210693,-0.323318481,
   -0.349868774,-0.376800537,-0.404083252,-0.431655884,-0.459472656,-0.487472534,-0.515609741,-0.543823242,
   -0.572036743,-0.600219727,-0.628295898,-0.656219482,-0.683914185,-0.711318970,-0.738372803,-0.765029907,
   -0.791213989,-0.816864014,-0.841949463,-0.866363525,-0.890090942,-0.913055420,-0.935195923,-0.956481934,
   -0.976852417,-0.996246338,-1.014617920,-1.031936646,-1.048156738,-1.063217163,-1.077117920,-1.089782715,
   -1.101211548,-1.111373901,-1.120223999,-1.127746582,-1.133926392,-1.138763428,-1.142211914,-1.144287109,
    1.144989014, 1.144287109, 1.142211914, 1.138763428, 1.133926392, 1.127746582, 1.120223999, 1.111373901,
    1.101211548, 1.089782715, 1.077117920, 1.063217163, 1.048156738, 1.031936646, 1.014617920, 0.996246338,
    0.976852417, 0.956481934, 0.935195923, 0.913055420, 0.890090942, 0.866363525, 0.841949463, 0.816864014,
    0.791213989, 0.765029907, 0.738372803, 0.711318970, 0.683914185, 0.656219482, 0.628295898, 0.600219727,
    0.572036743, 0.543823242, 0.515609741, 0.487472534, 0.459472656, 0.431655884, 0.404083252, 0.376800537,
    0.349868774, 0.323318481, 0.297210693, 0.271591187, 0.246505737, 0.221984863, 0.198059082, 0.174789429,
    0.152206421, 0.130310059, 0.109161377, 0.088775635, 0.069168091, 0.050354004, 0.032379150, 0.015228271,
   -0.001068115,-0.016510010,-0.031082153,-0.044784546,-0.057617187,-0.069595337,-0.080688477,-0.090927124,
    0.100311279, 0.108856201, 0.116577148, 0.123474121, 0.129577637, 0.134887695, 0.139450073, 0.143264771,
    0.146362305, 0.148773193, 0.150497437, 0.151596069, 0.152069092, 0.151962280, 0.151306152, 0.150115967,
    0.148422241, 0.146255493, 0.143676758, 0.140670776, 0.137298584, 0.133590698, 0.129562378, 0.125259399,
    0.120697021, 0.115921021, 0.110946655, 0.105819702, 0.100540161, 0.095169067, 0.089706421, 0.084182739,
    0.078628540, 0.073059082, 0.067520142, 0.061996460, 0.056533813, 0.051132202, 0.045837402, 0.040634155,
    0.035552979, 0.030609131, 0.025817871, 0.021179199, 0.016708374, 0.012420654, 0.008316040, 0.004394531,
    0.000686646,-0.002822876,-0.006134033,-0.009231567,-0.012115479,-0.014801025,-0.017257690,-0.019531250,
   -0.021575928,-0.023422241,-0.025085449,-0.026535034,-0.027801514,-0.028884888,-0.029785156,-0.030517578,
    0.031082153, 0.031478882, 0.031738281, 0.031845093, 0.031814575, 0.031661987, 0.031387329, 0.031005859,
    0.030532837, 0.029937744, 0.029281616, 0.028533936, 0.027725220, 0.026840210, 0.025909424, 0.024932861,
    0.023910522, 0.022857666, 0.021789551, 0.020690918, 0.019577026, 0.018463135, 0.017349243, 0.016235352,
    0.015121460, 0.014022827, 0.012939453, 0.011886597, 0.010848999, 0.009841919, 0.008865356, 0.007919312,
    0.007003784, 0.006118774, 0.005294800, 0.004486084, 0.003723145, 0.003005981, 0.002334595, 0.001693726,
    0.001098633, 0.000549316, 0.000030518,-0.000442505,-0.000869751,-0.001266479,-0.001617432,-0.001937866,
   -0.002227783,-0.002487183,-0.002700806,-0.002883911,-0.003051758,-0.003173828,-0.003280640,-0.003372192,
   -0.003417969,-0.003463745,-0.003479004,-0.003479004,-0.003463745,-0.003433228,-0.003387451,-0.003326416,
    0.003250122, 0.003173828, 0.003082275, 0.002990723, 0.002899170, 0.002792358, 0.002685547, 0.002578735,
    0.002456665, 0.002349854, 0.002243042, 0.002120972, 0.002014160, 0.001907349, 0.001785278, 0.001693726,
    0.001586914, 0.001480103, 0.001388550, 0.001296997, 0.001205444, 0.001113892, 0.001037598, 0.000961304,
    0.000885010, 0.000808716, 0.000747681, 0.000686646, 0.000625610, 0.000579834, 0.000534058, 0.000473022,
    0.000442505, 0.000396729, 0.000366211, 0.000320435, 0.000289917, 0.000259399, 0.000244141, 0.000213623,
    0.000198364, 0.000167847, 0.000152588, 0.000137329, 0.000122070, 0.000106812, 0.000106812, 0.000091553,
    0.000076294, 0.000076294, 0.000061035, 0.000061035, 0.000045776, 0.000045776, 0.000030518, 0.000030518,
    0.000030518, 0.000030518, 0.000015259, 0.000015259, 0.000015259, 0.000015259, 0.000015259, 0.000015259);
var
  i: Integer;
begin
  for i := 0 to 511 do GSynthD[i] := D[i];
end;

{ ============================ Huffman build ======================= }

function ISqrt(A: Integer): Integer;
begin
  Result := Round(Sqrt(A));
end;

{ Insert one (code,len) -> symbol mapping into the flat binary decode tree.
  ASym is the packed (x shl 8) or y. }
procedure TreeInsert(var ATree: array of Integer; var ANodeCount: Integer;
  ACode: Cardinal; ALen, ASym: Integer);
var
  node, b, bit: Integer;
begin
  node := 0;
  for b := ALen - 1 downto 0 do
  begin
    bit := (ACode shr b) and 1;
    if b = 0 then
    begin
      ATree[node * 2 + bit] := -(ASym) - 1;   // leaf
      Exit;
    end;
    if ATree[node * 2 + bit] <= 0 then
    begin
      ATree[node * 2 + bit] := ANodeCount;     // new internal node
      ATree[ANodeCount * 2] := 0;
      ATree[ANodeCount * 2 + 1] := 0;
      Inc(ANodeCount);
    end;
    node := ATree[node * 2 + bit];
  end;
end;

procedure BuildOneTable(AIdx, AVlcNum, ALinBits: Integer; AOffset, ACount: Integer);
var
  n, i, xl, L, maxL, x, y, nodeCount: Integer;
  acc: UInt64;
  cw: Cardinal;
  sym: Byte;
begin
  n := ACount;
  xl := ISqrt(n);
  MP3Huff[AIdx].XLen := xl;
  MP3Huff[AIdx].YLen := xl;
  MP3Huff[AIdx].LinBits := ALinBits;
  MP3Huff[AIdx].IsCount1 := False;
  SetLength(MP3Huff[AIdx].Codes, n);
  SetLength(MP3Huff[AIdx].Lens, n);
  { worst case one internal node per code bit; 2 ints per node }
  SetLength(MP3Huff[AIdx].Tree, (n * 20 + 4) * 2);
  MP3Huff[AIdx].Tree[0] := 0;
  MP3Huff[AIdx].Tree[1] := 0;
  nodeCount := 1;

  { FFmpeg-style canonical assignment: symbols in the given (ISO Table B.7)
    order, code accumulates left-aligned to 32 bits; the codeword is the top
    `len` bits.  This is exactly ff_vlc_init_from_lengths. }
  acc := 0;
  maxL := 0;
  for i := 0 to n - 1 do
  begin
    sym := HUFF_SYM_DATA[AOffset + i];
    L := HUFF_LEN_DATA[AOffset + i];
    cw := Cardinal(acc shr (32 - L));
    acc := acc + (UInt64(1) shl (32 - L));
    if L > maxL then maxL := L;
    x := sym shr 4;
    y := sym and $F;
    MP3Huff[AIdx].Codes[x * xl + y] := cw;
    MP3Huff[AIdx].Lens[x * xl + y] := L;
    TreeInsert(MP3Huff[AIdx].Tree, nodeCount, cw, L, (x shl 8) or y);
  end;
  MP3Huff[AIdx].MaxLen := maxL;
  SetLength(MP3Huff[AIdx].Tree, nodeCount * 2);
end;

procedure BuildCount1(AIdx, AWhich: Integer);
var
  i, L, maxL, nodeCount: Integer;
  cw: Cardinal;
begin
  MP3Huff[AIdx].IsCount1 := True;
  MP3Huff[AIdx].XLen := 16;
  MP3Huff[AIdx].YLen := 1;
  MP3Huff[AIdx].LinBits := 0;
  SetLength(MP3Huff[AIdx].Codes, 16);
  SetLength(MP3Huff[AIdx].Lens, 16);
  SetLength(MP3Huff[AIdx].Tree, (16 * 8 + 4) * 2);
  MP3Huff[AIdx].Tree[0] := 0;
  MP3Huff[AIdx].Tree[1] := 0;
  nodeCount := 1;
  maxL := 0;
  for i := 0 to 15 do
  begin
    L := QUAD_BITS[AWhich, i];
    cw := QUAD_CODES[AWhich, i];
    MP3Huff[AIdx].Codes[i] := cw;
    MP3Huff[AIdx].Lens[i] := L;
    if L > maxL then maxL := L;
    TreeInsert(MP3Huff[AIdx].Tree, nodeCount, cw, L, i shl 8);   // vwxy in the x slot
  end;
  MP3Huff[AIdx].MaxLen := maxL;
  SetLength(MP3Huff[AIdx].Tree, nodeCount * 2);
end;

procedure BuildHuffTables;
var
  t, v, off, i: Integer;
  blkOff: array[1..15] of Integer;
begin
  off := 0;
  for v := 1 to 15 do
  begin
    blkOff[v] := off;
    Inc(off, HUFF_BLK_SIZE[v]);
  end;
  for t := 0 to 31 do
  begin
    v := HUFF_TAB_MAP[t, 0];
    if v = 0 then Continue;   // tables 0, 4, 14
    BuildOneTable(t, v, HUFF_TAB_MAP[t, 1], blkOff[v], HUFF_BLK_SIZE[v]);
  end;
  BuildCount1(32, 0);
  BuildCount1(33, 1);
  i := 0; if i <> 0 then ;
end;

{ ============================ decode ============================== }

procedure TMP3HuffTable.Decode(var ABr: TBitReader; out AX, AY: Integer);
var
  node, nxt, steps, sym: Integer;
begin
  AX := 0; AY := 0;
  node := 0;
  steps := 0;
  while steps <= MaxLen do
  begin
    nxt := Tree[node * 2 + Integer(ABr.ReadBit)];
    if nxt < 0 then
    begin
      sym := (-nxt) - 1;
      AX := sym shr 8;
      AY := sym and $FF;
      Exit;
    end;
    if nxt = 0 then Exit;   // corrupt / no such code path - leave (0,0)
    node := nxt;
    Inc(steps);
  end;
end;

{ ============================ self-check ========================= }

function HuffmanTablesSelfCheck(out AError: string): Boolean;
var
  t, i: Integer;
  sum: Double;
begin
  AError := '';
  for t := 0 to 33 do
  begin
    if t in [0, 4, 14] then Continue;
    if Length(MP3Huff[t].Lens) = 0 then
    begin AError := Format('table %d empty', [t]); Exit(False); end;
    sum := 0;
    for i := 0 to High(MP3Huff[t].Lens) do
      if MP3Huff[t].Lens[i] > 0 then
        sum := sum + Power(2.0, -MP3Huff[t].Lens[i]);
    if (not MP3Huff[t].IsCount1) and (Abs(sum - 1.0) > 1.0E-6) then
    begin
      AError := Format('table %d Kraft %.9f (not a complete prefix code)', [t, sum]);
      Exit(False);
    end;
    if MP3Huff[t].MaxLen > 24 then
    begin AError := Format('table %d maxlen %d', [t, MP3Huff[t].MaxLen]); Exit(False); end;
  end;
  Result := True;
end;

var
  GInit: Boolean = False;

procedure InitAll;
var
  i: Integer;
begin
  if GInit then Exit;
  SetLength(GPow43, 8207);
  for i := 0 to 8206 do GPow43[i] := Power(i, 4.0 / 3.0);
  SetLength(GGainPow2, 768);
  for i := 0 to 767 do GGainPow2[i] := Power(2.0, 0.25 * (i - 320));
  BuildImdctWindows;
  BuildSynthWindow;
  BuildHuffTables;
  GInit := True;
end;

initialization
  InitAll;
end.
