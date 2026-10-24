unit UDAW.MIDI.Engine;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 17 - MIDI: the playback engine and its internal polyphonic synth
  (plan section 25: "Complete MIDI engine and piano roll").

  TMidiSynth is a real, self-contained polyphonic synthesiser: up to
  MIDI_SYNTH_VOICES voices, a small General-MIDI-family -> oscillator-shape map,
  a per-voice PolyBLEP oscillator + one-pole tone filter + ADSR (Phase 3
  UDAW.DSP.Envelope), and per-channel volume (CC7), expression (CC11), pan
  (CC10), sustain pedal (CC64), channel aftertouch and pitch bend with an
  RPN-0 settable bend range.  Channel 10 is the percussion channel (fixed
  noise-burst voices keyed by note).

  TMidiPlaybackEngine wraps a TMidiSequence as an IAudioSource: it flattens
  every track to one tick-ordered event stream, advances a sample clock through
  the sequence tempo map (with an adjustable tempo scale), dispatches due
  events to the synth and renders it into the callback buffer.  It also offers
  an offline RenderSequence for tests / bounce.

  Real-time contract: after Prepare, Render does no allocation and takes no
  locks. }

interface

uses
  SysUtils, Math,
  UDAW.Errors, UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Source,
  UDAW.DSP.Envelope,
  UDAW.MIDI.Types, UDAW.MIDI.Sequence, UDAW.Drum.Machine;

const
  MIDI_SYNTH_VOICES = 64;
  MIDI_DRUM_CHANNEL = 9;    // 0-based (channel "10")

