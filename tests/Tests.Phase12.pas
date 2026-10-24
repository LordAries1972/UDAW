unit Tests.Phase12;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 12 acceptance tests: MOD support.

  Covers the ProTracker / Soundtracker .MOD reader and writer in
  UDAW.Codec.ProTracker - header sniffing, the 31-sample and 15-sample layouts,
  period <-> note mapping, the full effect-column mapping onto UDAW's
  internal effect set, order table + restart, playback through the Phase 11
  TTrackerPlayer, the 31-sample exporter, byte-level round-tripping and the
  export-representability report.

  Requires src/common, src/audio, src/audio/dsp, src/timeline, src/project,
  src/mixer, src/tracker and src/codecs/tracker on the search path. }

interface

procedure RegisterPhase12Tests;

implementation

uses
  SysUtils, Classes, Math, IOUtils,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Audio.Types,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern,
  UDAW.Tracker.Player,
  UDAW.Project.Document, UDAW.Project.Serialization, UDAW.Project.Commands,
  UDAW.Tracker.Commands,
  UDAW.Codec.ProTracker, UDAW.Timeline.TrackerSource;

const
  SR = 48000;

{ ---------------- small helpers ---------------- }

function DomFreq(const P: TAudioPlanar; ACh, AFrom, ATo: Integer): Double;
var
  i, firstX, lastX, cross: Integer;
  prev, cur: Single;
begin
  Result := 0;
  firstX := -1; lastX := -1; cross := 0;
  if AFrom < 1 then AFrom := 1;
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
  if (cross < 2) or (lastX <= firstX) then Exit;
  Result := (cross - 1) * SR / (lastX - firstX);
end;

function PlanarRms(const P: TAudioPlanar; ACh, AFrom, ATo: Integer): Double;
var
  i: Integer;
  acc: Double;
begin
  acc := 0;
  for i := AFrom to ATo - 1 do
    acc := acc + Sqr(Double(P[ACh][i]));
  if ATo - AFrom <= 0 then Exit(0);
  Result := Sqrt(acc / (ATo - AFrom));
end;

function AllFinitePl(const P: TAudioPlanar): Boolean;
var
  ch, i: Integer;
begin
  for ch := 0 to High(P) do
    for i := 0 to High(P[ch]) do
      if IsNan(P[ch][i]) or IsInfinite(P[ch][i]) then Exit(False);
  Result := True;
end;

{ 8-bit signed sine: ACycles full periods across AByteCount samples }
function SineS8(ACycles, AByteCount: Integer): TBytes;
var
  i, v: Integer;
begin
  SetLength(Result, AByteCount);
  for i := 0 to AByteCount - 1 do
  begin
    v := Round(120.0 * Sin(2 * Pi * ACycles * i / AByteCount));
    if v > 127 then v := 127 else if v < -128 then v := -128;
    Result[i] := Byte(v and $FF);
  end;
end;

type
  TCellSpec = record
    Pat, Row, Chn, NoteIndex, Sample, Cmd, Param: Integer;
  end;

function Spec(APat, ARow, AChn, ANoteIndex, ASample, ACmd, AParam: Integer): TCellSpec;
begin
  Result.Pat := APat; Result.Row := ARow; Result.Chn := AChn;
  Result.NoteIndex := ANoteIndex; Result.Sample := ASample;
  Result.Cmd := ACmd; Result.Param := AParam;
end;

{ Build a 31-sample "M.K." MOD: AChannels channels, ANumPat patterns, one
  sine sample in slot 1 (full-length forward loop), the given order table and
  the given cells. NoteIndex < 0 means "no note". }
function BuildMod31(AChannels, ANumPat: Integer; const AOrder: array of Integer;
  const ACells: array of TCellSpec; ASampleCycles: Integer = 27;
  ASampleBytes: Integer = 512): TBytes;
var
  hdr, patData, pcm: TBytes;
  rowBytes, i, k, si, period, b0, b1, b2, b3: Integer;
  c: TCellSpec;
  st: TBytesStream;
  title: AnsiString;
