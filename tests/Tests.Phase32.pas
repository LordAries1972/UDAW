unit Tests.Phase32;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 32 acceptance tests - AI Composition Phase 1 (docs/AIPlan.md section
  17 Phase 1: internal data model). Per that phase's own instruction
  ("Create test specifications without connecting to AI"), every spec here
  is hand-built in code, mirroring docs/AIPlan.md section 5's JSON example -
  no AI provider is touched. }

interface

procedure RegisterPhase32Tests;

implementation

uses
  SysUtils,
  UDAW.Testing,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics, UDAW.Composer.Validation,
  UDAW.Composer.Serialization,
  UDAW.Project.Document, UDAW.Project.Commands, UDAW.Composer.Commands;

const
  GRP = 'phase32.composer_data_model';

function BuildSampleSpec(out ALyrics: TLyricDocument): TSongSpec;
var
  spec: TSongSpec;
  lyrics: TLyricDocument;
  intro, verse1, chorus1: TSongSection;
  drums, bass: TSongTrackSpec;
  chords: TChordProgressionEntry;
  lsec: TLyricSection;
begin
  spec := TSongSpec.Create;
  spec.OriginalRequest := 'Create a four-minute dark cyberpunk techno song at 128 BPM in D minor.';
  spec.ProviderId := 'openai';
  spec.ModelId := 'gpt-4o';
  spec.GenerationSeed := 1234567890;

  spec.Meta.Title := 'Neon Resistance';
  spec.Meta.Instrumental := False;
  spec.Meta.Tempo := 128;
  spec.Meta.Key := 'D';
  spec.Meta.Scale := 'minor';
  spec.Meta.TimeSigNum := 4;
  spec.Meta.TimeSigDen := 4;
  spec.Meta.DurationBars := 128;

  intro := TSongSection.Create('intro', 'Intro', 1, 8, 0.30);
  spec.AddSection(intro);
  verse1 := TSongSection.Create('verse_1', 'Verse 1', 9, 16, 0.55);
  spec.AddSection(verse1);
  chorus1 := TSongSection.Create('chorus_1', 'Chorus 1', 25, 16, 0.80);
  spec.AddSection(chorus1);

  drums := TSongTrackSpec.Create('drums_1', 'Main Drums', stkMidi, 'drums');
  drums.RequestedTags := ['hard-techno', 'electronic', 'punchy'];
  drums.PreferredInstrumentId := 'instrument_0105';
  drums.FallbackCategory := 'Electronic Drum Kit';
  drums.MidiChannel := 10;
  spec.AddTrack(drums);

  bass := TSongTrackSpec.Create('bass_1', 'Distorted Bass', stkMidi, 'bass');
  bass.RequestedTags := ['distorted', 'dark', 'analog'];
  bass.PreferredInstrumentId := 'instrument_0042';
  bass.FallbackCategory := 'Synth Bass';
  spec.AddTrack(bass);

  chords := TChordProgressionEntry.Create('verse_1', 1);
  chords.Chords := ['Dm', 'Bb', 'C', 'Dm'];
  spec.AddChordProgression(chords);

  lyrics := TLyricDocument.Create;
  lyrics.Language := 'English';
  lsec := TLyricSection.Create('verse_1');
  lsec.AddLine(TLyricLine.Create('Running through the circuits underneath the neon sky', 9, 2));
  lyrics.AddSection(lsec);

  ALyrics := lyrics;
  Result := spec;
end;

procedure Test_SampleSpec_ValidatesClean;
var
  spec: TSongSpec;
  lyrics: TLyricDocument;
  issues: TValidationIssues;
begin
  spec := BuildSampleSpec(lyrics);
  try
    issues := TSongSpecValidator.Validate(spec, lyrics);
    Check(not TSongSpecValidator.HasErrors(issues),
      'the AIPlan.md section 5 example spec has no validation errors');
  finally
    lyrics.Free;
    spec.Free;
  end;
end;

procedure Test_Validator_CatchesSectionPastDuration;
var
  spec: TSongSpec;
  issues: TValidationIssues;
