unit Tests.Phase37;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 37 acceptance tests - AIPlan.md PHASE 9 "TESTING AND OPTIMISATION"
  (docs/AIPlan.md section 17, lines 858-874). Phase 9 lists thirteen things
  to exercise rather than new subsystems: instrumental/lyrical projects,
  missing instruments, offline operation, provider failures, large
  arrangements, tempo/time-signature changes, undo/redo, project reopening,
  cross-platform paths, plug-in crashes and deterministic regeneration. Most
  of the underlying machinery already existed (Phases 1-8); this file is the
  coverage AIPlan.md's Phase 9 asked for, plus one real fix it uncovered:
  UDAW.Audio.Graph.Nodes.TVST2Node.Process now isolates a plugin that throws
  mid-processing instead of letting it take the audio engine down (see that
  unit - "plug-in crashes" is covered there by inspection/design, not by a
  unit test, since exercising it needs a real crashing VST2 DLL fixture). }

interface

procedure RegisterPhase37Tests;

implementation

uses
  SysUtils, StrUtils,
  UDAW.Testing, UDAW.Errors,
  UDAW.AI.Types, UDAW.AI.Composer,
  UDAW.Browser.Catalogue,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics, UDAW.Composer.Arrangement,
  UDAW.Project.Document, UDAW.Project.Commands, UDAW.Project.Serialization,
  UDAW.MIDI.Serialization;

const
  GRP = 'phase37.ai_testing_and_optimisation';

{ ================= TFakeFailingAIProvider ================= }

