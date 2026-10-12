unit UDAW.Codec.AAC.Tables;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 16b - AAC constant tables and the runtime-built helpers.

  This unit gathers every fixed table the AAC-LC (and HE-AAC core) decoder
  needs, plus the tables that are cheaper to synthesise once at start-up:

    * SWB (scalefactor window band) offset tables for the 1024- and 128-sample
      transforms, keyed by sampling_frequency_index, and the swb counts;
    * TNS max_sfb / filter-order / coefficient-resolution limits;
    * the 12 Huffman codebooks - 11 spectral (ISO/IEC 14496-3 Tables 4.A.2 ..
      4.A.12) plus the scalefactor codebook (Table 4.A.1) - as explicit
      (codeword,length) lists decoded through a binary tree, exactly like the
      Phase 15 MP3 fix.  The lists live in UDAW.Codec.AAC.HuffData.inc with a
      header naming the reference symbols to diff against;
      HuffBooksSelfCheck() runs a per-book Kraft-equality + count check.
    * x^(4/3) inverse-quantisation lookup, 2^(0.25*x) gain lookup;
    * KBD and sine analysis/synthesis windows for 2048 and 256 (+ 1920 / 240).

  No table read is ever used to size an allocation without a bounds check. }

interface

uses
  SysUtils, Math,
  UDAW.Errors,
  UDAW.Codec.AAC.Types;

const
  { spectral Huffman codebook numbers as they appear in section_data }
  HCB_ZERO      = 0;
  HCB_1         = 1;
  HCB_2         = 2;
  HCB_3         = 3;
  HCB_4         = 4;
  HCB_5         = 5;
  HCB_6         = 6;
  HCB_7         = 7;
  HCB_8         = 8;
  HCB_9         = 9;
  HCB_10        = 10;
  HCB_11        = 11;
  HCB_FIRST_PAIR = 5;          // books 5..11 are 2-tuples, 1..4 are 4-tuples
  HCB_ESC       = 11;
  HCB_INTENSITY2 = 14;         // NOISE/INTENSITY sentinels in section_data
  HCB_INTENSITY = 15;
  HCB_NOISE     = 13;

  ESC_MAX_PREFIX = 8;          // escape prefix ones before the value field

type
  { one Huffman codebook: an explicit code list turned into a binary tree.
    Tree holds 2 ints per node; a negative entry is ~leafIndex (index into the
    unquant tuple list built from Dim / Mod / Signed). }
  TAacHuffBook = record
    Num: Integer;              // 1..11, or 0 for the scalefactor book (stored [11])
    Dim: Integer;              // 2 or 4 spectral coefficients per codeword
    ModVal: Integer;           // range base (2*LAV+1 for signed, LAV+1 for unsigned)
    LavMax: Integer;           // largest absolute value coded (before escape)
    Signed: Boolean;           // codeword directly carries sign (no trailing bits)
    Count: Integer;            // number of codewords
    Lens: array of Byte;
    Codes: array of Cardinal;
    Tree: array of Integer;
    MaxLen: Integer;
    function Decode(var ABr: TAacBitReader): Integer;   // -> leaf index 0..Count-1
    procedure UnpackTuple(ALeaf: Integer; out W, X, Y, Z: Integer);
  end;

var
  { [1..11] spectral, [0] = scalefactor codebook (also reachable as SfBook) }
  AacHCB: array[0..11] of TAacHuffBook;

function SfBook: TAacHuffBook;   // the scalefactor Huffman codebook (Table 4.A.1)

{ ---- SWB offset tables ---- }
{ Offsets into the 1024 / 128 coefficient array for each scalefactor band, for
  the given sampling_frequency_index (0..11).  The returned array has
  NumSwb+1 entries (the last is the total length). }
function SwbOffsetLong(ASampleRateIndex: Integer): TArray<Integer>;
function SwbOffsetShort(ASampleRateIndex: Integer): TArray<Integer>;
function NumSwbLong(ASampleRateIndex: Integer): Integer;
function NumSwbShort(ASampleRateIndex: Integer): Integer;

