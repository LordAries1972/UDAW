unit UDAW.Codec.MP4;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 16 - MP4 support (plan section 19): the single facade over the container
  layer, mirroring UDAW.Codec.WAV / UDAW.Codec.MP3.

  MP4 is a CONTAINER.  This unit reports the container and the carried audio
  codec SEPARATELY (Mp4Probe fills both), never labelling MP4 itself as a codec.

  Supported audio workflows in this phase:
    * read : PCM-in-MP4  ('sowt' 'twos' 'in24' 'in32' 'fl32' 'fl64' 'raw '
             'lpcm' 'ipcm'/pcmC)  -> engine planar Float32, exact.
    * read : MP3-in-MP4  ('.mp3'/'mp3 ' sample entry, or mp4a + esds OTI 0x6B) ->
             the Phase 15 Layer III decoder is fed the concatenated access units.
    * write: PCM-in-MP4  (16 / 24 / 32-bit float) via TMP4Writer.
  AAC-LC / HE-AAC / ALAC / AC-3 payloads are fully IDENTIFIED and REPORTED
  (object type, sample rate, channels, AudioSpecificConfig) but decoding them
  needs the AAC codebook data (Phase 16b); Mp4DecodeAudio raises a precise
  EUDAWError(errNotImplemented) naming the detected codec until then. }

interface

uses {$IFDEF FPC}UDAW.Compat,{$ENDIF}
  UDAW.Media.Progress, SysUtils, Classes, Math,
  UDAW.Errors, UDAW.Audio.Types,
  UDAW.Codec.MP4.Atoms, UDAW.Codec.MP4.Container,
  UDAW.Codec.MP3,
  UDAW.Codec.AAC;

type
  TMP4CodecKind = UDAW.Codec.MP4.Container.TMP4CodecKind;
  TMP4WriteCodec = UDAW.Codec.MP4.Container.TMP4WriteCodec;

  TMP4ProbeInfo = record
    IsMP4: Boolean;
    MajorBrand: string;
    CompatibleBrands: string;      // space separated
    Fragmented: Boolean;
    HasAudio: Boolean;
    { --- the audio track, when present --- }
    SampleEntry: string;          // raw FourCC from stsd
    Codec: TMP4CodecKind;
    CodecName: string;
    ObjectTypeIndication: Byte;
    AudioObjectType: Integer;      // ASC AOT for AAC family, else 0
    SampleRate: Integer;
    Channels: Integer;
    BitsPerSample: Integer;
    SampleCount: Integer;
    DurationSeconds: Double;
    AvgBitrateKbps: Integer;
    Decodable: Boolean;           // this unit can turn it into PCM right now
    function ContainerReport: string;
    function Describe: string;
  end;

  TMP4DecodeResult = record
    Data: TAudioPlanar;           // [channel][frame], Float32
    Channels: Integer;
    SampleRate: Integer;
    Frames: Integer;
    Codec: TMP4CodecKind;
    CodecName: string;
    ContainerBrand: string;
  end;

  TMP4EncodeCodec = (mecPCM16, mecPCM24, mecFloat32);

{ ---- sniffing (never looks at the extension) ---- }
function Mp4SniffData(const AData: TBytes): Boolean;
function Mp4SniffFile(const AFileName: string): Boolean;

{ ---- inspect ---- }
function Mp4Probe(const AData: TBytes; out AInfo: TMP4ProbeInfo): Boolean;
function Mp4ProbeFile(const AFileName: string; out AInfo: TMP4ProbeInfo): Boolean;

{ ---- decode to engine PCM ---- }
function Mp4DecodeAudio(const AData: TBytes; out ARes: TMP4DecodeResult): Boolean;
function Mp4DecodeAudioFile(const AFileName: string; out ARes: TMP4DecodeResult): Boolean;

{ ---- encode PCM into an MP4 container ---- }
function Mp4EncodeAudio(const APcm: TAudioPlanar; ASampleRate: Integer;
  ACodec: TMP4EncodeCodec; out AOut: TBytes; AOnProgress: TProc<Double> = nil): Boolean;
function Mp4EncodeAudioToFile(const APcm: TAudioPlanar; ASampleRate: Integer;
  ACodec: TMP4EncodeCodec; const AFileName: string): Boolean;

