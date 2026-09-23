unit UDAW.Tracker.Types;
{$I udaw.inc}

{ Phase 11 - Tracker Engine: value types shared by the pattern model, the
  replay core and the serializer.

  A pattern cell is Note / Instrument / Volume / Effect / EffectParameter, e.g.
  the classic display "C-4 01 40 A06" - note C in octave 4, instrument 01,
  volume 40 (hex, 0..40 = 0..64), effect A parameter 06.

  Note values: 1 = C-0 .. 120 = B-9 (semitone index = value - 1). Two special
  values carry key-off and hard-cut. Frequency uses equal temperament with
  A-4 (value 58) = 440 Hz.

  Effect lettering is UDAW's own documented set (see EFFECT_LETTERS); it is
  close to the XM/ProTracker tradition but not tied to any one tracker - the
  MOD / XM / MPTM importers of later phases map their commands onto it. }

interface

uses
  SysUtils, Math;

const
  TRK_SUBSYS = 'Tracker';

  TRK_NOTE_NONE = 0;      // empty cell
  TRK_NOTE_MIN  = 1;      // C-0
  TRK_NOTE_MAX  = 120;    // B-9
  TRK_NOTE_OFF  = 253;    // key off  -> envelope release / fadeout ("===")
  TRK_NOTE_CUT  = 254;    // hard cut -> silence now              ("^^^")

  TRK_INSTR_NONE = 0;
  TRK_INSTR_MAX  = 255;

  TRK_VOL_NONE = 255;
  TRK_VOL_MAX  = 64;

  TRK_MIN_CHANNELS = 1;
  TRK_MAX_CHANNELS = 64;
  TRK_MIN_ROWS     = 1;
  TRK_MAX_ROWS     = 1024;

  TRK_MIN_SPEED = 1;       // ticks per row
  TRK_MAX_SPEED = 31;
  TRK_MIN_BPM   = 32;
  TRK_MAX_BPM   = 999;

  TRK_DEFAULT_CHANNELS = 4;
  TRK_DEFAULT_ROWS     = 64;
  TRK_DEFAULT_SPEED    = 6;
  TRK_DEFAULT_BPM      = 125;

  A4_NOTE_VALUE = 58;      // value that sounds A-4 = 440 Hz
  A4_HZ         = 440.0;

