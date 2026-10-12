unit Tests.Phase13;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 13 acceptance tests: XM support.

  Covers the FastTracker 2 Extended Module reader and writer in UDAW.Codec.XM -
  header sniffing, the v1.04 layout, the packed pattern format, the effect
  column + volume column mapping onto UDAW's internal effect set, relative-note
  / finetune -> sample-rate maths, 8-bit delta PCM, forward loops, playback
  through the Phase 11 TTrackerPlayer, the exporter, round-tripping and the
  export-representability report.

  Requires src/common, src/audio, src/audio/dsp, src/timeline, src/project,
  src/mixer, src/tracker and src/codecs/tracker on the search path. }

interface

procedure RegisterPhase13Tests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Audio.Types,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern,
  UDAW.Tracker.Player,
  UDAW.Project.Document, UDAW.Project.Serialization, UDAW.Project.Commands,
  UDAW.Tracker.Commands,
  UDAW.Codec.XM;

const
  SR = 48000;
  XM_MAGIC17 = 'Extended Module: ';

{ ---------------- small helpers (shared shape with Phase 12) ---------------- }

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

type
  TCellSpec = record
    Pat, Row, Chn, Note, Instr, Cmd, Param: Integer;   // Note: 0 = none, else internal/XM note value
  end;

function Spec(APat, ARow, AChn, ANote, AInstr, ACmd, AParam: Integer): TCellSpec;
begin
  Result.Pat := APat; Result.Row := ARow; Result.Chn := AChn;
  Result.Note := ANote; Result.Instr := AInstr;
  Result.Cmd := ACmd; Result.Param := AParam;
end;

procedure PutW(var B: TBytes; AOfs, AValue: Integer);
begin
  B[AOfs] := AValue and $FF;
  B[AOfs + 1] := (AValue shr 8) and $FF;
end;

procedure PutD(var B: TBytes; AOfs, AValue: Integer);
begin
  B[AOfs] := AValue and $FF;
  B[AOfs + 1] := (AValue shr 8) and $FF;
  B[AOfs + 2] := (AValue shr 16) and $FF;
  B[AOfs + 3] := (AValue shr 24) and $FF;
end;

{ 8-bit signed sine, delta-encoded: ACycles full periods across AByteCount samples }
function SineDelta8(ACycles, AByteCount: Integer): TBytes;
var
  i, v, prev: Integer;
begin
  SetLength(Result, AByteCount);
  prev := 0;
  for i := 0 to AByteCount - 1 do
  begin
    v := Round(120.0 * Sin(2 * Pi * ACycles * i / AByteCount));
    if v > 127 then v := 127 else if v < -128 then v := -128;
    Result[i] := Byte((v - prev) and $FF);
    prev := v;
  end;
end;

{ Build a minimal v1.04 XM: AChannels channels, ANumPat patterns, one 8-bit
  sine instrument (slot 1, whole-sample forward loop), an order table and a set
  of literal cells. }
function BuildXm(AChannels, ANumPat: Integer; const AOrder: array of Integer;
  const ACells: array of TCellSpec; ASampleCycles: Integer = 27;
  ASampleBytes: Integer = 512): TBytes;
var
  st: TBytesStream;
  fixed, vhdr, phdr, pbody, ihdr, shdr, sdata: TBytes;
  i, p, r, c, j, cellIdx: Integer;
  nm: AnsiString;
  has: Boolean;
  cs: TCellSpec;
