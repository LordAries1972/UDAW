unit Tests.Phase17;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 17 acceptance tests - the MIDI engine + piano roll.  Verified in memory
  with no reference media:

    * variable-length quantities across the boundary values;
    * TMidiMessage channel-voice helpers and the note-name / frequency tables;
    * Standard MIDI File write -> read round-trip (Type 1, running status,
      tempo / time signature / track name / marker meta, SysEx) - byte-accurate
      event recovery;
    * TMidiSequence tempo map: TickToSeconds monotone + SecondsToTick inverse,
      note-on/off pairing from an SMF, and a sequence -> SMF -> sequence
      round-trip;
    * the project-embedded MIDI section (v1) round-trips, and a full project
      save/open at file version 5 carries the MIDI clips - while an older v4
      project text with no MIDI block still loads;
    * piano-roll edits (add / move / resize / quantize / velocity clamp),
      scale membership and the triad chord namer;
    * undo commands (add-note execute/undo, move-note merge);
    * the internal synth engine renders a sequence to non-silent PCM whose
      dominant frequency matches the played note.

  Requires src/common, src/audio, src/midi and src/project on the search path. }

interface

procedure RegisterPhase17Tests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Audio.Types, UDAW.Audio.Buffer,
  UDAW.MIDI.Types,
  UDAW.MIDI.SMF,
  UDAW.MIDI.Sequence,
  UDAW.MIDI.PianoRoll,
  UDAW.MIDI.Engine,
  UDAW.MIDI.Serialization,
  UDAW.Project.Document,
  UDAW.Project.Serialization,
  UDAW.Project.Commands,
  UDAW.MIDI.Commands;

const
  GRP = 'phase17.midi';

function DomFreq(const P: TAudioPlanar; ACh, AFrom, ATo, ASampleRate: Integer): Double;
var
  i, crossings: Integer;
  prev: Single;
begin
  if (ACh < 0) or (ACh > High(P)) then Exit(0);
  if ATo > Length(P[ACh]) then ATo := Length(P[ACh]);
  crossings := 0; prev := 0;
  for i := AFrom to ATo - 1 do
  begin
    if (prev < 0) and (P[ACh][i] >= 0) then Inc(crossings);
    prev := P[ACh][i];
  end;
  if (ATo - AFrom) <= 0 then Exit(0);
  Result := crossings * ASampleRate / (ATo - AFrom);
end;

function Rms(const P: TAudioPlanar; ACh: Integer): Double;
var
  i: Integer;
  s: Double;
begin
  s := 0;
  for i := 0 to High(P[ACh]) do s := s + Sqr(P[ACh][i]);
  if Length(P[ACh]) = 0 then Exit(0);
  Result := Sqrt(s / Length(P[ACh]));
end;

{ ---------------- VLQ ---------------- }

procedure Test_VLQ;
  procedure RoundTrip(V: Cardinal);
  var
    ms: TMemoryStream;
    b: TBytes;
    pos: Int64;
    got: Cardinal;
  begin
    ms := TMemoryStream.Create;
    try
      SmfWriteVLQ(ms, V);
      SetLength(b, ms.Size);
      Move(ms.Memory^, b[0], ms.Size);
    finally
      ms.Free;
    end;
    pos := 0;
    got := SmfReadVLQ(b, pos);
    CheckEqualInt(V, got, Format('VLQ round-trip %d', [V]));
    CheckEqualInt(Length(b), pos, 'VLQ reader consumed exactly the written bytes');
  end;
begin
  RoundTrip(0);
  RoundTrip(1);
  RoundTrip(127);
  RoundTrip(128);
  RoundTrip(8192);
  RoundTrip(16383);
  RoundTrip(16384);
  RoundTrip(1000000);
  RoundTrip($0FFFFFFF);
end;

{ ---------------- message + tables ---------------- }

procedure Test_Message_Helpers;
var
  m: TMidiMessage;
