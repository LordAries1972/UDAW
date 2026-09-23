unit Tests.Phase36;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 36 acceptance tests - AIPlan.md PHASE 7 (Mixing Assistance: general
  frequency-conflict/pan-separation across analyzed strips, gate/de-esser
  effect selection, automation-ride recommendations) and PHASE 8
  (Conversational Revision: TAIRevisionSession, Locked content, structured
  change-set diffing, revision history). TFakeCompositionProvider stands in
  for a real AI provider and deliberately IGNORES the scope it is asked to
  respect, so the scoped-revision tests actually prove the guarantee is
  enforced by UDAW.AI.Composer.MergeLockedAndOutOfScope regardless of what
  the "AI" returns, not merely that a well-behaved AI would cooperate. }

interface

procedure RegisterPhase36Tests;

implementation

uses
  SysUtils, StrUtils,
  UDAW.Testing,
  UDAW.DSP.Analysis,
  UDAW.AI.Mixing, UDAW.AI.Composer, UDAW.AI.Revision,
  UDAW.Browser.Catalogue,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics, UDAW.Composer.RevisionHistory,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Mixer.Model;

const
  GRP = 'phase36.mixing_assistance_and_revision';

{ ================= TFakeCompositionProvider ================= }

type
  { Always "revises" by cloning the existing spec, bumping every section's
    energy by +0.1 and every track's role to 'changed' - regardless of what
    scope it was asked to respect, so the tests can prove the CALLER-side
    guarantee (MergeLockedAndOutOfScope) rather than provider cooperation. }
  TFakeCompositionProvider = class(TInterfacedObject, ICompositionProvider)
  private
    FLastError: string;
  public
    procedure Initialize;
    function Authenticate: Boolean;
    function SubmitCompositionRequest(const AUserRequest: string;
      ACatalogue: TInstrumentCatalogue; out ASpec: TSongSpec; out ALyrics: TLyricDocument): Int64;
    function SubmitRevisionRequest(AExistingSpec: TSongSpec; AExistingLyrics: TLyricDocument;
      const AInstruction: string; out ARevisedSpec: TSongSpec;
      out ARevisedLyrics: TLyricDocument; const AScopeTrackIds: TArray<string>;
      const AScopeSectionIds: TArray<string>): Int64;
    function GenerateLyrics(ASpec: TSongSpec; const ASubject, ALanguage: string;
      out ALyrics: TLyricDocument): Int64;
    function AnalyzeLyrics(ASpec: TSongSpec; ALyrics: TLyricDocument; out AReport: string): Int64;
    function AnalyzeArrangement(ASpec: TSongSpec; out AReport: string): Int64;
    procedure CancelRequest(ARequestId: Int64);
    function GetRequestStatus(ARequestId: Int64): TCompositionRequestStatus;
    function GetLastError: string;
    function ProviderId: string;
  end;

procedure TFakeCompositionProvider.Initialize;
begin
end;

function TFakeCompositionProvider.Authenticate: Boolean;
begin
  Result := True;
end;

function TFakeCompositionProvider.SubmitCompositionRequest(const AUserRequest: string;
  ACatalogue: TInstrumentCatalogue; out ASpec: TSongSpec; out ALyrics: TLyricDocument): Int64;
begin
  ASpec := nil; ALyrics := nil; Result := 0;
end;

function TFakeCompositionProvider.SubmitRevisionRequest(AExistingSpec: TSongSpec;
  AExistingLyrics: TLyricDocument; const AInstruction: string; out ARevisedSpec: TSongSpec;
  out ARevisedLyrics: TLyricDocument; const AScopeTrackIds, AScopeSectionIds: TArray<string>): Int64;
var
  i: Integer;
begin
  Result := 1;
  ARevisedSpec := AExistingSpec.Clone;
  for i := 0 to ARevisedSpec.Sections.Count - 1 do
    ARevisedSpec.Sections[i].Energy := ARevisedSpec.Sections[i].Energy + 0.1;
  for i := 0 to ARevisedSpec.Tracks.Count - 1 do
    ARevisedSpec.Tracks[i].Role := 'changed';
  ARevisedLyrics := AExistingLyrics.Clone;
end;

function TFakeCompositionProvider.GenerateLyrics(ASpec: TSongSpec; const ASubject, ALanguage: string;
  out ALyrics: TLyricDocument): Int64;
begin
  ALyrics := nil; Result := 0;
