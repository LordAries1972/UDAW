unit UDAW.Codec.MKV.Writer;
{$I udaw.inc}
{$POINTERMATH ON}

{ Matroska (.mkv) writer used by the Timeline video export.

  The export first produces an MP4 holding H.264 video and AAC audio (see
  UDAW.Timeline.VideoExport).  Matroska stores both codecs in the same form as
  MP4 (length-prefixed H.264 access units, raw AAC frames), so the MKV file is
  made by REMUXING: every encoded sample is copied across unchanged - nothing is
  decoded or re-encoded, so it is fast and loses no quality.

  Only the movie header ('moov') is held in memory; sample bytes are streamed
  from the MP4 one at a time, so the length of the video does not matter.

  Layout written: EBML header, then a Segment holding SeekHead, Info, Tracks,
  Tags, Clusters and Cues, in that order.  Clusters start on video key frames (at least ~1 s apart, never more
  than ~5 s), and every cluster that starts on a key frame gets a Cues entry so
  players can seek. }

interface

uses
  SysUtils, Classes, Math,
  UDAW.Errors, UDAW.Media.Attribution, UDAW.Version,
  UDAW.Codec.MP4.Atoms, UDAW.Codec.MP4.Container;

type
  TMkvProgress = reference to procedure(AFraction: Double);

{ Returns the complete 'moov' box (header included) of an MP4 file, reading
  nothing else.  Raises EUDAWError when the file has none. }
function Mp4ReadMoovBox(const AFileName: string): TBytes;

{ Copies the H.264 video track and the AAC audio track of AMp4 into AMkv.
  ABpm > 0 stamps the tempo and a non-empty AArtist the author / copyright as
  Matroska tags; every file also carries the UDAW "created by" and version
  tags (the same facts the MP4 / MP3 exports carry). }
procedure RemuxMp4ToMkv(const AMp4, AMkv: string; ABpm: Double; const AArtist: string;
  AProgress: TMkvProgress = nil);

implementation

const
  MKV_SUBSYS = 'Codec.MKV';
  ID_EBML = $1A45DFA3;
  ID_SEGMENT = $18538067;
  ID_SEEKHEAD = $114D9B74;
  ID_SEEK = $4DBB;
  ID_SEEKID = $53AB;
  ID_SEEKPOS = $53AC;
  ID_INFO = $1549A966;
  ID_TIMESCALE = $2AD7B1;
  ID_DURATION = $4489;
  ID_MUXINGAPP = $4D80;
  ID_WRITINGAPP = $5741;
  ID_TRACKS = $1654AE6B;
  ID_TRACKENTRY = $AE;
  ID_TRACKNUMBER = $D7;
  ID_TRACKUID = $73C5;
  ID_TRACKTYPE = $83;
  ID_FLAGLACING = $9C;
  ID_CODECID = $86;
  ID_CODECPRIVATE = $63A2;
  ID_DEFAULTDURATION = $23E383;
  ID_VIDEO = $E0;
  ID_PIXELW = $B0;
  ID_PIXELH = $BA;
  ID_AUDIO = $E1;
  ID_SAMPLINGFREQ = $B5;
  ID_CHANNELS = $9F;
  ID_BITDEPTH = $6264;
  ID_CLUSTER = $1F43B675;
  ID_TIMECODE = $E7;
  ID_SIMPLEBLOCK = $A3;
  ID_CUES = $1C53BB6B;
  ID_CUEPOINT = $BB;
  ID_CUETIME = $B3;
  ID_CUETRACKPOS = $B7;
  ID_CUETRACK = $F7;
  ID_CUECLUSTERPOS = $F1;
  ID_DOCTYPE = $4282;
  ID_DOCTYPEVER = $4287;
  ID_DOCTYPEREADVER = $4285;
  ID_EBMLVER = $4286;
  ID_EBMLREADVER = $42F7;
  ID_EBMLMAXID = $42F2;
  ID_EBMLMAXSIZE = $42F3;
  ID_TAGS = $1254C367;
  ID_TAG = $7373;
  ID_TARGETS = $63C0;
  ID_SIMPLETAG = $67C8;
  ID_TAGNAME = $45A3;
  ID_TAGSTRING = $4487;

  VIDEO_TRACK = 1;
  AUDIO_TRACK = 2;
  CLUSTER_MIN_KEY_MS = 1000;
  CLUSTER_MAX_MS = 5000;
  FOURCC_MOOV = $6D6F6F76;

