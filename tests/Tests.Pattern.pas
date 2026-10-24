unit Tests.Pattern;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

{ Pattern editor acceptance tests: the step model, its text codec (library and
  preset), the project file round trip, placing a pattern on the Timeline with undo,
  the live link between a pattern and its Timeline clips, and the drum machine's
  sample-accurate step sequencer. }

interface

procedure RegisterPatternTests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Paths,
  UDAW.Audio.Types,
  UDAW.Audio.Buffer,
  UDAW.Codec.WAV,
  UDAW.Drum.Machine,
  UDAW.Project.Document,
  UDAW.Project.Commands,
  UDAW.Project.Serialization,
  UDAW.Timeline.Model,
  UDAW.MIDI.Sequence,
  UDAW.Pattern.Model,
  UDAW.Pattern.Commands;

const
  RATE = 44100;

function KickPattern: TPattern;
begin
  Result := TPattern.Create;
  Result.Name := 'Boom';
  Result.StepsPerBeat := 4;
  Result.StepCount := 16;
  Result.AddLane(36, 'Kick', 'C:\kits\kick.wav');
  Result.SetVelocity(0, 0, 100);
  Result.SetVelocity(0, 8, 90);
  Result.AddLane(38, 'Snare', '');
  Result.SetVelocity(1, 4, 110);
  Result.SetVelocity(1, 12, 110);
end;

procedure Test_StepModel;
var
  p: TPattern;
begin
  p := KickPattern;
  try
    CheckEqualInt(2, p.LaneCount, 'two lanes');
    CheckEqualInt(4, p.TotalHits, 'four hits');
    CheckNear(4.0, p.DurationBeats, 0.0001, '16 sixteenths are four beats');
    CheckNear(2.0, p.DurationSeconds(120), 0.0001, 'two seconds at 120 BPM');
    CheckEqualInt(1, p.LaneForNote(38), 'lane of note 38');
    CheckEqualInt(-1, p.LaneForNote(40), 'no lane for note 40');
    p.StepCount := 32;
    CheckEqualInt(4, p.TotalHits, 'growing keeps the hits');
    p.StepCount := 8;
    CheckEqualInt(2, p.TotalHits, 'shrinking cuts the steps past the end');
    p.StepCount := 16;
    p.ClearSteps(-1);
    CheckEqualInt(0, p.TotalHits, 'clear');
    p.Fill(0, 4, 0, 100);
    CheckEqualInt(4, p.Lanes[0].HitCount, 'every fourth step of 16');
    p.Euclidean(1, 5, 0, 100);
    CheckEqualInt(5, p.Lanes[1].HitCount, 'euclidean 5 of 16');
    p.ClearSteps(1);
    p.SetVelocity(1, 15, 90);
    p.Rotate(1, 1);
    CheckEqualInt(90, p.Velocity(1, 0), 'rotate wraps the last step to the first');
    p.RemoveLane(1);
    CheckEqualInt(1, p.LaneCount, 'lane removed');
  finally
    p.Free;
  end;
end;

procedure Test_Resolution;
var
  p: TPattern;
begin
  p := KickPattern;
  try
    p.ChangeResolution(8);
    CheckEqualInt(32, p.StepCount, '1/16 -> 1/32 doubles the steps');
    CheckEqualInt(100, p.Velocity(0, 0), 'first hit keeps its time');
    CheckEqualInt(90, p.Velocity(0, 16), 'step 8 of 1/16 is step 16 of 1/32');
    CheckEqualInt(4, p.TotalHits, 'no hit lost going finer');
    CheckNear(4.0, p.DurationBeats, 0.0001, 'same musical length');
    p.ChangeResolution(2);
    CheckEqualInt(8, p.StepCount, '1/32 -> 1/8 quarters the steps');
    CheckEqualInt(4, p.TotalHits, 'the kick and snare hits land on different steps');
  finally
    p.Free;
  end;
end;

procedure Test_ToMidi;
var
  p: TPattern;
  seq: TMidiSequence;
  n: TMidiNote;