type
  TMidiWaveShape = (mwsSine, mwsTriangle, mwsSaw, mwsSquare, mwsPulse, mwsNoise);

  TMidiVoice = record
    Active: Boolean;
    Held: Boolean;             // key still down (vs. sustained by pedal)
    Channel: Integer;
    Note: Integer;
    Shape: TMidiWaveShape;
    Phase: Double;             // 0..1
    PhaseInc: Double;
    BaseHz: Double;
    Amp: Single;               // velocity gain
    Pan: Single;               // -1..+1 resolved at note-on, tracked from channel
    Env: TADSR;
    Lp: Double;                // one-pole tone filter state
    LpCoef: Double;
    PulseWidth: Double;
    Age: Int64;
    DrumDecay: Double;         // channel-10 fixed decay envelope (linear)
    DrumLevel: Double;
  end;

  TMidiChannelState = record
    ProgramNo: Integer;
    Volume: Double;            // CC7  0..1
    Expression: Double;        // CC11 0..1
    Pan: Double;               // CC10 -1..+1
    Sustain: Boolean;          // CC64 >= 64
    PitchBendSemis: Double;    // current bend in semitones
    BendRange: Double;         // semitones for full deflection (default 2)
    Aftertouch: Double;        // 0..1 channel pressure -> gentle level/vibrato
    RpnMsb, RpnLsb: Integer;
  end;

  TMidiSynth = class
  private
    FVoices: array[0..MIDI_SYNTH_VOICES - 1] of TMidiVoice;
    FChannels: array[0..15] of TMidiChannelState;
    FSampleRate: Integer;
    FMasterGain: Single;
    FAgeCounter: Int64;
    FDrum: TDrumMachine;          // not owned: channel-10 notes on its pads play samples
    function AllocVoice(AChannel, ANote: Integer): Integer;
    procedure StartVoice(AIdx, AChannel, ANote, AVelocity: Integer);
    procedure RecalcVoicePitch(AIdx: Integer);
    function Osc(var V: TMidiVoice): Single;
  public
    constructor Create;
    procedure Init(ASampleRate: Integer);
    procedure Reset;

    procedure NoteOn(AChannel, ANote, AVelocity: Integer);
    procedure NoteOff(AChannel, ANote, AVelocity: Integer);
    procedure ControlChange(AChannel, AController, AValue: Integer);
    procedure ProgramChange(AChannel, AProgram: Integer);
    procedure PitchBend(AChannel, AValue14: Integer);          // -8192..+8191
    procedure ChannelAftertouch(AChannel, AValue: Integer);
    procedure AllNotesOff(AChannel: Integer);
    procedure AllSoundOff;
    procedure DispatchMessage(const AMsg: TMidiMessage);

    { additively render frames [0..AFrameCount) into ABuffer (assumed pre-cleared
      by the caller when it wants only the synth) }
    procedure RenderAdd(ABuffer: TAudioBuffer; AFrameCount: Integer);

    function ActiveVoiceCount: Integer;
    property SampleRate: Integer read FSampleRate;
    property MasterGain: Single read FMasterGain write FMasterGain;
    { when set, channel-10 notes 36..51 on a pad that holds a sample play that sample }
    property DrumMachine: TDrumMachine read FDrum write FDrum;
    { the project's drum kit: every synth made after it is set plays its pads (the live
      monitor synth clears it, since the kit is auditioned stand-alone) }
    class var SharedDrum: TDrumMachine;
  end;

  { one flattened, tick-ordered event the engine dispatches }
  TEngineEvent = record
    Tick: Int64;
    Msg: TMidiMessage;
  end;

  TMidiPlaybackEngine = class(TInterfacedObject, IAudioSource)
  private
    FSeq: TMidiSequence;
    FSynth: TMidiSynth;
    FSampleRate: Integer;
    FChannels: Integer;
    FEvents: array of TEngineEvent;
    FEventCount: Integer;
    FCursor: Integer;
    FPlaying: Boolean;
    FSeconds: Double;          // musical seconds consumed
    FTempoScale: Double;
    FRate: Double;             // sequence seconds consumed per real second (tempo-map following)
    FLoop: Boolean;
    FLoopStartSec, FLoopEndSec: Double;
    FEndTick: Int64;
    procedure Flatten;
    procedure SeekInternal(ASeconds: Double);
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetSequence(ASeq: TMidiSequence);   // not owned; call Rebuild after edits
    procedure Rebuild;

    { IAudioSource }
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;

    procedure Play;
    procedure Stop;
    procedure SeekSeconds(ASeconds: Double);
    procedure SeekTick(ATick: Int64);

    { offline: render the whole sequence (+ tail) to engine-planar Float32 }
    function RenderToPlanar(ASampleRate, AChannels: Integer;
      ATailSeconds: Double = 2.0): TAudioPlanar;

    property Synth: TMidiSynth read FSynth;
    property Playing: Boolean read FPlaying;
    property PositionSeconds: Double read FSeconds;
    property TempoScale: Double read FTempoScale write FTempoScale;
    { how fast the sequence advances compared with real time; 1.0 = as written. Unlike
      TempoScale it is applied to the time consumed per block, so it can change while
      the sequence is playing (a tempo change on the timeline). }
    property Rate: Double read FRate write FRate;
    property Loop: Boolean read FLoop write FLoop;
    property LoopStartSeconds: Double read FLoopStartSec write FLoopStartSec;
    property LoopEndSeconds: Double read FLoopEndSec write FLoopEndSec;
  end;

function MidiProgramShape(AProgram: Integer): TMidiWaveShape;

implementation


uses
  UDAW.DSP.MathTables;

const
  ENGINE_SUBSYS = 'MIDI.Engine';
  TWO_PI = 2.0 * Pi;

function MidiProgramShape(AProgram: Integer): TMidiWaveShape;
begin
  { a coarse GM family map - enough for a recognisable preview per patch }
  case AProgram of
    0..7:    Result := mwsTriangle;   // pianos
    8..15:   Result := mwsSine;       // chromatic percussion / bells
    16..23:  Result := mwsSquare;     // organs
    24..31:  Result := mwsSaw;        // guitars
    32..39:  Result := mwsTriangle;   // basses
    40..47:  Result := mwsSaw;        // strings
    48..55:  Result := mwsSaw;        // ensemble
    56..63:  Result := mwsSquare;     // brass
    64..71:  Result := mwsPulse;      // reeds
    72..79:  Result := mwsSine;       // pipes
    80..87:  Result := mwsSquare;     // synth lead
    88..95:  Result := mwsSaw;        // synth pad
    96..103: Result := mwsSine;       // synth FX
    104..111:Result := mwsSaw;        // ethnic
    112..119:Result := mwsNoise;      // percussive
  else
    Result := mwsSine;
  end;
