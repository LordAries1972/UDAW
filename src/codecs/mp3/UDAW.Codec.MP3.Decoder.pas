unit UDAW.Codec.MP3.Decoder;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 15 - MPEG-1 Layer III decoder.

  A from-scratch Layer III audio decoder built on UDAW.Codec.MP3.Frame (frame
  walk / seek index) and UDAW.Codec.MP3.Tables (Huffman + windows + D[]).  It
  implements the full granule pipeline: bit-reservoir main-data assembly,
  scalefactor decode (long / short / mixed, scfsi sharing), Huffman decode of
  the three big-value regions plus the count1 quads, requantisation, MS /
  intensity stereo, alias reduction, the 18-point / 3x12-point IMDCT with
  overlap-add, frequency inversion, and the 32-band polyphase synthesis
  filterbank.  Output is the engine-wide planar Float32 layout.

  MPEG-2/2.5 (LSF) frames are detected and skipped (SkippedLsfFrames) - Phase
  15 decodes MPEG-1 Layer III, which covers 32/44.1/48 kHz.

  Phase 15 follow-up: the per-frame pipeline is now factored into
  TMP3StreamDecoder, an incremental decoder that decodes one MPEG frame per
  call and can SeekToSample with a reservoir + filterbank pre-roll.  The
  whole-file DecodeMp3 entry point is a thin loop over it (so both share one
  copy of the algorithm and the same test coverage). }

interface

uses
  UDAW.Media.Progress, SysUtils, Classes, Math,
  UDAW.Errors, UDAW.Audio.Types,
  UDAW.Codec.MP3.Frame, UDAW.Codec.MP3.Tables;

type
  TMP3DecodeResult = record
    Channels: Integer;
    SampleRate: Integer;
    Frames: Int64;                 // PCM sample frames produced
    Pcm: TAudioPlanar;             // [ch][frame]
    SkippedLsfFrames: Int64;
    DecodedFrames: Int64;
    ClippedSamples: Int64;
    Info: TMP3StreamInfo;
  end;

{ Decode an entire in-memory MP3. Raises EUDAWError (errConfig) if no MPEG-1
  Layer III audio can be found. Honours LAME/Xing encoder delay + padding when
  ATrimEncoderDelay is set. }
function DecodeMp3(const AData: TBytes; out ARes: TMP3DecodeResult;
  ATrimEncoderDelay: Boolean = True): Boolean;

function DecodeMp3File(const AFileName: string; out ARes: TMP3DecodeResult;
  ATrimEncoderDelay: Boolean = True): Boolean;

const
  MP3_MAX_FRAME_SAMPLES = 1152;   // MPEG-1 Layer III, both granules

type
  { Incremental Layer III decoder.  Feed it the whole file bytes once with Open;
    then pull PCM a frame at a time with DecodeNext, or jump with SeekToSample
    (which rewinds a few frames and decode-discards forward so the bit
    reservoir, IMDCT overlap and synthesis V-buffer are correct at the target).

    Not thread-safe; drive it from one thread (TMP3StreamSource runs it on a
    dedicated feeder thread). }
  TMP3StreamDecoder = class
  private
    FData: TBytes;
    FInfo: TMP3StreamInfo;
    FOpened: Boolean;
    FNch, FSr: Integer;
    FFrameIndex: Integer;           // next entry in FInfo.Frames to decode
    FAbsPos: Int64;                 // absolute sample-frame index of the next
                                    // sample DecodeNext will return
    FPendingSkip: Integer;          // drop this many frames off the front of the
                                    // next DecodeNext emission (post-seek)
    FClipped: Int64;
    FSkippedLsf: Int64;
    FDecoded: Int64;
    { pipeline state carried between frames }
    FState: Pointer;               // ^TDecoderState (opaque here, see impl)
    procedure EnsureState;
    procedure ResetPipeline;
    function RunOneFrame(var AOut: TAudioPlanar; out AProduced: Integer;
      out AFrameStartAbs: Int64): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    { Scan AData and prepare to decode from the first Layer III frame.  Raises
      EUDAWError(errConfig) if there is no MPEG-1 Layer III audio. }
    procedure Open(const AData: TBytes);

    { Decode the next MPEG frame.  AOut must be planar with >= FNch channels,
      each channel >= MP3_MAX_FRAME_SAMPLES long; on return AProduced samples
      per channel are valid (0 at end of stream, or for a skipped LSF / mismatched
      frame - call again).  Returns False only once the frame list is exhausted. }
    function DecodeNext(var AOut: TAudioPlanar; out AProduced: Integer): Boolean;

    { Jump so the next DecodeNext starts at (approximately) absolute sample
      ASample.  Clamped to [0, TotalSamples].  Rebuilds decoder state with a
      pre-roll of up to MP3_SEEK_PREROLL_FRAMES earlier frames. }
    procedure SeekToSample(ASample: Int64);

    property SampleRate: Integer read FSr;
    property Channels: Integer read FNch;
    function TotalSamples: Int64;
    property Position: Int64 read FAbsPos;
    property ClippedSamples: Int64 read FClipped;
    property SkippedLsfFrames: Int64 read FSkippedLsf;
    property DecodedFrames: Int64 read FDecoded;
    property Info: TMP3StreamInfo read FInfo;
    function AtEnd: Boolean;
  end;

const
  MP3_SEEK_PREROLL_FRAMES = 12;   // reservoir back-reference is <= 511 bytes ~ 9
                                  // frames; +overlap/synthesis warm-up margin

implementation

const
  DEC_SUBSYS = 'Codec.MP3.Dec';
  SSLIMIT = 18;
  SBLIMIT = 32;

