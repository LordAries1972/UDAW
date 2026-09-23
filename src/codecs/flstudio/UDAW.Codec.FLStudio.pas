unit UDAW.Codec.FLStudio;
{$I udaw.inc}

{ FL Studio Project (.flp) import - Playlist audio-sample clips only.

  Image-Line has never published an FLP specification; this is a clean-room
  implementation against the community reverse-engineering of the format,
  the same approach this project's tracker codecs (MOD/XM/IT-MPTM) and
  from-scratch MP3/AAC codecs use for their own foreign formats. Sources
  consulted for the event-stream shape and the specific IDs/scaling factors
  below (no code copied - every routine here is written from the documented
  field meanings):

    * the archived "FL Studio FLP file format (v11)" community write-up and
      fileformats.archiveteam.org/wiki/Raw_FL_Studio_Project for the overall
      FLhd/FLdt chunk shape and the byte/word/dword/variable-length event ID
      ranges;
    * PyFLP (github.com/demberto/PyFLP, GPL-3 - consulted for field meanings
      only, nothing transliterated) source, specifically:
        - pyflp/_event.py: VarInt is a protobuf-style base-128 varint (7
          data bits per byte, high bit = "more bytes follow", first byte
          holds the LEAST significant 7 bits); text events are ASCII when
          the project's FLVersion < 11.5.0, else null-terminated UTF-16LE;
        - pyflp/project.py: ProjectID.Tempo = DWORD+28 (dword value =
          BPM * 1000); older files instead carry ProjectID._TempoCoarse =
          WORD+2 (integer BPM) and optionally ProjectID._TempoFine =
          WORD+29 (thousandths to add); ProjectID.FLVersion = TEXT+7 = 199,
          always stored as ASCII regardless of the rest of the file, format
          "major.minor.build.revision";
        - pyflp/channel.py: ChannelID.New = WORD (id 64) - starts a new
          channel's event scope, word value = that channel's iid;
          ChannelID.Type = byte id 21 (0 = Sampler, 2 = Native/audio clip,
          3 = Layer, 4 = Instrument, 5 = Automation); ChannelID._Name =
          TEXT (id 192) = channel display name; ChannelID.SamplePath =
          TEXT+4 = id 196 = the referenced sample file's path;
        - pyflp/arrangement.py: ArrangementID.Playlist = DATA+25 = id 233,
          payload is a packed array of fixed-size records - 32 bytes in
          older files, 60 bytes from FL 21 on (detected by the payload
          length being an exact multiple of 60), laid out
            0  position     UInt32LE (ticks)
            4  pattern_base UInt16LE (observed constant 20480)
            6  item_index   UInt16LE
            8  length       UInt32LE (ticks)
            12 track_rvidx  UInt16LE (reversed track index; track 1 is the
                                       highest number seen)
            14 group        UInt16LE
            16..31 (..59)   reserved / start-offset / end-offset / FL21 tail
          item_index <= pattern_base means the block plays back
          CHANNEL #item_index; item_index > pattern_base means it plays
          PATTERN #(item_index - pattern_base).

  Scope: only playlist blocks that resolve to an audio-sample channel
  (a channel carrying a non-empty ChannelID.SamplePath that resolves to a
  real file - see ResolveFlpSamplePath) become TFlpAudioClip entries.
  Pattern blocks and channels with no resolvable sample path are counted,
  never fabricated; see UDAW.Codec.FLStudio.Timeline and
  docs/DAWImport-FLStudio.md for the full supported/unsupported breakdown. }

interface

uses
  SysUtils, StrUtils, Classes, Generics.Collections,
  UDAW.Errors;

const
  FLP_SUBSYS = 'Codec.FLStudio';

type
  TFlpAudioClip = record
    TrackIndex: Integer;       // 0-based; tracks are synthesized from distinct
                                // playlist track slots, ordered top-to-bottom
    TrackName: string;         // 'FL Track N' (FLP carries no reliable stable
                                // track name we can rely on for this pass)
    Name: string;               // channel display name, else the sample's file name
    StartSeconds: Double;
    LengthSeconds: Double;
    ResolvedFilePath: string;
  end;

  TFlpProject = record
    Tempo: Double;              // BPM
    PPQ: Integer;                // ticks per quarter note (from the FLhd header)
    Clips: TArray<TFlpAudioClip>;
  end;

{ Sniffs the 'FLhd' magic at offset 0 - the .flp extension is never trusted. }
function FlpSniffData(const AData: TBytes): Boolean;
function FlpSniffFile(const APath: string): Boolean;