end;

{ ============================ TMidiSynth ========================= }

constructor TMidiSynth.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FMasterGain := 0.22;
  Init(FSampleRate);
end;

procedure TMidiSynth.Init(ASampleRate: Integer);
var
  i: Integer;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  for i := 0 to High(FVoices) do
    FVoices[i].Env.Init(FSampleRate);
  FDrum := SharedDrum;
  Reset;
end;

procedure TMidiSynth.Reset;
var
  i: Integer;
begin
  for i := 0 to High(FVoices) do
  begin
    FVoices[i].Active := False;
    FVoices[i].Held := False;
    FVoices[i].Phase := 0;
    FVoices[i].Lp := 0;
    FVoices[i].Env.HardReset;
  end;
  for i := 0 to 15 do
  begin
    FChannels[i].ProgramNo := 0;
    FChannels[i].Volume := 100 / 127;
    FChannels[i].Expression := 1.0;
    FChannels[i].Pan := 0.0;
    FChannels[i].Sustain := False;
    FChannels[i].PitchBendSemis := 0.0;
    FChannels[i].BendRange := 2.0;
    FChannels[i].Aftertouch := 0.0;
    FChannels[i].RpnMsb := 127;
    FChannels[i].RpnLsb := 127;
  end;
  FAgeCounter := 0;
end;

function TMidiSynth.AllocVoice(AChannel, ANote: Integer): Integer;
var
  i, bestReleased, bestOldest: Integer;
  oldestAge, relAge: Int64;
begin
  { 1) reuse a voice already sounding the same channel+note }
  for i := 0 to High(FVoices) do
    if FVoices[i].Active and (FVoices[i].Channel = AChannel) and (FVoices[i].Note = ANote) then
      Exit(i);
  { 2) a free voice }
  bestReleased := -1;
  bestOldest := 0;
  oldestAge := High(Int64);
  relAge := High(Int64);
  for i := 0 to High(FVoices) do
  begin
    if not FVoices[i].Active then Exit(i);
    if (not FVoices[i].Held) and (FVoices[i].Age < relAge) then
    begin
      relAge := FVoices[i].Age;
      bestReleased := i;
    end;
    if FVoices[i].Age < oldestAge then
    begin
      oldestAge := FVoices[i].Age;
      bestOldest := i;
    end;
  end;
  if bestReleased >= 0 then Exit(bestReleased);
  Result := bestOldest;
end;

procedure TMidiSynth.RecalcVoicePitch(AIdx: Integer);
var
  ch: Integer;
  hz: Double;
begin
  ch := FVoices[AIdx].Channel;
  hz := FVoices[AIdx].BaseHz *
        SemitoneRatio(FChannels[ch].PitchBendSemis);
  FVoices[AIdx].PhaseInc := hz / FSampleRate;
end;

procedure TMidiSynth.StartVoice(AIdx, AChannel, ANote, AVelocity: Integer);
var
  cutoff, x: Double;