type
  TGranuleInfo = record
    Part2_3Length: Integer;
    BigValues: Integer;
    GlobalGain: Integer;
    ScalefacCompress: Integer;
    WindowSwitching: Boolean;
    BlockType: Integer;             // 0 normal, 1 start, 3 stop, 2 short
    MixedBlock: Boolean;
    TableSelect: array[0..2] of Integer;
    SubblockGain: array[0..2] of Integer;
    Region0Count: Integer;
    Region1Count: Integer;
    Preflag: Integer;
    ScalefacScale: Integer;
    Count1TableSelect: Integer;
  end;

  TSideInfo = record
    MainDataBegin: Integer;
    Scfsi: array[0..1, 0..3] of Integer;
    Gr: array[0..1, 0..1] of TGranuleInfo;   // [granule][channel]
  end;

  TChannelState = record
    { overlap-add carry from previous granule, per subband }
    Overlap: array[0..SBLIMIT - 1, 0..SSLIMIT - 1] of Single;
    { synthesis V buffer }
    V: array[0..1023] of Single;
    VOffset: Integer;
  end;

  TScalefacs = record
    L: array[0..21] of Integer;         // long
    S: array[0..2, 0..12] of Integer;   // short [window][sfb]
  end;

  { everything the per-frame pipeline carries from one frame to the next }
  TDecoderState = record
    ChState: array[0..1] of TChannelState;
    SfPrev: array[0..1] of TScalefacs;
    ResvBuf: TBytes;
    ResvLen: Integer;
  end;
  PDecoderState = ^TDecoderState;

var
  GSynthN: array[0..63, 0..31] of Double;
  GSynthReady: Boolean = False;

procedure BuildSynthN;
var
  i, k: Integer;
begin
  for i := 0 to 63 do
    for k := 0 to 31 do
      GSynthN[i, k] := Cos((16 + i) * (2 * k + 1) * Pi / 64.0);
  GSynthReady := True;
end;

{ ===================== bit-reservoir main-data ===================== }

type
  TReservoir = record
    Buf: TBytes;
    Len: Integer;
    procedure Reset;
    procedure Append(const ASrc: TBytes; AFrom, ACount: Integer);
    procedure KeepLast(ABytes: Integer);
  end;

procedure TReservoir.Reset;
begin
  SetLength(Buf, 0);
  Len := 0;
end;

procedure TReservoir.Append(const ASrc: TBytes; AFrom, ACount: Integer);
begin
  if ACount <= 0 then Exit;
  if Len + ACount > Length(Buf) then
    SetLength(Buf, Len + ACount + 4096);
  Move(ASrc[AFrom], Buf[Len], ACount);
  Inc(Len, ACount);
end;

procedure TReservoir.KeepLast(ABytes: Integer);
begin
  if ABytes < 0 then ABytes := 0;
  if ABytes >= Len then Exit;
  if ABytes > 0 then
    Move(Buf[Len - ABytes], Buf[0], ABytes);
  Len := ABytes;
end;

{ ===================== side info ===================== }

procedure ReadSideInfo(var ABr: TBitReader; ANch: Integer; AVersion: TMpegVersion;
  out ASI: TSideInfo);
var
  gr, ch, i, r0, r1: Integer;
  g: ^TGranuleInfo;
begin
  FillChar(ASI, SizeOf(ASI), 0);
  ASI.MainDataBegin := ABr.ReadBits(9);
  if ANch = 1 then ABr.SkipBits(5) else ABr.SkipBits(3);   // private bits

  for ch := 0 to ANch - 1 do
    for i := 0 to 3 do
      ASI.Scfsi[ch, i] := ABr.ReadBits(1);

  for gr := 0 to 1 do
    for ch := 0 to ANch - 1 do
    begin
      g := @ASI.Gr[gr, ch];
      g^.Part2_3Length := ABr.ReadBits(12);
      g^.BigValues := ABr.ReadBits(9);
      g^.GlobalGain := ABr.ReadBits(8);
      g^.ScalefacCompress := ABr.ReadBits(4);
      g^.WindowSwitching := ABr.ReadBits(1) = 1;
      if g^.WindowSwitching then
      begin
        g^.BlockType := ABr.ReadBits(2);
        g^.MixedBlock := ABr.ReadBits(1) = 1;
        g^.TableSelect[0] := ABr.ReadBits(5);
        g^.TableSelect[1] := ABr.ReadBits(5);
        g^.TableSelect[2] := 0;
        g^.SubblockGain[0] := ABr.ReadBits(3);
        g^.SubblockGain[1] := ABr.ReadBits(3);
        g^.SubblockGain[2] := ABr.ReadBits(3);
        if (g^.BlockType = 2) and (not g^.MixedBlock) then
          g^.Region0Count := 8
        else
          g^.Region0Count := 7;
        g^.Region1Count := 20 - g^.Region0Count;
      end
      else
      begin
        g^.BlockType := 0;
        g^.MixedBlock := False;
        g^.TableSelect[0] := ABr.ReadBits(5);
        g^.TableSelect[1] := ABr.ReadBits(5);
        g^.TableSelect[2] := ABr.ReadBits(5);
        r0 := ABr.ReadBits(4);
        r1 := ABr.ReadBits(3);
        g^.Region0Count := r0;
        g^.Region1Count := r1;
      end;
      g^.Preflag := ABr.ReadBits(1);
      g^.ScalefacScale := ABr.ReadBits(1);
      g^.Count1TableSelect := ABr.ReadBits(1);
      if AVersion <> mpv1 then ;   // LSF handled by skipping the frame upstream
    end;
end;

{ ===================== scalefactors ===================== }

function ReadScalefactors(var ABr: TBitReader; const AG: TGranuleInfo;
  AGr, ACh: Integer; const ASI: TSideInfo; var ASF: TScalefacs): Integer;