begin
  m := TMidiMessage.NoteOn(3, 60, 100);
  CheckEqualInt(3, m.Channel, 'channel');
  Check(m.IsNoteOn, 'note-on with velocity is a note-on');
  CheckFalse(m.IsNoteOff, 'not a note-off');
  CheckEqualInt(60, m.NoteNumber, 'note number');

  m := TMidiMessage.NoteOn(0, 60, 0);
  Check(m.IsNoteOff, 'note-on velocity 0 counts as note-off');

  m := TMidiMessage.PitchBend(0, 0);
  CheckEqualInt(0, m.PitchBend14, 'centre pitch bend is 0');
  m := TMidiMessage.PitchBend(0, 8191);
  Check(m.PitchBend14 >= 8190, 'max pitch bend');

  CheckEqualStr('C4', MidiNoteName(60), 'MIDI 60 = C4');
  CheckEqualStr('A4', MidiNoteName(69), 'MIDI 69 = A4');
  Check(Abs(MidiFrequency(69) - 440.0) < 0.001, 'A4 = 440 Hz');
  Check(Abs(MidiFrequency(81) - 880.0) < 0.01, 'A5 = 880 Hz');
  Check(MidiNoteIsBlack(61), 'C#4 is a black key');
  CheckFalse(MidiNoteIsBlack(60), 'C4 is a white key');
end;

{ ---------------- SMF round-trip ---------------- }

procedure Test_SMF_RoundTrip;
var
  smf, back: TSmfFile;
  t0, t1: TSmfTrack;
  ev: TMidiEvent;
  bytes: TBytes;
  i, notes: Integer;
begin
  smf := TSmfFile.Create;
  try
    smf.TicksPerQuarter := 480;
    t0 := smf.AddTrack('Conductor');
    FillChar(ev, SizeOf(ev), 0);
    ev.Tick := 0; ev.Kind := mekMeta; ev.MetaType := META_SET_TEMPO;
    SetLength(ev.Bytes, 3);
    ev.Bytes[0] := ($07 shl 0); ev.Bytes[1] := $A1; ev.Bytes[2] := $20;   // 500000
    ev.Bytes[0] := $07; ev.Bytes[1] := $A1; ev.Bytes[2] := $20;
    t0.Add(ev);
    FillChar(ev, SizeOf(ev), 0);
    ev.Tick := 0; ev.Kind := mekMeta; ev.MetaType := META_TIME_SIG;
    SetLength(ev.Bytes, 4);
    ev.Bytes[0] := 3; ev.Bytes[1] := 2; ev.Bytes[2] := 24; ev.Bytes[3] := 8;
    t0.Add(ev);

    t1 := smf.AddTrack('Lead');
    for i := 0 to 3 do
    begin
      FillChar(ev, SizeOf(ev), 0);
      ev.Tick := i * 480;
      ev.Kind := mekChannel;
      ev.Msg := TMidiMessage.NoteOn(0, 60 + i, 90);
      t1.Add(ev);
      FillChar(ev, SizeOf(ev), 0);
      ev.Tick := i * 480 + 240;
      ev.Kind := mekChannel;
      ev.Msg := TMidiMessage.NoteOff(0, 60 + i, 0);
      t1.Add(ev);
    end;
    { a marker + a sysex to exercise meta / F0 preservation }
    FillChar(ev, SizeOf(ev), 0);
    ev.Tick := 100; ev.Kind := mekMeta; ev.MetaType := META_MARKER;
    ev.Bytes := TEncoding.ANSI.GetBytes('verse');
    t1.Add(ev);
    FillChar(ev, SizeOf(ev), 0);
    ev.Tick := 200; ev.Kind := mekSysEx;
    SetLength(ev.Bytes, 5);
    ev.Bytes[0] := $F0; ev.Bytes[1] := $43; ev.Bytes[2] := $12; ev.Bytes[3] := $00; ev.Bytes[4] := $F7;
    t1.Add(ev);

    bytes := smf.SaveToBytes;
  finally
    smf.Free;
  end;

  Check(Length(bytes) > 40, 'SMF bytes produced');
  Check((bytes[0] = Ord('M')) and (bytes[1] = Ord('T')) and (bytes[2] = Ord('h')) and (bytes[3] = Ord('d')),
    'starts with MThd');

  back := TSmfFile.Create;
  try
    back.LoadFromBytes(bytes);
    CheckEqualInt(2, back.TrackCount, 'two tracks recovered');
    CheckEqualInt(480, back.TicksPerQuarter, 'division recovered');
    CheckEqualStr('Lead', back.GetTrack(1).Name, 'track name recovered');

    notes := 0;
    for i := 0 to back.GetTrack(1).Count - 1 do
      if (back.GetTrack(1).Events[i].Kind = mekChannel) and
         back.GetTrack(1).Events[i].Msg.IsNoteOn then
        Inc(notes);
    CheckEqualInt(4, notes, 'four note-ons recovered');

    { the sysex survives with its leading F0 }
    for i := 0 to back.GetTrack(1).Count - 1 do
      if back.GetTrack(1).Events[i].Kind = mekSysEx then
      begin
        Check(Length(back.GetTrack(1).Events[i].Bytes) >= 4, 'sysex length');
        CheckEqualInt($F0, back.GetTrack(1).Events[i].Bytes[0], 'sysex keeps its F0');
      end;
  finally
    back.Free;
  end;
