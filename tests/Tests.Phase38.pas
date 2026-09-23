unit Tests.Phase38;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 38 acceptance tests - MIDI device I/O redo: stable MIDI-project clip
  ids surviving deletion/reordering and a v1/v2 text-format round trip
  (UDAW.MIDI.Serialization), the Timeline's negative-SourceId MIDI-clip
  encoding (UDAW.Timeline.Model), committing a captured take to the Timeline
  with undo/redo (UDAW.MIDI.Commands.TCommitMidiTakeCommand), and the live
  capture engine's NoteOn/NoteOff pairing including notes still held at Stop
  (UDAW.MIDI.Capture). Real hardware I/O (UDAW.MIDI.Hardware) is not
  exercised here - it needs an actual MIDI device, which a CI/test machine
  may not have; EnumerateMidiInputs/EnumerateMidiOutputs degrading to an
  empty list with no device is covered by inspection (see that unit's
  header comment), the same way Phase 37 covers VST2 crash isolation. }

interface

procedure RegisterPhase38Tests;

implementation

uses
  SysUtils,
  UDAW.Testing, UDAW.Errors,
  UDAW.MIDI.Types, UDAW.MIDI.Sequence, UDAW.MIDI.Serialization, UDAW.MIDI.Capture,
  UDAW.Timeline.Model,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.MIDI.Commands;

const
  GRP = 'phase38.midi_device_io';

{ ================= TMidiProject stable ids ================= }

procedure Test_StableId_SurvivesRemovalOfAnEarlierClip;
var
  proj: TMidiProject;
  idA, idB, idC: Integer;
begin
  proj := TMidiProject.Create;
  try
    idA := proj.AddClipStable('A', TMidiSequence.Create);
    idB := proj.AddClipStable('B', TMidiSequence.Create);
    idC := proj.AddClipStable('C', TMidiSequence.Create);
    Check(proj.ClipById(idB) <> nil, 'sanity: B resolves before any removal');

    proj.RemoveClipById(idA);
    CheckEqualInt(2, proj.ClipCount, 'removing A leaves two clips');
    Check(proj.ClipById(idB) <> nil,
      'B''s stable id still resolves after A (an earlier array slot) was removed');
    Check(proj.ClipById(idC) <> nil, 'C''s stable id still resolves too');
    CheckEqualStr('B', proj.NameById(idB), 'NameById follows the same stable id');
  finally
    proj.Free;
  end;
end;

procedure Test_TextRoundTrip_V2PreservesStableIds;
var
  proj, proj2: TMidiProject;
  idA, idB: Integer;
  text: string;
begin
  proj := TMidiProject.Create;
  try
    idA := proj.AddClipStable('First', TMidiSequence.Create);
    idB := proj.AddClipStable('Second', TMidiSequence.Create);
    proj.RemoveClipById(idA);   // idB is no longer at index 0
    text := MidiProjectToString(proj);
  finally
    proj.Free;
  end;

  Check(Pos('UDAWMIDI 2', text) = 1, 'the writer stamps the v2 format header');
  proj2 := MidiProjectFromString(text);
  try
    CheckEqualInt(1, proj2.ClipCount, 'one clip survives the round trip');
    Check(proj2.ClipById(idB) <> nil,
      'the clip''s stable id (not its now-different array index) round-trips through save/load');
    CheckEqualStr('Second', proj2.NameById(idB), 'name follows the same id after reload');
  finally
    proj2.Free;
  end;
end;

procedure Test_TextRoundTrip_V1FileSynthesizesSequentialIds;
const
  V1_TEXT =
    'UDAWMIDI 1' + sLineBreak +
    'CLIPS 1' + sLineBreak +
    'CLIP 0 "Legacy" PPQ 480' + sLineBreak +
    'TRACK 0 "Track 1" CHAN 0 PROG 0' + sLineBreak +
    'ENDTRACK' + sLineBreak +
    'ENDCLIP' + sLineBreak;
var
  proj: TMidiProject;