begin
  st := TBytesStream.Create;
  try
    { 60-byte fixed header }
    SetLength(fixed, 60);
    FillChar(fixed[0], 60, 0);
    for i := 1 to 17 do fixed[i - 1] := Byte(XM_MAGIC17[i]);
    nm := 'PHASE13 XM TEST';
    for i := 0 to 19 do
      if i < Length(nm) then fixed[17 + i] := Byte(nm[i + 1]) else fixed[17 + i] := Byte(' ');
    fixed[37] := $1A;
    nm := 'builder';
    for i := 0 to Length(nm) - 1 do fixed[38 + i] := Byte(nm[i + 1]);
    PutW(fixed, 58, $0104);
    st.WriteBuffer(fixed[0], 60);

    { variable header: 20 fixed fields + 256 order = 276 }
    SetLength(vhdr, 276);
    FillChar(vhdr[0], 276, 0);
    PutD(vhdr, 0, 276);
    PutW(vhdr, 4, Length(AOrder));
    PutW(vhdr, 6, 0);
    PutW(vhdr, 8, AChannels);
    PutW(vhdr, 10, ANumPat);
    PutW(vhdr, 12, 1);            { one instrument }
    PutW(vhdr, 14, 1);            { linear frequency table }
    PutW(vhdr, 16, 6);            { default speed }
    PutW(vhdr, 18, 125);          { default BPM }
    for i := 0 to High(AOrder) do vhdr[20 + i] := Byte(AOrder[i]);
    st.WriteBuffer(vhdr[0], 276);

    { patterns }
    for p := 0 to ANumPat - 1 do
    begin
      SetLength(pbody, 0);
      for r := 0 to 63 do
        for c := 0 to AChannels - 1 do
        begin
          has := False;
          cs := Spec(0, 0, 0, 0, 0, 0, 0);
          for cellIdx := 0 to High(ACells) do
            if (ACells[cellIdx].Pat = p) and (ACells[cellIdx].Row = r)
               and (ACells[cellIdx].Chn = c) then
            begin
              cs := ACells[cellIdx];
              has := True;
              Break;
            end;
          if not has then
          begin
            { empty cell: a lone mask byte with bit7 set and no field bits }
            j := Length(pbody);
            SetLength(pbody, j + 1);
            pbody[j] := $80;
          end
          else
          begin
            { literal row: note byte (bit7 clear) then instr, vol, fx, param }
            j := Length(pbody);
            SetLength(pbody, j + 5);
            pbody[j]     := Byte(cs.Note and $7F);
            pbody[j + 1] := Byte(cs.Instr);
            pbody[j + 2] := 0;
            pbody[j + 3] := Byte(cs.Cmd);
            pbody[j + 4] := Byte(cs.Param);
          end;
        end;
      SetLength(phdr, 9);
      FillChar(phdr[0], 9, 0);
      PutD(phdr, 0, 9);
      phdr[4] := 0;
      PutW(phdr, 5, 64);
      PutW(phdr, 7, Length(pbody));
      st.WriteBuffer(phdr[0], 9);
      if Length(pbody) > 0 then st.WriteBuffer(pbody[0], Length(pbody));
    end;

    { one instrument, one sample }
    SetLength(ihdr, 263);
    FillChar(ihdr[0], 263, 0);
    PutD(ihdr, 0, 263);
    nm := 'sine';
    for i := 0 to Length(nm) - 1 do ihdr[4 + i] := Byte(nm[i + 1]);
    PutW(ihdr, 27, 1);        { one sample }
    PutD(ihdr, 29, 40);       { sample header size }
    st.WriteBuffer(ihdr[0], 263);

    SetLength(shdr, 40);
    FillChar(shdr[0], 40, 0);
    PutD(shdr, 0, ASampleBytes);          { length in bytes (8-bit) }
    PutD(shdr, 4, 0);                     { loop start }
    PutD(shdr, 8, ASampleBytes);          { loop length = whole sample }
    shdr[12] := 64;                       { volume }
    shdr[13] := 0;                        { finetune }
    shdr[14] := $01;                      { forward loop, 8-bit }
    shdr[15] := 128;                      { panning centre }
    shdr[16] := 0;                        { relative note }
    st.WriteBuffer(shdr[0], 40);

    sdata := SineDelta8(ASampleCycles, ASampleBytes);
    st.WriteBuffer(sdata[0], Length(sdata));

    Result := Copy(st.Bytes, 0, st.Size);
  finally
    st.Free;
  end;
end;

{ ---------------- tests ---------------- }

procedure Test_Sniff;
var
  data, junk: TBytes;
begin
  data := BuildXm(4, 1, [0], [Spec(0, 0, 0, 49, 1, 0, 0)]);
  Check(DataLooksLikeXm(data), 'generated buffer sniffs as an XM');
  Check(XmKindFromData(data), 'XmKindFromData agrees');
  SetLength(junk, 4000);
  FillChar(junk[0], Length(junk), 0);
  CheckFalse(DataLooksLikeXm(junk), 'all-zero buffer is not an XM');
end;

procedure Test_Import_Structure;
var
  data: TBytes;
  info: TXmImportInfo;
  m: TTrackerModule;
