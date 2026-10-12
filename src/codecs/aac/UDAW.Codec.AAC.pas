unit UDAW.Codec.AAC;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 16b - AAC support: the single facade over the AAC-LC decoder, plus the
  ADTS transport walk.  Mirrors UDAW.Codec.WAV / UDAW.Codec.MP3.

  Entry points:
    * AacSniff*      - true ADTS syncword (0xFFF + layer 0), never the extension.
    * AacProbe*      - profile / rate / channels / frame count from the ADTS
                       header (or a supplied AudioSpecificConfig).
    * AacDecodeAdts* - decode a whole .aac / ADTS elementary stream to engine
                       planar Float32.
    * AacDecodeRaw   - decode raw access units + an AudioSpecificConfig (the
                       shape UDAW.Codec.MP4 hands us for an 'mp4a' track).

  HE-AAC: the LC core is decoded here; SBR / PS reconstruction is a follow-up
  pass (TAACDecodeResult.HadSBR flags that the output is core-bandwidth only).

  If the Huffman codebooks in UDAW.Codec.AAC.HuffData.inc are still the loud
  stub, every decode path raises a precise EUDAWError(errNotImplemented) naming
  that file - never silent garbage. }

interface

uses
  UDAW.Media.Progress, SysUtils, Classes, Math,
  UDAW.Errors, UDAW.Audio.Types,
  UDAW.Codec.AAC.Types, UDAW.Codec.AAC.Tables, UDAW.Codec.AAC.Decoder;

type
  TAACStreamInfo = record
    IsADTS: Boolean;
    ObjectType: Integer;          // MPEG-4 AOT (ADTS profile + 1)
    SampleRateIndex: Integer;
    SampleRate: Integer;
    ChannelConfig: Integer;
    Channels: Integer;
    FrameCount: Int64;
    HasCRC: Boolean;
    ApproxDurationSeconds: Double;
    function Describe: string;
  end;

  TAACDecodeResult = record
    Data: TAudioPlanar;           // [ch][frame] Float32
    Channels: Integer;
    SampleRate: Integer;
    Frames: Int64;
    DecodedBlocks: Int64;
    DamagedBlocks: Int64;         // frames that could not be decoded - replaced by silence, timing kept
    FirstError: string;           // why the first damaged frame failed (diagnostics)
    HadSBR: Boolean;              // stream signalled SBR (output is core-band only)
    TablesPopulated: Boolean;    // false => HuffData.inc still stubbed
  end;

{ ---- sniff ---- }
function AacSniffData(const AData: TBytes): Boolean;
function AacSniffFile(const AFileName: string): Boolean;

{ ---- probe ---- }
function AacProbe(const AData: TBytes; out AInfo: TAACStreamInfo): Boolean;
function AacProbeFile(const AFileName: string; out AInfo: TAACStreamInfo): Boolean;

{ ---- decode ---- }
function AacDecodeAdts(const AData: TBytes; out ARes: TAACDecodeResult): Boolean;
function AacDecodeAdtsFile(const AFileName: string; out ARes: TAACDecodeResult): Boolean;

{ AAsc = AudioSpecificConfig / DecoderSpecificInfo (>= 2 bytes).
  AAccessUnits = the raw_data_block payloads, one per output frame. }
function AacDecodeRaw(const AAsc: TBytes; const AAccessUnits: array of TBytes;
  out ARes: TAACDecodeResult): Boolean;

{ true once the spectral Huffman tables in HuffData.inc carry real values }
function AacTablesReady: Boolean;

implementation

const
  FACADE_SUBSYS = 'Codec.AAC';

function AacTablesReady: Boolean;
var
  err: string;
begin
  InitAacTables;
  Result := HuffBooksSelfCheck(err);
end;

procedure RefuseIfNoTables;
begin
  if not AacTablesReady then
    RaiseUDAW(errNotImplemented, FACADE_SUBSYS,
      'AAC spectral Huffman codebooks are not populated - fill the length rows '
      + 'in src/codecs/aac/UDAW.Codec.AAC.HuffData.inc from ISO/IEC 14496-3 '
      + 'Tables 4.A.1..4.A.12 (or FFmpeg ff_aac_spectral_bits / _codes). The '
      + 'container, ADTS header and AudioSpecificConfig are all still available '
      + 'via AacProbe.');
end;

function LoadFile(const AFileName: string): TBytes;
var
  fs: TFileStream;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, FACADE_SUBSYS, 'AAC file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, fs.Size);
    if Length(Result) > 0 then fs.ReadBuffer(Result[0], Length(Result));
  finally
    fs.Free;
  end;
end;