{ Parses an already-loaded .flp byte buffer. AFlpPath is used only for
  sample-path resolution candidates (2)/(3) below (same folder / Samples /
  Audio subfolder as the .flp) - pass '' when there is no real file on disk
  (e.g. a hand-built test fixture); candidate (1), the stored path taken
  literally, still works in that case.

  Returns False only when the file is fundamentally unreadable (bad magic,
  or the header/data chunk cannot be located at all) - AWarnings explains
  why. A structurally valid file that simply has nothing importable (e.g.
  every block is a pattern) still returns True, with an empty Clips array
  and explanatory warnings. }
function FlpParseData(const AData: TBytes; const AFlpPath: string;
  out AProject: TFlpProject; out AWarnings: TArray<string>): Boolean;

{ Reads APath and calls FlpParseData. Raises on I/O failure (missing file);
  parse-level problems always come back through AWarnings, never an
  exception. }
function FlpParseFile(const APath: string; out AProject: TFlpProject;
  out AWarnings: TArray<string>): Boolean;

{ Sample-path resolution, exposed for testing:
    1. the path exactly as stored, if it exists on disk;
    2. the same file name next to the .flp file itself;
    3. the same file name in a Samples/ or Audio/ subfolder next to the .flp.
  Returns '' if none of the three resolve. }
function ResolveFlpSamplePath(const AStoredPath, AFlpPath: string): string;

implementation

const
  FLP_HDR_MAGIC = 'FLhd';
  FLP_DATA_MAGIC = 'FLdt';

  EVT_BYTE_MAX  = 63;   // 0..63   -> 1-byte payload
  EVT_WORD_MAX  = 127;  // 64..127 -> 2-byte payload
  EVT_DWORD_MAX = 191;  // 128..191 -> 4-byte payload
                          // 192..255 -> varint length + payload

  EVT_NEW_CHAN      = 64;         // WORD:  value = channel iid
  EVT_NEW_PAT       = 65;         // WORD:  new pattern scope (value = pattern iid-ish)
  EVT_TEMPO_COARSE  = 64 + 2;     // WORD:  integer BPM (older files)
  EVT_TEMPO_FINE    = 64 + 29;    // WORD:  BPM fraction * 1000 (older files)
  EVT_CHAN_TYPE     = 21;         // BYTE:  ChannelType (0 = Sampler)
  EVT_TEMPO_DWORD   = 128 + 28;   // DWORD: BPM * 1000 (modern files)
  EVT_TEXT_NAME     = 192;        // VAR:   channel/pattern display name
  EVT_TEXT_SAMPLE   = 192 + 4;    // VAR:   sample file path (196)
  EVT_TEXT_VERSION  = 192 + 7;    // VAR:   FL Studio save version, always ASCII (199)
  EVT_PLAYLIST      = 208 + 25;   // VAR:   playlist item array (233)

  PLAYLIST_REC_OLD = 32;
  PLAYLIST_REC_NEW = 60;

  FLP_DEFAULT_TEMPO = 140.0;
  FLP_DEFAULT_PPQ   = 96;
  FLP_MIN_TEMPO     = 10.0;
  FLP_MAX_TEMPO     = 999.0;

type
  TFlpChannelInfo = record
    Seen: Boolean;
    TypeByte: Integer;          // -1 = not seen
    NameRaw: TBytes;
    HasSamplePath: Boolean;
    SamplePathRaw: TBytes;
  end;

  TFlpPlaylistItem = record
    Position: Cardinal;
    PatternBase: Word;
    ItemIndex: Word;
    LengthTicks: Cardinal;
    TrackRvIdx: Word;
  end;

procedure AddWarning(var AWarnings: TArray<string>; const AMsg: string);
begin
  SetLength(AWarnings, Length(AWarnings) + 1);
  AWarnings[High(AWarnings)] := AMsg;
end;

{ ---- bounds-checked little-endian scalar reads ---- }

function LEU16(const B: TBytes; AOfs: Int64): Word; inline;
begin
  Result := Word(B[AOfs]) or (Word(B[AOfs + 1]) shl 8);
end;

function LEU32(const B: TBytes; AOfs: Int64): Cardinal; inline;
begin
  Result := Cardinal(B[AOfs]) or (Cardinal(B[AOfs + 1]) shl 8) or
    (Cardinal(B[AOfs + 2]) shl 16) or (Cardinal(B[AOfs + 3]) shl 24);