begin
  SetLength(hdr, 1084);
  FillChar(hdr[0], Length(hdr), 0);
  title := 'PHASE12 TEST';
  for i := 0 to 19 do
    if i < Length(title) then hdr[i] := Byte(title[i + 1]);

  { sample 1 header at offset 20 }
  hdr[20] := Ord('s'); hdr[21] := Ord('i'); hdr[22 - 0] := Ord('n');
  hdr[20 + 22] := (ASampleBytes div 2) shr 8;
  hdr[20 + 23] := (ASampleBytes div 2) and $FF;
  hdr[20 + 24] := 0;             { finetune 0 }
  hdr[20 + 25] := 64;            { volume }
  hdr[20 + 26] := 0; hdr[20 + 27] := 0;             { loop start = 0 }
  hdr[20 + 28] := (ASampleBytes div 2) shr 8;       { loop length = whole }
  hdr[20 + 29] := (ASampleBytes div 2) and $FF;
  { samples 2..31: loop length word = 1 => "no loop", length 0 }
  for k := 2 to 31 do
    hdr[20 + (k - 1) * 30 + 29] := 1;

  hdr[950] := Length(AOrder);
  hdr[951] := 0;                 { restart position }
  for i := 0 to High(AOrder) do
    hdr[952 + i] := Byte(AOrder[i]);
  { format tag - must encode the channel count the reader will use }
  if AChannels = 4 then title := 'M.K.'
  else if (AChannels >= 2) and (AChannels <= 9) then title := AnsiString(IntToStr(AChannels) + 'CHN')
  else title := AnsiString(Format('%.2dCH', [AChannels]));
  for i := 0 to 3 do hdr[1080 + i] := Byte(title[i + 1]);

  rowBytes := AChannels * 4;
  SetLength(patData, ANumPat * 64 * rowBytes);
  FillChar(patData[0], Length(patData), 0);

  for i := 0 to High(ACells) do
  begin
    c := ACells[i];
    si := (c.Pat * 64 + c.Row) * rowBytes + c.Chn * 4;
    if c.NoteIndex >= 0 then
      period := Round(ModNotePeriod(c.NoteIndex, 0))
    else
      period := 0;
    b0 := (c.Sample and $F0) or ((period shr 8) and $0F);
    b1 := period and $FF;
    b2 := ((c.Sample and $0F) shl 4) or (c.Cmd and $0F);
    b3 := c.Param and $FF;
    patData[si] := Byte(b0); patData[si + 1] := Byte(b1);
    patData[si + 2] := Byte(b2); patData[si + 3] := Byte(b3);
  end;

  pcm := SineS8(ASampleCycles, ASampleBytes);

  st := TBytesStream.Create;
  try
    st.WriteBuffer(hdr[0], Length(hdr));
    st.WriteBuffer(patData[0], Length(patData));
    st.WriteBuffer(pcm[0], Length(pcm));
    Result := Copy(st.Bytes, 0, st.Size);
  finally
    st.Free;
  end;
end;

{ ---------------- tests ---------------- }

procedure Test_Sniff_Kinds;
var
  data: TBytes;
  junk: TBytes;
begin
  data := BuildMod31(4, 1, [0], [Spec(0, 0, 0, 12, 1, 0, 0)]);
  Check(DataLooksLikeMod(data), 'generated buffer sniffs as a MOD');
  Check(ModKindFromData(data) = mk31, '31-sample kind');

  SetLength(junk, 4000);
  FillChar(junk[0], Length(junk), 0);
  CheckFalse(DataLooksLikeMod(junk), 'all-zero buffer is not a MOD');
end;

procedure Test_Import_Structure;
var
  data: TBytes;
  info: TModImportInfo;
  m: TTrackerModule;
