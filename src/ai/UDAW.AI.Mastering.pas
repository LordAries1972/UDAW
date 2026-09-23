unit UDAW.AI.Mastering;
{$I udaw.inc}

{ Phase 28 - AI Mastering Assistant (plan section 42, lines 2526-2567).

  Stages, per the plan: analyze mix -> identify target -> determine headroom
  -> analyze spectrum -> analyze dynamics -> suggest chain -> preview chain
  -> render comparison. SuggestMasteringChain performs the analysis-to-chain
  step (corrective EQ + compressor + the Phase 19 TMasteringChain, hosted as
  three ordinary inserts on the master strip); TAIMasteringSession performs
  the rest: it builds/updates those inserts as real mixer-command edits (so
  they are heard immediately and are undo-safe) and always offers "Original"
  vs "AI Recommendation" via CompareToggle, never committing anything until
  Apply is called. }

interface

uses
  SysUtils, Math,
  UDAW.DSP.Analysis,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Mixer.Model, UDAW.Mixer.Commands,
  UDAW.Audio.Graph.Nodes;

type
  TMasteringSuggestion = record
    HasCorrectiveEQ: Boolean;
    EQFreqHz, EQQ, EQGainDb: Double;
    HasCompressor: Boolean;
    CompThresholdDb, CompRatio, CompAttackMs, CompReleaseMs, CompMakeupDb: Double;
    CeilingDb: Double;
    TargetLufs: Double;
    WidthAmount: Double;
    Reasoning: TArray<string>;
  end;

function SuggestMasteringChain(const AAnalysis: TAudioAnalysisResult): TMasteringSuggestion;
function MasteringSuggestionToText(const ASuggestion: TMasteringSuggestion): string;

type
  { Hosts the suggested chain on the project's master strip as three
    inserts, added (or updated in place, if a previous session already added
    them) in a fixed order: corrective EQ, compressor, then the Phase 19
    mastering node (stereo width + true-peak ceiling + loudness target). }
  TAIMasteringSession = class
  private
    FDoc: TProjectDocument;
    FCommands: TCommandManager;
    FSuggestion: TMasteringSuggestion;
    FEQIndex, FCompIndex, FMasterInsertIndex: Integer;   // -1 = not present
    FAppliedCount: Integer;
    FShowingOriginal: Boolean;
    function Master: TMixStrip;
    function FindInsertIndex(const AKind: string): Integer;
  public
    constructor Create(ADoc: TProjectDocument; ACommands: TCommandManager);

    procedure Analyze(const AAnalysis: TAudioAnalysisResult);
    property Suggestion: TMasteringSuggestion read FSuggestion;
    function HasPendingPreview: Boolean;

    procedure Preview;
    procedure CompareToggle;    // Original <-> AI Recommendation
    procedure Apply;
    procedure Reject;
  end;

implementation

function FStr(AValue: Double): string;
begin
  Result := FloatToStr(AValue, TFormatSettings.Invariant);
end;

{ ================= suggestion heuristic ================= }

function SuggestMasteringChain(const AAnalysis: TAudioAnalysisResult): TMasteringSuggestion;
var
  reasons: TArray<string>;

  procedure Add(const AText: string);
  begin
    SetLength(reasons, Length(reasons) + 1);
    reasons[High(reasons)] := AText;
  end;

