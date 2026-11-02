unit Tests.Phase11;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 11 acceptance tests: the native tracker engine.

  Covers the value types (note names / frequencies / effect letters), the
  pattern grid + module (resize, order-table edits, instrument slots, clone),
  instruments + envelopes, the replay core (note pitch, octave, arpeggio,
  portamento, tone portamento, volume slide, set speed / BPM, position jump,
  note cut / delay, song looping, ping-pong sample loop), the versioned text
  serializer (round-trip incl. sample PCM, rejects, project v4 embedding, cell
  text) and the undo/redo commands.

  Requires src/common, src/audio, src/audio/dsp, src/timeline, src/project,
  src/mixer and src/tracker on the search path. }

interface

procedure RegisterPhase11Tests;

implementation

uses
  SysUtils, Classes, Graphics, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Audio.Types, UDAW.Audio.Buffer,
  UDAW.Project.Document, UDAW.Project.Serialization, UDAW.Project.Commands,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern,
  UDAW.Tracker.Player, UDAW.Tracker.Serialization, UDAW.Tracker.Commands,
  UDAW.Tracker.ScoreNotes, UDAW.Codec.TrackerLegacy,
  UDAW.GL.Canvas, UDAW.UI.Score, UDAW.UI.ScorePdf;

const
  SR = 48000;

{ dominant frequency by positive-going zero crossings over one channel }
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

function PlanarPeak(const P: TAudioPlanar; ACh, AFrom, ATo: Integer): Double;
var
  i: Integer;
  m: Double;
begin
  m := 0;
  for i := AFrom to ATo - 1 do
    if Abs(Double(P[ACh][i])) > m then m := Abs(Double(P[ACh][i]));
  Result := m;
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

function Cell(const ANote: string; AInstr: Integer; AEffect: TTrackerEffect;
  AParam: Integer): TTrackerCell;
begin
  Result := TTrackerCell.Empty;
  NoteFromName(ANote, Result.Note);
  Result.Instrument := Byte(AInstr);
  Result.Effect := AEffect;
  Result.Param := Byte(AParam);
end;

{ a module with one looped sine instrument and a pattern that plays A-4 on ch0 }
function SineModule(AInstrFreq: Double = 440.0): TTrackerModule;
var
  ins: TTrackerInstrument;
begin
  Result := TTrackerModule.Create;
  Result.InitDefault;
  Result.InitialSpeed := 6;
  Result.InitialBPM := 125;
  ins := Result.AddInstrument('Sine');
  ins.MakeSine(AInstrFreq, 1.0, SR, 0.7);
  { instrument root is now the note that sounds AInstrFreq; play that note }
  Result.GetPattern(0).SetCell(0, 0, Cell(NoteName(ins.RootNote), 1, tfxNone, 0));
end;

{ ================= types ================= }

procedure Test_Types_Notes;
var
  n: Byte;
begin
  CheckEqualStr('C-4', NoteName(49), 'C-4 name');
  CheckEqualStr('A-4', NoteName(58), 'A-4 name');
  Check(NoteFromName('C-4', n) and (n = 49), 'C-4 parses to 49');
  Check(NoteFromName('A-4', n) and (n = 58), 'A-4 parses to 58');
  Check(NoteFromName('===', n) and (n = TRK_NOTE_OFF), 'note-off token');
  Check(NoteFromName('^^^', n) and (n = TRK_NOTE_CUT), 'note-cut token');
  Check(NoteFromName('...', n) and (n = TRK_NOTE_NONE), 'empty token');
  CheckNear(440.0, NoteToHz(58), 0.01, 'A-4 = 440 Hz');
  CheckNear(880.0, NoteToHz(70), 0.02, 'octave up doubles');
  CheckNear(220.0, NoteToHz(46), 0.02, 'octave down halves');
end;

procedure Test_Types_EffectLetters;
var
  e, e2: TTrackerEffect;
begin
  for e := Low(TTrackerEffect) to High(TTrackerEffect) do
    if e <> tfxNone then
    begin
      Check(EffectFromLetter(EffectLetter(e), e2), 'letter parses: ' + EffectLetter(e));
      Check(e2 = e, 'letter round-trips for ' + IntToStr(Ord(e)));
    end;
end;

{ ================= pattern / module ================= }

procedure Test_Pattern_ResizeKeepsRows;
var
  p: TTrackerPattern;
begin
  p := TTrackerPattern.Create(16, 4);
  try
    p.SetCell(3, 1, Cell('C-4', 1, tfxNone, 0));
    p.Resize(32);
    CheckEqualInt(32, p.Rows, 'grew to 32 rows');
    Check(p.GetCell(3, 1).Note = 49, 'row 3 survived the grow');
    p.Resize(2);
    CheckEqualInt(2, p.Rows, 'shrank to 2 rows');
  finally
    p.Free;
  end;
end;

procedure Test_Module_OrderAndPatterns;
var
  m: TTrackerModule;
begin
  m := TTrackerModule.Create;
  try
    m.InitDefault;
    CheckEqualInt(1, m.PatternCount, 'one pattern');
    CheckEqualInt(1, m.OrderLength, 'one order entry');
    m.AddPattern(32);
    m.AddPattern(48);
    m.AppendOrder(1);
    m.AppendOrder(2);
    m.AppendOrder(1);
    CheckEqualInt(4, m.OrderLength, 'order grew to 4');

    m.RemovePattern(1);   // pattern 2 renumbers to 1, order refs to 1 drop
    CheckEqualInt(2, m.PatternCount, 'two patterns left');
    { every remaining order entry must point at a valid pattern }
    Check((m.GetOrder(0) < m.PatternCount) and (m.GetOrder(m.OrderLength - 1) < m.PatternCount),
      'order table stays valid after pattern removal');
  finally
    m.Free;
  end;
end;

procedure Test_Module_Instruments;
var
  m: TTrackerModule;
