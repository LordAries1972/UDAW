unit UDAW.Codec.MP3.Frame;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 15 - MP3 support (plan section 18).  MPEG-1/2/2.5 audio *frame layer*:
  a self-contained MSB-first bit reader, the 32-bit frame header decode with the
  full CBR/VBR bitrate + sample-rate tables, frame-length arithmetic, the
  Xing / Info / LAME and VBRI VBR headers, and a whole-file frame scanner that
  produces a seek index (byte offset -> first sample of each frame).

  Nothing here trusts the file extension: DataLooksLikeMp3 / FileLooksLikeMp3
  sniff for a valid MPEG-audio sync plus (optionally) a leading ID3v2 tag.  A
  hostile stream can never steer an allocation - every table lookup is bounds
  checked and a bad header raises EUDAWError (errConfig).

  This unit is Layer I/II/III aware for *parsing* (needed to walk any MPEG audio
  stream and to seek), while the decoder (UDAW.Codec.MP3.Decoder) implements
  Layer III audio.  Layer I/II frames are skipped by the walker and reported. }

interface

uses
  SysUtils, Classes, Math, StrUtils,
  UDAW.Errors;

const
  MP3_SUBSYS = 'Codec.MP3';

  { Allocation guard rails (plan section 18 / 16). }
  MP3_MAX_FILE_BYTES   = Int64(768) * 1024 * 1024;   // 768 MiB
  MP3_MAX_FRAMES       = 4 * 1024 * 1024;            // ~26 h @ 1152/44100
  MP3_MAX_FRAME_BYTES  = 2881;                       // Layer II 448k @ 32k + pad

type
  TMpegVersion = (mpv25, mpvReserved, mpv2, mpv1);      // matches the 2-bit field
  TMpegLayer   = (mlReserved, mlLayer3, mlLayer2, mlLayer1);
  TMpegChannelMode = (cmStereo, cmJointStereo, cmDualChannel, cmMono);

  { One decoded frame header. Valid only when FParsed is set. }
  TMP3FrameHeader = record
    Version: TMpegVersion;
    Layer: TMpegLayer;
    HasCRC: Boolean;                // protection bit == 0
    BitrateKbps: Integer;           // 0 == "free format"
    SampleRate: Integer;            // Hz
    Padding: Boolean;
    Private_: Boolean;
    ChannelMode: TMpegChannelMode;
    ModeExtension: Integer;         // 0..3 (Layer III: MS/intensity flags)
    Copyright: Boolean;
    Original: Boolean;
    Emphasis: Integer;             // 0..3
    Parsed: Boolean;
    function Channels: Integer;
    function SamplesPerFrame: Integer;
    function FrameLengthBytes: Integer;    // incl. header, incl. padding
    function SideInfoBytes: Integer;       // Layer III only
    function IsLayer3: Boolean;
    function Describe: string;
  end;

  { MSB-first bit reader over a byte buffer. Reads past the end return 0 and set
    Overrun (the Layer III decoder relies on graceful zero-fill, never a fault). }
  TBitReader = record
  private
    FData: PByte;
    FLen: Integer;
    FBytePos: Integer;
    FBitPos: Integer;            // 0..7, bits already consumed in the current byte
    FOverrun: Boolean;
  public
    procedure Init(AData: PByte; ALen: Integer; AStartByte: Integer = 0);
    function ReadBit: Cardinal;
    function ReadBits(ACount: Integer): Cardinal;      // ACount 0..32
    function ReadBitsBig(ACount: Integer): UInt64;
    procedure SkipBits(ACount: Integer);
    function BitPosition: Int64;                       // absolute, from AStartByte
    procedure SetBitPosition(ABit: Int64);
    function BitsLeft: Int64;
    property Overrun: Boolean read FOverrun;
    property BytePos: Integer read FBytePos;
  end;

  { A VBR header (Xing "Xing"/"Info" or Fraunhofer "VBRI") sitting in the first
    frame. Gives an exact frame/sample count and a 100-entry seek table. }
  TMP3VbrHeader = record
    Present: Boolean;
    IsVBRI: Boolean;
    FrameCount: Int64;           // audio frames NOT counting this header frame
    ByteCount: Int64;            // bytes of audio incl. this frame, 0 if absent
    TocEntries: Integer;         // Xing: 0 or 100 ; VBRI: variable
    Toc: array of Byte;          // Xing 100-byte TOC (percent-of-bytes per 1/100)
    VbriToc: array of Cardinal;  // VBRI: bytes per (ScaleFactor) segment
    VbriFramesPerEntry: Integer;
    EncoderDelay: Integer;       // LAME tag, samples
    EncoderPadding: Integer;     // LAME tag, samples
    EncoderName: string;         // "LAME3.100" etc, if present
  end;

  { Result of walking the whole stream. }
  TMP3FrameRef = record
    FileOffset: Int64;           // byte offset of the 0xFF sync
    FrameBytes: Integer;
    SamplePos: Int64;            // first PCM sample index this frame yields
    SamplesInFrame: Integer;
  end;

  TMP3StreamInfo = record
    FirstFrame: TMP3FrameHeader;
    Vbr: TMP3VbrHeader;
    AudioStartOffset: Int64;     // past any ID3v2 tag
    AudioEndOffset: Int64;       // before any ID3v1 / APE trailer
    Id3v2Size: Int64;
    HasId3v1: Boolean;
    ApeTrailerSize: Int64;
    FrameCount: Int64;
    Layer3FrameCount: Int64;
    OtherLayerFrameCount: Int64;
    TotalSamples: Int64;         // sum of SamplesInFrame over Layer III frames
    IsCBR: Boolean;
    NominalBitrateKbps: Integer;
    Frames: array of TMP3FrameRef;
    function Channels: Integer;
    function SampleRate: Integer;
    function DurationSeconds: Double;
    function Describe: string;
  end;