begin
  data := BuildMod31(6, 3, [0, 1, 2, 1],
    [Spec(0, 0, 0, 12, 1, 0, 0), Spec(1, 0, 0, 0, 1, 0, 0)]);
  m := ModToModule(data, info);
  try
    CheckEqualInt(6, info.Channels, 'channel count from the 6CHN-equivalent layout');
    CheckEqualInt(6, m.Channels, 'module channels');
    CheckEqualInt(3, m.PatternCount, 'pattern count from the order table max + 1');
    CheckEqualInt(4, m.OrderLength, 'order length');
    CheckEqualInt(31, info.SampleCount, '31 sample slots');
    CheckEqualInt(31, m.InstrumentCount, 'one instrument per MOD sample slot');
    CheckEqualInt(MOD_DEFAULT_SPEED, m.InitialSpeed, 'default MOD speed');
    CheckEqualInt(MOD_DEFAULT_BPM, m.InitialBPM, 'default MOD tempo');
    CheckEqualStr('PHASE12 TEST', m.Name, 'song title');
    Check(m.GetInstrument(1).FrameCount = 512, 'sample 1 PCM length (bytes)');
    Check(m.GetInstrument(1).LoopMode = tlmForward, 'whole-sample forward loop');
    CheckEqualInt(49, m.GetPattern(0).GetCell(0, 0).Note, 'reference note index 12 -> C-4 (value 49)');
    CheckEqualInt(1, m.GetPattern(0).GetCell(0, 0).Instrument, 'sample 1 referenced');
  finally
    m.Free;
  end;
end;

procedure Test_Import_15Sample;
var
  buf: TBytes;
  st: TBytesStream;
  hdr, pat, pcm: TBytes;
  i: Integer;
  info: TModImportInfo;
  m: TTrackerModule;
begin
  { 15-sample Soundtracker layout: 20 title + 15*30 headers, songlen@470,
    restart@471, order@472, patterns@600, 4 channels, no tag }
  SetLength(hdr, 600);
  FillChar(hdr[0], Length(hdr), 0);
  hdr[20 + 22] := 0; hdr[20 + 23] := 128;     { sample 1: 128 words = 256 bytes }
  hdr[20 + 25] := 64;                          { volume }
  hdr[20 + 29] := 1;                           { no loop }
  for i := 2 to 15 do hdr[20 + (i - 1) * 30 + 29] := 1;
  hdr[470] := 1;                               { song length }
  hdr[471] := 0;                               { restart }
  hdr[472] := 0;                               { order[0] = pattern 0 }

  SetLength(pat, 64 * 4 * 4);
  FillChar(pat[0], Length(pat), 0);
  pcm := SineS8(10, 256);

  st := TBytesStream.Create;
  try
    st.WriteBuffer(hdr[0], Length(hdr));
    st.WriteBuffer(pat[0], Length(pat));
    st.WriteBuffer(pcm[0], Length(pcm));
    buf := Copy(st.Bytes, 0, st.Size);
  finally
    st.Free;
  end;

  Check(ModKindFromData(buf) = mk15, '15-sample kind detected (no tag)');
  m := ModToModule(buf, info);
  try
    CheckEqualInt(4, m.Channels, '15-sample is always 4 channels');
    CheckEqualInt(15, info.SampleCount, '15 sample slots');
    CheckEqualInt(1, m.PatternCount, 'one pattern');
    Check(m.GetInstrument(1).FrameCount = 256, 'sample 1 length');
  finally
    m.Free;
  end;
end;

procedure Test_Effect_Mapping;
var
  data: TBytes;
  m: TTrackerModule;
  info: TModImportInfo;
  p: TTrackerPattern;

  procedure ExpectFx(ARow: Integer; AEff: TTrackerEffect; AParam: Integer; const AWhat: string);
  var
    cell: TTrackerCell;
  begin
    cell := p.GetCell(ARow, 0);
    Check(cell.Effect = AEff, AWhat + ': effect');
    CheckEqualInt(AParam, cell.Param, AWhat + ': param');
  end;