end;

function LES16(const B: TBytes; AOfs: Int64): SmallInt; inline;
begin
  Result := SmallInt(LEU16(B, AOfs));
end;

{ Protobuf-style base-128 varint: 7 payload bits per byte, high bit = more
  bytes follow, first byte holds the LEAST significant 7 bits. }
function ReadFlpVarInt(const AData: TBytes; var APos: Int64; AEnd: Int64;
  out AValue: Cardinal): Boolean;
var
  shift: Integer;
  b: Byte;
begin
  AValue := 0;
  shift := 0;
  while APos < AEnd do
  begin
    b := AData[APos];
    Inc(APos);
    AValue := AValue or (Cardinal(b and $7F) shl shift);
    Inc(shift, 7);
    if (b and $80) = 0 then Exit(True);
    if shift >= 35 then Exit(False);   // pathological / corrupt stream
  end;
  Result := False;   // ran out of bytes before a terminal byte
end;

function DecodeAsciiZ(const ARaw: TBytes): string;
var
  i: Integer;
  c: Byte;
begin
  Result := '';
  for i := 0 to High(ARaw) do
  begin
    c := ARaw[i];
    if c = 0 then Break;
    Result := Result + Chr(c);
  end;
end;

function DecodeUtf16LEZ(const ARaw: TBytes): string;
var
  i, n: Integer;
  c: Word;
begin
  Result := '';
  n := Length(ARaw) div 2;
  for i := 0 to n - 1 do
  begin
    c := Word(ARaw[i * 2]) or (Word(ARaw[i * 2 + 1]) shl 8);
    if c = 0 then Break;
    Result := Result + Chr(c);
  end;
end;

{ ---- sniffing ---- }