{ ============================ ADTS ============================= }

type
  TAdtsHeader = record
    Valid: Boolean;
    HeaderBytes: Integer;      // 7 or 9
    ProfileObjectType: Integer;// MPEG-2 profile (0..3); AOT = +1
    SampleRateIndex: Integer;
    ChannelConfig: Integer;
    FrameLength: Integer;      // whole ADTS frame incl. header
    RawBlocksInFrame: Integer; // number_of_raw_data_blocks_in_frame + 1
    CrcAbsent: Boolean;
  end;

function ParseAdtsAt(const AData: TBytes; AOfs: Integer; out AHdr: TAdtsHeader): Boolean;
var
  b: PByte;
begin
  FillChar(AHdr, SizeOf(AHdr), 0);
  Result := False;
  if AOfs < 0 then Exit;
  if AOfs + 7 > Length(AData) then Exit;
  b := @AData[AOfs];
  { syncword 0xFFF, layer (bits) must be 00 }
  if (b[0] <> $FF) or ((b[1] and $F6) <> $F0) then Exit;   // 1111 1111  1111 0xx0
  AHdr.CrcAbsent := (b[1] and $01) = 1;
  AHdr.HeaderBytes := 7;
  if not AHdr.CrcAbsent then AHdr.HeaderBytes := 9;
  AHdr.ProfileObjectType := (b[2] shr 6) and $03;
  AHdr.SampleRateIndex := (b[2] shr 2) and $0F;
  AHdr.ChannelConfig := ((b[2] and $01) shl 2) or ((b[3] shr 6) and $03);
  AHdr.FrameLength := ((Integer(b[3]) and $03) shl 11) or (Integer(b[4]) shl 3) or
                      ((Integer(b[5]) shr 5) and $07);
  AHdr.RawBlocksInFrame := (b[6] and $03) + 1;
  if (AHdr.FrameLength < AHdr.HeaderBytes) or (AHdr.SampleRateIndex > 12) then Exit;
  AHdr.Valid := True;
  Result := True;
end;

function FindFirstAdts(const AData: TBytes; out AOfs: Integer): Boolean;
var
  i: Integer;
  h: TAdtsHeader;
begin
  AOfs := -1;
  { skip a leading ID3v2 tag if present }
  i := 0;
  if (Length(AData) > 10) and (AData[0] = Ord('I')) and (AData[1] = Ord('D')) and
     (AData[2] = Ord('3')) then
    i := 10 + (((AData[6] and $7F) shl 21) or ((AData[7] and $7F) shl 14) or
               ((AData[8] and $7F) shl 7) or (AData[9] and $7F));
  if (i < 0) or (i >= Length(AData)) then i := 0;
  while i + 7 <= Length(AData) do
  begin
    if (AData[i] = $FF) and ((AData[i + 1] and $F6) = $F0) then
      if ParseAdtsAt(AData, i, h) then
      begin
        { confirm the next frame also syncs, when there is room }
        if (i + h.FrameLength + 2 > Length(AData)) or
           ((AData[i + h.FrameLength] = $FF) and
            ((AData[i + h.FrameLength + 1] and $F6) = $F0)) then
        begin
          AOfs := i;
          Exit(True);
        end;
      end;
    Inc(i);
  end;
  Result := False;
end;

{ ============================ sniff / probe =================== }

function AacSniffData(const AData: TBytes): Boolean;
var
  ofs: Integer;
begin
  Result := FindFirstAdts(AData, ofs);
end;

function AacSniffFile(const AFileName: string): Boolean;
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
      SetLength(buf, Min(Int64(64 * 1024), fs.Size));
      if Length(buf) = 0 then Exit;
      n := fs.Read(buf[0], Length(buf));
      SetLength(buf, n);
    finally
      fs.Free;
    end;
    Result := AacSniffData(buf);
  except
    Result := False;
  end;
end;

function TAACStreamInfo.Describe: string;
begin
  Result := Format('AAC %s: AOT %d, %d Hz, chan-cfg %d (%d ch), %d frames, ~%.2f s',
    [BoolToStr(IsADTS, True), ObjectType, SampleRate, ChannelConfig, Channels,
     FrameCount, ApproxDurationSeconds]);
end;