begin
  data := BuildXm(6, 3, [0, 1, 2, 1],
    [Spec(0, 0, 0, 49, 1, 0, 0), Spec(1, 0, 0, 0, 1, 0, 0)]);
  m := XmToModule(data, info);
  try
    CheckEqualInt(6, info.Channels, 'channel count');
    CheckEqualInt(6, m.Channels, 'module channels');
    CheckEqualInt(3, m.PatternCount, 'pattern count');
    CheckEqualInt(4, m.OrderLength, 'order length');
    CheckEqualInt(1, m.InstrumentCount, 'one instrument slot');
    CheckEqualStr('PHASE13 XM TEST', m.Name, 'song title');
    Check(info.LinearFreq, 'linear frequency table flagged');
    Check(m.GetInstrument(1).FrameCount = 512, 'sample PCM length (frames)');
    Check(m.GetInstrument(1).LoopMode = tlmForward, 'whole-sample forward loop');
    CheckEqualInt(49, m.GetPattern(0).GetCell(0, 0).Note, 'C-4 note value 49 preserved');
    CheckEqualInt(1, m.GetPattern(0).GetCell(0, 0).Instrument, 'instrument 1 referenced');
  finally
    m.Free;
  end;
end;

procedure Test_Effect_And_VolColumn;
var
  data: TBytes;
  m: TTrackerModule;
  info: TXmImportInfo;
  p: TTrackerPattern;

  procedure ExpectFx(ARow: Integer; AEff: TTrackerEffect; AParam: Integer; const AWhat: string);
  var cell: TTrackerCell;
  begin
    cell := p.GetCell(ARow, 0);
    Check(cell.Effect = AEff, AWhat + ': effect');
    CheckEqualInt(AParam, cell.Param, AWhat + ': param');
  end;

begin
  data := BuildXm(1, 1, [0],
    [ Spec(0, 0, 0, 0, 0, $0, $37),     // arpeggio 3/7
      Spec(0, 1, 0, 0, 0, $C, $20),     // set volume 0x20
      Spec(0, 2, 0, 0, 0, $A, $40),     // volume slide up
      Spec(0, 3, 0, 0, 0, $D, $12),     // pattern break BCD 0x12 -> row 12
      Spec(0, 4, 0, 0, 0, $F, $03),     // set speed 3
      Spec(0, 5, 0, 0, 0, $E, $C4),     // EC4 note cut on tick 4
      Spec(0, 6, 0, 0, 0, $E, $A3),     // EA3 fine volume up 3
      Spec(0, 7, 0, 0, 0, $10, $40),    // G (set global volume) -> no internal equivalent
      Spec(0, 8, 0, 0, 0, $19, $35) ]); // P (panning slide) -> tfxPanSlide, same nibble layout (x right, y left)
  m := XmToModule(data, info);
  try
    p := m.GetPattern(0);
    ExpectFx(0, tfxArpeggio, $37, 'arpeggio');
    ExpectFx(1, tfxSetVolume, $20, 'set volume');
    ExpectFx(2, tfxVolSlide, $40, 'volume slide');
    ExpectFx(3, tfxPatternBreak, 12, 'pattern break decodes BCD');
    ExpectFx(4, tfxSetSpeed, $03, 'set speed');
    ExpectFx(6, tfxFineVolUp, 3, 'EA fine volume up');
    Check(p.GetCell(7, 0).Effect = tfxNone, 'unmapped G leaves no effect');
    ExpectFx(8, tfxPanSlide, $35, 'P panning slide keeps x=right, y=left');
    Check(info.LostEffectCells >= 1, 'the dropped command is counted');
  finally
    m.Free;
  end;
end;

procedure Test_VolumeColumn_SetsVolume;
var
  data: TBytes;
  m: TTrackerModule;
  st: TBytesStream;
  fixed, vhdr, phdr, pbody: TBytes;
  i: Integer;