begin
  spec := TSongSpec.Create;
  try
    spec.Meta.DurationBars := 16;
    spec.AddSection(TSongSection.Create('outro', 'Outro', 10, 16, 0.5)); // 10..25 > 16
    issues := TSongSpecValidator.Validate(spec);
    Check(TSongSpecValidator.HasErrors(issues), 'a section extending past durationBars is an error');
  finally
    spec.Free;
  end;
end;

procedure Test_Validator_CatchesUnderCoveredChordProgression;
var
  spec: TSongSpec;
  chords: TChordProgressionEntry;
  issues: TValidationIssues;
  i: Integer;
  found: Boolean;
begin
  spec := TSongSpec.Create;
  try
    spec.AddSection(TSongSection.Create('verse_1', 'Verse 1', 1, 16, 0.5));
    chords := TChordProgressionEntry.Create('verse_1', 1);
    chords.Chords := ['Dm', 'Bb']; // 2 bars, section is 16
    spec.AddChordProgression(chords);
    issues := TSongSpecValidator.Validate(spec);
    found := False;
    for i := 0 to High(issues) do
      if Pos('covers', issues[i].Message) > 0 then found := True;
    Check(found, 'an under-covered chord progression is flagged');
  finally
    spec.Free;
  end;
end;

procedure Test_Validator_CatchesLyricLineOutsideSection;
var
  spec: TSongSpec;
  lyrics: TLyricDocument;
  lsec: TLyricSection;
  issues: TValidationIssues;
begin
  spec := TSongSpec.Create;
  lyrics := TLyricDocument.Create;
  try
    spec.AddSection(TSongSection.Create('verse_1', 'Verse 1', 9, 8, 0.5)); // bars 9..16
    lsec := TLyricSection.Create('verse_1');
    lsec.AddLine(TLyricLine.Create('too early', 1, 2)); // outside 9..16
    lyrics.AddSection(lsec);
    issues := TSongSpecValidator.Validate(spec, lyrics);
    Check(TSongSpecValidator.HasErrors(issues), 'a lyric line outside its section''s bars is an error');
  finally
    lyrics.Free;
    spec.Free;
  end;
end;

procedure Test_Validator_InstrumentalVsVocalConsistency;
var
  spec: TSongSpec;
  issues: TValidationIssues;
begin
  spec := TSongSpec.Create;
  try
    spec.Meta.Instrumental := True;
    spec.AddTrack(TSongTrackSpec.Create('vox_1', 'Lead Vocal', stkMidi, 'vocal'));
    issues := TSongSpecValidator.Validate(spec);
    Check(TSongSpecValidator.HasErrors(issues), 'instrumental=true with a vocal track is an error');
  finally
    spec.Free;
  end;
end;

procedure Test_ApplyDefaults_FillsMissingOptionalFields;
var
  spec: TSongSpec;
begin
  spec := TSongSpec.Create;
  try
    spec.Meta.Tempo := 0;
    spec.Meta.Key := '';
    spec.Meta.TimeSigDen := 3; // not a power of two
    TSongSpecValidator.ApplyDefaults(spec);
    Check(spec.Meta.Tempo > 0, 'tempo default applied');
    Check(spec.Meta.Key <> '', 'key default applied');
    Check(spec.Meta.TimeSigDen in [1, 2, 4, 8, 16, 32, 64], 'time signature denominator corrected');
  finally
    spec.Free;
  end;
end;

procedure Test_Serialization_RoundTrips;
var
  spec, spec2: TSongSpec;
  lyrics, lyrics2: TLyricDocument;
  text: string;