{ re-exports so a caller only needs this unit }
function Mp4CodecKindName(AKind: TMP4CodecKind): string;

implementation

uses
  UDAW.Codec.MP3.Decoder;

const
  MP4_FACADE_SUBSYS = 'Codec.MP4';

function Mp4CodecKindName(AKind: TMP4CodecKind): string;
begin
  Result := MP4CodecKindName(AKind);
end;

function LoadFile(const AFileName: string): TBytes;
var
  fs: TFileStream;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, MP4_FACADE_SUBSYS, 'MP4 file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, fs.Size);
    if Length(Result) > 0 then fs.ReadBuffer(Result[0], Length(Result));
  finally
    fs.Free;
  end;
end;

{ ============================ TMP4ProbeInfo ======================== }

function TMP4ProbeInfo.ContainerReport: string;
begin
  if not IsMP4 then
    Exit('Container: (not an MP4)');
  if HasAudio then
    Result := Format('Container: MP4 (brand ''%s'')  |  Audio codec: %s, %d Hz, %d ch, %d-bit',
      [MajorBrand, CodecName, SampleRate, Channels, BitsPerSample])
  else
    Result := Format('Container: MP4 (brand ''%s'')  |  Audio codec: (no sound track)',
      [MajorBrand]);
end;

function TMP4ProbeInfo.Describe: string;
begin
  Result := ContainerReport + sLineBreak +
    Format('  compatible brands : %s'#13#10 +
           '  fragmented        : %s'#13#10 +
           '  sample entry      : %s'#13#10 +
           '  object type (OTI) : 0x%.2x'#13#10 +
           '  AAC object type   : %d'#13#10 +
           '  samples           : %d'#13#10 +
           '  duration          : %.3f s'#13#10 +
           '  avg bitrate       : %d kbps'#13#10 +
           '  decodable here    : %s',
      [CompatibleBrands, BoolToStr(Fragmented, True), SampleEntry,
       ObjectTypeIndication, AudioObjectType, SampleCount, DurationSeconds,
       AvgBitrateKbps, BoolToStr(Decodable, True)]);
end;

{ ============================ sniff =============================== }

function Mp4SniffData(const AData: TBytes): Boolean;
var
  sz: Cardinal;
  t: string;
begin
  { A well-formed ISOBMFF file begins with a box whose type is 'ftyp' (or, more
    rarely, 'styp'/'moov'/'free'/'skip'/'wide'/'pdin').  Check the box type at
    offset 4 and a plausible size at offset 0. }
  Result := False;
  if Length(AData) < 12 then Exit;
  sz := (Cardinal(AData[0]) shl 24) or (Cardinal(AData[1]) shl 16) or
        (Cardinal(AData[2]) shl 8) or Cardinal(AData[3]);
  if (sz < 8) and (sz <> 1) then Exit;
  t := Chr(AData[4]) + Chr(AData[5]) + Chr(AData[6]) + Chr(AData[7]);
  if (t = 'ftyp') or (t = 'styp') or (t = 'moov') or (t = 'free') or
     (t = 'skip') or (t = 'wide') or (t = 'pdin') or (t = 'mdat') then
    Exit(True);
end;

function Mp4SniffFile(const AFileName: string): Boolean;
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
      SetLength(buf, Min(64, fs.Size));
      if Length(buf) = 0 then Exit;
      n := fs.Read(buf[0], Length(buf));
      SetLength(buf, n);
      Result := Mp4SniffData(buf);
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

{ ============================ probe ============================== }

function CodecDecodableHere(AKind: TMP4CodecKind): Boolean;
begin
  Result := MP4CodecIsPCM(AKind) or (AKind in [mckMP3, mckMP2, mckMP1]);
  if (not Result) and (AKind in [mckAAC_LC, mckHE_AAC, mckHE_AACv2]) then
    Result := AacTablesReady;
end;

