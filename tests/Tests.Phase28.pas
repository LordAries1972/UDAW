unit Tests.Phase28;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 28 acceptance tests - the AI mastering assistant (UDAW.AI.Mastering):
  the heuristic chain-suggestion function against known analysis inputs, and
  the Preview/Compare/Apply/Reject session against a real in-memory
  TProjectDocument/TCommandManager master strip. }

interface

procedure RegisterPhase28Tests;

implementation

uses
  SysUtils,
  UDAW.Testing,
  UDAW.DSP.Analysis,
  UDAW.AI.Mastering,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Mixer.Model,
  UDAW.Audio.Graph.Nodes;

const
  GRP = 'phase28.ai_mastering';

procedure Test_SuggestMasteringChain_HotPeakGetsCeiling;
var
  analysis: TAudioAnalysisResult;
  s: TMasteringSuggestion;
begin
  analysis := TAudioAnalysisResult.Empty;
  analysis.TruePeakDb := 1.0;
  analysis.IntegratedLufs := -14.0;
  analysis.StereoCorrelation := 0.5;
  analysis.LowBandEnergy := 0.2;
  analysis.HighBandEnergy := 0.2;
  analysis.CrestFactorDb := 8.0;
  s := SuggestMasteringChain(analysis);
  CheckNear(-1.0, s.CeilingDb, 1.0E-9, 'ceiling is always -1 dBTP');
  Check(Length(s.Reasoning) > 0, 'reasoning is never empty');
  CheckFalse(s.HasCompressor, 'a crest factor of 8 dB is already controlled - no extra compression');
end;

procedure Test_SuggestMasteringChain_HeavyLowEndGetsCorrectiveEQ;
var
  analysis: TAudioAnalysisResult;
  s: TMasteringSuggestion;
begin
  analysis := TAudioAnalysisResult.Empty;
  analysis.TruePeakDb := -3.0;
  analysis.IntegratedLufs := -14.0;
  analysis.StereoCorrelation := 0.5;
  analysis.LowBandEnergy := 0.6;
  analysis.HighBandEnergy := 0.2;
  analysis.CrestFactorDb := 8.0;
  s := SuggestMasteringChain(analysis);
  Check(s.HasCorrectiveEQ, 'heavy low end triggers a corrective EQ suggestion');
  Check(s.EQGainDb < 0, 'the correction is a cut, not a boost');
end;

procedure Test_SuggestMasteringChain_VeryDynamicMixGetsGentleGlue;
var
  analysis: TAudioAnalysisResult;
  s: TMasteringSuggestion;
begin
  analysis := TAudioAnalysisResult.Empty;
  analysis.TruePeakDb := -6.0;
  analysis.IntegratedLufs := -20.0;
  analysis.StereoCorrelation := 0.5;
  analysis.LowBandEnergy := 0.2;
  analysis.HighBandEnergy := 0.2;
  analysis.CrestFactorDb := 18.0;
  analysis.RmsDb := -20.0;
  s := SuggestMasteringChain(analysis);
  Check(s.HasCompressor, 'high crest factor triggers gentle glue compression');
  CheckNear(2.0, s.CompRatio, 1.0E-9, 'the suggested ratio is gentle (2:1)');
end;

procedure Test_MasteringSuggestionToText_NotEmpty;
var
  analysis: TAudioAnalysisResult;
begin
  analysis := TAudioAnalysisResult.Empty;
  analysis.IntegratedLufs := -14.0;
  Check(Length(MasteringSuggestionToText(SuggestMasteringChain(analysis))) > 0,
    'produces a human-readable summary');
end;

procedure Test_MasteringSession_PreviewAddsMasterInsertAndIsUndoSafe;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  session: TAIMasteringSession;
  master: TMixStrip;
  analysis: TAudioAnalysisResult;
  insertsBefore: Integer;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  try
    master := doc.Mixer.MasterStrip;
    insertsBefore := master.InsertCount;

    analysis := TAudioAnalysisResult.Empty;
    analysis.TruePeakDb := 1.0;
    analysis.IntegratedLufs := -20.0;
    analysis.StereoCorrelation := 0.5;
    analysis.LowBandEnergy := 0.6;
    analysis.HighBandEnergy := 0.2;
    analysis.CrestFactorDb := 8.0;

    session := TAIMasteringSession.Create(doc, cmds);
    try
      session.Analyze(analysis);
      session.Preview;
      Check(session.HasPendingPreview, 'preview performed at least one command');
      Check(master.InsertCount > insertsBefore, 'the mastering/EQ chain was actually added to the master strip');

      { undo/redo replaces the whole mixer model, so the strip must be re-fetched }
      session.CompareToggle;   // -> Original
      master := doc.Mixer.MasterStrip;
      CheckEqualInt(insertsBefore, master.InsertCount, 'comparing to Original removes the previewed inserts');

      session.CompareToggle;   // -> AI Recommendation
      master := doc.Mixer.MasterStrip;
      Check(master.InsertCount > insertsBefore, 'comparing back restores the previewed inserts');

      session.Reject;
      master := doc.Mixer.MasterStrip;
      CheckEqualInt(insertsBefore, master.InsertCount, 'reject leaves the master strip exactly as it was');
      CheckFalse(session.HasPendingPreview, 'reject clears the session');
    finally
      session.Free;
    end;
  finally
    cmds.Free;
    doc.Free;
  end;
end;

procedure RegisterPhase28Tests;
begin
  RegisterTest(GRP, 'SuggestMasteringChain: hot true peak, controlled dynamics', Test_SuggestMasteringChain_HotPeakGetsCeiling);
  RegisterTest(GRP, 'SuggestMasteringChain: heavy low end -> corrective EQ cut', Test_SuggestMasteringChain_HeavyLowEndGetsCorrectiveEQ);
  RegisterTest(GRP, 'SuggestMasteringChain: very dynamic mix -> gentle glue compression', Test_SuggestMasteringChain_VeryDynamicMixGetsGentleGlue);
  RegisterTest(GRP, 'MasteringSuggestionToText: produces readable output', Test_MasteringSuggestionToText_NotEmpty);
  RegisterTest(GRP, 'TAIMasteringSession: Preview/Compare/Reject on the master strip', Test_MasteringSession_PreviewAddsMasterInsertAndIsUndoSafe);
end;

end.