function AacProbe(const AData: TBytes; out AInfo: TAACStreamInfo): Boolean;
var
  ofs, i, blocks: Integer;
  h: TAdtsHeader;
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  Result := False;
  if not FindFirstAdts(AData, ofs) then Exit;
  if not ParseAdtsAt(AData, ofs, h) then Exit;

  AInfo.IsADTS := True;
  AInfo.ObjectType := h.ProfileObjectType + 1;      // ADTS profile -> MPEG-4 AOT
  AInfo.SampleRateIndex := h.SampleRateIndex;
  AInfo.SampleRate := AacRateFromIndex(h.SampleRateIndex);
  AInfo.ChannelConfig := h.ChannelConfig;
  AInfo.Channels := AacChannelsForConfig(h.ChannelConfig);
  AInfo.HasCRC := not h.CrcAbsent;

  { count frames }
  i := ofs; blocks := 0;
  while (i + 7 <= Length(AData)) and ParseAdtsAt(AData, i, h) and h.Valid do
  begin
    Inc(blocks, h.RawBlocksInFrame);
    Inc(i, h.FrameLength);
    if h.FrameLength <= 0 then Break;
  end;
  AInfo.FrameCount := blocks;
  if AInfo.SampleRate > 0 then
    AInfo.ApproxDurationSeconds := blocks * 1024.0 / AInfo.SampleRate;
  Result := True;
end;

function AacProbeFile(const AFileName: string; out AInfo: TAACStreamInfo): Boolean;
begin
  Result := AacProbe(LoadFile(AFileName), AInfo);
end;

{ ============================ decode ========================= }

{ Decode one access unit.  A damaged or empty unit becomes a frame of silence so
  every later sample keeps its place in time (never a truncated file). }
procedure DecodeUnitOrConceal(ADec: TAACDecoder; ABytes: PByte; ALen: Integer;
  var ABlock: TAudioPlanar; out AProduced: Integer; var ADamaged: Int64; var AFirstError: string);
var
  br: TAacBitReader;
  ok: Boolean;
  ch: Integer;
begin
  ok := False;
  AProduced := 0;
  if ALen > 0 then
  begin
    br.Init(ABytes, ALen, 0);
    try
      ok := ADec.DecodeFrame(br, ABlock, AProduced) = adsOK;
    except
      on E: Exception do
      begin
        ok := False;
        if AFirstError = '' then AFirstError := E.ClassName + ': ' + E.Message;
      end;
    end;
  end;
  if (not ok) or (AProduced <= 0) or (Length(ABlock) < ADec.Channels) then
  begin
    AProduced := ADec.FrameLength;
    SetLength(ABlock, ADec.Channels);
    for ch := 0 to ADec.Channels - 1 do
    begin
      SetLength(ABlock[ch], AProduced);
      FillChar(ABlock[ch][0], AProduced * SizeOf(Single), 0);
    end;
    Inc(ADamaged);
  end;
end;

{ AAC lists channels in stream-element order (centre first); the engine and
  WAV use the front-left, front-right, centre, LFE, rear... order.  Only the
  fixed channelConfiguration layouts 3..7 need reordering. }
procedure AacToWaveChannelOrder(var AData: TAudioPlanar; AChannelConfig: Integer);
var
  src: TAudioPlanar;
  map: array of Integer;       // map[outCh] = stream channel
  i: Integer;
begin
  case AChannelConfig of
    3: map := [1, 2, 0];                          // C L R        -> L R C
    4: map := [1, 2, 0, 3];                       // C L R Cs     -> L R C Cs
    5: map := [1, 2, 0, 3, 4];                    // C L R Ls Rs  -> L R C Ls Rs
    6: map := [1, 2, 0, 5, 3, 4];                 // C L R Ls Rs LFE -> L R C LFE Ls Rs
    7: map := [3, 4, 0, 7, 5, 6, 1, 2];           // C Lc Rc L R Ls Rs LFE -> L R C LFE Ls Rs Lc Rc
  else
    Exit;
  end;
  if Length(AData) <> Length(map) then Exit;
  src := Copy(AData);
  for i := 0 to High(map) do AData[i] := src[map[i]];
end;

function AacDecodeAdts(const AData: TBytes; out ARes: TAACDecodeResult): Boolean;
var
  dec: TAACDecoder;
  ofs, i, ch, k, produced: Integer;
  h: TAdtsHeader;
  block: TAudioPlanar;
  outPos, capacity: Int64;