begin
  data := BuildMod31(1, 1, [0],
    [ Spec(0, 0, 0, -1, 0, $0, $37),     // arpeggio 3/7
      Spec(0, 1, 0, -1, 0, $C, $20),     // set volume 0x20
      Spec(0, 2, 0, -1, 0, $A, $40),     // volume slide (nibble layout matches)
      Spec(0, 3, 0, -1, 0, $D, $12),     // pattern break, BCD 0x12 -> row 12
      Spec(0, 4, 0, -1, 0, $F, $03),     // set speed 3
      Spec(0, 5, 0, -1, 0, $F, $7D),     // set tempo 125
      Spec(0, 6, 0, -1, 0, $E, $C4),     // EC4 note cut on tick 4
      Spec(0, 7, 0, -1, 0, $E, $A3),     // EA3 fine volume up 3
      Spec(0, 8, 0, -1, 0, $E, $30) ]);  // E3x glissando -> no internal equivalent
  m := ModToModule(data, info);
  try
    p := m.GetPattern(0);
    ExpectFx(0, tfxArpeggio, $37, 'arpeggio');
    ExpectFx(1, tfxSetVolume, $20, 'set volume');
    ExpectFx(2, tfxVolSlide, $40, 'volume slide');
    ExpectFx(3, tfxPatternBreak, 12, 'pattern break decodes BCD');
    ExpectFx(4, tfxSetSpeed, $03, 'set speed');
    ExpectFx(5, tfxSetSpeed, $7D, 'set tempo maps to the same F command');
    ExpectFx(6, tfxNoteCut, 4, 'EC note cut');
    ExpectFx(7, tfxFineVolUp, 3, 'EA fine volume up');
    Check(p.GetCell(8, 0).Effect = tfxNone, 'unmapped E3x leaves no effect');
    Check(info.LostEffectCells >= 1, 'the dropped command is counted in the report');
  finally
    m.Free;
  end;
end;

procedure Test_Play_Tone;
var
  data: TBytes;
  m: TTrackerModule;
  pl: TTrackerPlayer;
  o: TAudioPlanar;
begin
  { sine of 27 cycles over 512 bytes, played at the reference note -> the
    sample streams at 8363 Hz, so ~8363*27/512 ~= 441 Hz }
  data := BuildMod31(4, 1, [0], [Spec(0, 0, 0, 12, 1, 0, 0)], 27, 512);
  m := ModToModule(data);
  pl := nil;
  try
    pl := TTrackerPlayer.Create(m);
    pl.LoopSong := True;
    o := pl.RenderToPlanar(SR div 2, 2);
    Check(AllFinitePl(o), 'rendered output is finite');
    Check(PlanarRms(o, 0, SR div 20, Length(o[0])) > 0.03, 'the note produces audio');
    CheckNear(441.0, DomFreq(o, 0, SR div 20, Length(o[0])), 35.0, 'at ~441 Hz');
  finally
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Play_OctaveDown;
var
  hi, lo: TBytes;
  m1, m2: TTrackerModule;
  p1, p2: TTrackerPlayer;
  o1, o2: TAudioPlanar;
  f1, f2: Double;
begin
  hi := BuildMod31(4, 1, [0], [Spec(0, 0, 0, 12, 1, 0, 0)], 27, 512);
  lo := BuildMod31(4, 1, [0], [Spec(0, 0, 0, 0, 1, 0, 0)], 27, 512);
  m1 := ModToModule(hi);
  m2 := ModToModule(lo);
  p1 := nil; p2 := nil;
  try
    p1 := TTrackerPlayer.Create(m1);
    p2 := TTrackerPlayer.Create(m2);
    o1 := p1.RenderToPlanar(SR div 2, 2);
    o2 := p2.RenderToPlanar(SR div 2, 2);
    f1 := DomFreq(o1, 0, SR div 20, Length(o1[0]));
    f2 := DomFreq(o2, 0, SR div 20, Length(o2[0]));
    Check((f1 > 0) and (f2 > 0), 'both render a pitch');
    CheckNear(2.0, f1 / f2, 0.15, 'one octave lower halves the frequency');
  finally
    p1.Free; p2.Free;
    m1.Free; m2.Free;
  end;