var
  slen1, slen2, sfb, w: Integer;
  bitsUsed: Integer;
begin
  slen1 := SF_COMPRESS[AG.ScalefacCompress, 0];
  slen2 := SF_COMPRESS[AG.ScalefacCompress, 1];
  bitsUsed := 0;
  { NOTE: ASF must NOT be cleared here. The caller seeds it - zero for granule 0,
    granule 0's scalefactors for granule 1 - so that the scfsi "Continue" branch
    below preserves the shared band values. A FillChar here would zero those
    shared bands (they carry no bits in granule 1), detuning the gain of every
    scfsi-shared band and producing a seam at each granule boundary. }

  if AG.WindowSwitching and (AG.BlockType = 2) then
  begin
    if AG.MixedBlock then
    begin
      for sfb := 0 to 7 do
      begin
        ASF.L[sfb] := ABr.ReadBits(slen1); Inc(bitsUsed, slen1);
      end;
      for sfb := 3 to 11 do
        for w := 0 to 2 do
        begin
          if sfb < 6 then
          begin ASF.S[w, sfb] := ABr.ReadBits(slen1); Inc(bitsUsed, slen1); end
          else
          begin ASF.S[w, sfb] := ABr.ReadBits(slen2); Inc(bitsUsed, slen2); end;
        end;
    end
    else
    begin
      for sfb := 0 to 11 do
        for w := 0 to 2 do
        begin
          if sfb < 6 then
          begin ASF.S[w, sfb] := ABr.ReadBits(slen1); Inc(bitsUsed, slen1); end
          else
          begin ASF.S[w, sfb] := ABr.ReadBits(slen2); Inc(bitsUsed, slen2); end;
        end;
    end;
  end
  else
  begin
    { long block: 21 sfbs, grouped 0-5,6-10,11-15,16-20 with scfsi sharing
      from granule 0 to granule 1 }
    for sfb := 0 to 20 do
    begin
      if (AGr = 1) and
         (((sfb <= 5) and (ASI.Scfsi[ACh, 0] = 1)) or
          ((sfb >= 6) and (sfb <= 10) and (ASI.Scfsi[ACh, 1] = 1)) or
          ((sfb >= 11) and (sfb <= 15) and (ASI.Scfsi[ACh, 2] = 1)) or
          ((sfb >= 16) and (sfb <= 20) and (ASI.Scfsi[ACh, 3] = 1))) then
        Continue   // shared: keep granule 0's value (caller preserves)
      else if sfb <= 10 then
      begin ASF.L[sfb] := ABr.ReadBits(slen1); Inc(bitsUsed, slen1); end
      else
      begin ASF.L[sfb] := ABr.ReadBits(slen2); Inc(bitsUsed, slen2); end;
    end;
  end;
  Result := bitsUsed;
end;

{ ===================== Huffman + requantise ===================== }

procedure DecodeHuffman(var ABr: TBitReader; const AG: TGranuleInfo;
  AStartBit: Int64; ASampleRate: Integer; var AIs: array of Single);
var
  r, i, x, y, tbl, count1tbl: Integer;
  region0End, region1End: Integer;
  bandIdxLong: array[0..22] of Integer;
  acc, sfb: Integer;
  endBit: Int64;
  linb: Integer;
  vv, ww, xx, yy: Integer;
  pos: Integer;
  sr: Integer;
begin
  for i := 0 to High(AIs) do AIs[i] := 0;
  sr := SampleRateRow(ASampleRate);
  if sr < 0 then Exit;

  acc := 0;
  for i := 0 to 21 do
  begin
    bandIdxLong[i] := acc;
    acc := acc + SFB_LONG_WIDTH[sr, i];
  end;
  bandIdxLong[22] := acc;

  endBit := AStartBit + AG.Part2_3Length;

  { region boundaries in units of is[] index (each big_value = 2 is entries) }
  if AG.WindowSwitching and (AG.BlockType = 2) then
  begin
    region0End := 36;                 // 3 * 12 = short block region0 fixed
    region1End := 576;
  end
  else
  begin
    if AG.Region0Count + 1 > 21 then region0End := bandIdxLong[22]
    else region0End := bandIdxLong[AG.Region0Count + 1];
    sfb := AG.Region0Count + AG.Region1Count + 2;
    if sfb > 22 then sfb := 22;
    region1End := bandIdxLong[sfb];
    if region1End > 576 then region1End := 576;
  end;
  if region0End > 2 * AG.BigValues then region0End := 2 * AG.BigValues;
  if region1End > 2 * AG.BigValues then region1End := 2 * AG.BigValues;

  pos := 0;
  for r := 0 to 2 do
  begin
    if r = 0 then begin tbl := AG.TableSelect[0]; end
    else if r = 1 then begin tbl := AG.TableSelect[1]; end
    else begin tbl := AG.TableSelect[2]; end;
    if r = 0 then i := region0End
    else if r = 1 then i := region1End
    else i := 2 * AG.BigValues;
    if i > 576 then i := 576;

    if (tbl = 0) then
    begin
      { table 0: all values are zero for this region }
      pos := i;
      Continue;
    end;

    linb := MP3Huff[tbl].LinBits;
    while (pos < i) and (ABr.BitPosition < endBit) do
    begin
      MP3Huff[tbl].Decode(ABr, x, y);
      if (x = 15) and (linb > 0) then x := x + Integer(ABr.ReadBits(linb));
      if x <> 0 then
      begin
        if ABr.ReadBit = 1 then x := -x;
      end;
      if (y = 15) and (linb > 0) then y := y + Integer(ABr.ReadBits(linb));
      if y <> 0 then
      begin
        if ABr.ReadBit = 1 then y := -y;
      end;
      if pos < 576 then AIs[pos] := x;
      Inc(pos);
      if pos < 576 then AIs[pos] := y;
      Inc(pos);
    end;
    pos := i;
  end;

  { count1 region: quads until part2_3 bits exhausted or 576 reached }
  count1tbl := 32 + AG.Count1TableSelect;
  pos := 2 * AG.BigValues;
  if pos < 0 then pos := 0;
  while (pos <= 572) and (ABr.BitPosition < endBit) do
  begin
    MP3Huff[count1tbl].Decode(ABr, x, y);   // x holds vwxy (0..15), y unused
    vv := (x shr 3) and 1;
    ww := (x shr 2) and 1;
    xx := (x shr 1) and 1;
    yy := x and 1;
    if vv <> 0 then begin if ABr.ReadBit = 1 then vv := -1; end;
    if ww <> 0 then begin if ABr.ReadBit = 1 then ww := -1; end;
    if xx <> 0 then begin if ABr.ReadBit = 1 then xx := -1; end;
    if yy <> 0 then begin if ABr.ReadBit = 1 then yy := -1; end;
    if pos < 576 then AIs[pos] := vv; Inc(pos);
    if pos < 576 then AIs[pos] := ww; Inc(pos);
    if pos < 576 then AIs[pos] := xx; Inc(pos);
    if pos < 576 then AIs[pos] := yy; Inc(pos);
  end;
  { align to end of part2_3 for the next channel/granule }
  if ABr.BitPosition < endBit then ABr.SetBitPosition(endBit)
  else if ABr.BitPosition > endBit then ABr.SetBitPosition(endBit);