{ TNS limits (ISO 14496-3 Table 4.140 / 4.152), LC profile }
function TnsMaxBandsLong(ASampleRateIndex: Integer): Integer;
function TnsMaxBandsShort(ASampleRateIndex: Integer): Integer;
const
  TNS_MAX_ORDER_LC_LONG  = 12;
  TNS_MAX_ORDER_LC_SHORT = 7;
  TNS_MAX_FILTERS_LONG   = 3;
  TNS_MAX_FILTERS_SHORT  = 1;

{ ---- runtime lookups ---- }
function Iq43(AIndex: Integer): Double;          // |x|^(4/3), x in 0..8191(+esc)
function GainScale2(AExp: Integer): Double;      // 2^(0.25*AExp)
{ analysis/synthesis window halves, length N (1024 or 128, or 960/120). }
procedure GetWindow(ALongLen: Boolean; AShape: Integer; AIs960: Boolean;
  out AWin: TArray<Double>);

{ LONG_START / LONG_STOP transition windows (ISO/IEC 14496-3 4.6.9): a plain
  long window is wrong for these - it fails to complement the adjacent
  EIGHT_SHORT sequence's window shape, which is exactly the TDAC (time-domain
  aliasing cancellation) condition overlap-add depends on, and produces an
  audible click/crackle at every long<->short transition (i.e. on essentially
  any transient - a kick or hi-hat - in real content). AWinLong / AWinShort
  are the plain prototype windows for this N/Ns pair (get them from GetWindow,
  which already caches them). }
procedure BuildLongStartWindow(const AWinLong, AWinShort: TArray<Double>;
  N, Ns: Integer; out AWin: TArray<Double>);
procedure BuildLongStopWindow(const AWinLong, AWinShort: TArray<Double>;
  N, Ns: Integer; out AWin: TArray<Double>);

function HuffBooksSelfCheck(out AError: string): Boolean;

procedure InitAacTables;

implementation

{$I UDAW.Codec.AAC.HuffData.inc}

const
  TAB_SUBSYS = 'Codec.AAC.Tab';

{ ============================ SWB offset tables ================== }
{ Grouped exactly as ISO/IEC 14496-3: rates 0..2 share, 3..4 share, 5 alone,
  6..7 share, 8..10 share, 11..12 share.  Values are the FFmpeg / FAAD2
  ff_swb_offset_1024 / ff_swb_offset_128 contents. }

type
  TIntArr = array of Integer;

function MakeArr(const A: array of Integer): TArray<Integer>;
var
  i: Integer;
begin
  SetLength(Result, Length(A));
  for i := 0 to High(A) do Result[i] := A[i];
end;

{ --- 1024 --- }
function SwbLong_96_88: TArray<Integer>;      // index 0,1  (num_swb = 41)
begin
  Result := MakeArr([
    0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,64,72,80,88,96,108,120,132,144,
    156,172,188,212,240,276,320,384,448,512,576,640,704,768,832,896,960,1024]);
end;

function SwbLong_64: TArray<Integer>;         // index 2  (num_swb = 47)
begin
  Result := MakeArr([
    0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,64,72,80,88,100,112,124,140,156,
    172,192,216,240,268,304,344,384,424,464,504,544,584,624,664,704,744,784,
    824,864,904,944,984,1024]);
end;

function SwbLong_48_44: TArray<Integer>;      // index 3,4  (num_swb = 49)
begin
  Result := MakeArr([
    0,4,8,12,16,20,24,28,32,36,40,48,56,64,72,80,88,96,108,120,132,144,160,
    176,196,216,240,264,292,320,352,384,416,448,480,512,544,576,608,640,672,
    704,736,768,800,832,864,896,928,1024]);
end;

function SwbLong_32: TArray<Integer>;         // index 5  (num_swb = 51)
begin
  Result := MakeArr([
    0,4,8,12,16,20,24,28,32,36,40,48,56,64,72,80,88,96,108,120,132,144,160,
    176,196,216,240,264,292,320,352,384,416,448,480,512,544,576,608,640,672,
    704,736,768,800,832,864,896,928,960,992,1024]);