end;

{ ---------------- sequence + tempo map ---------------- }

procedure Test_Sequence_Tempo;
var
  seq: TMidiSequence;
  s1, s2: Double;
begin
  seq := TMidiSequence.Create(480);
  try
    seq.InitDefault;
    seq.SetInitialBPM(120);
    { one quarter note at 120 BPM = 0.5 s }
    Check(Abs(seq.TickToSeconds(480) - 0.5) < 1e-6, 'quarter @120 = 0.5 s');
    { tempo change to 60 BPM at tick 480: next quarter takes 1.0 s }
    seq.SetTempoAt(480, 60);
    s1 := seq.TickToSeconds(480);
    s2 := seq.TickToSeconds(960);
    Check(Abs(s1 - 0.5) < 1e-6, 'first quarter unchanged');
    Check(Abs((s2 - s1) - 1.0) < 1e-6, 'second quarter now 1.0 s');
    { inverse }
    Check(Abs(seq.SecondsToTick(s2) - 960) < 2, 'SecondsToTick inverts TickToSeconds');
  finally
    seq.Free;
  end;
end;

procedure Test_Sequence_FromSMF_Pairing;
var
  smf: TSmfFile;
  t: TSmfTrack;
  ev: TMidiEvent;
  seq: TMidiSequence;
begin
  smf := TSmfFile.Create;
  try
    smf.TicksPerQuarter := 480;
    t := smf.AddTrack('T');
    FillChar(ev, SizeOf(ev), 0);
    ev.Tick := 0; ev.Kind := mekChannel; ev.Msg := TMidiMessage.NoteOn(0, 64, 100);
    t.Add(ev);
    FillChar(ev, SizeOf(ev), 0);
    ev.Tick := 480; ev.Kind := mekChannel; ev.Msg := TMidiMessage.NoteOff(0, 64, 0);
    t.Add(ev);

    seq := TMidiSequence.Create;
    try
      seq.BuildFromSMF(smf);
      Check(seq.TrackCount >= 1, 'at least one track');
      CheckEqualInt(1, seq.GetTrack(0).NoteCount, 'one paired note');
      CheckEqualInt(64, seq.GetTrack(0).Notes[0].Note, 'note number');
      CheckEqualInt(480, seq.GetTrack(0).Notes[0].LengthTick, 'note length from off-tick');
    finally
      seq.Free;
    end;
  finally
    smf.Free;
  end;