end;

function TFakeCompositionProvider.AnalyzeLyrics(ASpec: TSongSpec; ALyrics: TLyricDocument;
  out AReport: string): Int64;
begin
  AReport := ''; Result := 0;
end;

function TFakeCompositionProvider.AnalyzeArrangement(ASpec: TSongSpec; out AReport: string): Int64;
begin
  AReport := ''; Result := 0;
end;

procedure TFakeCompositionProvider.CancelRequest(ARequestId: Int64);
begin
end;

function TFakeCompositionProvider.GetRequestStatus(ARequestId: Int64): TCompositionRequestStatus;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

function TFakeCompositionProvider.GetLastError: string;
begin
  Result := FLastError;
end;

function TFakeCompositionProvider.ProviderId: string;
begin
  Result := 'fake';
end;

{ ================= helpers ================= }

function MakeTwoSectionTwoTrackSpec: TSongSpec;
begin
  Result := TSongSpec.Create;
  Result.AddSection(TSongSection.Create('intro', 'Intro', 1, 8, 0.2));
  Result.AddSection(TSongSection.Create('drop', 'Drop', 9, 8, 0.9));
  Result.AddTrack(TSongTrackSpec.Create('t1', 'Bass', stkMidi, 'bass'));
  Result.AddTrack(TSongTrackSpec.Create('t2', 'Lead', stkMidi, 'lead'));
end;

{ ================= DiffSongSpecs ================= }

procedure Test_DiffSongSpecs_DetectsModifiedSectionAndAddedTrack;
var
  oldSpec, newSpec: TSongSpec;
  changes: TArray<TSongSpecChange>;
  i: Integer;
  foundSectionMod, foundTrackAdd: Boolean;
begin
  oldSpec := MakeTwoSectionTwoTrackSpec;
  newSpec := oldSpec.Clone;
  try
    newSpec.SectionById('intro').Energy := 0.5;
    newSpec.AddTrack(TSongTrackSpec.Create('t3', 'Pad', stkMidi, 'pad'));

    changes := DiffSongSpecs(oldSpec, newSpec);
    foundSectionMod := False;
    foundTrackAdd := False;
    for i := 0 to High(changes) do
    begin
      if (changes[i].Kind = scSectionModified) and SameText(changes[i].TargetId, 'intro') then
        foundSectionMod := True;
      if (changes[i].Kind = scTrackAdded) and SameText(changes[i].TargetId, 't3') then
        foundTrackAdd := True;
    end;
    Check(foundSectionMod, 'energy change on "intro" is reported as a section modification');
    Check(foundTrackAdd, 'the new "Pad" track is reported as a track addition');
  finally
    oldSpec.Free;
    newSpec.Free;
  end;
end;

{ ================= MergeLockedAndOutOfScope ================= }

procedure Test_MergeLockedAndOutOfScope_PreservesLockedSection;
var
  existing, revised: TSongSpec;
begin
  existing := MakeTwoSectionTwoTrackSpec;
  existing.SectionById('intro').Locked := True;
  revised := existing.Clone;
  try
    revised.SectionById('intro').Energy := 0.99;   // "AI" touched a locked section
    revised.SectionById('drop').Energy := 0.99;    // and an unlocked one

    MergeLockedAndOutOfScope(existing, revised, nil, nil);

    CheckNear(0.2, revised.SectionById('intro').Energy, 1.0E-9,
      'a Locked section is restored to its original value no matter what the AI returned');
    CheckNear(0.99, revised.SectionById('drop').Energy, 1.0E-9,
      'an unlocked section keeps the AI''s change');
  finally
    existing.Free;
    revised.Free;
  end;
end;

procedure Test_MergeLockedAndOutOfScope_RestrictsToScope;
var
  existing, revised: TSongSpec;
begin
  existing := MakeTwoSectionTwoTrackSpec;
  revised := existing.Clone;
  try
    revised.TrackById('t1').Role := 'ai-changed';
    revised.TrackById('t2').Role := 'ai-changed';

    { only t1 is in scope - t2 must be forced back even though it is not
      Locked, because it is outside the requested scope }
    MergeLockedAndOutOfScope(existing, revised, ['t1'], nil);

    CheckEqualStr('ai-changed', revised.TrackById('t1').Role, 'in-scope track keeps the AI''s change');
    CheckEqualStr('lead', revised.TrackById('t2').Role, 'out-of-scope track is restored');
  finally
    existing.Free;
    revised.Free;
  end;