type
  { Always raises a transport-shaped error, regardless of the request - the
    stand-in for "the network/provider is unavailable" (AIPlan.md section
    16: "AI service unavailable"; section 9's testing list: "Offline
    operation", "Provider failures"). }
  TFakeFailingAIProvider = class(TInterfacedObject, IAIProvider)
  public
    function ProviderId: string;
    function DisplayName: string;
    function SendMessage(const ARequest: TAIRequest; ACancel: TObject): TAIResponse;
    function StreamMessage(const ARequest: TAIRequest; ADelta: TAIStreamDeltaProc;
      ACancel: TObject): TAIResponse;
    function ListModels: TArray<string>;
  end;

function TFakeFailingAIProvider.ProviderId: string;
begin
  Result := 'fake-offline';
end;

function TFakeFailingAIProvider.DisplayName: string;
begin
  Result := 'Fake Offline Provider';
end;

function TFakeFailingAIProvider.SendMessage(const ARequest: TAIRequest;
  ACancel: TObject): TAIResponse;
begin
  FillChar(Result, SizeOf(Result), 0);
  RaiseUDAW(errNetwork, 'Tests.Phase37', 'simulated: provider unreachable');
end;

function TFakeFailingAIProvider.StreamMessage(const ARequest: TAIRequest;
  ADelta: TAIStreamDeltaProc; ACancel: TObject): TAIResponse;
begin
  Result := SendMessage(ARequest, ACancel);
end;

function TFakeFailingAIProvider.ListModels: TArray<string>;
begin
  SetLength(Result, 0);
end;

{ ================= helpers ================= }

function MakeCatalogueItem(const AId, AName, ACategory: string; const ARoles, ATags: TArray<string>;
  ANoteLow: Integer = 28; ANoteHigh: Integer = 100): TCatalogueItem;
begin
  Result := TCatalogueItem.Create;
  Result.Id := AId;
  Result.Name := AName;
  Result.Category := ACategory;
  Result.Kind := ikInstrumentVST;
  Result.Roles := ARoles;
  Result.Tags := ATags;
  Result.Available := True;
  Result.NoteRangeLow := ANoteLow;
  Result.NoteRangeHigh := ANoteHigh;
end;

function MakeSimpleSpec(AInstrumental: Boolean; ASeed: Int64 = 42): TSongSpec;
begin
  Result := TSongSpec.Create;
  Result.Meta.Instrumental := AInstrumental;
  Result.Meta.Tempo := 140.0;
  Result.Meta.Key := 'D';
  Result.Meta.Scale := 'minor';
  Result.Meta.TimeSigNum := 3;
  Result.Meta.TimeSigDen := 4;
  Result.Meta.DurationBars := 16;
  Result.GenerationSeed := ASeed;
  Result.AddSection(TSongSection.Create('intro', 'Intro', 1, 8, 0.3));
  Result.AddSection(TSongSection.Create('drop', 'Drop', 9, 8, 0.9));
  Result.AddTrack(TSongTrackSpec.Create('drums', 'Drums', stkMidi, 'drums'));
  Result.AddTrack(TSongTrackSpec.Create('bass', 'Bass', stkMidi, 'bass'));
end;

{ ================= 1. instrumental projects ================= }

procedure Test_Instrumental_ValidationRejectsAVocalTrack;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  cat: TInstrumentCatalogue;
  engine: TArrangementEngine;
  spec: TSongSpec;
  lyrics: TLyricDocument;
  res: TArrangementResult;
  ok: Boolean;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  cat := TInstrumentCatalogue.Create;
  try
    spec := MakeSimpleSpec(True);
    spec.AddTrack(TSongTrackSpec.Create('vox', 'Lead Vocal', stkMidi, 'vocal'));
    lyrics := TLyricDocument.Create;

    { TApplyArrangementCommand adopts ASpec/ALyrics at construction and
      TCommandManager.Perform always frees a command whose Execute fails
      (UDAW.Project.Commands.Perform: "except ACommand.Free; raise;"), so a
      rejected Apply already freed spec/lyrics for us - nothing to free here. }
    engine := TArrangementEngine.Create(doc, cat);
    try
      ok := engine.Apply(cmds, spec, lyrics, res);
      CheckFalse(ok, 'project.instrumental=true with a vocal-role track must be rejected (AIPlan.md section 7)');
      CheckEqualInt(0, doc.Timeline.TrackCount, 'a rejected arrangement must not touch the project at all');
    finally
      engine.Free;
    end;
  finally
    cat.Free;
    cmds.Free;
    doc.Free;
  end;
end;

{ ================= 2. lyrical projects ================= }

procedure Test_Lyrical_ArrangementAcceptsVocalTrackWithMatchingLyrics;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  cat: TInstrumentCatalogue;
  engine: TArrangementEngine;
  spec: TSongSpec;
  lyrics: TLyricDocument;
  lsec: TLyricSection;
  res: TArrangementResult;
  ok: Boolean;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  cat := TInstrumentCatalogue.Create;
  try
    spec := MakeSimpleSpec(False);
    spec.AddTrack(TSongTrackSpec.Create('vox', 'Lead Vocal', stkMidi, 'vocal'));
    lyrics := TLyricDocument.Create;
    lsec := TLyricSection.Create('intro');
    lsec.AddLine(TLyricLine.Create('running through the circuits', 1, 4));
    lyrics.AddSection(lsec);

    engine := TArrangementEngine.Create(doc, cat);
    try
      ok := engine.Apply(cmds, spec, lyrics, res);
      Check(ok, 'a non-instrumental spec with a vocal track and matching lyrics must apply cleanly');
      CheckEqualInt(3, doc.Timeline.TrackCount, 'drums + bass + vocal tracks were all created');
    finally
      engine.Free;
    end;
  finally
    cat.Free;
    cmds.Free;
    doc.Free;
  end;
end;

{ ================= 3. missing instruments ================= }

procedure Test_MissingInstrument_UnresolvedTrackIsKeptNotDropped;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  cat: TInstrumentCatalogue;
  engine: TArrangementEngine;
  spec: TSongSpec;
  lyrics: TLyricDocument;
  res: TArrangementResult;
  ok: Boolean;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  cat := TInstrumentCatalogue.Create;    // deliberately empty: nothing can resolve
  try
    spec := MakeSimpleSpec(True);
    lyrics := TLyricDocument.Create;

    engine := TArrangementEngine.Create(doc, cat);
    try
      ok := engine.Apply(cmds, spec, lyrics, res);
      Check(ok, 'an unresolved instrument must not fail the whole apply');
      CheckEqualInt(2, res.UnresolvedCount, 'both drums and bass are unresolved against an empty catalogue');
      CheckEqualInt(2, doc.Timeline.TrackCount,
        'AIPlan.md section 6: "never silently remove the track" - both tracks are still created');
    finally
      engine.Free;
    end;
  finally
    cat.Free;
    cmds.Free;
    doc.Free;
  end;
end;

procedure Test_MissingInstrument_ExactIdBeatsCategoryMatch;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  cat: TInstrumentCatalogue;
  engine: TArrangementEngine;
  spec: TSongSpec;
  lyrics: TLyricDocument;
  res: TArrangementResult;
  ok: Boolean;
  i: Integer;
  resolved: string;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  cat := TInstrumentCatalogue.Create;
  try
    cat.Items.Add(MakeCatalogueItem('cat_bass', 'Category Bass', 'Synth Bass', ['bass'], ['dark']));
    cat.Items.Add(MakeCatalogueItem('exact_bass', 'Exact Bass', 'Other Category', [], []));

    spec := MakeSimpleSpec(True);
    spec.TrackById('bass').PreferredInstrumentId := 'exact_bass';
    spec.TrackById('bass').FallbackCategory := 'Synth Bass';
    lyrics := TLyricDocument.Create;

    engine := TArrangementEngine.Create(doc, cat);
    try
      ok := engine.Apply(cmds, spec, lyrics, res);
      Check(ok, 'apply succeeds with a populated catalogue');
      resolved := '';
      for i := 0 to High(res.Resolutions) do
        if SameText(res.Resolutions[i].TrackId, 'bass') then
          resolved := res.Resolutions[i].ItemId;
      CheckEqualStr('exact_bass', resolved,
        'AIPlan.md section 6 matching order: an exact instrument id wins over a category/role match');
    finally
      engine.Free;
    end;
  finally
    cat.Free;
    cmds.Free;
    doc.Free;
  end;
end;

{ ================= 4. offline operation ================= }

procedure Test_OfflineOperation_ArrangementNeedsNoAIProvider;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  cat: TInstrumentCatalogue;
  engine: TArrangementEngine;
  spec: TSongSpec;
  lyrics: TLyricDocument;
  res: TArrangementResult;
begin
  { No IAIProvider/ICompositionProvider is constructed anywhere in this test:
    the arrangement pipeline (catalogue -> spec -> timeline/mixer/MIDI) is
    entirely local, matching AIPlan.md section 16's "the current project must
    remain usable even if the AI request fails" taken to its limit - it
    never needed the AI to begin with. }
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  cat := TInstrumentCatalogue.Create;
  try
    spec := MakeSimpleSpec(True);
    lyrics := TLyricDocument.Create;
    engine := TArrangementEngine.Create(doc, cat);
    try
      Check(engine.Apply(cmds, spec, lyrics, res), 'arrangement applies with zero network access');
      CheckNear(140.0, doc.TempoBPM, 1.0E-9, 'tempo came from the spec, not a provider round-trip');
    finally
      engine.Free;
    end;
  finally
    cat.Free;
    cmds.Free;
    doc.Free;
  end;
end;

{ ================= 5. provider failures ================= }

procedure Test_ProviderFailure_CompositionRequestFailsCleanlyAfterRetries;
var
  provider: ICompositionProvider;
  cat: TInstrumentCatalogue;
  spec: TSongSpec;
  lyrics: TLyricDocument;
  reqId: Int64;
  status: TCompositionRequestStatus;
begin
  cat := TInstrumentCatalogue.Create;
  try
    provider := TCompositionProvider.Create(TFakeFailingAIProvider.Create, 'fake-model', 1);
    reqId := provider.SubmitCompositionRequest('a song', cat, spec, lyrics);
    try
      Check(reqId > 0, 'a request id is issued even though the provider will fail');
      Check(spec = nil, 'no spec is produced when every attempt fails');
      status := provider.GetRequestStatus(reqId);
      CheckEqualBool(True, status.State = crsFailed, 'the request is recorded as failed, not left running');
      Check(status.Attempts >= 1, 'at least one attempt was recorded');
      Check(Trim(provider.GetLastError) <> '', 'GetLastError explains why (AIPlan.md section 2A)');
    finally
      spec.Free;
      lyrics.Free;
    end;
  finally
    cat.Free;
  end;
end;

{ ================= 6. large arrangements ================= }

procedure Test_LargeArrangement_ManySectionsAndTracksApplyWithoutError;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  cat: TInstrumentCatalogue;
  engine: TArrangementEngine;
  spec: TSongSpec;
  lyrics: TLyricDocument;
  res: TArrangementResult;
  i: Integer;
  ok: Boolean;
const
  SECTION_COUNT = 40;
  TRACK_COUNT = 12;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  cat := TInstrumentCatalogue.Create;
  try
    spec := TSongSpec.Create;
    spec.Meta.Instrumental := True;
    spec.Meta.Tempo := 128.0;
    spec.Meta.DurationBars := SECTION_COUNT * 4;
    for i := 0 to SECTION_COUNT - 1 do
      spec.AddSection(TSongSection.Create(Format('sec%d', [i]), Format('Section %d', [i]),
        1 + i * 4, 4, 0.2 + (i mod 5) * 0.15));
    for i := 0 to TRACK_COUNT - 1 do
      spec.AddTrack(TSongTrackSpec.Create(Format('trk%d', [i]), Format('Track %d', [i]),
        stkMidi, IfThen(i mod 3 = 0, 'drums', IfThen(i mod 3 = 1, 'bass', 'pad'))));
    lyrics := TLyricDocument.Create;

    engine := TArrangementEngine.Create(doc, cat);
    try
      ok := engine.Apply(cmds, spec, lyrics, res);
      Check(ok, Format('a %d-section/%d-track spec applies without raising', [SECTION_COUNT, TRACK_COUNT]));
      CheckEqualInt(TRACK_COUNT, doc.Timeline.TrackCount, 'every track was created, none dropped');
      CheckEqualInt(TRACK_COUNT, Length(res.Resolutions), 'every track got a resolution outcome');
    finally
      engine.Free;
    end;
  finally
    cat.Free;
    cmds.Free;
    doc.Free;
  end;
end;

{ ================= 7. tempo / time-signature changes ================= }

procedure Test_TempoAndTimeSignature_AppliedThenUndoRestoresPrevious;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  cat: TInstrumentCatalogue;
  engine: TArrangementEngine;
  spec: TSongSpec;
  lyrics: TLyricDocument;
  res: TArrangementResult;
  prevTempo: Double;
  prevNum, prevDen: Integer;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  cat := TInstrumentCatalogue.Create;
  try
    prevTempo := doc.TempoBPM;
    prevNum := doc.TimeSigNum;
    prevDen := doc.TimeSigDen;

    spec := MakeSimpleSpec(True); // Meta.Tempo=140, TimeSig=3/4
    lyrics := TLyricDocument.Create;
    engine := TArrangementEngine.Create(doc, cat);
    try
      Check(engine.Apply(cmds, spec, lyrics, res), 'apply succeeds');
      CheckNear(140.0, doc.TempoBPM, 1.0E-9, 'project tempo now follows the spec');
      CheckEqualInt(3, doc.TimeSigNum, 'project time-signature numerator now follows the spec');
      CheckEqualInt(4, doc.TimeSigDen, 'project time-signature denominator now follows the spec');

      cmds.Undo;
      CheckNear(prevTempo, doc.TempoBPM, 1.0E-9, 'Undo restores the pre-apply tempo');
      CheckEqualInt(prevNum, doc.TimeSigNum, 'Undo restores the pre-apply time-signature numerator');
      CheckEqualInt(prevDen, doc.TimeSigDen, 'Undo restores the pre-apply time-signature denominator');
    finally
      engine.Free;
    end;
  finally
    cat.Free;
    cmds.Free;
    doc.Free;
  end;
end;

{ ================= 8. undo / redo ================= }

procedure Test_UndoRedo_ArrangementApplyRoundTrips;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  cat: TInstrumentCatalogue;
  engine: TArrangementEngine;
  spec: TSongSpec;
  lyrics: TLyricDocument;
  res: TArrangementResult;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  cat := TInstrumentCatalogue.Create;
  try
    spec := MakeSimpleSpec(True);
    lyrics := TLyricDocument.Create;
    engine := TArrangementEngine.Create(doc, cat);
    try
      Check(engine.Apply(cmds, spec, lyrics, res), 'apply succeeds');
      CheckEqualInt(2, doc.Timeline.TrackCount, 'two tracks exist right after apply');
      Check(cmds.CanUndo, 'the apply is one undoable step');

      cmds.Undo;
      CheckEqualInt(0, doc.Timeline.TrackCount, 'Undo removes everything the apply created');
      Check(cmds.CanRedo, 'the undone apply can be redone');

      cmds.Redo;
      CheckEqualInt(2, doc.Timeline.TrackCount, 'Redo re-creates both tracks');
    finally
      engine.Free;
    end;
  finally
    cat.Free;
    cmds.Free;
    doc.Free;
  end;
end;

{ ================= 9. project reopening ================= }

procedure Test_ProjectReopening_RoundTripsAISpecThroughSaveLoad;
var
  doc, doc2: TProjectDocument;
  spec: TSongSpec;
  text: string;
begin
  doc := TProjectDocument.CreateNew;
  try
    spec := MakeSimpleSpec(True);
    doc.ReplaceSongSpec(spec);
    text := ProjectToString(doc);
  finally
    doc.Free;
  end;

  doc2 := ProjectFromString(text);
  try
    CheckEqualInt(2, doc2.SongSpec.Sections.Count, 'both sections survive a save/load round trip');
    CheckEqualInt(2, doc2.SongSpec.Tracks.Count, 'both tracks survive a save/load round trip');
    CheckNear(140.0, doc2.SongSpec.Meta.Tempo, 1.0E-9, 'the spec''s own tempo field round-trips');
  finally
    doc2.Free;
  end;
end;

procedure Test_ProjectReopening_OlderFileWithNoAISpecSynthesizesEmptySpec;
var
  doc, doc2: TProjectDocument;
  spec: TSongSpec;
  text: string;
  beginPos, endPos: Integer;
begin
  doc := TProjectDocument.CreateNew;
  try
    spec := MakeSimpleSpec(True);
    doc.ReplaceSongSpec(spec);
    text := ProjectToString(doc);
  finally
    doc.Free;
  end;

  { simulate a pre-v6 file: strip the AISPEC-BEGIN..AISPEC-END block and roll
    the header back to version 5, exactly like a file saved before AIPlan.md
    Phase 1 shipped. }
  beginPos := Pos('AISPEC-BEGIN', text);
  Check(beginPos > 0, 'sanity: the freshly-saved v6 text actually has an AISPEC block');
  endPos := Pos('AISPEC-END', text) + Length('AISPEC-END') + 1;
  Delete(text, beginPos, endPos - beginPos);
  text := StringReplace(text, 'UDAWPROJECT 6', 'UDAWPROJECT 5', [rfIgnoreCase]);

  doc2 := ProjectFromString(text);
  try
    Check(doc2.SongSpec <> nil, 'an older file with no AISPEC block still loads with a (synthesized) spec');
    CheckEqualInt(0, doc2.SongSpec.Sections.Count, 'the synthesized spec is empty, not an error');
  finally
    doc2.Free;
  end;
end;

{ ================= 10. cross-platform paths ================= }

procedure Test_CrossPlatformPaths_StableIdIgnoresSeparatorStyle;
var
  idBackslash, idForwardSlash: string;
begin
  idBackslash := StableCatalogueId('C:\Sounds\Instruments\Bass.wav');
  idForwardSlash := StableCatalogueId('C:/Sounds/Instruments/Bass.wav');
  CheckEqualStr(idBackslash, idForwardSlash,
    'the same file referenced with "\\" or "/" separators must get the same catalogue id, ' +
    'so a catalogue built on one platform still resolves TSongTrackSpec.PreferredInstrumentId on another');
end;

{ ================= 11. deterministic regeneration ================= }

procedure Test_DeterministicRegeneration_SameSpecAndSeedProduceIdenticalMidi;
var
  doc1, doc2: TProjectDocument;
  cmds1, cmds2: TCommandManager;
  cat: TInstrumentCatalogue;
  engine1, engine2: TArrangementEngine;
  spec1, spec2: TSongSpec;
  lyrics1, lyrics2: TLyricDocument;
  res: TArrangementResult;
  midi1, midi2: string;
begin
  doc1 := TProjectDocument.CreateNew;
  doc2 := TProjectDocument.CreateNew;
  cmds1 := TCommandManager.Create;
  cmds2 := TCommandManager.Create;
  cat := TInstrumentCatalogue.Create;
  try
    spec1 := MakeSimpleSpec(True, 42);
    spec2 := MakeSimpleSpec(True, 42);
    lyrics1 := TLyricDocument.Create;
    lyrics2 := TLyricDocument.Create;

    engine1 := TArrangementEngine.Create(doc1, cat);
    engine2 := TArrangementEngine.Create(doc2, cat);
    try
      Check(engine1.Apply(cmds1, spec1, lyrics1, res), 'first apply succeeds');
      Check(engine2.Apply(cmds2, spec2, lyrics2, res), 'second apply succeeds');

      midi1 := MidiProjectToString(doc1.Midi);
      midi2 := MidiProjectToString(doc2.Midi);
      CheckEqualStr(midi1, midi2,
        'AIPlan.md section 9: "Saving the random seed allows the exact performance to be ' +
        'regenerated" - the same spec + GenerationSeed must produce byte-identical MIDI');
    finally
      engine1.Free;
      engine2.Free;
    end;
  finally
    cat.Free;
    cmds1.Free;
    cmds2.Free;
    doc1.Free;
    doc2.Free;
  end;
end;

procedure RegisterPhase37Tests;
begin
  RegisterTest(GRP, 'Instrumental: validation rejects a vocal-role track', Test_Instrumental_ValidationRejectsAVocalTrack);
  RegisterTest(GRP, 'Lyrical: a vocal track with matching lyrics applies cleanly', Test_Lyrical_ArrangementAcceptsVocalTrackWithMatchingLyrics);
  RegisterTest(GRP, 'Missing instrument: an unresolved track is kept, not dropped', Test_MissingInstrument_UnresolvedTrackIsKeptNotDropped);
  RegisterTest(GRP, 'Missing instrument: an exact instrument id beats a category match', Test_MissingInstrument_ExactIdBeatsCategoryMatch);
  RegisterTest(GRP, 'Offline operation: the arrangement pipeline needs no AI provider', Test_OfflineOperation_ArrangementNeedsNoAIProvider);
  RegisterTest(GRP, 'Provider failure: a composition request fails cleanly after retries', Test_ProviderFailure_CompositionRequestFailsCleanlyAfterRetries);
  RegisterTest(GRP, 'Large arrangement: many sections/tracks apply without error', Test_LargeArrangement_ManySectionsAndTracksApplyWithoutError);
  RegisterTest(GRP, 'Tempo/time-signature: applied by the spec, restored by Undo', Test_TempoAndTimeSignature_AppliedThenUndoRestoresPrevious);
  RegisterTest(GRP, 'Undo/Redo: an arrangement apply round-trips cleanly', Test_UndoRedo_ArrangementApplyRoundTrips);
  RegisterTest(GRP, 'Project reopening: the AISPEC section round-trips through save/load', Test_ProjectReopening_RoundTripsAISpecThroughSaveLoad);
  RegisterTest(GRP, 'Project reopening: an older file with no AISPEC synthesizes an empty spec', Test_ProjectReopening_OlderFileWithNoAISpecSynthesizesEmptySpec);
  RegisterTest(GRP, 'Cross-platform paths: the stable catalogue id ignores separator style', Test_CrossPlatformPaths_StableIdIgnoresSeparatorStyle);
  RegisterTest(GRP, 'Deterministic regeneration: same spec + seed produces identical MIDI', Test_DeterministicRegeneration_SameSpecAndSeedProduceIdenticalMidi);
end;

end.