function Mp4Probe(const AData: TBytes; out AInfo: TMP4ProbeInfo): Boolean;
var
  rdr: TMP4Reader;
  at: TMP4Track;
  i: Integer;
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  Result := False;
  if not Mp4SniffData(AData) then Exit;
  try
    rdr := TMP4Reader.Create(AData);
  except
    on E: EUDAWError do
      Exit;
  end;
  try
    AInfo.IsMP4 := True;
    AInfo.MajorBrand := rdr.MajorBrand;
    for i := 0 to High(rdr.CompatibleBrands) do
    begin
      if i > 0 then AInfo.CompatibleBrands := AInfo.CompatibleBrands + ' ';
      AInfo.CompatibleBrands := AInfo.CompatibleBrands + rdr.CompatibleBrands[i];
    end;
    AInfo.Fragmented := rdr.Fragmented;

    at := rdr.FirstAudioTrack;
    if at <> nil then
    begin
      AInfo.HasAudio := True;
      AInfo.SampleEntry := at.SampleEntry;
      AInfo.Codec := at.Codec;
      AInfo.CodecName := at.CodecName;
      AInfo.ObjectTypeIndication := at.ObjectTypeIndication;
      AInfo.AudioObjectType := at.AudioObjectType;
      AInfo.SampleRate := at.SampleRate;
      AInfo.Channels := at.ChannelCount;
      AInfo.BitsPerSample := at.BitsPerSample;
      AInfo.SampleCount := at.Table.SampleCount;
      AInfo.DurationSeconds := at.DurationSeconds;
      AInfo.AvgBitrateKbps := at.AvgBitrate div 1000;
      AInfo.Decodable := CodecDecodableHere(at.Codec) and (not rdr.Fragmented);
    end;
    Result := True;
  finally
    rdr.Free;
  end;
end;

function Mp4ProbeFile(const AFileName: string; out AInfo: TMP4ProbeInfo): Boolean;
begin
  Result := Mp4Probe(LoadFile(AFileName), AInfo);
end;

{ ============================ decode ============================= }

{ read a sample's raw bytes out of the file buffer }
function SampleBytes(const AData: TBytes; const S: TMP4SampleRef): TBytes;
begin
  SetLength(Result, 0);
  if (S.Offset < 0) or (S.Size <= 0) or (S.Offset + S.Size > Length(AData)) then Exit;
  SetLength(Result, S.Size);
  Move(AData[S.Offset], Result[0], S.Size);
end;

procedure DecodePCMTrack(const AData: TBytes; ATrack: TMP4Track;
  out ARes: TMP4DecodeResult);
var
  ch, chans, bytesPerSample, frameBytes, i, fi, totalFrames: Integer;
  kind: TMP4CodecKind;
  littleEndian, isFloat, isUnsigned: Boolean;
  blob: TBytes;
  p, blobLen: Int64;
  s: Single;
  smp: TMP4SampleRefArray;

  function ReadOne(AOfs: Int64): Single;
  var
    v, k: Integer;
    d: Double;
    b0, b1, b2, b3, tb: Byte;
    tmp: array[0..7] of Byte;
  begin
    Result := 0;
    case bytesPerSample of
      1:
        if isUnsigned then
          Result := (Integer(blob[AOfs]) - 128) / 128.0
        else
          Result := ShortInt(blob[AOfs]) / 128.0;
      2:
        begin
          if littleEndian then
            v := SmallInt(blob[AOfs] or (blob[AOfs + 1] shl 8))
          else
            v := SmallInt((blob[AOfs] shl 8) or blob[AOfs + 1]);
          Result := v / 32768.0;
        end;
      3:
        begin
          if littleEndian then
            v := blob[AOfs] or (blob[AOfs + 1] shl 8) or (blob[AOfs + 2] shl 16)
          else
            v := blob[AOfs + 2] or (blob[AOfs + 1] shl 8) or (blob[AOfs] shl 16);
          if (v and $800000) <> 0 then v := v or Integer($FF000000);
          Result := v / 8388608.0;
        end;
      4:
        begin
          if littleEndian then
          begin
            b0 := blob[AOfs]; b1 := blob[AOfs + 1]; b2 := blob[AOfs + 2]; b3 := blob[AOfs + 3];
          end
          else
          begin
            b0 := blob[AOfs + 3]; b1 := blob[AOfs + 2]; b2 := blob[AOfs + 1]; b3 := blob[AOfs];
          end;
          v := Integer(b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24));
          if isFloat then
            Result := PSingle(@v)^
          else
            Result := v / 2147483648.0;
        end;
      8:
        begin
          Move(blob[AOfs], d, 8);
          if not littleEndian then
          begin
            Move(blob[AOfs], tmp[0], 8);
            for k := 0 to 3 do
            begin
              tb := tmp[k]; tmp[k] := tmp[7 - k]; tmp[7 - k] := tb;
            end;
            Move(tmp[0], d, 8);
          end;
          Result := d;
        end;
    end;
  end;