end;

{ ================= TAIRevisionSession ================= }

procedure Test_RevisionSession_ScopedProposeHonoursLockAndScopeEvenWithAnUncooperativeAI;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  provider: ICompositionProvider;
  session: TAIRevisionSession;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  provider := TFakeCompositionProvider.Create;
  try
    doc.ReplaceSongSpec(MakeTwoSectionTwoTrackSpec);
    doc.SongSpec.SectionById('intro').Locked := True;

    session := TAIRevisionSession.Create(doc, cmds, provider);
    try
      Check(session.Propose('make it louder', ['t1'], nil),
        'the fake provider always returns a usable revision');
      Check(session.HasPendingProposal, 'a proposal is now pending');
      Check(Length(session.PendingChanges) > 0, 'the diff found at least one change');

      session.Preview;
      Check(session.HasPendingPreview, 'preview performed the staged command');

      { the fake AI bumped every section's energy and every track's role,
        ignoring both the Locked section and the requested track scope - the
        session must still have suppressed both }
      CheckNear(0.2, doc.SongSpec.SectionById('intro').Energy, 1.0E-9,
        'Locked section "intro" was not changed despite the AI touching it');
      CheckEqualStr('changed', doc.SongSpec.TrackById('t1').Role, 'in-scope track "t1" was changed');
      CheckEqualStr('lead', doc.SongSpec.TrackById('t2').Role, 'out-of-scope track "t2" was restored');

      session.Reject;
      CheckFalse(session.HasPendingPreview, 'reject undoes the previewed revision');
      CheckNear(0.9, doc.SongSpec.SectionById('drop').Energy, 1.0E-9,
        'rejecting restores the pre-revision spec entirely');
      Check(session.History.Entry(0).Resolved, 'the history entry is marked resolved');
      CheckFalse(session.History.Entry(0).Accepted, 'a rejected revision is recorded as not accepted');
    finally
      session.Free;
    end;
  finally
    cmds.Free;
    doc.Free;
  end;
end;

procedure Test_RevisionSession_ApplyKeepsRevisionAndMarksHistoryAccepted;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  provider: ICompositionProvider;
  session: TAIRevisionSession;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  provider := TFakeCompositionProvider.Create;
  try
    doc.ReplaceSongSpec(MakeTwoSectionTwoTrackSpec);

    session := TAIRevisionSession.Create(doc, cmds, provider);
    try
      session.Propose('go bigger');
      session.Preview;
      session.Apply;

      CheckFalse(session.HasPendingPreview, 'apply clears session tracking');
      CheckNear(0.3, doc.SongSpec.SectionById('intro').Energy, 1.0E-9, 'the revision survives Apply');
      Check(cmds.CanUndo, 'the revision is still a normal, undoable command');
      Check(session.History.Entry(0).Accepted, 'an applied revision is recorded as accepted');
    finally
      session.Free;
    end;
  finally
    cmds.Free;
    doc.Free;
  end;
end;

{ ================= SuggestFrequencyConflicts / SuggestAutomationRide / effect selection ================= }

procedure Test_SuggestFrequencyConflicts_SeparatesCollidingStrips;
var
  strips: TArray<TStripAnalysis>;
  suggestions: TArray<TMixSuggestion>;
  i: Integer;
  foundPanA, foundPanB, foundEQ: Boolean;
begin
  SetLength(strips, 2);
  strips[0].StripName := 'Rhythm Guitar';
  strips[0].Analysis := TAudioAnalysisResult.Empty;
  strips[0].Analysis.MidBandEnergy := 0.6;
  strips[1].StripName := 'Synth Lead';
  strips[1].Analysis := TAudioAnalysisResult.Empty;
  strips[1].Analysis.MidBandEnergy := 0.55;

  suggestions := SuggestFrequencyConflicts(strips);
  foundPanA := False; foundPanB := False; foundEQ := False;
  for i := 0 to High(suggestions) do
  begin
    if (suggestions[i].Kind = mskPan) and SameText(suggestions[i].StripName, 'Rhythm Guitar') then
      foundPanA := suggestions[i].NewPan < 0;
    if (suggestions[i].Kind = mskPan) and SameText(suggestions[i].StripName, 'Synth Lead') then
      foundPanB := suggestions[i].NewPan > 0;
    if suggestions[i].Kind = mskCorrectiveEQ then
      foundEQ := True;
  end;
  Check(foundPanA, 'the first colliding strip is panned left');
  Check(foundPanB, 'the second colliding strip is panned right');
  Check(foundEQ, 'a corrective EQ dip is also suggested for the shared band');