end;

procedure Requantize(const AG: TGranuleInfo; const ASF: TScalefacs;
  ASampleRate: Integer; var AIs: array of Single; var AXr: array of Single);
var
  sr, i, sfb, w, width, startL, gg: Integer;
  bandL: array[0..22] of Integer;
  bandS: array[0..13] of Integer;
  acc: Integer;
  scale: Double;
  gainBase: Double;
  isShort: Boolean;
  sfMul: Double;
  idxInSfb, sPos: Integer;
begin
  for i := 0 to High(AXr) do AXr[i] := 0;
  sr := SampleRateRow(ASampleRate);
  if sr < 0 then Exit;
  gg := AG.GlobalGain;
  gainBase := GainPow2(gg - 210);
  if AG.ScalefacScale = 0 then sfMul := 0.5 else sfMul := 1.0;

  acc := 0;
  for i := 0 to 21 do begin bandL[i] := acc; acc := acc + SFB_LONG_WIDTH[sr, i]; end;
  bandL[22] := acc;
  acc := 0;
  for i := 0 to 12 do begin bandS[i] := acc; acc := acc + SFB_SHORT_WIDTH[sr, i]; end;
  bandS[13] := acc;

  isShort := AG.WindowSwitching and (AG.BlockType = 2);

  if not isShort then
  begin
    for sfb := 0 to 20 do
    begin
      startL := bandL[sfb];
      width := bandL[sfb + 1] - bandL[sfb];
      scale := gainBase * Power(2.0, -sfMul * (ASF.L[sfb] + AG.Preflag * PRETAB[sfb]));
      for i := 0 to width - 1 do
      begin
        if startL + i >= 576 then Break;
        AXr[startL + i] := Single(Sign(AIs[startL + i]) * Pow43(Round(Abs(AIs[startL + i]))) * scale);
      end;
    end;
  end
  else
  begin
    { short (and the short part of a mixed block); long part 0..1 for mixed }
    sPos := 0;
    if AG.MixedBlock then
    begin
      for sfb := 0 to 7 do
      begin
        startL := bandL[sfb];
        width := bandL[sfb + 1] - bandL[sfb];
        scale := gainBase * Power(2.0, -sfMul * (ASF.L[sfb] + AG.Preflag * PRETAB[sfb]));
        for i := 0 to width - 1 do
        begin
          if startL + i >= 576 then Break;
          AXr[startL + i] := Single(Sign(AIs[startL + i]) * Pow43(Round(Abs(AIs[startL + i]))) * scale);
        end;
        sPos := startL + width;
      end;
    end;
    { remaining as short: interleaved [sfb][window] }
    sfb := 0;
    if AG.MixedBlock then sfb := 3;
    while sfb <= 12 do
    begin
      width := SFB_SHORT_WIDTH[sr, sfb];
      for w := 0 to 2 do
      begin
        scale := gainBase * Power(2.0, 0.25 * (-8.0 * AG.SubblockGain[w]))
                 * Power(2.0, -sfMul * ASF.S[w, sfb]);
        for idxInSfb := 0 to width - 1 do
        begin
          if sPos >= 576 then Break;
          AXr[sPos] := Single(Sign(AIs[sPos]) * Pow43(Round(Abs(AIs[sPos]))) * scale);
          Inc(sPos);
        end;
      end;
      Inc(sfb);
    end;
  end;
end;

{ ===================== reorder (short blocks) ===================== }

procedure ReorderShort(const AG: TGranuleInfo; ASampleRate: Integer;
  var AXr: array of Single);
var
  sr, sfb, w, i, width, src, startShort: Integer;
  bandS: array[0..13] of Integer;
  acc: Integer;
  tmp: array[0..575] of Single;