begin
  FillChar(ARes, SizeOf(ARes), 0);
  kind := ATrack.Codec;
  chans := Max(1, ATrack.ChannelCount);

  littleEndian := kind in [mckPCM_S16LE, mckPCM_S24LE, mckPCM_S32LE, mckPCM_F32, mckPCM_U8, mckPCM_ISO, mckPCM_F64];
  isFloat := kind in [mckPCM_F32, mckPCM_F64];
  isUnsigned := kind = mckPCM_U8;
  case kind of
    mckPCM_U8:                     bytesPerSample := 1;
    mckPCM_S16LE, mckPCM_S16BE:    bytesPerSample := 2;
    mckPCM_S24LE, mckPCM_S24BE:    bytesPerSample := 3;
    mckPCM_S32LE, mckPCM_S32BE, mckPCM_F32: bytesPerSample := 4;
    mckPCM_F64:                    bytesPerSample := 8;
    mckPCM_ISO:                    bytesPerSample := Max(1, ATrack.BitsPerSample div 8);
  else
    bytesPerSample := 2;
  end;
  if kind = mckPCM_ISO then
  begin
    { pcmC little-endian variants already remapped to mckPCM_S*LE in the
      container; a bare 'ipcm' with no pcmC defaults to big-endian per spec. }
    littleEndian := False;
  end;
  frameBytes := bytesPerSample * chans;

  { gather every sample payload into one contiguous blob }
  smp := ATrack.Table.Samples;
  blobLen := 0;
  for i := 0 to High(smp) do
    Inc(blobLen, smp[i].Size);
  SetLength(blob, blobLen);
  p := 0;
  for i := 0 to High(smp) do
  begin
    if (smp[i].Offset >= 0) and (smp[i].Offset + smp[i].Size <= Length(AData)) and (smp[i].Size > 0) then
    begin
      Move(AData[smp[i].Offset], blob[p], smp[i].Size);
      Inc(p, smp[i].Size);
    end;
  end;
  blobLen := p;
  SetLength(blob, blobLen);

  if frameBytes <= 0 then
    RaiseUDAW(errIO, MP4_FACADE_SUBSYS, 'PCM-in-MP4: zero frame size');
  totalFrames := blobLen div frameBytes;

  EnsurePlanar(ARes.Data, chans, totalFrames);
  for fi := 0 to totalFrames - 1 do
  begin
    if (fi mod 4096) = 0 then ReportMediaProgress('Decoding MP4 PCM', fi, totalFrames, ATrack.SampleRate);
    for ch := 0 to chans - 1 do
    begin
      s := ReadOne(Int64(fi) * frameBytes + ch * bytesPerSample);
      ARes.Data[ch][fi] := ClampSample(s);
    end;

  end;
  ARes.Channels := chans;
  ARes.SampleRate := ATrack.SampleRate;
  ARes.Frames := totalFrames;
  ARes.Codec := kind;
  ARes.CodecName := ATrack.CodecName;
end;

procedure DecodeMP3Track(const AData: TBytes; ATrack: TMP4Track;
  out ARes: TMP4DecodeResult);
var
  smp: TMP4SampleRefArray;
  blob: TBytes;
  p, blobLen: Int64;
  i: Integer;
  mres: TMP3DecodeResult;