end;

procedure Test_Export_RoundTrip;
var
  data, data2: TBytes;
  a, b: TTrackerModule;
  ca, cb: TTrackerCell;
begin
  data := BuildMod31(4, 2, [0, 1],
    [ Spec(0, 0, 0, 12, 1, 0, 0),
      Spec(0, 4, 0, 24, 1, $C, $2A),
      Spec(0, 8, 0, -1, 0, $D, $08),
      Spec(1, 0, 1, 5, 1, $A, $30) ]);
  a := ModToModule(data);
  try
    data2 := ModuleToMod(a);
    Check(DataLooksLikeMod(data2), 're-exported bytes still sniff as a MOD');
    b := ModToModule(data2);
    try
      CheckEqualInt(a.Channels, b.Channels, 'channels survive export');
      CheckEqualInt(a.PatternCount, b.PatternCount, 'pattern count survives');
      CheckEqualInt(a.OrderLength, b.OrderLength, 'order length survives');
      CheckEqualInt(a.InstrumentCount, b.InstrumentCount, 'instrument slots survive');

      ca := a.GetPattern(0).GetCell(0, 0);
      cb := b.GetPattern(0).GetCell(0, 0);
      CheckEqualInt(ca.Note, cb.Note, 'note 0,0 round-trips');
      CheckEqualInt(ca.Instrument, cb.Instrument, 'instrument 0,0 round-trips');

      ca := a.GetPattern(0).GetCell(4, 0);
      cb := b.GetPattern(0).GetCell(4, 0);
      CheckEqualInt(ca.Note, cb.Note, 'note at 4,0 round-trips');
      Check(cb.Effect = tfxSetVolume, 'set-volume effect round-trips');
      CheckEqualInt($2A, cb.Param, 'set-volume param round-trips');

      cb := b.GetPattern(0).GetCell(8, 0);
      Check(cb.Effect = tfxPatternBreak, 'pattern break round-trips');
      CheckEqualInt(8, cb.Param, 'pattern break row round-trips through BCD');

      Check(b.GetInstrument(1).FrameCount = a.GetInstrument(1).FrameCount,
        'sample length round-trips (whole words)');
      CheckNear(a.GetInstrument(1).Volume, b.GetInstrument(1).Volume, 0.02,
        'sample volume round-trips');
    finally
      b.Free;
    end;
  finally
    a.Free;
  end;
end;

procedure Test_Export_SampleData_Approx;
var
  data, data2: TBytes;
  a, b: TTrackerModule;
  i, n: Integer;
  maxErr, e: Double;
begin
  data := BuildMod31(4, 1, [0], [Spec(0, 0, 0, 12, 1, 0, 0)], 8, 400);
  a := ModToModule(data);
  try
    data2 := ModuleToMod(a);
    b := ModToModule(data2);
    try
      n := Min(a.GetInstrument(1).FrameCount, b.GetInstrument(1).FrameCount);
      Check(n > 0, 'there is sample data to compare');
      maxErr := 0;
      for i := 0 to n - 1 do
      begin
        e := Abs(a.GetInstrument(1).Data[i] - b.GetInstrument(1).Data[i]);
        if e > maxErr then maxErr := e;
      end;
      { 8-bit quantisation: within one LSB (1/128) plus a hair }
      Check(maxErr <= 0.02, 'PCM survives export within 8-bit quantisation');
    finally
      b.Free;
    end;
  finally
    a.Free;
  end;
end;

procedure Test_Export_Issues;
var
  m: TTrackerModule;
  issues: TArray<string>;
  i, k: Integer;
  joined: string;
  cell: TTrackerCell;