begin
  FillChar(ARes, SizeOf(ARes), 0);
  RefuseIfNoTables;

  if not FindFirstAdts(AData, ofs) then
    RaiseUDAW(errConfig, FACADE_SUBSYS, 'no ADTS syncword found');
  if not ParseAdtsAt(AData, ofs, h) then
    RaiseUDAW(errConfig, FACADE_SUBSYS, 'ADTS header parse failed');

  dec := TAACDecoder.Create;
  try
    dec.InitFromParams(h.ProfileObjectType + 1,
      AacRateFromIndex(h.SampleRateIndex), h.ChannelConfig);
    ARes.Channels := dec.Channels;
    ARes.SampleRate := dec.SampleRate;
    ARes.TablesPopulated := True;

    capacity := 4 * 1024 * 1024;
    SetLength(ARes.Data, ARes.Channels);
    for ch := 0 to ARes.Channels - 1 do SetLength(ARes.Data[ch], capacity);

    i := ofs;
    outPos := 0;
    while (i + 7 <= Length(AData)) and ParseAdtsAt(AData, i, h) and h.Valid do
    begin
      if i + h.FrameLength > Length(AData) then Break;
      DecodeUnitOrConceal(dec, @AData[i + h.HeaderBytes], h.FrameLength - h.HeaderBytes,
        block, produced, ARes.DamagedBlocks, ARes.FirstError);

      if outPos + produced > capacity then
      begin
        capacity := (outPos + produced) * 2 + 4096;
        for ch := 0 to ARes.Channels - 1 do SetLength(ARes.Data[ch], capacity);
      end;
      for ch := 0 to ARes.Channels - 1 do
        for k := 0 to produced - 1 do
          ARes.Data[ch][outPos + k] := block[ch][k];
      Inc(outPos, produced);
      Inc(ARes.DecodedBlocks);


      Inc(i, h.FrameLength);
      if h.FrameLength <= 0 then Break;
    end;

    for ch := 0 to ARes.Channels - 1 do SetLength(ARes.Data[ch], outPos);
    ARes.Frames := outPos;
    ARes.HadSBR := (dec.Config.Extension <> aeNone) or dec.SbrSeen;
    AacToWaveChannelOrder(ARes.Data, h.ChannelConfig);
    Result := outPos > 0;
  finally
    dec.Free;
  end;
end;

function AacDecodeAdtsFile(const AFileName: string; out ARes: TAACDecodeResult): Boolean;
begin
  Result := AacDecodeAdts(LoadFile(AFileName), ARes);
end;

function AacDecodeRaw(const AAsc: TBytes; const AAccessUnits: array of TBytes;
  out ARes: TAACDecodeResult): Boolean;
var
  cfg: TAacAudioConfig;
  dec: TAACDecoder;
  au, ch, k, produced: Integer;
  block: TAudioPlanar;
  outPos, capacity: Int64;
begin
  FillChar(ARes, SizeOf(ARes), 0);
  RefuseIfNoTables;

  if not ParseAudioSpecificConfig(AAsc, cfg) then
    RaiseUDAW(errConfig, FACADE_SUBSYS, 'AudioSpecificConfig parse failed');

  dec := TAACDecoder.Create;
  try
    dec.InitFromConfig(cfg);
    ARes.Channels := dec.Channels;
    ARes.SampleRate := dec.SampleRate;
    ARes.TablesPopulated := True;

    capacity := Int64(Length(AAccessUnits) + 2) * (dec.FrameLength + 8);
    if capacity < 8192 then capacity := 8192;
    SetLength(ARes.Data, ARes.Channels);
    for ch := 0 to ARes.Channels - 1 do SetLength(ARes.Data[ch], capacity);

    outPos := 0;
    for au := 0 to High(AAccessUnits) do
    begin
      if Length(AAccessUnits[au]) = 0 then
        DecodeUnitOrConceal(dec, nil, 0, block, produced, ARes.DamagedBlocks, ARes.FirstError)
      else
        DecodeUnitOrConceal(dec, @AAccessUnits[au][0], Length(AAccessUnits[au]),
          block, produced, ARes.DamagedBlocks, ARes.FirstError);
      if outPos + produced > capacity then
      begin
        capacity := (outPos + produced) * 2 + 4096;
        for ch := 0 to ARes.Channels - 1 do SetLength(ARes.Data[ch], capacity);
      end;
      for ch := 0 to ARes.Channels - 1 do
        for k := 0 to produced - 1 do
          ARes.Data[ch][outPos + k] := block[ch][k];
      Inc(outPos, produced);
      Inc(ARes.DecodedBlocks);
      ReportMediaProgress('Decoding AAC', outPos, Int64(Length(AAccessUnits)) * dec.FrameLength, ARes.SampleRate);
    end;

    for ch := 0 to ARes.Channels - 1 do SetLength(ARes.Data[ch], outPos);
    ARes.Frames := outPos;
    ARes.HadSBR := (cfg.Extension <> aeNone) or dec.SbrSeen;
    AacToWaveChannelOrder(ARes.Data, cfg.ChannelConfig);
    Result := outPos > 0;
  finally
    dec.Free;
  end;
end;

end.