{ ============================ EBML primitives ============================ }

procedure Append(var ADest: TBytes; const ASrc: TBytes);
var
  n: Integer;
begin
  if Length(ASrc) = 0 then Exit;
  n := Length(ADest);
  SetLength(ADest, n + Length(ASrc));
  Move(ASrc[0], ADest[n], Length(ASrc));
end;

function IdBytes(AId: Cardinal): TBytes;
begin
  if AId > $FFFFFF then
    Result := TBytes.Create(Byte(AId shr 24), Byte(AId shr 16), Byte(AId shr 8), Byte(AId))
  else if AId > $FFFF then
    Result := TBytes.Create(Byte(AId shr 16), Byte(AId shr 8), Byte(AId))
  else if AId > $FF then
    Result := TBytes.Create(Byte(AId shr 8), Byte(AId))
  else
    Result := TBytes.Create(Byte(AId));
end;

{ Size as the shortest EBML varint (used for ordinary elements). }
function SizeBytes(ASize: Int64): TBytes;
var
  len, i: Integer;
  v: Int64;
begin
  len := 1;
  while (len < 8) and (ASize >= (Int64(1) shl (7 * len)) - 1) do Inc(len);
  SetLength(Result, len);
  v := ASize or (Int64(1) shl (7 * len));
  for i := len - 1 downto 0 do
  begin
    Result[i] := Byte(v and $FF);
    v := v shr 8;
  end;
end;

{ Size as a fixed 8-byte varint (used where the size is patched afterwards). }
function SizeBytes8(ASize: Int64): TBytes;
var
  i: Integer;
begin
  SetLength(Result, 8);
  Result[0] := $01;
  for i := 7 downto 1 do
  begin
    Result[i] := Byte(ASize and $FF);
    ASize := ASize shr 8;
  end;
end;

function Elem(AId: Cardinal; const APayload: TBytes): TBytes;
begin
  Result := IdBytes(AId);
  Append(Result, SizeBytes(Length(APayload)));
  Append(Result, APayload);
end;

function UIntBytes(AValue: UInt64; AFixed8: Boolean): TBytes;
var
  n, i: Integer;
begin
  n := 1;
  if not AFixed8 then
    while (n < 8) and (AValue >= (UInt64(1) shl (8 * n))) do Inc(n)
  else
    n := 8;
  SetLength(Result, n);
  for i := n - 1 downto 0 do
  begin
    Result[i] := Byte(AValue and $FF);
    AValue := AValue shr 8;
  end;
end;

function ElemUInt(AId: Cardinal; AValue: UInt64; AFixed8: Boolean = False): TBytes;
begin
  Result := Elem(AId, UIntBytes(AValue, AFixed8));
end;

function ElemStr(AId: Cardinal; const AText: string): TBytes;
begin
  Result := Elem(AId, TEncoding.UTF8.GetBytes(AText));
end;

function ElemFloat64(AId: Cardinal; AValue: Double): TBytes;
var
  bits: UInt64;
  b: TBytes;
  i: Integer;
begin
  Move(AValue, bits, 8);
  SetLength(b, 8);
  for i := 7 downto 0 do
  begin
    b[i] := Byte(bits and $FF);
    bits := bits shr 8;
  end;
  Result := Elem(AId, b);
end;

{ ============================== MP4 access =============================== }

function Mp4ReadMoovBox(const AFileName: string): TBytes;
var
  fs: TFileStream;
  hdr: array[0..15] of Byte;
  pos, size, hdrLen: Int64;
  kind: Cardinal;
  i: Integer;
