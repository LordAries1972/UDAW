unit Tests.Phase15;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 15 acceptance tests - MP3 *frame layer* (UDAW.Codec.MP3.Frame).

  These cover the parts of MP3 support that can be verified exhaustively with
  no reference audio: the MSB-first bit reader, the 32-bit MPEG-1/2/2.5 frame
  header decode (every version / layer / bitrate / sample-rate combination, and
  every rejection path), frame-length arithmetic, the Xing/Info/LAME and VBRI
  VBR headers, ID3v2 syncsafe size, whole-stream frame scanning with a seek
  index, CBR vs VBR classification, resync-over-garbage, and signature
  sniffing.  All test streams are built byte-by-byte in memory.

  Requires src/common and src/codecs/mp3 on the search path. }

interface

procedure RegisterPhase15Tests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Paths,
  UDAW.Audio.Types,
  UDAW.Audio.Buffer,
  UDAW.Audio.Source,
  UDAW.Codec.MP3.Frame,
  UDAW.Codec.MP3.Tables,
  UDAW.Codec.MP3.Decoder,
  UDAW.Codec.MP3.Encoder,
  UDAW.Codec.MP3.Metadata,
  UDAW.Codec.MP3,
  UDAW.Codec.MP3.Source,
  UDAW.Codec.MP3.Timeline,
  UDAW.Project.Document,
  UDAW.Project.Commands,
  UDAW.Timeline.Model,
  UDAW.Timeline.Commands;

const
  GRP = 'phase15.mp3';

{ zero-crossing dominant-frequency estimate over [AFrom,ATo), assuming 44100 Hz }
function DomFreq(const P: TAudioPlanar; ACh, AFrom, ATo: Integer): Double;
var
  i, firstX, lastX, cross: Integer;
  prev, cur: Single;
begin
  Result := 0;
  firstX := -1; lastX := -1; cross := 0;
  if AFrom < 1 then AFrom := 1;
  if ATo > Length(P[ACh]) then ATo := Length(P[ACh]);
  prev := P[ACh][AFrom - 1];
  for i := AFrom to ATo - 1 do
  begin
    cur := P[ACh][i];
    if (prev <= 0) and (cur > 0) then
    begin
      if firstX < 0 then firstX := i;
      lastX := i;
      Inc(cross);
    end;
    prev := cur;
  end;
  if (cross >= 2) and (lastX > firstX) then
    Result := (cross - 1) * 44100.0 / (lastX - firstX);
end;

{ ---------------- header builders ---------------- }

type
  TMk = record
    Ver: Integer;    // 0 = 2.5, 2 = MPEG2, 3 = MPEG1  (the raw 2-bit field)
    LayerBits: Integer; // 1 = L3, 2 = L2, 3 = L1
    BrIndex: Integer;
    SrIndex: Integer;
    Padding: Boolean;
    Mono: Boolean;
    Emphasis: Integer;
    Protection0: Boolean;   // True => CRC present (bit 16 = 0)
  end;

function BuildHeaderWord(const M: TMk): Cardinal;
var
  w: Cardinal;
begin
  w := $FFE00000;                                  // 11-bit sync
  w := w or (Cardinal(M.Ver and 3) shl 19);
  w := w or (Cardinal(M.LayerBits and 3) shl 17);
  if not M.Protection0 then w := w or (Cardinal(1) shl 16);
  w := w or (Cardinal(M.BrIndex and $F) shl 12);
  w := w or (Cardinal(M.SrIndex and 3) shl 10);
  if M.Padding then w := w or (Cardinal(1) shl 9);
  if M.Mono then
    w := w or (Cardinal(3) shl 6)
  else
    w := w or (Cardinal(0) shl 6);                  // stereo
  w := w or (Cardinal(1) shl 2);                    // original
  w := w or Cardinal(M.Emphasis and 3);
  Result := w;
end;

function DefaultMk: TMk;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Ver := 3;         // MPEG1
  Result.LayerBits := 1;   // Layer III
  Result.BrIndex := 9;     // MPEG1 L3 -> 128 kbps
  Result.SrIndex := 0;     // MPEG1 -> 44100
  Result.Protection0 := False;   // no CRC
end;

procedure PutBE32(var B: TBytes; AAt: Integer; AValue: Cardinal);
begin
  B[AAt]     := Byte(AValue shr 24);
  B[AAt + 1] := Byte(AValue shr 16);
  B[AAt + 2] := Byte(AValue shr 8);
  B[AAt + 3] := Byte(AValue);
end;

{ Append a whole CBR frame (header + zero-filled body) of the given header. }
procedure AppendFrame(var B: TBytes; const M: TMk);
var
  w: Cardinal;
  hdr: TMP3FrameHeader;
  flen, start: Integer;
begin
  w := BuildHeaderWord(M);
  if not ParseFrameHeader(w, hdr) then
    Fail('AppendFrame: header word did not parse');
  flen := hdr.FrameLengthBytes;
  if flen <= 4 then Fail('AppendFrame: frame length too small');
  start := Length(B);
  SetLength(B, start + flen);
  FillChar(B[start], flen, 0);
  PutBE32(B, start, w);
end;

{ ---------------- tests: header decode ---------------- }

procedure Test_Header_Mpeg1L3;
var
  m: TMk;
  h: TMP3FrameHeader;
begin
  m := DefaultMk;
  Check(ParseFrameHeader(BuildHeaderWord(m), h), 'MPEG1 L3 header parses');
  CheckEqualBool(True, h.Version = mpv1, 'version MPEG1');
  CheckEqualBool(True, h.Layer = mlLayer3, 'layer III');
  CheckEqualInt(128, h.BitrateKbps, 'bitrate 128k');
  CheckEqualInt(44100, h.SampleRate, 'sample rate 44100');
  CheckEqualInt(2, h.Channels, 'stereo -> 2 ch');
  CheckEqualInt(1152, h.SamplesPerFrame, 'MPEG1 L3 -> 1152 samples');
  CheckEqualInt(32, h.SideInfoBytes, 'MPEG1 stereo side info 32');
  { 144 * 128000 / 44100 = 417 (no padding) }
  CheckEqualInt(417, h.FrameLengthBytes, 'frame length 417');
  CheckEqualBool(False, h.HasCRC, 'protection bit 1 -> no CRC (typical)');
end;

procedure Test_Header_Padding;
var
  m: TMk;
  h: TMP3FrameHeader;
begin
  m := DefaultMk;
  m.Padding := True;
  Check(ParseFrameHeader(BuildHeaderWord(m), h), 'padded header parses');
  CheckEqualBool(True, h.Padding, 'padding flag set');
  CheckEqualInt(418, h.FrameLengthBytes, 'L3 padding adds exactly 1 byte');
