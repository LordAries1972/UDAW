unit UDAW.Composer.Arrangement;
{$I udaw.inc}

{ AI Composition, Phase 4 - Basic Arrangement Generation (docs/AIPlan.md
  section 17 "PHASE 4 - BASIC ARRANGEMENT GENERATION", and section E
  "ArrangementEngine"). This is the piece docs/Phase32-33-AIComposerDataModel.md
  flagged as still missing: "no arrangement engine turns a spec into real
  timeline/MIDI/mixer content yet."

  TArrangementEngine turns a validated TSongSpec (UDAW.Composer.SongSpec,
  Phase 1) into real project content, one subsystem at a time, exactly in
  AIPlan.md section 8's order (tempo/time-signature -> section markers ->
  buses -> tracks -> instrument resolution -> MIDI generation):

    * tempo and section markers  - TProjectDocument.TempoBPM/TimeSigNum/Den
      and TTimeline.AddMarker (one marker per TSongSection);
    * tracks and buses           - a TTimelineTrack + a linked TMixStrip per
      stkMidi/stkAudio TSongTrackSpec, a bus-only TMixStrip per stkBus one;
    * instrument resolution      - a suitability score (AIPlan.md section 6:
      exact id > category > role > tag match) against the Phase 2
      TInstrumentCatalogue; an unresolved track is reported, never dropped
      (section 6: "never silently remove the track");
    * simple chords/bass/drums   - TPianoRoll-driven MIDI generation for any
      track whose Role names a harmony/bass/drum part, built from
      TChordProgressionEntry + a small chord-symbol parser; other roles
      (melody, vocals, fx, ...) get an empty, ready-to-edit MIDI clip/track,
      since real melody/performance generation is AIPlan.md's later PHASE 6;
    * editable timeline, preview and Undo - every mutation happens inside
      ONE TApplyArrangementCommand (a plain TDAWCommand, UDAW.Project.Commands)
      that snapshots Timeline/Mixer/Midi/SongSpec/Lyrics/tempo before it
      touches anything and restores them on Undo, so "Apply" (or a rejected
      "Preview") is always a single undo step - AIPlan.md section 12: "Keep
      a complete Undo transaction." }

interface

uses
  SysUtils, Classes, StrUtils, Math, Generics.Collections,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Timeline.Model, UDAW.Timeline.Time,
  UDAW.Mixer.Model, UDAW.Mixer.Automation,
  UDAW.MIDI.Serialization, UDAW.MIDI.Sequence, UDAW.MIDI.Types, UDAW.MIDI.PianoRoll,
  UDAW.Browser.Catalogue, UDAW.Codec.WAV,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics, UDAW.Composer.Validation;

const
  ARRANGEMENT_SUBSYS = 'Composer.Arrangement';

