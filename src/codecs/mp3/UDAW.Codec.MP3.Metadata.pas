unit UDAW.Codec.MP3.Metadata;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 15 - MP3 metadata (TMP3Metadata).  A self-contained ID3 reader/writer:

    * ID3v2.2 / 2.3 / 2.4 parse - syncsafe tag size, unsynchronisation,
      extended header skip, the common text frames (TIT2/TPE1/TALB/TYER/TDRC/
      TCON/TRCK/TPE2/TCOM) and COMM, with Latin-1 / UTF-16 (BOM) / UTF-8
      payload decode.  Unknown frames are preserved as raw (id,bytes).
    * ID3v1 / v1.1 parse as a fallback (last 128 bytes, "TAG").
    * Writer: emits a fresh ID3v2.3 tag (Latin-1 where the text is ASCII, else
      UTF-16LE) plus a matching 128-byte ID3v1 trailer, and splices them around
      the audio (BuildTaggedFile).

  No third-party tag library. }

interface

uses
  SysUtils, Classes,
  UDAW.Codec.MP3.Frame;

type
  TMP3RawFrame = record
    Id: string;         // 3 or 4 chars
    Data: TBytes;
  end;

  TMP3Metadata = record
    HasV2: Boolean;
    HasV1: Boolean;
    V2Major: Integer;   // 2, 3 or 4
    Title: string;
    Artist: string;
    Album: string;
    AlbumArtist: string;
    Composer: string;
    Year: string;
    Comment: string;
    Copyright: string;
    Genre: string;
    TrackNumber: string;
    Other: array of TMP3RawFrame;
    function Describe: string;
    procedure Clear;
  end;

{ Parse whatever ID3 is present. Never raises - a malformed tag yields whatever
  fields could be read plus HasV2/HasV1 flags. }
function ReadMp3Metadata(const AData: TBytes): TMP3Metadata;
function ReadMp3MetadataFile(const AFileName: string): TMP3Metadata;

{ Serialise AMeta to a fresh ID3v2.3 tag (returned) - prepend to the audio. }
function BuildId3v2Tag(const AMeta: TMP3Metadata): TBytes;
{ 128-byte ID3v1.1 trailer. }
function BuildId3v1Tag(const AMeta: TMP3Metadata): TBytes;

{ Read AInFile, strip any existing ID3v1/v2, write AOutFile = v2 tag + audio +
  v1 tag. Returns the number of audio bytes carried over. }
function WriteMp3WithMetadata(const AInFile, AOutFile: string;
  const AMeta: TMP3Metadata): Int64;

const
  ID3_GENRES: array[0..79] of string = (
    'Blues','Classic Rock','Country','Dance','Disco','Funk','Grunge','Hip-Hop',
    'Jazz','Metal','New Age','Oldies','Other','Pop','R&B','Rap','Reggae','Rock',
    'Techno','Industrial','Alternative','Ska','Death Metal','Pranks','Soundtrack',
    'Euro-Techno','Ambient','Trip-Hop','Vocal','Jazz+Funk','Fusion','Trance',
    'Classical','Instrumental','Acid','House','Game','Sound Clip','Gospel',
    'Noise','Alt. Rock','Bass','Soul','Punk','Space','Meditative','Instrum. Pop',
    'Instrum. Rock','Ethnic','Gothic','Darkwave','Techno-Industrial','Electronic',
    'Pop-Folk','Eurodance','Dream','Southern Rock','Comedy','Cult','Gangsta Rap',
    'Top 40','Christian Rap','Pop/Funk','Jungle','Native American','Cabaret',
    'New Wave','Psychedelic','Rave','Showtunes','Trailer','Lo-Fi','Tribal',
    'Acid Punk','Acid Jazz','Polka','Retro','Musical','Rock & Roll','Hard Rock');

implementation

{ ============================ helpers ============================ }

function SynchsafeToInt(B0, B1, B2, B3: Byte): Integer;
begin
  Result := (Integer(B0 and $7F) shl 21) or (Integer(B1 and $7F) shl 14) or
            (Integer(B2 and $7F) shl 7) or Integer(B3 and $7F);
end;