begin
  FillChar(Result, SizeOf(Result), 0);
  SetLength(reasons, 0);

  { target loudness: -14 LUFS is a broadly-applicable streaming target; only
    call it out if the mix is meaningfully off it }
  Result.TargetLufs := -14.0;
  if Abs(AAnalysis.IntegratedLufs - Result.TargetLufs) > 0.5 then
    Add(Format('Mix is at %.1f LUFS integrated; targeting %.0f LUFS.',
      [AAnalysis.IntegratedLufs, Result.TargetLufs]))
  else
    Add(Format('Mix is already close to the %.0f LUFS target (%.1f LUFS).',
      [Result.TargetLufs, AAnalysis.IntegratedLufs]));

  { headroom / ceiling }
  Result.CeilingDb := -1.0;
  if AAnalysis.TruePeakDb > Result.CeilingDb then
    Add(Format('True peak is %.1f dBTP - limiting to a %.1f dBTP ceiling.',
      [AAnalysis.TruePeakDb, Result.CeilingDb]))
  else
    Add(Format('Headroom to the %.1f dBTP ceiling is already healthy (%.1f dBTP).',
      [Result.CeilingDb, AAnalysis.TruePeakDb]));

  { stereo processor: nudge width from correlation, never past a sane range }
  Result.WidthAmount := 1.0 + Max(-0.3, Min(0.3, (0.5 - AAnalysis.StereoCorrelation) * 0.6));
  if Abs(Result.WidthAmount - 1.0) > 0.02 then
    Add(Format('Stereo correlation %.2f -> width factor %.2f.',
      [AAnalysis.StereoCorrelation, Result.WidthAmount]));

  { corrective EQ: only the two most common mastering-stage issues }
  if AAnalysis.LowBandEnergy > 0.50 then
  begin
    Result.HasCorrectiveEQ := True;
    Result.EQFreqHz := 100.0;
    Result.EQQ := 0.9;
    Result.EQGainDb := -1.5;
    Add('Low end is heavy - gentle corrective cut around 100 Hz.');
  end
  else if AAnalysis.HighBandEnergy < 0.04 then
  begin
    Result.HasCorrectiveEQ := True;
    Result.EQFreqHz := 10000.0;
    Result.EQQ := 0.7;
    Result.EQGainDb := 1.0;
    Add('High end is thin - gentle high-shelf lift around 10 kHz.');
  end;

  { dynamics: only add glue compression if the mix has real dynamic range to
    tame; an already-squashed mix gets no further compression here }
  if AAnalysis.CrestFactorDb > 14.0 then
  begin
    Result.HasCompressor := True;
    Result.CompThresholdDb := AAnalysis.RmsDb + 6.0;
    Result.CompRatio := 2.0;
    Result.CompAttackMs := 15.0;
    Result.CompReleaseMs := 150.0;
    Result.CompMakeupDb := 1.5;
    Add(Format('Crest factor is %.1f dB - gentle 2:1 glue compression to control peaks.',
      [AAnalysis.CrestFactorDb]));
  end
  else
    Add(Format('Crest factor is %.1f dB - dynamics already controlled, no extra compression.',
      [AAnalysis.CrestFactorDb]));

  Result.Reasoning := reasons;
end;

function MasteringSuggestionToText(const ASuggestion: TMasteringSuggestion): string;
var
  sb: TStringBuilder;
  s: string;
begin
  sb := TStringBuilder.Create;
  try
    for s in ASuggestion.Reasoning do
      sb.AppendLine('- ' + s);
    if ASuggestion.HasCorrectiveEQ then
      sb.AppendLine(Format('  Corrective EQ: %.1f dB @ %.0f Hz, Q %.1f',
        [ASuggestion.EQGainDb, ASuggestion.EQFreqHz, ASuggestion.EQQ]));
    if ASuggestion.HasCompressor then
      sb.AppendLine(Format('  Compressor: thresh %.1f dB, ratio %.1f:1, attack %.0f ms, release %.0f ms, makeup %.1f dB',
        [ASuggestion.CompThresholdDb, ASuggestion.CompRatio, ASuggestion.CompAttackMs,
         ASuggestion.CompReleaseMs, ASuggestion.CompMakeupDb]));
    sb.AppendLine(Format('  Mastering stage: ceiling %.1f dBTP, target %.0f LUFS, width %.2f',
      [ASuggestion.CeilingDb, ASuggestion.TargetLufs, ASuggestion.WidthAmount]));
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ ================= TAIMasteringSession ================= }

constructor TAIMasteringSession.Create(ADoc: TProjectDocument; ACommands: TCommandManager);
begin
  inherited Create;
  FDoc := ADoc;
  FCommands := ACommands;
  FEQIndex := -1;
  FCompIndex := -1;
  FMasterInsertIndex := -1;
end;

function TAIMasteringSession.Master: TMixStrip;
begin
  Result := FDoc.Mixer.MasterStrip;
end;

function TAIMasteringSession.FindInsertIndex(const AKind: string): Integer;
var
  i: Integer;
  m: TMixStrip;
