unit UDAW.MIDI.Capture;
{$I udaw.inc}

{ Phase 38 - MIDI: live capture from a hardware MIDI input device into a
  TMidiSequence, ready to hand to TCommitMidiTakeCommand (see
  UDAW.MIDI.Commands) exactly the way UDAW.Recording.Takes' recorded WAV
  specs feed TCommitTakeCommand.

  Start begins a capture at a fixed tempo/PPQ (the project's tempo at the
  moment recording was armed - like UDAW.Recording.Types.TRecordSettings.
  TempoBPM, not re-derived from a tempo map that might move mid-take). Every
  Feed call - driven from UDAW.MIDI.Hardware.TMidiInputDevice.Poll on the UI
  thread, never the driver callback thread - pairs NoteOn/NoteOff into
  TMidiNote records and records CC/program/pitch-bend/aftertouch verbatim on
  one track. Stop closes any notes still held at the stop position, so a
  capture stopped mid-note never leaves a hung note behind, and hands back
  the finished sequence (nil if nothing was captured). }

interface

uses
  SysUtils, Math, Generics.Collections,
  UDAW.MIDI.Types, UDAW.MIDI.Sequence, UDAW.MIDI.Engine;

type
  TMidiCaptureEngine = class
  private
    FSeq: TMidiSequence;
    FTrack: TMidiTrackSeq;
    FRecording: Boolean;
    FStartSeconds: Double;
    FTempoBPM: Double;
    FHeldIndex: TDictionary<Integer, Integer>;   // (channel*128+note) -> FTrack note index
    FMonitor: TMidiSynth;   // not owned - see Monitor
    FEventCount: Integer;
    procedure StartNote(AChannel, ANote, AVelocity: Integer; ATick: Int64);
    procedure EndNote(AChannel, ANote, AOffVelocity: Integer; ATick: Int64);
  public
    constructor Create;
    destructor Destroy; override;

    { ATimelineStartSeconds is where the captured clip will be placed on the
      timeline once committed. }
    procedure Start(ATimelineStartSeconds, ATempoBPM: Double; APPQ: Integer = MIDI_DEFAULT_PPQ);
    { Feed one live event; ASecondsSinceStart is elapsed time since Start
      (the caller converts the device's own millisecond timestamp - see
      TMidiInputDevice.Poll - to seconds since this capture's Start). No-op
      when not currently recording. }
    procedure Feed(const AMsg: TMidiMessage; ASecondsSinceStart: Double);
    { Closes any still-held notes at ASecondsSinceStart, hands the caller the
      finished sequence (caller owns it from here) or nil if nothing at all
      was captured. Safe to call when not recording (returns nil). }
    function Stop(ASecondsSinceStart: Double): TMidiSequence;

    property Recording: Boolean read FRecording;
    property EventCount: Integer read FEventCount;
    property TimelineStartSeconds: Double read FStartSeconds;
    { Optional real-time echo of every captured event - typically the same
      TMidiSynth a Timeline/Piano-Roll monitor path renders (see
      UDAW.Timeline.Playback.TTimelinePlayer.AttachLiveMidiMonitor), so what
      is heard while recording is exactly what got captured. Not owned;
      leave nil for silent (e.g. hardware-thru-only) capture. }
    property Monitor: TMidiSynth read FMonitor write FMonitor;
  end;

implementation

function HeldKey(AChannel, ANote: Integer): Integer;
begin
  Result := (AChannel and $0F) * 128 + (ANote and $7F);
end;

constructor TMidiCaptureEngine.Create;
begin
  inherited Create;
  FHeldIndex := TDictionary<Integer, Integer>.Create;
end;

destructor TMidiCaptureEngine.Destroy;
begin
  FSeq.Free;   // still owned only if Stop was never called
  FHeldIndex.Free;
  inherited Destroy;
end;

procedure TMidiCaptureEngine.Start(ATimelineStartSeconds, ATempoBPM: Double; APPQ: Integer);
begin
  FreeAndNil(FSeq);
  FHeldIndex.Clear;
  FEventCount := 0;
  if ATempoBPM <= 0 then ATempoBPM := 120.0;
  FTempoBPM := ATempoBPM;
  FStartSeconds := Max(0.0, ATimelineStartSeconds);
  FSeq := TMidiSequence.Create(APPQ);
  FSeq.SetTempoAt(0, FTempoBPM);
  FTrack := FSeq.AddTrack('Recorded MIDI');
  FRecording := True;
end;

procedure TMidiCaptureEngine.StartNote(AChannel, ANote, AVelocity: Integer; ATick: Int64);
var
  key, idx: Integer;
  note: TMidiNote;
begin
  key := HeldKey(AChannel, ANote);
  if FHeldIndex.TryGetValue(key, idx) then
    EndNote(AChannel, ANote, 0, ATick);   // retrigger without a NoteOff: close the old one first
  FillChar(note, SizeOf(note), 0);
  note.StartTick := ATick;
  note.LengthTick := 1;   // placeholder; fixed up by EndNote (or Stop, if still held)
  note.Channel := AChannel and $0F;
  note.Note := ANote and $7F;
  note.Velocity := Max(1, AVelocity and $7F);
  note.OffVelocity := 0;
  idx := FTrack.AddNote(note);
  FHeldIndex.AddOrSetValue(key, idx);
end;

procedure TMidiCaptureEngine.EndNote(AChannel, ANote, AOffVelocity: Integer; ATick: Int64);
var
  key, idx: Integer;
  note: TMidiNote;
begin
  key := HeldKey(AChannel, ANote);
  if not FHeldIndex.TryGetValue(key, idx) then Exit;   // no matching held note - ignore
  FHeldIndex.Remove(key);
  if (idx < 0) or (idx >= FTrack.NoteCount) then Exit;
  note := FTrack.Notes[idx];
  note.LengthTick := Max(1, ATick - note.StartTick);
  note.OffVelocity := AOffVelocity and $7F;
  FTrack.UpdateNote(idx, note);
end;

procedure TMidiCaptureEngine.Feed(const AMsg: TMidiMessage; ASecondsSinceStart: Double);
var
  tick: Int64;
  cc: TMidiCC;
  ev: TMidiEvent;
begin
  if not FRecording then Exit;
  Inc(FEventCount);
  if Assigned(FMonitor) then FMonitor.DispatchMessage(AMsg);

  tick := FSeq.SecondsToTick(Max(0.0, ASecondsSinceStart));
  case AMsg.StatusHi of
    MIDI_NOTE_ON:
      if AMsg.Data2 > 0 then StartNote(AMsg.Channel, AMsg.NoteNumber, AMsg.Velocity, tick)
      else EndNote(AMsg.Channel, AMsg.NoteNumber, 0, tick);
    MIDI_NOTE_OFF:
      EndNote(AMsg.Channel, AMsg.NoteNumber, AMsg.Velocity, tick);
    MIDI_CONTROL_CHANGE:
      begin
        cc.Tick := tick;
        cc.Channel := AMsg.Channel;
        cc.Controller := AMsg.Data1;
        cc.Value := AMsg.Data2;
        FTrack.AddCC(cc);
      end;
    MIDI_PROGRAM_CHANGE, MIDI_PITCH_BEND, MIDI_CHAN_AFTERTOUCH, MIDI_POLY_AFTERTOUCH:
      begin
        FillChar(ev, SizeOf(ev), 0);
        ev.Tick := tick;
        ev.Kind := mekChannel;
        ev.Msg := AMsg;
        FTrack.AddAux(ev);
      end;
  end;
end;

function TMidiCaptureEngine.Stop(ASecondsSinceStart: Double): TMidiSequence;
var
  tick: Int64;
  keys: TArray<Integer>;
  k, idx: Integer;
  note: TMidiNote;
begin
  Result := nil;
  if not FRecording then Exit;
  FRecording := False;

  tick := FSeq.SecondsToTick(Max(0.0, ASecondsSinceStart));
  keys := FHeldIndex.Keys.ToArray;
  for k in keys do
  begin
    idx := FHeldIndex[k];
    if (idx >= 0) and (idx < FTrack.NoteCount) then
    begin
      note := FTrack.Notes[idx];
      note.LengthTick := Max(1, tick - note.StartTick);
      FTrack.UpdateNote(idx, note);
    end;
  end;
  FHeldIndex.Clear;
  FTrack.SortNotes;
  FTrack.SortCC;

  if (FTrack.NoteCount = 0) and (FTrack.CCCount = 0) and (FTrack.AuxCount = 0) then
  begin
    FreeAndNil(FSeq);
    Exit(nil);
  end;
  Result := FSeq;
  FSeq := nil;   // ownership transferred to the caller
end;

end.
