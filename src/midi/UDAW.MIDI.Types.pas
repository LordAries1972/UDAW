unit UDAW.MIDI.Types;
{$I udaw.inc}

{ Phase 17 - MIDI (plan section 25).  Core shared types for the MIDI engine and
  piano roll: channel-voice messages, meta events, one timestamped event, and
  the small helper tables (note names, GM program names) the UI needs.

  Nothing here does IO.  Standard MIDI File parsing/writing is in
  UDAW.MIDI.SMF; the musical (note/tempo) model is in UDAW.MIDI.Sequence. }

interface

uses
  SysUtils, Math, StrUtils;

const
  MIDI_SUBSYS = 'MIDI';

  { status nibbles (high nibble of a channel-voice status byte) }
  MIDI_NOTE_OFF        = $80;
  MIDI_NOTE_ON         = $90;
  MIDI_POLY_AFTERTOUCH = $A0;
  MIDI_CONTROL_CHANGE  = $B0;
  MIDI_PROGRAM_CHANGE  = $C0;
  MIDI_CHAN_AFTERTOUCH = $D0;
  MIDI_PITCH_BEND      = $E0;
  MIDI_SYSEX_START     = $F0;
  MIDI_SYSEX_END       = $F7;
  MIDI_META            = $FF;

  { common controllers }
  MIDI_CC_BANK_MSB     = 0;
  MIDI_CC_MOD_WHEEL    = 1;
  MIDI_CC_BREATH       = 2;
  MIDI_CC_FOOT         = 4;
  MIDI_CC_PORTA_TIME   = 5;
  MIDI_CC_DATA_MSB     = 6;
  MIDI_CC_VOLUME       = 7;
  MIDI_CC_BALANCE      = 8;
  MIDI_CC_PAN          = 10;
  MIDI_CC_EXPRESSION   = 11;
  MIDI_CC_BANK_LSB     = 32;
  MIDI_CC_DATA_LSB     = 38;
  MIDI_CC_SUSTAIN      = 64;
  MIDI_CC_PORTAMENTO   = 65;
  MIDI_CC_SOSTENUTO    = 66;
  MIDI_CC_SOFT_PEDAL   = 67;
  MIDI_CC_RESONANCE    = 71;
  MIDI_CC_RELEASE      = 72;
  MIDI_CC_ATTACK       = 73;
  MIDI_CC_BRIGHTNESS   = 74;
  MIDI_CC_REVERB       = 91;
  MIDI_CC_CHORUS       = 93;
  MIDI_CC_RPN_LSB      = 100;
  MIDI_CC_RPN_MSB      = 101;
  MIDI_CC_ALL_SOUND_OFF   = 120;
  MIDI_CC_RESET_ALL_CTRL  = 121;
  MIDI_CC_ALL_NOTES_OFF   = 123;

  { meta-event types }
  META_SEQ_NUMBER   = $00;
  META_TEXT         = $01;
  META_COPYRIGHT    = $02;
  META_TRACK_NAME   = $03;
  META_INSTRUMENT   = $04;
  META_LYRIC        = $05;
  META_MARKER       = $06;
  META_CUE_POINT    = $07;
  META_PROGRAM_NAME = $08;
  META_DEVICE_NAME  = $09;
  META_CHANNEL_PREFIX = $20;
  META_PORT         = $21;
  META_END_OF_TRACK = $2F;
  META_SET_TEMPO    = $51;
  META_SMPTE_OFFSET = $54;
  META_TIME_SIG     = $58;
  META_KEY_SIG      = $59;
  META_SEQ_SPECIFIC = $7F;

  MIDI_DEFAULT_PPQ   = 480;
  MIDI_DEFAULT_TEMPO_US = 500000;   // 120 BPM in microseconds per quarter note