end;

procedure Test_Header_Mpeg2L3;
var
  m: TMk;
  h: TMP3FrameHeader;
begin
  m := DefaultMk;
  m.Ver := 2;            // MPEG2
  m.SrIndex := 0;        // -> 22050
  m.BrIndex := 8;        // MPEG2 L3 -> 64 kbps
  m.Mono := True;
  m.Protection0 := True; // CRC present
  Check(ParseFrameHeader(BuildHeaderWord(m), h), 'MPEG2 L3 header parses');
  CheckEqualBool(True, h.HasCRC, 'protection bit 0 -> CRC present');
  CheckEqualBool(True, h.Version = mpv2, 'version MPEG2');
  CheckEqualInt(22050, h.SampleRate, 'sr 22050');
  CheckEqualInt(64, h.BitrateKbps, 'br 64k');
  CheckEqualInt(1, h.Channels, 'mono');
  CheckEqualInt(576, h.SamplesPerFrame, 'MPEG2 L3 -> 576 samples');
  CheckEqualInt(9, h.SideInfoBytes, 'MPEG2 mono side info 9');
  { 72 * 64000 / 22050 = 208 }
  CheckEqualInt(208, h.FrameLengthBytes, 'MPEG2 L3 frame length 208');
end;

procedure Test_Header_Mpeg25;
var
  m: TMk;
  h: TMP3FrameHeader;
begin
  m := DefaultMk;
  m.Ver := 0;           // MPEG2.5
  m.SrIndex := 2;       // -> 8000
  m.BrIndex := 1;       // -> 8 kbps
  Check(ParseFrameHeader(BuildHeaderWord(m), h), 'MPEG2.5 header parses');
  CheckEqualBool(True, h.Version = mpv25, 'version 2.5');
  CheckEqualInt(8000, h.SampleRate, 'sr 8000');
  CheckEqualInt(8, h.BitrateKbps, 'br 8k');
  CheckEqualInt(576, h.SamplesPerFrame, 'MPEG2.5 L3 -> 576 samples');
end;

procedure Test_Header_FreeFormat;
var
  m: TMk;
  h: TMP3FrameHeader;
begin
  m := DefaultMk;
  m.BrIndex := 0;       // free format
  Check(ParseFrameHeader(BuildHeaderWord(m), h), 'free-format header parses');
  CheckEqualInt(0, h.BitrateKbps, 'free format -> 0 kbps');
  CheckEqualInt(0, h.FrameLengthBytes, 'free format -> length must be measured');
end;

procedure Test_Header_Rejections;
var
  m: TMk;
  h: TMP3FrameHeader;
begin
  { no sync }
  CheckFalse(ParseFrameHeader($00000000, h), 'all-zero rejected');
  CheckFalse(ParseFrameHeader($FFC00000, h), 'partial sync rejected');
  { reserved version (raw 01) }
  m := DefaultMk; m.Ver := 1;
  CheckFalse(ParseFrameHeader(BuildHeaderWord(m), h), 'reserved version rejected');
  { reserved layer (raw 00) }
  m := DefaultMk; m.LayerBits := 0;
  CheckFalse(ParseFrameHeader(BuildHeaderWord(m), h), 'reserved layer rejected');
  { bad bitrate index 15 }
  m := DefaultMk; m.BrIndex := 15;
  CheckFalse(ParseFrameHeader(BuildHeaderWord(m), h), 'bitrate index 15 rejected');
  { reserved sample-rate index 3 }
  m := DefaultMk; m.SrIndex := 3;
  CheckFalse(ParseFrameHeader(BuildHeaderWord(m), h), 'sample-rate index 3 rejected');
  { reserved emphasis 2 }
  m := DefaultMk; m.Emphasis := 2;
  CheckFalse(ParseFrameHeader(BuildHeaderWord(m), h), 'emphasis 2 rejected');
end;

procedure Test_Header_LayerIandII;
var
  m: TMk;
  h: TMP3FrameHeader;
begin
  { Layer I, MPEG1, 32 kbps, 44100 : (12*32000/44100 + 0) * 4 = 32 }
  m := DefaultMk; m.LayerBits := 3; m.BrIndex := 1;
  Check(ParseFrameHeader(BuildHeaderWord(m), h), 'Layer I header parses');
  CheckEqualBool(True, h.Layer = mlLayer1, 'layer I');
  CheckEqualInt(384, h.SamplesPerFrame, 'Layer I -> 384');
  CheckEqualInt(32, h.FrameLengthBytes, 'Layer I frame length');

  { Layer II, MPEG1, 128 kbps, 48000 : 144*128000/48000 = 384 }
  m := DefaultMk; m.LayerBits := 2; m.BrIndex := 8; m.SrIndex := 1;
  Check(ParseFrameHeader(BuildHeaderWord(m), h), 'Layer II header parses');
  CheckEqualBool(True, h.Layer = mlLayer2, 'layer II');
  CheckEqualInt(1152, h.SamplesPerFrame, 'Layer II -> 1152');
  CheckEqualInt(384, h.FrameLengthBytes, 'Layer II frame length');
end;

{ ---------------- tests: bit reader ---------------- }

procedure Test_BitReader_Basic;
var
  data: array[0..3] of Byte;
  br: TBitReader;
begin
  { 1011 0010  1111 0000  0000 1111  1010 1010 }
  data[0] := $B2; data[1] := $F0; data[2] := $0F; data[3] := $AA;
  br.Init(@data[0], 4);
  CheckEqualInt(1, br.ReadBits(1), 'bit 0 = 1');
  CheckEqualInt(0, br.ReadBits(1), 'bit 1 = 0');
  CheckEqualInt(3, br.ReadBits(2), 'bits 2-3 = 11');
  CheckEqualInt(2, br.ReadBits(4), 'bits 4-7 = 0010');
  CheckEqualInt($F0, br.ReadBits(8), 'byte 1 = 0xF0');
  CheckEqualInt($0FAA, br.ReadBits(16), 'bytes 2-3 = 0x0FAA');
  CheckEqualBool(False, br.Overrun, 'no overrun yet');
  CheckEqualInt(0, br.ReadBits(4), 'past end reads 0');
  CheckEqualBool(True, br.Overrun, 'overrun flagged past end');
end;

procedure Test_BitReader_Seek;
var
  data: array[0..7] of Byte;
  br: TBitReader;
  i: Integer;
