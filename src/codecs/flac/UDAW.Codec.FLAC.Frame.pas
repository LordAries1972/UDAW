unit UDAW.Codec.FLAC.Frame;
{$I udaw.inc}
{$POINTERMATH ON}

{ FLAC decode-only support - bitstream / frame layer.

  A from-scratch MSB-first bit reader (mirrors UDAW.Codec.MP3.Frame.TBitReader),
  the FLAC metadata-block walker (STREAMINFO is fully parsed; every other block
  type is recognised and skipped by length), the 32-bit-plus FLAC frame header
  decode (block size / sample rate / channel assignment / bits-per-sample,
  including every "get it from STREAMINFO" and "read N more bits" escape, the
  UTF-8-style variable-length frame/sample-number code, and the header's CRC-8),
  and the CRC-8 / CRC-16 routines the frame footer uses.

  Nothing here trusts a file extension: DataLooksLikeFlac / FileLooksLikeFlac
  look for the literal 4-byte "fLaC" magic (optionally past a leading ID3v2 tag
  some taggers mistakenly prepend), never the file name.

  FLAC does not encode an explicit frame length in its header - the true frame
  size is only known once the frame's subframes and residual have been fully
  decoded, unlike MPEG audio where the header alone gives the frame length.  So
  this unit's "whole-stream scan" is metadata-block-only (ScanFlacMetadata):
  it locates STREAMINFO and the offset audio starts at.  The frame-by-frame
  walk that discovers actual frame boundaries lives in the decoder
  (UDAW.Codec.FLAC.Decoder), which decodes each frame in turn and thereby knows
  exactly where the next one begins. }

interface

uses
  SysUtils, Classes, Math,
  UDAW.Errors;

const
  FLAC_SUBSYS = 'Codec.FLAC';

  FLAC_MAGIC: array[0..3] of Byte = (Ord('f'), Ord('L'), Ord('a'), Ord('C'));
  FLAC_SYNC_CODE = $3FFE;              // 14-bit frame sync '11111111111110'

  FLAC_MAX_FILE_BYTES = Int64(768) * 1024 * 1024;

  { metadata block types (STREAMINFO.md, section "METADATA_BLOCK_HEADER") }
  FLAC_BLOCK_STREAMINFO     = 0;
  FLAC_BLOCK_PADDING        = 1;
  FLAC_BLOCK_APPLICATION    = 2;
  FLAC_BLOCK_SEEKTABLE      = 3;
  FLAC_BLOCK_VORBIS_COMMENT = 4;
  FLAC_BLOCK_CUESHEET       = 5;
  FLAC_BLOCK_PICTURE        = 6;

type
  { MSB-first bit reader over a byte buffer, mirroring
    UDAW.Codec.MP3.Frame.TBitReader.  Reads past the end return 0 and set
    Overrun - callers treat that as "stream ended mid-frame", never a fault. }
  TFlacBitReader = record
  private
    FData: PByte;
    FLen: Integer;
    FBytePos: Integer;
    FBitPos: Integer;          // 0..7, bits already consumed in the current byte
    FOverrun: Boolean;
  public
    procedure Init(AData: PByte; ALen: Integer; AStartByte: Integer = 0);
    function ReadBit: Cardinal;
    function ReadBits(ACount: Integer): Cardinal;         // ACount 0..32
    function ReadBitsBig(ACount: Integer): UInt64;         // ACount 0..64
    { Signed two's-complement value coded in ACount bits (0..64). }
    function ReadSigned(ACount: Integer): Int64;
    { Number of 0 bits before the terminating 1 bit (unary code). Capped and
      marked Overrun if the stream runs out before a 1 bit appears. }
    function ReadUnary: Cardinal;
    procedure SkipBits(ACount: Integer);
    procedure AlignToByte;
    function BitPosition: Int64;         // absolute, from buffer start
    function BitsLeft: Int64;
    property Overrun: Boolean read FOverrun;
    property BytePos: Integer read FBytePos;
    property BitPos: Integer read FBitPos;
  end;

  { STREAMINFO (mandatory first metadata block). }
  TFlacStreamInfo = record
    MinBlockSize: Integer;
    MaxBlockSize: Integer;
    MinFrameSize: Integer;      // 0 == unknown
    MaxFrameSize: Integer;      // 0 == unknown
    SampleRate: Integer;
    Channels: Integer;          // 1..8
    BitsPerSample: Integer;     // 4..32
    TotalSamples: Int64;        // 0 == unknown (streamed)
    MD5: array[0..15] of Byte;
    Present: Boolean;
    function DurationSeconds: Double;
    function Describe: string;
  end;

  TFlacChannelAssign = (fcaIndependent, fcaLeftSide, fcaRightSide, fcaMidSide);

  { One decoded frame header. Valid only when Parsed is set. On return ABr sits
    immediately after the header's CRC-8 byte, ready for subframe data. }
  TFlacFrameHeader = record
    VariableBlocking: Boolean;
    BlockSize: Integer;
    SampleRate: Integer;
    ChannelAssign: TFlacChannelAssign;
    RawChannelCode: Integer;
    Channels: Integer;            // independent channel count (always 2 for */side)
    BitsPerSample: Integer;       // per-channel storage depth (pre stereo +1 adjust)
    FrameOrSampleNumber: UInt64;  // frame number (fixed) or first sample (variable)
    HeaderCrcOk: Boolean;
    HeaderStartByte: Int64;
    Parsed: Boolean;
    function Describe: string;
  end;

  TFlacMetaBlockHeader = record
    IsLast: Boolean;
    BlockType: Integer;
    Length: Integer;             // payload length in bytes
  end;

{ ---- CRC ---- }
function Flac_CRC8(const AData: TBytes; AFrom, ALen: Integer): Byte;
function Flac_CRC16(const AData: TBytes; AFrom, ALen: Integer): Word;

{ ---- sniffing (never looks at the name) ---- }
function DataLooksLikeFlac(const AData; ALength: Integer): Boolean;
function FileLooksLikeFlac(const AFileName: string): Boolean;

{ ---- metadata ---- }
function ReadMetaBlockHeaderAt(const AData: TBytes; AOffset: Int64;
  out AHdr: TFlacMetaBlockHeader): Boolean;
function ParseStreamInfoBlock(const AData: TBytes; AOffset: Int64;
  out AInfo: TFlacStreamInfo): Boolean;

{ Locate the "fLaC" magic (offset 0, or right after a leading ID3v2 tag),
  parse every metadata block up to and including the last one, and return the
  byte offset the first audio frame starts at. }
function ScanFlacMetadata(const AData: TBytes; out AInfo: TFlacStreamInfo;
  out AAudioStart: Int64): Boolean;

{ ---- frame header ----
  ABr must already be initialised over AData and positioned at the candidate
  frame's first byte (the 0xFF sync byte) - i.e. the caller did
  ABr.Init(@AData[0], Length(AData), offset).  AData is needed only to run the
  header's CRC-8 over the raw bytes; on success ABr is left just past the
  header's CRC-8 byte, ready for subframe data. }
function ParseFlacFrameHeader(const AData: TBytes; var ABr: TFlacBitReader;
  const AStreamInfo: TFlacStreamInfo; out AHdr: TFlacFrameHeader): Boolean;

function ChannelAssignName(A: TFlacChannelAssign): string;

implementation

{ ============================ CRC ==================================== }

function Flac_CRC8(const AData: TBytes; AFrom, ALen: Integer): Byte;
var
  i, b: Integer;
  crc: Byte;
begin
  crc := 0;
  for i := AFrom to AFrom + ALen - 1 do
  begin
    crc := crc xor AData[i];
    for b := 0 to 7 do
      if (crc and $80) <> 0 then crc := Byte((crc shl 1) xor $07)
      else crc := Byte(crc shl 1);
  end;
  Result := crc;
end;

function Flac_CRC16(const AData: TBytes; AFrom, ALen: Integer): Word;
var
  i, b: Integer;
  crc: Word;
begin
  crc := 0;
  for i := AFrom to AFrom + ALen - 1 do
  begin
    crc := crc xor (Word(AData[i]) shl 8);
    for b := 0 to 7 do
      if (crc and $8000) <> 0 then crc := Word((crc shl 1) xor $8005)
      else crc := Word(crc shl 1);
  end;
  Result := crc;
end;

{ ============================ TFlacBitReader ========================= }

procedure TFlacBitReader.Init(AData: PByte; ALen: Integer; AStartByte: Integer);
begin
  FData := AData;
  FLen := ALen;
  if AStartByte < 0 then AStartByte := 0;
  FBytePos := AStartByte;
  FBitPos := 0;
  FOverrun := False;
end;

function TFlacBitReader.ReadBit: Cardinal;
begin
  if FBytePos >= FLen then
  begin
    FOverrun := True;
    Result := 0;
    Exit;
  end;
  Result := (Cardinal(FData[FBytePos]) shr (7 - FBitPos)) and 1;
  Inc(FBitPos);
  if FBitPos = 8 then
  begin
    FBitPos := 0;
    Inc(FBytePos);
  end;
end;

function TFlacBitReader.ReadBits(ACount: Integer): Cardinal;
var
  i: Integer;
begin
  Result := 0;
  if ACount <= 0 then Exit;
  if ACount > 32 then ACount := 32;
  for i := 1 to ACount do
    Result := (Result shl 1) or ReadBit;
end;

function TFlacBitReader.ReadBitsBig(ACount: Integer): UInt64;
var
  i: Integer;
begin
  Result := 0;
  if ACount <= 0 then Exit;
  if ACount > 64 then ACount := 64;
  for i := 1 to ACount do
    Result := (Result shl 1) or ReadBit;
end;

function TFlacBitReader.ReadSigned(ACount: Integer): Int64;
var
  raw: UInt64;
  signBit: UInt64;
begin
  if ACount <= 0 then Exit(0);
  raw := ReadBitsBig(ACount);
  if ACount >= 64 then Exit(Int64(raw));
  signBit := UInt64(1) shl (ACount - 1);
  if (raw and signBit) <> 0 then
    Result := Int64(raw) - Int64(UInt64(1) shl ACount)
  else
    Result := Int64(raw);
end;

function TFlacBitReader.ReadUnary: Cardinal;
const
  MAX_UNARY = 1 shl 24;      // guard against runaway reads on corrupt data
begin
  Result := 0;
  while (ReadBit = 0) do
  begin
    if FOverrun then Exit;
    Inc(Result);
    if Result >= MAX_UNARY then
    begin
      FOverrun := True;
      Exit;
    end;
  end;
end;

procedure TFlacBitReader.SkipBits(ACount: Integer);
var
  total: Int64;
begin
  if ACount <= 0 then Exit;
  total := Int64(FBitPos) + ACount;
  Inc(FBytePos, total shr 3);
  FBitPos := total and 7;
  if FBytePos >= FLen then
  begin
    FOverrun := True;
    FBytePos := FLen;
    FBitPos := 0;
  end;
end;

procedure TFlacBitReader.AlignToByte;
begin
  if FBitPos <> 0 then SkipBits(8 - FBitPos);
end;

function TFlacBitReader.BitPosition: Int64;
begin
  Result := Int64(FBytePos) * 8 + FBitPos;
end;

function TFlacBitReader.BitsLeft: Int64;
begin
  Result := Int64(FLen) * 8 - BitPosition;
  if Result < 0 then Result := 0;
end;

{ ============================ sniffing ================================ }

function LeadingId3v2Size(const AData; ALength: Integer): Int64;
var
  p: PByte;
  body: Integer;
begin
  Result := 0;
  if ALength < 10 then Exit;
  p := PByte(@AData);
  if (p[0] <> Ord('I')) or (p[1] <> Ord('D')) or (p[2] <> Ord('3')) then Exit;
  if (p[3] = $FF) or (p[4] = $FF) then Exit;
  if (p[6] >= $80) or (p[7] >= $80) or (p[8] >= $80) or (p[9] >= $80) then Exit;
  body := (Integer(p[6]) shl 21) or (Integer(p[7]) shl 14) or
          (Integer(p[8]) shl 7) or Integer(p[9]);
  Result := 10 + body;
  if (p[5] and $10) <> 0 then Inc(Result, 10);   // footer present
end;

function DataLooksLikeFlac(const AData; ALength: Integer): Boolean;
var
  p: PByte;
  ofs: Int64;
begin
  Result := False;
  if ALength < 4 then Exit;
  p := PByte(@AData);
  if (p[0] = FLAC_MAGIC[0]) and (p[1] = FLAC_MAGIC[1]) and
     (p[2] = FLAC_MAGIC[2]) and (p[3] = FLAC_MAGIC[3]) then
    Exit(True);

  { tolerate a leading ID3v2 tag some taggers mistakenly prepend to .flac }
  ofs := LeadingId3v2Size(AData, ALength);
  if (ofs > 0) and (ofs + 4 <= ALength) then
  begin
    Inc(p, ofs);
    Result := (p[0] = FLAC_MAGIC[0]) and (p[1] = FLAC_MAGIC[1]) and
              (p[2] = FLAC_MAGIC[2]) and (p[3] = FLAC_MAGIC[3]);
  end;
end;

function FileLooksLikeFlac(const AFileName: string): Boolean;
var
  fs: TFileStream;
  buf: TBytes;
  n: Integer;
begin
  Result := False;
  if not FileExists(AFileName) then Exit;
  try
    fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(buf, Min(4096, fs.Size));
      if Length(buf) = 0 then Exit;
      n := fs.Read(buf[0], Length(buf));
      Result := DataLooksLikeFlac(buf[0], n);
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

{ ============================ TFlacStreamInfo ========================= }

function TFlacStreamInfo.DurationSeconds: Double;
begin
  if SampleRate > 0 then Result := TotalSamples / SampleRate else Result := 0;
end;

function TFlacStreamInfo.Describe: string;
begin
  if not Present then Exit('<no STREAMINFO>');
  Result := Format('%d Hz, %d ch, %d-bit, %d samples, %.3f s',
    [SampleRate, Channels, BitsPerSample, TotalSamples, DurationSeconds]);
end;

{ ============================ TFlacFrameHeader ========================= }

function ChannelAssignName(A: TFlacChannelAssign): string;
begin
  case A of
    fcaIndependent: Result := 'independent';
    fcaLeftSide:    Result := 'left/side';
    fcaRightSide:   Result := 'right/side';
    fcaMidSide:     Result := 'mid/side';
  else
    Result := '?';
  end;
end;

function TFlacFrameHeader.Describe: string;
var
  crcNote: string;
begin
  if not Parsed then Exit('<unparsed>');
  crcNote := '';
  if not HeaderCrcOk then crcNote := ' [CRC8 MISMATCH]';
  Result := Format('%d Hz, %d ch (%s), %d-bit, block=%d, #%d%s',
    [SampleRate, Channels, ChannelAssignName(ChannelAssign), BitsPerSample,
     BlockSize, FrameOrSampleNumber, crcNote]);
end;

{ ============================ metadata ================================ }

function ReadMetaBlockHeaderAt(const AData: TBytes; AOffset: Int64;
  out AHdr: TFlacMetaBlockHeader): Boolean;
var
  b0: Byte;
begin
  FillChar(AHdr, SizeOf(AHdr), 0);
  Result := False;
  if (AOffset < 0) or (AOffset + 4 > Length(AData)) then Exit;
  b0 := AData[AOffset];
  AHdr.IsLast := (b0 and $80) <> 0;
  AHdr.BlockType := b0 and $7F;
  AHdr.Length := (Integer(AData[AOffset + 1]) shl 16) or
                 (Integer(AData[AOffset + 2]) shl 8) or Integer(AData[AOffset + 3]);
  Result := True;
end;

function ParseStreamInfoBlock(const AData: TBytes; AOffset: Int64;
  out AInfo: TFlacStreamInfo): Boolean;
var
  br: TFlacBitReader;
  i: Integer;
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  Result := False;
  if AOffset + 34 > Length(AData) then Exit;
  br.Init(@AData[0], Length(AData), Integer(AOffset));
  AInfo.MinBlockSize := br.ReadBits(16);
  AInfo.MaxBlockSize := br.ReadBits(16);
  AInfo.MinFrameSize := Integer(br.ReadBits(24));
  AInfo.MaxFrameSize := Integer(br.ReadBits(24));
  AInfo.SampleRate := Integer(br.ReadBits(20));
  AInfo.Channels := Integer(br.ReadBits(3)) + 1;
  AInfo.BitsPerSample := Integer(br.ReadBits(5)) + 1;
  AInfo.TotalSamples := Int64(br.ReadBitsBig(36));
  for i := 0 to 15 do
    AInfo.MD5[i] := Byte(br.ReadBits(8));
  if (AInfo.SampleRate <= 0) or (AInfo.Channels <= 0) or (AInfo.BitsPerSample <= 0) then
    Exit;
  AInfo.Present := True;
  Result := True;
end;

function ScanFlacMetadata(const AData: TBytes; out AInfo: TFlacStreamInfo;
  out AAudioStart: Int64): Boolean;
var
  len, magicAt: Int64;
  mh: TFlacMetaBlockHeader;
  pos: Int64;
  first: Boolean;
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  AAudioStart := 0;
  Result := False;
  len := Length(AData);
  if (len < 8) or (len > FLAC_MAX_FILE_BYTES) then Exit;

  magicAt := -1;
  if (AData[0] = FLAC_MAGIC[0]) and (AData[1] = FLAC_MAGIC[1]) and
     (AData[2] = FLAC_MAGIC[2]) and (AData[3] = FLAC_MAGIC[3]) then
    magicAt := 0
  else
  begin
    pos := LeadingId3v2Size(AData[0], Integer(Min(len, MaxInt)));
    if (pos > 0) and (pos + 4 <= len) and
       (AData[pos] = FLAC_MAGIC[0]) and (AData[pos + 1] = FLAC_MAGIC[1]) and
       (AData[pos + 2] = FLAC_MAGIC[2]) and (AData[pos + 3] = FLAC_MAGIC[3]) then
      magicAt := pos;
  end;
  if magicAt < 0 then Exit;

  pos := magicAt + 4;
  first := True;
  while pos + 4 <= len do
  begin
    if not ReadMetaBlockHeaderAt(AData, pos, mh) then Exit;
    Inc(pos, 4);
    if first then
    begin
      if mh.BlockType <> FLAC_BLOCK_STREAMINFO then Exit;   // mandatory first block
      if not ParseStreamInfoBlock(AData, pos, AInfo) then Exit;
      first := False;
    end;
    if pos + mh.Length > len then Exit;
    Inc(pos, mh.Length);
    if mh.IsLast then Break;
  end;
  if not AInfo.Present then Exit;

  AAudioStart := pos;
  Result := True;
end;

{ ============================ frame header ============================ }

function ParseFlacFrameHeader(const AData: TBytes; var ABr: TFlacBitReader;
  const AStreamInfo: TFlacStreamInfo; out AHdr: TFlacFrameHeader): Boolean;
var
  startByte: Integer;
  sync, blockingBit, bsCode, srCode, chCode, bpsCode, reserved2: Cardinal;
  b0: Byte;
  utf8Val: UInt64;
  crc8Stored, crc8Calc: Byte;
  crcEndByte: Integer;
begin
  FillChar(AHdr, SizeOf(AHdr), 0);
  Result := False;
  startByte := ABr.BytePos;
  AHdr.HeaderStartByte := startByte;

  sync := ABr.ReadBits(14);
  if sync <> FLAC_SYNC_CODE then Exit;
  if ABr.ReadBits(1) <> 0 then Exit;                { mandatory reserved bit }
  blockingBit := ABr.ReadBits(1);
  AHdr.VariableBlocking := blockingBit = 1;

  bsCode := ABr.ReadBits(4);
  srCode := ABr.ReadBits(4);
  chCode := ABr.ReadBits(4);
  bpsCode := ABr.ReadBits(3);
  reserved2 := ABr.ReadBits(1);
  if reserved2 <> 0 then Exit;
  if ABr.Overrun then Exit;

  { frame/sample number: UTF-8-style variable length code, byte-aligned here }
  b0 := Byte(ABr.ReadBits(8));
  if (b0 and $80) = 0 then
    utf8Val := b0
  else if (b0 and $E0) = $C0 then
  begin
    utf8Val := b0 and $1F;
    if (ABr.ReadBits(8) and $C0) <> $80 then Exit;
  end
  else
  begin
    { general case: count leading 1 bits in b0 to find the byte count }
    var leadOnes: Integer := 0;
    var mask: Byte := $80;
    while (b0 and mask) <> 0 do
    begin
      Inc(leadOnes);
      mask := mask shr 1;
    end;
    if (leadOnes < 2) or (leadOnes > 7) then Exit;    // malformed lead byte
    if leadOnes = 7 then
      utf8Val := 0                                    // 11111110 lead carries no data bits
    else
      utf8Val := b0 and ((1 shl (7 - leadOnes)) - 1);
    var i: Integer;
    for i := 1 to leadOnes - 1 do
    begin
      var cont: Byte := Byte(ABr.ReadBits(8));
      if (cont and $C0) <> $80 then Exit;             // bad continuation byte
      utf8Val := (utf8Val shl 6) or (cont and $3F);
    end;
  end;
  if ABr.Overrun then Exit;
  AHdr.FrameOrSampleNumber := utf8Val;

  { block size }
  case bsCode of
    0: Exit;                                          // reserved
    1: AHdr.BlockSize := 192;
    2..5: AHdr.BlockSize := 576 shl (Integer(bsCode) - 2);
    6: AHdr.BlockSize := Integer(ABr.ReadBits(8)) + 1;
    7: AHdr.BlockSize := Integer(ABr.ReadBits(16)) + 1;
  else
    AHdr.BlockSize := 256 shl (Integer(bsCode) - 8);  // 8..15
  end;
  if AHdr.BlockSize <= 0 then Exit;

  { sample rate }
  case srCode of
    0: AHdr.SampleRate := AStreamInfo.SampleRate;
    1: AHdr.SampleRate := 88200;
    2: AHdr.SampleRate := 176400;
    3: AHdr.SampleRate := 192000;
    4: AHdr.SampleRate := 8000;
    5: AHdr.SampleRate := 16000;
    6: AHdr.SampleRate := 22050;
    7: AHdr.SampleRate := 24000;
    8: AHdr.SampleRate := 32000;
    9: AHdr.SampleRate := 44100;
    10: AHdr.SampleRate := 48000;
    11: AHdr.SampleRate := 96000;
    12: AHdr.SampleRate := Integer(ABr.ReadBits(8)) * 1000;
    13: AHdr.SampleRate := Integer(ABr.ReadBits(16));
    14: AHdr.SampleRate := Integer(ABr.ReadBits(16)) * 10;
  else
    Exit;                                             // 15 == invalid
  end;
  if AHdr.SampleRate <= 0 then Exit;

  { channel assignment }
  AHdr.RawChannelCode := Integer(chCode);
  if chCode <= 7 then
  begin
    AHdr.ChannelAssign := fcaIndependent;
    AHdr.Channels := Integer(chCode) + 1;
  end
  else if chCode = 8 then
  begin
    AHdr.ChannelAssign := fcaLeftSide;
    AHdr.Channels := 2;
  end
  else if chCode = 9 then
  begin
    AHdr.ChannelAssign := fcaRightSide;
    AHdr.Channels := 2;
  end
  else if chCode = 10 then
  begin
    AHdr.ChannelAssign := fcaMidSide;
    AHdr.Channels := 2;
  end
  else
    Exit;                                             // 11..15 reserved

  { bits per sample }
  case bpsCode of
    0: AHdr.BitsPerSample := AStreamInfo.BitsPerSample;
    1: AHdr.BitsPerSample := 8;
    2: AHdr.BitsPerSample := 12;
    4: AHdr.BitsPerSample := 16;
    5: AHdr.BitsPerSample := 20;
    6: AHdr.BitsPerSample := 24;
  else
    Exit;                                             // 3, 7 reserved
  end;
  if AHdr.BitsPerSample <= 0 then Exit;

  if ABr.Overrun then Exit;

  { header CRC-8, byte-aligned }
  crc8Stored := Byte(ABr.ReadBits(8));
  if ABr.Overrun then Exit;
  crcEndByte := ABr.BytePos - 1;    // byte holding crc8Stored
  crc8Calc := Flac_CRC8(AData, startByte, crcEndByte - startByte);
  AHdr.HeaderCrcOk := crc8Calc = crc8Stored;

  AHdr.Parsed := True;
  Result := True;
end;

end.