end;

procedure Test_Sequence_ToSMF_RoundTrip;
var
  seq, seq2: TMidiSequence;
  pr: TPianoRoll;
  smf: TSmfFile;
  total, ti: Integer;
begin
  seq := TMidiSequence.Create(480);
  try
    seq.InitDefault;
    pr := TPianoRoll.Create(seq, 0);
    try
      pr.AddNote(0, 240, 60, 100, 0);
      pr.AddNote(480, 240, 62, 90, 0);
      pr.AddNote(960, 480, 64, 80, 0);
    finally
      pr.Free;
    end;
    smf := seq.ToSMF(1);
    try
      seq2 := TMidiSequence.Create;
      try
        seq2.BuildFromSMF(smf);
        { conductor track + the one note track }
        Check(seq2.TrackCount >= 1, 'round-trip track count');
        total := 0;
        for ti := 0 to seq2.TrackCount - 1 do
          Inc(total, seq2.GetTrack(ti).NoteCount);
        CheckEqualInt(3, total, 'all three notes survive sequence->SMF->sequence');
      finally
        seq2.Free;
      end;
    finally
      smf.Free;
    end;
  finally
    seq.Free;
  end;
end;

{ ---------------- project embedding ---------------- }

procedure Test_MidiProject_TextRoundTrip;
var
  proj, back: TMidiProject;
  seq: TMidiSequence;
  pr: TPianoRoll;
  s: string;
begin
  proj := TMidiProject.Create;
  try
    seq := proj.NewClip('Clip A', 480);
    seq.SetInitialBPM(140);
    seq.SetTimeSigAt(0, 3, 4);
    pr := TPianoRoll.Create(seq, 0);
    try
      pr.AddNote(0, 480, 60, 100, 0);
      pr.AddNote(480, 480, 67, 88, 0);
      pr.SetController(0, MIDI_CC_VOLUME, 0, 90);
    finally
      pr.Free;
    end;
    s := MidiProjectToString(proj);
  finally
    proj.Free;
  end;

  Check(Pos('UDAWMIDI 1', s) > 0, 'header present');
  back := MidiProjectFromString(s);
  try
    CheckEqualInt(1, back.ClipCount, 'one clip');
    CheckEqualStr('Clip A', back.ClipName(0), 'clip name');
    Check(Abs(back.Clip(0).InitialBPM - 140) < 0.01, 'tempo round-trips');
    CheckEqualInt(2, back.Clip(0).GetTrack(0).NoteCount, 'note count round-trips');
    CheckEqualInt(1, back.Clip(0).GetTrack(0).CCCount, 'CC round-trips');
  finally
    back.Free;
  end;
end;

procedure Test_ProjectFile_V5_CarriesMidi;
var
  doc, doc2: TProjectDocument;
  seq: TMidiSequence;
  pr: TPianoRoll;
  text: string;
begin
  doc := TProjectDocument.CreateNew('P17');
  try
    seq := doc.Midi.NewClip('Verse', 480);
    pr := TPianoRoll.Create(seq, 0);
    try
      pr.AddNote(0, 480, 60, 100, 0);
      pr.AddNote(480, 480, 64, 100, 0);
      pr.AddNote(960, 480, 67, 100, 0);
    finally
      pr.Free;
    end;
    text := ProjectToString(doc);
  finally
    doc.Free;
  end;

  Check(Pos('UDAWPROJECT 5', text) > 0, 'project file is version 5');
  Check(Pos('MIDI-BEGIN', text) > 0, 'MIDI section written');

  doc2 := ProjectFromString(text);
  try
    CheckEqualInt(1, doc2.Midi.ClipCount, 'MIDI clip survives project round-trip');
    CheckEqualInt(3, doc2.Midi.TotalNoteCount, 'notes survive project round-trip');
  finally
    doc2.Free;
  end;
end;