begin
  for i := 0 to 7 do data[i] := i * 17;
  br.Init(@data[0], 8);
  br.SkipBits(12);
  CheckEqualInt(12, br.BitPosition, 'BitPosition after skip 12');
  br.SetBitPosition(0);
  CheckEqualInt(Cardinal(data[0]), br.ReadBits(8), 'reread byte 0 after rewind');
  br.SetBitPosition(60);
  CheckEqualInt(4, br.BitsLeft, '4 bits left at bit 60 of 64');
  br.ReadBits(8);
  CheckEqualBool(True, br.Overrun, 'reading past 64 overruns');
end;

{ ---------------- tests: ID3v2 size ---------------- }

procedure Test_Id3v2_Size;
var
  b: TBytes;
  sz: Int64;
begin
  SetLength(b, 40);
  FillChar(b[0], 40, 0);
  b[0] := Ord('I'); b[1] := Ord('D'); b[2] := Ord('3');
  b[3] := 3; b[4] := 0; b[5] := 0;
  { syncsafe 0,0,2,1 -> (2<<7)|1 = 257 }
  b[6] := 0; b[7] := 0; b[8] := 2; b[9] := 1;
  Check(ReadId3v2Size(b, sz), 'ID3v2 size parses');
  CheckEqualInt(10 + 257, sz, 'size = 10 header + 257 body');

  b[5] := $10;   // footer-present flag
  Check(ReadId3v2Size(b, sz), 'ID3v2 with footer parses');
  CheckEqualInt(10 + 257 + 10, sz, 'footer adds 10');

  b[8] := $80;   // non-syncsafe byte -> invalid
  CheckFalse(ReadId3v2Size(b, sz), 'non-syncsafe size byte rejected');
end;

{ ---------------- tests: VBR headers ---------------- }

procedure Test_Vbr_Xing;
var
  m: TMk;
  h: TMP3FrameHeader;
  frame: TBytes;
  ofs, i: Integer;
  vbr: TMP3VbrHeader;
begin
  m := DefaultMk;
  ParseFrameHeader(BuildHeaderWord(m), h);
  SetLength(frame, h.FrameLengthBytes);
  FillChar(frame[0], Length(frame), 0);
  PutBE32(frame, 0, BuildHeaderWord(m));

  ofs := 4 + h.SideInfoBytes;   // 4 + 32
  frame[ofs] := Ord('X'); frame[ofs+1] := Ord('i'); frame[ofs+2] := Ord('n'); frame[ofs+3] := Ord('g');
  PutBE32(frame, ofs + 4, $00000007);      // frames + bytes + TOC (no quality word)
  PutBE32(frame, ofs + 8, 5000);           // frame count
  PutBE32(frame, ofs + 12, 1234567);       // byte count
  for i := 0 to 99 do frame[ofs + 16 + i] := Byte(i * 2);   // TOC
  { LAME tag right after: name + delay/padding at +21 }
  frame[ofs + 116] := Ord('L'); frame[ofs + 117] := Ord('A');
  frame[ofs + 118] := Ord('M'); frame[ofs + 119] := Ord('E');
  { delay 576, padding 1152 -> bytes: delay hi=576>>4=36, lo nibble = 0;
    next byte low nibble = (1152>>8)=4 ; last byte = 1152 & 255 = 128 }
  frame[ofs + 116 + 21]     := 36;
  frame[ofs + 116 + 22]     := (0 shl 4) or 4;
  frame[ofs + 116 + 23]     := 128;

  Check(ParseVbrHeader(frame, h, vbr), 'Xing parse returns true');
  CheckEqualBool(True, vbr.Present, 'Xing present');
  CheckEqualBool(False, vbr.IsVBRI, 'not VBRI');
  CheckEqualInt(5000, vbr.FrameCount, 'Xing frame count');
  CheckEqualInt(1234567, vbr.ByteCount, 'Xing byte count');
  CheckEqualInt(100, vbr.TocEntries, 'Xing TOC 100 entries');
  CheckEqualInt(576, vbr.EncoderDelay, 'LAME encoder delay');
  CheckEqualInt(1152, vbr.EncoderPadding, 'LAME encoder padding');
end;

procedure Test_Vbr_Vbri;
var
  m: TMk;
  h: TMP3FrameHeader;
  frame: TBytes;
  ofs: Integer;
  vbr: TMP3VbrHeader;
begin
  m := DefaultMk;
  ParseFrameHeader(BuildHeaderWord(m), h);
  SetLength(frame, h.FrameLengthBytes);
  FillChar(frame[0], Length(frame), 0);
  PutBE32(frame, 0, BuildHeaderWord(m));

  ofs := 4 + 32;
  frame[ofs] := Ord('V'); frame[ofs+1] := Ord('B'); frame[ofs+2] := Ord('R'); frame[ofs+3] := Ord('I');
  PutBE32(frame, ofs + 10, 987654);   // byte count
  PutBE32(frame, ofs + 14, 4321);     // frame count
  frame[ofs + 18] := 0; frame[ofs + 19] := 0;   // 0 TOC entries (keep simple)
  frame[ofs + 22] := 0; frame[ofs + 23] := 2;   // entry size 2 (unused w/ 0 entries)
  frame[ofs + 24] := 0; frame[ofs + 25] := 1;   // frames per entry

  Check(ParseVbrHeader(frame, h, vbr), 'VBRI parse returns true');
  CheckEqualBool(True, vbr.IsVBRI, 'IsVBRI');
  CheckEqualInt(987654, vbr.ByteCount, 'VBRI byte count');
  CheckEqualInt(4321, vbr.FrameCount, 'VBRI frame count');
end;

{ ---------------- tests: whole-stream scan ---------------- }

function BuildStream(const AHeaders: array of TMk; AWithId3v2, AWithId3v1: Boolean): TBytes;
var
  b: TBytes;
  i, start: Integer;
begin
  SetLength(b, 0);
  if AWithId3v2 then
  begin
    SetLength(b, 30);
    FillChar(b[0], 30, 0);
    b[0] := Ord('I'); b[1] := Ord('D'); b[2] := Ord('3'); b[3] := 3;
    b[9] := 20;   // syncsafe body size 20 -> total 30
  end;
  for i := 0 to High(AHeaders) do
    AppendFrame(b, AHeaders[i]);
  if AWithId3v1 then
  begin
    start := Length(b);
    SetLength(b, start + 128);
    FillChar(b[start], 128, 0);
    b[start] := Ord('T'); b[start+1] := Ord('A'); b[start+2] := Ord('G');
  end;
  Result := b;
end;

procedure Test_Scan_Cbr;
var
  hdrs: array[0..7] of TMk;
  i: Integer;
  data: TBytes;
  info: TMP3StreamInfo;