begin
  spec := BuildSampleSpec(lyrics);
  spec2 := nil;
  lyrics2 := nil;
  try
    text := SongSpecToString(spec, lyrics);
    SongSpecFromString(text, spec2, lyrics2);

    CheckEqualStr(spec.Meta.Title, spec2.Meta.Title, 'title round-trips');
    CheckEqualInt(Trunc(spec.Meta.Tempo), Trunc(spec2.Meta.Tempo), 'tempo round-trips');
    CheckEqualInt(spec.Sections.Count, spec2.Sections.Count, 'section count round-trips');
    CheckEqualStr(spec.Sections[1].Id, spec2.Sections[1].Id, 'section id round-trips');
    CheckEqualInt(spec.Tracks.Count, spec2.Tracks.Count, 'track count round-trips');
    CheckEqualStr(spec.Tracks[0].PreferredInstrumentId, spec2.Tracks[0].PreferredInstrumentId,
      'preferred instrument id round-trips');
    CheckEqualInt(spec.Harmony.Count, spec2.Harmony.Count, 'harmony count round-trips');
    CheckEqualInt(Length(spec.Harmony[0].Chords), Length(spec2.Harmony[0].Chords), 'chord list length round-trips');
    CheckEqualStr(lyrics.Sections[0].Lines[0].Text, lyrics2.Sections[0].Lines[0].Text,
      'lyric line text round-trips');
    CheckEqualInt(lyrics.Sections[0].Lines[0].StartBar, lyrics2.Sections[0].Lines[0].StartBar,
      'lyric line start bar round-trips');
  finally
    lyrics2.Free;
    spec2.Free;
    lyrics.Free;
    spec.Free;
  end;
end;

procedure Test_SetSongSpecCommand_UndoRedo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  spec: TSongSpec;
  lyrics: TLyricDocument;
begin
  doc := TProjectDocument.CreateNew('Composer Test');
  mgr := TCommandManager.Create;
  try
    spec := BuildSampleSpec(lyrics);
    mgr.Perform(TSetSongSpecCommand.Create(doc, spec, lyrics, 'Generate'));
    CheckEqualStr('Neon Resistance', doc.SongSpec.Meta.Title, 'spec applied');
    CheckEqualInt(3, doc.SongSpec.Sections.Count, 'sections applied');

    mgr.Undo;
    CheckEqualInt(0, doc.SongSpec.Sections.Count, 'undo restores the empty spec');

    mgr.Redo;
    CheckEqualStr('Neon Resistance', doc.SongSpec.Meta.Title, 'redo re-applies the spec');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_UpdateSongSectionCommand_UndoRedo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
begin
  doc := TProjectDocument.CreateNew('Composer Test 2');
  mgr := TCommandManager.Create;
  try
    doc.SongSpec.AddSection(TSongSection.Create('intro', 'Intro', 1, 8, 0.3));
    mgr.Perform(TUpdateSongSectionCommand.Create(doc, 'intro', 1, 4, 0.2));
    CheckEqualInt(4, doc.SongSpec.SectionById('intro').LengthBars, '"shorten the intro to four bars" applied');

    mgr.Undo;
    CheckEqualInt(8, doc.SongSpec.SectionById('intro').LengthBars, 'undo restores the original length');

    mgr.Redo;
    CheckEqualInt(4, doc.SongSpec.SectionById('intro').LengthBars, 'redo re-applies the shortened length');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure RegisterPhase32Tests;
begin
  RegisterTest(GRP, 'AIPlan.md section 5 sample spec validates clean', Test_SampleSpec_ValidatesClean);
  RegisterTest(GRP, 'Validator catches a section past the song duration', Test_Validator_CatchesSectionPastDuration);
  RegisterTest(GRP, 'Validator catches an under-covered chord progression', Test_Validator_CatchesUnderCoveredChordProgression);
  RegisterTest(GRP, 'Validator catches a lyric line outside its section', Test_Validator_CatchesLyricLineOutsideSection);
  RegisterTest(GRP, 'Validator enforces instrumental/vocal consistency', Test_Validator_InstrumentalVsVocalConsistency);
  RegisterTest(GRP, 'ApplyDefaults fills missing optional fields', Test_ApplyDefaults_FillsMissingOptionalFields);
  RegisterTest(GRP, 'Song spec + lyrics serialize/deserialize round-trip', Test_Serialization_RoundTrips);
  RegisterTest(GRP, 'TSetSongSpecCommand undo/redo', Test_SetSongSpecCommand_UndoRedo);
  RegisterTest(GRP, 'TUpdateSongSectionCommand undo/redo', Test_UpdateSongSectionCommand_UndoRedo);
end;

end.