begin
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    pos := 0;
    while pos + 8 <= fs.Size do
    begin
      fs.Position := pos;
      fs.ReadBuffer(hdr[0], 8);
      size := (Int64(hdr[0]) shl 24) or (Int64(hdr[1]) shl 16) or (Int64(hdr[2]) shl 8) or hdr[3];
      kind := (Cardinal(hdr[4]) shl 24) or (Cardinal(hdr[5]) shl 16) or
        (Cardinal(hdr[6]) shl 8) or hdr[7];
      hdrLen := 8;
      if size = 1 then
      begin
        if pos + 16 > fs.Size then Break;
        fs.ReadBuffer(hdr[8], 8);
        size := 0;
        for i := 8 to 15 do size := (size shl 8) or hdr[i];
        hdrLen := 16;
      end
      else if size = 0 then
        size := fs.Size - pos;
      if (size < hdrLen) or (pos + size > fs.Size) then Break;
      if kind = FOURCC_MOOV then
      begin
        if size > 512 * 1024 * 1024 then
          RaiseUDAW(errIO, MKV_SUBSYS, 'The movie header is implausibly large.');
        { Re-emitted with a plain 32-bit size so the atom parser sees a normal box. }
        SetLength(Result, size - hdrLen + 8);
        Result[0] := Byte((Length(Result) shr 24) and $FF);
        Result[1] := Byte((Length(Result) shr 16) and $FF);
        Result[2] := Byte((Length(Result) shr 8) and $FF);
        Result[3] := Byte(Length(Result) and $FF);
        Result[4] := Ord('m'); Result[5] := Ord('o'); Result[6] := Ord('o'); Result[7] := Ord('v');
        fs.Position := pos + hdrLen;
        if size > hdrLen then fs.ReadBuffer(Result[8], size - hdrLen);
        Exit;
      end;
      Inc(pos, size);
    end;
  finally
    fs.Free;
  end;
  RaiseUDAW(errIO, MKV_SUBSYS, 'The MP4 has no movie header (moov).');
end;

{ The avcC box (H.264 decoder configuration) inside the movie header: the first
  'avcC' FourCC, with its 4-byte size just before it. The encoder writes one
  video track, so the first hit is the right one. }
function FindAvcC(const AMoov: TBytes): TBytes;
var
  i: Integer;
  size: Cardinal;
begin
  SetLength(Result, 0);
  for i := 4 to Length(AMoov) - 4 do
    if (AMoov[i] = Ord('a')) and (AMoov[i + 1] = Ord('v')) and
       (AMoov[i + 2] = Ord('c')) and (AMoov[i + 3] = Ord('C')) then
    begin
      size := (Cardinal(AMoov[i - 4]) shl 24) or (Cardinal(AMoov[i - 3]) shl 16) or
        (Cardinal(AMoov[i - 2]) shl 8) or AMoov[i - 1];
      if (size > 8) and (Int64(i) - 4 + size <= Length(AMoov)) then
      begin
        SetLength(Result, size - 8);
        Move(AMoov[i + 4], Result[0], size - 8);
        Exit;
      end;
    end;
end;

{ One Matroska tag: a SimpleTag holding a TagName and a TagString. }
function SimpleTag(const AName, AValue: string): TBytes;
begin
  Result := ElemStr(ID_TAGNAME, AName);
  Append(Result, ElemStr(ID_TAGSTRING, AValue));
  Result := Elem(ID_SIMPLETAG, Result);
end;

{ ================================= remux ================================= }

type
  TMkvCue = record
    TimeMs: Int64;
    ClusterPos: Int64;     // relative to the start of the segment payload
  end;

procedure RemuxMp4ToMkv(const AMp4, AMkv: string; ABpm: Double; const AArtist: string;
  AProgress: TMkvProgress);