end;

function SwbLong_24_22: TArray<Integer>;      // index 6,7  (num_swb = 47)
begin
  Result := MakeArr([
    0,4,8,12,16,20,24,28,32,36,40,44,52,60,68,76,84,92,100,108,116,124,136,
    148,160,172,188,204,220,240,260,284,308,336,364,396,432,468,508,552,600,
    652,704,768,832,896,960,1024]);
end;

function SwbLong_16_12_11: TArray<Integer>;   // index 8,9,10  (num_swb = 43)
begin
  Result := MakeArr([
    0,8,16,24,32,40,48,56,64,72,80,88,100,112,124,136,148,160,172,184,196,
    212,228,244,260,280,300,320,344,368,396,424,456,492,532,572,616,664,716,
    772,832,896,960,1024]);
end;

function SwbLong_8: TArray<Integer>;          // index 11,12  (num_swb = 40)
begin
  Result := MakeArr([
    0,12,24,36,48,60,72,84,96,108,120,132,144,156,172,188,204,220,236,252,
    268,288,308,328,348,372,396,420,448,476,508,544,580,620,664,712,764,820,
    880,944,1024]);
end;

{ --- 128 --- }
function SwbShort_96_88_64: TArray<Integer>;  // index 0,1,2  (num_swb = 12)
begin
  Result := MakeArr([0,4,8,12,16,20,24,32,40,48,64,92,128]);
end;

function SwbShort_48_44_32: TArray<Integer>;  // index 3,4,5  (num_swb = 14)
begin
  Result := MakeArr([0,4,8,12,16,20,28,36,44,56,68,80,96,112,128]);
end;

function SwbShort_24_22: TArray<Integer>;     // index 6,7  (num_swb = 15)
begin
  Result := MakeArr([0,4,8,12,16,20,24,28,36,44,52,64,76,92,108,128]);
end;

function SwbShort_16_12_11: TArray<Integer>;  // index 8,9,10  (num_swb = 15)
begin
  Result := MakeArr([0,4,8,12,16,20,24,28,32,40,48,60,72,88,108,128]);
end;

function SwbShort_8: TArray<Integer>;         // index 11,12  (num_swb = 15)
begin
  Result := MakeArr([0,4,8,12,16,20,24,28,36,44,52,60,72,88,108,128]);
end;

function SwbOffsetLong(ASampleRateIndex: Integer): TArray<Integer>;
begin
  case ASampleRateIndex of
    0, 1:         Result := SwbLong_96_88;
    2:            Result := SwbLong_64;
    3, 4:         Result := SwbLong_48_44;
    5:            Result := SwbLong_32;
    6, 7:         Result := SwbLong_24_22;
    8, 9, 10:     Result := SwbLong_16_12_11;
  else
    Result := SwbLong_8;
  end;
end;

function SwbOffsetShort(ASampleRateIndex: Integer): TArray<Integer>;
begin
  case ASampleRateIndex of
    0, 1, 2:      Result := SwbShort_96_88_64;
    3, 4, 5:      Result := SwbShort_48_44_32;
    6, 7:         Result := SwbShort_24_22;
    8, 9, 10:     Result := SwbShort_16_12_11;
  else
    Result := SwbShort_8;
  end;
end;

function NumSwbLong(ASampleRateIndex: Integer): Integer;
begin
  Result := Length(SwbOffsetLong(ASampleRateIndex)) - 1;
end;

function NumSwbShort(ASampleRateIndex: Integer): Integer;
begin
  Result := Length(SwbOffsetShort(ASampleRateIndex)) - 1;
end;

function TnsMaxBandsLong(ASampleRateIndex: Integer): Integer;
const
  T: array[0..12] of Integer = (31,31,34,40,42,51,46,46,42,42,42,39,39);
begin
  if (ASampleRateIndex >= 0) and (ASampleRateIndex <= 12) then
    Result := T[ASampleRateIndex]
  else
    Result := 39;
end;