begin
  Inc(FAgeCounter);
  FVoices[AIdx].Active := True;
  FVoices[AIdx].Held := True;
  FVoices[AIdx].Channel := AChannel;
  FVoices[AIdx].Note := ANote;
  FVoices[AIdx].Phase := 0;
  FVoices[AIdx].Lp := 0;
  FVoices[AIdx].Age := FAgeCounter;
  FVoices[AIdx].Amp := (AVelocity / 127.0);
  FVoices[AIdx].Pan := FChannels[AChannel].Pan;
  FVoices[AIdx].PulseWidth := 0.35;

  if AChannel = MIDI_DRUM_CHANNEL then
  begin
    FVoices[AIdx].Shape := mwsNoise;
    FVoices[AIdx].BaseHz := 200.0;
    { fixed percussive decay: bass drums long, hats short }
    case ANote of
      35, 36:       FVoices[AIdx].DrumDecay := 0.18;
      38, 40:       FVoices[AIdx].DrumDecay := 0.12;
      42, 44:       FVoices[AIdx].DrumDecay := 0.04;
      46:           FVoices[AIdx].DrumDecay := 0.22;
      49, 51, 57:   FVoices[AIdx].DrumDecay := 0.9;
    else
      FVoices[AIdx].DrumDecay := 0.10;
    end;
    FVoices[AIdx].DrumLevel := 1.0;
    FVoices[AIdx].BaseHz := 80.0 + (ANote - 35) * 40.0;
    RecalcVoicePitch(AIdx);
    FVoices[AIdx].Env.SetADSR(0.5, 40.0, 0.0, 60.0);
    FVoices[AIdx].Env.NoteOn;
  end
  else
  begin
    FVoices[AIdx].Shape := MidiProgramShape(FChannels[AChannel].ProgramNo);
    FVoices[AIdx].BaseHz := MidiFrequency(ANote);
    RecalcVoicePitch(AIdx);
    { tone filter: brighter for higher notes and higher velocity }
    cutoff := 800.0 + FVoices[AIdx].BaseHz * 6.0 + AVelocity * 20.0;
    if cutoff > FSampleRate * 0.45 then cutoff := FSampleRate * 0.45;
    x := FastExp(-TWO_PI * cutoff / FSampleRate);
    FVoices[AIdx].LpCoef := x;
    { envelope by family: pads slow, plucks fast }
    case FVoices[AIdx].Shape of
      mwsTriangle: FVoices[AIdx].Env.SetADSR(4.0, 600.0, 0.35, 260.0);
      mwsSaw:      FVoices[AIdx].Env.SetADSR(8.0, 400.0, 0.55, 380.0);
      mwsSquare:   FVoices[AIdx].Env.SetADSR(3.0, 200.0, 0.7, 180.0);
      mwsPulse:    FVoices[AIdx].Env.SetADSR(10.0, 300.0, 0.6, 220.0);
      mwsSine:     FVoices[AIdx].Env.SetADSR(6.0, 500.0, 0.5, 300.0);
    else
      FVoices[AIdx].Env.SetADSR(5.0, 400.0, 0.5, 250.0);
    end;
    FVoices[AIdx].Env.NoteOn;
  end;
end;

procedure TMidiSynth.NoteOn(AChannel, ANote, AVelocity: Integer);
var
  idx: Integer;
begin
  AChannel := AChannel and $0F;
  if AVelocity <= 0 then
  begin
    NoteOff(AChannel, ANote, 0);
    Exit;
  end;
  if (AChannel = MIDI_DRUM_CHANNEL) and (FDrum <> nil) and FDrum.HitNote(ANote, AVelocity) then Exit;
  idx := AllocVoice(AChannel, ANote);
  StartVoice(idx, AChannel, ANote, AVelocity);
end;

procedure TMidiSynth.NoteOff(AChannel, ANote, AVelocity: Integer);
var
  i: Integer;
begin
  AChannel := AChannel and $0F;
  if (AChannel = MIDI_DRUM_CHANNEL) and (FDrum <> nil) then FDrum.ReleaseNote(ANote);
  for i := 0 to High(FVoices) do
    if FVoices[i].Active and (FVoices[i].Channel = AChannel) and
       (FVoices[i].Note = ANote) and FVoices[i].Held then
    begin
      FVoices[i].Held := False;
      if not FChannels[AChannel].Sustain then
        FVoices[i].Env.NoteOff;
    end;
end;

procedure TMidiSynth.ControlChange(AChannel, AController, AValue: Integer);
var
  i: Integer;
begin
  AChannel := AChannel and $0F;
  case AController of
    MIDI_CC_VOLUME:     FChannels[AChannel].Volume := AValue / 127.0;
    MIDI_CC_EXPRESSION: FChannels[AChannel].Expression := AValue / 127.0;
    MIDI_CC_PAN:        FChannels[AChannel].Pan := (AValue - 64) / 63.0;
    MIDI_CC_SUSTAIN:
      begin
        FChannels[AChannel].Sustain := AValue >= 64;
        if not FChannels[AChannel].Sustain then
          for i := 0 to High(FVoices) do
            if FVoices[i].Active and (FVoices[i].Channel = AChannel) and
               (not FVoices[i].Held) then
              FVoices[i].Env.NoteOff;
      end;
    MIDI_CC_RPN_MSB:    FChannels[AChannel].RpnMsb := AValue;
    MIDI_CC_RPN_LSB:    FChannels[AChannel].RpnLsb := AValue;
    MIDI_CC_DATA_MSB:
      if (FChannels[AChannel].RpnMsb = 0) and (FChannels[AChannel].RpnLsb = 0) then
        FChannels[AChannel].BendRange := AValue;    // RPN 0,0 = pitch bend range (semitones)
    MIDI_CC_ALL_SOUND_OFF:  AllNotesOff(AChannel);
    MIDI_CC_ALL_NOTES_OFF:  AllNotesOff(AChannel);
    MIDI_CC_RESET_ALL_CTRL:
      begin
        FChannels[AChannel].Expression := 1.0;
        FChannels[AChannel].PitchBendSemis := 0.0;
        FChannels[AChannel].Sustain := False;
      end;
  end;