begin
  if not (AG.WindowSwitching and (AG.BlockType = 2)) then Exit;
  sr := SampleRateRow(ASampleRate);
  if sr < 0 then Exit;
  acc := 0;
  for i := 0 to 12 do begin bandS[i] := acc; acc := acc + SFB_SHORT_WIDTH[sr, i]; end;
  bandS[13] := acc;

  for i := 0 to 575 do tmp[i] := AXr[i];

  startShort := 0;
  sfb := 0;
  if AG.MixedBlock then
  begin
    startShort := 36;    // MPEG-1 mixed block: first 36 lines are the long part
    sfb := 3;
  end;

  { Requantise left tmp[] in bitstream order  [sfb][window][line]  (each short
    sfb block is 3*width long, sfbs contiguous from startShort).  ISO/IEC
    11172-3 2.4.3.4.10.2 reorder -> frequency/subband order:
      src  = 3*sfb_start + window*width + line       (== our linear walk)
      dest = 3*sfb_start + window       + line*3     (window-interleaved by 3)
    NOTE: earlier this wrote `window*width + line`, which scrambled every
    short-block spectrum (widths 4..56, not 3) and muffled transient sections. }
  src := startShort;
  while sfb <= 12 do
  begin
    width := SFB_SHORT_WIDTH[sr, sfb];
    for w := 0 to 2 do
      for i := 0 to width - 1 do
      begin
        AXr[3 * bandS[sfb] + w + i * 3] := tmp[src];
        Inc(src);
      end;
    Inc(sfb);
  end;
end;

{ ===================== stereo ===================== }

procedure StereoProcess(const AHdr: TMP3FrameHeader; const AGL, AGR: TGranuleInfo;
  ASampleRate: Integer; var AXrL, AXrR: array of Single);
var
  msStereo, iStereo: Boolean;
  i: Integer;
  a, b: Single;
begin
  if AHdr.ChannelMode <> cmJointStereo then Exit;
  msStereo := (AHdr.ModeExtension and 2) <> 0;
  iStereo := (AHdr.ModeExtension and 1) <> 0;

  if msStereo then
  begin
    for i := 0 to 575 do
    begin
      a := AXrL[i];
      b := AXrR[i];
      AXrL[i] := Single((a + b) * 0.70710678);
      AXrR[i] := Single((a - b) * 0.70710678);
    end;
  end;
  { intensity stereo (upper zero region of the right channel) - conservative:
    when only intensity is signalled and the right channel is all-zero in a
    region, mirror left. Full IS position tables are a documented deferral. }
  if iStereo and (not msStereo) then
  begin
    for i := 0 to 575 do
      if AXrR[i] = 0 then
        AXrR[i] := AXrL[i];
  end;
end;

{ ===================== antialias ===================== }

procedure AntiAlias(const AG: TGranuleInfo; var AXr: array of Single);
var
  sb, i, idx: Integer;
  a, b: Single;
  lastSb: Integer;
begin
  if AG.WindowSwitching and (AG.BlockType = 2) and (not AG.MixedBlock) then Exit;
  lastSb := 31;
  if AG.WindowSwitching and (AG.BlockType = 2) and AG.MixedBlock then lastSb := 1;
  for sb := 0 to lastSb - 1 do
    for i := 0 to 7 do
    begin
      idx := 18 * (sb + 1);
      a := AXr[idx - 1 - i];
      b := AXr[idx + i];
      AXr[idx - 1 - i] := Single(a * ALIAS_CS[i] - b * ALIAS_CA[i]);
      AXr[idx + i]     := Single(b * ALIAS_CS[i] + a * ALIAS_CA[i]);
    end;
end;

{ ===================== IMDCT + overlap ===================== }

procedure HybridSynthesis(const AG: TGranuleInfo; var AXr: array of Single;
  var ACh: TChannelState; var ASbSamples: array of Single);   // out [18][32]
var
  sb, i, bt: Integer;
  inp: array[0..17] of Single;
  outp: array[0..35] of Single;
begin
  for sb := 0 to SBLIMIT - 1 do
  begin
    for i := 0 to 17 do inp[i] := AXr[sb * 18 + i];

    if AG.WindowSwitching and (AG.BlockType = 2) and
       (not (AG.MixedBlock and (sb < 2))) then
      bt := 2
    else if AG.WindowSwitching and (AG.MixedBlock and (sb < 2)) then
      bt := 0
    else
      bt := AG.BlockType;

    IMDCT(inp, bt, outp);

    { overlap-add: first 18 with carry, save last 18 }
    for i := 0 to 17 do
    begin
      ASbSamples[i * 32 + sb] := outp[i] + ACh.Overlap[sb, i];
      ACh.Overlap[sb, i] := outp[i + 18];
    end;

    { frequency inversion: negate odd samples of odd subbands }
    if (sb and 1) = 1 then
      for i := 1 to 17 do
        if (i and 1) = 1 then
          ASbSamples[i * 32 + sb] := -ASbSamples[i * 32 + sb];
  end;
end;

{ ===================== polyphase synthesis ===================== }

procedure SynthFilterbank(var ACh: TChannelState; const ASb: array of Single;
  var APcm: array of Single; APcmOffset: Integer);
var
  ss, i, j, k: Integer;
  s: array[0..31] of Double;
  sum: Double;
  u: array[0..511] of Double;
  vp: Integer;
begin
  for ss := 0 to SSLIMIT - 1 do
  begin
    for k := 0 to 31 do s[k] := ASb[ss * 32 + k];

    ACh.VOffset := (ACh.VOffset - 64) and 1023;
    vp := ACh.VOffset;
    for i := 0 to 63 do
    begin
      sum := 0;
      for k := 0 to 31 do
        sum := sum + GSynthN[i, k] * s[k];
      ACh.V[(vp + i) and 1023] := sum;
    end;

    for i := 0 to 7 do
      for j := 0 to 31 do
      begin
        u[i * 64 + j]      := ACh.V[(vp + i * 128 + j) and 1023];
        u[i * 64 + 32 + j] := ACh.V[(vp + i * 128 + 96 + j) and 1023];
      end;

    for j := 0 to 31 do
    begin
      sum := 0;
      for i := 0 to 15 do
        sum := sum + u[j + 32 * i] * SynthWindowD(j + 32 * i);
      APcm[APcmOffset + ss * 32 + j] := Single(sum);
    end;
  end;