function TnsMaxBandsShort(ASampleRateIndex: Integer): Integer;
const
  T: array[0..12] of Integer = (9,9,10,14,14,14,14,14,14,14,14,14,14);
begin
  if (ASampleRateIndex >= 0) and (ASampleRateIndex <= 12) then
    Result := T[ASampleRateIndex]
  else
    Result := 14;
end;

{ ============================ runtime lookups =================== }

var
  GIq43: array of Double;      // 0 .. IQ43_MAX
  GGain2: array of Double;     // 2^(0.25*e), e in -256..+256 (offset)
  GTablesReady: Boolean = False;

const
  IQ43_MAX = 8192 + 16;        // 8191 max coded + a little escape headroom
  GAIN_OFFSET = 256;

function Iq43(AIndex: Integer): Double;
begin
  if AIndex < 0 then Exit(-Iq43(-AIndex));
  if AIndex < Length(GIq43) then
    Result := GIq43[AIndex]
  else
    Result := Power(AIndex, 4.0 / 3.0);
end;

function GainScale2(AExp: Integer): Double;
var
  i: Integer;
begin
  i := AExp + GAIN_OFFSET;
  if (i >= 0) and (i < Length(GGain2)) then
    Result := GGain2[i]
  else
    Result := Power(2.0, 0.25 * AExp);
end;

procedure BuildRuntimeLookups;
var
  i: Integer;
begin
  SetLength(GIq43, IQ43_MAX);
  GIq43[0] := 0;
  for i := 1 to IQ43_MAX - 1 do
    GIq43[i] := Power(i, 4.0 / 3.0);
  SetLength(GGain2, 2 * GAIN_OFFSET + 1);
  for i := 0 to High(GGain2) do
    GGain2[i] := Power(2.0, 0.25 * (i - GAIN_OFFSET));
end;

{ ---- windows ---- }

procedure BuildSine(N: Integer; out W: TArray<Double>);
var
  i: Integer;
begin
  SetLength(W, N);
  for i := 0 to N - 1 do
    W[i] := Sin(Pi / N * (i + 0.5));
end;

procedure BuildKBD(N: Integer; Alpha: Double; out W: TArray<Double>);
var
  i, m: Integer;
  sum, acc, x, bess: Double;
  win: TArray<Double>;

  function I0(a: Double): Double;
  var
    k: Integer;
    t, s: Double;
  begin
    s := 1.0; t := 1.0;
    for k := 1 to 40 do
    begin
      t := t * Sqr(a / (2.0 * k));
      s := s + t;
      if t < 1e-16 * s then Break;
    end;
    Result := s;
  end;

begin
  m := N div 2;
  SetLength(win, m + 1);
  sum := 0;
  for i := 0 to m do
  begin
    x := (2.0 * i / m) - 1.0;               // -1 .. +1
    bess := I0(Pi * Alpha * Sqrt(1.0 - x * x));
    win[i] := bess;
    sum := sum + bess;                      // sum over 0..m (= N/2)
  end;
  SetLength(W, N);
  acc := 0;
  for i := 0 to m - 1 do
  begin
    acc := acc + win[i];
    W[i] := Sqrt(acc / sum);
    W[N - 1 - i] := W[i];
  end;
end;

var
  { Only 8 (ALongLen x AShape x AIs960) combinations ever occur, and none
    depend on frame content - yet GetWindow used to rebuild the array (a full
    KBD window means an 0..N/2 Bessel-function series per sample) from
    scratch on every single Filterbank call, twice per frame (winL, winR).
    Over a multi-thousand-frame file that is tens of millions of avoidable
    Bessel evaluations. Cache each of the 8 by first use, same pattern as the
    AAC Huffman tables and the IMDCT plan cache. }
  GWindowCache: array[Boolean, 0..1, Boolean] of TArray<Double>;
  GWindowCached: array[Boolean, 0..1, Boolean] of Boolean;

procedure GetWindow(ALongLen: Boolean; AShape: Integer; AIs960: Boolean;
  out AWin: TArray<Double>);