end;

procedure TMidiSynth.ProgramChange(AChannel, AProgram: Integer);
begin
  FChannels[AChannel and $0F].ProgramNo := AProgram and $7F;
end;

procedure TMidiSynth.PitchBend(AChannel, AValue14: Integer);
var
  i: Integer;
begin
  AChannel := AChannel and $0F;
  FChannels[AChannel].PitchBendSemis :=
    (AValue14 / 8192.0) * FChannels[AChannel].BendRange;
  for i := 0 to High(FVoices) do
    if FVoices[i].Active and (FVoices[i].Channel = AChannel) then
      RecalcVoicePitch(i);
end;

procedure TMidiSynth.ChannelAftertouch(AChannel, AValue: Integer);
begin
  FChannels[AChannel and $0F].Aftertouch := AValue / 127.0;
end;

procedure TMidiSynth.AllNotesOff(AChannel: Integer);
var
  i: Integer;
begin
  AChannel := AChannel and $0F;
  for i := 0 to High(FVoices) do
    if FVoices[i].Active and (FVoices[i].Channel = AChannel) then
    begin
      FVoices[i].Held := False;
      FVoices[i].Env.NoteOff;
    end;
end;

procedure TMidiSynth.AllSoundOff;
var
  i: Integer;
begin
  for i := 0 to High(FVoices) do
  begin
    FVoices[i].Active := False;
    FVoices[i].Env.HardReset;
  end;
end;

procedure TMidiSynth.DispatchMessage(const AMsg: TMidiMessage);
begin
  case AMsg.StatusHi of
    MIDI_NOTE_ON:
      if AMsg.Data2 > 0 then NoteOn(AMsg.Channel, AMsg.Data1, AMsg.Data2)
      else NoteOff(AMsg.Channel, AMsg.Data1, 0);
    MIDI_NOTE_OFF:        NoteOff(AMsg.Channel, AMsg.Data1, AMsg.Data2);
    MIDI_CONTROL_CHANGE:  ControlChange(AMsg.Channel, AMsg.Data1, AMsg.Data2);
    MIDI_PROGRAM_CHANGE:  ProgramChange(AMsg.Channel, AMsg.Data1);
    MIDI_PITCH_BEND:      PitchBend(AMsg.Channel, AMsg.PitchBend14);
    MIDI_CHAN_AFTERTOUCH: ChannelAftertouch(AMsg.Channel, AMsg.Data1);
  end;
end;

function PolyBlep(AT, ADt: Double): Double;
begin
  { PolyBLEP residual for band-limiting discontinuities }
  if AT < ADt then
  begin
    AT := AT / ADt;
    Result := AT + AT - AT * AT - 1.0;
  end
  else if AT > 1.0 - ADt then
  begin
    AT := (AT - 1.0) / ADt;
    Result := AT * AT + AT + AT + 1.0;
  end
  else
    Result := 0.0;
end;

function TMidiSynth.Osc(var V: TMidiVoice): Single;
var
  t, dt, v0: Double;
  r: Integer;