end;

{ ===================== per-frame decode ===================== }

procedure DecodeGranuleChannel(var AMdBr: TBitReader; AStartBit: Int64;
  const AG: TGranuleInfo; AGr, ACh: Integer; const ASI: TSideInfo;
  const AHdr: TMP3FrameHeader; var ASfPrev: TScalefacs; var AXrOut: array of Single);
var
  sf: TScalefacs;
  is_: array[0..575] of Single;
  sfBits: Integer;
  bitPos: Int64;
begin
  AMdBr.SetBitPosition(AStartBit);
  { Scalefactors. Seed the buffer before ReadScalefactors (which no longer clears
    it): granule 0 starts from zero; granule 1 starts from granule 0's values so
    the scfsi-shared bands, which carry no bits in granule 1, keep granule 0's
    scalefactor. Non-shared bands are overwritten with freshly read values. }
  FillChar(sf, SizeOf(sf), 0);
  if AGr = 1 then sf := ASfPrev;
  sfBits := ReadScalefactors(AMdBr, AG, AGr, ACh, ASI, sf);
  if AGr = 0 then ASfPrev := sf;

  bitPos := AMdBr.BitPosition;
  DecodeHuffman(AMdBr, AG, AStartBit, AHdr.SampleRate, is_);
  if bitPos + sfBits > AStartBit + AG.Part2_3Length + 8 then ;  // tolerate

  Requantize(AG, sf, AHdr.SampleRate, is_, AXrOut);
  ReorderShort(AG, AHdr.SampleRate, AXrOut);
end;

{ Decode exactly one MPEG-1 Layer III frame (2 granules) using AState's carried
  pipeline state, writing up to 1152 samples/channel into AOut.  APcmFrames is
  the number of PCM sample-frames produced (0 for a frame that could not be
  assembled - e.g. reservoir not warm yet).  ClippedInc counts clamped samples. }
procedure DecodeOneMp3Frame(const AData: TBytes; const AFrameRef: TMP3FrameRef;
  var AState: TDecoderState; ANch, ASr: Integer; var AOut: TAudioPlanar;
  out APcmFrames: Integer; var AClippedInc: Int64);
var
  hdr: TMP3FrameHeader;
  crcSkip, siBytes: Integer;
  sideStart: Int64;
  br, mdBr: TBitReader;
  si: TSideInfo;
  frameBytesStart: Int64;
  mainDataBytesThisFrame: Integer;
  mdBegin, mdAvail: Integer;
  gr, ch, j: Integer;
  part2_3Acc: Int64;
  v: Single;
  resv: TReservoir;
  xr: array[0..1, 0..575] of Single;
  sbSamples: array[0..1, 0..575] of Single;
  pcmScratch: array[0..1, 0..1151] of Single;
  asm_: TBytes;