type
  { One track's instrument-resolution outcome (AIPlan.md section 6). ItemId
    is '' when nothing matched - the track is still created, just unresolved. }
  TResolvedInstrument = record
    TrackId: string;
    TrackName: string;
    ItemId: string;
    ItemName: string;
    Score: Integer;
    Suggestions: TArray<string>; // catalogue item ids, best-effort alternatives
  end;

  TArrangementResult = record
    Warnings: TArray<string>;
    Resolutions: TArray<TResolvedInstrument>;
    function UnresolvedCount: Integer;
  end;

  { The single undo step for "apply this song specification to the project"
    (see the unit header). Owns ASpec/ALyrics after construction, exactly
    like TSetSongSpecCommand. }
  TApplyArrangementCommand = class(TDAWCommand)
  private
    FDoc: TProjectDocument;
    FCatalogue: TInstrumentCatalogue; // borrowed, not owned
    FSpec: TSongSpec;
    FLyrics: TLyricDocument;
    FResult: TArrangementResult;

    FBeforeTimeline: TTimeline;
    FBeforeMixer: TMixerModel;
    FBeforeMidi: TMidiProject;
    FBeforeSpec: TSongSpec;
    FBeforeLyrics: TLyricDocument;
    FBeforeTempo: Double;
    FBeforeTSigNum, FBeforeTSigDen: Integer;

    FAfterTimeline: TTimeline;
    FAfterMixer: TMixerModel;
    FAfterMidi: TMidiProject;
    FAfterSpec: TSongSpec;
    FAfterLyrics: TLyricDocument;
    FAfterTempo: Double;
    FAfterTSigNum, FAfterTSigDen: Integer;
    FHaveAfter: Boolean;

    function MapTrackKind(AKind: TSongTrackKind): TTrackKind;
    function MapMixKind(AKind: TSongTrackKind): TMixStripKind;
    function ResolveFiltered(ATrack: TSongTrackSpec;
      const AKindFilter: TArray<TCatalogueItemKind>): TResolvedInstrument;
    function ResolveInstrument(ATrack: TSongTrackSpec): TResolvedInstrument;
    { AIPlan.md section 9/10: samples and loops are tried before MIDI - see
      TSongTrackSpec.RequireMidi. Only matches ikSample/ikLoop catalogue
      items. }
    function ResolveSampleOrLoop(ATrack: TSongTrackSpec): TResolvedInstrument;
    procedure GenerateMidiForTrack(ASeq: TMidiSequence; ATrackSeqIndex: Integer;
      ATrackSpec: TSongTrackSpec; const AResolvedItemId: string);
    { Places the resolved sample/loop as one or more timeline clips covering
      every section (tiling a short loop to fill each section, truncating
      the last tile to the section's exact length; a one-shot "sample" item
      is placed once per section at its natural length instead). Returns
      False (and adds a warning) if the file can't be read as audio. }
    function PlaceSampleClips(ATrackId: Integer; AItem: TCatalogueItem;
      AWarnings: TStrings): Boolean;
    procedure ApplyEnergyAutomation(AStripId: Integer);
    procedure ApplySidechaining(const AStripIdByTrackId: TDictionary<string, Integer>);
    procedure CaptureBefore;
    procedure CaptureAfter;
    procedure RestoreFrom(ATimeline: TTimeline; AMixer: TMixerModel; AMidi: TMidiProject;
      ASpec: TSongSpec; ALyrics: TLyricDocument; ATempo: Double; ATSigNum, ATSigDen: Integer);
  public
    { Adopts ASpec/ALyrics: the caller must not free them after construction. }
    constructor Create(ADoc: TProjectDocument; ACatalogue: TInstrumentCatalogue;
      ASpec: TSongSpec; ALyrics: TLyricDocument);
    destructor Destroy; override;
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;
    property Result: TArrangementResult read FResult;
  end;

  TArrangementEngine = class
  private
    FDoc: TProjectDocument;
    FCatalogue: TInstrumentCatalogue;
  public
    constructor Create(ADoc: TProjectDocument; ACatalogue: TInstrumentCatalogue);

    { Validates ASpec (UDAW.Composer.Validation); a vsError issue rejects the
      whole apply (AIPlan.md section 1's core rule: never let unvalidated
      content reach the timeline) and this returns False without touching
      the project. On success, builds and performs ONE
      TApplyArrangementCommand through ACommands and returns True; AResult
      carries instrument-resolution/warning detail either way. Adopts
      ASpec/ALyrics only on success (matching TCommandManager.Perform's
      "always consumed" contract); on rejection the caller still owns them. }
    function Apply(ACommands: TCommandManager; ASpec: TSongSpec; ALyrics: TLyricDocument;
      out AResult: TArrangementResult): Boolean;
  end;

{ Best-effort chord-symbol -> pitch-class-offsets-from-root parser (AIPlan.md
  section 9's "chord progression" input); exposed so tests / other callers
  can use it directly. }
function ParseChordSymbol(const AChord: string; out ARootPC: Integer): TArray<Integer>;
function ScaleKindFromName(const AScale: string): TScaleKind;
{ Root pitch class (0=C..11=B) of a bare key name such as 'D' or 'Bb';
  -1 if AChord does not start with a note letter. Exposed for callers (e.g.
  the vocal-guide generator) that need the song's key, not a chord symbol. }
function RootPitchClass(const AChord: string; out AConsumed: Integer): Integer;

implementation

uses
  UDAW.Composer.VocalGuide;

const
  DRUM_KICK = 36;
  DRUM_SNARE = 38;
  DRUM_HAT_CLOSED = 42;

{ TArrangementResult }

function TArrangementResult.UnresolvedCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Resolutions) do
    if Resolutions[i].ItemId = '' then Inc(Result);
end;

{ ---------------- chord-symbol / scale parsing (pure helpers) ---------------- }

function RootPitchClass(const AChord: string; out AConsumed: Integer): Integer;
const
  LETTERS: array['A'..'G'] of Integer = (9, 11, 0, 2, 4, 5, 7);
var
  letter: Char;
  pc: Integer;
begin
  Result := -1;
  AConsumed := 0;
  if Length(AChord) = 0 then Exit;
  letter := UpCase(AChord[1]);
  if not CharInSet(letter, ['A'..'G']) then Exit;
  pc := LETTERS[letter];
  AConsumed := 1;
  if Length(AChord) >= 2 then
  begin
    if AChord[2] = '#' then
    begin
      pc := (pc + 1) mod 12;
      AConsumed := 2;
    end
    else if AChord[2] = 'b' then
    begin
      pc := (pc + 11) mod 12;
      AConsumed := 2;
    end;
  end;
  Result := pc;
end;

function ParseChordSymbol(const AChord: string; out ARootPC: Integer): TArray<Integer>;
var
  consumed: Integer;
  quality: string;
  trimmed: string;
begin
  trimmed := Trim(AChord);
  ARootPC := RootPitchClass(trimmed, consumed);
  if ARootPC < 0 then
  begin
    ARootPC := 0; // default to C rather than silently dropping the chord
    Result := [0, 4, 7];
    Exit;
  end;
  quality := LowerCase(Copy(trimmed, consumed + 1, MaxInt));
  if quality = '' then Result := [0, 4, 7]
  else if (quality = 'maj7') or (quality = 'major7') then Result := [0, 4, 7, 11]
  else if (quality = 'm7') or (quality = 'min7') then Result := [0, 3, 7, 10]
  else if (quality = '7') or (quality = 'dom7') then Result := [0, 4, 7, 10]
  else if (quality = 'dim7') then Result := [0, 3, 6, 9]
  else if (quality = 'dim') or (quality = 'o') then Result := [0, 3, 6]
  else if (quality = 'aug') or (quality = '+') then Result := [0, 4, 8]
  else if (quality = 'sus2') then Result := [0, 2, 7]
  else if (quality = 'sus4') then Result := [0, 5, 7]
  else if (quality = 'm') or (quality = 'min') then Result := [0, 3, 7]
  else if (quality = 'maj') then Result := [0, 4, 7]
  else Result := [0, 4, 7]; // unrecognised suffix: fall back to a major triad
end;

function ScaleKindFromName(const AScale: string): TScaleKind;
var
  s: string;
begin
  s := LowerCase(Trim(AScale));
  if (s = 'minor') or (s = 'natural minor') or (s = 'aeolian') then Result := skNaturalMinor
  else if s = 'harmonic minor' then Result := skHarmonicMinor
  else if s = 'melodic minor' then Result := skMelodicMinor
  else if s = 'dorian' then Result := skDorian
  else if s = 'phrygian' then Result := skPhrygian
  else if s = 'lydian' then Result := skLydian
  else if s = 'mixolydian' then Result := skMixolydian
  else if s = 'locrian' then Result := skLocrian
  else if s = 'major pentatonic' then Result := skMajorPentatonic
  else if s = 'minor pentatonic' then Result := skMinorPentatonic
  else if s = 'blues' then Result := skBlues
  else if s = 'whole tone' then Result := skWholeTone
  else if s = 'chromatic' then Result := skChromatic
  else Result := skMajor; // 'major' and anything unrecognised
end;

function TrackRoleClass(const ARole: string): Integer;
// 0=other 1=drums 2=bass 3=harmony 4=melody/lead 5=vocal
var
  r: string;
begin
  r := LowerCase(Trim(ARole));
  if (Pos('drum', r) > 0) or (Pos('perc', r) > 0) or (Pos('kick', r) > 0) then Exit(1);
  if Pos('bass', r) > 0 then Exit(2);
  if (Pos('vocal', r) > 0) or (Pos('vox', r) > 0) then Exit(5);
  if (Pos('melody', r) > 0) or (Pos('lead', r) > 0) or (Pos('hook', r) > 0) then Exit(4);
  if (Pos('chord', r) > 0) or (Pos('harmony', r) > 0) or (Pos('pad', r) > 0) or
     (Pos('keys', r) > 0) or (Pos('rhythm', r) > 0) or (Pos('guitar', r) > 0) then Exit(3);
  Result := 0;
end;

function HashStr(const S: string): Cardinal;
var
  i: Integer;
begin
  Result := 2166136261;
  for i := 1 to Length(S) do
  begin
    Result := Result xor Ord(S[i]);
    Result := Cardinal((UInt64(Result) * 16777619) and $FFFFFFFF);   // 32-bit wrap by design
  end;
end;

{ ================= TApplyArrangementCommand ================= }

constructor TApplyArrangementCommand.Create(ADoc: TProjectDocument;
  ACatalogue: TInstrumentCatalogue; ASpec: TSongSpec; ALyrics: TLyricDocument);
begin
  inherited Create;
  if ADoc = nil then
    RaiseUDAW(errInvalidArgument, ARRANGEMENT_SUBSYS, 'an arrangement command requires a project document');
  if ASpec = nil then
    RaiseUDAW(errInvalidArgument, ARRANGEMENT_SUBSYS, 'an arrangement command requires a song specification');
  FDoc := ADoc;
  FCatalogue := ACatalogue;
  FSpec := ASpec;
  FLyrics := ALyrics;
  if FLyrics = nil then
    FLyrics := TLyricDocument.Create;
end;

destructor TApplyArrangementCommand.Destroy;
begin
  FSpec.Free;
  FLyrics.Free;
  FBeforeTimeline.Free;
  FBeforeMixer.Free;
  FBeforeMidi.Free;
  FBeforeSpec.Free;
  FBeforeLyrics.Free;
  FAfterTimeline.Free;
  FAfterMixer.Free;
  FAfterMidi.Free;
  FAfterSpec.Free;
  FAfterLyrics.Free;
  inherited Destroy;
end;

procedure TApplyArrangementCommand.CaptureBefore;
begin
  FBeforeTimeline := FDoc.Timeline.Clone;
  FBeforeMixer := FDoc.Mixer.Clone;
  FBeforeMidi := FDoc.Midi.Clone;
  FBeforeSpec := FDoc.SongSpec.Clone;
  FBeforeLyrics := FDoc.Lyrics.Clone;
  FBeforeTempo := FDoc.TempoBPM;
  FBeforeTSigNum := FDoc.TimeSigNum;
  FBeforeTSigDen := FDoc.TimeSigDen;
end;

procedure TApplyArrangementCommand.CaptureAfter;
begin
  FAfterTimeline.Free; FAfterTimeline := FDoc.Timeline.Clone;
  FAfterMixer.Free; FAfterMixer := FDoc.Mixer.Clone;
  FAfterMidi.Free; FAfterMidi := FDoc.Midi.Clone;
  FAfterSpec.Free; FAfterSpec := FDoc.SongSpec.Clone;
  FAfterLyrics.Free; FAfterLyrics := FDoc.Lyrics.Clone;
  FAfterTempo := FDoc.TempoBPM;
  FAfterTSigNum := FDoc.TimeSigNum;
  FAfterTSigDen := FDoc.TimeSigDen;
  FHaveAfter := True;
end;

procedure TApplyArrangementCommand.RestoreFrom(ATimeline: TTimeline; AMixer: TMixerModel;
  AMidi: TMidiProject; ASpec: TSongSpec; ALyrics: TLyricDocument; ATempo: Double;
  ATSigNum, ATSigDen: Integer);
begin
  FDoc.ReplaceTimeline(ATimeline.Clone);
  FDoc.ReplaceMixer(AMixer.Clone);
  FDoc.ReplaceMidi(AMidi.Clone);
  FDoc.ReplaceSongSpec(ASpec.Clone);
  FDoc.ReplaceLyrics(ALyrics.Clone);
  FDoc.TempoBPM := ATempo;
  FDoc.TimeSigNum := ATSigNum;
  FDoc.TimeSigDen := ATSigDen;
  FDoc.Touch;
end;

function TApplyArrangementCommand.MapTrackKind(AKind: TSongTrackKind): TTrackKind;
begin
  case AKind of
    stkMidi:  Result := tkMidi;
    stkAudio: Result := tkAudio;
  else
    Result := tkBus;
  end;
end;

function TApplyArrangementCommand.MapMixKind(AKind: TSongTrackKind): TMixStripKind;
begin
  case AKind of
    stkBus: Result := skBus;
  else
    Result := skAudioTrack;
  end;
end;

function TApplyArrangementCommand.ResolveFiltered(ATrack: TSongTrackSpec;
  const AKindFilter: TArray<TCatalogueItemKind>): TResolvedInstrument;
var
  i, j, score, bestScore: Integer;
  item, best: TCatalogueItem;
  roleMatches: TArray<TCatalogueItem>;
  suggestions: TStringList;

  function KindAllowed(AKind: TCatalogueItemKind): Boolean;
  var
    k: Integer;
  begin
    if Length(AKindFilter) = 0 then Exit(True); // no filter - any kind matches
    for k := 0 to High(AKindFilter) do
      if AKindFilter[k] = AKind then Exit(True);
    Result := False;
  end;

begin
  Result.TrackId := ATrack.Id;
  Result.TrackName := ATrack.Name;
  Result.ItemId := '';
  Result.ItemName := '';
  Result.Score := 0;
  SetLength(Result.Suggestions, 0);

  if FCatalogue = nil then Exit;

  best := nil;
  bestScore := 0;

  if Trim(ATrack.PreferredInstrumentId) <> '' then
  begin
    item := FCatalogue.ItemById(ATrack.PreferredInstrumentId);
    if (item <> nil) and item.Available and KindAllowed(item.Kind) then
    begin
      best := item;
      bestScore := 1000; // AIPlan.md section 6, matching order step 1: exact instrument id
    end;
  end;

  if best = nil then
    for i := 0 to FCatalogue.ItemCount - 1 do
    begin
      item := FCatalogue.GetItem(i);
      if not item.Available then Continue;
      if not KindAllowed(item.Kind) then Continue;
      score := 0;
      if SameText(item.Category, ATrack.FallbackCategory) then Inc(score, 20);
      for j := 0 to High(item.Roles) do
        if SameText(item.Roles[j], ATrack.Role) then Inc(score, 15);
      if Length(item.Tags) > 0 then
        for j := 0 to High(ATrack.RequestedTags) do
          if MatchText(ATrack.RequestedTags[j], item.Tags) then Inc(score, 5);
      if score > bestScore then
      begin
        bestScore := score;
        best := item;
      end;
    end;

  if (best <> nil) and (bestScore > 0) then
  begin
    Result.ItemId := best.Id;
    Result.ItemName := best.Name;
    Result.Score := bestScore;
  end;

  { Suggestions for the "missing instrument" UI (AIPlan.md section 6:
    "Suggest the closest installed alternatives") - up to 3 role matches
    other than whatever was actually resolved. }
  suggestions := TStringList.Create;
  try
    suggestions.Duplicates := dupIgnore;
    suggestions.Sorted := False;
    roleMatches := FCatalogue.FindByRole(ATrack.Role);
    for i := 0 to High(roleMatches) do
    begin
      if not KindAllowed(roleMatches[i].Kind) then Continue;
      if (best <> nil) and (roleMatches[i].Id = best.Id) then Continue;
      if suggestions.Count >= 3 then Break;
      suggestions.Add(roleMatches[i].Id);
    end;
    Result.Suggestions := suggestions.ToStringArray;
  finally
    suggestions.Free;
  end;
end;

function TApplyArrangementCommand.ResolveInstrument(ATrack: TSongTrackSpec): TResolvedInstrument;
begin
  Result := ResolveFiltered(ATrack, []);
end;

function TApplyArrangementCommand.ResolveSampleOrLoop(ATrack: TSongTrackSpec): TResolvedInstrument;
begin
  Result := ResolveFiltered(ATrack, [ikSample, ikLoop]);
end;

procedure TApplyArrangementCommand.GenerateMidiForTrack(ASeq: TMidiSequence; ATrackSeqIndex: Integer;
  ATrackSpec: TSongTrackSpec; const AResolvedItemId: string);
var
  pr: TPianoRoll;
  roleClass: Integer;
  ticksPerBeat, ticksPerBar: Int64;
  sec, nextSec: TSongSection;
  prog, foundProg: TChordProgressionEntry;
  secIdx, hIdx, barIdx, beatIdx, chordIdx, dummyConsumed: Integer;
  rootPC: Integer;
  offsets: TArray<Integer>;
  scaleInts: TArray<Integer>;
  startTick: Int64;
  vel: Integer;
  channel: Integer;
  useEighths, isLastBar, isBuildup: Boolean;
  o: Integer;
  seed: Cardinal;
  noteLow, noteHigh: Integer;
  catItem: TCatalogueItem;
  prevMelodyNote: Integer;

  function Rnd01: Double;
  begin
    seed := seed xor (seed shl 13);
    seed := seed xor (seed shr 17);
    seed := seed xor (seed shl 5);
    if seed = 0 then seed := $2545F491;
    Result := seed / 4294967296.0;
  end;

  function ChordOrScaleOffsets(ABarIdx: Integer): TArray<Integer>;
  begin
    if (prog <> nil) and (Length(prog.Chords) > 0) and (prog.BarsPerChord > 0) then
    begin
      chordIdx := (ABarIdx div prog.BarsPerChord) mod Length(prog.Chords);
      Result := ParseChordSymbol(prog.Chords[chordIdx], rootPC);
    end
    else
    begin
      rootPC := RootPitchClass(FSpec.Meta.Key, dummyConsumed);
      if rootPC < 0 then rootPC := 0;
      if ScaleKindFromName(FSpec.Meta.Scale) in [skNaturalMinor, skHarmonicMinor, skMelodicMinor] then
        Result := [0, 3, 7]
      else
        Result := [0, 4, 7];
    end;
  end;

  function ClampToInstrumentRange(ANote: Integer): Integer;
  begin
    Result := ANote;
    if noteLow > noteHigh then Exit;
    while Result < noteLow do Inc(Result, 12);
    while Result > noteHigh do Dec(Result, 12);
    if Result < noteLow then Result := noteLow;
    if Result > noteHigh then Result := noteHigh;
  end;

  { picks whichever octave of ANote (a pitch class realised in some default
    octave) lies closest to AReference, so a melodic line steps smoothly
    instead of jumping octaves every note. }
  function NearestOctaveTo(ANote, AReference: Integer): Integer;
  begin
    Result := ANote;
    while Result - AReference > 6 do Dec(Result, 12);
    while AReference - Result > 6 do Inc(Result, 12);
  end;

begin
  roleClass := TrackRoleClass(ATrackSpec.Role);
  if roleClass = 0 then Exit; // fx/other: leave the clip empty for a later phase

  ticksPerBeat := Max(Int64(1), (Int64(ASeq.PPQ) * 4) div Max(1, FSpec.Meta.TimeSigDen));
  ticksPerBar := ticksPerBeat * Max(1, FSpec.Meta.TimeSigNum);

  channel := ATrackSpec.MidiChannel;
  if channel < 0 then
  begin
    if roleClass = 1 then channel := 9 else channel := 0; // GM percussion channel for drums
  end;

  { AIPlan.md section 17 PHASE 6 "Instrument-specific performance logic":
    clamp generated melodic content into the resolved instrument's declared
    range (defaulting to a generic 2.5-octave register when unresolved). }
  noteLow := 48; noteHigh := 84;
  if (FCatalogue <> nil) and (Trim(AResolvedItemId) <> '') then
  begin
    catItem := FCatalogue.ItemById(AResolvedItemId);
    if catItem <> nil then
    begin
      noteLow := catItem.NoteRangeLow;
      noteHigh := catItem.NoteRangeHigh;
    end;
  end;

  { AIPlan.md section 17 PHASE 6 "Section variations": deterministic per
    track+seed so the same spec always regenerates identically (section 9:
    "Saving the random seed allows the exact performance to be
    regenerated"), but differs bar-to-bar and between tracks/sections. }
  seed := Cardinal(FSpec.GenerationSeed) xor HashStr(ATrackSpec.Id);
  if seed = 0 then seed := 1;
  prevMelodyNote := (noteLow + noteHigh) div 2;

  pr := TPianoRoll.Create(ASeq, ATrackSeqIndex);
  try
    if roleClass = 5 then
    begin
      { vocal: the guide-vocal generator reads TLyricDocument directly and
        no-ops for an instrumental section (AIPlan.md section 7: "When
        Instrumental is enabled ... Do not create lyric or vocal tracks" -
        enforced by TSongSpecValidator upstream; here it is simply "no
        matching lyric section"). }
      for secIdx := 0 to FSpec.Sections.Count - 1 do
        GenerateVocalGuide(FSpec, FLyrics, FSpec.Sections[secIdx].Id, pr, ASeq.PPQ,
          channel, noteLow, noteHigh, seed + Cardinal(secIdx) + 1);
      Exit;
    end;

    for secIdx := 0 to FSpec.Sections.Count - 1 do
    begin
      sec := FSpec.Sections[secIdx];
      vel := Max(1, Min(127, Round(40 + sec.Energy * 80)));
      useEighths := sec.Energy > 0.5;
      if secIdx < FSpec.Sections.Count - 1 then nextSec := FSpec.Sections[secIdx + 1] else nextSec := nil;

      if roleClass = 1 then
      begin
        { simple drum pattern: kick on beat 1 (and 3 in a >=4-beat bar for
          higher energy), snare on the off-beats, closed hat on every beat
          (plus the 8th-note in between once energy warrants it); PHASE 6
          "Drum fills"/"Transitions": the section's last bar gets a
          building 16th-note fill instead of the steady pattern whenever
          the next section raises the energy. }
        for barIdx := 0 to sec.LengthBars - 1 do
        begin
          startTick := ticksPerBar * (sec.StartBar - 1 + barIdx);
          isLastBar := barIdx = sec.LengthBars - 1;
          isBuildup := isLastBar and (nextSec <> nil) and (nextSec.Energy > sec.Energy + 0.05);

          if isBuildup then
          begin
            { a 16th-note snare/tom roll across the whole bar, velocity
              ramping up into the next section. }
            for beatIdx := 0 to (FSpec.Meta.TimeSigNum * 4) - 1 do
              pr.AddNote(startTick + beatIdx * (ticksPerBeat div 4), Max(Int64(1), ticksPerBeat div 4),
                DRUM_SNARE, Max(1, Min(127, vel - 30 + Round(beatIdx * (60.0 / (FSpec.Meta.TimeSigNum * 4))))),
                channel);
            Continue;
          end;

          for beatIdx := 0 to FSpec.Meta.TimeSigNum - 1 do
          begin
            if (beatIdx = 0) or ((sec.Energy > 0.5) and (FSpec.Meta.TimeSigNum >= 4) and (beatIdx = 2)) then
              pr.AddNote(startTick + beatIdx * ticksPerBeat, ticksPerBeat div 2, DRUM_KICK, vel, channel);
            if Odd(beatIdx) then
              pr.AddNote(startTick + beatIdx * ticksPerBeat, ticksPerBeat div 2, DRUM_SNARE, vel, channel);
            pr.AddNote(startTick + beatIdx * ticksPerBeat, ticksPerBeat div 2, DRUM_HAT_CLOSED,
              Max(1, vel - 20), channel);
            if useEighths then
              pr.AddNote(startTick + beatIdx * ticksPerBeat + ticksPerBeat div 2, ticksPerBeat div 2,
                DRUM_HAT_CLOSED, Max(1, vel - 30), channel);
            { section-variation embellishment: an occasional deterministic
              extra hat/ghost-snare so repeated sections do not sound
              machine-identical. }
            if (roleClass = 1) and (Rnd01 < 0.12 * sec.Energy) then
              pr.AddNote(startTick + beatIdx * ticksPerBeat + ticksPerBeat div 2, ticksPerBeat div 4,
                DRUM_SNARE, Max(1, vel - 45), channel);
          end;
        end;
        Continue;
      end;

      { harmony/bass roles: walk the section's declared chord progression
        (falling back to a static I-chord on the song's key if the section
        has none) one bar at a time. }
      foundProg := nil;
      for hIdx := 0 to FSpec.Harmony.Count - 1 do
        if SameText(FSpec.Harmony[hIdx].SectionId, sec.Id) then
        begin
          foundProg := FSpec.Harmony[hIdx];
          Break;
        end;
      prog := foundProg;
      scaleInts := ScaleIntervals(ScaleKindFromName(FSpec.Meta.Scale));

      for barIdx := 0 to sec.LengthBars - 1 do
      begin
        startTick := ticksPerBar * (sec.StartBar - 1 + barIdx);
        offsets := ChordOrScaleOffsets(barIdx);

        case roleClass of
          2: { bass: root note, low octave, with a deterministic octave/passing-tone
               variation on repeat bars (PHASE 6 "Section variations"). }
            begin
              if Rnd01 < 0.15 then
                pr.AddNote(startTick, ticksPerBar div 2, ClampToInstrumentRange(36 + rootPC), vel, channel)
              else
                pr.AddNote(startTick, ticksPerBar, ClampToInstrumentRange(36 + rootPC), vel, channel);
            end;
          3: { harmony/chords: block chord sustained for the bar, occasionally
               arpeggiated for higher-energy sections (an "articulation"). }
            begin
              if useEighths and (Rnd01 < 0.3) then
                for o := 0 to High(offsets) do
                  pr.AddNote(startTick + o * (ticksPerBar div Max(1, Length(offsets))),
                    ticksPerBar div Max(1, Length(offsets)),
                    ClampToInstrumentRange(60 + rootPC + offsets[o]), vel, channel)
              else
                for o := 0 to High(offsets) do
                  pr.AddNote(startTick, ticksPerBar, ClampToInstrumentRange(60 + rootPC + offsets[o]), vel, channel);
            end;
          4: { melody/lead (PHASE 6 "Melody generation"): a stepwise line
               walking chord tones + scale passing tones, one note per beat
               (or per 8th at higher energy), with an "articulation" gate
               (legato vs. detached) that varies with energy. }
            begin
              for beatIdx := 0 to (FSpec.Meta.TimeSigNum * (1 + Ord(useEighths))) - 1 do
              begin
                if (Length(offsets) > 0) and (Rnd01 < 0.6) then
                  prevMelodyNote := NearestOctaveTo(60 + rootPC + offsets[Round(Rnd01 * (Length(offsets) - 1))],
                    prevMelodyNote)
                else if Length(scaleInts) > 0 then
                  prevMelodyNote := NearestOctaveTo(60 + rootPC + scaleInts[Round(Rnd01 * (Length(scaleInts) - 1))],
                    prevMelodyNote);
                prevMelodyNote := ClampToInstrumentRange(prevMelodyNote);
                pr.AddNote(startTick + beatIdx * (ticksPerBeat div (1 + Ord(useEighths))),
                  Max(Int64(1), Round((ticksPerBeat div (1 + Ord(useEighths))) * (0.55 + Rnd01 * 0.4))),
                  prevMelodyNote, Max(1, Min(127, vel + Round((Rnd01 * 2 - 1) * 10))), channel);
              end;
            end;
        end;
      end;
    end;
  finally
    pr.Free;
  end;
end;

function TApplyArrangementCommand.PlaceSampleClips(ATrackId: Integer; AItem: TCatalogueItem;
  AWarnings: TStrings): Boolean;
var
  info: TWavInfo;
  src: TMediaSource;
  sampleLenSec, secStartSec, secLenSec, pos, tileLen: Double;
  isLoop: Boolean;
  secIdx: Integer;
  sec: TSongSection;
  gridCtx: TGridContext;
begin
  Result := False;
  try
    info := ReadWavInfo(AItem.Path);
  except
    on E: Exception do
    begin
      AWarnings.Add(Format('sample/loop "%s" (%s): could not read the audio file (%s)',
        [AItem.Name, AItem.Path, E.Message]));
      Exit;
    end;
  end;
  if (info.SampleRate <= 0) or (info.Channels <= 0) or (info.FrameCount <= 0) then
  begin
    AWarnings.Add(Format('sample/loop "%s": audio file reports no playable frames', [AItem.Name]));
    Exit;
  end;

  src := FDoc.Timeline.AddSource(AItem.Path, info.SampleRate, info.Channels, info.FrameCount);
  sampleLenSec := info.FrameCount / info.SampleRate;
  { a "loop" item tiles to fill each section (truncating the last tile to
    the section's exact length); a one-shot "sample" plays once per section
    at its own natural length, never stretched. }
  isLoop := AItem.Kind = ikLoop;
  gridCtx := FDoc.GridContext;

  for secIdx := 0 to FSpec.Sections.Count - 1 do
  begin
    sec := FSpec.Sections[secIdx];
    secStartSec := BarsToSeconds(gridCtx, sec.StartBar - 1);
    secLenSec := BarsToSeconds(gridCtx, sec.EndBarExclusive - 1) - secStartSec;
    if secLenSec < TIMELINE_MIN_CLIP_SECONDS then Continue;

    if isLoop then
    begin
      pos := 0;
      while pos < secLenSec do
      begin
        tileLen := Min(sampleLenSec, secLenSec - pos);
        if tileLen < TIMELINE_MIN_CLIP_SECONDS then Break;
        FDoc.Timeline.AddClip(ATrackId, src.Id, AItem.Name, secStartSec + pos, 0, tileLen);
        pos := pos + sampleLenSec;
      end;
    end
    else
      FDoc.Timeline.AddClip(ATrackId, src.Id, AItem.Name, secStartSec, 0, Min(sampleLenSec, secLenSec));
  end;
  Result := True;
end;

procedure TApplyArrangementCommand.ApplyEnergyAutomation(AStripId: Integer);
var
  i: Integer;
  sec: TSongSection;
  gridCtx: TGridContext;
  lane: TAutomationLane;
  db: Double;
begin
  gridCtx := FDoc.GridContext;
  lane := FDoc.Mixer.Automation.LaneFor(AStripId, apFader, True);
  for i := 0 to FSpec.Sections.Count - 1 do
  begin
    sec := FSpec.Sections[i];
    db := -6.0 + Max(0.0, Min(1.0, sec.Energy)) * 6.0; // -6dB (quiet) .. 0dB (full energy)
    lane.AddPoint(BarsToSeconds(gridCtx, sec.StartBar - 1), db);
  end;
end;

procedure TApplyArrangementCommand.ApplySidechaining(const AStripIdByTrackId: TDictionary<string, Integer>);
var
  i: Integer;
  trkSpec: TSongTrackSpec;
  bassStripId, drumStripId: Integer;
  bassStrip: TMixStrip;
begin
  bassStripId := 0;
  drumStripId := 0;
  for i := 0 to FSpec.Tracks.Count - 1 do
  begin
    trkSpec := FSpec.Tracks[i];
    if not AStripIdByTrackId.ContainsKey(trkSpec.Id) then Continue;
    case TrackRoleClass(trkSpec.Role) of
      1: if drumStripId = 0 then drumStripId := AStripIdByTrackId[trkSpec.Id];
      2: if bassStripId = 0 then bassStripId := AStripIdByTrackId[trkSpec.Id];
    end;
  end;
  if (bassStripId = 0) or (drumStripId = 0) then Exit;

  bassStrip := FDoc.Mixer.StripById(bassStripId);
  if bassStrip = nil then Exit;
  bassStrip.AddInsert(TMixInsert.Make('compressor',
    'type=compressor;thresh=-24;ratio=6;attack=1;release=120', False, drumStripId));
end;

function TApplyArrangementCommand.Execute: Boolean;
var
  issues: TValidationIssues;
  i: Integer;
  sec: TSongSection;
  gridCtx: TGridContext;
  trkSpec: TSongTrackSpec;
  tlTrack: TTimelineTrack;
  strip: TMixStrip;
  midiSeq: TMidiSequence;
  trackSeqIdx: Integer;
  resolution: TResolvedInstrument;
  sampleResolution: TResolvedInstrument;
  sampleItem: TCatalogueItem;
  effectiveKind: TSongTrackKind;
  resolutions: TList<TResolvedInstrument>;
  warnings: TStringList;
  stripIdByTrackId: TDictionary<string, Integer>;
begin
  TSongSpecValidator.ApplyDefaults(FSpec);
  issues := TSongSpecValidator.Validate(FSpec, FLyrics);
  if TSongSpecValidator.HasErrors(issues) then
  begin
    warnings := TStringList.Create;
    try
      for i := 0 to High(issues) do
        if issues[i].Severity = vsError then
          warnings.Add(issues[i].Message);
      RaiseUDAWFmt(errInvalidState, ARRANGEMENT_SUBSYS,
        'song specification rejected: %s', [warnings.Text]);
    finally
      warnings.Free;
    end;
  end;

  CaptureBefore;

  resolutions := TList<TResolvedInstrument>.Create;
  warnings := TStringList.Create;
  stripIdByTrackId := TDictionary<string, Integer>.Create;
  try
    for i := 0 to High(issues) do
      if issues[i].Severity = vsWarning then
        warnings.Add(issues[i].Message);

    FDoc.TempoBPM := FSpec.Meta.Tempo;
    FDoc.TimeSigNum := FSpec.Meta.TimeSigNum;
    FDoc.TimeSigDen := FSpec.Meta.TimeSigDen;
    gridCtx := FDoc.GridContext;

    for i := 0 to FSpec.Sections.Count - 1 do
    begin
      sec := FSpec.Sections[i];
      FDoc.Timeline.AddMarker(sec.Name, BarsToSeconds(gridCtx, sec.StartBar - 1));
    end;

    FDoc.Mixer.EnsureMaster;

    for i := 0 to FSpec.Tracks.Count - 1 do
    begin
      trkSpec := FSpec.Tracks[i];

      if trkSpec.Kind = stkBus then
      begin
        FDoc.Mixer.AddStrip(skBus, trkSpec.Name);
        Continue;
      end;

      { AIPlan.md section 9/10: a real sample/loop is tried before generated
        MIDI, for every stkAudio track and for any stkMidi track the AI/user
        did not explicitly pin to real performance data
        (TSongTrackSpec.RequireMidi) - enforced here regardless of what
        "type" the AI actually chose, the same way this command already
        enforces Locked/scope/instrumental rules regardless of AI
        cooperation. An stkAudio track with no catalogue match never falls
        back to MIDI - it is just left unresolved, per section 6's "never
        silently remove the track". }
      sampleResolution.ItemId := '';
      if (trkSpec.Kind = stkAudio) or (not trkSpec.RequireMidi) then
        sampleResolution := ResolveSampleOrLoop(trkSpec);

      if sampleResolution.ItemId <> '' then
      begin
        resolution := sampleResolution;
        effectiveKind := stkAudio;
      end
      else if trkSpec.Kind = stkAudio then
      begin
        resolution := sampleResolution; // stays unresolved
        effectiveKind := stkAudio;
      end
      else
      begin
        resolution := ResolveInstrument(trkSpec);
        effectiveKind := stkMidi;
      end;
      resolutions.Add(resolution);
      if resolution.ItemId = '' then
        warnings.Add(Format('track "%s": no matching %s found in the catalogue - marked unresolved',
          [trkSpec.Name, IfThen(effectiveKind = stkAudio, 'sample/loop', 'instrument')]));

      tlTrack := FDoc.Timeline.AddTrack(MapTrackKind(effectiveKind), trkSpec.Name);
      strip := FDoc.Mixer.AddStrip(MapMixKind(effectiveKind), trkSpec.Name);
      strip.InputSourceId := tlTrack.Id;
      stripIdByTrackId.AddOrSetValue(trkSpec.Id, strip.Id);

      if (effectiveKind = stkAudio) and (sampleResolution.ItemId <> '') then
      begin
        sampleItem := FCatalogue.ItemById(sampleResolution.ItemId);
        if (sampleItem = nil) or not PlaceSampleClips(tlTrack.Id, sampleItem, warnings) then
          warnings.Add(Format('track "%s": sample/loop could not be placed - track left empty',
            [trkSpec.Name]));
      end
      else if effectiveKind = stkMidi then
      begin
        midiSeq := FDoc.Midi.NewClip(trkSpec.Name);
        midiSeq.SetTempoAt(0, FSpec.Meta.Tempo);
        midiSeq.AddTrack(trkSpec.Name);
        trackSeqIdx := midiSeq.TrackCount - 1;
        GenerateMidiForTrack(midiSeq, trackSeqIdx, trkSpec, resolution.ItemId);
      end;

      { PHASE 6 "Automation": a gentle fader ride that follows the
        arrangement's own declared section energy - not a substitute for
        real mixing (AIPlan.md section 11: "The validation system should
        first correct track and bus gain"), just enough that a freshly
        applied arrangement is not perfectly flat. }
      ApplyEnergyAutomation(strip.Id);
    end;

    { PHASE 6 "Side-chaining": duck the first bass-role strip against the
      first drum-role strip, the textbook example from AIPlan.md section 11
      ("Side-chain the bass to the kick"). }
    ApplySidechaining(stripIdByTrackId);

    FDoc.ReplaceSongSpec(FSpec.Clone);
    FDoc.ReplaceLyrics(FLyrics.Clone);
    FDoc.Touch;

    FResult.Resolutions := resolutions.ToArray;
    FResult.Warnings := warnings.ToStringArray;
  finally
    resolutions.Free;
    warnings.Free;
    stripIdByTrackId.Free;
  end;

  CaptureAfter;
  Result := True;
end;

procedure TApplyArrangementCommand.Undo;
begin
  RestoreFrom(FBeforeTimeline, FBeforeMixer, FBeforeMidi, FBeforeSpec, FBeforeLyrics,
    FBeforeTempo, FBeforeTSigNum, FBeforeTSigDen);
end;

function TApplyArrangementCommand.Redo: Boolean;
begin
  if FHaveAfter then
  begin
    RestoreFrom(FAfterTimeline, FAfterMixer, FAfterMidi, FAfterSpec, FAfterLyrics,
      FAfterTempo, FAfterTSigNum, FAfterTSigDen);
    Result := True;
  end
  else
    Result := Execute;
end;

function TApplyArrangementCommand.Description: string;
begin
  Result := Format('Apply song specification "%s"', [FSpec.Meta.Title]);
end;

{ ================= TArrangementEngine ================= }

constructor TArrangementEngine.Create(ADoc: TProjectDocument; ACatalogue: TInstrumentCatalogue);
begin
  inherited Create;
  if ADoc = nil then
    RaiseUDAW(errInvalidArgument, ARRANGEMENT_SUBSYS, 'an arrangement engine requires a project document');
  FDoc := ADoc;
  FCatalogue := ACatalogue;
end;

function TArrangementEngine.Apply(ACommands: TCommandManager; ASpec: TSongSpec;
  ALyrics: TLyricDocument; out AResult: TArrangementResult): Boolean;
var
  cmd: TApplyArrangementCommand;
begin
  SetLength(AResult.Warnings, 0);
  SetLength(AResult.Resolutions, 0);
  cmd := TApplyArrangementCommand.Create(FDoc, FCatalogue, ASpec, ALyrics);
  try
    Result := ACommands.Perform(cmd);
  except
    on E: EUDAWError do
    begin
      SetLength(AResult.Warnings, 1);
      AResult.Warnings[0] := E.Message;
      Exit(False);
    end;
  end;
  if Result then
    AResult := cmd.Result;
end;

end.