begin
  t := V.Phase;
  dt := V.PhaseInc;
  case V.Shape of
    mwsSine:
      v0 := FastSin(t * TWO_PI);
    mwsTriangle:
      begin
        if t < 0.5 then v0 := 4.0 * t - 1.0 else v0 := 3.0 - 4.0 * t;
        { soften harmonics a touch }
        v0 := v0 * (1.0 - 0.15 * v0 * v0);
      end;
    mwsSaw:
      begin
        v0 := 2.0 * t - 1.0;
        v0 := v0 - PolyBlep(t, dt);
      end;
    mwsSquare:
      begin
        if t < 0.5 then v0 := 1.0 else v0 := -1.0;
        v0 := v0 + PolyBlep(t, dt);
        v0 := v0 - PolyBlep(Frac(t + 0.5), dt);
      end;
    mwsPulse:
      begin
        if t < V.PulseWidth then v0 := 1.0 else v0 := -1.0;
        v0 := v0 + PolyBlep(t, dt);
        v0 := v0 - PolyBlep(Frac(t + (1.0 - V.PulseWidth)), dt);
      end;
    mwsNoise:
      begin
        { xorshift white noise via the phase word reinterpreted as a counter }
        r := Integer(Round(V.Phase * 8388608.0)) xor $2545F491;
        r := r xor (r shl 13); r := r xor (r shr 17); r := r xor (r shl 5);
        v0 := (r / 1073741824.0);
        if v0 > 1 then v0 := 1 else if v0 < -1 then v0 := -1;
      end;
  else
    v0 := 0;
  end;

  V.Phase := V.Phase + dt;
  if V.Phase >= 1.0 then V.Phase := V.Phase - 1.0;

  { one-pole low-pass tone shaping for the pitched voices }
  if V.Shape <> mwsNoise then
  begin
    V.Lp := V.Lp + (1.0 - V.LpCoef) * (v0 - V.Lp);
    v0 := V.Lp;
  end;

  Result := v0;
end;

procedure TMidiSynth.RenderAdd(ABuffer: TAudioBuffer; AFrameCount: Integer);
var
  vi, f, nch: Integer;
  ch: Integer;
  e, s, lg, rg, chGain, pan: Double;
  L, R: PAudioSample;
  monoPtr: PAudioSample;
begin
  nch := ABuffer.ChannelCount;
  if (nch <= 0) or (AFrameCount <= 0) then Exit;
  if FDrum <> nil then FDrum.RenderAdd(ABuffer, AFrameCount);
  L := ABuffer.ChannelPtr(0);
  if nch >= 2 then R := ABuffer.ChannelPtr(1) else R := L;

  for vi := 0 to High(FVoices) do
  begin
    if not FVoices[vi].Active then Continue;
    ch := FVoices[vi].Channel;
    chGain := FChannels[ch].Volume * FChannels[ch].Expression *
              (0.85 + 0.15 * FChannels[ch].Aftertouch);
    pan := FVoices[vi].Pan;
    if pan < -1 then pan := -1 else if pan > 1 then pan := 1;
    { equal-power pan }
    lg := FastCos((pan + 1.0) * (Pi / 4.0));
    rg := FastSin((pan + 1.0) * (Pi / 4.0));

    for f := 0 to AFrameCount - 1 do
    begin
      if not FVoices[vi].Env.IsActive then
      begin
        FVoices[vi].Active := False;
        Break;
      end;
      e := FVoices[vi].Env.Process;
      s := Osc(FVoices[vi]) * e * FVoices[vi].Amp * chGain;

      if (ch = MIDI_DRUM_CHANNEL) and (FVoices[vi].DrumDecay > 0) then
      begin
        s := s * FVoices[vi].DrumLevel;
        FVoices[vi].DrumLevel := FVoices[vi].DrumLevel -
          (1.0 / (FVoices[vi].DrumDecay * FSampleRate));
        if FVoices[vi].DrumLevel <= 0 then
        begin
          FVoices[vi].DrumLevel := 0;
          FVoices[vi].Active := False;
        end;
      end;

      s := s * FMasterGain;
      if nch >= 2 then
      begin
        (L + f)^ := (L + f)^ + Single(s * lg);
        (R + f)^ := (R + f)^ + Single(s * rg);
      end
      else
      begin
        monoPtr := L;
        (monoPtr + f)^ := (monoPtr + f)^ + Single(s);
      end;
    end;
  end;

  { spread the synth across any extra channels as a copy of L }
  for ch := 2 to nch - 1 do
  begin
    monoPtr := ABuffer.ChannelPtr(ch);
    for f := 0 to AFrameCount - 1 do
      (monoPtr + f)^ := (L + f)^;
  end;