begin
  m := TTrackerModule.Create;
  try
    Check(m.GetInstrument(0) = nil, 'slot 0 is none');
    m.AddInstrument('Kick');
    m.AddInstrument('Snare');
    CheckEqualInt(2, m.InstrumentCount, 'two instruments');
    CheckEqualStr('Kick', m.GetInstrument(1).Name, '1-based access');
    CheckEqualStr('Snare', m.GetInstrument(2).Name, 'second slot');
    Check(m.GetInstrument(3) = nil, 'past the end is nil');
  finally
    m.Free;
  end;
end;

procedure Test_Module_CloneIndependent;
var
  m, c: TTrackerModule;
begin
  m := SineModule;
  try
    c := m.Clone;
    try
      m.GetPattern(0).SetCell(0, 0, TTrackerCell.Empty);
      m.InitialSpeed := 3;
      Check(c.GetPattern(0).GetCell(0, 0).Note <> TRK_NOTE_NONE, 'clone keeps its cell');
      CheckEqualInt(6, c.InitialSpeed, 'clone keeps its speed');
      CheckEqualInt(1, c.InstrumentCount, 'clone kept the instrument');
    finally
      c.Free;
    end;
  finally
    m.Free;
  end;
end;

{ ================= instrument / envelope ================= }

procedure Test_Envelope_Interp;
var
  e: TTrackerEnvelope;
begin
  e.Clear;
  e.Enabled := True;
  e.AddPoint(0, 1.0);
  e.AddPoint(10, 0.0);
  CheckNear(1.0, e.ValueAt(0), 1e-6, 'start');
  CheckNear(0.5, e.ValueAt(5), 1e-6, 'midpoint interpolates');
  CheckNear(0.0, e.ValueAt(10), 1e-6, 'end');
  CheckNear(0.0, e.ValueAt(50), 1e-6, 'clamps past the last point');
end;

procedure Test_Instrument_MakeSine;
var
  ins: TTrackerInstrument;
begin
  ins := TTrackerInstrument.Create;
  try
    ins.MakeSine(440.0, 0.5, SR, 0.7);
    CheckEqualInt(Round(0.5 * SR), ins.FrameCount, 'sample length');
    Check(ins.LoopMode = tlmForward, 'loop set forward');
    CheckNear(440.0, NoteToHz(ins.RootNote), 15.0, 'root note is close to the sine frequency');
  finally
    ins.Free;
  end;
end;

{ ================= player ================= }

procedure Test_Player_SilenceWhenEmpty;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  o: TAudioPlanar;
begin
  m := TTrackerModule.Create;
  pl := nil;
  try
    m.InitDefault;   // one empty pattern, no instruments
    pl := TTrackerPlayer.Create(m);
    o := pl.RenderToPlanar(SR div 4, 2);
    CheckNear(0.0, PlanarPeak(o, 0, 0, Length(o[0])), 1e-9, 'empty module renders silence');
  finally
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Player_NotePlaysTone;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  o: TAudioPlanar;
begin
  m := SineModule(440.0);
  pl := nil;
  try
    pl := TTrackerPlayer.Create(m);
    o := pl.RenderToPlanar(SR div 4, 2);
    Check(PlanarRms(o, 0, SR div 20, Length(o[0])) > 0.05, 'the note produces audio');
    CheckNear(440.0, DomFreq(o, 0, SR div 20, Length(o[0])), 30.0, 'at ~440 Hz');
  finally
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Player_OctaveUp;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  ins: TTrackerInstrument;
  o: TAudioPlanar;
begin
  m := TTrackerModule.Create;
  pl := nil;
  try
    m.InitDefault;
    ins := m.AddInstrument('Sine');
    ins.MakeSine(220.0, 1.0, SR, 0.7);
    m.GetPattern(0).SetCell(0, 0, Cell(NoteName(ins.RootNote + 12), 1, tfxNone, 0));
    pl := TTrackerPlayer.Create(m);
    o := pl.RenderToPlanar(SR div 4, 2);
    CheckNear(440.0, DomFreq(o, 0, SR div 20, Length(o[0])), 40.0,
      'playing one octave above the root doubles the pitch');
  finally
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Player_Arpeggio;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  tmp: TAudioBuffer;
  base, t1, t2: Double;
  blk: Integer;
begin
  m := SineModule(440.0);
  pl := nil;
  tmp := nil;
  try
    { J effect, x=4 y=7 -> note, note+4, note+7 cycling by tick }
    m.GetPattern(0).SetCell(0, 0, Cell(NoteName(m.GetInstrument(1).RootNote), 1, tfxArpeggio, $47));
    pl := TTrackerPlayer.Create(m);
    { one block per tick: samples-per-tick at 125 BPM / 48k ~ 960 }
    blk := Round(2.5 * SR / 125);
    pl.Prepare(SR, blk, 2);
    tmp := TAudioBuffer.Create(2, blk, SR);
    pl.RenderBlock(tmp);
    base := pl.DebugChannelNote(0);          // tick 0 -> base note
    pl.RenderBlock(tmp);
    t1 := pl.DebugChannelNote(0);            // tick 1 -> base + x
    pl.RenderBlock(tmp);
    t2 := pl.DebugChannelNote(0);            // tick 2 -> base + y
    Check((Abs(t1 - base - 4.0) < 0.01) or (Abs(t2 - base - 4.0) < 0.01),
      'arpeggio raises the sounding note by +4 on one of the next ticks');
    Check((Abs(t1 - base - 7.0) < 0.01) or (Abs(t2 - base - 7.0) < 0.01),
      'arpeggio raises the sounding note by +7 on another tick');
  finally
    tmp.Free;
    pl.Free;
    m.Free;
  end;
end;

{ fine portamento (E1x / E2x) moves the pitch once on tick 0 and then holds }
procedure Test_Player_FinePortaOnce;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  tmp: TAudioBuffer;
  n0, n5: Double;