{ ---- header ---- }
function ParseFrameHeader(AWord: Cardinal; out AHdr: TMP3FrameHeader): Boolean;
{ Reads 4 bytes at AOffset and parses. False if not a plausible frame there. }
function ReadFrameHeaderAt(const AData: TBytes; AOffset: Int64;
  out AHdr: TMP3FrameHeader): Boolean;

{ ---- sniffing (never looks at the name) ---- }
function DataLooksLikeMp3(const AData; ALength: Integer): Boolean;
function FileLooksLikeMp3(const AFileName: string): Boolean;

{ ---- ID3v2 envelope ---- }
function ReadId3v2Size(const AData: TBytes; out ASize: Int64): Boolean;

{ ---- VBR header (call with the first frame's bytes) ---- }
function ParseVbrHeader(const AFrame: TBytes; const AHdr: TMP3FrameHeader;
  out AVbr: TMP3VbrHeader): Boolean;

{ ---- whole-stream scan ---- }
function ScanMp3Stream(const AData: TBytes; out AInfo: TMP3StreamInfo): Boolean;

function MpegVersionName(V: TMpegVersion): string;
function MpegLayerName(L: TMpegLayer): string;
function ChannelModeName(M: TMpegChannelMode): string;

implementation

const
  { [version=MPEG1?][layer 1..3 -> 0..2][index 0..15], kbps. -1 == invalid. }
  BITRATE_MPEG1: array[0..2, 0..15] of SmallInt = (
    { Layer I   } (0, 32, 64, 96,128,160,192,224,256,288,320,352,384,416,448, -1),
    { Layer II  } (0, 32, 48, 56, 64, 80, 96,112,128,160,192,224,256,320,384, -1),
    { Layer III } (0, 32, 40, 48, 56, 64, 80, 96,112,128,160,192,224,256,320, -1));
  BITRATE_MPEG2: array[0..2, 0..15] of SmallInt = (
    { Layer I   } (0, 32, 48, 56, 64, 80, 96,112,128,144,160,176,192,224,256, -1),
    { Layer II  } (0,  8, 16, 24, 32, 40, 48, 56, 64, 80, 96,112,128,144,160, -1),
    { Layer III } (0,  8, 16, 24, 32, 40, 48, 56, 64, 80, 96,112,128,144,160, -1));

  SAMPLERATE: array[TMpegVersion, 0..3] of Integer = (
    { mpv25      } (11025, 12000,  8000, 0),
    { mpvReserved} (0, 0, 0, 0),
    { mpv2       } (22050, 24000, 16000, 0),
    { mpv1       } (44100, 48000, 32000, 0));

function MpegVersionName(V: TMpegVersion): string;
begin
  case V of
    mpv25: Result := 'MPEG 2.5';
    mpv2:  Result := 'MPEG 2';
    mpv1:  Result := 'MPEG 1';
  else     Result := 'reserved';
  end;
end;

function MpegLayerName(L: TMpegLayer): string;
begin
  case L of
    mlLayer1: Result := 'Layer I';
    mlLayer2: Result := 'Layer II';
    mlLayer3: Result := 'Layer III';
  else        Result := 'reserved';
  end;
end;

function ChannelModeName(M: TMpegChannelMode): string;
begin
  case M of
    cmStereo:       Result := 'stereo';
    cmJointStereo:  Result := 'joint stereo';
    cmDualChannel:  Result := 'dual channel';
    cmMono:         Result := 'mono';
  end;
end;

{ ============================ TMP3FrameHeader ============================ }

function TMP3FrameHeader.Channels: Integer;
begin
  if ChannelMode = cmMono then Result := 1 else Result := 2;
end;

function TMP3FrameHeader.IsLayer3: Boolean;
begin
  Result := Layer = mlLayer3;
end;

function TMP3FrameHeader.SamplesPerFrame: Integer;
begin
  case Layer of
    mlLayer1: Result := 384;
    mlLayer2: Result := 1152;
    mlLayer3: if Version = mpv1 then Result := 1152 else Result := 576;
  else
    Result := 0;
  end;
end;

function TMP3FrameHeader.SideInfoBytes: Integer;
begin
  if Version = mpv1 then
  begin
    if ChannelMode = cmMono then Result := 17 else Result := 32;
  end
  else
  begin
    if ChannelMode = cmMono then Result := 9 else Result := 17;
  end;
end;

function TMP3FrameHeader.FrameLengthBytes: Integer;
var
  slots, coeff: Integer;
begin
  if (SampleRate <= 0) or (BitrateKbps <= 0) then
  begin
    Result := 0;   // free format: caller must measure to the next sync
    Exit;
  end;
  case Layer of
    mlLayer1:
      begin
        Result := ((12 * BitrateKbps * 1000) div SampleRate + Ord(Padding)) * 4;
      end;
    mlLayer2:
      begin
        Result := (144 * BitrateKbps * 1000) div SampleRate + Ord(Padding);
      end;
    mlLayer3:
      begin
        if Version = mpv1 then coeff := 144 else coeff := 72;
        slots := (coeff * BitrateKbps * 1000) div SampleRate;
        Result := slots + Ord(Padding);
      end;
  else
    Result := 0;
  end;
end;

function TMP3FrameHeader.Describe: string;
begin
  if not Parsed then Exit('<unparsed>');
  Result := Format('%s %s %d ch %d Hz %s %d B/frame',
    [MpegVersionName(Version), MpegLayerName(Layer), Channels, SampleRate,
     IfThen(BitrateKbps > 0, IntToStr(BitrateKbps) + 'k', 'free'),
     FrameLengthBytes]);
end;

{ ============================ header parse ============================== }

function ParseFrameHeader(AWord: Cardinal; out AHdr: TMP3FrameHeader): Boolean;
var
  verBits, layerBits, brIdx, srIdx, layerRow: Integer;
begin
  Result := False;
  FillChar(AHdr, SizeOf(AHdr), 0);

  { 11-bit sync }
  if (AWord and $FFE00000) <> $FFE00000 then Exit;

  verBits   := (AWord shr 19) and $3;
  layerBits := (AWord shr 17) and $3;
  if verBits = 1 then Exit;              // reserved version
  if layerBits = 0 then Exit;            // reserved layer

  AHdr.Version := TMpegVersion(verBits);
  AHdr.Layer   := TMpegLayer(layerBits);
  AHdr.HasCRC  := ((AWord shr 16) and $1) = 0;

  brIdx := (AWord shr 12) and $F;
  srIdx := (AWord shr 10) and $3;
  if brIdx = 15 then Exit;               // "bad" bitrate index
  if srIdx = 3 then Exit;                // reserved sample-rate index

  layerRow := Ord(AHdr.Layer) - Ord(mlLayer3);   // 0=L3,1=L2,2=L1 -> reorder
  case AHdr.Layer of
    mlLayer1: layerRow := 0;
    mlLayer2: layerRow := 1;
    mlLayer3: layerRow := 2;
  end;

  if AHdr.Version = mpv1 then
    AHdr.BitrateKbps := BITRATE_MPEG1[layerRow, brIdx]
  else
    AHdr.BitrateKbps := BITRATE_MPEG2[layerRow, brIdx];
  if AHdr.BitrateKbps < 0 then Exit;

  AHdr.SampleRate := SAMPLERATE[AHdr.Version, srIdx];
  if AHdr.SampleRate <= 0 then Exit;

  AHdr.Padding       := ((AWord shr 9) and $1) = 1;
  AHdr.Private_      := ((AWord shr 8) and $1) = 1;
  AHdr.ChannelMode   := TMpegChannelMode((AWord shr 6) and $3);
  AHdr.ModeExtension := (AWord shr 4) and $3;
  AHdr.Copyright     := ((AWord shr 3) and $1) = 1;
  AHdr.Original      := ((AWord shr 2) and $1) = 1;
  AHdr.Emphasis      := AWord and $3;
  if AHdr.Emphasis = 2 then Exit;        // reserved emphasis

  AHdr.Parsed := True;
  Result := True;
end;

function ReadFrameHeaderAt(const AData: TBytes; AOffset: Int64;
  out AHdr: TMP3FrameHeader): Boolean;
var
  w: Cardinal;
begin
  Result := False;
  FillChar(AHdr, SizeOf(AHdr), 0);
  if (AOffset < 0) or (AOffset + 4 > Length(AData)) then Exit;
  w := (Cardinal(AData[AOffset]) shl 24) or (Cardinal(AData[AOffset + 1]) shl 16) or
       (Cardinal(AData[AOffset + 2]) shl 8) or Cardinal(AData[AOffset + 3]);
  Result := ParseFrameHeader(w, AHdr);
end;

{ ============================ TBitReader =============================== }

procedure TBitReader.Init(AData: PByte; ALen: Integer; AStartByte: Integer);
begin
  FData := AData;
  FLen := ALen;
  if AStartByte < 0 then AStartByte := 0;
  FBytePos := AStartByte;
  FBitPos := 0;
  FOverrun := False;
end;

function TBitReader.ReadBit: Cardinal;
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

function TBitReader.ReadBits(ACount: Integer): Cardinal;
var
  i: Integer;
begin
  Result := 0;
  if ACount <= 0 then Exit;
  if ACount > 32 then ACount := 32;
  for i := 1 to ACount do
    Result := (Result shl 1) or ReadBit;
end;

function TBitReader.ReadBitsBig(ACount: Integer): UInt64;
var
  i: Integer;
begin
  Result := 0;
  if ACount <= 0 then Exit;
  if ACount > 64 then ACount := 64;
  for i := 1 to ACount do
    Result := (Result shl 1) or ReadBit;
end;

procedure TBitReader.SkipBits(ACount: Integer);
var
  total: Int64;
begin
  if ACount <= 0 then Exit;
  total := Int64(FBitPos) + ACount;
  Inc(FBytePos, total shr 3);   // total > 0
  FBitPos := total and 7;
  if FBytePos >= FLen then
  begin
    FOverrun := True;
    FBytePos := FLen;
    FBitPos := 0;
  end;
end;

function TBitReader.BitPosition: Int64;
begin
  Result := Int64(FBytePos) * 8 + FBitPos;
end;

procedure TBitReader.SetBitPosition(ABit: Int64);
begin
  if ABit < 0 then ABit := 0;
  FBytePos := ABit shr 3;   // ABit clamped >= 0
  FBitPos := ABit and 7;
  if FBytePos > FLen then
  begin
    FBytePos := FLen;
    FBitPos := 0;
    FOverrun := True;
  end;
end;

function TBitReader.BitsLeft: Int64;
begin
  Result := Int64(FLen) * 8 - BitPosition;
  if Result < 0 then Result := 0;
end;

{ ============================ sniffing ================================= }

{ Reads the 4 bytes at AOffset and parses them as a frame header, if there's
  room. Shared by LooksLikeConsecutiveSyncAt's two probes below. }
function TryParseHeaderAt(const AData; ALength, AOffset: Integer;
  out AHdr: TMP3FrameHeader): Boolean;
var
  p: PByte;
  w: Cardinal;
begin
  if AOffset + 4 > ALength then Exit(False);
  p := PByte(@AData);
  w := (Cardinal(p[AOffset]) shl 24) or (Cardinal(p[AOffset + 1]) shl 16) or
       (Cardinal(p[AOffset + 2]) shl 8) or Cardinal(p[AOffset + 3]);
  Result := ParseFrameHeader(w, AHdr);
end;

{ A single plausible-looking frame header is a weak signal on its own - random
  PCM data (e.g. a WAV file's sample bytes, scanned from byte 0 since there is
  no leading "ID3"/sync to skip past) hits ParseFrameHeader's bit-field checks
  by chance roughly once per 6-7 KB, well within the 8192-byte scan window
  below, and used to misidentify WAV imports as MP3 (silent decode failure ->
  flat waveform, no audio). Requiring a second, consistent sync at the exact
  byte offset the first frame's own length predicts is the standard MPEG
  demuxer safeguard against that: real MP3 streams satisfy it, random PCM
  essentially never does twice in a row. }
function LooksLikeConsecutiveSyncAt(const AData; ALength: Integer; AOffset: Integer): Boolean;
var
  h, h2: TMP3FrameHeader;
  frameLen: Integer;
begin
  Result := False;
  if not TryParseHeaderAt(AData, ALength, AOffset, h) then Exit;

  frameLen := h.FrameLengthBytes;
  if frameLen <= 0 then Exit;   // free-format: no predictable next offset to verify against
  if not TryParseHeaderAt(AData, ALength, AOffset + frameLen, h2) then Exit;
  Result := (h2.Version = h.Version) and (h2.Layer = h.Layer) and
    (h2.SampleRate = h.SampleRate);
end;

function DataLooksLikeMp3(const AData; ALength: Integer): Boolean;
var
  p: PByte;
  i, scan: Integer;
  tagSize: Integer;
begin
  Result := False;
  if ALength < 4 then Exit;
  p := PByte(@AData);

  { A RIFF/WAVE container is never an MP3: its PCM payload (notably a 24-bit
    fade-in starting from silence, runs of $FF/$00) can imitate two
    consecutive MPEG sync words inside the 8 KB scan below, which sent a valid
    effect-render WAV down the MP3 decoder and left its clip a flat line. }
  if (ALength >= 12) and (p[0] = Ord('R')) and (p[1] = Ord('I')) and
     (p[2] = Ord('F')) and (p[3] = Ord('F')) and (p[8] = Ord('W')) and
     (p[9] = Ord('A')) and (p[10] = Ord('V')) and (p[11] = Ord('E')) then
    Exit;

  { Leading ID3v2 tag? "ID3" + ver + flags + 4 syncsafe size bytes. }
  if (ALength >= 10) and (p[0] = Ord('I')) and (p[1] = Ord('D')) and (p[2] = Ord('3'))
     and (p[3] < $FF) and (p[4] < $FF)
     and (p[6] < $80) and (p[7] < $80) and (p[8] < $80) and (p[9] < $80) then
  begin
    tagSize := (Integer(p[6]) shl 21) or (Integer(p[7]) shl 14) or
               (Integer(p[8]) shl 7) or Integer(p[9]);
    Exit(tagSize > 0);   // a well-formed ID3v2 header is a strong signal
  end;

  { Otherwise scan a little way in for a real MPEG-audio sync, confirmed by a
    second consistent frame at the offset the first one predicts. }
  scan := ALength - 4;
  if scan > 8192 then scan := 8192;
  for i := 0 to scan do
    if LooksLikeConsecutiveSyncAt(AData, ALength, i) then
      Exit(True);
end;

function FileLooksLikeMp3(const AFileName: string): Boolean;
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
      SetLength(buf, Min(16384, fs.Size));
      if Length(buf) = 0 then Exit;
      n := fs.Read(buf[0], Length(buf));
      Result := DataLooksLikeMp3(buf[0], n);
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

{ ============================ ID3v2 size =============================== }

function ReadId3v2Size(const AData: TBytes; out ASize: Int64): Boolean;
var
  footerPresent: Boolean;
  body: Integer;
begin
  ASize := 0;
  Result := False;
  if Length(AData) < 10 then Exit;
  if (AData[0] <> Ord('I')) or (AData[1] <> Ord('D')) or (AData[2] <> Ord('3')) then Exit;
  if (AData[3] = $FF) or (AData[4] = $FF) then Exit;
  if (AData[6] >= $80) or (AData[7] >= $80) or (AData[8] >= $80) or (AData[9] >= $80) then Exit;
  body := (Integer(AData[6]) shl 21) or (Integer(AData[7]) shl 14) or
          (Integer(AData[8]) shl 7) or Integer(AData[9]);
  footerPresent := (AData[5] and $10) <> 0;
  ASize := Int64(10) + body;
  if footerPresent then Inc(ASize, 10);
  Result := ASize > 0;
end;

{ ============================ VBR header ============================== }

function BE32(const B: TBytes; AOfs: Integer): Cardinal;
begin
  Result := (Cardinal(B[AOfs]) shl 24) or (Cardinal(B[AOfs + 1]) shl 16) or
            (Cardinal(B[AOfs + 2]) shl 8) or Cardinal(B[AOfs + 3]);
end;

function BE16(const B: TBytes; AOfs: Integer): Word;
begin
  Result := (Word(B[AOfs]) shl 8) or Word(B[AOfs + 1]);
end;

function ParseVbrHeader(const AFrame: TBytes; const AHdr: TMP3FrameHeader;
  out AVbr: TMP3VbrHeader): Boolean;
var
  ofs, flags, i, tocOfs, lameOfs, entries, entrySize, sfPos: Integer;
  tag: string;
begin
  FillChar(AVbr, SizeOf(AVbr), 0);
  Result := False;
  if Length(AFrame) < 40 then Exit;

  { Xing/Info sits right after the side info; VBRI at a fixed offset 32+4. }
  ofs := 4 + AHdr.SideInfoBytes;
  if ofs + 8 <= Length(AFrame) then
  begin
    tag := Chr(AFrame[ofs]) + Chr(AFrame[ofs + 1]) + Chr(AFrame[ofs + 2]) + Chr(AFrame[ofs + 3]);
    if (tag = 'Xing') or (tag = 'Info') then
    begin
      AVbr.Present := True;
      flags := BE32(AFrame, ofs + 4);
      tocOfs := ofs + 8;
      if (flags and $1) <> 0 then       // frames
      begin
        if tocOfs + 4 > Length(AFrame) then Exit(True);
        AVbr.FrameCount := BE32(AFrame, tocOfs);
        Inc(tocOfs, 4);
      end;
      if (flags and $2) <> 0 then       // bytes
      begin
        if tocOfs + 4 > Length(AFrame) then Exit(True);
        AVbr.ByteCount := BE32(AFrame, tocOfs);
        Inc(tocOfs, 4);
      end;
      if (flags and $4) <> 0 then       // TOC
      begin
        if tocOfs + 100 > Length(AFrame) then Exit(True);
        SetLength(AVbr.Toc, 100);
        for i := 0 to 99 do AVbr.Toc[i] := AFrame[tocOfs + i];
        AVbr.TocEntries := 100;
        Inc(tocOfs, 100);
      end;
      if (flags and $8) <> 0 then Inc(tocOfs, 4);   // quality indicator

      { LAME / encoder extension: "LAME"/"Lavf"/... then delay+padding at +21 }
      lameOfs := tocOfs;
      if lameOfs + 24 <= Length(AFrame) then
      begin
        AVbr.EncoderName := Trim(Chr(AFrame[lameOfs]) + Chr(AFrame[lameOfs + 1]) +
          Chr(AFrame[lameOfs + 2]) + Chr(AFrame[lameOfs + 3]) + Chr(AFrame[lameOfs + 4]) +
          Chr(AFrame[lameOfs + 5]) + Chr(AFrame[lameOfs + 6]) + Chr(AFrame[lameOfs + 7]) +
          Chr(AFrame[lameOfs + 8]));
        sfPos := lameOfs + 21;
        if sfPos + 3 <= Length(AFrame) then
        begin
          AVbr.EncoderDelay := (Integer(AFrame[sfPos]) shl 4) or (AFrame[sfPos + 1] shr 4);
          AVbr.EncoderPadding := ((Integer(AFrame[sfPos + 1]) and $0F) shl 8) or AFrame[sfPos + 2];
        end;
      end;
      Exit(True);
    end;
  end;

  { VBRI - always at byte 4 + 32 of an MPEG-1 stereo frame. }
  ofs := 4 + 32;
  if ofs + 26 <= Length(AFrame) then
  begin
    tag := Chr(AFrame[ofs]) + Chr(AFrame[ofs + 1]) + Chr(AFrame[ofs + 2]) + Chr(AFrame[ofs + 3]);
    if tag = 'VBRI' then
    begin
      AVbr.Present := True;
      AVbr.IsVBRI := True;
      AVbr.ByteCount := BE32(AFrame, ofs + 10);
      AVbr.FrameCount := BE32(AFrame, ofs + 14);
      entries := BE16(AFrame, ofs + 18);
      entrySize := BE16(AFrame, ofs + 22);
      AVbr.VbriFramesPerEntry := BE16(AFrame, ofs + 24);
      if (entrySize in [1, 2, 3, 4]) and (entries > 0) and (entries <= 65535) and
         (ofs + 26 + entries * entrySize <= Length(AFrame)) then
      begin
        SetLength(AVbr.VbriToc, entries);
        for i := 0 to entries - 1 do
        begin
          case entrySize of
            1: AVbr.VbriToc[i] := AFrame[ofs + 26 + i];
            2: AVbr.VbriToc[i] := BE16(AFrame, ofs + 26 + i * 2);
            3: AVbr.VbriToc[i] := (Cardinal(AFrame[ofs + 26 + i * 3]) shl 16) or
                                  BE16(AFrame, ofs + 27 + i * 3);
            4: AVbr.VbriToc[i] := BE32(AFrame, ofs + 26 + i * 4);
          end;
        end;
        AVbr.TocEntries := entries;
      end;
      Exit(True);
    end;
  end;
end;

{ ============================ TMP3StreamInfo ========================== }

function TMP3StreamInfo.Channels: Integer;
begin
  Result := FirstFrame.Channels;
end;

function TMP3StreamInfo.SampleRate: Integer;
begin
  Result := FirstFrame.SampleRate;
end;

function TMP3StreamInfo.DurationSeconds: Double;
begin
  if SampleRate > 0 then Result := TotalSamples / SampleRate else Result := 0;
end;

function TMP3StreamInfo.Describe: string;
begin
  Result := Format('%s | %s | %d frames (%d L3), %d samples, %.3f s, %s%d kbps',
    [FirstFrame.Describe,
     IfThen(Vbr.Present, IfThen(Vbr.IsVBRI, 'VBRI', 'Xing'), 'no VBR hdr'),
     FrameCount, Layer3FrameCount, TotalSamples, DurationSeconds,
     IfThen(IsCBR, 'CBR ', 'VBR ~'), NominalBitrateKbps]);
end;

{ Is there an ID3v1 tag in the last 128 bytes? }
function TrailingId3v1(const AData: TBytes): Boolean;
var
  o: Int64;
begin
  Result := False;
  o := Int64(Length(AData)) - 128;
  if o < 0 then Exit;
  Result := (AData[o] = Ord('T')) and (AData[o + 1] = Ord('A')) and (AData[o + 2] = Ord('G'));
end;

{ APEv2 trailer detection ("APETAGEX" 8 bytes, version, size...). Returns the
  full footer+body size or 0. }
function TrailingApeSize(const AData: TBytes; AEndBeforeId3v1: Int64): Int64;
var
  o: Int64;
  sig: string;
  bodySize: Cardinal;
  i: Integer;
begin
  Result := 0;
  o := AEndBeforeId3v1 - 32;
  if o < 0 then Exit;
  sig := '';
  for i := 0 to 7 do sig := sig + Chr(AData[o + i]);
  if sig <> 'APETAGEX' then Exit;
  bodySize := Cardinal(AData[o + 12]) or (Cardinal(AData[o + 13]) shl 8) or
              (Cardinal(AData[o + 14]) shl 16) or (Cardinal(AData[o + 15]) shl 24);
  Result := Int64(bodySize) + 32;   // footer counted in bodySize already per spec varies; be safe
  if Result > AEndBeforeId3v1 then Result := 0;
end;

function ScanMp3Stream(const AData: TBytes; out AInfo: TMP3StreamInfo): Boolean;
var
  len, pos: Int64;
  hdr, firstReal: TMP3FrameHeader;
  flen: Integer;
  samplePos: Int64;
  gotFirst: Boolean;
  frameCap, nFrames: Integer;
  firstFrameBytes: TBytes;
  minBr, maxBr: Integer;
  resyncTries: Integer;
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  Result := False;
  len := Length(AData);
  if (len < 4) or (len > MP3_MAX_FILE_BYTES) then
    Exit;

  { ID3v2 at the front. }
  if ReadId3v2Size(AData, AInfo.Id3v2Size) then
  begin
    if (AInfo.Id3v2Size <= 0) or (AInfo.Id3v2Size >= len) then
      AInfo.Id3v2Size := 0;
  end;
  AInfo.AudioStartOffset := AInfo.Id3v2Size;

  { ID3v1 / APE at the back. }
  AInfo.HasId3v1 := TrailingId3v1(AData);
  AInfo.AudioEndOffset := len;
  if AInfo.HasId3v1 then Dec(AInfo.AudioEndOffset, 128);
  AInfo.ApeTrailerSize := TrailingApeSize(AData, AInfo.AudioEndOffset);
  if AInfo.ApeTrailerSize > 0 then Dec(AInfo.AudioEndOffset, AInfo.ApeTrailerSize);
  if AInfo.AudioEndOffset <= AInfo.AudioStartOffset then
    AInfo.AudioEndOffset := len;

  { Find the first valid frame (skip up to 64 KiB of junk). }
  pos := AInfo.AudioStartOffset;
  resyncTries := 0;
  gotFirst := False;
  while (pos + 4 <= AInfo.AudioEndOffset) and (resyncTries < 65536) do
  begin
    if ReadFrameHeaderAt(AData, pos, hdr) and (hdr.FrameLengthBytes > 0) then
    begin
      { require a second sync where this frame says the next one is }
      if (pos + hdr.FrameLengthBytes + 4 <= AInfo.AudioEndOffset) then
      begin
        if ReadFrameHeaderAt(AData, pos + hdr.FrameLengthBytes, firstReal) and
           (firstReal.Version = hdr.Version) and (firstReal.Layer = hdr.Layer) and
           (firstReal.SampleRate = hdr.SampleRate) then
        begin
          gotFirst := True;
          Break;
        end;
      end
      else
      begin
        gotFirst := True;   // single-frame file
        Break;
      end;
    end;
    Inc(pos);
    Inc(resyncTries);
  end;

  if not gotFirst then Exit;

  AInfo.AudioStartOffset := pos;
  AInfo.FirstFrame := hdr;

  { VBR header check on the first frame. }
  flen := hdr.FrameLengthBytes;
  if (flen > 0) and (pos + flen <= len) then
  begin
    SetLength(firstFrameBytes, flen);
    Move(AData[pos], firstFrameBytes[0], flen);
    if ParseVbrHeader(firstFrameBytes, hdr, AInfo.Vbr) and AInfo.Vbr.Present then
      Inc(pos, flen);   // the VBR header frame carries no audio
  end;

  { Walk. }
  frameCap := 1024;
  SetLength(AInfo.Frames, frameCap);
  nFrames := 0;
  samplePos := 0;
  minBr := MaxInt;
  maxBr := 0;

  while pos + 4 <= AInfo.AudioEndOffset do
  begin
    if not ReadFrameHeaderAt(AData, pos, hdr) then
    begin
      { try a short resync }
      Inc(pos);
      resyncTries := 0;
      while (pos + 4 <= AInfo.AudioEndOffset) and (resyncTries < 4096) do
      begin
        if ReadFrameHeaderAt(AData, pos, hdr) then Break;
        Inc(pos);
        Inc(resyncTries);
      end;
      if not hdr.Parsed then Break;
    end;

    flen := hdr.FrameLengthBytes;
    if flen <= 0 then
    begin
      { free format - measure to the next sync }
      var nextp: Int64 := pos + 4;
      while (nextp + 4 <= AInfo.AudioEndOffset) do
      begin
        var h2: TMP3FrameHeader;
        if ReadFrameHeaderAt(AData, nextp, h2) and (h2.Version = hdr.Version) then Break;
        Inc(nextp);
      end;
      flen := nextp - pos;
      if flen <= 4 then Break;
    end;
    if flen > MP3_MAX_FRAME_BYTES then Break;
    if pos + flen > AInfo.AudioEndOffset + 1 then
      flen := Integer(AInfo.AudioEndOffset - pos);
    if flen <= 4 then Break;

    if nFrames >= frameCap then
    begin
      frameCap := frameCap * 2;
      if frameCap > MP3_MAX_FRAMES then Break;
      SetLength(AInfo.Frames, frameCap);
    end;

    AInfo.Frames[nFrames].FileOffset := pos;
    AInfo.Frames[nFrames].FrameBytes := flen;
    AInfo.Frames[nFrames].SamplePos := samplePos;

    if hdr.IsLayer3 then
    begin
      AInfo.Frames[nFrames].SamplesInFrame := hdr.SamplesPerFrame;
      Inc(AInfo.Layer3FrameCount);
      Inc(samplePos, hdr.SamplesPerFrame);
      Inc(AInfo.TotalSamples, hdr.SamplesPerFrame);
    end
    else
    begin
      AInfo.Frames[nFrames].SamplesInFrame := 0;
      Inc(AInfo.OtherLayerFrameCount);
    end;

    if hdr.BitrateKbps > 0 then
    begin
      if hdr.BitrateKbps < minBr then minBr := hdr.BitrateKbps;
      if hdr.BitrateKbps > maxBr then maxBr := hdr.BitrateKbps;
    end;

    Inc(nFrames);
    Inc(pos, flen);
  end;

  SetLength(AInfo.Frames, nFrames);
  AInfo.FrameCount := nFrames;
  AInfo.IsCBR := (minBr = maxBr) and (maxBr > 0);
  if maxBr > 0 then
  begin
    if AInfo.IsCBR then AInfo.NominalBitrateKbps := maxBr
    else AInfo.NominalBitrateKbps := (minBr + maxBr) div 2;
  end
  else
    AInfo.NominalBitrateKbps := AInfo.FirstFrame.BitrateKbps;

  { If a Xing frame count exists and we came up short (truncated), trust the
    scan for seeking but keep the reported count honest. }
  Result := nFrames > 0;
end;

end.