end;

function TMidiSynth.ActiveVoiceCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FVoices) do
    if FVoices[i].Active then Inc(Result);
end;

{ ============================ TMidiPlaybackEngine =============== }

constructor TMidiPlaybackEngine.Create;
begin
  inherited Create;
  FSynth := TMidiSynth.Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  FTempoScale := 1.0;
  FRate := 1.0;
end;

destructor TMidiPlaybackEngine.Destroy;
begin
  FSynth.Free;
  inherited Destroy;
end;

procedure TMidiPlaybackEngine.SetSequence(ASeq: TMidiSequence);
begin
  FSeq := ASeq;
  Rebuild;
end;

procedure TMidiPlaybackEngine.Flatten;
var
  ti, ni, ci, ai, i, j: Integer;
  trk: TMidiTrackSeq;
  ev: TEngineEvent;
  cap: Integer;

  procedure Push(ATick: Int64; const M: TMidiMessage);
  begin
    if FEventCount >= cap then
    begin
      cap := cap * 2;
      SetLength(FEvents, cap);
    end;
    FEvents[FEventCount].Tick := ATick;
    FEvents[FEventCount].Msg := M;
    Inc(FEventCount);
  end;

begin
  FEventCount := 0;
  cap := 1024;
  SetLength(FEvents, cap);
  FEndTick := 0;
  if FSeq = nil then Exit;

  for ti := 0 to FSeq.TrackCount - 1 do
  begin
    trk := FSeq.GetTrack(ti);
    for ni := 0 to trk.NoteCount - 1 do
    begin
      Push(trk.Notes[ni].StartTick,
        TMidiMessage.NoteOn(trk.Notes[ni].Channel, trk.Notes[ni].Note, trk.Notes[ni].Velocity));
      Push(trk.Notes[ni].EndTick,
        TMidiMessage.NoteOff(trk.Notes[ni].Channel, trk.Notes[ni].Note, trk.Notes[ni].OffVelocity));
      FEndTick := Max(FEndTick, trk.Notes[ni].EndTick);
    end;
    for ci := 0 to trk.CCCount - 1 do
      Push(trk.Controllers[ci].Tick,
        TMidiMessage.ControlChange(trk.Controllers[ci].Channel,
          trk.Controllers[ci].Controller, trk.Controllers[ci].Value));
    for ai := 0 to trk.AuxCount - 1 do
      if trk.Aux[ai].Kind = mekChannel then
        Push(trk.Aux[ai].Tick, trk.Aux[ai].Msg);
  end;

  { stable insertion sort by tick (event lists are near-sorted per track) }
  for i := 1 to FEventCount - 1 do
  begin
    ev := FEvents[i];
    j := i - 1;
    while (j >= 0) and (FEvents[j].Tick > ev.Tick) do
    begin
      FEvents[j + 1] := FEvents[j];
      Dec(j);
    end;
    FEvents[j + 1] := ev;
  end;
end;

procedure TMidiPlaybackEngine.Rebuild;
begin
  Flatten;
  SeekInternal(FSeconds);
end;

procedure TMidiPlaybackEngine.SeekInternal(ASeconds: Double);
var
  tick: Int64;
begin
  if ASeconds < 0 then ASeconds := 0;
  FSeconds := ASeconds;
  FSynth.AllSoundOff;
  FCursor := 0;
  if FSeq = nil then Exit;
  tick := FSeq.SecondsToTick(ASeconds * FTempoScale);
  while (FCursor < FEventCount) and (FEvents[FCursor].Tick < tick) do
  begin
    { apply state-affecting events (CC / program / bend) while scrubbing, but
      not note-ons, so a seek lands silent }
    if FEvents[FCursor].Msg.StatusHi in
       [MIDI_CONTROL_CHANGE, MIDI_PROGRAM_CHANGE, MIDI_PITCH_BEND] then
      FSynth.DispatchMessage(FEvents[FCursor].Msg);
    Inc(FCursor);
  end;
end;

procedure TMidiPlaybackEngine.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  FSynth.Init(FSampleRate);
  Rebuild;