begin
  m := SineModule(220.0);
  pl := nil;
  tmp := nil;
  try
    m.GetPattern(0).SetCell(0, 0, Cell(NoteName(m.GetInstrument(1).RootNote), 1, tfxFinePortaUp, 8));
    pl := TTrackerPlayer.Create(m);
    pl.Prepare(SR, 4096, 2);
    tmp := TAudioBuffer.Create(2, 4096, SR);
    pl.RenderBlock(tmp);
    n0 := pl.DebugChannelNote(0);
    pl.RenderBlock(tmp);
    pl.RenderBlock(tmp);
    pl.RenderBlock(tmp);
    pl.RenderBlock(tmp);
    n5 := pl.DebugChannelNote(0);
    CheckNear(m.GetInstrument(1).RootNote + 0.5, n0, 0.001, 'fine porta up is half a semitone at 8/16');
    CheckNear(n0, n5, 0.001, 'and does not keep sliding');
  finally
    tmp.Free;
    pl.Free;
    m.Free;
  end;
end;

{ a multi-sample instrument plays the sample its key map names }
procedure Test_Instrument_KeyMapLayers;
var
  ins, lay: TTrackerInstrument;
  c: TTrackerInstrument;
begin
  ins := TTrackerInstrument.Create('multi');
  try
    ins.MakeSine(220.0, 0.1, SR, 0.5);
    lay := ins.AddLayer;
    lay.MakeSine(440.0, 0.1, SR, 0.5);
    ins.SetKeyMap(60, 1);
    Check(ins.SampleForNote(60) = lay, 'a mapped note plays its layer');
    Check(ins.SampleForNote(61) = ins, 'an unmapped note plays the instrument itself');
    c := ins.Clone;
    try
      CheckEqualInt(1, c.LayerCount, 'clone keeps the layers');
      CheckEqualInt(1, c.KeyMapAt(60), 'clone keeps the key map');
    finally
      c.Free;
    end;
  finally
    ins.Free;
  end;
end;

{ the Score reads notes out of a tracker module and filters them by channel / instrument }
procedure Test_ScoreNotes_Filter;
var
  m: TTrackerModule;
  all, one: TArray<TTrkScoreNote>;
  chOn, inOn: TArray<Boolean>;
  i: Integer;
begin
  m := SineModule;
  try
    m.GetPattern(0).SetCell(2, 1, Cell('C-4', 1, tfxNone, 0));
    all := TrackerScoreNotes(m, nil, nil);
    CheckEqualInt(2, Length(all), 'both notes found');
    CheckEqualInt(69, all[0].Pitch, 'A-4 is MIDI 69');
    CheckEqualInt(60, all[1].Pitch, 'C-4 is MIDI 60');
    Check(all[1].StartSec > all[0].StartSec, 'the second note comes later');

    SetLength(chOn, m.Channels);
    for i := 0 to High(chOn) do chOn[i] := True;
    chOn[1] := False;
    one := TrackerScoreNotes(m, chOn, nil);
    CheckEqualInt(1, Length(one), 'channel 2 filtered out');
    CheckEqualInt(0, one[0].Channel, 'the note left is on channel 1');

    SetLength(inOn, 2);
    inOn[0] := True;
    inOn[1] := False;
    CheckEqualInt(0, Length(TrackerScoreNotes(m, nil, inOn)), 'instrument 1 filtered out');
  finally
    m.Free;
  end;
end;

{ a minimal ScreamTracker 3 module: one sample, one pattern, a C-5 on channel 1 }
procedure Test_Legacy_S3M;
var
  d: TBytes;
  m: TTrackerModule;
  info: TLegacyImportInfo;
  i: Integer;
begin
  SetLength(d, $110);
  FillChar(d[0], Length(d), 0);
  d[$1C] := $1A; d[$1D] := 16;
  d[$20] := 2; d[$22] := 1; d[$24] := 1;
  d[$2A] := 2;
  d[$2C] := Ord('S'); d[$2D] := Ord('C'); d[$2E] := Ord('R'); d[$2F] := Ord('M');
  d[$30] := 64; d[$31] := 6; d[$32] := 125; d[$33] := $B0;
  for i := 0 to 31 do d[$40 + i] := 255;
  d[$40] := 0; d[$41] := 8;
  d[$60] := 0; d[$61] := 255;
  d[$62] := 7;        // sample header at paragraph 7 ($70)
  d[$64] := 12;       // pattern at paragraph 12 ($C0)
  d[$70] := 1;
  d[$7E] := 16;       // sample data at paragraph 16 ($100)
  d[$80] := 8;        // length
  d[$8C] := 64;       // volume
  d[$90] := $AB; d[$91] := $20;   // C2Spd 8363
  d[$B0 + 28 - 28] := 0;
  d[$70 + $4C] := Ord('S'); d[$70 + $4D] := Ord('C'); d[$70 + $4E] := Ord('R'); d[$70 + $4F] := Ord('S');
  d[$C0] := 69; d[$C1] := 0;
  d[$C2] := 32 or 0; d[$C3] := $40; d[$C4] := 1; d[$C5] := 0;
  for i := 0 to 7 do d[$100 + i] := Byte(128 + i * 8);
  Check(LegacyFormatOfData(d) = lfS3M, 'sniffed as S3M');
  m := LegacyToModule(d, info);
  try
    CheckEqualInt(2, m.Channels, 'two PCM channels');
    CheckEqualInt(1, m.InstrumentCount, 'one sample');
    CheckEqualInt(61, m.GetPattern(0).GetCell(0, 0).Note, 'C-5 (octave 4, note 0) is note 61');
    CheckEqualInt(1, m.GetPattern(0).GetCell(0, 0).Instrument, 'sample 1');
    CheckEqualInt(8363, m.GetInstrument(1).SampleRate, 'C2Spd carried over');
    CheckEqualInt(8, m.GetInstrument(1).FrameCount, 'sample length');
    CheckEqualInt(1, m.OrderLength, 'the end marker stops the order list');
  finally
    m.Free;
  end;
