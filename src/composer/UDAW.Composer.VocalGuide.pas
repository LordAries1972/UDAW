unit UDAW.Composer.VocalGuide;
{$I udaw.inc}

{ AI Composition, Phase 5 - Lyrics and Vocals (docs/AIPlan.md section 17
  "PHASE 5 - LYRICS AND VOCALS": "Generate vocal guide notes", and section 7
  step 7 "Generate a guide vocal melody or MIDI reference").

  GenerateVocalGuide turns one song section's TLyricLine set into real MIDI
  notes: one note per syllable (UDAW.Composer.Lyrics.ComputeSyllableTimings
  already did the phrase/timing analysis), pitched from the section's chord
  progression when one exists (UDAW.Composer.Arrangement.ParseChordSymbol)
  or the song's key/scale otherwise (ScaleKindFromName + UDAW.MIDI.PianoRoll
  ScaleIntervals), with a small deterministic stepwise contour so the guide
  reads as a line rather than a monotone chant. AIPlan.md section 7 step 8
  ("Allow recorded vocals to replace the guide") and step 9 ("Preserve the
  lyrics for display and export") are why this never mutates TLyricDocument
  itself - it only reads it and writes MIDI notes via TPianoRoll, exactly
  like TApplyArrangementCommand.GenerateMidiForTrack does for every other
  role.

  This is explicitly the "AI-generated singing... optional provider
  feature" line from AIPlan.md section 7: a guide melody the user can sing
  or play against, not audio synthesis. }

interface

uses
  SysUtils, Math,
  UDAW.MIDI.Sequence, UDAW.MIDI.PianoRoll,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics;