begin
  p := KickPattern;
  try
    seq := p.ToMidi(480, 120);
    try
      CheckEqualInt(4, seq.GetTrack(0).NoteCount, 'one note per hit');
      n := seq.GetTrack(0).Notes[1];
      CheckEqualInt(480, Integer(n.StartTick), 'the snare on step 4 is one beat in');
      CheckEqualInt(38, n.Note, 'its note');
      CheckEqualInt(PATTERN_DRUM_CHANNEL, n.Channel, 'on the drum channel');
      CheckEqualInt(110, n.Velocity, 'its velocity');
    finally
      seq.Free;
    end;
    p.Lanes[1].Muted := True;
    seq := p.ToMidi(480, 120);
    try
      CheckEqualInt(2, seq.GetTrack(0).NoteCount, 'a muted lane renders nothing');
    finally
      seq.Free;
    end;
  finally
    p.Free;
  end;
end;

procedure Test_LibraryCodec;
var
  lib, back: TPatternLibrary;
  p: TPattern;
  text: string;
begin
  lib := TPatternLibrary.Create;
  try
    p := KickPattern;
    p.MidiClipId := 7;
    lib.Add(p);
    p := KickPattern;
    p.Name := 'Second';
    lib.Add(p);
    text := PatternLibraryToString(lib);
    back := PatternLibraryFromString(text);
    try
      CheckEqualInt(2, back.Count, 'both patterns come back');
      CheckEqualStr('Boom', back[0].Name, 'name');
      CheckEqualInt(7, back[0].MidiClipId, 'the Timeline link');
      CheckEqualInt(16, back[0].StepCount, 'steps');
      CheckEqualInt(4, back[0].StepsPerBeat, 'resolution');
      CheckEqualStr('Kick', back[0].Lanes[0].Name, 'the instrument name');
      CheckEqualStr('C:\kits\kick.wav', back[0].Lanes[0].SamplePath, 'the instrument sample');
      CheckEqualInt(36, back[0].Lanes[0].Note, 'the instrument note');
      CheckEqualInt(90, back[0].Velocity(0, 8), 'a velocity');
      CheckEqualInt(lib.NextId, back.NextId, 'id counter');
      CheckEqualInt(2, back.ById(back[1].Id).Id, 'ids are stable');
      CheckEqualStr(text, PatternLibraryToString(back), 'writing it again gives the same text');
    finally
      back.Free;
    end;
  finally
    lib.Free;
  end;
end;

procedure Test_Preset;
var
  p, q: TPattern;
begin
  p := KickPattern;
  try
    p.Id := 5;
    p.MidiClipId := 9;
    q := PatternFromPreset(PatternToPreset(p));
    try
      CheckEqualInt(0, q.Id, 'a preset carries no project id');
      CheckEqualInt(0, q.MidiClipId, 'nor a Timeline link');
      CheckEqualInt(p.TotalHits, q.TotalHits, 'the hits');
      CheckEqualStr('Snare', q.Lanes[1].Name, 'the instruments');
    finally
      q.Free;
    end;
  finally
    p.Free;
  end;
  try
    PatternFromPreset('nonsense');
    Check(False, 'garbage is rejected');
  except
    on E: Exception do Check(True, 'garbage is rejected');
  end;
end;

procedure Test_ProjectRoundTrip;
var
  doc, back: TProjectDocument;
begin
  doc := TProjectDocument.CreateNew('patterns');
  try
    doc.Patterns.Add(KickPattern);
    back := ProjectFromString(ProjectToString(doc));
    try
      CheckEqualInt(1, back.Patterns.Count, 'the pattern is in the project file');
      CheckEqualInt(4, back.Patterns[0].TotalHits, 'with its hits');
      CheckEqualStr('Snare', back.Patterns[0].Lanes[1].Name, 'and its instruments');
    finally
      back.Free;
    end;
  finally
    doc.Free;
  end;
end;