var
  n: Integer;
  alpha: Double;
  shapeIdx: Integer;
begin
  shapeIdx := AShape and 1;
  if GWindowCached[ALongLen, shapeIdx, AIs960] then
  begin
    AWin := GWindowCache[ALongLen, shapeIdx, AIs960];
    Exit;
  end;

  if ALongLen then
    if AIs960 then n := 1920 else n := 2048
  else
    if AIs960 then n := 240 else n := 256;
  if shapeIdx = WSHAPE_KBD then
  begin
    if ALongLen then alpha := 4.0 else alpha := 6.0;
    BuildKBD(n, alpha, AWin);
  end
  else
    BuildSine(n, AWin);

  GWindowCache[ALongLen, shapeIdx, AIs960] := AWin;
  GWindowCached[ALongLen, shapeIdx, AIs960] := True;
end;

procedure BuildLongStartWindow(const AWinLong, AWinShort: TArray<Double>;
  N, Ns: Integer; out AWin: TArray<Double>);
var
  i: Integer;
begin
  { ISO/IEC 14496-3 4.6.11.3.  The short run is centred in the second half,
    so the 8 short windows start (N/2 - Ns)/2 samples into the next frame:
    long_window[n]                n in [0, N/2)                  - rising half
    1.0                           n in [N/2, 3N/4 - Ns/4)        - flat
    short_window[n - 3N/4 + Ns/4 + Ns/2]
                                  n in [3N/4 - Ns/4, 3N/4 + Ns/4) - short falling half
    0.0                           n in [3N/4 + Ns/4, N)          - silent }
  SetLength(AWin, N);
  for i := 0 to N div 2 - 1 do
    AWin[i] := AWinLong[i];
  for i := N div 2 to 3 * N div 4 - Ns div 4 - 1 do
    AWin[i] := 1.0;
  for i := 3 * N div 4 - Ns div 4 to 3 * N div 4 + Ns div 4 - 1 do
    AWin[i] := AWinShort[Ns div 2 + i - (3 * N div 4 - Ns div 4)];
  for i := 3 * N div 4 + Ns div 4 to N - 1 do
    AWin[i] := 0.0;
end;

procedure BuildLongStopWindow(const AWinLong, AWinShort: TArray<Double>;
  N, Ns: Integer; out AWin: TArray<Double>);
var
  startWin: TArray<Double>;
  i: Integer;