begin
  APcmFrames := 0;
  if not ReadFrameHeaderAt(AData, AFrameRef.FileOffset, hdr) then Exit;
  if not hdr.IsLayer3 then Exit;
  if hdr.Version <> mpv1 then Exit;
  if (hdr.Channels <> ANch) or (hdr.SampleRate <> ASr) then Exit;

  frameBytesStart := AFrameRef.FileOffset;
  crcSkip := 0;
  if hdr.HasCRC then crcSkip := 2;
  siBytes := hdr.SideInfoBytes;
  sideStart := frameBytesStart + 4 + crcSkip;
  if sideStart + siBytes > Length(AData) then Exit;

  { adopt the carried reservoir }
  resv.Buf := AState.ResvBuf;
  resv.Len := AState.ResvLen;

  br.Init(@AData[sideStart], siBytes, 0);
  ReadSideInfo(br, ANch, hdr.Version, si);

  mainDataBytesThisFrame := AFrameRef.FrameBytes - 4 - crcSkip - siBytes;
  if mainDataBytesThisFrame < 0 then mainDataBytesThisFrame := 0;
  if sideStart + siBytes + mainDataBytesThisFrame > Length(AData) then
    mainDataBytesThisFrame := Length(AData) - Integer(sideStart) - siBytes;
  if mainDataBytesThisFrame < 0 then mainDataBytesThisFrame := 0;

  mdBegin := si.MainDataBegin;
  if mdBegin > resv.Len then
  begin
    { not enough reservoir yet (start of stream / right after a seek) - stash
      this frame's main data and emit nothing }
    resv.Append(AData, sideStart + siBytes, mainDataBytesThisFrame);
    resv.KeepLast(4096);
    AState.ResvBuf := resv.Buf;
    AState.ResvLen := resv.Len;
    Exit;
  end;

  mdAvail := mdBegin + mainDataBytesThisFrame;
  SetLength(asm_, mdAvail);
  if mdBegin > 0 then
    Move(resv.Buf[resv.Len - mdBegin], asm_[0], mdBegin);
  if mainDataBytesThisFrame > 0 then
    Move(AData[sideStart + siBytes], asm_[mdBegin], mainDataBytesThisFrame);
  mdBr.Init(@asm_[0], mdAvail, 0);

  part2_3Acc := 0;
  for gr := 0 to 1 do
  begin
    for ch := 0 to ANch - 1 do
    begin
      DecodeGranuleChannel(mdBr, part2_3Acc, si.Gr[gr, ch], gr, ch, si, hdr,
        AState.SfPrev[ch], xr[ch]);
      part2_3Acc := part2_3Acc + si.Gr[gr, ch].Part2_3Length;
    end;

    if ANch = 2 then
      StereoProcess(hdr, si.Gr[gr, 0], si.Gr[gr, 1], ASr, xr[0], xr[1]);

    for ch := 0 to ANch - 1 do
    begin
      AntiAlias(si.Gr[gr, ch], xr[ch]);
      HybridSynthesis(si.Gr[gr, ch], xr[ch], AState.ChState[ch], sbSamples[ch]);
      SynthFilterbank(AState.ChState[ch], sbSamples[ch], pcmScratch[ch], 0);
    end;

    for j := 0 to 575 do
      for ch := 0 to ANch - 1 do
      begin
        v := pcmScratch[ch][j];
        if v > 1.0 then begin v := 1.0; Inc(AClippedInc); end
        else if v < -1.0 then begin v := -1.0; Inc(AClippedInc); end;
        AOut[ch][gr * 576 + j] := v;
      end;
  end;
  APcmFrames := 1152;

  { push this frame's main data into the reservoir for the following frames }
  resv.Append(AData, sideStart + siBytes, mainDataBytesThisFrame);
  if resv.Len > 4096 then resv.KeepLast(4096);
  AState.ResvBuf := resv.Buf;
  AState.ResvLen := resv.Len;
end;

{ ============================ TMP3StreamDecoder ==================== }

constructor TMP3StreamDecoder.Create;
begin
  inherited Create;
  FState := AllocMem(SizeOf(TDecoderState));
end;

destructor TMP3StreamDecoder.Destroy;
begin
  if FState <> nil then
  begin
    Finalize(PDecoderState(FState)^);
    FreeMem(FState);
    FState := nil;
  end;
  inherited Destroy;
end;

procedure TMP3StreamDecoder.EnsureState;
begin
  if FState = nil then
    FState := AllocMem(SizeOf(TDecoderState));
end;

procedure TMP3StreamDecoder.ResetPipeline;
var
  st: PDecoderState;
begin
  EnsureState;
  st := PDecoderState(FState);
  Finalize(st^);
  FillChar(st^, SizeOf(TDecoderState), 0);
end;

procedure TMP3StreamDecoder.Open(const AData: TBytes);
begin
  FData := AData;
  if not ScanMp3Stream(FData, FInfo) then
    RaiseUDAW(errConfig, DEC_SUBSYS, 'no MPEG audio frames found');
  if FInfo.Layer3FrameCount = 0 then
    RaiseUDAW(errConfig, DEC_SUBSYS, 'stream contains no Layer III audio');
  if SampleRateRow(FInfo.FirstFrame.SampleRate) < 0 then
    RaiseUDAWFmt(errConfig, DEC_SUBSYS,
      'sample rate %d Hz is MPEG-2/2.5 LSF - not supported by the MP3 decoder',
      [FInfo.FirstFrame.SampleRate]);
  if not GSynthReady then BuildSynthN;

  FNch := FInfo.FirstFrame.Channels;
  FSr := FInfo.FirstFrame.SampleRate;
  FFrameIndex := 0;
  FAbsPos := 0;
  FPendingSkip := 0;
  FClipped := 0;
  FSkippedLsf := 0;
  FDecoded := 0;
  ResetPipeline;
  FOpened := True;
end;

function TMP3StreamDecoder.TotalSamples: Int64;
begin
  Result := FInfo.TotalSamples;
end;

function TMP3StreamDecoder.AtEnd: Boolean;
begin
  Result := (not FOpened) or (FFrameIndex > High(FInfo.Frames));
end;

function TMP3StreamDecoder.RunOneFrame(var AOut: TAudioPlanar;
  out AProduced: Integer; out AFrameStartAbs: Int64): Boolean;
var
  ref: TMP3FrameRef;
  hdr: TMP3FrameHeader;
begin
  AProduced := 0;
  AFrameStartAbs := FAbsPos;
  if FFrameIndex > High(FInfo.Frames) then Exit(False);

  ref := FInfo.Frames[FFrameIndex];
  Inc(FFrameIndex);

  { classify without decoding, to keep the SkippedLsf / mismatch counters }
  if ReadFrameHeaderAt(FData, ref.FileOffset, hdr) and hdr.IsLayer3 then
  begin
    if hdr.Version <> mpv1 then
      Inc(FSkippedLsf)
    else if (hdr.Channels = FNch) and (hdr.SampleRate = FSr) then
    begin
      DecodeOneMp3Frame(FData, ref, PDecoderState(FState)^, FNch, FSr,
        AOut, AProduced, FClipped);
      if AProduced > 0 then
        Inc(FDecoded);
    end;
  end;
  Result := True;
end;

function TMP3StreamDecoder.DecodeNext(var AOut: TAudioPlanar;
  out AProduced: Integer): Boolean;
var
  startAbs: Int64;
  ch, keep, skip: Integer;
begin
  AProduced := 0;
  if not FOpened then Exit(False);
  if not RunOneFrame(AOut, AProduced, startAbs) then Exit(False);

  if (AProduced > 0) and (FPendingSkip > 0) then
  begin
    skip := FPendingSkip;
    if skip > AProduced then skip := AProduced;
    keep := AProduced - skip;
    if keep > 0 then
      for ch := 0 to FNch - 1 do
        Move(AOut[ch][skip], AOut[ch][0], keep * SizeOf(Single));
    AProduced := keep;
    Dec(FPendingSkip, skip);
  end;

  Inc(FAbsPos, AProduced);
  Result := True;
end;

procedure TMP3StreamDecoder.SeekToSample(ASample: Int64);
var
  target, startFrame, i: Integer;
  scratch: TAudioPlanar;
  produced, ch: Integer;
  startAbs: Int64;
  frameStartAbs: Int64;
begin
  if not FOpened then Exit;
  if ASample < 0 then ASample := 0;
  if (TotalSamples > 0) and (ASample > TotalSamples) then ASample := TotalSamples;

  { locate the frame whose sample span contains ASample }
  target := 0;
  for i := 0 to High(FInfo.Frames) do
  begin
    if FInfo.Frames[i].SamplePos <= ASample then
      target := i
    else
      Break;
  end;

  startFrame := target - MP3_SEEK_PREROLL_FRAMES;
  if startFrame < 0 then startFrame := 0;

  ResetPipeline;
  FFrameIndex := startFrame;
  FAbsPos := FInfo.Frames[startFrame].SamplePos;
  FPendingSkip := 0;

  SetLength(scratch, FNch);
  for ch := 0 to FNch - 1 do
    SetLength(scratch[ch], MP3_MAX_FRAME_SAMPLES);

  { decode-discard from the pre-roll point up to (not including) the target
    frame so the reservoir, IMDCT overlap and synthesis V-buffers are warm }
  while (FFrameIndex < target) and (FFrameIndex <= High(FInfo.Frames)) do
  begin
    RunOneFrame(scratch, produced, startAbs);
    Inc(FAbsPos, produced);
  end;

  { the target frame itself: FAbsPos now sits at its start; ask DecodeNext to
    drop the leading samples before ASample }
  if FFrameIndex <= High(FInfo.Frames) then
  begin
    frameStartAbs := FInfo.Frames[FFrameIndex].SamplePos;
    FAbsPos := frameStartAbs;
    if ASample > frameStartAbs then
      FPendingSkip := Integer(ASample - frameStartAbs)
    else
      FPendingSkip := 0;
  end;
end;

{ ============================ DecodeMp3 (whole file) ============== }

function DecodeMp3(const AData: TBytes; out ARes: TMP3DecodeResult;
  ATrimEncoderDelay: Boolean): Boolean;
var
  sd: TMP3StreamDecoder;
  frame: TAudioPlanar;
  ch, i, produced: Integer;
  outPos, capacity: Int64;
  delay, pad, skip: Integer;
begin
  FillChar(ARes, SizeOf(ARes), 0);

  sd := TMP3StreamDecoder.Create;
  try
    sd.Open(AData);
    ARes.Info := sd.Info;
    ARes.Channels := sd.Channels;
    ARes.SampleRate := sd.SampleRate;

    capacity := sd.TotalSamples + 4608;
    if capacity < 4608 then capacity := 4608;
    SetLength(ARes.Pcm, sd.Channels);
    for ch := 0 to sd.Channels - 1 do
      SetLength(ARes.Pcm[ch], capacity);

    SetLength(frame, sd.Channels);
    for ch := 0 to sd.Channels - 1 do
      SetLength(frame[ch], MP3_MAX_FRAME_SAMPLES);

    outPos := 0;
    while sd.DecodeNext(frame, produced) do
    begin
      if produced <= 0 then Continue;
      if outPos + produced > capacity then
      begin
        capacity := outPos + produced + 4608;
        for ch := 0 to sd.Channels - 1 do
          SetLength(ARes.Pcm[ch], capacity);
      end;
      for ch := 0 to sd.Channels - 1 do
        for i := 0 to produced - 1 do
          ARes.Pcm[ch][outPos + i] := frame[ch][i];
      Inc(outPos, produced);
      ReportMediaProgress('Decoding MP3', outPos, sd.TotalSamples, sd.SampleRate);
    end;

    ARes.SkippedLsfFrames := sd.SkippedLsfFrames;
    ARes.DecodedFrames := sd.DecodedFrames;
    ARes.ClippedSamples := sd.ClippedSamples;
  finally
    sd.Free;
  end;

  { encoder delay / padding trim }
  delay := 0; pad := 0;
  if ARes.Info.Vbr.Present then
  begin
    delay := ARes.Info.Vbr.EncoderDelay;
    pad := ARes.Info.Vbr.EncoderPadding;
  end;
  if not ATrimEncoderDelay then begin delay := 0; pad := 0; end;
  if delay < 0 then delay := 0;
  { the decoder's own filterbank latency (one granule + 32-tap synthesis) that
    every MP3 decoder must skip, on top of the encoder's reported delay }
  if delay + pad >= outPos then
  begin
    delay := 0; pad := 0;
  end;
  { Gapless playback as LAME / mpg123 define it: the start skips the encoder
    delay PLUS the decoder latency, but the program length is the decoded total
    minus the tag's delay and padding only (the latency is already inside the
    tag's padding). Subtracting the latency from the length as well - as an
    earlier version did - lost the last 528 samples of every file. }
  skip := delay;
  if skip > 0 then skip := skip + 528;
  ARes.Frames := Integer(Min(outPos - delay - pad, outPos - skip));
  delay := skip;
  if ARes.Frames < 0 then ARes.Frames := 0;
  for ch := 0 to ARes.Channels - 1 do
  begin
    if delay > 0 then
      Move(ARes.Pcm[ch][delay], ARes.Pcm[ch][0], (outPos - delay) * SizeOf(Single));
    SetLength(ARes.Pcm[ch], ARes.Frames);
  end;

  Result := ARes.Frames > 0;
end;

function DecodeMp3File(const AFileName: string; out ARes: TMP3DecodeResult;
  ATrimEncoderDelay: Boolean): Boolean;
var
  fs: TFileStream;
  data: TBytes;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, DEC_SUBSYS, 'MP3 file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(data, fs.Size);
    if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
  finally
    fs.Free;
  end;
  Result := DecodeMp3(data, ARes, ATrimEncoderDelay);
end;

end.