type
  TMidiEventKind = (mekChannel, mekMeta, mekSysEx);

  { A channel-voice message.  For running-status economy the SMF reader expands
    everything to an explicit status byte here. }
  TMidiMessage = record
    Status: Byte;      // full status incl. channel, e.g. $93
    Data1: Byte;
    Data2: Byte;
    function StatusHi: Byte;               // $80..$E0
    function Channel: Integer;             // 0..15
    function IsNoteOn: Boolean;            // NoteOn with velocity > 0
    function IsNoteOff: Boolean;           // NoteOff, or NoteOn velocity 0
    function NoteNumber: Integer;
    function Velocity: Integer;
    function PitchBend14: Integer;         // -8192..+8191
    class function NoteOn(AChannel, ANote, AVel: Integer): TMidiMessage; static;
    class function NoteOff(AChannel, ANote, AVel: Integer): TMidiMessage; static;
    class function ControlChange(AChannel, ACC, AValue: Integer): TMidiMessage; static;
    class function ProgramChange(AChannel, AProgram: Integer): TMidiMessage; static;
    class function PitchBend(AChannel, AValue: Integer): TMidiMessage; static;   // AValue -8192..8191
    function Describe: string;
  end;

  { One timestamped event on a track.  Tick is absolute (from the SMF reader) or
    relative only inside the writer. }
  TMidiEvent = record
    Tick: Int64;
    Kind: TMidiEventKind;
    Msg: TMidiMessage;        // valid when Kind = mekChannel
    MetaType: Byte;           // valid when Kind = mekMeta
    Bytes: TBytes;            // meta payload, or full SysEx (incl. leading $F0)
    function TempoMicros: Cardinal;      // META_SET_TEMPO -> us/quarter
    function TimeSigParts(out ANum, ADenPow2, AClocks, A32nds: Integer): Boolean;
    function KeySigParts(out ASharpsFlats: Integer; out AMinor: Boolean): Boolean;
    function AsText: string;             // for text-family metas
    function Describe: string;
  end;
  TMidiEventArray = TArray<TMidiEvent>;

function MidiNoteName(ANote: Integer): string;         // 60 -> "C4"
function MidiNoteIsBlack(ANote: Integer): Boolean;
function MidiFrequency(ANote: Integer): Double;        // equal temperament, A4=440
function GMProgramName(AProgram: Integer): string;     // 0..127
function GMDrumName(ANote: Integer): string;           // channel 10 percussion map
function TempoToBPM(AMicrosPerQuarter: Cardinal): Double;
function BPMToTempo(ABPM: Double): Cardinal;

implementation

{ ============================ TMidiMessage ========================= }

function TMidiMessage.StatusHi: Byte;
begin
  Result := Status and $F0;
end;

function TMidiMessage.Channel: Integer;
begin
  Result := Status and $0F;
end;

function TMidiMessage.IsNoteOn: Boolean;
begin
  Result := (StatusHi = MIDI_NOTE_ON) and (Data2 > 0);
end;

function TMidiMessage.IsNoteOff: Boolean;
begin
  Result := (StatusHi = MIDI_NOTE_OFF) or
            ((StatusHi = MIDI_NOTE_ON) and (Data2 = 0));
end;

function TMidiMessage.NoteNumber: Integer;
begin
  Result := Data1 and $7F;
end;

function TMidiMessage.Velocity: Integer;
begin
  Result := Data2 and $7F;
end;

function TMidiMessage.PitchBend14: Integer;
begin
  Result := ((Integer(Data2 and $7F) shl 7) or Integer(Data1 and $7F)) - 8192;
end;

class function TMidiMessage.NoteOn(AChannel, ANote, AVel: Integer): TMidiMessage;
begin
  Result.Status := MIDI_NOTE_ON or (AChannel and $0F);
  Result.Data1 := ANote and $7F;
  Result.Data2 := AVel and $7F;
end;

class function TMidiMessage.NoteOff(AChannel, ANote, AVel: Integer): TMidiMessage;
begin
  Result.Status := MIDI_NOTE_OFF or (AChannel and $0F);
  Result.Data1 := ANote and $7F;
  Result.Data2 := AVel and $7F;