begin
  { hand-build one pattern whose single cell carries a volume-column set-volume
    (0x30 -> volume 0x20 = 32) and no effect column }
  st := TBytesStream.Create;
  try
    SetLength(fixed, 60); FillChar(fixed[0], 60, 0);
    for i := 1 to 17 do fixed[i - 1] := Byte(XM_MAGIC17[i]);
    fixed[37] := $1A;
    PutW(fixed, 58, $0104);
    st.WriteBuffer(fixed[0], 60);

    SetLength(vhdr, 276); FillChar(vhdr[0], 276, 0);
    PutD(vhdr, 0, 276);
    PutW(vhdr, 4, 1); PutW(vhdr, 8, 1); PutW(vhdr, 10, 1); PutW(vhdr, 12, 0);
    PutW(vhdr, 14, 1); PutW(vhdr, 16, 6); PutW(vhdr, 18, 125);
    st.WriteBuffer(vhdr[0], 276);

    { one row, one channel: literal note 0, instr 0, vol byte 0x30, no fx }
    SetLength(pbody, 5);
    pbody[0] := 0; pbody[1] := 0; pbody[2] := $30; pbody[3] := 0; pbody[4] := 0;
    SetLength(phdr, 9); FillChar(phdr[0], 9, 0);
    PutD(phdr, 0, 9); PutW(phdr, 5, 1); PutW(phdr, 7, Length(pbody));
    st.WriteBuffer(phdr[0], 9);
    st.WriteBuffer(pbody[0], Length(pbody));

    data := Copy(st.Bytes, 0, st.Size);
  finally
    st.Free;
  end;

  m := XmToModule(data);
  try
    CheckEqualInt($20, m.GetPattern(0).GetCell(0, 0).Volume, 'volume column 0x30 -> volume 32');
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
  data := BuildXm(4, 1, [0], [Spec(0, 0, 0, 49, 1, 0, 0)], 27, 512);
  m := XmToModule(data);
  pl := nil;
  try
    pl := TTrackerPlayer.Create(m);
    pl.LoopSong := True;
    o := pl.RenderToPlanar(SR div 2, 2);
    Check(AllFinitePl(o), 'rendered output is finite');
    Check(PlanarRms(o, 0, SR div 20, Length(o[0])) > 0.03, 'the note produces audio');
    CheckNear(441.0, DomFreq(o, 0, SR div 20, Length(o[0])), 40.0, 'C-4 sample streams at ~441 Hz');
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
  hi := BuildXm(4, 1, [0], [Spec(0, 0, 0, 49, 1, 0, 0)], 27, 512);
  lo := BuildXm(4, 1, [0], [Spec(0, 0, 0, 37, 1, 0, 0)], 27, 512);
  m1 := XmToModule(hi);
  m2 := XmToModule(lo);
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

procedure Test_SampleRate_Helper;
begin
  CheckNear(8363.0, XmSampleRate(0, 0), 2.0, 'relnote 0, ft 0 -> 8363 Hz');
  CheckNear(16726.0, XmSampleRate(12, 0), 4.0, 'relnote +12 doubles the rate');
  CheckNear(8363.0 * Power(2.0, 1.0 / 12.0), XmSampleRate(0, 128), 3.0,
    'finetune +128 = one semitone up');
end;

procedure Test_Export_RoundTrip;
var
  data, data2: TBytes;
  a, b: TTrackerModule;
  ca, cb: TTrackerCell;
begin
  data := BuildXm(4, 2, [0, 1],
    [ Spec(0, 0, 0, 49, 1, 0, 0),
      Spec(0, 4, 0, 61, 1, $C, $2A),
      Spec(0, 8, 0, 0, 0, $D, $08),
      Spec(1, 0, 1, 40, 1, $A, $30) ]);
  a := XmToModule(data);
  try
    data2 := ModuleToXm(a);
    Check(DataLooksLikeXm(data2), 're-exported bytes still sniff as an XM');
    b := XmToModule(data2);
    try
      CheckEqualInt(a.Channels, b.Channels, 'channels survive export');
      CheckEqualInt(a.PatternCount, b.PatternCount, 'pattern count survives');
      CheckEqualInt(a.OrderLength, b.OrderLength, 'order length survives');

      ca := a.GetPattern(0).GetCell(0, 0);
      cb := b.GetPattern(0).GetCell(0, 0);
      CheckEqualInt(ca.Note, cb.Note, 'note 0,0 round-trips');
      CheckEqualInt(ca.Instrument, cb.Instrument, 'instrument 0,0 round-trips');

      cb := b.GetPattern(0).GetCell(4, 0);
      Check(cb.Effect = tfxSetVolume, 'set-volume effect round-trips');
      CheckEqualInt($2A, cb.Param, 'set-volume param round-trips');

      cb := b.GetPattern(0).GetCell(8, 0);
      Check(cb.Effect = tfxPatternBreak, 'pattern break round-trips');
      CheckEqualInt(8, cb.Param, 'pattern break row round-trips through BCD');

      Check(b.GetInstrument(1).FrameCount = a.GetInstrument(1).FrameCount,
        'sample length round-trips');
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
  i: Integer;
  joined: string;
  cell: TTrackerCell;