begin
  m := TTrackerModule.Create;
  try
    m.Clear;
    m.SetChannels(2);
    for k := 1 to 40 do m.AddInstrument(Format('i%d', [k]));
    m.AddPattern(32);           { not 64 rows }
    m.AppendOrder(0);
    cell := TTrackerCell.Empty;
    cell.Effect := tfxPanSlide;  { no MOD equivalent }
    cell.Param := $11;
    m.GetPattern(0).SetCell(0, 0, cell);

    issues := ModExportIssues(m);
    Check(Length(issues) >= 3, 'issues reported for instruments, rows and the lost effect');
    joined := '';
    for i := 0 to High(issues) do joined := joined + issues[i] + ' | ';
    Check(Pos('31', joined) > 0, 'mentions the 31-instrument limit');
    Check(Pos('rows', joined) > 0, 'mentions the 64-row constraint');
    Check(Pos('no MOD equivalent', joined) > 0, 'mentions the dropped effect');

    { a clean 4-channel / 64-row / 1-instrument module reports nothing }
    m.Free;
    m := TTrackerModule.Create;
    m.Clear;
    m.SetChannels(4);
    m.AddInstrument('clean');
    m.AddPattern(64);
    m.AppendOrder(0);
    m.GetPattern(0).SetCell(0, 0, TTrackerCell.Empty);
    issues := ModExportIssues(m);
    CheckEqualInt(0, Length(issues), 'a MOD-compatible module reports no issues');
  finally
    m.Free;
  end;
end;

procedure Test_Import_RejectsGarbage;
var
  junk: TBytes;
begin
  SetLength(junk, 2500);
  FillChar(junk[0], Length(junk), $AA);
  try
    ModToModule(junk).Free;
    Fail('garbage should not parse as a MOD');
  except
    on E: EUDAWError do CheckEqualInt(Ord(errConfig), Ord(E.Code), 'errConfig on a non-MOD buffer');
  end;
end;

procedure Test_ImportCommand_UndoRedo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  data: TBytes;
  before: string;
begin
  doc := TProjectDocument.CreateNew('mod host');
  mgr := TCommandManager.Create;
  try
    before := doc.Tracker.Name;
    data := BuildMod31(4, 2, [0, 1], [Spec(0, 0, 0, 12, 1, 0, 0)]);
    mgr.Perform(TImportModCommand.Create(doc, data, 'MOD'));
    CheckEqualStr('PHASE12 TEST', doc.Tracker.Name, 'module replaced by the import');
    CheckEqualInt(2, doc.Tracker.PatternCount, 'imported patterns present');
    mgr.Undo;
    CheckEqualStr(before, doc.Tracker.Name, 'undo restores the previous module');
    mgr.Redo;
    CheckEqualStr('PHASE12 TEST', doc.Tracker.Name, 'redo re-imports');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_ImportedModule_EmbedsInProject;
var
  doc, back: TProjectDocument;
  data: TBytes;
  s: string;
begin
  doc := TProjectDocument.CreateNew('embed');
  try
    data := BuildMod31(4, 2, [0, 1, 1],
      [Spec(0, 0, 0, 12, 1, 0, 0), Spec(1, 8, 0, 0, 1, $C, $10)]);
    doc.ReplaceTracker(ModToModule(data));
    s := ProjectToString(doc);
    back := ProjectFromString(s);
    try
      CheckEqualStr('PHASE12 TEST', back.Tracker.Name, 'imported module name persists in the project');
      CheckEqualInt(2, back.Tracker.PatternCount, 'patterns persist');
      CheckEqualInt(3, back.Tracker.OrderLength, 'order table persists');
      CheckEqualInt(49, back.Tracker.GetPattern(0).GetCell(0, 0).Note, 'a cell persists');
    finally
      back.Free;
    end;
  finally
    doc.Free;
  end;
end;

procedure Test_Period_NoteMath;
var
  idx: Integer;
begin
  { the reference note (index 12) sits near the classic ProTracker period 428 }
  CheckNear(428.0, ModNotePeriod(12, 0), 6.0, 'reference period ~428');
  { an octave up halves the period }
  CheckNear(0.5, ModNotePeriod(24, 0) / ModNotePeriod(12, 0), 0.001, 'octave halves the period');
  { round-trip a period back to its note index }
  idx := ModPeriodToNoteIndex(Round(ModNotePeriod(20, 0)), 0);
  CheckEqualInt(20, idx, 'period -> nearest note index round-trips');
  { finetune shifts pitch up (shorter period) }
  Check(ModNotePeriod(12, 7) < ModNotePeriod(12, 0), 'positive finetune shortens the period');