begin
  for i := 0 to 7 do hdrs[i] := DefaultMk;
  data := BuildStream(hdrs, True, True);

  Check(ScanMp3Stream(data, info), 'scan succeeds');
  CheckEqualInt(30, info.Id3v2Size, 'ID3v2 size 30');
  CheckEqualInt(30, info.AudioStartOffset, 'audio starts past ID3v2');
  CheckEqualBool(True, info.HasId3v1, 'ID3v1 detected');
  CheckEqualInt(8, info.FrameCount, 'all 8 frames found');
  CheckEqualInt(8, info.Layer3FrameCount, 'all Layer III');
  CheckEqualInt(8 * 1152, info.TotalSamples, 'total samples');
  CheckEqualBool(True, info.IsCBR, 'constant bitrate detected');
  CheckEqualInt(128, info.NominalBitrateKbps, 'nominal 128k');
  CheckEqualInt(30, info.Frames[0].FileOffset, 'frame 0 at 30');
  CheckEqualInt(30 + 417, info.Frames[1].FileOffset, 'frame 1 at 30+417');
  CheckEqualInt(1152, info.Frames[1].SamplePos, 'frame 1 sample pos');
  CheckEqualInt(7 * 1152, info.Frames[7].SamplePos, 'frame 7 sample pos');
end;

procedure Test_Scan_Vbr;
var
  hdrs: array[0..5] of TMk;
  i: Integer;
  data: TBytes;
  info: TMP3StreamInfo;
begin
  for i := 0 to 5 do hdrs[i] := DefaultMk;
  hdrs[1].BrIndex := 10;   // 160k
  hdrs[3].BrIndex := 11;   // 192k
  hdrs[4].BrIndex := 12;   // 224k
  data := BuildStream(hdrs, False, False);

  Check(ScanMp3Stream(data, info), 'VBR scan succeeds');
  CheckEqualInt(6, info.FrameCount, 'all 6 VBR frames found');
  CheckEqualBool(False, info.IsCBR, 'VBR classified');
  Check((info.NominalBitrateKbps >= 128) and (info.NominalBitrateKbps <= 224),
    'nominal bitrate between min and max');
  { sample positions still monotonic and evenly spaced (L3 = 1152 each) }
  for i := 1 to 5 do
    CheckEqualInt(i * 1152, info.Frames[i].SamplePos, 'VBR sample pos frame ' + IntToStr(i));
end;

procedure Test_Scan_Resync;
var
  hdrs: array[0..4] of TMk;
  i: Integer;
  clean, dirty: TBytes;
  info: TMP3StreamInfo;
  cut: Integer;
begin
  for i := 0 to 4 do hdrs[i] := DefaultMk;
  clean := BuildStream(hdrs, False, False);
  { splice 5 garbage bytes after the 2nd frame (offset 2*417) }
  cut := 2 * 417;
  SetLength(dirty, Length(clean) + 5);
  Move(clean[0], dirty[0], cut);
  dirty[cut] := $12; dirty[cut+1] := $34; dirty[cut+2] := $56;
  dirty[cut+3] := $78; dirty[cut+4] := $9A;
  Move(clean[cut], dirty[cut + 5], Length(clean) - cut);

  Check(ScanMp3Stream(dirty, info), 'scan over garbage still succeeds');
  Check(info.FrameCount >= 4, 'recovered at least 4 of 5 frames after resync');
  { sample positions must stay strictly increasing }
  for i := 1 to High(info.Frames) do
    Check(info.Frames[i].SamplePos > info.Frames[i-1].SamplePos,
      'sample positions strictly increasing across resync');
end;

{ ---------------- tests: sniffing ---------------- }

procedure Test_Sniff;
var
  data: TBytes;
  m: TMk;
  w: Cardinal;
  zeros: array[0..63] of Byte;
  wav: array[0..15] of Byte;
begin
  { valid sync at offset 0 }
  m := DefaultMk;
  w := BuildHeaderWord(m);
  SetLength(data, 64);
  FillChar(data[0], 64, 0);
  PutBE32(data, 0, w);
  CheckFalse(DataLooksLikeMp3(data[0], 64), 'isolated sync is insufficient');
  SetLength(data, 0);
  AppendFrame(data, m);
  AppendFrame(data, m);
  Check(DataLooksLikeMp3(data[0], Length(data)), 'two consecutive frames sniff as MP3');

  { valid ID3v2 header }
  FillChar(data[0], 64, 0);
  data[0] := Ord('I'); data[1] := Ord('D'); data[2] := Ord('3'); data[3] := 3;
  data[9] := 40;
  Check(DataLooksLikeMp3(data[0], 64), 'ID3v2-led stream sniffs as MP3');

  FillChar(zeros[0], SizeOf(zeros), 0);
  CheckFalse(DataLooksLikeMp3(zeros[0], SizeOf(zeros)), 'all zeros not MP3');

  wav[0] := Ord('R'); wav[1] := Ord('I'); wav[2] := Ord('F'); wav[3] := Ord('F');
  wav[8] := Ord('W'); wav[9] := Ord('A'); wav[10] := Ord('V'); wav[11] := Ord('E');
  CheckFalse(DataLooksLikeMp3(wav[0], 16), 'RIFF/WAVE not MP3');
end;

{ ---------------- tests: Huffman tables ---------------- }

procedure Test_Huffman_SelfCheck;
var
  err: string;
  br: TBitReader;
  data: array[0..3] of Byte;
  x, y: Integer;
begin
  Check(HuffmanTablesSelfCheck(err), 'all Huffman tables are complete prefix codes: ' + err);

  { table 1 spot check: code "1" (len 1) -> (0,0); "01" -> (1,0); "000" -> (1,1);
    "001" -> (0,1). Pack bits MSB-first: 1 01 000 001 = 1010 0000 1 -> $A0 $80 }
  data[0] := $A0; data[1] := $80; data[2] := 0; data[3] := 0;
  br.Init(@data[0], 4);
  MP3Huff[1].Decode(br, x, y); Check((x = 0) and (y = 0), 'table1 "1" -> (0,0)');
  MP3Huff[1].Decode(br, x, y); Check((x = 1) and (y = 0), 'table1 "01" -> (1,0)');
  MP3Huff[1].Decode(br, x, y); Check((x = 1) and (y = 1), 'table1 "000" -> (1,1)');
  MP3Huff[1].Decode(br, x, y); Check((x = 0) and (y = 1), 'table1 "001" -> (0,1)');

  { count1 table 33 (ISO table B): 4-bit codes, INVERTED - "0000" -> vwxy 15,
    "1111" -> vwxy 0 }
  data[0] := $00;
  br.Init(@data[0], 1);
  MP3Huff[33].Decode(br, x, y);
  CheckEqualInt(15, x, 'count1 tbl33 "0000" -> vwxy 15');
  data[0] := $F0;
  br.Init(@data[0], 1);
  MP3Huff[33].Decode(br, x, y);
  CheckEqualInt(0, x, 'count1 tbl33 "1111" -> vwxy 0');