var
  moov, avcC, hdr, info, tracks, tagsEl, tagsBody, seekHead, body, cueBody, cuePoints: TBytes;
  reader: TMP4Reader;
  vt, at: TMP4Track;
  src, dst: TFileStream;
  vi, ai: Integer;
  segDataStart, seekHeadPos, infoPos, tracksPos, tagsPos, cuesPos, clusterPos: Int64;
  durationMs, fps: Double;
  cues: TArray<TMkvCue>;
  clusterBytes: TBytesStream;
  clusterOpen, takeVideo, isKey: Boolean;
  clusterStartMs, tMs: Int64;
  vTime, aTime: Double;
  sample: TMP4SampleRef;
  data: TBytes;
  rel: Integer;
  trackNo: Integer;
  total, done: Int64;

  function VideoTimeMs(I: Integer): Double;
  begin
    Result := vt.Table.Samples[I].CTS * 1000.0 / vt.MediaTimescale;
  end;

  function AudioTimeMs(I: Integer): Double;
  begin
    Result := at.Table.Samples[I].DTS * 1000.0 / at.MediaTimescale;
  end;

  function SeekHeadBytes(AInfo, ATracks, ATags, ACues: Int64): TBytes;
    function Entry(AId: Cardinal; APos: Int64): TBytes;
    var
      payload: TBytes;
    begin
      payload := Elem(ID_SEEKID, IdBytes(AId));
      Append(payload, ElemUInt(ID_SEEKPOS, UInt64(APos), True));
      Result := Elem(ID_SEEK, payload);
    end;
  var
    payload: TBytes;
  begin
    payload := Entry(ID_INFO, AInfo);
    Append(payload, Entry(ID_TRACKS, ATracks));
    Append(payload, Entry(ID_TAGS, ATags));
    Append(payload, Entry(ID_CUES, ACues));
    Result := Elem(ID_SEEKHEAD, payload);
  end;

  procedure FlushCluster;
  var
    h: TBytes;
  begin
    if not clusterOpen then Exit;
    h := IdBytes(ID_CLUSTER);
    Append(h, SizeBytes(clusterBytes.Size));
    dst.WriteBuffer(h[0], Length(h));
    if clusterBytes.Size > 0 then dst.WriteBuffer(clusterBytes.Bytes[0], clusterBytes.Size);
    clusterBytes.Clear;
    clusterOpen := False;
  end;

  procedure OpenCluster(AStartMs: Int64; AKey: Boolean);
  var
    c: TMkvCue;
  begin
    clusterPos := dst.Position - segDataStart;
    clusterStartMs := AStartMs;
    clusterBytes.Clear;
    body := ElemUInt(ID_TIMECODE, UInt64(AStartMs));
    clusterBytes.WriteBuffer(body[0], Length(body));
    clusterOpen := True;
    if AKey then
    begin
      c.TimeMs := AStartMs;
      c.ClusterPos := clusterPos;
      SetLength(cues, Length(cues) + 1);
      cues[High(cues)] := c;
    end;
  end;

  procedure WriteBlock(ATrack: Integer; ATimeMs: Int64; AKey: Boolean; const AData: TBytes);
  var
    h: TBytes;
    payloadLen: Integer;
    flags: Byte;
  begin
    rel := Integer(ATimeMs - clusterStartMs);
    if rel < -32768 then rel := -32768;
    if rel > 32767 then rel := 32767;
    payloadLen := 4 + Length(AData);
    h := IdBytes(ID_SIMPLEBLOCK);
    Append(h, SizeBytes(payloadLen));
    flags := 0;
    if AKey then flags := $80;
    Append(h, TBytes.Create(Byte($80 or ATrack), Byte((rel shr 8) and $FF), Byte(rel and $FF), flags));
    clusterBytes.WriteBuffer(h[0], Length(h));
    if Length(AData) > 0 then clusterBytes.WriteBuffer(AData[0], Length(AData));
  end;