end;

class function TMidiMessage.ControlChange(AChannel, ACC, AValue: Integer): TMidiMessage;
begin
  Result.Status := MIDI_CONTROL_CHANGE or (AChannel and $0F);
  Result.Data1 := ACC and $7F;
  Result.Data2 := AValue and $7F;
end;

class function TMidiMessage.ProgramChange(AChannel, AProgram: Integer): TMidiMessage;
begin
  Result.Status := MIDI_PROGRAM_CHANGE or (AChannel and $0F);
  Result.Data1 := AProgram and $7F;
  Result.Data2 := 0;
end;

class function TMidiMessage.PitchBend(AChannel, AValue: Integer): TMidiMessage;
var
  v: Integer;
begin
  v := AValue + 8192;
  if v < 0 then v := 0 else if v > 16383 then v := 16383;
  Result.Status := MIDI_PITCH_BEND or (AChannel and $0F);
  Result.Data1 := v and $7F;
  Result.Data2 := (v shr 7) and $7F;
end;

function TMidiMessage.Describe: string;
begin
  case StatusHi of
    MIDI_NOTE_OFF: Result := Format('ch%d NoteOff %s v%d', [Channel + 1, MidiNoteName(Data1), Data2]);
    MIDI_NOTE_ON:  Result := Format('ch%d NoteOn  %s v%d', [Channel + 1, MidiNoteName(Data1), Data2]);
    MIDI_POLY_AFTERTOUCH: Result := Format('ch%d PolyAT %s %d', [Channel + 1, MidiNoteName(Data1), Data2]);
    MIDI_CONTROL_CHANGE:  Result := Format('ch%d CC %d = %d', [Channel + 1, Data1, Data2]);
    MIDI_PROGRAM_CHANGE:  Result := Format('ch%d Program %d (%s)', [Channel + 1, Data1, GMProgramName(Data1)]);
    MIDI_CHAN_AFTERTOUCH: Result := Format('ch%d ChanAT %d', [Channel + 1, Data1]);
    MIDI_PITCH_BEND:      Result := Format('ch%d PitchBend %d', [Channel + 1, PitchBend14]);
  else
    Result := Format('status $%.2x %d %d', [Status, Data1, Data2]);
  end;
end;

{ ============================ TMidiEvent =========================== }

function TMidiEvent.TempoMicros: Cardinal;
begin
  if (Kind = mekMeta) and (MetaType = META_SET_TEMPO) and (Length(Bytes) >= 3) then
    Result := (Cardinal(Bytes[0]) shl 16) or (Cardinal(Bytes[1]) shl 8) or Cardinal(Bytes[2])
  else
    Result := MIDI_DEFAULT_TEMPO_US;
end;

function TMidiEvent.TimeSigParts(out ANum, ADenPow2, AClocks, A32nds: Integer): Boolean;
begin
  ANum := 4; ADenPow2 := 2; AClocks := 24; A32nds := 8;
  Result := (Kind = mekMeta) and (MetaType = META_TIME_SIG) and (Length(Bytes) >= 4);
  if Result then
  begin
    ANum := Bytes[0];
    ADenPow2 := Bytes[1];
    AClocks := Bytes[2];
    A32nds := Bytes[3];
  end;
end;

function TMidiEvent.KeySigParts(out ASharpsFlats: Integer; out AMinor: Boolean): Boolean;
begin
  ASharpsFlats := 0; AMinor := False;
  Result := (Kind = mekMeta) and (MetaType = META_KEY_SIG) and (Length(Bytes) >= 2);
  if Result then
  begin
    ASharpsFlats := ShortInt(Bytes[0]);
    AMinor := Bytes[1] = 1;
  end;
end;

function TMidiEvent.AsText: string;
begin
  if (Kind = mekMeta) and (Length(Bytes) > 0) then
    Result := TEncoding.ANSI.GetString(Bytes)
  else
    Result := '';