function MagicAt(const AData: TBytes; AOfs: Integer; const AMagic: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if AOfs + Length(AMagic) > Length(AData) then Exit;
  for i := 1 to Length(AMagic) do
    if Chr(AData[AOfs + i - 1]) <> AMagic[i] then Exit;
  Result := True;
end;

function FlpSniffData(const AData: TBytes): Boolean;
begin
  Result := MagicAt(AData, 0, FLP_HDR_MAGIC);
end;

function FlpSniffFile(const APath: string): Boolean;
var
  fs: TFileStream;
  head: TBytes;
  n: Integer;
begin
  Result := False;
  if not FileExists(APath) then Exit;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(head, 4);
    n := fs.Read(head[0], 4);
    if n < 4 then Exit;
    Result := FlpSniffData(head);
  finally
    fs.Free;
  end;
end;

{ ---- sample path resolution ---- }

function TryResolve(const APath: string): string;
begin
  if (APath <> '') and FileExists(APath) then
    Result := APath
  else
    Result := '';
end;

function ResolveFlpSamplePath(const AStoredPath, AFlpPath: string): string;
var
  baseDir, fname, candidate: string;
begin
  Result := '';
  if AStoredPath = '' then Exit;

  { (1) the path exactly as stored }
  Result := TryResolve(AStoredPath);
  if Result <> '' then Exit;

  fname := ExtractFileName(AStoredPath);
  if fname = '' then Exit;
  baseDir := ExtractFilePath(AFlpPath);
  if baseDir = '' then Exit;

  { (2) same file name next to the .flp itself }
  candidate := IncludeTrailingPathDelimiter(baseDir) + fname;
  Result := TryResolve(candidate);
  if Result <> '' then Exit;

  { (3) same file name under a Samples/ or Audio/ subfolder next to the .flp }
  candidate := IncludeTrailingPathDelimiter(baseDir) + 'Samples' +
    PathDelim + fname;
  Result := TryResolve(candidate);
  if Result <> '' then Exit;

  candidate := IncludeTrailingPathDelimiter(baseDir) + 'Audio' +
    PathDelim + fname;
  Result := TryResolve(candidate);
end;

{ ---- event-stream parse ---- }

function FlpParseData(const AData: TBytes; const AFlpPath: string;
  out AProject: TFlpProject; out AWarnings: TArray<string>): Boolean;
var
  hdrLen: Cardinal;
  ppq: SmallInt;
  dataOfs, dataLen, dataEnd, pos: Int64;
  id: Byte;
  wVal: Word;
  dVal: Cardinal;
  varLen: Cardinal;
  raw: TBytes;
  curChanIid: Integer;
  channels: TDictionary<Integer, TFlpChannelInfo>;
  ch: TFlpChannelInfo;
  tempoDword, tempoCoarse, tempoFine: Integer;   // -1 = not present
  flVersionRaw: TBytes;
  flVersionMajor, flVersionMinor: Integer;
  useUnicode: Boolean;
  items: TArray<TFlpPlaylistItem>;
  itemCount: Integer;

  procedure AppendPlaylistPayload(const APayload: TBytes);
  var
    recSize, n, i, base: Integer;
    it: TFlpPlaylistItem;
  begin
    if Length(APayload) = 0 then Exit;
    if (Length(APayload) mod PLAYLIST_REC_NEW) = 0 then
      recSize := PLAYLIST_REC_NEW
    else
      recSize := PLAYLIST_REC_OLD;
    n := Length(APayload) div recSize;
    for i := 0 to n - 1 do
    begin
      base := i * recSize;
      if base + 16 > Length(APayload) then Break;    // defensive, shouldn't happen
      it.Position := LEU32(APayload, base + 0);
      it.PatternBase := LEU16(APayload, base + 4);
      it.ItemIndex := LEU16(APayload, base + 6);
      it.LengthTicks := LEU32(APayload, base + 8);
      it.TrackRvIdx := LEU16(APayload, base + 12);
      SetLength(items, itemCount + 1);
      items[itemCount] := it;
      Inc(itemCount);
    end;
  end;

  function ParseFlVersion(const AVersion: string; out AMajor, AMinor: Integer): Boolean;
  var
    parts: TArray<string>;
  begin
    AMajor := 0; AMinor := 0;
    parts := AVersion.Split(['.']);
    Result := Length(parts) >= 2;
    if not Result then Exit;
    if not TryStrToInt(parts[0], AMajor) then Exit(False);
    if not TryStrToInt(parts[1], AMinor) then Exit(False);
  end;

var
  distinctTracks: TArray<Word>;

  procedure NoteDistinctTrack(ATrackRvIdx: Word);
  var
    i: Integer;
  begin
    for i := 0 to High(distinctTracks) do
      if distinctTracks[i] = ATrackRvIdx then Exit;
    SetLength(distinctTracks, Length(distinctTracks) + 1);
    distinctTracks[High(distinctTracks)] := ATrackRvIdx;
  end;

  function TrackIndexOf(ATrackRvIdx: Word): Integer;
  var
    i: Integer;
  begin
    { descending rvidx order: FL stores track 1 (top) as the HIGHEST rvidx
      seen, so sorting descending and taking position gives a stable,
      top-to-bottom-ish track ordering without needing the exact FL
      max-track-count constant this pass has no other use for. }
    Result := 0;
    for i := 0 to High(distinctTracks) do
      if distinctTracks[i] = ATrackRvIdx then Exit(i);
  end;

var
  i, j: Integer;
  tmpW: Word;
  clips: TArray<TFlpAudioClip>;
  clipCount: Integer;
  skippedPatternOrInstr: Integer;
  skippedUnresolvedSample: Integer;
  storedPath, resolved, dispName: string;
  secondsPerTick: Double;
  clip: TFlpAudioClip;
begin
  SetLength(AWarnings, 0);
  FillChar(AProject, SizeOf(AProject), 0);
  Result := False;

  if not FlpSniffData(AData) then
  begin
    AddWarning(AWarnings, 'not an FLP file: missing ''FLhd'' magic');
    Exit;
  end;
  if Length(AData) < 8 then
  begin
    AddWarning(AWarnings, 'file too short to hold an FLhd header');
    Exit;
  end;

  hdrLen := LEU32(AData, 4);
  if (hdrLen < 6) or (8 + Int64(hdrLen) + 8 > Length(AData)) then
  begin
    AddWarning(AWarnings, 'FLhd header chunk is truncated or malformed');
    Exit;
  end;

  { offset 8: format (Int16LE) and offset 10: channel count (Int16LE) are read
    by FL Studio but not needed for a playlist-only import - skipped. }
  ppq := SmallInt(LEU16(AData, 12));
  if ppq <= 0 then
  begin
    AddWarning(AWarnings, Format(
      'header PPQ was %d (invalid) - defaulting to %d', [ppq, FLP_DEFAULT_PPQ]));
    ppq := FLP_DEFAULT_PPQ;
  end;

  dataOfs := 8 + hdrLen;
  if (dataOfs + 8 > Length(AData)) or not MagicAt(AData, Integer(dataOfs), FLP_DATA_MAGIC) then
  begin
    AddWarning(AWarnings, '''FLdt'' data chunk not found where the header said it would be');
    Exit;
  end;
  dataLen := LEU32(AData, dataOfs + 4);
  dataOfs := dataOfs + 8;
  dataEnd := dataOfs + dataLen;
  if dataEnd > Length(AData) then
  begin
    AddWarning(AWarnings, 'FLdt chunk length runs past end of file - parsing what is present');
    dataEnd := Length(AData);
  end;

  { -------- pass 1: walk the event stream -------- }
  channels := TDictionary<Integer, TFlpChannelInfo>.Create;
  try
    curChanIid := -1;
    tempoDword := -1;
    tempoCoarse := -1;
    tempoFine := -1;
    SetLength(flVersionRaw, 0);
    itemCount := 0;
    pos := dataOfs;

    while pos < dataEnd do
    begin
      id := AData[pos];
      Inc(pos);

      if id <= EVT_BYTE_MAX then
      begin
        if pos >= dataEnd then Break;
        if (id = EVT_CHAN_TYPE) and (curChanIid >= 0) and channels.TryGetValue(curChanIid, ch) then
        begin
          ch.TypeByte := AData[pos];
          channels.AddOrSetValue(curChanIid, ch);
        end;
        Inc(pos);
      end
      else if id <= EVT_WORD_MAX then
      begin
        if pos + 2 > dataEnd then Break;
        wVal := LEU16(AData, pos);
        Inc(pos, 2);
        case id of
          EVT_NEW_CHAN:
            begin
              curChanIid := wVal;
              if not channels.ContainsKey(curChanIid) then
              begin
                ch.Seen := True;
                ch.TypeByte := -1;
                ch.NameRaw := nil;
                ch.HasSamplePath := False;
                ch.SamplePathRaw := nil;
                channels.Add(curChanIid, ch);
              end;
            end;
          EVT_NEW_PAT:
            curChanIid := -1;   // leave channel scope; pattern-name events are
                                 // out of scope for this pass, no need to track it
          EVT_TEMPO_COARSE: tempoCoarse := wVal;
          EVT_TEMPO_FINE: tempoFine := wVal;
        end;
      end
      else if id <= EVT_DWORD_MAX then
      begin
        if pos + 4 > dataEnd then Break;
        dVal := LEU32(AData, pos);
        Inc(pos, 4);
        if id = EVT_TEMPO_DWORD then
          tempoDword := Integer(dVal);
      end
      else
      begin
        if not ReadFlpVarInt(AData, pos, dataEnd, varLen) then Break;
        if pos + Int64(varLen) > dataEnd then
        begin
          AddWarning(AWarnings, 'a variable-length event ran past the end of the data chunk - stopped parsing there');
          Break;
        end;
        SetLength(raw, varLen);
        if varLen > 0 then
          Move(AData[pos], raw[0], varLen);
        pos := pos + Int64(varLen);

        case id of
          EVT_TEXT_NAME:
            if (curChanIid >= 0) and channels.TryGetValue(curChanIid, ch) then
            begin
              ch.NameRaw := raw;
              channels.AddOrSetValue(curChanIid, ch);
            end;
          EVT_TEXT_SAMPLE:
            if (curChanIid >= 0) and channels.TryGetValue(curChanIid, ch) then
            begin
              ch.HasSamplePath := True;
              ch.SamplePathRaw := raw;
              channels.AddOrSetValue(curChanIid, ch);
            end;
          EVT_TEXT_VERSION:
            flVersionRaw := raw;
          EVT_PLAYLIST:
            AppendPlaylistPayload(raw);
        end;
      end;
    end;

    { -------- resolve project-level values -------- }

    if not ParseFlVersion(DecodeAsciiZ(flVersionRaw), flVersionMajor, flVersionMinor) then
    begin
      useUnicode := True;   // safest default for a modern file with no/unreadable version tag
      if Length(flVersionRaw) > 0 then
        AddWarning(AWarnings, 'could not parse the FLVersion event - assuming Unicode (UTF-16) text');
    end
    else
      useUnicode := (flVersionMajor > 11) or ((flVersionMajor = 11) and (flVersionMinor >= 5));

    if tempoDword > 0 then
      AProject.Tempo := tempoDword / 1000.0
    else if tempoCoarse > 0 then
    begin
      AProject.Tempo := tempoCoarse;
      if tempoFine >= 0 then
        AProject.Tempo := AProject.Tempo + tempoFine / 1000.0;
    end
    else
    begin
      AProject.Tempo := FLP_DEFAULT_TEMPO;
      AddWarning(AWarnings, Format(
        'no tempo event found - defaulting to %.1f BPM', [FLP_DEFAULT_TEMPO]));
    end;
    if (AProject.Tempo < FLP_MIN_TEMPO) or (AProject.Tempo > FLP_MAX_TEMPO) then
    begin
      AddWarning(AWarnings, Format(
        'tempo %.3f BPM out of the sane range, clamped to %.1f',
        [AProject.Tempo, FLP_DEFAULT_TEMPO]));
      AProject.Tempo := FLP_DEFAULT_TEMPO;
    end;
    AProject.PPQ := ppq;
    secondsPerTick := 60.0 / (AProject.Tempo * AProject.PPQ);

    { -------- pass 2: classify playlist items -------- }

    SetLength(distinctTracks, 0);
    for i := 0 to itemCount - 1 do
      if items[i].ItemIndex <= items[i].PatternBase then
        if channels.TryGetValue(Integer(items[i].ItemIndex), ch) and ch.HasSamplePath then
          NoteDistinctTrack(items[i].TrackRvIdx);

    { descending sort of distinctTracks (small N, insertion sort is plenty) }
    for i := 1 to High(distinctTracks) do
    begin
      tmpW := distinctTracks[i];
      j := i - 1;
      while (j >= 0) and (distinctTracks[j] < tmpW) do
      begin
        distinctTracks[j + 1] := distinctTracks[j];
        Dec(j);
      end;
      distinctTracks[j + 1] := tmpW;
    end;

    clipCount := 0;
    skippedPatternOrInstr := 0;
    skippedUnresolvedSample := 0;
    SetLength(clips, 0);

    for i := 0 to itemCount - 1 do
    begin
      if items[i].LengthTicks = 0 then
      begin
        AddWarning(AWarnings, Format(
          'playlist block at tick %d has zero length - skipped', [items[i].Position]));
        Continue;
      end;

      if items[i].ItemIndex > items[i].PatternBase then
      begin
        Inc(skippedPatternOrInstr);
        Continue;
      end;

      if not (channels.TryGetValue(Integer(items[i].ItemIndex), ch) and ch.HasSamplePath) then
      begin
        Inc(skippedPatternOrInstr);
        Continue;
      end;

      storedPath := IfThen(useUnicode, DecodeUtf16LEZ(ch.SamplePathRaw),
        DecodeAsciiZ(ch.SamplePathRaw));
      resolved := ResolveFlpSamplePath(storedPath, AFlpPath);
      if resolved = '' then
      begin
        Inc(skippedUnresolvedSample);
        AddWarning(AWarnings, Format(
          'sample "%s" for the playlist block at tick %d could not be resolved - skipped',
          [storedPath, items[i].Position]));
        Continue;
      end;

      dispName := IfThen(useUnicode, DecodeUtf16LEZ(ch.NameRaw), DecodeAsciiZ(ch.NameRaw));
      if dispName = '' then dispName := ExtractFileName(resolved);

      clip.TrackIndex := TrackIndexOf(items[i].TrackRvIdx);
      clip.TrackName := Format('FL Track %d', [clip.TrackIndex + 1]);
      clip.Name := dispName;
      clip.StartSeconds := items[i].Position * secondsPerTick;
      clip.LengthSeconds := items[i].LengthTicks * secondsPerTick;
      clip.ResolvedFilePath := resolved;

      SetLength(clips, clipCount + 1);
      clips[clipCount] := clip;
      Inc(clipCount);
    end;

    if skippedPatternOrInstr > 0 then
      AddWarning(AWarnings, Format(
        '%d pattern/instrument blocks were not imported (MIDI/pattern import not yet supported)',
        [skippedPatternOrInstr]));

    AProject.Clips := clips;
    Result := True;
  finally
    channels.Free;
  end;
end;

function FlpParseFile(const APath: string; out AProject: TFlpProject;
  out AWarnings: TArray<string>): Boolean;
var
  fs: TFileStream;
  data: TBytes;
begin
  if not FileExists(APath) then
    RaiseUDAWFmt(errFileNotFound, FLP_SUBSYS, 'FLP file not found: %s', [APath]);

  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(data, fs.Size);
    if Length(data) > 0 then
      fs.ReadBuffer(data[0], Length(data));
  finally
    fs.Free;
  end;

  Result := FlpParseData(data, APath, AProject, AWarnings);
end;

end.