end;

procedure Test_SuggestAutomationRide_BuildsPointsFromSectionEnergy;
var
  doc: TProjectDocument;
  suggestions: TArray<TMixSuggestion>;
begin
  doc := TProjectDocument.CreateNew;
  try
    doc.ReplaceSongSpec(MakeTwoSectionTwoTrackSpec);
    suggestions := SuggestAutomationRide(doc);
    CheckEqualInt(1, Length(suggestions), 'one automation-ride suggestion for the master');
    CheckEqualInt(2, Length(suggestions[0].RidePoints), 'one ride point per section');
    CheckNear(-4.8, suggestions[0].RidePoints[0].GainDb, 1.0E-9, 'intro (energy 0.2) maps to -6+0.2*6 dB');
    CheckNear(-0.6, suggestions[0].RidePoints[1].GainDb, 1.0E-9, 'drop (energy 0.9) maps to -6+0.9*6 dB');
  finally
    doc.Free;
  end;
end;

procedure Test_SuggestMixHeuristic_SelectsDeEsserAndGate;
var
  doc: TProjectDocument;
  analysis: TAudioAnalysisResult;
  suggestions: TArray<TMixSuggestion>;
  i: Integer;
  foundDeEsser, foundGate: Boolean;
begin
  doc := TProjectDocument.CreateNew;
  try
    doc.Mixer.AddStrip(skAudioTrack, 'Lead Vocal');
    doc.Mixer.AddStrip(skAudioTrack, 'Drum Kit');

    analysis := TAudioAnalysisResult.Empty;
    analysis.IntegratedLufs := -30.0;
    analysis.TruePeakDb := -1.0;       // 29 dB above integrated -> gate candidate
    analysis.HighBandEnergy := 0.2;    // sibilance candidate
    analysis.LowBandEnergy := 0.1;
    analysis.StereoCorrelation := 0.5;

    suggestions := SuggestMixHeuristic(analysis, doc);
    foundDeEsser := False; foundGate := False;
    for i := 0 to High(suggestions) do
    begin
      if (suggestions[i].Kind = mskDeEsser) and ContainsText(suggestions[i].StripName, 'Vocal') then
        foundDeEsser := True;
      if (suggestions[i].Kind = mskGate) and ContainsText(suggestions[i].StripName, 'Drum') then
        foundGate := True;
    end;
    Check(foundDeEsser, 'bright mix + a vocal strip suggests a de-esser on it');
    Check(foundGate, 'true-peak far above loudness + a drum strip suggests a gate on it');
  finally
    doc.Free;
  end;
end;

procedure RegisterPhase36Tests;
begin
  RegisterTest(GRP, 'DiffSongSpecs: detects a modified section and an added track', Test_DiffSongSpecs_DetectsModifiedSectionAndAddedTrack);
  RegisterTest(GRP, 'MergeLockedAndOutOfScope: preserves a Locked section', Test_MergeLockedAndOutOfScope_PreservesLockedSection);
  RegisterTest(GRP, 'MergeLockedAndOutOfScope: restricts changes to scope', Test_MergeLockedAndOutOfScope_RestrictsToScope);
  RegisterTest(GRP, 'TAIRevisionSession: scoped Propose honours lock/scope despite an uncooperative AI', Test_RevisionSession_ScopedProposeHonoursLockAndScopeEvenWithAnUncooperativeAI);
  RegisterTest(GRP, 'TAIRevisionSession: Apply keeps the revision and marks history accepted', Test_RevisionSession_ApplyKeepsRevisionAndMarksHistoryAccepted);
  RegisterTest(GRP, 'SuggestFrequencyConflicts: separates two colliding strips', Test_SuggestFrequencyConflicts_SeparatesCollidingStrips);
  RegisterTest(GRP, 'SuggestAutomationRide: builds points from section energy', Test_SuggestAutomationRide_BuildsPointsFromSectionEnergy);
  RegisterTest(GRP, 'SuggestMixHeuristic: selects a de-esser and a gate', Test_SuggestMixHeuristic_SelectsDeEsserAndGate);
end;

end.
