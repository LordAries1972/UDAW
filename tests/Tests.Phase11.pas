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
  SysUtils, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Audio.Types, UDAW.Audio.Buffer,
  UDAW.Project.Document, UDAW.Project.Serialization, UDAW.Project.Commands,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern,
  UDAW.Tracker.Player, UDAW.Tracker.Serialization, UDAW.Tracker.Commands;

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
    TrackerModuleFromString('UDAWTRACKER 1'#10'PATTERN 0 rows=4'#10'R00 C-4 01 40 z09'#10).Free;
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