begin
  moov := Mp4ReadMoovBox(AMp4);
  reader := TMP4Reader.Create(moov);
  src := nil; dst := nil; clusterBytes := nil;
  try
    vt := reader.FirstVideoTrack;
    at := reader.FirstAudioTrack;
    if (vt = nil) or (vt.Table.SampleCount = 0) or (vt.MediaTimescale = 0) then
      RaiseUDAW(errIO, MKV_SUBSYS, 'The encoded MP4 has no video track to convert.');
    if (at <> nil) and ((at.Table.SampleCount = 0) or (at.MediaTimescale = 0)) then at := nil;
    if (at <> nil) and not MP4CodecIsAAC(at.Codec) then
      RaiseUDAW(errIO, MKV_SUBSYS, 'The audio is not AAC, which this MKV writer carries.');
    avcC := FindAvcC(moov);
    if Length(avcC) < 7 then
      RaiseUDAW(errIO, MKV_SUBSYS, 'The encoded MP4 has no H.264 configuration.');

    durationMs := VideoTimeMs(vt.Table.SampleCount - 1) + 1000.0 / 30;
    if vt.Table.ConstantSampleDelta > 0 then
      durationMs := (vt.Table.Samples[vt.Table.SampleCount - 1].CTS +
        vt.Table.ConstantSampleDelta) * 1000.0 / vt.MediaTimescale;
    if (at <> nil) and (at.DurationSeconds * 1000.0 > durationMs) then
      durationMs := at.DurationSeconds * 1000.0;
    fps := vt.Table.SampleCount * 1000.0 / Max(1.0, durationMs);

    { ---- header elements ---- }
    hdr := ElemUInt(ID_EBMLVER, 1);
    Append(hdr, ElemUInt(ID_EBMLREADVER, 1));
    Append(hdr, ElemUInt(ID_EBMLMAXID, 4));
    Append(hdr, ElemUInt(ID_EBMLMAXSIZE, 8));
    Append(hdr, ElemStr(ID_DOCTYPE, 'matroska'));
    Append(hdr, ElemUInt(ID_DOCTYPEVER, 4));
    Append(hdr, ElemUInt(ID_DOCTYPEREADVER, 2));
    hdr := Elem(ID_EBML, hdr);

    info := ElemUInt(ID_TIMESCALE, 1000000);   // 1 ms ticks
    Append(info, ElemStr(ID_MUXINGAPP, 'UDAW'));
    Append(info, ElemStr(ID_WRITINGAPP, 'UDAW'));
    Append(info, ElemFloat64(ID_DURATION, durationMs));
    info := Elem(ID_INFO, info);

    { video track }
    body := ElemUInt(ID_TRACKNUMBER, VIDEO_TRACK);
    Append(body, ElemUInt(ID_TRACKUID, VIDEO_TRACK));
    Append(body, ElemUInt(ID_TRACKTYPE, 1));
    Append(body, ElemUInt(ID_FLAGLACING, 0));
    Append(body, ElemStr(ID_CODECID, 'V_MPEG4/ISO/AVC'));
    Append(body, Elem(ID_CODECPRIVATE, avcC));
    Append(body, ElemUInt(ID_DEFAULTDURATION, Round(1.0E9 / Max(1.0, fps))));
    cueBody := ElemUInt(ID_PIXELW, vt.VideoWidth);
    Append(cueBody, ElemUInt(ID_PIXELH, vt.VideoHeight));
    Append(body, Elem(ID_VIDEO, cueBody));
    tracks := Elem(ID_TRACKENTRY, body);
    { audio track }
    if at <> nil then
    begin
      body := ElemUInt(ID_TRACKNUMBER, AUDIO_TRACK);
      Append(body, ElemUInt(ID_TRACKUID, AUDIO_TRACK));
      Append(body, ElemUInt(ID_TRACKTYPE, 2));
      Append(body, ElemUInt(ID_FLAGLACING, 0));
      Append(body, ElemStr(ID_CODECID, 'A_AAC'));
      Append(body, Elem(ID_CODECPRIVATE, at.AudioSpecificConfig));
      cueBody := ElemFloat64(ID_SAMPLINGFREQ, at.SampleRate);
      Append(cueBody, ElemUInt(ID_CHANNELS, Max(1, at.ChannelCount)));
      Append(cueBody, ElemUInt(ID_BITDEPTH, 16));
      Append(body, Elem(ID_AUDIO, cueBody));
      Append(tracks, Elem(ID_TRACKENTRY, body));
    end;
    tracks := Elem(ID_TRACKS, tracks);

    { Tags: copyright / author, tempo, creator and version. }
    if AArtist <> '' then tagsBody := SimpleTag('COPYRIGHT', AArtist)
    else tagsBody := SimpleTag('COPYRIGHT', UDAW_MEDIA_COPYRIGHT);
    if AArtist <> '' then Append(tagsBody, SimpleTag('ARTIST', AArtist));
    if ABpm > 0 then Append(tagsBody, SimpleTag('BPM', Format('%.2f', [ABpm], TFormatSettings.Invariant)));
    Append(tagsBody, SimpleTag('ENCODER', UDAW_MEDIA_CREATED_BY));
    Append(tagsBody, SimpleTag('UDAW_VERSION', UDAWDisplayVersionString));
    Append(tagsBody, SimpleTag('WEBSITE', UDAW_MEDIA_WEBSITE));
    tagsEl := Elem(ID_TARGETS, nil);
    Append(tagsEl, tagsBody);
    tagsEl := Elem(ID_TAGS, Elem(ID_TAG, tagsEl));

    seekHead := SeekHeadBytes(0, 0, 0, 0);   // placeholder, same size when patched

    src := TFileStream.Create(AMp4, fmOpenRead or fmShareDenyNone);
    dst := TFileStream.Create(AMkv, fmCreate);
    clusterBytes := TBytesStream.Create;

    dst.WriteBuffer(hdr[0], Length(hdr));
    body := IdBytes(ID_SEGMENT);
    Append(body, SizeBytes8(0));            // patched at the end
    dst.WriteBuffer(body[0], Length(body));
    segDataStart := dst.Position;
    seekHeadPos := dst.Position - segDataStart;
    dst.WriteBuffer(seekHead[0], Length(seekHead));
    infoPos := dst.Position - segDataStart;
    dst.WriteBuffer(info[0], Length(info));
    tracksPos := dst.Position - segDataStart;
    dst.WriteBuffer(tracks[0], Length(tracks));
    tagsPos := dst.Position - segDataStart;
    dst.WriteBuffer(tagsEl[0], Length(tagsEl));

    { ---- samples, interleaved by presentation time ---- }
    vi := 0; ai := 0;
    clusterOpen := False;
    total := vt.Table.SampleCount;
    if at <> nil then Inc(total, at.Table.SampleCount);
    done := 0;
    while (vi < vt.Table.SampleCount) or ((at <> nil) and (ai < at.Table.SampleCount)) do
    begin
      if vi < vt.Table.SampleCount then vTime := VideoTimeMs(vi) else vTime := MaxDouble;
      if (at <> nil) and (ai < at.Table.SampleCount) then aTime := AudioTimeMs(ai) else aTime := MaxDouble;
      takeVideo := vTime <= aTime;
      if takeVideo then
      begin
        sample := vt.Table.Samples[vi];
        tMs := Round(vTime);
        isKey := sample.Sync;
        trackNo := VIDEO_TRACK;
        Inc(vi);
      end
      else
      begin
        sample := at.Table.Samples[ai];
        tMs := Round(aTime);
        isKey := True;
        trackNo := AUDIO_TRACK;
        Inc(ai);
      end;
      if (sample.Size <= 0) or (sample.Offset < 0) or (sample.Offset + sample.Size > src.Size) then
        RaiseUDAW(errIO, MKV_SUBSYS, 'The encoded MP4 has a sample outside the file.');
      SetLength(data, sample.Size);
      src.Position := sample.Offset;
      src.ReadBuffer(data[0], sample.Size);

      if clusterOpen and
         ((tMs - clusterStartMs >= CLUSTER_MAX_MS) or
          (takeVideo and isKey and (tMs - clusterStartMs >= CLUSTER_MIN_KEY_MS))) then
        FlushCluster;
      if not clusterOpen then OpenCluster(tMs, takeVideo and isKey);
      WriteBlock(trackNo, tMs, isKey, data);

      Inc(done);
      if Assigned(AProgress) and (done mod 256 = 0) then AProgress(done / total);
    end;
    FlushCluster;

    { ---- cues ---- }
    cuesPos := dst.Position - segDataStart;
    cuePoints := nil;
    for vi := 0 to High(cues) do
    begin
      body := ElemUInt(ID_CUETRACK, VIDEO_TRACK);
      Append(body, ElemUInt(ID_CUECLUSTERPOS, UInt64(cues[vi].ClusterPos)));
      cueBody := ElemUInt(ID_CUETIME, UInt64(cues[vi].TimeMs));
      Append(cueBody, Elem(ID_CUETRACKPOS, body));
      Append(cuePoints, Elem(ID_CUEPOINT, cueBody));
    end;
    if Length(cuePoints) > 0 then
    begin
      cuePoints := Elem(ID_CUES, cuePoints);
      dst.WriteBuffer(cuePoints[0], Length(cuePoints));
    end
    else
      cuesPos := 0;

    { ---- patch the seek head and the segment size ---- }
    seekHead := SeekHeadBytes(infoPos, tracksPos, tagsPos, cuesPos);
    dst.Position := segDataStart + seekHeadPos;
    dst.WriteBuffer(seekHead[0], Length(seekHead));
    body := SizeBytes8(dst.Size - segDataStart);
    dst.Position := segDataStart - 8;
    dst.WriteBuffer(body[0], 8);
    if Assigned(AProgress) then AProgress(1.0);
  finally
    clusterBytes.Free;
    dst.Free;
    src.Free;
    reader.Free;
  end;
end;

end.
