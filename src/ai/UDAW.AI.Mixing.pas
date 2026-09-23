unit UDAW.AI.Mixing;
{$I udaw.inc}

{ Phase 27 - AI Mixing Assistant (plan section 41, lines 2477-2524).

  Turns a UDAW.DSP.Analysis result of the current mix (typically the master
  bus, or a stem the caller rendered) into a short list of concrete mix
  suggestions - fader trims, pan moves, one corrective EQ - each carrying a
  plain-English reason exactly like the plan's own worked example ("Bass
  masks kick between 70-95 Hz... Bass EQ: -2.5 dB, 82 Hz, Q 1.3").

  TAIMixingSession owns the Preview / Apply / Reject / Compare workflow the
  plan requires ("never make irreversible changes automatically"): Preview
  performs every suggestion as a normal Phase 5 TDAWCommand (so it is heard
  immediately and is already undo-safe), Compare toggles the whole batch
  on/off, Reject undoes the batch, and Apply simply stops tracking it (the
  edits stay on the undo stack like any other edit - nothing further to do,
  since nothing was ever done outside the command manager). }

interface

uses
  SysUtils, Math, Generics.Collections,
  UDAW.DSP.Analysis, UDAW.DSP.Dynamics,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Mixer.Model, UDAW.Mixer.Commands, UDAW.Mixer.Automation,
  UDAW.Timeline.Time,
  UDAW.Audio.Graph.Nodes;

type
  TMixSuggestionKind = (mskFaderTrim, mskPan, mskCorrectiveEQ, mskGate, mskDeEsser,
    mskAutomationRide);

  TAutomationRidePoint = record
    Bar: Integer;
    GainDb: Double;
  end;

  TMixSuggestion = record
    Kind: TMixSuggestionKind;
    StripName: string;
    DeltaDb: Double;      // mskFaderTrim
    NewPan: Double;       // mskPan
    EQFreqHz: Double;     // mskCorrectiveEQ
    EQQ: Double;
    EQGainDb: Double;
    GateThreshDb: Double; // mskGate
    DeEsserFreqHz: Double; // mskDeEsser
    RidePoints: TArray<TAutomationRidePoint>; // mskAutomationRide
    Reason: string;
  end;

  { One strip's own analysis (caller renders/analyzes each strip's buffer
    separately - AnalyzeStereoBuffer, UDAW.DSP.Analysis - since a single
    master-bus analysis cannot tell which sources are actually colliding). }
  TStripAnalysis = record
    StripName: string;
    Analysis: TAudioAnalysisResult;
  end;

{ Deterministic, offline (no AI provider required - plan rule 26: "the
  complete DAW must function without Internet") heuristic pass. Looks at the
  master-bus analysis and, if it can be matched to a named strip (e.g. a
  "Bass"/"Kick" strip when the low band is heavy), proposes the correction;
  otherwise proposes only master-level trims. Also looks for a de-esser
  candidate (a vocal-named strip when the master reads unusually bright) and
  a gate candidate (a drum/percussion-named strip when true peak sits far
  above integrated loudness, i.e. inconsistent hits or bleed between them). }
function SuggestMixHeuristic(const AAnalysis: TAudioAnalysisResult;
  ADoc: TProjectDocument): TArray<TMixSuggestion>;

{ AIPlan.md section 17 PHASE 7 "Frequency-conflict detection" / "Panning
  suggestions", generalised beyond the single hard-coded bass/kick case
  above: compares every pair of strips the caller analyzed separately and,
  when two strips both concentrate most of their energy in the same band,
  proposes separating them - a small corrective dip on the less dominant
  strip's shared band plus a symmetric pan split so they no longer compete
  for both the same frequencies AND the same position in the stereo field. }
function SuggestFrequencyConflicts(const AStrips: TArray<TStripAnalysis>): TArray<TMixSuggestion>;

{ AIPlan.md section 17 PHASE 7 "Automation recommendations": turns the
  project's own TSongSpec section energy curve (docs/AIPlan.md section 5
  "sections[].energy") into a single suggested master-fader ride, the same
  -6..0 dB mapping UDAW.Composer.Arrangement.ApplyEnergyAutomation uses when
  first building the arrangement - offered here as a reviewable suggestion
  for an EXISTING mix instead of something silently baked in at generation
  time. Returns an empty array if the project carries no song specification
  or fewer than two sections (nothing to ride between). }