type
  TTrackerEffect = (
    tfxNone,          // .   no effect
    tfxArpeggio,      // J   xy  cycle note, note+x, note+y each tick
    tfxPortaUp,       // F   xx  slide pitch up   (xx/16 semitone per tick)
    tfxPortaDown,     // E   xx  slide pitch down
    tfxTonePorta,     // G   xx  glide toward the new note at xx/16 semitone/tick
    tfxVibrato,       // H   xy  x = speed, y = depth (pitch)
    tfxTremolo,       // R   xy  x = speed, y = depth (volume)
    tfxVolSlide,      // D   xy  x up / y down, per tick (x*4 / y*4 of 0..255)
    tfxSetVolume,     // C   xx  set channel volume 0..64
    tfxSampleOffset,  // O   xx  start the note at xx*256 sample frames
    tfxPositionJump,  // B   xx  jump to order position xx (row 0)
    tfxPatternBreak,  // K   xx  break to row xx of the next order position
    tfxSetSpeed,      // A   xx  set ticks-per-row (1..1F) or BPM (>=20)
    tfxSetBPM,        // T   xx  set BPM explicitly
    tfxNoteDelay,     // W   0y  trigger the note on tick y
    tfxNoteCut,       // X   0y  set volume to 0 on tick y
    tfxRetrigger,     // Q   0y  retrigger the note every y ticks
    tfxSetPanning,    // P   xx  set channel pan 00 (L) .. FF (R)
    tfxPanSlide,      // Y   xy  x right / y left per tick
    tfxFineVolUp,     // U   0x  add x to volume once (row scope)
    tfxFineVolDown,   // V   0x  subtract x from volume once
    tfxVibratoWaveform,  // I   0x  x&3 = vibrato waveform: sine/ramp-down/square/random
    tfxTremoloWaveform   // Z   0x  x&3 = tremolo waveform: sine/ramp-down/square/random
  );

  { One pattern cell. Instrument 0 = "keep current"; Volume 255 = "no volume
    column"; Effect tfxNone with Param 0 = "no effect". }
  TTrackerCell = record
    Note: Byte;
    Instrument: Byte;
    Volume: Byte;
    Effect: TTrackerEffect;
    Param: Byte;
    class function Empty: TTrackerCell; static;
    function IsEmpty: Boolean;
  end;

const
  EFFECT_LETTERS: array[TTrackerEffect] of Char = (
    '.', 'J', 'F', 'E', 'G', 'H', 'R', 'D', 'C', 'O', 'B', 'K',
    'A', 'T', 'W', 'X', 'Q', 'P', 'Y', 'U', 'V', 'I', 'Z');

function EffectFromLetter(ALetter: Char; out AEffect: TTrackerEffect): Boolean;
function EffectLetter(AEffect: TTrackerEffect): Char;

{ "C-4", "===", "^^^", "..." }
function NoteName(ANote: Byte): string;
function NoteFromName(const AName: string; out ANote: Byte): Boolean;
{ Playback frequency of a (fractional) note value. }
function NoteToHz(ANote: Double): Double;

function ClampInt(AValue, ALo, AHi: Integer): Integer;

implementation

const
  SEMI: array[0..11] of string =
    ('C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-');

function ClampInt(AValue, ALo, AHi: Integer): Integer;
begin
  if AValue < ALo then Result := ALo
  else if AValue > AHi then Result := AHi
  else Result := AValue;
end;

{ ---------------- TTrackerCell ---------------- }

class function TTrackerCell.Empty: TTrackerCell;
begin
  Result.Note := TRK_NOTE_NONE;
  Result.Instrument := TRK_INSTR_NONE;
  Result.Volume := TRK_VOL_NONE;
  Result.Effect := tfxNone;
  Result.Param := 0;
end;

function TTrackerCell.IsEmpty: Boolean;
begin
  Result := (Note = TRK_NOTE_NONE) and (Instrument = TRK_INSTR_NONE)
    and (Volume = TRK_VOL_NONE) and (Effect = tfxNone) and (Param = 0);
end;

{ ---------------- effect letters ---------------- }

function EffectLetter(AEffect: TTrackerEffect): Char;
begin
  Result := EFFECT_LETTERS[AEffect];
end;

function EffectFromLetter(ALetter: Char; out AEffect: TTrackerEffect): Boolean;
var
  e: TTrackerEffect;
begin
  ALetter := UpCase(ALetter);
  for e := Low(TTrackerEffect) to High(TTrackerEffect) do
    if EFFECT_LETTERS[e] = ALetter then
    begin
      AEffect := e;
      Exit(True);
    end;
  Result := False;
end;

{ ---------------- notes ---------------- }

function NoteName(ANote: Byte): string;
var
  idx, oct: Integer;
begin
  case ANote of
    TRK_NOTE_NONE: Exit('...');
    TRK_NOTE_OFF:  Exit('===');
    TRK_NOTE_CUT:  Exit('^^^');
  end;
  if (ANote < TRK_NOTE_MIN) or (ANote > TRK_NOTE_MAX) then Exit('???');
  idx := (ANote - 1) mod 12;
  oct := (ANote - 1) div 12;
  Result := SEMI[idx] + IntToStr(oct);
end;

function NoteFromName(const AName: string; out ANote: Byte): Boolean;
var
  s, pref: string;
  i, oct: Integer;
begin
  ANote := TRK_NOTE_NONE;
  s := Trim(AName);
  if (s = '') or (s = '...') then Exit(True);
  if s = '===' then begin ANote := TRK_NOTE_OFF; Exit(True); end;
  if s = '^^^' then begin ANote := TRK_NOTE_CUT; Exit(True); end;
  if Length(s) < 3 then Exit(False);
  pref := UpperCase(Copy(s, 1, 2));
  for i := 0 to 11 do
    if UpperCase(SEMI[i]) = pref then
    begin
      if not TryStrToInt(Copy(s, 3, MaxInt), oct) then Exit(False);
      if (oct < 0) or (oct > 9) then Exit(False);
      ANote := Byte(oct * 12 + i + 1);
      Exit(True);
    end;
  Result := False;
end;

function NoteToHz(ANote: Double): Double;
begin
  Result := A4_HZ * Power(2.0, (ANote - A4_NOTE_VALUE) / 12.0);
end;

end.