end;

procedure Test_Truncated_PatternData;
var
  data, chopped: TBytes;
begin
  { order references pattern 2 but only ~1 pattern of data is present }
  data := BuildMod31(4, 1, [0], [Spec(0, 0, 0, 12, 1, 0, 0)]);
  { keep the header + a bit over one pattern, drop the rest + PCM }
  SetLength(chopped, 1084 + 64 * 4 * 4);
  Move(data[0], chopped[0], Length(chopped));
  { must still parse without raising and yield a usable module }
  with ModToModule(chopped) do
  try
    Check(PatternCount >= 1, 'a short MOD still yields at least one pattern');
    Check(Channels = 4, 'channel count intact');
  finally
    Free;
  end;
end;

{ ---------------- registration ---------------- }

procedure Test_TrackerClipSource;
var
  data: TBytes;
  path: string;
  pcm: TAudioPlanar;
  frames, i: Integer;
  bpm, peak: Double;
  fs: TFileStream;
begin
  data := BuildMod31(4, 1, [0], [Spec(0, 0, 0, 12, 1, 0, 0)]);
  path := IncludeTrailingPathDelimiter(TPath.GetTempPath) + 'udaw-trackerclip-test.mod';
  fs := TFileStream.Create(path, fmCreate);
  try
    fs.WriteBuffer(data[0], Length(data));
  finally
    fs.Free;
  end;
  try
    Check(TrackerSniffFile(path), 'a module file is a tracker source');
    Check(TrackerRenderFile(path, pcm, frames, bpm), 'module renders for the Timeline');
    Check(frames > 0, 'rendered some audio');
    CheckEqualInt(2, Length(pcm), 'stereo');
    CheckNear(125.0, bpm, 1e-9, 'default 125 BPM / speed 6 is 125 beats per minute');
    CheckNear(125.0, TrackerFileBpm(path), 1e-9, 'tempo without rendering');
    peak := 0;
    for i := 0 to frames - 1 do
      if Abs(pcm[0][i]) > peak then peak := Abs(pcm[0][i]);
    Check(peak > 0.01, 'the module is audible');
    Check(peak <= 1.0, 'render stays inside full scale');
  finally
    DeleteFile(path);
  end;
end;

procedure RegisterPhase12Tests;
begin
  RegisterTest('mod.sniff', 'kind detection',            @Test_Sniff_Kinds);
  RegisterTest('mod.timeline', 'module as a Timeline clip source', @Test_TrackerClipSource);
  RegisterTest('mod.import', '31-sample structure',      @Test_Import_Structure);
  RegisterTest('mod.import', '15-sample Soundtracker',   @Test_Import_15Sample);
  RegisterTest('mod.import', 'effect column mapping',    @Test_Effect_Mapping);
  RegisterTest('mod.import', 'rejects garbage',          @Test_Import_RejectsGarbage);
  RegisterTest('mod.import', 'tolerates truncation',     @Test_Truncated_PatternData);
  RegisterTest('mod.period', 'period / note maths',      @Test_Period_NoteMath);
  RegisterTest('mod.play',   'note plays a tone',        @Test_Play_Tone);
  RegisterTest('mod.play',   'octave down halves pitch', @Test_Play_OctaveDown);
  RegisterTest('mod.export', 'byte-level round trip',    @Test_Export_RoundTrip);
  RegisterTest('mod.export', 'PCM within quantisation',  @Test_Export_SampleData_Approx);
  RegisterTest('mod.export', 'representability report',  @Test_Export_Issues);
  RegisterTest('mod.cmd',    'import command undo/redo', @Test_ImportCommand_UndoRedo);
  RegisterTest('mod.cmd',    'imported module embeds',   @Test_ImportedModule_EmbedsInProject);
end;

end.