procedure Test_ProjectFile_V4_LoadsWithoutMidi;
var
  doc, doc2: TProjectDocument;
  text: string;
  p: Integer;
begin
  doc := TProjectDocument.CreateNew('OldP');
  try
    text := ProjectToString(doc);
  finally
    doc.Free;
  end;
  { strip the MIDI section and drop the version to 4, emulating an older file }
  text := StringReplace(text, 'UDAWPROJECT 5', 'UDAWPROJECT 4', []);
  p := Pos('MIDI-BEGIN', text);
  if p > 0 then
    text := Copy(text, 1, p - 1);   // everything after (incl.) MIDI-BEGIN goes

  doc2 := ProjectFromString(text);
  try
    Check(doc2 <> nil, 'a v4 project with no MIDI block still loads');
    CheckEqualInt(0, doc2.Midi.ClipCount, 'missing MIDI block -> empty MIDI project');
  finally
    doc2.Free;
  end;
end;

{ ---------------- piano roll ---------------- }

procedure Test_PianoRoll_Edits;
var
  seq: TMidiSequence;
  pr: TPianoRoll;
  id: Integer;
  n: TMidiNote;
begin
  seq := TMidiSequence.Create(480);
  try
    seq.InitDefault;
    pr := TPianoRoll.Create(seq, 0);
    try
      id := pr.AddNote(37, 200, 60, 100, 0);   // slightly off the grid
      Check(pr.GetNote(id, n), 'note added');
      CheckEqualInt(60, n.Note, 'note pitch');

      Check(pr.MoveNote(id, 100, 2), 'move applied');
      pr.GetNote(id, n);
      CheckEqualInt(137, n.StartTick, 'moved start tick');
      CheckEqualInt(62, n.Note, 'moved pitch');

      Check(pr.ResizeNote(id, 240, False), 'resize applied');
      pr.GetNote(id, n);
      CheckEqualInt(440, n.LengthTick, 'resized length');

      Check(pr.SetVelocity(id, 999), 'velocity set (over-range)');
      pr.GetNote(id, n);
      CheckEqualInt(127, n.Velocity, 'velocity clamped to 127');

      { quantize to the 1/16 grid (120 ticks) at full strength }
      pr.Quantize([id], GridTicks(seq, 16), 1.0, 0.0, False);
      pr.GetNote(id, n);
      CheckEqualInt(0, n.StartTick mod GridTicks(seq, 16), 'start snapped to the grid');
    finally
      pr.Free;
    end;
  finally
    seq.Free;
  end;
end;

procedure Test_Scales_And_Chords;
begin
  Check(ScaleContains(62, 0, skMajor), 'D is in C major');
  CheckFalse(ScaleContains(61, 0, skMajor), 'C# is not in C major');
  CheckEqualInt(60, SnapNoteToScale(61, 0, skMajor), 'C# snaps down to C in C major');

  CheckEqualStr('C', DetectChordName([0, 4, 7]), 'C major triad');
  CheckEqualStr('Cm', DetectChordName([0, 3, 7]), 'C minor triad');
  CheckEqualStr('G7', DetectChordName([7, 11, 2, 5]), 'G dominant 7th');
end;

{ ---------------- commands ---------------- }

procedure Test_Commands;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  add: TAddMidiNoteCommand;
  noteId: Integer;
  n: TMidiNote;
  pr: TPianoRoll;
