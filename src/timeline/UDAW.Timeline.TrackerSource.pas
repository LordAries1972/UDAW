unit UDAW.Timeline.TrackerSource;

{ Tracker modules (MOD / XM / IT / MPTM) as Timeline clip sources.

  A clip whose source file is a module plays that module: the song is rendered
  once (looping off) at TRACKER_SOURCE_RATE and kept in the cache folder, keyed
  by the file's path, size and date so editing or replacing the module renders
  it again. Everything downstream (waveform, playback, export) then treats it
  like any other audio source.

  A module has its own tempo (BPM + speed). TrackerMusicalBpm turns that into
  the usual beats-per-minute figure so the clip's Source BPM can be set to it
  and the Timeline's tempo conforming brings the module in line with the
  project tempo (and its tempo changes). }

interface

uses
  SysUtils, Classes, UDAW.Audio.Types;

const
  TRACKER_SOURCE_RATE = 48000;

{ True when AFileName is a MOD, XM, IT or MPTM module. }
function TrackerSniffFile(const AFileName: string): Boolean;

{ Renders (or loads the cached render of) the module as stereo planar float.
  AMusicalBpm is the module's tempo in beats per minute (4 rows to a beat). }
function TrackerRenderFile(const AFileName: string; out APlanar: TAudioPlanar;
  out AFrames: Integer; out AMusicalBpm: Double): Boolean;

{ Tempo of the module in beats per minute, without rendering it. 0 if unreadable. }
function TrackerFileBpm(const AFileName: string): Double;

type
  { one note of the module laid out in song time (seconds at the module's own tempo) }
  TTrackerDash = record
    StartSec, EndSec: Double;
    Note: Byte;
    Channel: Byte;
  end;

  TTrackerNotation = record
    Dashes: TArray<TTrackerDash>;
    MinNote, MaxNote: Integer;
    Channels: Integer;
    Seconds: Double;
  end;

{ Walks the module's order list once (speed/tempo changes, position jumps and
  pattern breaks honoured, stopping when a row would repeat) and returns every
  note as a timed dash, for drawing the module as notation on the Timeline. }
function TrackerNotationFile(const AFileName: string; out ANotation: TTrackerNotation): Boolean;

implementation

uses
  Math, Generics.Collections, UDAW.Tracker.Types, UDAW.Paths, UDAW.Codec.WAV, UDAW.Tracker.Pattern, UDAW.Tracker.Player,
  UDAW.Codec.ProTracker, UDAW.Codec.XM, UDAW.Codec.MPTM;

const
  MAX_RENDER_MINUTES = 20;

function LoadModule(const AFileName: string): TTrackerModule;
var
  fs: TFileStream;
  data: TBytes;
begin
  Result := nil;
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(data, fs.Size);
    if Length(data) > 0 then fs.ReadBuffer(data[0], Length(data));
  finally
    fs.Free;
  end;
  if FileLooksLikeXm(AFileName) then
    Result := XmToModule(data)
  else if FileLooksLikeMptm(AFileName) then
  begin
    MptmSetSampleFolder(ExtractFilePath(ExpandFileName(AFileName)));
    Result := MptmToModule(data);
  end
  else if FileLooksLikeMod(AFileName) then
    Result := ModToModule(data);
end;

function ModuleBpm(AModule: TTrackerModule): Double;
begin
  if AModule.InitialSpeed < 1 then Exit(0);
  { a row lasts speed * 2.5 / BPM seconds; four rows make a beat }
  Result := AModule.InitialBPM * 6.0 / AModule.InitialSpeed;
end;

function TrackerSniffFile(const AFileName: string): Boolean;
begin
  Result := FileExists(AFileName) and
    (FileLooksLikeXm(AFileName) or FileLooksLikeMptm(AFileName) or FileLooksLikeMod(AFileName));
end;

function TrackerFileBpm(const AFileName: string): Double;
var
  m: TTrackerModule;
begin
  Result := 0;
  try
    m := LoadModule(AFileName);
    if m = nil then Exit;
    try
      Result := ModuleBpm(m);
    finally
      m.Free;
    end;
  except
    Result := 0;
  end;
end;

function TrackerNotationFile(const AFileName: string; out ANotation: TTrackerNotation): Boolean;
var
  m: TTrackerModule;
  pat: TTrackerPattern;
  dashes: TList<TTrackerDash>;
  seen: TDictionary<Integer, Boolean>;
  openAt: array of Double;
  openNote: array of Integer;
  order, row, ch, speed, bpm, jumpOrder, breakRow, nch: Integer;
  t: Double;
  cell: TTrackerCell;
  d: TTrackerDash;

  procedure CloseChannel(AChannel: Integer; AAt: Double);
  begin
    if (AChannel < Length(openNote)) and (openNote[AChannel] > 0) then
    begin
      d.StartSec := openAt[AChannel];
      d.EndSec := Max(AAt, openAt[AChannel] + 0.02);
      d.Note := openNote[AChannel];
      d.Channel := AChannel;
      dashes.Add(d);
      openNote[AChannel] := 0;
    end;
  end;

begin
  Result := False;
  ANotation.Dashes := nil;
  ANotation.MinNote := 0;
  ANotation.MaxNote := 0;
  ANotation.Channels := 0;
  ANotation.Seconds := 0;
  if not FileExists(AFileName) then Exit;
  m := LoadModule(AFileName);
  if m = nil then Exit;
  dashes := TList<TTrackerDash>.Create;
  seen := TDictionary<Integer, Boolean>.Create;
  try
    nch := 0;
    for order := 0 to m.OrderLength - 1 do
    begin
      pat := m.GetPattern(m.GetOrder(order));
      if (pat <> nil) and (pat.Channels > nch) then nch := pat.Channels;
    end;
    SetLength(openAt, nch);
    SetLength(openNote, nch);
    speed := Max(1, m.InitialSpeed);
    bpm := Max(32, m.InitialBPM);
    t := 0;
    order := 0;
    row := 0;
    ANotation.MinNote := 255;
    while order < m.OrderLength do
    begin
      pat := m.GetPattern(m.GetOrder(order));
      if (pat = nil) or (row >= pat.Rows) then
      begin
        Inc(order);
        row := 0;
        Continue;
      end;
      if seen.ContainsKey(order * 4096 + row) then Break;   // the song loops here
      seen.Add(order * 4096 + row, True);
      jumpOrder := -1;
      breakRow := -1;
      for ch := 0 to pat.Channels - 1 do
      begin
        cell := pat.GetCell(row, ch);
        if (cell.Note >= TRK_NOTE_MIN) and (cell.Note <= TRK_NOTE_MAX) then
        begin
          CloseChannel(ch, t);
          openNote[ch] := cell.Note;
          openAt[ch] := t;
          if cell.Note < ANotation.MinNote then ANotation.MinNote := cell.Note;
          if cell.Note > ANotation.MaxNote then ANotation.MaxNote := cell.Note;
        end
        else if cell.Note = TRK_NOTE_OFF then
          CloseChannel(ch, t);
        case cell.Effect of
          tfxSetSpeed:
            if cell.Param > 0 then
              if cell.Param < $20 then speed := cell.Param
              else bpm := Max(32, cell.Param);
          tfxSetBPM:
            if cell.Param >= 32 then bpm := cell.Param;
          tfxPositionJump: jumpOrder := cell.Param;
          tfxPatternBreak: breakRow := cell.Param;
        end;
      end;
      t := t + speed * 2.5 / bpm;
      if jumpOrder >= 0 then
      begin
        order := jumpOrder;
        row := Max(0, breakRow);
      end
      else if breakRow >= 0 then
      begin
        Inc(order);
        row := breakRow;
      end
      else
        Inc(row);
    end;
    for ch := 0 to nch - 1 do
      CloseChannel(ch, t);
    ANotation.Dashes := dashes.ToArray;
    if ANotation.MinNote > ANotation.MaxNote then
    begin
      ANotation.MinNote := 0;
      ANotation.MaxNote := 0;
    end;
    ANotation.Channels := nch;
    ANotation.Seconds := t;
    Result := Length(ANotation.Dashes) > 0;
  finally
    seen.Free;
    dashes.Free;
    m.Free;
  end;
end;

function CachePathFor(const AFileName: string): string;
var
  stamp: Integer;
  size: Int64;
  sr: TSearchRec;
  key: Cardinal;
  i: Integer;
  id: string;
begin
  size := 0;
  stamp := 0;
  if FindFirst(AFileName, faAnyFile, sr) = 0 then
  begin
    size := sr.Size;
    stamp := Trunc(sr.TimeStamp * 86400) mod MaxInt;
    FindClose(sr);
  end;
  id := LowerCase(ExpandFileName(AFileName)) + '|' + IntToStr(size) + '|' + IntToStr(stamp);
  key := 2166136261;
  for i := 1 to Length(id) do
    key := Cardinal((UInt64(key xor Cardinal(Ord(id[i]))) * 16777619) and $FFFFFFFF);
  Result := IncludeTrailingPathDelimiter(CacheFile('trackerclips')) +
    ChangeFileExt(ExtractFileName(AFileName), '') + '-' + IntToHex(key, 8) + '.wav';
end;

function TrackerRenderFile(const AFileName: string; out APlanar: TAudioPlanar;
  out AFrames: Integer; out AMusicalBpm: Double): Boolean;
var
  m: TTrackerModule;
  p: TTrackerPlayer;
  cachePath: string;
  ch, sr, i, n: Integer;
  peak, v, scale: Single;
begin
  Result := False;
  AFrames := 0;
  AMusicalBpm := 0;
  APlanar := nil;
  if not FileExists(AFileName) then Exit;
  m := LoadModule(AFileName);
  if m = nil then Exit;
  try
    AMusicalBpm := ModuleBpm(m);
    cachePath := CachePathFor(AFileName);
    if FileExists(cachePath) then
    begin
      APlanar := LoadWavFile(cachePath, ch, sr);
      if (ch > 0) and (Length(APlanar[0]) > 0) then
      begin
        AFrames := Length(APlanar[0]);
        Exit(True);
      end;
    end;

    p := TTrackerPlayer.Create(m);
    try
      p.Prepare(TRACKER_SOURCE_RATE, 1024, 2);
      APlanar := p.RenderSongToPlanar(TRACKER_SOURCE_RATE * 60 * MAX_RENDER_MINUTES, 2, 1024);
    finally
      p.Free;
    end;
    if Length(APlanar) = 0 then Exit;
    AFrames := Length(APlanar[0]);
    if AFrames < 1 then Exit;

    { channels sum at unity gain; bring a hot render under full scale }
    peak := 0;
    for ch := 0 to High(APlanar) do
      for i := 0 to AFrames - 1 do
      begin
        v := Abs(APlanar[ch][i]);
        if v > peak then peak := v;
      end;
    if peak > 0.999 then
    begin
      scale := 0.999 / peak;
      for ch := 0 to High(APlanar) do
        for i := 0 to AFrames - 1 do
          APlanar[ch][i] := APlanar[ch][i] * scale;
    end;

    try
      ForceDirectories(ExtractFilePath(cachePath));
      SaveWavFile(cachePath, APlanar, Length(APlanar), TRACKER_SOURCE_RATE, AFrames);
    except
      { an unwritable cache only costs a re-render next time }
    end;
    n := AFrames;
    Result := n > 0;
  finally
    m.Free;
  end;
end;

end.