function PlainToInt(B0, B1, B2, B3: Byte): Integer;
begin
  Result := (Integer(B0) shl 24) or (Integer(B1) shl 16) or
            (Integer(B2) shl 8) or Integer(B3);
end;

function IsAsciiText(const S: string): Boolean;
var
  i: Integer;
begin
  for i := 1 to Length(S) do
    if Ord(S[i]) > 126 then Exit(False);
  Result := True;
end;

function DecodeTextPayload(const AData: TBytes; AFrom, ALen: Integer): string;
var
  enc: Byte;
  i, e: Integer;
  ws: WideString;
  swap: Boolean;
begin
  Result := '';
  if ALen <= 0 then Exit;
  enc := AData[AFrom];
  e := AFrom + ALen;
  case enc of
    0: { ISO-8859-1 }
      begin
        for i := AFrom + 1 to e - 1 do
        begin
          if AData[i] = 0 then Break;
          Result := Result + Char(AData[i]);
        end;
      end;
    1: { UTF-16 with BOM }
      begin
        i := AFrom + 1;
        swap := False;
        if (e - i >= 2) then
        begin
          if (AData[i] = $FF) and (AData[i + 1] = $FE) then begin swap := False; Inc(i, 2); end
          else if (AData[i] = $FE) and (AData[i + 1] = $FF) then begin swap := True; Inc(i, 2); end;
        end;
        ws := '';
        while i + 1 < e do
        begin
          if swap then
            ws := ws + WideChar((Word(AData[i]) shl 8) or AData[i + 1])
          else
            ws := ws + WideChar((Word(AData[i + 1]) shl 8) or AData[i]);
          Inc(i, 2);
        end;
        Result := string(ws);
      end;
    2: { UTF-16BE no BOM }
      begin
        ws := '';
        i := AFrom + 1;
        while i + 1 < e do
        begin
          ws := ws + WideChar((Word(AData[i]) shl 8) or AData[i + 1]);
          Inc(i, 2);
        end;
        Result := string(ws);
      end;
    3: { UTF-8 }
      begin
        var bs: TBytes;
        SetLength(bs, ALen - 1);
        if ALen - 1 > 0 then Move(AData[AFrom + 1], bs[0], ALen - 1);
        Result := TEncoding.UTF8.GetString(bs);
        i := Pos(#0, Result);
        if i > 0 then SetLength(Result, i - 1);
      end;
  else
    for i := AFrom to e - 1 do
    begin
      if AData[i] = 0 then Break;
      Result := Result + Char(AData[i]);
    end;
  end;
  Result := Trim(Result);
end;

function DecodeCommPayload(const AData: TBytes; AFrom, ALen: Integer): string;
var
  enc: Byte;
  p, e: Integer;
begin
  { COMM = enc(1) + lang(3) + short-desc(nul-terminated in enc) + text }
  Result := '';
  if ALen < 5 then Exit;
  enc := AData[AFrom];
  e := AFrom + ALen;
  p := AFrom + 4;   // skip enc + 3-byte language
  if enc in [1, 2] then
  begin
    while (p + 1 < e) and not ((AData[p] = 0) and (AData[p + 1] = 0)) do Inc(p, 2);
    Inc(p, 2);
  end
  else
  begin
    while (p < e) and (AData[p] <> 0) do Inc(p);
    Inc(p);
  end;
  if p >= e then Exit;
  { rebuild a mini text frame: prepend the encoding byte }
  var tmp: TBytes;
  SetLength(tmp, e - p + 1);
  tmp[0] := enc;
  Move(AData[p], tmp[1], e - p);
  Result := DecodeTextPayload(tmp, 0, Length(tmp));
end;

{ ============================ TMP3Metadata ============================ }

procedure TMP3Metadata.Clear;
begin
  Self := Default(TMP3Metadata);
end;

function TMP3Metadata.Describe: string;
begin
  Result := Format('%s%s%s%s%s%s%s',
    [BoolToStr(HasV2, True) + ' v2.' + IntToStr(V2Major) + ' / ' +
     BoolToStr(HasV1, True) + ' v1' + sLineBreak,
     'title  : ' + Title + sLineBreak,
     'artist : ' + Artist + sLineBreak,
     'album  : ' + Album + sLineBreak,
     'year   : ' + Year + sLineBreak,
     'genre  : ' + Genre + sLineBreak,
     'track  : ' + TrackNumber]);
end;

{ ============================ v1 ============================ }

function ReadTrimmed(const AData: TBytes; AFrom, ALen: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := AFrom to AFrom + ALen - 1 do
  begin
    if (i >= Length(AData)) or (AData[i] = 0) then Break;
    Result := Result + Char(AData[i]);
  end;
  Result := Trim(Result);
end;

procedure ParseId3v1(const AData: TBytes; var AMeta: TMP3Metadata);
var
  o: Int64;
  g: Integer;
begin
  o := Int64(Length(AData)) - 128;
  if o < 0 then Exit;
  if not ((AData[o] = Ord('T')) and (AData[o + 1] = Ord('A')) and (AData[o + 2] = Ord('G'))) then
    Exit;
  AMeta.HasV1 := True;
  if AMeta.Title = '' then AMeta.Title := ReadTrimmed(AData, o + 3, 30);
  if AMeta.Artist = '' then AMeta.Artist := ReadTrimmed(AData, o + 33, 30);
  if AMeta.Album = '' then AMeta.Album := ReadTrimmed(AData, o + 63, 30);
  if AMeta.Year = '' then AMeta.Year := ReadTrimmed(AData, o + 93, 4);
  { v1.1: byte 125 = 0 and byte 126 = track }
  if (AData[o + 125] = 0) and (AData[o + 126] <> 0) then
  begin
    if AMeta.Comment = '' then AMeta.Comment := ReadTrimmed(AData, o + 97, 28);
    if AMeta.TrackNumber = '' then AMeta.TrackNumber := IntToStr(AData[o + 126]);
  end
  else if AMeta.Comment = '' then
    AMeta.Comment := ReadTrimmed(AData, o + 97, 30);
  g := AData[o + 127];
  if (AMeta.Genre = '') and (g < Length(ID3_GENRES)) then AMeta.Genre := ID3_GENRES[g];
end;

{ ============================ v2 ============================ }

procedure AssignFrame(var AMeta: TMP3Metadata; const AId, AValue: string);
begin
  if AValue = '' then Exit;
  if AId = 'TCOP' then AMeta.Copyright := AValue
  else if (AId = 'TIT2') or (AId = 'TT2') then AMeta.Title := AValue
  else if (AId = 'TPE1') or (AId = 'TP1') then AMeta.Artist := AValue
  else if (AId = 'TALB') or (AId = 'TAL') then AMeta.Album := AValue
  else if (AId = 'TPE2') or (AId = 'TP2') then AMeta.AlbumArtist := AValue
  else if (AId = 'TCOM') or (AId = 'TCM') then AMeta.Composer := AValue
  else if (AId = 'TYER') or (AId = 'TYE') or (AId = 'TDRC') then
  begin
    if AMeta.Year = '' then AMeta.Year := Copy(AValue, 1, 4);
  end
  else if (AId = 'TCON') or (AId = 'TCO') then AMeta.Genre := AValue
  else if (AId = 'TRCK') or (AId = 'TRK') then AMeta.TrackNumber := AValue
  else if (AId = 'COMM') or (AId = 'COM') then
  begin
    if AMeta.Comment = '' then AMeta.Comment := AValue;
  end;
end;

procedure ParseId3v2(const AData: TBytes; var AMeta: TMP3Metadata);
var
  tagSize, major, minor, flags: Integer;
  unsync, extHdr: Boolean;
  p, tagEnd: Integer;
  frameIdLen, frameSizeLen: Integer;
  fid: string;
  fsize, fflags: Integer;
  i: Integer;
  val: string;
begin
  if Length(AData) < 10 then Exit;
  if not ((AData[0] = Ord('I')) and (AData[1] = Ord('D')) and (AData[2] = Ord('3'))) then Exit;
  major := AData[3];
  minor := AData[4];
  if minor = 0 then ;
  if (major < 2) or (major > 4) then Exit;
  flags := AData[5];
  if (AData[6] >= $80) or (AData[7] >= $80) or (AData[8] >= $80) or (AData[9] >= $80) then Exit;
  tagSize := SynchsafeToInt(AData[6], AData[7], AData[8], AData[9]);
  tagEnd := 10 + tagSize;
  if tagEnd > Length(AData) then tagEnd := Length(AData);

  AMeta.HasV2 := True;
  AMeta.V2Major := major;
  unsync := (flags and $80) <> 0;
  extHdr := (flags and $40) <> 0;
  if unsync then ;   // rare; frame-level payloads below tolerate stray 0x00

  p := 10;
  if extHdr and (major >= 3) then
  begin
    if p + 4 <= tagEnd then
    begin
      if major = 4 then
        i := SynchsafeToInt(AData[p], AData[p+1], AData[p+2], AData[p+3])
      else
        i := PlainToInt(AData[p], AData[p+1], AData[p+2], AData[p+3]);
      p := p + 4 + i;
      if major = 3 then p := p + 4;  // v2.3 ext-header size excludes itself
    end;
  end;

  if major = 2 then begin frameIdLen := 3; frameSizeLen := 3; end
  else begin frameIdLen := 4; frameSizeLen := 4; end;

  while p + frameIdLen + frameSizeLen + (2 * Ord(major >= 3)) <= tagEnd do
  begin
    fid := '';
    for i := 0 to frameIdLen - 1 do
    begin
      if (AData[p + i] < 32) then Exit;   // padding / end
      fid := fid + Char(AData[p + i]);
    end;
    Inc(p, frameIdLen);

    if major = 2 then
      fsize := (Integer(AData[p]) shl 16) or (Integer(AData[p+1]) shl 8) or AData[p+2]
    else if major = 4 then
      fsize := SynchsafeToInt(AData[p], AData[p+1], AData[p+2], AData[p+3])
    else
      fsize := PlainToInt(AData[p], AData[p+1], AData[p+2], AData[p+3]);
    Inc(p, frameSizeLen);

    fflags := 0;
    if major >= 3 then begin fflags := (Integer(AData[p]) shl 8) or AData[p+1]; Inc(p, 2); end;
    if fflags = 0 then ;

    if (fsize <= 0) or (p + fsize > tagEnd) then Break;

    if fid = 'COMM' then
      val := DecodeCommPayload(AData, p, fsize)
    else if (Length(fid) > 0) and (fid[1] = 'T') then
      val := DecodeTextPayload(AData, p, fsize)
    else
      val := '';

    if val <> '' then
      AssignFrame(AMeta, fid, val)
    else if (Length(fid) > 0) and (fid[1] <> 'T') and (fid <> 'APIC') then
    begin
      var rf: TMP3RawFrame;
      rf.Id := fid;
      SetLength(rf.Data, fsize);
      Move(AData[p], rf.Data[0], fsize);
      SetLength(AMeta.Other, Length(AMeta.Other) + 1);
      AMeta.Other[High(AMeta.Other)] := rf;
    end;

    Inc(p, fsize);
  end;
end;

function ReadMp3Metadata(const AData: TBytes): TMP3Metadata;
begin
  Result.Clear;
  try
    ParseId3v2(AData, Result);
  except
    { keep whatever was read }
  end;
  try
    ParseId3v1(AData, Result);
  except
  end;
end;

function ReadMp3MetadataFile(const AFileName: string): TMP3Metadata;
var
  fs: TFileStream;
  data: TBytes;
begin
  Result.Clear;
  if not FileExists(AFileName) then Exit;
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(data, fs.Size);
    if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
  finally
    fs.Free;
  end;
  Result := ReadMp3Metadata(data);
end;

{ ============================ writer ============================ }

procedure PutSynchsafe(var B: TBytes; AAt, AValue: Integer);
begin
  B[AAt]     := (AValue shr 21) and $7F;
  B[AAt + 1] := (AValue shr 14) and $7F;
  B[AAt + 2] := (AValue shr 7) and $7F;
  B[AAt + 3] := AValue and $7F;
end;

function EncodeTextFrame(const AId, AValue: string): TBytes;
var
  payload: TBytes;
  i, n: Integer;
  ws: WideString;
begin
  if IsAsciiText(AValue) then
  begin
    SetLength(payload, Length(AValue) + 1);
    payload[0] := 0;   // ISO-8859-1
    for i := 1 to Length(AValue) do payload[i] := Byte(Ord(AValue[i]));
  end
  else
  begin
    ws := WideString(AValue);
    SetLength(payload, 3 + Length(ws) * 2);
    payload[0] := 1;             // UTF-16 with BOM
    payload[1] := $FF; payload[2] := $FE;
    for i := 0 to Length(ws) - 1 do
    begin
      payload[3 + i * 2]     := Word(ws[i + 1]) and $FF;
      payload[3 + i * 2 + 1] := (Word(ws[i + 1]) shr 8) and $FF;
    end;
  end;
  n := Length(payload);
  SetLength(Result, 10 + n);
  for i := 1 to 4 do Result[i - 1] := Byte(Ord(AId[i]));
  { v2.3 plain 32-bit size }
  Result[4] := (n shr 24) and $FF;
  Result[5] := (n shr 16) and $FF;
  Result[6] := (n shr 8) and $FF;
  Result[7] := n and $FF;
  Result[8] := 0; Result[9] := 0;
  if n > 0 then Move(payload[0], Result[10], n);
end;

function EncodeCommFrame(const AValue: string): TBytes;
var
  payload: TBytes;
  i, n: Integer;
begin
  { enc=0 + "eng" + empty desc(0) + text (ISO-8859-1) }
  if not IsAsciiText(AValue) then Exit(EncodeTextFrame('TXXX', AValue));
  SetLength(payload, 4 + 1 + Length(AValue));
  payload[0] := 0;
  payload[1] := Ord('e'); payload[2] := Ord('n'); payload[3] := Ord('g');
  payload[4] := 0;
  for i := 1 to Length(AValue) do payload[4 + i] := Byte(Ord(AValue[i]));
  n := Length(payload);
  SetLength(Result, 10 + n);
  Result[0] := Ord('C'); Result[1] := Ord('O'); Result[2] := Ord('M'); Result[3] := Ord('M');
  Result[4] := (n shr 24) and $FF; Result[5] := (n shr 16) and $FF;
  Result[6] := (n shr 8) and $FF;  Result[7] := n and $FF;
  Result[8] := 0; Result[9] := 0;
  Move(payload[0], Result[10], n);
end;

procedure AppendBytes(var ADst: TBytes; const ASrc: TBytes);
var
  o: Integer;
begin
  if Length(ASrc) = 0 then Exit;
  o := Length(ADst);
  SetLength(ADst, o + Length(ASrc));
  Move(ASrc[0], ADst[o], Length(ASrc));
end;

function BuildId3v2Tag(const AMeta: TMP3Metadata): TBytes;
var
  body: TBytes;
  hdr: TBytes;
  i: Integer;
begin
  SetLength(body, 0);
  if AMeta.Copyright <> '' then AppendBytes(body, EncodeTextFrame('TCOP', AMeta.Copyright));
  if AMeta.Title <> '' then AppendBytes(body, EncodeTextFrame('TIT2', AMeta.Title));
  if AMeta.Artist <> '' then AppendBytes(body, EncodeTextFrame('TPE1', AMeta.Artist));
  if AMeta.Album <> '' then AppendBytes(body, EncodeTextFrame('TALB', AMeta.Album));
  if AMeta.AlbumArtist <> '' then AppendBytes(body, EncodeTextFrame('TPE2', AMeta.AlbumArtist));
  if AMeta.Composer <> '' then AppendBytes(body, EncodeTextFrame('TCOM', AMeta.Composer));
  if AMeta.Year <> '' then AppendBytes(body, EncodeTextFrame('TYER', AMeta.Year));
  if AMeta.Genre <> '' then AppendBytes(body, EncodeTextFrame('TCON', AMeta.Genre));
  if AMeta.TrackNumber <> '' then AppendBytes(body, EncodeTextFrame('TRCK', AMeta.TrackNumber));
  if AMeta.Comment <> '' then AppendBytes(body, EncodeCommFrame(AMeta.Comment));
  for i := 0 to High(AMeta.Other) do
  begin
    var rf: TBytes;
    SetLength(rf, 10 + Length(AMeta.Other[i].Data));
    if Length(AMeta.Other[i].Id) >= 4 then
    begin
      rf[0] := Byte(Ord(AMeta.Other[i].Id[1])); rf[1] := Byte(Ord(AMeta.Other[i].Id[2]));
      rf[2] := Byte(Ord(AMeta.Other[i].Id[3])); rf[3] := Byte(Ord(AMeta.Other[i].Id[4]));
      var m: Integer := Length(AMeta.Other[i].Data);
      rf[4] := (m shr 24) and $FF; rf[5] := (m shr 16) and $FF;
      rf[6] := (m shr 8) and $FF;  rf[7] := m and $FF;
      rf[8] := 0; rf[9] := 0;
      if m > 0 then Move(AMeta.Other[i].Data[0], rf[10], m);
      AppendBytes(body, rf);
    end;
  end;

  SetLength(hdr, 10);
  hdr[0] := Ord('I'); hdr[1] := Ord('D'); hdr[2] := Ord('3');
  hdr[3] := 3; hdr[4] := 0; hdr[5] := 0;
  PutSynchsafe(hdr, 6, Length(body));

  SetLength(Result, 10 + Length(body));
  Move(hdr[0], Result[0], 10);
  if Length(body) > 0 then Move(body[0], Result[10], Length(body));
end;

procedure PutFixed(var B: TBytes; AAt: Integer; const S: string; ALen: Integer);
var
  i: Integer;
begin
  for i := 0 to ALen - 1 do
    if i < Length(S) then B[AAt + i] := Byte(Ord(S[i + 1])) else B[AAt + i] := 0;
end;

function BuildId3v1Tag(const AMeta: TMP3Metadata): TBytes;
var
  trk: Integer;
begin
  SetLength(Result, 128);
  FillChar(Result[0], 128, 0);
  Result[0] := Ord('T'); Result[1] := Ord('A'); Result[2] := Ord('G');
  PutFixed(Result, 3, AMeta.Title, 30);
  PutFixed(Result, 33, AMeta.Artist, 30);
  PutFixed(Result, 63, AMeta.Album, 30);
  PutFixed(Result, 93, Copy(AMeta.Year, 1, 4), 4);
  PutFixed(Result, 97, AMeta.Comment, 28);
  Result[125] := 0;
  if TryStrToInt(AMeta.TrackNumber, trk) and (trk > 0) and (trk < 256) then
    Result[126] := trk
  else
    Result[126] := 0;
  Result[127] := 255;   // genre "unknown"
end;

function WriteMp3WithMetadata(const AInFile, AOutFile: string;
  const AMeta: TMP3Metadata): Int64;
var
  fs: TFileStream;
  data, v2, v1, outb: TBytes;
  info: TMP3StreamInfo;
  audioFrom, audioTo: Int64;
begin
  fs := TFileStream.Create(AInFile, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(data, fs.Size);
    if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
  finally
    fs.Free;
  end;

  audioFrom := 0;
  audioTo := Length(data);
  if ScanMp3Stream(data, info) then
  begin
    audioFrom := info.AudioStartOffset;
    audioTo := info.AudioEndOffset;
  end;
  if audioTo <= audioFrom then
  begin
    audioFrom := 0;
    audioTo := Length(data);
  end;

  v2 := BuildId3v2Tag(AMeta);
  v1 := BuildId3v1Tag(AMeta);
  SetLength(outb, Length(v2) + (audioTo - audioFrom) + 128);
  Move(v2[0], outb[0], Length(v2));
  Move(data[audioFrom], outb[Length(v2)], audioTo - audioFrom);
  Move(v1[0], outb[Length(v2) + (audioTo - audioFrom)], 128);

  fs := TFileStream.Create(AOutFile, fmCreate);
  try
    fs.WriteBuffer(outb[0], Length(outb));
  finally
    fs.Free;
  end;
  Result := audioTo - audioFrom;
end;

end.