begin
  Result := -1;
  m := Master;
  if m = nil then Exit;
  for i := 0 to m.InsertCount - 1 do
    if SameText(m.GetInsert(i).Kind, AKind) then Exit(i);
end;

procedure TAIMasteringSession.Analyze(const AAnalysis: TAudioAnalysisResult);
begin
  if FAppliedCount > 0 then Reject;
  FSuggestion := SuggestMasteringChain(AAnalysis);
end;

function TAIMasteringSession.HasPendingPreview: Boolean;
begin
  Result := FAppliedCount > 0;
end;

procedure TAIMasteringSession.Preview;
var
  m: TMixStrip;
  eqParams, compParams, masterParams: string;
  idx: Integer;
begin
  m := Master;
  if m = nil then Exit;
  if FAppliedCount > 0 then Exit;
  FShowingOriginal := False;

  if FSuggestion.HasCorrectiveEQ then
  begin
    eqParams := Format('type=peaking;freq=%s;q=%s;gaindb=%s',
      [FStr(FSuggestion.EQFreqHz), FStr(FSuggestion.EQQ), FStr(FSuggestion.EQGainDb)]);
    idx := FindInsertIndex(NodeKindId(nkBiquad));
    if idx >= 0 then
    begin
      FEQIndex := idx;
      if FCommands.Perform(TSetMixInsertParamsCommand.Create(FDoc, m.Id, idx, eqParams)) then
        Inc(FAppliedCount);
    end
    else if FCommands.Perform(TAddMixInsertCommand.Create(FDoc, m.Id, NodeKindId(nkBiquad), eqParams, -1, 'Mastering EQ')) then
    begin
      FEQIndex := FindInsertIndex(NodeKindId(nkBiquad));
      Inc(FAppliedCount);
    end;
  end;

  if FSuggestion.HasCompressor then
  begin
    compParams := Format('type=compressor;thresh=%s;ratio=%s;attack=%s;release=%s;makeup=%s',
      [FStr(FSuggestion.CompThresholdDb), FStr(FSuggestion.CompRatio),
       FStr(FSuggestion.CompAttackMs), FStr(FSuggestion.CompReleaseMs),
       FStr(FSuggestion.CompMakeupDb)]);
    idx := FindInsertIndex(NodeKindId(nkCompressor));
    if idx >= 0 then
    begin
      FCompIndex := idx;
      if FCommands.Perform(TSetMixInsertParamsCommand.Create(FDoc, m.Id, idx, compParams)) then
        Inc(FAppliedCount);
    end
    else if FCommands.Perform(TAddMixInsertCommand.Create(FDoc, m.Id, NodeKindId(nkCompressor), compParams, -1, 'Mastering compressor')) then
    begin
      FCompIndex := FindInsertIndex(NodeKindId(nkCompressor));
      Inc(FAppliedCount);
    end;
  end;

  masterParams := Format('ceiling=%s;target=%s;width=%s',
    [FStr(FSuggestion.CeilingDb), FStr(FSuggestion.TargetLufs), FStr(FSuggestion.WidthAmount)]);
  idx := FindInsertIndex(NodeKindId(nkMastering));
  if idx >= 0 then
  begin
    FMasterInsertIndex := idx;
    if FCommands.Perform(TSetMixInsertParamsCommand.Create(FDoc, m.Id, idx, masterParams)) then
      Inc(FAppliedCount);
  end
  else if FCommands.Perform(TAddMixInsertCommand.Create(FDoc, m.Id, NodeKindId(nkMastering), masterParams, -1, 'Mastering')) then
  begin
    FMasterInsertIndex := FindInsertIndex(NodeKindId(nkMastering));
    Inc(FAppliedCount);
  end;
end;

procedure TAIMasteringSession.CompareToggle;
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

procedure TAIMasteringSession.Apply;
begin
  if FShowingOriginal then CompareToggle;
  FAppliedCount := 0;
end;

procedure TAIMasteringSession.Reject;
var
  i: Integer;
begin
  if not FShowingOriginal then
    for i := 1 to FAppliedCount do FCommands.Undo;
  FAppliedCount := 0;
end;

end.