begin
  proj := MidiProjectFromString(V1_TEXT);
  try
    CheckEqualInt(1, proj.ClipCount, 'the one v1 clip loads');
    Check(proj.IdOfIndex(0) > 0, 'a v1 file with no stable ids still gets one synthesised on load');
    Check(proj.ClipById(proj.IdOfIndex(0)) <> nil, 'the synthesised id resolves back to the clip');
  finally
    proj.Free;
  end;
end;

{ ================= Timeline negative-SourceId MIDI-clip encoding ================= }

procedure Test_MidiClipId_EncodeDecodeRoundTrip;
var
  tl: TTimeline;
  trk: TTimelineTrack;
  clip: TTimelineClip;
begin
  tl := TTimeline.Create;
  try
    trk := tl.AddTrack(tkMidi, 'MIDI 1');
    clip := tl.AddClip(trk.Id, EncodeMidiSourceId(77), 'take', 0, 0, 2.0);
    Check(clip.IsMidiClip, 'a clip with a negative SourceId is recognised as a MIDI clip');
    CheckEqualInt(77, clip.MidiClipId, 'MidiClipId decodes back to the original stable id');
  finally
    tl.Free;
  end;
end;

procedure Test_AudioClip_IsNotAMidiClip;
var
  tl: TTimeline;
  trk: TTimelineTrack;
  src: TMediaSource;
  clip: TTimelineClip;
begin
  tl := TTimeline.Create;
  try
    trk := tl.AddTrack(tkAudio, 'Audio 1');
    src := tl.AddSource('nonexistent.wav', 48000, 2, 1000);
    clip := tl.AddClip(trk.Id, src.Id, 'clip', 0, 0, 1.0);
    CheckFalse(clip.IsMidiClip, 'a normal, non-negative SourceId is never mistaken for a MIDI clip');
    CheckEqualInt(0, clip.MidiClipId, 'MidiClipId is 0 for a non-MIDI clip');
  finally
    tl.Free;
  end;
end;

{ ================= TCommitMidiTakeCommand ================= }

function MakeCapturedSequence: TMidiSequence;
var
  trk: TMidiTrackSeq;
  n: TMidiNote;
begin
  Result := TMidiSequence.Create(480);
  Result.SetTempoAt(0, 120.0);
  trk := Result.AddTrack('Recorded MIDI');
  FillChar(n, SizeOf(n), 0);
  n.StartTick := 0;
  n.LengthTick := 480;
  n.Channel := 0;
  n.Note := 60;
  n.Velocity := 100;
  trk.AddNote(n);
end;

procedure Test_CommitMidiTake_CreatesTrackAndClip_UndoRedo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  cmd: TCommitMidiTakeCommand;
  midiClipId: Integer;
begin
  doc := TProjectDocument.CreateNew;
  mgr := TCommandManager.Create;
  try
    cmd := TCommitMidiTakeCommand.Create(doc, 0, MakeCapturedSequence, 'Take 1', 1.5);
    Check(mgr.Perform(cmd), 'commit command executes');
    CheckEqualInt(1, doc.Timeline.TrackCount, 'a tkMidi track was created for the take');
    Check(doc.Timeline.GetTrack(0).Kind = tkMidi, 'the created track is a MIDI track');
    CheckEqualInt(1, doc.Timeline.ClipCountTotal, 'the take landed as one clip');
    CheckEqualInt(1, doc.Midi.ClipCount, 'the captured performance is registered as a MIDI-project clip');
    midiClipId := cmd.MidiClipId;

    mgr.Undo;
    CheckEqualInt(0, doc.Timeline.ClipCountTotal, 'undo removes the committed timeline clip');
    CheckEqualInt(0, doc.Timeline.TrackCount, 'undo removes the track this command created');
    Check(doc.Midi.ClipById(midiClipId) <> nil,
      'undo leaves the MIDI-project clip itself in place, like TCommitTakeCommand leaves media sources');

    mgr.Redo;
    CheckEqualInt(1, doc.Timeline.ClipCountTotal, 'redo puts the clip back');
    CheckEqualInt(1, doc.Timeline.TrackCount, 'redo puts the track back');
    Check(doc.Timeline.GetTrack(0).GetClip(0).MidiClipId = midiClipId,
      'the re-created clip references the SAME MIDI-project clip, not a new one');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

{ ================= TMidiCaptureEngine ================= }