begin
  m := TTrackerModule.Create;
  try
    m.Clear;
    m.SetChannels(4);
    m.AddInstrument('clean');
    m.AddPattern(64);
    m.AppendOrder(0);
    cell := TTrackerCell.Empty;
    cell.Note := 110;               { above B-7 }
    cell.Effect := tfxSetBPM;       { representable }
    m.GetPattern(0).SetCell(0, 0, cell);
    cell := TTrackerCell.Empty;
    cell.Effect := tfxFineVolUp;
    cell.Param := 3;
    m.GetPattern(0).SetCell(1, 0, cell);

    issues := XmExportIssues(m);
    joined := '';
    for i := 0 to High(issues) do joined := joined + issues[i] + ' | ';
    Check(Pos('B-7', joined) > 0, 'flags the note above B-7');

    { a clean module reports nothing }
    m.GetPattern(0).SetCell(0, 0, TTrackerCell.Empty);
    m.GetPattern(0).SetCell(1, 0, TTrackerCell.Empty);
    issues := XmExportIssues(m);
    CheckEqualInt(0, Length(issues), 'a clean 4-channel / 64-row module reports no issues');
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
    XmToModule(junk).Free;
    Fail('garbage should not parse as an XM');
  except
    on E: EUDAWError do CheckEqualInt(Ord(errConfig), Ord(E.Code), 'errConfig on a non-XM buffer');
  end;
end;

procedure Test_Truncated;
var
  data, chopped: TBytes;
begin
  data := BuildXm(4, 3, [0, 1, 2], [Spec(0, 0, 0, 49, 1, 0, 0)]);
  SetLength(chopped, 60 + 276 + 40);       { header + a sliver of the first pattern }
  Move(data[0], chopped[0], Length(chopped));
  with XmToModule(chopped) do
  try
    Check(PatternCount >= 1, 'a short XM still yields at least one pattern');
    Check(Channels = 4, 'channel count intact');
  finally
    Free;
  end;
end;

procedure Test_ImportCommand_UndoRedo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  data: TBytes;
  before: string;
begin
  doc := TProjectDocument.CreateNew('xm host');
  mgr := TCommandManager.Create;
  try
    before := doc.Tracker.Name;
    data := BuildXm(4, 2, [0, 1], [Spec(0, 0, 0, 49, 1, 0, 0)]);
    mgr.Perform(TImportXmCommand.Create(doc, data, 'XM'));
    CheckEqualStr('PHASE13 XM TEST', doc.Tracker.Name, 'module replaced by the import');
    CheckEqualInt(2, doc.Tracker.PatternCount, 'imported patterns present');
    mgr.Undo;
    CheckEqualStr(before, doc.Tracker.Name, 'undo restores the previous module');
    mgr.Redo;
    CheckEqualStr('PHASE13 XM TEST', doc.Tracker.Name, 'redo re-imports');
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
    data := BuildXm(4, 2, [0, 1, 1],
      [Spec(0, 0, 0, 49, 1, 0, 0), Spec(1, 8, 0, 37, 1, $C, $10)]);
    doc.ReplaceTracker(XmToModule(data));
    s := ProjectToString(doc);
    back := ProjectFromString(s);
    try
      CheckEqualStr('PHASE13 XM TEST', back.Tracker.Name, 'imported module name persists');
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

{ ---------------- registration ---------------- }

procedure RegisterPhase13Tests;
begin
  RegisterTest('xm.sniff',  'kind detection',           @Test_Sniff);
  RegisterTest('xm.import', 'structure',                @Test_Import_Structure);
  RegisterTest('xm.import', 'effect + volume column',   @Test_Effect_And_VolColumn);
  RegisterTest('xm.import', 'volume column set-volume', @Test_VolumeColumn_SetsVolume);
  RegisterTest('xm.import', 'rejects garbage',          @Test_Import_RejectsGarbage);
  RegisterTest('xm.import', 'tolerates truncation',     @Test_Truncated);
  RegisterTest('xm.rate',   'relnote / finetune maths', @Test_SampleRate_Helper);
  RegisterTest('xm.play',   'note plays a tone',        @Test_Play_Tone);
  RegisterTest('xm.play',   'octave down halves pitch', @Test_Play_OctaveDown);
  RegisterTest('xm.export', 'byte-level round trip',    @Test_Export_RoundTrip);
  RegisterTest('xm.export', 'representability report',  @Test_Export_Issues);
  RegisterTest('xm.cmd',    'import command undo/redo', @Test_ImportCommand_UndoRedo);
  RegisterTest('xm.cmd',    'imported module embeds',   @Test_ImportedModule_EmbedsInProject);
end;

end.