begin
  FillChar(ARes, SizeOf(ARes), 0);
  smp := ATrack.Table.Samples;
  blobLen := 0;
  for i := 0 to High(smp) do Inc(blobLen, smp[i].Size);
  SetLength(blob, blobLen);
  p := 0;
  for i := 0 to High(smp) do
    if (smp[i].Offset >= 0) and (smp[i].Offset + smp[i].Size <= Length(AData)) and (smp[i].Size > 0) then
    begin
      Move(AData[smp[i].Offset], blob[p], smp[i].Size);
      Inc(p, smp[i].Size);
    end;
  SetLength(blob, p);

  if not Mp3Decode(blob, mres, False) then
    RaiseUDAW(errIO, MP4_FACADE_SUBSYS, 'MP3-in-MP4: the Layer III decoder rejected the payload');

  ARes.Data := mres.Pcm;
  ARes.Channels := mres.Channels;
  ARes.SampleRate := mres.SampleRate;
  ARes.Frames := Integer(mres.Frames);
  ARes.Codec := ATrack.Codec;
  ARes.CodecName := ATrack.CodecName;
end;

procedure DecodeAACTrack(const AData: TBytes; ATrack: TMP4Track;
  out ARes: TMP4DecodeResult);
var
  smp: TMP4SampleRefArray;
  units: array of TBytes;
  i: Integer;
  ares_: TAACDecodeResult;
  asc: TBytes;
begin
  FillChar(ARes, SizeOf(ARes), 0);
  asc := ATrack.AudioSpecificConfig;
  if Length(asc) < 2 then
    RaiseUDAW(errConfig, MP4_FACADE_SUBSYS,
      'AAC-in-MP4: track carries no AudioSpecificConfig (esds/DecoderSpecificInfo)');

  smp := ATrack.Table.Samples;
  SetLength(units, Length(smp));
  for i := 0 to High(smp) do
  begin
    if (smp[i].Offset >= 0) and (smp[i].Size > 0) and
       (smp[i].Offset + smp[i].Size <= Length(AData)) then
    begin
      SetLength(units[i], smp[i].Size);
      Move(AData[smp[i].Offset], units[i][0], smp[i].Size);
    end
    else
      SetLength(units[i], 0);
  end;

  if not AacDecodeRaw(asc, units, ares_) then
    RaiseUDAW(errIO, MP4_FACADE_SUBSYS, 'AAC-in-MP4: the AAC-LC decoder produced no audio');

  ARes.Data := ares_.Data;
  ARes.Channels := ares_.Channels;
  ARes.SampleRate := ares_.SampleRate;
  ARes.Frames := Integer(ares_.Frames);
  ARes.Codec := ATrack.Codec;
  ARes.CodecName := ATrack.CodecName;
end;

function Mp4DecodeAudio(const AData: TBytes; out ARes: TMP4DecodeResult): Boolean;
var
  rdr: TMP4Reader;
  at: TMP4Track;
begin
  FillChar(ARes, SizeOf(ARes), 0);
  rdr := TMP4Reader.Create(AData);
  try
    if rdr.Fragmented then
      RaiseUDAW(errNotImplemented, MP4_FACADE_SUBSYS,
        'fragmented MP4 (moof) decoding is not supported in this phase');
    at := rdr.FirstAudioTrack;
    if at = nil then
      RaiseUDAW(errIO, MP4_FACADE_SUBSYS, 'MP4 has no sound track to decode');

    ARes.ContainerBrand := rdr.MajorBrand;

    if at.IsPCM then
      DecodePCMTrack(AData, at, ARes)
    else if at.Codec in [mckMP3, mckMP2, mckMP1] then
      DecodeMP3Track(AData, at, ARes)
    else if at.Codec in [mckAAC_LC, mckHE_AAC, mckHE_AACv2] then
      DecodeAACTrack(AData, at, ARes)
    else
      RaiseUDAWFmt(errNotImplemented, MP4_FACADE_SUBSYS,
        'audio codec identified as "%s" (sample entry ''%s''); the built-in ' +
        'decoder covers AAC-LC (and the HE-AAC core), not this profile. The ' +
        'container, codec identity, %d Hz / %d ch / %.3f s and the ' +
        'AudioSpecificConfig are all available via Mp4Probe.',
        [at.CodecName, at.SampleEntry, at.SampleRate, at.ChannelCount, at.DurationSeconds]);

    ARes.ContainerBrand := rdr.MajorBrand;
    Result := ARes.Frames > 0;
  finally
    rdr.Free;
  end;
end;