{ Generates guide-vocal notes for every lyric line in ALyrics' TLyricSection
  matching ASectionId, into APianoRoll (already bound to the target MIDI
  track). ANoteRangeLow/High bound the generated pitches (octave-shifted
  into range, never dropped) - pass a resolved instrument's/voice's range
  when known, or leave the defaults for a generic guide. Returns the number
  of notes generated (0 for an instrumental section, i.e. one with no
  matching TLyricSection - AIPlan.md section 7: "When Instrumental is
  enabled: ... Replace vocal sections with melodic or instrumental
  development", which is the caller's job, not this function's). }
function GenerateVocalGuide(ASpec: TSongSpec; ALyrics: TLyricDocument;
  const ASectionId: string; APianoRoll: TPianoRoll; APPQ: Integer;
  AChannel: Integer = 0; ANoteRangeLow: Integer = 57; ANoteRangeHigh: Integer = 74;
  ASeed: Cardinal = 1): Integer;

implementation

uses
  UDAW.Composer.Arrangement; // ParseChordSymbol / RootPitchClass / ScaleKindFromName

function XorShift32(var AState: Cardinal): Double;
begin
  AState := AState xor (AState shl 13);
  AState := AState xor (AState shr 17);
  AState := AState xor (AState shl 5);
  if AState = 0 then AState := $A17C0DE1;
  Result := AState / 4294967296.0;
end;

function ClampToRange(ANote, ALow, AHigh: Integer): Integer;
begin
  Result := ANote;
  if ALow > AHigh then Exit;
  while Result < ALow do Inc(Result, 12);
  while Result > AHigh do Dec(Result, 12);
  if Result < ALow then Result := ALow;   // range narrower than an octave
  if Result > AHigh then Result := AHigh;
end;

function GenerateVocalGuide(ASpec: TSongSpec; ALyrics: TLyricDocument;
  const ASectionId: string; APianoRoll: TPianoRoll; APPQ: Integer;
  AChannel: Integer; ANoteRangeLow, ANoteRangeHigh: Integer; ASeed: Cardinal): Integer;
var
  lsec: TLyricSection;
  sec: TSongSection;
  prog: TChordProgressionEntry;
  pool: TArray<Integer>;
  poolLow, poolHigh: Integer;
  rootPC, dummyConsumed: Integer;
  offsets: TArray<Integer>;
  scaleInts: TArray<Integer>;
  scaleKind: TScaleKind;
  ticksPerBar: Int64;
  li, si, i, register_: Integer;
  starts, durations: TArray<Double>;
  prevNote: Integer;
  rnd: Cardinal;
  vel: Integer;
  gate: Double;
  startTick, lenTick: Int64;
  chordIdx: Integer;
  line: TLyricLine;

  { pitch pool for one syllable: chord tones (if a progression covers this
    bar) transposed across a couple of octaves, else the full scale. }
  procedure BuildPool(ABar: Integer);
  var
    o, j: Integer;
  begin
    SetLength(pool, 0);
    if (prog <> nil) and (Length(prog.Chords) > 0) and (prog.BarsPerChord > 0) then
    begin
      chordIdx := ((ABar - sec.StartBar) div prog.BarsPerChord) mod Length(prog.Chords);
      if chordIdx < 0 then chordIdx := 0;
      offsets := ParseChordSymbol(prog.Chords[chordIdx], rootPC);
      for o := -1 to 2 do
        for j := 0 to High(offsets) do
          pool := pool + [60 + rootPC + offsets[j] + o * 12];
    end
    else
    begin
      for o := -1 to 2 do
        for j := 0 to High(scaleInts) do
          pool := pool + [60 + rootPC + scaleInts[j] + o * 12];
    end;
  end;

  function NearestInPool(ATarget: Integer): Integer;
  var
    j, best, bestDist, d: Integer;
  begin
    if Length(pool) = 0 then Exit(ATarget);
    best := pool[0];
    bestDist := Abs(pool[0] - ATarget);
    for j := 1 to High(pool) do
    begin
      d := Abs(pool[j] - ATarget);
      if d < bestDist then
      begin
        bestDist := d;
        best := pool[j];
      end;
    end;
    Result := best;
  end;

begin
  Result := 0;
  if (ASpec = nil) or (ALyrics = nil) or (APianoRoll = nil) then Exit;
  sec := ASpec.SectionById(ASectionId);
  if sec = nil then Exit;
  lsec := ALyrics.SectionById(ASectionId);
  if lsec = nil then Exit; // instrumental section: nothing to guide

  rootPC := RootPitchClass(ASpec.Meta.Key, dummyConsumed);
  if rootPC < 0 then rootPC := 0;
  scaleKind := ScaleKindFromName(ASpec.Meta.Scale);
  scaleInts := ScaleIntervals(scaleKind);

  prog := nil;
  for si := 0 to ASpec.Harmony.Count - 1 do
    if SameText(ASpec.Harmony[si].SectionId, ASectionId) then
    begin
      prog := ASpec.Harmony[si];
      Break;
    end;

  poolLow := ANoteRangeLow;
  poolHigh := ANoteRangeHigh;
  if poolLow > poolHigh then poolLow := poolHigh;
  register_ := (poolLow + poolHigh) div 2;

  ticksPerBar := Max(Int64(1), (Int64(APPQ) * 4 * ASpec.Meta.TimeSigNum) div Max(1, ASpec.Meta.TimeSigDen));
  rnd := ASeed;
  if rnd = 0 then rnd := 1;
  prevNote := register_;

  for li := 0 to lsec.Lines.Count - 1 do
  begin
    line := lsec.Lines[li];
    line.ComputeSyllableTimings(starts, durations);
    for i := 0 to High(starts) do
    begin
      BuildPool(Trunc(starts[i]));
      { small deterministic stepwise contour around the previous pitch }
      prevNote := NearestInPool(prevNote + Round((XorShift32(rnd) * 2.0 - 1.0) * 4));
      prevNote := ClampToRange(prevNote, poolLow, poolHigh);

      startTick := Round((starts[i] - 1) * ticksPerBar);
      lenTick := Max(Int64(1), Round(durations[i] * ticksPerBar));
      gate := 0.7 + XorShift32(rnd) * 0.25; // 0.70..0.95: legato-ish, not machine-locked
      vel := Max(1, Min(127, Round(70 + sec.Energy * 40 + (XorShift32(rnd) * 2.0 - 1.0) * 8)));

      APianoRoll.AddNote(startTick, Max(Int64(1), Round(lenTick * gate)), prevNote, vel, AChannel);
      Inc(Result);
    end;
  end;
end;

end.