end;

{ real ScreamTracker modules (OpenMPT's own example songs and a few others), when this machine has
  them: each must load, carry notes and samples, and play to audible, in-range sound }
procedure Test_Legacy_RealS3M;
const
  FILES: array[0..3] of string = (
    'G:\Studio\OpenMPT\ExampleSongs\ASIKWUSpulse - Shrubbing.s3m',
    'G:\Studio\OpenMPT\ExampleSongs\LPChip - No Mercy [s13].s3m',
    'G:\Studio\Mine\Computerised\Other Artist\batman_1.s3m',
    'G:\Studio\Mine\Computerised\Other Artist\the_void.s3m');
var
  i, j, k, notes, minN, maxN: Integer;
  m: TTrackerModule;
  info: TLegacyImportInfo;
  pl: TTrackerPlayer;
  planar: TAudioPlanar;
  pk: Single;
  cell: TTrackerCell;
  seen: Integer;
begin
  seen := 0;
  for i := 0 to High(FILES) do
  begin
    if not FileExists(FILES[i]) then Continue;
    Inc(seen);
    m := LoadLegacyFile(FILES[i], info);
    try
      Check(info.Format = lfS3M, 'sniffed as S3M: ' + ExtractFileName(FILES[i]));
      Check(m.Channels >= 1, 'has channels: ' + ExtractFileName(FILES[i]));
      Check(m.InstrumentCount > 0, 'has samples: ' + ExtractFileName(FILES[i]));
      notes := 0;
      minN := 999;
      maxN := 0;
      for j := 0 to m.PatternCount - 1 do
        for k := 0 to m.GetPattern(j).Rows * m.Channels - 1 do
        begin
          cell := m.GetPattern(j).GetCell(k div m.Channels, k mod m.Channels);
          if (cell.Note >= TRK_NOTE_MIN) and (cell.Note <= TRK_NOTE_MAX) then
          begin
            Inc(notes);
            minN := Min(minN, cell.Note);
            maxN := Max(maxN, cell.Note);
          end;
        end;
      Check(notes > 0, 'has notes: ' + ExtractFileName(FILES[i]));
      Check((minN >= 13) and (maxN <= 108), Format('notes within the S3M range (%d..%d): %s', [minN, maxN, ExtractFileName(FILES[i])]));
      pl := TTrackerPlayer.Create(m);
      try
        pl.Prepare(SR, 4096, 2);
        planar := pl.RenderToPlanar(SR * 4, 2, 4096);
        pk := 0;
        for j := 0 to High(planar[0]) do pk := Max(pk, Abs(planar[0][j]));
        Check(pk > 0.01, Format('plays audibly (peak %.3f): %s', [pk, ExtractFileName(FILES[i])]));
      finally
        pl.Free;
      end;
    finally
      m.Free;
    end;
  end;
  if seen = 0 then Check(True, 'no example S3M files on this machine - skipped');
end;

{ the last path of each file dialog is part of the project file and comes back with it }
procedure Test_Project_DialogPaths;
var
  doc, back: TProjectDocument;
  s: string;
begin
  doc := TProjectDocument.CreateNew('dialogs');
  try
    doc.DialogPaths.Put('dlgOpenMod', 'G:\Studio\Music\song.mod');
    doc.DialogPaths.Put('folder:Choose a folder', 'D:\Samples');
    s := ProjectToString(doc);
    Check(Pos('DIALOGS-BEGIN', s) > 0, 'the dialogs section is written');
    back := ProjectFromString(s);
    try
      CheckEqualStr('G:\Studio\Music\song.mod', back.DialogPaths.Get('dlgOpenMod'), 'a file dialog path survives');
      CheckEqualStr('D:\Samples', back.DialogPaths.Get('folder:Choose a folder'), 'a folder dialog path survives');
      CheckEqualStr('', back.DialogPaths.Get('dlgNeverUsed'), 'an unused dialog has none');
    finally
      back.Free;
    end;
  finally
    doc.Free;
  end;
end;

{ the score as a PDF: a well-formed file whose cross-reference table points at real objects }
procedure Test_Score_PdfFile;
var
  notes: TArray<TScoreNote>;
  chords: TArray<TScoreChord>;
  opt: TScoreOptions;
  cv: TGLCanvas;
  rec: TScorePdfRecorder;
  lay: TScoreLayout;
  path, txt: string;
  bytes: TBytes;
  pages, i, xrefAt, entries, off, tab: Integer;
  fs: TFileStream;
  pass: Integer;
begin
  SetLength(notes, 12);
  for i := 0 to 11 do
  begin
    notes[i].StartQ := i * 0.5;
    notes[i].LenQ := 0.5;
    notes[i].Pitch := 52 + (i * 5) mod 24;
    notes[i].Color := clNone;
  end;
  SetLength(chords, 0);
  path := IncludeTrailingPathDelimiter(GetCurrentDir) + 'udaw-score-test.pdf';
  for pass := 0 to 1 do
  begin
    opt := Default(TScoreOptions);
    opt.QuantQ := 0.25;
    opt.Zoom := 1.0;
    opt.SigNum := 4;
    opt.SigDen := 4;
    opt.BarQ := 4;
    opt.Print := True;
    opt.Tab := pass = 1;
    cv := TGLCanvas.Create;
    rec := TScorePdfRecorder.Create;
    try
      cv.Recorder := rec;
      ScoreRender(cv, 1100, MaxInt div 2, notes, chords, opt, lay);
      pages := rec.SaveToFile(path, 'Test', lay, 1100);
    finally
      rec.Free;
      cv.Free;
    end;
    Check(pages >= 1, 'at least one page');
    fs := TFileStream.Create(path, fmOpenRead);
    try
      SetLength(bytes, fs.Size);
      fs.ReadBuffer(bytes[0], fs.Size);
    finally
      fs.Free;
    end;
    SetLength(txt, Length(bytes));
    for i := 0 to High(bytes) do txt[i + 1] := Chr(bytes[i]);
    Check(Copy(txt, 1, 8) = '%PDF-1.4', 'the PDF header');
    Check(Pos('%%EOF', txt) > 0, 'the end marker');
    xrefAt := Pos(#10'xref'#10, txt);
    Check(xrefAt > 0, 'a cross-reference table');
    { every entry of the table points at "<n> 0 obj" }
    tab := xrefAt + 6;
    entries := StrToIntDef(Trim(Copy(txt, tab + 2, Pos(#10, Copy(txt, tab + 2, 20)) - 1)), 0);
    Check(entries > 5, 'objects are listed');
    tab := Pos(#10, Copy(txt, tab, 40)) + tab;      // past "0 N"
    tab := tab + 20;                                // past the free entry
    for i := 1 to entries - 1 do
    begin
      off := StrToIntDef(Copy(txt, tab + (i - 1) * 20, 10), -1);
      Check(Copy(txt, off + 1, Length(IntToStr(i)) + 6) = IntToStr(i) + ' 0 obj', 'xref entry ' + IntToStr(i) + ' points at its object');
    end;
    if GetEnvironmentVariable('UDAW_KEEP_PDF') <> '' then RenameFile(path, ChangeFileExt(path, IntToStr(pass) + '.pdf'))
    else DeleteFile(path);
  end;
end;

{ removed legacy formats (and plain garbage) are not recognised as modules }
procedure Test_Legacy_Rejected;
var
  d: TBytes;
begin
  SetLength(d, 2000);
  FillChar(d[0], Length(d), 7);
  Check(LegacyFormatOfData(d) = lfNone, 'garbage is not a module');
  { a 669 header is no longer a supported module }
  FillChar(d[0], Length(d), 0);
  d[0] := $69; d[1] := $66;
  Check(LegacyFormatOfData(d) = lfNone, '669 is no longer supported');
  Check(not IsLegacyModuleExt('.669'), '.669 not an import extension');
  Check(not IsLegacyModuleExt('.stm'), '.stm not an import extension');
  Check(IsLegacyModuleExt('.s3m'), '.s3m still an import extension');
end;

{ Play Pattern: only the chosen pattern sounds, and it starts over at its end instead of moving on }
procedure Test_Player_LoopPattern;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  tmp: TAudioBuffer;
  i, seen: Integer;
  wrapped: Boolean;
  lastRow: Integer;
begin
  m := SineModule(220.0);
  pl := nil;
  tmp := nil;
  try
    m.AddPattern(4);                     // pattern 1: four rows, not in the order list
    pl := TTrackerPlayer.Create(m);
    pl.LoopPattern := 1;
    pl.Prepare(SR, 4096, 2);
    tmp := TAudioBuffer.Create(2, 4096, SR);
    wrapped := False;
    lastRow := -1;
    seen := 0;
    for i := 1 to 40 do               // about 3.4 s: many times the four rows
    begin
      pl.RenderBlock(tmp);
      Check(pl.CurrentPatternIndex = 1, 'the chosen pattern stays the one playing');
      Check((pl.CurrentRow >= 0) and (pl.CurrentRow < 4), 'the row stays inside the pattern');
      if pl.CurrentRow < lastRow then wrapped := True;
      lastRow := pl.CurrentRow;
      Inc(seen);
    end;
    Check(wrapped, 'the pattern starts over at its end');
    CheckEqualInt(0, pl.CurrentOrder, 'the order position does not move');
  finally
    tmp.Free;
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Player_PortamentoUp;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  tmp: TAudioBuffer;
  n0, n5: Double;
begin
  m := SineModule(220.0);
  pl := nil;
  tmp := nil;
  try
    m.GetPattern(0).SetCell(0, 0, Cell(NoteName(m.GetInstrument(1).RootNote), 1, tfxPortaUp, $20));
    pl := TTrackerPlayer.Create(m);
    pl.Prepare(SR, 4096, 2);
    tmp := TAudioBuffer.Create(2, 4096, SR);
    pl.RenderBlock(tmp);            // tick 0 (no slide)
    n0 := pl.DebugChannelNote(0);
    pl.RenderBlock(tmp);
    pl.RenderBlock(tmp);
    pl.RenderBlock(tmp);
    pl.RenderBlock(tmp);
    n5 := pl.DebugChannelNote(0);
    Check(n5 > n0 + 1.0, 'portamento up raises the pitch over several ticks');
  finally
    tmp.Free;
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Player_TonePortamento;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  tmp: TAudioBuffer;
  root: Byte;
  n0, n8: Double;
  blk: Integer;
begin
  m := SineModule(220.0);
  pl := nil;
  tmp := nil;
  try
    root := m.GetInstrument(1).RootNote;
    m.GetPattern(0).Resize(16);
    m.GetPattern(0).SetCell(0, 0, Cell(NoteName(root), 1, tfxNone, 0));
    m.GetPattern(0).SetCell(1, 0, Cell(NoteName(root + 12), 1, tfxTonePorta, $10));
    pl := TTrackerPlayer.Create(m);
    blk := Round(2.5 * SR / 125);      // one tick per block
    pl.Prepare(SR, blk, 2);
    tmp := TAudioBuffer.Create(2, blk, SR);
    pl.RenderBlock(tmp);               // row 0, tick 0
    n0 := pl.DebugChannelNote(0);
    { speed is 6 -> ticks 1..5 finish row 0, then ticks in row 1 glide }
    pl.RenderBlock(tmp); pl.RenderBlock(tmp); pl.RenderBlock(tmp);
    pl.RenderBlock(tmp); pl.RenderBlock(tmp);   // now at row 1 tick 0
    pl.RenderBlock(tmp); pl.RenderBlock(tmp); pl.RenderBlock(tmp);
    pl.RenderBlock(tmp);
    n8 := pl.DebugChannelNote(0);
    CheckNear(Double(root), n0, 0.001, 'row 0 sounds the root exactly');
    Check((n8 > n0 + 0.5) and (n8 < root + 12.0 + 0.001),
      'tone portamento glides toward the target without overshooting');
  finally
    tmp.Free;
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Player_VolumeSlideDown;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  tmp: TAudioBuffer;
  v0, v5: Double;
begin
  m := SineModule(220.0);
  pl := nil;
  tmp := nil;
  try
    m.GetPattern(0).SetCell(0, 0, Cell(NoteName(m.GetInstrument(1).RootNote), 1, tfxVolSlide, $02));
    pl := TTrackerPlayer.Create(m);
    pl.Prepare(SR, 4096, 2);
    tmp := TAudioBuffer.Create(2, 4096, SR);
    pl.RenderBlock(tmp);
    v0 := pl.DebugChannelVolume(0);
    pl.RenderBlock(tmp); pl.RenderBlock(tmp); pl.RenderBlock(tmp); pl.RenderBlock(tmp);
    v5 := pl.DebugChannelVolume(0);
    Check(v5 < v0 - 0.02, 'D02 slides the channel volume down');
  finally
    tmp.Free;
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Player_SetSpeedAndBPM;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  tmp: TAudioBuffer;
begin
  m := SineModule(220.0);
  pl := nil;
  tmp := nil;
  try
    m.GetPattern(0).SetCell(0, 1, Cell('...', 0, tfxSetSpeed, $03));
    m.GetPattern(0).SetCell(0, 2, Cell('...', 0, tfxSetBPM, $96));   // 150
    pl := TTrackerPlayer.Create(m);
    pl.Prepare(SR, 2048, 2);
    tmp := TAudioBuffer.Create(2, 2048, SR);
    pl.RenderBlock(tmp);
    CheckEqualInt(3, pl.Speed, 'A03 set ticks-per-row to 3');
    CheckEqualInt(150, pl.BPM, 'T96 set BPM to 150');
  finally
    tmp.Free;
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Player_PositionJump;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  tmp: TAudioBuffer;
  i: Integer;
begin
  m := SineModule(220.0);
  pl := nil;
  tmp := nil;
  try
    m.AddPattern(16);
    m.AppendOrder(1);
    m.GetPattern(0).SetCell(2, 0, Cell('...', 0, tfxPositionJump, $01));
    pl := TTrackerPlayer.Create(m);
    pl.LoopSong := False;
    pl.Prepare(SR, 4096, 2);
    tmp := TAudioBuffer.Create(2, 4096, SR);
    for i := 0 to 40 do
      pl.RenderBlock(tmp);
    Check(pl.CurrentOrder >= 1, 'B01 jumped to order position 1');
  finally
    tmp.Free;
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Player_NoteCutAndDelay;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  tmp: TAudioBuffer;
  root: Byte;
  activeAt0: Boolean;
  blk: Integer;
begin
  m := SineModule(220.0);
  pl := nil;
  tmp := nil;
  try
    root := m.GetInstrument(1).RootNote;
    m.GetPattern(0).Resize(16);
    m.GetPattern(0).SetCell(0, 0, Cell(NoteName(root), 1, tfxNoteDelay, $03));
    pl := TTrackerPlayer.Create(m);
    blk := Round(2.5 * SR / 125);     // one tick per block
    pl.Prepare(SR, blk, 2);
    tmp := TAudioBuffer.Create(2, blk, SR);
    pl.RenderBlock(tmp);              // tick 0 - note deferred to tick 3
    activeAt0 := pl.DebugChannelActive(0);
    pl.RenderBlock(tmp);             // tick 1
    pl.RenderBlock(tmp);             // tick 2
    pl.RenderBlock(tmp);             // tick 3 - triggers now
    Check((not activeAt0) and pl.DebugChannelActive(0),
      'note delay W03 defers the trigger to a later tick');
  finally
    tmp.Free;
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Player_SongLoopAndEnd;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  o: TAudioPlanar;
begin
  m := SineModule(220.0);
  pl := nil;
  try
    m.GetPattern(0).Resize(4);
    pl := TTrackerPlayer.Create(m);

    pl.LoopSong := True;
    o := pl.RenderToPlanar(SR, 2);   // ~1 s, several 4-row loops
    Check(pl.LoopCount >= 1, 'the song loops back to the restart position');
    Check(AllFinitePl(o), 'looped output stays finite');

    pl.LoopSong := False;
    o := pl.RenderToPlanar(SR, 2);
    Check(pl.SongEnded, 'with looping off the song ends');
  finally
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Player_PingPongLoopStable;
var
  m: TTrackerModule;
  pl: TTrackerPlayer;
  o: TAudioPlanar;
begin
  m := SineModule(220.0);
  pl := nil;
  try
    m.GetInstrument(1).LoopMode := tlmPingPong;
    pl := TTrackerPlayer.Create(m);
    o := pl.RenderToPlanar(SR, 2);
    Check(AllFinitePl(o), 'ping-pong loop stays finite over a second');
    Check(PlanarRms(o, 0, SR div 2, SR) > 0.02, 'and keeps producing sound (does not run off the end)');
  finally
    pl.Free;
    m.Free;
  end;
end;

{ ================= serialization ================= }

function BuildRichModule: TTrackerModule;
var
  ins: TTrackerInstrument;
  e: TTrackerEnvelope;
  p: TTrackerPattern;
begin
  Result := TTrackerModule.Create;
  Result.InitDefault;
  Result.Name := 'Demo Song';
  Result.SetChannels(4);
  Result.InitialSpeed := 4;
  Result.InitialBPM := 140;
  Result.GlobalVolume := 0.8;
  Result.AddPattern(32);
  Result.AppendOrder(1);
  Result.AppendOrder(0);
  Result.RestartPos := 1;

  ins := Result.AddInstrument('Lead');
  ins.MakeSine(330.0, 0.05, SR, 0.6);
  ins.Fadeout := 0.02;
  e.Clear; e.Enabled := True; e.SustainPoint := 1;
  e.AddPoint(0, 1.0); e.AddPoint(20, 0.6); e.AddPoint(60, 0.0);
  ins.VolEnv := e;

  p := Result.GetPattern(0);
  p.SetCell(0, 0, Cell('C-4', 1, tfxArpeggio, $37));
  p.SetCell(1, 0, Cell('D#4', 1, tfxVibrato, $84));
  p.SetCell(2, 0, Cell('===', 0, tfxNone, 0));
  p.SetCell(0, 1, Cell('G-3', 1, tfxSetVolume, $20));
  p.SetCell(4, 2, Cell('...', 0, tfxSetSpeed, $06));
end;

procedure Test_Serialize_RoundTrip;
var
  a, b: TTrackerModule;
  ca, cb: TTrackerCell;
  i: Integer;
  same: Boolean;
begin
  a := BuildRichModule;
  try
    b := TrackerModuleFromString(TrackerModuleToString(a));
    try
      CheckEqualStr(a.Describe, b.Describe, 'Describe round-trips');
      ca := a.GetPattern(0).GetCell(0, 0);
      cb := b.GetPattern(0).GetCell(0, 0);
      Check((ca.Note = cb.Note) and (ca.Instrument = cb.Instrument)
        and (ca.Effect = cb.Effect) and (ca.Param = cb.Param), 'cell 0,0 round-trips');
      CheckEqualInt(a.GetInstrument(1).FrameCount, b.GetInstrument(1).FrameCount,
        'sample length round-trips');
      same := True;
      for i := 0 to a.GetInstrument(1).FrameCount - 1 do
        if a.GetInstrument(1).Data[i] <> b.GetInstrument(1).Data[i] then same := False;
      Check(same, 'sample PCM is bit-exact through the hex payload');
      Check(b.GetInstrument(1).VolEnv.Enabled, 'volume envelope round-trips');
    finally
      b.Free;
    end;
  finally
    a.Free;
  end;
end;

procedure Test_Serialize_Rejects;
begin
  try
    TrackerModuleFromString('UDAWTRACKER 9'#10).Free;
    Fail('unsupported version should raise');
  except
    on E: EUDAWError do CheckEqualInt(Ord(errConfig), Ord(E.Code), 'errConfig on bad version');
  end;
  try
    TrackerModuleFromString('UDAWTRACKER 1'#10'PATTERN 0 rows=4'#10'R00 C-4 01 40 ?09'#10).Free;
    Fail('bad effect letter should raise');
  except
    on E: EUDAWError do CheckEqualInt(Ord(errConfig), Ord(E.Code), 'errConfig on bad effect');
  end;
end;

procedure Test_Serialize_CellText;
var
  a: TTrackerCell;
begin
  a := Cell('C-4', 1, tfxSetSpeed, 6);
  a.Volume := $40;
  { A06 -> effect A = tfxSetSpeed, param 6 }
  Check(EffectLetter(tfxSetSpeed) = 'A', 'set-speed is effect A');
end;

procedure Test_Serialize_EmbeddedInProjectV4;
var
  doc, back: TProjectDocument;
  s: string;
begin
  doc := TProjectDocument.CreateNew('trk proj');
  try
    doc.Tracker.Name := 'Embedded';
    doc.Tracker.AddPattern(16);
    doc.Tracker.AddInstrument('Bass').MakeSine(110.0, 0.03, SR, 0.5);
    doc.Tracker.GetPattern(0).SetCell(0, 0, Cell('C-3', 1, tfxNone, 0));
    s := ProjectToString(doc);
    { PROJECT_FILE_VERSION, not a hardcoded literal: it moves on whenever a
      later phase's project format changes (v4 -> v5 for Phase 17's MIDI
      section) and a stale literal here would silently start failing again. }
    Check(Pos(Format('UDAWPROJECT %d', [PROJECT_FILE_VERSION]), s) = 1, 'project file is the current version');
    Check(Pos('TRACKER-BEGIN', s) > 0, 'tracker section is written');
    back := ProjectFromString(s);
    try
      CheckEqualStr('Embedded', back.Tracker.Name, 'module name survives');
      CheckEqualInt(2, back.Tracker.PatternCount, 'patterns survive');
      CheckEqualInt(1, back.Tracker.InstrumentCount, 'instrument survives');
      Check(back.Tracker.GetPattern(0).GetCell(0, 0).Note = 37, 'a cell survives (C-3 = 37)');
    finally
      back.Free;
    end;
  finally
    doc.Free;
  end;
end;

procedure Test_Serialize_PreV4GainsModule;
var
  doc, back: TProjectDocument;
  s: string;
  p: Integer;
begin
  doc := TProjectDocument.CreateNew('old');
  try
    s := ProjectToString(doc);
  finally
    doc.Free;
  end;
  p := Pos('TRACKER-BEGIN', s);
  if p > 0 then s := Copy(s, 1, p - 1);
  s := StringReplace(s, 'UDAWPROJECT 4', 'UDAWPROJECT 3', []);
  back := ProjectFromString(s);
  try
    Check(back.Tracker.PatternCount >= 1, 'a pre-v4 project gets a default tracker module');
  finally
    back.Free;
  end;
end;

{ ================= commands ================= }

procedure Test_Cmd_SetCellUndoRedo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    mgr.Perform(TSetTrackerCellCommand.Create(doc, 0, 5, 0, Cell('C-4', 1, tfxNone, 0)));
    Check(doc.Tracker.GetPattern(0).GetCell(5, 0).Note = 49, 'cell set');
    mgr.Undo;
    Check(doc.Tracker.GetPattern(0).GetCell(5, 0).IsEmpty, 'undo clears the cell');
    mgr.Redo;
    Check(doc.Tracker.GetPattern(0).GetCell(5, 0).Note = 49, 'redo restores it');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Cmd_AddRemovePatternUndoRedo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    mgr.Perform(TAddTrackerPatternCommand.Create(doc, 48));
    CheckEqualInt(2, doc.Tracker.PatternCount, 'pattern added');
    mgr.Undo;
    CheckEqualInt(1, doc.Tracker.PatternCount, 'undo removes it');
    mgr.Redo;
    CheckEqualInt(2, doc.Tracker.PatternCount, 'redo puts it back');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Cmd_TransportMerges;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    mgr.Perform(TSetTrackerTransportCommand.Create(doc, True, 4));
    mgr.Perform(TSetTrackerTransportCommand.Create(doc, True, 3));
    mgr.Perform(TSetTrackerTransportCommand.Create(doc, True, 8));
    CheckEqualInt(1, mgr.UndoCount, 'three fast speed changes merge to one undo');
    CheckEqualInt(8, doc.Tracker.InitialSpeed, 'latest value stuck');
    mgr.Undo;
    CheckEqualInt(TRK_DEFAULT_SPEED, doc.Tracker.InitialSpeed, 'one undo restores the original');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Cmd_AddInstrumentWithSine;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    mgr.Perform(TAddTrackerInstrumentCommand.Create(doc, 'Lead', 440.0, 0.05));
    CheckEqualInt(1, doc.Tracker.InstrumentCount, 'instrument added');
    Check(doc.Tracker.GetInstrument(1).FrameCount > 0, 'with sample data from the sine fill');
    mgr.Undo;
    CheckEqualInt(0, doc.Tracker.InstrumentCount, 'undo removes it');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

{ ---------------- registration ---------------- }

procedure RegisterPhase11Tests;
begin
  RegisterTest('tracker.types', 'note names + frequencies',   @Test_Types_Notes);
  RegisterTest('tracker.types', 'effect letters round-trip',  @Test_Types_EffectLetters);

  RegisterTest('tracker.model', 'pattern resize keeps rows',  @Test_Pattern_ResizeKeepsRows);
  RegisterTest('tracker.model', 'order table + patterns',     @Test_Module_OrderAndPatterns);
  RegisterTest('tracker.model', 'instrument slots',           @Test_Module_Instruments);
  RegisterTest('tracker.model', 'clone is independent',       @Test_Module_CloneIndependent);

  RegisterTest('tracker.instr', 'envelope interpolation',     @Test_Envelope_Interp);
  RegisterTest('tracker.instr', 'MakeSine',                   @Test_Instrument_MakeSine);

  RegisterTest('tracker.player', 'silence when empty',        @Test_Player_SilenceWhenEmpty);
  RegisterTest('tracker.player', 'note plays a tone',         @Test_Player_NotePlaysTone);
  RegisterTest('tracker.player', 'octave up doubles pitch',   @Test_Player_OctaveUp);
  RegisterTest('tracker.player', 'arpeggio',                  @Test_Player_Arpeggio);
  RegisterTest('tracker.player', 'portamento up',             @Test_Player_PortamentoUp);
  RegisterTest('tracker.player', 'play pattern loops one pattern', @Test_Player_LoopPattern);
  RegisterTest('tracker.player', 'fine portamento is one-shot', @Test_Player_FinePortaOnce);
  RegisterTest('tracker.instrument', 'key map layers',        @Test_Instrument_KeyMapLayers);
  RegisterTest('tracker.legacy', 'S3M module reads',          @Test_Legacy_S3M);
  RegisterTest('tracker.legacy', 'removed formats are rejected', @Test_Legacy_Rejected);
  RegisterTest('project.dialogs', 'dialog paths are saved with the project', @Test_Project_DialogPaths);
  RegisterTest('score.pdf', 'staff and tab write a well-formed PDF', @Test_Score_PdfFile);
  RegisterTest('tracker.legacy', 'real S3M files load and play', @Test_Legacy_RealS3M);
  RegisterTest('tracker.score', 'notes + channel/instrument filters', @Test_ScoreNotes_Filter);
  RegisterTest('tracker.player', 'tone portamento',           @Test_Player_TonePortamento);
  RegisterTest('tracker.player', 'volume slide down',         @Test_Player_VolumeSlideDown);
  RegisterTest('tracker.player', 'set speed + BPM',           @Test_Player_SetSpeedAndBPM);
  RegisterTest('tracker.player', 'position jump',             @Test_Player_PositionJump);
  RegisterTest('tracker.player', 'note delay',                @Test_Player_NoteCutAndDelay);
  RegisterTest('tracker.player', 'song loop + end',           @Test_Player_SongLoopAndEnd);
  RegisterTest('tracker.player', 'ping-pong loop stable',     @Test_Player_PingPongLoopStable);

  RegisterTest('tracker.serialize', 'round-trip incl. PCM',   @Test_Serialize_RoundTrip);
  RegisterTest('tracker.serialize', 'rejects bad docs',       @Test_Serialize_Rejects);
  RegisterTest('tracker.serialize', 'cell text',              @Test_Serialize_CellText);
  RegisterTest('tracker.serialize', 'embedded in project v4', @Test_Serialize_EmbeddedInProjectV4);
  RegisterTest('tracker.serialize', 'pre-v4 gains a module',  @Test_Serialize_PreV4GainsModule);

  RegisterTest('tracker.commands', 'set cell undo/redo',      @Test_Cmd_SetCellUndoRedo);
  RegisterTest('tracker.commands', 'add/remove pattern',      @Test_Cmd_AddRemovePatternUndoRedo);
  RegisterTest('tracker.commands', 'transport merges',        @Test_Cmd_TransportMerges);
  RegisterTest('tracker.commands', 'add instrument + sine',   @Test_Cmd_AddInstrumentWithSine);
end;

end.