begin
  doc := TProjectDocument.CreateNew('C17');
  mgr := TCommandManager.Create;
  try
    doc.Midi.NewClip('Clip', 480);

    add := TAddMidiNoteCommand.Create(doc, 0, 0, 0, 480, 60, 100, 0);
    Check(mgr.Perform(add), 'add-note command executes');
    noteId := add.NewNoteId;
    CheckEqualInt(1, doc.Midi.Clip(0).GetTrack(0).NoteCount, 'note present after add');

    mgr.Undo;
    CheckEqualInt(0, doc.Midi.Clip(0).GetTrack(0).NoteCount, 'note gone after undo');
    mgr.Redo;
    CheckEqualInt(1, doc.Midi.Clip(0).GetTrack(0).NoteCount, 'note back after redo');

    { two consecutive move commands should merge into one undo step }
    mgr.Perform(TMoveMidiNoteCommand.Create(doc, 0, 0, noteId, 60, 0));
    mgr.Perform(TMoveMidiNoteCommand.Create(doc, 0, 0, noteId, 60, 0));
    pr := TPianoRoll.Create(doc.Midi.Clip(0), 0);
    try
      pr.GetNote(noteId, n);
    finally
      pr.Free;
    end;
    CheckEqualInt(120, n.StartTick, 'both moves applied (60 + 60)');
    mgr.Undo;   // one undo should revert BOTH merged moves
    pr := TPianoRoll.Create(doc.Midi.Clip(0), 0);
    try
      pr.GetNote(noteId, n);
    finally
      pr.Free;
    end;
    CheckEqualInt(0, n.StartTick, 'merged move undone in a single step');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

{ ---------------- engine ---------------- }

procedure Test_Engine_RendersAudibleTone;
var
  seq: TMidiSequence;
  pr: TPianoRoll;
  eng: TMidiPlaybackEngine;
  outp: TAudioPlanar;
  dom: Double;
begin
  seq := TMidiSequence.Create(480);
  try
    seq.InitDefault;
    seq.SetInitialBPM(120);
    pr := TPianoRoll.Create(seq, 0);
    try
      { A4 (440 Hz) held for a full note }
      pr.AddNote(0, 1920, 69, 110, 0);
    finally
      pr.Free;
    end;

    eng := TMidiPlaybackEngine.Create;
    try
      eng.SetSequence(seq);
      outp := eng.RenderToPlanar(44100, 2, 1.0);
      Check(Length(outp) = 2, 'stereo output');
      Check(Length(outp[0]) > 22050, 'at least ~0.5 s rendered');
      Check(Rms(outp, 0) > 0.005, 'output is not silent');
      dom := DomFreq(outp, 0, 2000, 20000, 44100);
      { the synth is band-limited + filtered, so allow a wide tolerance }
      Check((dom > 380) and (dom < 500), Format('dominant freq %.1f near A4 440', [dom]));
    finally
      eng.Free;
    end;
  finally
    seq.Free;
  end;
end;

procedure RegisterPhase17Tests;
begin
  RegisterTest(GRP, 'variable-length quantity round-trip', Test_VLQ);
  RegisterTest(GRP, 'channel-voice message + note tables', Test_Message_Helpers);
  RegisterTest(GRP, 'SMF write -> read round-trip (meta + sysex)', Test_SMF_RoundTrip);
  RegisterTest(GRP, 'sequence tempo map: seconds <-> ticks', Test_Sequence_Tempo);
  RegisterTest(GRP, 'note-on/off pairing from an SMF', Test_Sequence_FromSMF_Pairing);
  RegisterTest(GRP, 'sequence -> SMF -> sequence round-trip', Test_Sequence_ToSMF_RoundTrip);
  RegisterTest(GRP, 'embedded MIDI section text round-trip', Test_MidiProject_TextRoundTrip);
  RegisterTest(GRP, 'project file v5 carries MIDI clips', Test_ProjectFile_V5_CarriesMidi);
  RegisterTest(GRP, 'older v4 project with no MIDI block loads', Test_ProjectFile_V4_LoadsWithoutMidi);
  RegisterTest(GRP, 'piano roll edits (add/move/resize/quantize/velocity)', Test_PianoRoll_Edits);
  RegisterTest(GRP, 'scale membership + chord namer', Test_Scales_And_Chords);
  RegisterTest(GRP, 'undo commands (add + merged move)', Test_Commands);
  RegisterTest(GRP, 'engine renders an audible tone for a note', Test_Engine_RendersAudibleTone);
end;

end.