procedure Test_Capture_PairsNoteOnNoteOff;
var
  cap: TMidiCaptureEngine;
  seq: TMidiSequence;
  trk: TMidiTrackSeq;
begin
  cap := TMidiCaptureEngine.Create;
  try
    cap.Start(0, 120.0, 480);   // 120 BPM, 480 PPQ -> 1 tick = 1/960 s, 1 quarter = 0.5 s
    cap.Feed(TMidiMessage.NoteOn(0, 60, 100), 0.0);
    cap.Feed(TMidiMessage.NoteOn(0, 60, 0), 0.5);   // NoteOn vel=0 == NoteOff
    seq := cap.Stop(0.5);
    Check(seq <> nil, 'a captured note-on/off pair produces a sequence');
    try
      CheckEqualInt(1, seq.TrackCount, 'one track was captured');
      trk := seq.GetTrack(0);
      CheckEqualInt(1, trk.NoteCount, 'exactly one note was captured');
      CheckEqualInt(0, trk.Notes[0].StartTick, 'the note starts at tick 0');
      CheckEqualInt(480, trk.Notes[0].LengthTick, 'half a second at 120 BPM/480 PPQ is one quarter note (480 ticks)');
      CheckEqualInt(60, trk.Notes[0].Note, 'note number was captured correctly');
    finally
      seq.Free;
    end;
  finally
    cap.Free;
  end;
end;

procedure Test_Capture_StopClosesAStillHeldNote;
var
  cap: TMidiCaptureEngine;
  seq: TMidiSequence;
begin
  cap := TMidiCaptureEngine.Create;
  try
    cap.Start(0, 120.0, 480);
    cap.Feed(TMidiMessage.NoteOn(0, 64, 90), 0.0);
    { no NoteOff ever arrives - Stop must close it, not leave a hung note }
    seq := cap.Stop(1.0);
    Check(seq <> nil, 'a still-held note still produces a sequence at Stop');
    try
      CheckEqualInt(1, seq.GetTrack(0).NoteCount, 'the held note was captured');
      Check(seq.GetTrack(0).Notes[0].LengthTick > 0,
        'Stop gives the still-held note a real length instead of leaving it zero/hung');
    finally
      seq.Free;
    end;
  finally
    cap.Free;
  end;
end;

procedure Test_Capture_NothingCapturedReturnsNil;
var
  cap: TMidiCaptureEngine;
  seq: TMidiSequence;
begin
  cap := TMidiCaptureEngine.Create;
  try
    cap.Start(0, 120.0, 480);
    seq := cap.Stop(1.0);   // no Feed calls at all
    Check(seq = nil, 'an empty capture (nothing played) returns nil, not an empty clip');
  finally
    cap.Free;
  end;
end;

procedure RegisterPhase38Tests;
begin
  RegisterTest(GRP, 'Stable id: survives removal of an earlier clip', Test_StableId_SurvivesRemovalOfAnEarlierClip);
  RegisterTest(GRP, 'Text round trip: v2 format preserves stable ids across save/load', Test_TextRoundTrip_V2PreservesStableIds);
  RegisterTest(GRP, 'Text round trip: a v1 file synthesizes sequential stable ids', Test_TextRoundTrip_V1FileSynthesizesSequentialIds);
  RegisterTest(GRP, 'Timeline: MIDI clip id encode/decode round trip', Test_MidiClipId_EncodeDecodeRoundTrip);
  RegisterTest(GRP, 'Timeline: a normal audio clip is never mistaken for a MIDI clip', Test_AudioClip_IsNotAMidiClip);
  RegisterTest(GRP, 'Commit MIDI take: creates track+clip, undo/redo round-trips', Test_CommitMidiTake_CreatesTrackAndClip_UndoRedo);
  RegisterTest(GRP, 'Capture: pairs NoteOn/NoteOff into one note', Test_Capture_PairsNoteOnNoteOff);
  RegisterTest(GRP, 'Capture: Stop closes a still-held note instead of leaving it hung', Test_Capture_StopClosesAStillHeldNote);
  RegisterTest(GRP, 'Capture: nothing played returns nil, not an empty clip', Test_Capture_NothingCapturedReturnsNil);
end;

end.