function Mp4DecodeAudioFile(const AFileName: string; out ARes: TMP4DecodeResult): Boolean;
begin
  Result := Mp4DecodeAudio(LoadFile(AFileName), ARes);
end;

{ ============================ encode ============================= }

function Mp4EncodeAudio(const APcm: TAudioPlanar; ASampleRate: Integer;
  ACodec: TMP4EncodeCodec; out AOut: TBytes; AOnProgress: TProc<Double>): Boolean;
var
  chans, frames, ch, fi, bytesPerSample: Integer;
  wc: TMP4WriteCodec;
  inter: TBytes;
  ofs: Int64;
  s: Single;
  v: Integer;
begin
  SetLength(AOut, 0);
  chans := Length(APcm);
  if chans < 1 then
    RaiseUDAW(errInvalidArgument, MP4_FACADE_SUBSYS, 'Mp4EncodeAudio: no channels');
  frames := Length(APcm[0]);
  for ch := 1 to chans - 1 do
    frames := Min(frames, Length(APcm[ch]));
  if frames <= 0 then
    RaiseUDAW(errInvalidArgument, MP4_FACADE_SUBSYS, 'Mp4EncodeAudio: empty input');

  wc := mwcPCM_S16LE;
  bytesPerSample := 0;
  case ACodec of
    mecPCM16:   begin wc := mwcPCM_S16LE; bytesPerSample := 2; end;
    mecPCM24:   begin wc := mwcPCM_S24LE; bytesPerSample := 3; end;
    mecFloat32: begin wc := mwcPCM_F32LE; bytesPerSample := 4; end;
  else
    RaiseUDAW(errInvalidArgument, MP4_FACADE_SUBSYS, 'Mp4EncodeAudio: bad codec');
  end;

  SetLength(inter, Int64(frames) * chans * bytesPerSample);
  for fi := 0 to frames - 1 do
  begin
    if Assigned(AOnProgress) and ((fi mod 4096) = 0) then AOnProgress(fi / frames);
    for ch := 0 to chans - 1 do
    begin
      ofs := (Int64(fi) * chans + ch) * bytesPerSample;
      s := ClampSample(APcm[ch][fi]);
      case ACodec of
        mecPCM16:
          begin
            v := Round(s * 32767.0);
            if v > 32767 then v := 32767 else if v < -32768 then v := -32768;
            inter[ofs] := v and $FF;
            inter[ofs + 1] := (v shr 8) and $FF;
          end;
        mecPCM24:
          begin
            { 'in24' (unlike 'sowt', which explicitly means little-endian)
              means big-endian per QuickTime/MP4 convention when there is no
              'wave'/'enda' child atom declaring otherwise - and this writer
              doesn't emit one. UDAW.Codec.MP4.Container's reader already
              assumes 'in24' -> big-endian (mckPCM_S24BE); this writer used
              to pack little-endian bytes under that same fourcc, so a
              round-trip byte-swapped every sample into noise. Pack
              big-endian (MSB first) here to match both the reader and the
              wider spec convention real MP4 tools also assume for 'in24'. }
            v := Round(s * 8388607.0);
            if v > 8388607 then v := 8388607 else if v < -8388608 then v := -8388608;
            inter[ofs] := (v shr 16) and $FF;
            inter[ofs + 1] := (v shr 8) and $FF;
            inter[ofs + 2] := v and $FF;
          end;
        mecFloat32:
          begin
            Move(s, inter[ofs], 4);
          end;
      end;
    end;

  end;
  AOut := TMP4Writer.BuildPCM(wc, inter, ASampleRate, chans, frames);
  Result := Length(AOut) > 0;
end;

function Mp4EncodeAudioToFile(const APcm: TAudioPlanar; ASampleRate: Integer;
  ACodec: TMP4EncodeCodec; const AFileName: string): Boolean;
var
  bytes: TBytes;
  fs: TFileStream;
begin
  Result := Mp4EncodeAudio(APcm, ASampleRate, ACodec, bytes);
  if not Result then Exit;
  fs := TFileStream.Create(AFileName, fmCreate);
  try
    if Length(bytes) > 0 then fs.WriteBuffer(bytes[0], Length(bytes));
  finally
    fs.Free;
  end;
end;

end.