end;

procedure TMidiPlaybackEngine.Reset;
begin
  FPlaying := False;
  FSeconds := 0;
  FSynth.Reset;
  SeekInternal(0);
end;

function TMidiPlaybackEngine.Name: string;
begin
  Result := 'midi-playback-engine';
end;

procedure TMidiPlaybackEngine.Play;
begin
  FPlaying := True;
end;

procedure TMidiPlaybackEngine.Stop;
begin
  FPlaying := False;
  FSynth.AllSoundOff;
end;

procedure TMidiPlaybackEngine.SeekSeconds(ASeconds: Double);
begin
  SeekInternal(ASeconds);
end;

procedure TMidiPlaybackEngine.SeekTick(ATick: Int64);
begin
  if FSeq <> nil then
    SeekInternal(FSeq.TickToSeconds(ATick) / Max(0.0001, FTempoScale));
end;

procedure TMidiPlaybackEngine.Render(ABuffer: TAudioBuffer);
var
  n: Integer;
  blockSeconds, endSeconds: Double;
  curTick: Int64;
begin
  ABuffer.Clear;
  n := ABuffer.FrameCount;
  if ABuffer.SampleRate > 0 then FSampleRate := ABuffer.SampleRate;
  if (not FPlaying) or (FSeq = nil) or (n <= 0) then
  begin
    { still let voice tails ring out even when transport is stopped }
    if FSeq <> nil then FSynth.RenderAdd(ABuffer, n);
    Exit;
  end;

  blockSeconds := n / FSampleRate;
  endSeconds := FSeconds + blockSeconds * Max(0.01, FRate);

  { dispatch every event whose tick falls before the END of this block.  Sample-
    accurate scheduling within the block is approximated to the block edge -
    adequate for a preview synth and for offline bounce at small block sizes. }
  curTick := FSeq.SecondsToTick(endSeconds * FTempoScale);
  while (FCursor < FEventCount) and (FEvents[FCursor].Tick <= curTick) do
  begin
    FSynth.DispatchMessage(FEvents[FCursor].Msg);
    Inc(FCursor);
  end;

  FSynth.RenderAdd(ABuffer, n);
  FSeconds := endSeconds;

  if FLoop and (FLoopEndSec > FLoopStartSec) and (FSeconds >= FLoopEndSec) then
    SeekInternal(FLoopStartSec)
  else if (FCursor >= FEventCount) and (FSynth.ActiveVoiceCount = 0) then
    FPlaying := False;
end;

function TMidiPlaybackEngine.RenderToPlanar(ASampleRate, AChannels: Integer;
  ATailSeconds: Double): TAudioPlanar;
var
  buf: TAudioBuffer;
  block, ch, f, written, total: Integer;
  totalSeconds: Double;
  src: PAudioSample;
begin
  SetLength(Result, 0);
  if FSeq = nil then Exit;
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  if AChannels <= 0 then AChannels := 2;

  Prepare(ASampleRate, 1024, AChannels);
  SeekInternal(0);
  Play;

  totalSeconds := FSeq.DurationSeconds / Max(0.0001, FTempoScale) + Max(0.0, ATailSeconds);
  total := Max(1, Round(totalSeconds * ASampleRate));
  EnsurePlanar(Result, AChannels, total);
  for ch := 0 to AChannels - 1 do
    FillChar(Result[ch][0], total * SizeOf(Single), 0);

  buf := TAudioBuffer.Create(AChannels, 1024, ASampleRate);
  try
    written := 0;
    while written < total do
    begin
      block := Min(1024, total - written);
      buf.SetActiveFrames(block);
      Render(buf);
      for ch := 0 to AChannels - 1 do
      begin
        src := buf.ChannelPtr(ch);
        for f := 0 to block - 1 do
          Result[ch][written + f] := (src + f)^;
      end;
      Inc(written, block);
      if (not FPlaying) and (FSynth.ActiveVoiceCount = 0) then Break;
    end;
  finally
    buf.Free;
  end;
  { trim to what we actually wrote }
  if written < total then
    for ch := 0 to AChannels - 1 do
      SetLength(Result[ch], written);
end;

end.