procedure Test_PlaceAndSync;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  p: TPattern;
  clip: TTimelineClip;
  pid, clipId: Integer;
  cmd: TPlacePatternCommand;
begin
  doc := TProjectDocument.CreateNew('place');
  mgr := TCommandManager.Create;
  try
    doc.TempoBPM := 120;
    p := KickPattern;
    doc.Patterns.Add(p);
    pid := p.Id;
    cmd := TPlacePatternCommand.Create(doc, pid, 0, 4.0);
    Check(mgr.Perform(cmd), 'placed');
    CheckEqualInt(1, doc.Timeline.TrackCount, 'a track was made for it');
    p := doc.Patterns.ById(pid);
    Check(p.MidiClipId <> 0, 'the pattern knows its MIDI clip');
    Check(doc.Midi.ClipById(p.MidiClipId) <> nil, 'the MIDI clip exists');
    clip := doc.Timeline.GetTrack(0).GetClip(0);
    clipId := clip.Id;
    CheckNear(4.0, clip.StartSeconds, 0.0001, 'at the requested position');
    CheckNear(2.0, clip.LengthSeconds, 0.001, 'as long as the pattern');
    Check(clip.IsMidiClip and (clip.MidiClipId = p.MidiClipId), 'it plays the rendered clip');

    { editing the pattern re-renders the clip and lengthens the untouched instance }
    mgr.Perform(TPatternEditCommand.Create(doc, 'Longer',
      procedure(ALib: TPatternLibrary)
      begin
        ALib.ById(pid).StepCount := 32;
        ALib.ById(pid).SetVelocity(0, 20, 100);
      end));
    clip := doc.Timeline.ClipById(clipId);
    CheckNear(4.0, clip.LengthSeconds, 0.001, 'the instance followed the new length');
    CheckEqualInt(5, doc.Midi.ClipById(doc.Patterns.ById(pid).MidiClipId).GetTrack(0).NoteCount,
      'and the MIDI clip has the new hit');
    mgr.Undo;
    clip := doc.Timeline.ClipById(clipId);
    CheckNear(2.0, clip.LengthSeconds, 0.001, 'undo restores the length');
    CheckEqualInt(4, doc.Midi.ClipById(doc.Patterns.ById(pid).MidiClipId).GetTrack(0).NoteCount,
      'and the notes');
    mgr.Redo;
    CheckEqualInt(32, doc.Patterns.ById(pid).StepCount, 'redo');

    { a clip the user stretched keeps its own length }
    doc.Timeline.ClipById(clipId).LengthSeconds := 9.0;
    mgr.Perform(TPatternEditCommand.Create(doc, 'Shorter',
      procedure(ALib: TPatternLibrary)
      begin
        ALib.ById(pid).StepCount := 16;
      end));
    CheckNear(9.0, doc.Timeline.ClipById(clipId).LengthSeconds, 0.001, 'a stretched instance is left alone');
    mgr.Undo;
    mgr.Undo;
    mgr.Undo;
    CheckEqualInt(0, doc.Timeline.TrackCount, 'undoing the place removes its track');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_EmptyPatternIsNotPlaced;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  p: TPattern;
begin
  doc := TProjectDocument.CreateNew('empty');
  mgr := TCommandManager.Create;
  try
    p := TPattern.Create;
    doc.Patterns.Add(p);
    CheckFalse(mgr.Perform(TPlacePatternCommand.Create(doc, p.Id, 0, 0)), 'no hits, nothing to place');
    CheckEqualInt(0, doc.Timeline.TrackCount, 'no track either');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