function SuggestAutomationRide(ADoc: TProjectDocument): TArray<TMixSuggestion>;

function MixSuggestionToText(const ASuggestion: TMixSuggestion): string;

type
  TAIMixingSession = class
  private
    FDoc: TProjectDocument;
    FCommands: TCommandManager;
    FSuggestions: TArray<TMixSuggestion>;
    FAppliedCount: Integer;    // commands pushed onto the undo stack by Preview
    FShowingOriginal: Boolean;
    function FindStripByName(const AName: string): TMixStrip;
  public
    constructor Create(ADoc: TProjectDocument; ACommands: TCommandManager);

    { Master-bus-only overload, unchanged from Phase 27. }
    procedure Analyze(const AAnalysis: TAudioAnalysisResult); overload;
    { AStripAnalyses: when the caller has analyzed individual strips
      separately (not just the master bus), those are also run through
      SuggestFrequencyConflicts. Master-analysis heuristics
      (SuggestMixHeuristic) and an automation-ride suggestion
      (SuggestAutomationRide, from the project's own TSongSpec) are always
      included either way. }
    procedure Analyze(const AAnalysis: TAudioAnalysisResult;
      const AStripAnalyses: TArray<TStripAnalysis>); overload;
    property Suggestions: TArray<TMixSuggestion> read FSuggestions;
    function HasPendingPreview: Boolean;

    { Applies every current suggestion as real (undo-stack) commands so the
      result can be heard immediately. }
    procedure Preview;
    { Toggles between the previewed recommendation and the original (undoes
      or redoes the batch Preview pushed). Only meaningful while
      HasPendingPreview and no unrelated edit has happened since. }
    procedure CompareToggle;
    { Keeps the previewed edits (they are already on the undo stack like any
      other edit) and clears the session's own tracking. }
    procedure Apply;
    { Undoes every command Preview pushed and clears the session. }
    procedure Reject;
  end;

implementation

uses
  StrUtils,
  UDAW.Composer.SongSpec;

function FStr(AValue: Double): string;
begin
  Result := FloatToStr(AValue, TFormatSettings.Invariant);
end;

{ ================= heuristics ================= }

function SuggestMixHeuristic(const AAnalysis: TAudioAnalysisResult;
  ADoc: TProjectDocument): TArray<TMixSuggestion>;
var
  list: TList<TMixSuggestion>;
  s: TMixSuggestion;
  bassStrip: TMixStrip;

  function FindNamed(const ANeedles: array of string): TMixStrip;
  var
    j, k: Integer;
  begin
    Result := nil;
    for j := 0 to ADoc.Mixer.StripCount - 1 do
      for k := Low(ANeedles) to High(ANeedles) do
        if ContainsText(ADoc.Mixer.GetStrip(j).Name, ANeedles[k]) then
          Exit(ADoc.Mixer.GetStrip(j));
  end;

begin
  list := TList<TMixSuggestion>.Create;
  try
    { true-peak / clipping headroom }
    if (AAnalysis.TruePeakDb > -1.0) or (AAnalysis.ClippingSamples > 0) then
    begin
      FillChar(s, SizeOf(s), 0);
      s.Kind := mskFaderTrim;
      s.StripName := 'Master';
      s.DeltaDb := -1.0 - AAnalysis.TruePeakDb;
      if s.DeltaDb > -0.1 then s.DeltaDb := -0.5;
      s.Reason := Format(
        'True peak is %.1f dBTP (%d clipped sample(s)) - trim the master to restore headroom.',
        [AAnalysis.TruePeakDb, AAnalysis.ClippingSamples]);
      list.Add(s);
    end;

    { loudness vs. a common streaming target }
    if Abs(AAnalysis.IntegratedLufs - (-14.0)) > 1.0 then
    begin
      FillChar(s, SizeOf(s), 0);
      s.Kind := mskFaderTrim;
      s.StripName := 'Master';
      s.DeltaDb := (-14.0) - AAnalysis.IntegratedLufs;
      s.Reason := Format(
        'Integrated loudness is %.1f LUFS; -14 LUFS is a common streaming target.',
        [AAnalysis.IntegratedLufs]);
      list.Add(s);
    end;

    { narrow / mono-collapsed stereo image }
    if AAnalysis.StereoCorrelation > 0.95 then
    begin
      FillChar(s, SizeOf(s), 0);
      s.Kind := mskPan;
      s.StripName := 'Master';
      s.NewPan := 0.0;
      s.Reason := Format(
        'Stereo correlation is %.2f - the mix is nearly mono; consider widening ' +
        'individual sources rather than the master.', [AAnalysis.StereoCorrelation]);
      list.Add(s);
    end;

    { bass masking a kick/bass strip - the plan's own worked example }
    if AAnalysis.LowBandEnergy > 0.50 then
    begin
      bassStrip := FindNamed(['bass', 'sub']);
      if bassStrip <> nil then
      begin
        FillChar(s, SizeOf(s), 0);
        s.Kind := mskCorrectiveEQ;
        s.StripName := bassStrip.Name;
        s.EQFreqHz := 82.0;
        s.EQQ := 1.3;
        s.EQGainDb := -2.5;
        s.Reason := Format(
          'Low-band energy is %.0f%% of the spectrum - bass likely masks the kick ' +
          'around 70-95 Hz.', [AAnalysis.LowBandEnergy * 100.0]);
        list.Add(s);
      end;
    end;

    { dull high end }
    if AAnalysis.HighBandEnergy < 0.04 then
    begin
      FillChar(s, SizeOf(s), 0);
      s.Kind := mskCorrectiveEQ;
      s.StripName := 'Master';
      s.EQFreqHz := 9000.0;
      s.EQQ := 0.7;
      s.EQGainDb := 1.5;
      s.Reason := Format(
        'High-band energy is only %.0f%% of the spectrum - the mix may read as dull; ' +
        'a gentle high shelf can help.', [AAnalysis.HighBandEnergy * 100.0]);
      list.Add(s);
    end;

    { AIPlan.md section 17 PHASE 7 "Effect selection" - harsh/bright mix
      attributed to a vocal strip: sibilance candidate. }
    if AAnalysis.HighBandEnergy > 0.12 then
    begin
      bassStrip := FindNamed(['vocal', 'vox', 'voice', 'lead vox']);
      if bassStrip <> nil then
      begin
        FillChar(s, SizeOf(s), 0);
        s.Kind := mskDeEsser;
        s.StripName := bassStrip.Name;
        s.DeEsserFreqHz := 6500.0;
        s.Reason := Format(
          'High-band energy is %.0f%% of the spectrum - "%s" likely carries sibilance ' +
          'around 6-8 kHz; a de-esser can tame it.', [AAnalysis.HighBandEnergy * 100.0, bassStrip.Name]);
        list.Add(s);
      end;
    end;

    { AIPlan.md section 17 PHASE 7 "Effect selection" - true peak sitting far
      above integrated loudness on a drum/percussion strip suggests
      inconsistent hits or bleed between them: gate candidate. }
    if (AAnalysis.TruePeakDb - AAnalysis.IntegratedLufs) > 20.0 then
    begin
      bassStrip := FindNamed(['drum', 'kit', 'perc']);
      if bassStrip <> nil then
      begin
        FillChar(s, SizeOf(s), 0);
        s.Kind := mskGate;
        s.StripName := bassStrip.Name;
        s.GateThreshDb := -40.0;
        s.Reason := Format(
          'True peak sits %.0f dB above integrated loudness - "%s" may have inconsistent ' +
          'hits or bleed between them; a gate can clean that up.',
          [AAnalysis.TruePeakDb - AAnalysis.IntegratedLufs, bassStrip.Name]);
        list.Add(s);
      end;
    end;

    Result := list.ToArray;
  finally
    list.Free;
  end;
end;

function SuggestFrequencyConflicts(const AStrips: TArray<TStripAnalysis>): TArray<TMixSuggestion>;
type
  TBand = (bandLow, bandMid, bandHigh);
const
  CONFLICT_THRESHOLD = 0.30;
  BAND_FREQ: array[TBand] of Double = (100.0, 1200.0, 6000.0);
var
  list: TList<TMixSuggestion>;
  s: TMixSuggestion;
  i, j: Integer;
  bandI, bandJ: TBand;
  energyI, energyJ: Double;

  function Dominant(const AAnalysis: TAudioAnalysisResult; out AEnergy: Double): TBand;
  begin
    Result := bandLow; AEnergy := AAnalysis.LowBandEnergy;
    if AAnalysis.MidBandEnergy > AEnergy then begin Result := bandMid; AEnergy := AAnalysis.MidBandEnergy; end;
    if AAnalysis.HighBandEnergy > AEnergy then begin Result := bandHigh; AEnergy := AAnalysis.HighBandEnergy; end;
  end;

begin
  list := TList<TMixSuggestion>.Create;
  try
    for i := 0 to High(AStrips) do
    begin
      bandI := Dominant(AStrips[i].Analysis, energyI);
      if energyI < CONFLICT_THRESHOLD then Continue;
      for j := i + 1 to High(AStrips) do
      begin
        bandJ := Dominant(AStrips[j].Analysis, energyJ);
        if (bandJ <> bandI) or (energyJ < CONFLICT_THRESHOLD) then Continue;

        { Both strips concentrate most of their energy in the same band -
          separate them in the stereo field (real pan logic, not the
          center-only mono-collapse case above) ... }
        FillChar(s, SizeOf(s), 0);
        s.Kind := mskPan;
        s.StripName := AStrips[i].StripName;
        s.NewPan := -0.30;
        s.Reason := Format(
          '"%s" and "%s" both concentrate energy in the same band (%.0f%% / %.0f%%) - ' +
          'panning them apart reduces the collision.',
          [AStrips[i].StripName, AStrips[j].StripName, energyI * 100.0, energyJ * 100.0]);
        list.Add(s);

        FillChar(s, SizeOf(s), 0);
        s.Kind := mskPan;
        s.StripName := AStrips[j].StripName;
        s.NewPan := 0.30;
        s.Reason := Format(
          '"%s" and "%s" both concentrate energy in the same band (%.0f%% / %.0f%%) - ' +
          'panning them apart reduces the collision.',
          [AStrips[i].StripName, AStrips[j].StripName, energyI * 100.0, energyJ * 100.0]);
        list.Add(s);

        { ... and dip the less energetic one so the band itself is less
          crowded even when both end up close to center anyway. }
        FillChar(s, SizeOf(s), 0);
        s.Kind := mskCorrectiveEQ;
        s.StripName := AStrips[j].StripName;
        s.EQFreqHz := BAND_FREQ[bandJ];
        s.EQQ := 1.0;
        s.EQGainDb := -2.0;
        s.Reason := Format(
          '"%s" masks "%s" around %.0f Hz - a small corrective cut on "%s" makes room.',
          [AStrips[i].StripName, AStrips[j].StripName, BAND_FREQ[bandJ], AStrips[j].StripName]);
        list.Add(s);
      end;
    end;
    Result := list.ToArray;
  finally
    list.Free;
  end;
end;

function SuggestAutomationRide(ADoc: TProjectDocument): TArray<TMixSuggestion>;
var
  s: TMixSuggestion;
  spec: TSongSpec;
  i: Integer;
  points: TArray<TAutomationRidePoint>;
begin
  Result := [];
  if ADoc = nil then Exit;
  spec := ADoc.SongSpec;
  if (spec = nil) or (spec.Sections.Count < 2) then Exit;

  SetLength(points, spec.Sections.Count);
  for i := 0 to spec.Sections.Count - 1 do
  begin
    points[i].Bar := spec.Sections[i].StartBar;
    points[i].GainDb := -6.0 + Max(0.0, Min(1.0, spec.Sections[i].Energy)) * 6.0;
  end;

  FillChar(s, SizeOf(s), 0);
  s.Kind := mskAutomationRide;
  s.StripName := 'Master';
  s.RidePoints := points;
  s.Reason := Format(
    'The song specification''s %d section(s) carry an energy curve (0..1) that is not yet ' +
    'reflected as a fader ride on the master - riding the fader with each section''s energy ' +
    'keeps quiet sections quiet and loud sections loud without the listener reaching for the volume knob.',
    [spec.Sections.Count]);
  Result := [s];
end;

function MixSuggestionToText(const ASuggestion: TMixSuggestion): string;
begin
  case ASuggestion.Kind of
    mskFaderTrim:
      Result := Format('%s: fader %+.1f dB - %s',
        [ASuggestion.StripName, ASuggestion.DeltaDb, ASuggestion.Reason]);
    mskPan:
      Result := Format('%s: pan -> %.2f - %s',
        [ASuggestion.StripName, ASuggestion.NewPan, ASuggestion.Reason]);
    mskCorrectiveEQ:
      Result := Format('%s: EQ %.1f dB @ %.0f Hz, Q %.1f - %s',
        [ASuggestion.StripName, ASuggestion.EQGainDb, ASuggestion.EQFreqHz,
         ASuggestion.EQQ, ASuggestion.Reason]);
    mskGate:
      Result := Format('%s: gate @ %.1f dB - %s',
        [ASuggestion.StripName, ASuggestion.GateThreshDb, ASuggestion.Reason]);
    mskDeEsser:
      Result := Format('%s: de-esser @ %.0f Hz - %s',
        [ASuggestion.StripName, ASuggestion.DeEsserFreqHz, ASuggestion.Reason]);
    mskAutomationRide:
      Result := Format('%s: fader ride (%d point(s)) - %s',
        [ASuggestion.StripName, Length(ASuggestion.RidePoints), ASuggestion.Reason]);
  else
    Result := ASuggestion.Reason;
  end;
end;

{ ================= TAIMixingSession ================= }

constructor TAIMixingSession.Create(ADoc: TProjectDocument; ACommands: TCommandManager);
begin
  inherited Create;
  FDoc := ADoc;
  FCommands := ACommands;
  FShowingOriginal := False;
end;

function TAIMixingSession.FindStripByName(const AName: string): TMixStrip;
var
  i: Integer;
  s: TMixStrip;
begin
  Result := nil;
  for i := 0 to FDoc.Mixer.StripCount - 1 do
  begin
    s := FDoc.Mixer.GetStrip(i);
    if SameText(s.Name, AName) then Exit(s);
  end;
  for i := 0 to FDoc.Mixer.StripCount - 1 do
  begin
    s := FDoc.Mixer.GetStrip(i);
    if ContainsText(s.Name, AName) then Exit(s);
  end;
end;

procedure TAIMixingSession.Analyze(const AAnalysis: TAudioAnalysisResult);
begin
  Analyze(AAnalysis, nil);
end;

procedure TAIMixingSession.Analyze(const AAnalysis: TAudioAnalysisResult;
  const AStripAnalyses: TArray<TStripAnalysis>);
begin
  if FAppliedCount > 0 then Reject;   // don't stack a second analysis on an unresolved preview
  FSuggestions := SuggestMixHeuristic(AAnalysis, FDoc)
    + SuggestFrequencyConflicts(AStripAnalyses)
    + SuggestAutomationRide(FDoc);
end;

function TAIMixingSession.HasPendingPreview: Boolean;
begin
  Result := FAppliedCount > 0;
end;

procedure TAIMixingSession.Preview;
var
  i, j: Integer;
  s: TMixSuggestion;
  strip: TMixStrip;
  paramStr: string;
  gridCtx: TGridContext;
begin
  if FAppliedCount > 0 then Exit;   // already previewing this batch
  FShowingOriginal := False;
  for i := 0 to High(FSuggestions) do
  begin
    s := FSuggestions[i];
    strip := FindStripByName(s.StripName);
    if strip = nil then Continue;
    case s.Kind of
      mskFaderTrim:
        if FCommands.Perform(TSetMixStripFloatCommand.Create(FDoc, strip.Id, mffFader,
          strip.FaderDb + s.DeltaDb)) then
          Inc(FAppliedCount);
      mskPan:
        if FCommands.Perform(TSetMixStripFloatCommand.Create(FDoc, strip.Id, mffPan,
          s.NewPan)) then
          Inc(FAppliedCount);
      mskCorrectiveEQ:
        begin
          paramStr := Format('type=peaking;freq=%s;q=%s;gaindb=%s',
            [FStr(s.EQFreqHz), FStr(s.EQQ), FStr(s.EQGainDb)]);
          if FCommands.Perform(TAddMixInsertCommand.Create(FDoc, strip.Id,
            NodeKindId(nkBiquad), paramStr, -1, 'Corrective EQ')) then
            Inc(FAppliedCount);
        end;
      mskGate:
        begin
          paramStr := Format('type=%s;thresh=%s;ratio=10;knee=2;attack=2;release=100;hold=20;range=-60',
            [DynamicsModeId(dynGate), FStr(s.GateThreshDb)]);
          if FCommands.Perform(TAddMixInsertCommand.Create(FDoc, strip.Id,
            NodeKindId(nkCompressor), paramStr, -1, 'Noise gate')) then
            Inc(FAppliedCount);
        end;
      mskDeEsser:
        begin
          paramStr := Format('type=%s;thresh=-24;ratio=4;knee=3;attack=1;release=80;scfreq=%s',
            [DynamicsModeId(dynDeEsser), FStr(s.DeEsserFreqHz)]);
          if FCommands.Perform(TAddMixInsertCommand.Create(FDoc, strip.Id,
            NodeKindId(nkCompressor), paramStr, -1, 'De-esser')) then
            Inc(FAppliedCount);
        end;
      mskAutomationRide:
        begin
          gridCtx := FDoc.GridContext;
          for j := 0 to High(s.RidePoints) do
            if FCommands.Perform(TAddAutomationPointCommand.Create(FDoc, strip.Id, apFader,
              BarsToSeconds(gridCtx, s.RidePoints[j].Bar - 1), s.RidePoints[j].GainDb)) then
              Inc(FAppliedCount);
        end;
    end;
  end;
end;

procedure TAIMixingSession.CompareToggle;
var
  i: Integer;
begin
  if FAppliedCount = 0 then Exit;
  if FShowingOriginal then
  begin
    for i := 1 to FAppliedCount do FCommands.Redo;
    FShowingOriginal := False;
  end
  else
  begin
    for i := 1 to FAppliedCount do FCommands.Undo;
    FShowingOriginal := True;
  end;
end;

procedure TAIMixingSession.Apply;
begin
  if FShowingOriginal then CompareToggle;   // land back on the recommendation before committing
  FAppliedCount := 0;
  FSuggestions := [];
end;

procedure TAIMixingSession.Reject;
var
  i: Integer;
begin
  if FShowingOriginal then
  begin
    { the batch is already undone; just drop the redo entries so they can
      never be re-applied by an unrelated future Redo }
    FAppliedCount := 0;
    FSuggestions := [];
    Exit;
  end;
  for i := 1 to FAppliedCount do FCommands.Undo;
  FAppliedCount := 0;
  FSuggestions := [];
end;

end.
