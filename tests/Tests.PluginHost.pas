unit Tests.PluginHost;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ VST2 / VST3 hosting that can be checked without a plug-in binary: the layout of every record that is
  handed to a plug-in (a wrong size means a crash in somebody else's code), the MIDI hub that routes
  notes to plug-in instruments, and the extraction of a highlighted range's MIDI for offline rendering. }

interface

procedure RegisterPluginHostTests;

implementation

uses
  SysUtils, Math,
  UDAW.Testing, UDAW.MIDI.Types, UDAW.MIDI.Sequence, UDAW.MIDI.Serialization,
  UDAW.Timeline.Model, UDAW.Mixer.PluginHost, UDAW.Mixer.PluginMidi, UDAW.Mixer.PluginRender,
  UDAW.Mixer.VST2, UDAW.Mixer.VST3;

const
  GRP = 'plugin_hosting';
  SR = 48000;

{ ---------------- record layouts (the plug-in reads and writes these in place) ---------------- }

procedure Test_Vst2_StructSizes;
begin
  CheckEqualInt(88, SizeOf(TVstTimeInfo), 'VstTimeInfo is 88 bytes');
  CheckEqualInt(32, SizeOf(TVstMidiEvent), 'VstMidiEvent is 32 bytes');
  CheckEqualInt(152, SizeOf(TVstParameterProperties), 'VstParameterProperties is 152 bytes');
  CheckEqualInt(128, SizeOf(TVstPinProperties), 'VstPinProperties is 128 bytes');
  CheckEqualInt(16 + SizeOf(Pointer) * VST2_MAX_EVENTS, SizeOf(TVstEventsBlock),
    'VstEvents block: count + reserved + the event pointers');
end;

procedure Test_Vst3_StructSizes;
begin
  CheckEqualInt(48, SizeOf(TVst3Event), 'Event is 48 bytes');
  CheckEqualInt(112, SizeOf(TProcessContext), 'ProcessContext is 112 bytes');
  CheckEqualInt(792, SizeOf(TParameterInfo), 'ParameterInfo is 792 bytes');
  CheckEqualInt(276, SizeOf(TBusInfo), 'BusInfo is 276 bytes');
  CheckEqualInt(264, SizeOf(TProgramListInfo), 'ProgramListInfo is 264 bytes');
  CheckEqualInt(24, SizeOf(TAudioBusBuffers), 'AudioBusBuffers is 24 bytes');
  CheckEqualInt(80, SizeOf(TProcessData), 'ProcessData is 80 bytes');
  CheckEqualInt(440, SizeOf(TClassInfo2), 'PClassInfo2 is 440 bytes');
  CheckEqualInt(116, SizeOf(TClassInfo), 'PClassInfo is 116 bytes');
  CheckEqualInt(452, SizeOf(TFactoryInfo), 'PFactoryInfo is 452 bytes');
  CheckEqualInt(16, SizeOf(TViewRect), 'ViewRect is 16 bytes');
end;

procedure Test_Vst3_FieldOffsets;
var
  ctx: TProcessContext;
  ev: TVst3Event;
  base: NativeUInt;
begin
  base := NativeUInt(@ctx);
  CheckEqualInt(8, NativeUInt(@ctx.SampleRate) - base, 'ProcessContext.sampleRate at 8');
  CheckEqualInt(40, NativeUInt(@ctx.ProjectTimeMusic) - base, 'ProcessContext.projectTimeMusic at 40');
  CheckEqualInt(72, NativeUInt(@ctx.Tempo) - base, 'ProcessContext.tempo at 72');
  CheckEqualInt(80, NativeUInt(@ctx.TimeSigNumerator) - base, 'ProcessContext.timeSigNumerator at 80');
  CheckEqualInt(104, NativeUInt(@ctx.SamplesToNextClock) - base, 'ProcessContext.samplesToNextClock at 104');
  base := NativeUInt(@ev);
  CheckEqualInt(8, NativeUInt(@ev.PpqPosition) - base, 'Event.ppqPosition at 8');
  CheckEqualInt(16, NativeUInt(@ev.Flags) - base, 'Event.flags at 16');
  CheckEqualInt(18, NativeUInt(@ev.EventType) - base, 'Event.type at 18');
  CheckEqualInt(24, NativeUInt(@ev.Data[0]) - base, 'Event data union at 24');
end;

{ ---------------- the MIDI hub ---------------- }

procedure Test_Hub_LaneAndLiveRouting;
var
  hub: TPluginMidiHub;
  a, b, c: Integer;
  buf: array[0..63] of TPluginMidi;
  n: Integer;
begin
  hub := TPluginMidiHub.Create;
  try
    hub.Register(@a, 5, True, True);        { an instrument on lane 5, listening to the keyboard }
    hub.Register(@b, 7, False, True);       { an instrument on lane 7, not listening to the keyboard }
    hub.Register(@c, 5, True, False);       { an effect on lane 5 }
    Check(hub.LaneHasInstrument(5), 'lane 5 has an instrument');
    Check(hub.LaneHasInstrument(7), 'lane 7 has an instrument');
    CheckFalse(hub.LaneHasInstrument(9), 'lane 9 has none');
    CheckFalse(hub.LaneHasInstrument(0), 'lane 0 means no lane');

    hub.Post(5, $90, 60, 100, 12);
    n := hub.Take(@a, buf);
    CheckEqualInt(1, n, 'lane 5 note reached the lane 5 instrument');
    CheckEqualInt(60, buf[0].Data1, 'note number');
    CheckEqualInt(12, buf[0].DeltaFrames, 'delta frames are kept');
    CheckEqualInt(1, hub.Take(@c, buf), 'and the effect on the same lane');
    CheckEqualInt(0, hub.Take(@b, buf), 'but not the instrument on lane 7');
    CheckEqualInt(0, hub.Take(@a, buf), 'taking empties the queue');

    hub.PostLive($90, 64, 90);
    CheckEqualInt(1, hub.Take(@a, buf), 'live MIDI reaches a listener with live on');
    CheckEqualInt(0, hub.Take(@b, buf), 'not one with live off');
    hub.Take(@c, buf);

    hub.PostAllNotesOff(7);
    CheckEqualInt(32, hub.Take(@b, buf), 'all notes off is CC 123 and CC 120 on 16 channels');

    hub.Unregister(@a);
    CheckFalse(hub.LaneHasInstrument(5), 'an unregistered instrument no longer takes its lane');
  finally
    hub.Free;
  end;
end;

procedure Test_Hub_OutputQueueAndTransport;
var
  hub: TPluginMidiHub;
  buf: array[0..7] of TPluginMidi;
  tp: TPluginTransport;
begin
  hub := TPluginMidiHub.Create;
  try
    hub.PostOut($90, 60, 100);
    hub.PostOut($80, 60, 0);
    CheckEqualInt(2, hub.TakeOut(buf), 'both messages the plug-in sent out');
    CheckEqualInt($90, buf[0].Status, 'in order');
    CheckEqualInt($80, buf[1].Status, 'in order');
    CheckEqualInt(0, hub.TakeOut(buf), 'drained');

    tp := TPluginTransport.Make(True, 140, 8.0);
    hub.SetTransport(tp);
    Check(hub.Transport.Playing, 'the transport is playing right after it was published');
    CheckNear(140, hub.Transport.Tempo, 0.001, 'tempo');
    CheckNear(8.0, hub.Transport.PpqPos, 0.001, 'beat position');
    CheckEqualInt(4, hub.Transport.TimeSigNum, 'default time signature');
  finally
    hub.Free;
  end;
end;

{ ---------------- MIDI of a highlighted range ---------------- }

function BuildMidiTimeline(out ATl: TTimeline; out AProj: TMidiProject; out ATrackId: Integer): TMidiSequence;
var
  nt: TMidiNote;
  trk: TTimelineTrack;
  idx: Integer;
begin
  ATl := TTimeline.Create;
  AProj := TMidiProject.Create;
  Result := AProj.NewClip('riff');
  if Result.TrackCount = 0 then Result.AddTrack('t');
  FillChar(nt, SizeOf(nt), 0);
  nt.StartTick := MIDI_DEFAULT_PPQ;          { one beat in: 0.5 s at 120 BPM }
  nt.LengthTick := MIDI_DEFAULT_PPQ;         { half a second long }
  nt.Channel := 0;
  nt.Note := 64;
  nt.Velocity := 100;
  nt.OffVelocity := 0;
  Result.GetTrack(0).AddNote(nt);
  trk := ATl.AddTrack(tkInstrument, 'Lead');
  ATrackId := trk.Id;
  idx := AProj.ClipCount - 1;
  ATl.AddClip(trk.Id, EncodeMidiSourceId(AProj.IdOfIndex(idx)), 'riff', 2.0, 0, 4.0);
end;

procedure Test_RangeMidi_NotesInsideTheRange;
var
  tl: TTimeline;
  proj: TMidiProject;
  tid: Integer;
  m: TTimedMidiArray;
begin
  BuildMidiTimeline(tl, proj, tid);
  try
    m := CollectRangeMidi(tl, proj, [tid], 2.0, 4.0, SR);
    CheckEqualInt(2, Length(m), 'one note = a note on and a note off');
    CheckEqualInt($90, m[0].Status and $F0, 'first the note on');
    CheckEqualInt(64, m[0].Data1, 'its pitch');
    CheckEqualInt(24000, m[0].Sample, 'half a second into the range');
    CheckEqualInt($80, m[1].Status and $F0, 'then the note off');
    CheckEqualInt(48000, m[1].Sample, 'a second into the range');
  finally
    proj.Free;
    tl.Free;
  end;
end;

procedure Test_RangeMidi_NoteAlreadySoundingStartsAtZero;
var
  tl: TTimeline;
  proj: TMidiProject;
  tid: Integer;
  m: TTimedMidiArray;
begin
  BuildMidiTimeline(tl, proj, tid);
  try
    m := CollectRangeMidi(tl, proj, [tid], 2.75, 4.0, SR);   { starts in the middle of the note }
    CheckEqualInt(2, Length(m), 'the note that is already sounding is kept');
    CheckEqualInt(0, m[0].Sample, 'and starts at the start of the range');
    CheckEqualInt(12000, m[1].Sample, 'ending a quarter of a second later');
  finally
    proj.Free;
    tl.Free;
  end;
end;

procedure Test_RangeMidi_CutAtTheEndAndOutsideIgnored;
var
  tl: TTimeline;
  proj: TMidiProject;
  tid: Integer;
  m: TTimedMidiArray;
begin
  BuildMidiTimeline(tl, proj, tid);
  try
    m := CollectRangeMidi(tl, proj, [tid], 2.0, 2.75, SR);   { ends in the middle of the note }
    CheckEqualInt(2, Length(m), 'the note is cut at the end of the range');
    CheckEqualInt(36000, m[1].Sample, 'the note off lands on the range end');
    m := CollectRangeMidi(tl, proj, [tid], 2.0, 2.4, SR);    { before the note starts }
    CheckEqualInt(0, Length(m), 'a range before the note has no MIDI');
    m := CollectRangeMidi(tl, proj, [tid], 8.0, 9.0, SR);    { past the clip }
    CheckEqualInt(0, Length(m), 'a range past the clip has no MIDI');
    m := CollectRangeMidi(tl, proj, [], 2.0, 4.0, SR);
    CheckEqualInt(0, Length(m), 'no lanes selected, no MIDI');
  finally
    proj.Free;
    tl.Free;
  end;
end;

procedure RegisterPluginHostTests;
begin
  RegisterTest(GRP, 'VST2: record sizes match the plug-in ABI', Test_Vst2_StructSizes);
  RegisterTest(GRP, 'VST3: record sizes match the plug-in ABI', Test_Vst3_StructSizes);
  RegisterTest(GRP, 'VST3: field offsets match the plug-in ABI', Test_Vst3_FieldOffsets);
  RegisterTest(GRP, 'MIDI hub: lane and live routing to plug-in instruments', Test_Hub_LaneAndLiveRouting);
  RegisterTest(GRP, 'MIDI hub: plug-in output queue and transport', Test_Hub_OutputQueueAndTransport);
  RegisterTest(GRP, 'Range MIDI: notes inside the highlighted range', Test_RangeMidi_NotesInsideTheRange);
  RegisterTest(GRP, 'Range MIDI: a note already sounding starts at zero', Test_RangeMidi_NoteAlreadySoundingStartsAtZero);
  RegisterTest(GRP, 'Range MIDI: cut at the end, outside ignored', Test_RangeMidi_CutAtTheEndAndOutsideIgnored);
end;

end.