end;

function TMidiEvent.Describe: string;
var
  n, d, c, s, sf: Integer;
  mn: Boolean;
begin
  case Kind of
    mekChannel: Result := Format('@%d %s', [Tick, Msg.Describe]);
    mekSysEx:   Result := Format('@%d SysEx %d bytes', [Tick, Length(Bytes)]);
    mekMeta:
      case MetaType of
        META_TRACK_NAME: Result := Format('@%d TrackName "%s"', [Tick, AsText]);
        META_TEXT:       Result := Format('@%d Text "%s"', [Tick, AsText]);
        META_MARKER:     Result := Format('@%d Marker "%s"', [Tick, AsText]);
        META_SET_TEMPO:  Result := Format('@%d Tempo %.2f BPM', [Tick, TempoToBPM(TempoMicros)]);
        META_TIME_SIG:
          begin
            TimeSigParts(n, d, c, s);
            Result := Format('@%d TimeSig %d/%d', [Tick, n, 1 shl d]);
          end;
        META_KEY_SIG:
          begin
            KeySigParts(sf, mn);
            Result := Format('@%d KeySig %d%s', [Tick, sf, IfThen(mn, ' minor', ' major')]);
          end;
        META_END_OF_TRACK: Result := Format('@%d EndOfTrack', [Tick]);
      else
        Result := Format('@%d Meta $%.2x %d bytes', [Tick, MetaType, Length(Bytes)]);
      end;
  else
    Result := Format('@%d ?', [Tick]);
  end;
end;

{ ============================ helper tables ======================= }

function MidiNoteName(ANote: Integer): string;
const
  NAMES: array[0..11] of string = ('C', 'C#', 'D', 'D#', 'E', 'F',
    'F#', 'G', 'G#', 'A', 'A#', 'B');
var
  octave: Integer;
begin
  if (ANote < 0) or (ANote > 127) then Exit(Format('n%d', [ANote]));
  octave := (ANote div 12) - 1;   // MIDI 60 = C4 (Yamaha/"middle C" convention)
  Result := NAMES[ANote mod 12] + IntToStr(octave);
end;

function MidiNoteIsBlack(ANote: Integer): Boolean;
begin
  case ((ANote mod 12) + 12) mod 12 of
    1, 3, 6, 8, 10: Result := True;
  else
    Result := False;
  end;
end;

function MidiFrequency(ANote: Integer): Double;
begin
  Result := 440.0 * Power(2.0, (ANote - 69) / 12.0);
end;

function TempoToBPM(AMicrosPerQuarter: Cardinal): Double;
begin
  if AMicrosPerQuarter = 0 then Exit(120.0);
  Result := 60000000.0 / AMicrosPerQuarter;
end;

function BPMToTempo(ABPM: Double): Cardinal;
begin
  if ABPM <= 0 then Exit(MIDI_DEFAULT_TEMPO_US);
  Result := Round(60000000.0 / ABPM);
end;