{ ---- the drum machine's step sequencer ---- }

function MakeDc(const AName: string; AFrames: Integer; AValue: Single): string;
var
  d: TAudioPlanar;
  ch, i: Integer;
begin
  Result := IncludeTrailingPathDelimiter(Paths.Temp) + 'pattern-tests' + PathDelim;
  ForceDirectories(Result);
  Result := Result + AName;
  SetLength(d, 2);
  for ch := 0 to 1 do
  begin
    SetLength(d[ch], AFrames);
    for i := 0 to AFrames - 1 do d[ch][i] := AValue;
  end;
  SaveWavFile(Result, d, 2, RATE, AFrames, wsfFloat32);
end;

procedure Test_Sequencer_SampleAccurate;
var
  m: TDrumMachine;
  iface: IInterface;
  b: TAudioBuffer;
  steps: TArray<TArray<TDrumHit>>;
  err: string;
  f, first, expect: Integer;
begin
  m := TDrumMachine.Create;
  iface := m;
  m.Prepare(RATE, 512, 2);
  Check(m.LoadPad(60, MakeDc('seq.wav', 20000, 0.5), err), 'pad 60 loaded: ' + err);
  { 120 BPM, 1/16: a step is 0.125 s = 5512.5 frames; the hit is on step 2 }
  SetLength(steps, 4);
  SetLength(steps[2], 1);
  steps[2][0].Pad := 60;
  steps[2][0].Vel := 127;
  m.SetSequence(4, 120, steps);
  m.StartSequence;
  b := TAudioBuffer.Create(2, 16384, RATE);
  try
    b.SetActiveFrames(16384);
    m.Render(b);
    first := -1;
    for f := 0 to 16383 do
      if Abs(PAudioSample(PByte(b.ChannelPtr(0)) + f * SizeOf(TAudioSample))^) > 0.01 then
      begin
        first := f;
        Break;
      end;
    expect := Ceil(2 * 5512.5);   // two steps in
    Check(first >= 0, 'the sequence produced sound');
    Check(Abs(first - expect) <= 2, Format('the hit starts on its frame (got %d, expected %d)', [first, expect]));
  finally
    b.Free;
  end;
  m.StopSequence;
  b := TAudioBuffer.Create(2, 512, RATE);
  try
    b.SetActiveFrames(512);
    m.Render(b);
    CheckEqualInt(-1, m.SequenceStep, 'stopped');
  finally
    b.Free;
  end;
end;

procedure Test_Kit_WholeNoteRange;
var
  a, c: TDrumMachine;
  ia, ic: IInterface;
  f, kit: string;
  err: string;
begin
  a := TDrumMachine.Create;
  ia := a;
  c := TDrumMachine.Create;
  ic := c;
  f := MakeDc('range.wav', 800, 0.5);
  Check(a.LoadPad(0, f, err), 'lowest note');
  Check(a.LoadPad(127, f, err), 'highest note');
  Check(a.HitNote(127, 100), 'note 127 plays its pad');
  kit := IncludeTrailingPathDelimiter(Paths.Temp) + 'pattern-tests' + PathDelim + 'range.kit';
  Check(a.SaveKit(kit), 'saved');
  Check(c.LoadKit(kit), 'loaded');
  Check(c.HasSample(0) and c.HasSample(127), 'both ends come back');
  CheckFalse(c.HasSample(36), 'and nothing else');
end;

procedure RegisterPatternTests;
begin
  RegisterTest('pattern.model', 'step model',                   @Test_StepModel);
  RegisterTest('pattern.model', 'resolution change',            @Test_Resolution);
  RegisterTest('pattern.model', 'render to MIDI',               @Test_ToMidi);
  RegisterTest('pattern.model', 'library codec',                @Test_LibraryCodec);
  RegisterTest('pattern.model', 'preset codec',                 @Test_Preset);
  RegisterTest('pattern.project', 'project file round trip',    @Test_ProjectRoundTrip);
  RegisterTest('pattern.project', 'place, edit, undo',          @Test_PlaceAndSync);
  RegisterTest('pattern.project', 'empty pattern not placed',   @Test_EmptyPatternIsNotPlaced);
  RegisterTest('pattern.drum', 'sample-accurate sequencer',     @Test_Sequencer_SampleAccurate);
  RegisterTest('pattern.drum', 'kit covers notes 0..127',       @Test_Kit_WholeNoteRange);
end;

end.