begin
  { the time-reverse of LONG_START: short-shaped rising head, then flat, then
    the long window's falling half. }
  BuildLongStartWindow(AWinLong, AWinShort, N, Ns, startWin);
  SetLength(AWin, N);
  for i := 0 to N - 1 do
    AWin[i] := startWin[N - 1 - i];
end;

{ ============================ Huffman book decode =============== }

procedure TreeInsertBook(var ATree: array of Integer; var ANodeCount: Integer;
  ACode: Cardinal; ALen: Integer; ALeaf: Integer);
var
  node, i, bit: Integer;
begin
  { Flat binary tree, 2 ints per node.  A child slot holds:
      0            - empty
      > 0          - index of an internal child node
      < 0          - a leaf: the value is (not leafIndex)
    The leaf marker is written into the PARENT's child slot on the last bit
    (so decode consumes exactly ALen bits), never as a separate node. }
  node := 0;
  for i := ALen - 1 downto 0 do
  begin
    bit := (ACode shr i) and 1;
    if i = 0 then
    begin
      ATree[node * 2 + bit] := not ALeaf;    // leaf
      Exit;
    end;
    if ATree[node * 2 + bit] <= 0 then
    begin
      Inc(ANodeCount);
      ATree[node * 2 + bit] := ANodeCount;
      ATree[ANodeCount * 2] := 0;
      ATree[ANodeCount * 2 + 1] := 0;
    end;
    node := ATree[node * 2 + bit];
  end;
end;

function TAacHuffBook.Decode(var ABr: TAacBitReader): Integer;
var
  node, bit, guard: Integer;
begin
  if Length(Tree) = 0 then Exit(0);
  node := 0;
  guard := 0;
  while guard < 64 do
  begin
    Inc(guard);
    bit := ABr.ReadBit;
    node := Tree[node * 2 + bit];
    if node < 0 then Exit(not node);        // leaf
    if node = 0 then Exit(0);               // malformed / ran off the tree
    if ABr.Overrun then Exit(0);
  end;
  Result := 0;
end;

procedure TAacHuffBook.UnpackTuple(ALeaf: Integer; out W, X, Y, Z: Integer);
var
  base, r: Integer;
begin
  { leaf index enumerates the nested loop over Dim elements each in
    [0 .. ModVal-1], with a Signed offset of (ModVal-1) div 2. }
  base := (ModVal - 1) div 2;
  r := ALeaf;
  if Dim = 4 then
  begin
    Z := r mod ModVal; r := r div ModVal;
    Y := r mod ModVal; r := r div ModVal;
    X := r mod ModVal; r := r div ModVal;
    W := r mod ModVal;
    if Signed then
    begin
      Dec(W, base); Dec(X, base); Dec(Y, base); Dec(Z, base);
    end;
  end
  else
  begin
    W := 0; X := 0;
    Z := r mod ModVal; r := r div ModVal;
    Y := r mod ModVal;
    if Signed then
    begin
      Dec(Y, base); Dec(Z, base);
    end;
  end;
end;

procedure BuildOneBook(var B: TAacHuffBook);
var
  i, nodeCount: Integer;
begin
  B.MaxLen := 0;
  for i := 0 to High(B.Lens) do
    if B.Lens[i] > B.MaxLen then B.MaxLen := B.Lens[i];
  B.Count := Length(B.Lens);
  SetLength(B.Tree, (B.Count * (B.MaxLen + 2) + 4) * 2);
  FillChar(B.Tree[0], Length(B.Tree) * SizeOf(Integer), 0);
  nodeCount := 0;
  for i := 0 to B.Count - 1 do
    if B.Lens[i] > 0 then
      TreeInsertBook(B.Tree, nodeCount, B.Codes[i], B.Lens[i], i);
  SetLength(B.Tree, (nodeCount + 1) * 2);
end;

function SfBook: TAacHuffBook;
begin
  Result := AacHCB[0];
end;

function HuffBooksSelfCheck(out AError: string): Boolean;
var
  b, i: Integer;
  sum: Double;
  expect: array[0..11] of Integer;
begin
  AError := '';
  expect[0] := 121;                          // scalefactor book
  expect[1] := 81;  expect[2] := 81;
  expect[3] := 81;  expect[4] := 81;
  expect[5] := 81;  expect[6] := 81;
  expect[7] := 64;  expect[8] := 64;
  expect[9] := 169; expect[10] := 169; expect[11] := 289;
  for b := 0 to 11 do
  begin
    if Length(AacHCB[b].Lens) <> expect[b] then
    begin
      AError := Format('book %d: %d codewords, expected %d',
        [b, Length(AacHCB[b].Lens), expect[b]]);
      Exit(False);
    end;
    sum := 0;
    for i := 0 to High(AacHCB[b].Lens) do
      if AacHCB[b].Lens[i] > 0 then
        sum := sum + Power(2.0, -AacHCB[b].Lens[i]);
    if Abs(sum - 1.0) > 1.0E-6 then
    begin
      AError := Format('book %d: Kraft sum %.9f (expected 1.0)', [b, sum]);
      Exit(False);
    end;
    if AacHCB[b].MaxLen > 24 then
    begin
      AError := Format('book %d: max length %d', [b, AacHCB[b].MaxLen]);
      Exit(False);
    end;
  end;
  Result := True;
end;

procedure InitAacTables;
var
  b: Integer;
begin
  if GTablesReady then Exit;
  BuildRuntimeLookups;
  InitAacHuffData;              // fills AacHCB[*].Num/Dim/ModVal/LavMax/Signed/Lens/Codes
  for b := 0 to 11 do
    BuildOneBook(AacHCB[b]);
  GTablesReady := True;
end;

initialization
  InitAacTables;

end.