function GMProgramName(AProgram: Integer): string;
const
  GM: array[0..127] of string = (
    'Acoustic Grand Piano','Bright Acoustic Piano','Electric Grand Piano','Honky-tonk Piano',
    'Electric Piano 1','Electric Piano 2','Harpsichord','Clavinet',
    'Celesta','Glockenspiel','Music Box','Vibraphone','Marimba','Xylophone','Tubular Bells','Dulcimer',
    'Drawbar Organ','Percussive Organ','Rock Organ','Church Organ','Reed Organ',
    'Accordion','Harmonica','Tango Accordion',
    'Acoustic Guitar (nylon)','Acoustic Guitar (steel)','Electric Guitar (jazz)','Electric Guitar (clean)',
    'Electric Guitar (muted)','Overdriven Guitar','Distortion Guitar','Guitar Harmonics',
    'Acoustic Bass','Electric Bass (finger)','Electric Bass (pick)','Fretless Bass',
    'Slap Bass 1','Slap Bass 2','Synth Bass 1','Synth Bass 2',
    'Violin','Viola','Cello','Contrabass','Tremolo Strings','Pizzicato Strings','Orchestral Harp','Timpani',
    'String Ensemble 1','String Ensemble 2','Synth Strings 1','Synth Strings 2',
    'Choir Aahs','Voice Oohs','Synth Voice','Orchestra Hit',
    'Trumpet','Trombone','Tuba','Muted Trumpet','French Horn','Brass Section','Synth Brass 1','Synth Brass 2',
    'Soprano Sax','Alto Sax','Tenor Sax','Baritone Sax','Oboe','English Horn','Bassoon','Clarinet',
    'Piccolo','Flute','Recorder','Pan Flute','Blown Bottle','Shakuhachi','Whistle','Ocarina',
    'Lead 1 (square)','Lead 2 (sawtooth)','Lead 3 (calliope)','Lead 4 (chiff)',
    'Lead 5 (charang)','Lead 6 (voice)','Lead 7 (fifths)','Lead 8 (bass + lead)',
    'Pad 1 (new age)','Pad 2 (warm)','Pad 3 (polysynth)','Pad 4 (choir)',
    'Pad 5 (bowed)','Pad 6 (metallic)','Pad 7 (halo)','Pad 8 (sweep)',
    'FX 1 (rain)','FX 2 (soundtrack)','FX 3 (crystal)','FX 4 (atmosphere)',
    'FX 5 (brightness)','FX 6 (goblins)','FX 7 (echoes)','FX 8 (sci-fi)',
    'Sitar','Banjo','Shamisen','Koto','Kalimba','Bag pipe','Fiddle','Shanai',
    'Tinkle Bell','Agogo','Steel Drums','Woodblock','Taiko Drum','Melodic Tom','Synth Drum','Reverse Cymbal',
    'Guitar Fret Noise','Breath Noise','Seashore','Bird Tweet','Telephone Ring','Helicopter',
    'Applause','Gunshot');
begin
  if (AProgram < 0) or (AProgram > 127) then Exit(Format('program %d', [AProgram]));
  Result := GM[AProgram];
end;

function GMDrumName(ANote: Integer): string;
begin
  case ANote of
    35: Result := 'Acoustic Bass Drum';
    36: Result := 'Bass Drum 1';
    37: Result := 'Side Stick';
    38: Result := 'Acoustic Snare';
    39: Result := 'Hand Clap';
    40: Result := 'Electric Snare';
    41: Result := 'Low Floor Tom';
    42: Result := 'Closed Hi-Hat';
    43: Result := 'High Floor Tom';
    44: Result := 'Pedal Hi-Hat';
    45: Result := 'Low Tom';
    46: Result := 'Open Hi-Hat';
    47: Result := 'Low-Mid Tom';
    48: Result := 'Hi-Mid Tom';
    49: Result := 'Crash Cymbal 1';
    50: Result := 'High Tom';
    51: Result := 'Ride Cymbal 1';
    52: Result := 'Chinese Cymbal';
    53: Result := 'Ride Bell';
    54: Result := 'Tambourine';
    55: Result := 'Splash Cymbal';
    56: Result := 'Cowbell';
    57: Result := 'Crash Cymbal 2';
    59: Result := 'Ride Cymbal 2';
    60: Result := 'Hi Bongo';
    61: Result := 'Low Bongo';
    62: Result := 'Mute Hi Conga';
    63: Result := 'Open Hi Conga';
    64: Result := 'Low Conga';
    65: Result := 'High Timbale';
    66: Result := 'Low Timbale';
    67: Result := 'High Agogo';
    68: Result := 'Low Agogo';
    69: Result := 'Cabasa';
    70: Result := 'Maracas';
    75: Result := 'Claves';
  else
    Result := Format('perc %d', [ANote]);
  end;
end;

end.