end;

{ ---------------- tests: decoder conformance vs ffmpeg golden PCM ---------------- }

function FixturePath(const AName: string): string;
var
  cands: array[0..3] of string;
  i: Integer;
begin
  cands[0] := 'tests' + PathDelim + 'fixtures' + PathDelim + AName;
  cands[1] := '..' + PathDelim + 'tests' + PathDelim + 'fixtures' + PathDelim + AName;
  cands[2] := 'fixtures' + PathDelim + AName;
  cands[3] := ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' + PathDelim +
              'tests' + PathDelim + 'fixtures' + PathDelim + AName;
  for i := 0 to High(cands) do
    if FileExists(cands[i]) then Exit(cands[i]);
  Result := cands[0];
end;

function LoadF32Interleaved(const AFile: string; AChannels: Integer): TAudioPlanar;
var
  fs: TFileStream;
  raw: TBytes;
  n, frames, ch, i: Integer;
  pf: PSingle;
begin
  fs := TFileStream.Create(AFile, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(raw, fs.Size);
    if Length(raw) > 0 then fs.ReadBuffer(raw[0], Length(raw));
  finally
    fs.Free;
  end;
  n := Length(raw) div 4;
  frames := n div AChannels;
  SetLength(Result, AChannels);
  for ch := 0 to AChannels - 1 do SetLength(Result[ch], frames);
  pf := PSingle(@raw[0]);
  for i := 0 to frames - 1 do
    for ch := 0 to AChannels - 1 do
      Result[ch][i] := pf[i * AChannels + ch];
end;

{ best-lag segmental SNR of ATest vs ARef (channel 0), searching +/-AMaxLag.
  Returns dB; higher is better. Returns -999 if there is no usable overlap. }
function AlignedSNR(const ARef, ATest: TAudioPlanar; AMaxLag: Integer): Double;
var
  refN, testN, lag, bestLag, i, a, b, guard, lo, hi: Integer;
  corr, bestCorr, sigE, errE, d, na, nb: Double;
begin
  Result := -999;
  if (Length(ARef) = 0) or (Length(ATest) = 0) then Exit;
  refN := Length(ARef[0]);
  testN := Length(ATest[0]);
  if (refN < 8192) or (testN < 8192) then Exit;

  { the decoder may carry encoder-priming silence at the front, so the test
    output is generally LATER than the trimmed golden: search 0..AMaxLag plus a
    small negative margin, using normalised cross-correlation. }
  lo := -256; hi := AMaxLag;
  bestCorr := -1e30; bestLag := 0;
  for lag := lo to hi do
  begin
    corr := 0; na := 0; nb := 0;
    i := 4000;
    while i < 16000 do
    begin
      a := i; b := i + lag;
      if (b >= 0) and (b < testN) and (a < refN) then
      begin
        corr := corr + ARef[0][a] * ATest[0][b];
        na := na + ARef[0][a] * ARef[0][a];
        nb := nb + ATest[0][b] * ATest[0][b];
      end;
      Inc(i);
    end;
    if (na > 0) and (nb > 0) then
    begin
      corr := corr / Sqrt(na * nb);
      if corr > bestCorr then begin bestCorr := corr; bestLag := lag; end;
    end;
  end;

  guard := 2000;
  sigE := 0; errE := 0;
  i := guard;
  while (i < refN - guard) and (i + bestLag < testN) do
  begin
    if i + bestLag >= 0 then
    begin
      d := ARef[0][i] - ATest[0][i + bestLag];
      sigE := sigE + ARef[0][i] * ARef[0][i];
      errE := errE + d * d;
    end;
    Inc(i);
  end;
  Writeln(Format('    [snr] bestLag=%d corr=%.3f', [bestLag, bestCorr]));
  if sigE <= 0 then Exit;
  if errE <= 0 then Exit(200);
  Result := 10.0 * Log10(sigE / errE);
end;

procedure DecodeAndCompare(const AMp3, AGolden: string; AChannels: Integer;
  AMinSNR: Double; const ALabel: string);
var
  res: TMP3DecodeResult;
  golden: TAudioPlanar;
  snr: Double;
begin
  if not FileExists(FixturePath(AMp3)) then
    Fail('missing fixture ' + AMp3 + ' (see tests/fixtures/README.md)');
  { decode without delay trimming; the SNR aligner finds the offset }
  Check(DecodeMp3File(FixturePath(AMp3), res, False), ALabel + ': decode returned data');
  CheckEqualInt(AChannels, res.Channels, ALabel + ': channel count');
  Check(res.Frames > 2000, ALabel + ': produced enough frames');
  golden := LoadF32Interleaved(FixturePath(AGolden), AChannels);
  snr := AlignedSNR(golden, res.Pcm, 5000);
  Writeln(Format('    [%s] decoder vs ffmpeg golden: SNR = %.2f dB (frames %d vs %d)',
    [ALabel, snr, res.Frames, Length(golden[0])]));
  Check(snr >= AMinSNR, Format('%s: SNR %.2f dB below %.2f dB floor', [ALabel, snr, AMinSNR]));
end;

procedure Test_Decode_ToneCbr;
begin
  DecodeAndCompare('tone_cbr128.mp3', 'tone_cbr128.f32', 2, 12.0, 'tone CBR128');
end;

procedure Test_Decode_ToneVbr;
var
  res: TMP3DecodeResult;
  domL, domR: Double;
begin
  Check(DecodeMp3File(FixturePath('tone_vbr.mp3'), res), 'VBR decode');
  Check(res.Frames > 4000, 'VBR produced frames');
  { spectral check: left channel ~440 Hz, right ~1500 Hz }
  domL := DomFreq(res.Pcm, 0, 1000, res.Frames - 1000);
  domR := DomFreq(res.Pcm, 1, 1000, res.Frames - 1000);
  Check(Abs(domL - 440.0) < 25.0, Format('VBR left dominant freq %.1f ~ 440', [domL]));
  Check(Abs(domR - 1500.0) < 40.0, Format('VBR right dominant freq %.1f ~ 1500', [domR]));
end;

procedure Test_Decode_RealExcerpt;
begin
  DecodeAndCompare('real_excerpt.mp3', 'real_excerpt.f32', 2, 10.0, 'real excerpt 48k');
end;

{ ---------------- tests: ID3 metadata round-trip ---------------- }

procedure Test_Metadata_RoundTrip;
var
  meta, back: TMP3Metadata;
  v2, v1, stream: TBytes;
  m: TMk;
  n: Integer;
begin
  meta.Clear;
  meta.Title := 'Test Title';
  meta.Artist := 'The Artist';
  meta.Album := 'An Album';
  meta.Year := '2026';
  meta.Comment := 'hello';
  meta.Genre := 'Electronic';
  meta.TrackNumber := '3';

  v2 := BuildId3v2Tag(meta);
  v1 := BuildId3v1Tag(meta);
  Check(Length(v2) >= 10, 'ID3v2 tag built');
  Check((v2[0] = Ord('I')) and (v2[1] = Ord('D')) and (v2[2] = Ord('3')), 'ID3v2 magic');
  CheckEqualInt(128, Length(v1), 'ID3v1 is 128 bytes');
  Check((v1[0] = Ord('T')) and (v1[1] = Ord('A')) and (v1[2] = Ord('G')), 'ID3v1 magic');

  { v2 tag + one silent frame + v1 tag }
  m := DefaultMk;
  SetLength(stream, 0);
  n := Length(stream); SetLength(stream, n + Length(v2)); Move(v2[0], stream[n], Length(v2));
  AppendFrame(stream, m);
  n := Length(stream); SetLength(stream, n + Length(v1)); Move(v1[0], stream[n], Length(v1));

  back := ReadMp3Metadata(stream);
  Check(back.HasV2, 'v2 detected on read-back');
  CheckEqualStr('Test Title', back.Title, 'title survives round-trip');
  CheckEqualStr('The Artist', back.Artist, 'artist survives round-trip');
  CheckEqualStr('An Album', back.Album, 'album survives round-trip');
  Check(Pos('2026', back.Year) = 1, 'year survives round-trip');
end;

{ ---------------- tests: encoder ---------------- }

function MakeTone(AFreqL, AFreqR: Double; ASampleRate, AFrames: Integer): TAudioPlanar;
var
  i: Integer;
begin
  SetLength(Result, 2);
  SetLength(Result[0], AFrames);
  SetLength(Result[1], AFrames);
  for i := 0 to AFrames - 1 do
  begin
    Result[0][i] := 0.5 * Sin(2 * Pi * AFreqL * i / ASampleRate);
    Result[1][i] := 0.5 * Sin(2 * Pi * AFreqR * i / ASampleRate);
  end;
end;

procedure Test_Encode_ProducesValidStream;
var
  pcm: TAudioPlanar;
  opt: TMP3EncodeOptions;
  res: TMP3EncodeResult;
  info: TMP3StreamInfo;
begin
  pcm := MakeTone(440, 660, 44100, 44100);   // 1 s
  opt := TMP3EncodeOptions.Default;
  opt.Mode := emCBR;
  opt.BitrateKbps := 192;
  Check(EncodeMp3(pcm, 44100, opt, res), 'CBR encode returns data');
  Check(res.FrameCount >= 36, 'about 38 frames for 1 s');
  Check(DataLooksLikeMp3(res.Data[0], Length(res.Data)), 'encoded stream sniffs as MP3');

  Check(ScanMp3Stream(res.Data, info), 'encoded stream scans');
  CheckEqualInt(44100, info.FirstFrame.SampleRate, 'encoded sample rate 44100');
  CheckEqualInt(2, info.FirstFrame.Channels, 'encoded stereo');
  CheckEqualBool(True, info.FirstFrame.Layer = mlLayer3, 'encoded Layer III');
  Check(info.Vbr.Present, 'Xing/Info header frame present');
  Check(info.IsCBR, 'CBR classification');
  CheckEqualInt(192, info.NominalBitrateKbps, 'nominal 192 kbps');
end;

procedure Test_Encode_VbrClassifies;
var
  pcm: TAudioPlanar;
  opt: TMP3EncodeOptions;
  res: TMP3EncodeResult;
  info: TMP3StreamInfo;
begin
  pcm := MakeTone(300, 300, 48000, 48000);
  opt := TMP3EncodeOptions.Default;
  opt.Mode := emVBR;
  opt.BitrateKbps := 256;       // ceiling
  opt.MinBitrateKbps := 96;
  opt.VBRQuality := 4;
  Check(EncodeMp3(pcm, 48000, opt, res), 'VBR encode returns data');
  Check(ScanMp3Stream(res.Data, info), 'VBR stream scans');
  Check(res.FrameCount >= 30, 'VBR produced frames');
end;

procedure Test_Encode_DecodeRoundTrip;
var
  pcm, dec: TAudioPlanar;
  opt: TMP3EncodeOptions;
  eres: TMP3EncodeResult;
  dres: TMP3DecodeResult;
  domL, domR: Double;
begin
  pcm := MakeTone(440, 1500, 44100, 44100 * 2);   // 2 s
  opt := TMP3EncodeOptions.Default;
  opt.Mode := emCBR;
  opt.BitrateKbps := 256;
  Check(EncodeMp3(pcm, 44100, opt, eres), 'encode for round-trip');

  Check(DecodeMp3(eres.Data, dres, False), 'decode the freshly encoded stream');
  CheckEqualInt(2, dres.Channels, 'round-trip channel count');
  Check(dres.Frames > 44100, 'round-trip produced ~2 s of audio');
  dec := dres.Pcm;

  { the tone should survive: dominant frequency per channel within tolerance }
  domL := DomFreq(dec, 0, 2000, dres.Frames - 2000);
  domR := DomFreq(dec, 1, 2000, dres.Frames - 2000);
  Writeln(Format('    [enc-rt] domL=%.1f (want 440)  domR=%.1f (want 1500)', [domL, domR]));
  Check(Abs(domL - 440.0) < 30.0, Format('round-trip left dominant %.1f ~ 440', [domL]));
  Check(Abs(domR - 1500.0) < 60.0, Format('round-trip right dominant %.1f ~ 1500', [domR]));
end;

{ ---------------- ISO scalefactor-band table lock ---------------- }

{ ISO/IEC 11172-3 Table B.8 - MPEG-1 Layer III long/short sfBandIndex boundaries.
  The decoder + encoder both index SFB_*_WIDTH; a wrong row garbles the top of
  the spectrum for that sample rate (this is how the 48 kHz long row shipped in
  Phase 15 with bands 19..21 = 54,54,192 instead of 56,68,176 - "muffled" 48 kHz
  playback). Lock every value against the reference. }
procedure Test_SfbTables_MatchISO;
const
  LONG_BOUNDARY: array[0..2, 0..22] of Integer = (
    { 44100 } (0,4,8,12,16,20,24,30,36,44,52,62,74,90,110,134,162,196,238,288,342,418,576),
    { 48000 } (0,4,8,12,16,20,24,30,36,42,50,60,72,88,106,128,156,190,230,276,332,400,576),
    { 32000 } (0,4,8,12,16,20,24,30,36,44,54,66,82,102,126,156,194,240,296,364,448,550,576));
  SHORT_BOUNDARY: array[0..2, 0..13] of Integer = (
    { 44100 } (0,4,8,12,16,22,30,40,52,66,84,106,136,192),
    { 48000 } (0,4,8,12,16,22,28,38,50,64,80,100,126,192),
    { 32000 } (0,4,8,12,16,22,30,42,58,78,104,138,180,192));
var
  r, i, acc: Integer;
begin
  for r := 0 to 2 do
  begin
    acc := 0;
    for i := 0 to 21 do
    begin
      CheckEqualInt(LONG_BOUNDARY[r, i + 1] - LONG_BOUNDARY[r, i],
        SFB_LONG_WIDTH[r, i],
        Format('SFB_LONG_WIDTH[%d,%d] vs ISO B.8', [r, i]));
      acc := acc + SFB_LONG_WIDTH[r, i];
    end;
    CheckEqualInt(576, acc, Format('long sfb widths for rate row %d sum to 576', [r]));

    acc := 0;
    for i := 0 to 12 do
    begin
      CheckEqualInt(SHORT_BOUNDARY[r, i + 1] - SHORT_BOUNDARY[r, i],
        SFB_SHORT_WIDTH[r, i],
        Format('SFB_SHORT_WIDTH[%d,%d] vs ISO B.8', [r, i]));
      acc := acc + SFB_SHORT_WIDTH[r, i];
    end;
    CheckEqualInt(192, acc, Format('short sfb widths for rate row %d sum to 192', [r]));
  end;
end;

{ ---------------- Phase 15 follow-up: streaming decoder / source / import ---- }

function EncodeToneMp3(AFreqL, AFreqR: Double; ASr, AFrames, ABitrate: Integer): TBytes;
var
  pcm: TAudioPlanar;
  opt: TMP3EncodeOptions;
  res: TMP3EncodeResult;
begin
  pcm := MakeTone(AFreqL, AFreqR, ASr, AFrames);
  opt := TMP3EncodeOptions.Default;
  opt.Mode := emCBR;
  opt.BitrateKbps := ABitrate;
  Check(EncodeMp3(pcm, ASr, opt, res), 'EncodeToneMp3 produced a stream');
  Result := res.Data;
end;

procedure Test_Stream_IncrementalMatchesWhole;
var
  bytes: TBytes;
  whole: TMP3DecodeResult;
  sd: TMP3StreamDecoder;
  frame: TAudioPlanar;
  ch, i, produced: Integer;
  total: Int64;
  maxDiff: Single;
begin
  bytes := EncodeToneMp3(440, 660, 44100, 44100, 192);
  Check(DecodeMp3(bytes, whole, False), 'whole-file decode');

  sd := TMP3StreamDecoder.Create;
  try
    sd.Open(bytes);
    CheckEqualInt(whole.Channels, sd.Channels, 'stream channel count matches whole-file');
    SetLength(frame, sd.Channels);
    for ch := 0 to sd.Channels - 1 do SetLength(frame[ch], MP3_MAX_FRAME_SAMPLES);
    total := 0;
    maxDiff := 0;
    while sd.DecodeNext(frame, produced) do
    begin
      for i := 0 to produced - 1 do
      begin
        if total + i >= whole.Frames then Break;
        for ch := 0 to sd.Channels - 1 do
          maxDiff := Max(maxDiff, Abs(frame[ch][i] - whole.Pcm[ch][total + i]));
      end;
      Inc(total, produced);
    end;
    Check(total >= whole.Frames,
      Format('incremental produced >= whole-file (%d vs %d)', [total, whole.Frames]));
    Check(maxDiff < 1.0E-4,
      Format('incremental samples equal the whole-file path (max diff %.2e)', [maxDiff]));
  finally
    sd.Free;
  end;
end;

procedure Test_Stream_SeekPreroll;
var
  bytes: TBytes;
  whole: TMP3DecodeResult;
  sd: TMP3StreamDecoder;
  frame, seg, ref: TAudioPlanar;
  ch, i, produced, n: Integer;
  target: Int64;
  snr: Double;
begin
  bytes := EncodeToneMp3(440, 440, 44100, 44100 * 3, 192);
  Check(DecodeMp3(bytes, whole, False), 'whole decode for seek reference');

  sd := TMP3StreamDecoder.Create;
  try
    sd.Open(bytes);
    target := 44100 + 5000;                 // ~1.1 s in
    sd.SeekToSample(target);

    SetLength(frame, sd.Channels);
    for ch := 0 to sd.Channels - 1 do SetLength(frame[ch], MP3_MAX_FRAME_SAMPLES);
    SetLength(seg, sd.Channels);
    for ch := 0 to sd.Channels - 1 do SetLength(seg[ch], 0);

    n := 0;
    while (n < 24000) and sd.DecodeNext(frame, produced) do
    begin
      for ch := 0 to sd.Channels - 1 do
      begin
        SetLength(seg[ch], n + produced);
        for i := 0 to produced - 1 do seg[ch][n + i] := frame[ch][i];
      end;
      Inc(n, produced);
    end;
    Check(n >= 8192, 'seek then decoded a usable block');

    SetLength(ref, sd.Channels);
    for ch := 0 to sd.Channels - 1 do
    begin
      SetLength(ref[ch], n);
      for i := 0 to n - 1 do
        if target + i < whole.Frames then ref[ch][i] := whole.Pcm[ch][target + i];
    end;
    snr := AlignedSNR(ref, seg, 64);
    Writeln(Format('    [stream-seek] reconvergence SNR = %.1f dB', [snr]));
    Check(snr > 20.0,
      Format('post-seek block converges to the reference (SNR %.1f dB)', [snr]));
  finally
    sd.Free;
  end;
end;

procedure Test_Source_RenderAndSeek;
var
  bytes: TBytes;
  obj: TMP3StreamSource;
  src: IAudioSource;
  buf: TAudioBuffer;
  i, ch: Integer;
  e0, e1: Double;
begin
  bytes := EncodeToneMp3(440, 440, 44100, 44100 * 2, 192);
  obj := TMP3StreamSource.CreateFromData(bytes, False);
  src := obj;                             // hold via the interface (ref-counted)
  CheckEqualInt(44100, obj.SourceRate, 'source sample rate');
  CheckEqualInt(2, obj.SourceChannels, 'source channels');
  Check(obj.DurationSeconds > 1.5, 'source duration ~2 s');

  buf := TAudioBuffer.Create(2, 4096, 44100);
  try
    src.Prepare(44100, 4096, 2);
    buf.Configure(2, 2048, 44100);
    src.Render(buf);
    e0 := 0;
    for ch := 0 to 1 do
      for i := 0 to buf.FrameCount - 1 do e0 := e0 + Abs(buf.ChannelPtr(ch)[i]);
    Check(e0 > 1.0, 'render from the start produced signal');

    obj.SeekSeconds(1.5);
    buf.Configure(2, 2048, 44100);
    src.Render(buf);
    Check(obj.PositionSeconds >= 1.5, 'position advanced past the seek target');
    e1 := 0;
    for ch := 0 to 1 do
      for i := 0 to buf.FrameCount - 1 do e1 := e1 + Abs(buf.ChannelPtr(ch)[i]);
    Check(e1 > 1.0, 'render after the seek still produces signal');
  finally
    buf.Free;
  end;
  src := nil;                              // releases obj
end;

procedure Test_Import_MP3_Command;
var
  bytes: TBytes;
  fn: string;
  fs: TFileStream;
  doc: TProjectDocument;
  mgr: TCommandManager;
  trkCmd: TAddTimelineTrackCommand;
  impCmd: TImportMp3Command;
  trackId, clipId: Integer;
  c: TTimelineClip;
begin
  bytes := EncodeToneMp3(440, 660, 44100, 44100, 192);
  fn := IncludeTrailingPathDelimiter(Paths.Temp) + 'udaw_test_import.mp3';
  fs := TFileStream.Create(fn, fmCreate);
  try
    if Length(bytes) > 0 then fs.WriteBuffer(bytes[0], Length(bytes));
  finally
    fs.Free;
  end;

  try
    doc := TProjectDocument.CreateNew('imp');
    mgr := TCommandManager.Create;
    try
      trkCmd := TAddTimelineTrackCommand.Create(doc, tkAudio, 'Audio 1');
      mgr.Perform(trkCmd);
      trackId := trkCmd.CreatedId;

      impCmd := TImportMp3Command.Create(doc, trackId, fn, 2.0, 0);
      Check(mgr.Perform(impCmd), 'import-MP3 command executed');
      clipId := impCmd.CreatedClipId;
      CheckEqualInt(44100, impCmd.ImportedSampleRate, 'probed sample rate');
      CheckEqualInt(2, impCmd.ImportedChannels, 'probed channel count');

      c := doc.Timeline.ClipById(clipId);
      Check(c <> nil, 'clip present after import');
      CheckNear(2.0, c.StartSeconds, 1.0E-6, 'clip start honoured');
      Check(c.LengthSeconds > 0.8, 'clip length is ~1 s');
      Check(doc.Timeline.SourceCount >= 1, 'a media source was registered');

      mgr.Undo;
      Check(doc.Timeline.ClipById(clipId) = nil, 'undo removed the imported clip');

      mgr.Redo;
      Check(doc.Timeline.ClipById(clipId) <> nil, 'redo restored the imported clip');
    finally
      mgr.Free;
      doc.Free;
    end;
  finally
    if FileExists(fn) then DeleteFile(fn);
  end;
end;

{ ---------------- registration ---------------- }

procedure RegisterPhase15Tests;
begin
  RegisterTest(GRP, 'Huffman tables self-check + decode', Test_Huffman_SelfCheck);
  RegisterTest(GRP, 'decode conformance - tone CBR 128k vs ffmpeg', Test_Decode_ToneCbr);
  RegisterTest(GRP, 'decode - tone VBR spectral check', Test_Decode_ToneVbr);
  RegisterTest(GRP, 'decode conformance - real 48k excerpt vs ffmpeg', Test_Decode_RealExcerpt);
  RegisterTest(GRP, 'ID3 metadata build + read round-trip', Test_Metadata_RoundTrip);
  RegisterTest(GRP, 'encoder - CBR produces a valid scannable stream', Test_Encode_ProducesValidStream);
  RegisterTest(GRP, 'encoder - VBR mode encodes', Test_Encode_VbrClassifies);
  RegisterTest(GRP, 'encoder - encode->decode tone round-trip', Test_Encode_DecodeRoundTrip);
  RegisterTest(GRP, 'header MPEG-1 Layer III', Test_Header_Mpeg1L3);
  RegisterTest(GRP, 'header padding adds one slot', Test_Header_Padding);
  RegisterTest(GRP, 'header MPEG-2 Layer III', Test_Header_Mpeg2L3);
  RegisterTest(GRP, 'header MPEG-2.5', Test_Header_Mpeg25);
  RegisterTest(GRP, 'header free format', Test_Header_FreeFormat);
  RegisterTest(GRP, 'header rejection paths', Test_Header_Rejections);
  RegisterTest(GRP, 'header Layer I / II length', Test_Header_LayerIandII);
  RegisterTest(GRP, 'bit reader MSB-first + overrun', Test_BitReader_Basic);
  RegisterTest(GRP, 'bit reader seek / bits-left', Test_BitReader_Seek);
  RegisterTest(GRP, 'ID3v2 syncsafe size', Test_Id3v2_Size);
  RegisterTest(GRP, 'Xing / Info / LAME header', Test_Vbr_Xing);
  RegisterTest(GRP, 'VBRI header', Test_Vbr_Vbri);
  RegisterTest(GRP, 'stream scan - CBR + ID3 envelope', Test_Scan_Cbr);
  RegisterTest(GRP, 'stream scan - VBR classification', Test_Scan_Vbr);
  RegisterTest(GRP, 'stream scan - resync over garbage', Test_Scan_Resync);
  RegisterTest(GRP, 'signature sniffing', Test_Sniff);
  RegisterTest(GRP, 'scalefactor-band width tables vs ISO 11172-3 B.8', Test_SfbTables_MatchISO);
  RegisterTest(GRP, 'stream decoder - incremental output equals whole-file', Test_Stream_IncrementalMatchesWhole);
  RegisterTest(GRP, 'stream decoder - SeekToSample pre-roll reconverges', Test_Stream_SeekPreroll);
  RegisterTest(GRP, 'MP3 IAudioSource - render + seek', Test_Source_RenderAndSeek);
  RegisterTest(GRP, 'TImportMp3Command - execute / undo / redo', Test_Import_MP3_Command);
end;

end.
