unit Tests.Phase27;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 27 acceptance tests - local audio analysis (UDAW.DSP.Analysis) and
  the AI mixing assistant (UDAW.AI.Mixing). Analysis is exercised against
  small synthetic buffers (silence, a full-scale square wave, a clean sine)
  built in-process - no fixture audio files needed, and the expected results
  are known exactly. The mixing session is exercised against a real
  in-memory TProjectDocument/TCommandManager so Preview/Compare/Apply/Reject
  are verified to be actual (undo-safe) command-manager operations. }

interface

procedure RegisterPhase27Tests;

implementation

uses
  SysUtils, Math,
  UDAW.Testing,
  UDAW.Audio.Types,
  UDAW.DSP.Analysis,
  UDAW.AI.Mixing,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Mixer.Model;

const
  GRP = 'phase27.ai_mixing';
  SR = 48000;

function MakeSilence(AFrames: Integer): TAudioSampleArray;
begin
  SetLength(Result, AFrames);
  FillChar(Result[0], AFrames * SizeOf(Single), 0);
end;

function MakeSine(AFrames: Integer; AFreqHz, AAmplitude: Double): TAudioSampleArray;
var
  i: Integer;
begin
  SetLength(Result, AFrames);
  for i := 0 to AFrames - 1 do
    Result[i] := Single(AAmplitude * Sin(2 * Pi * AFreqHz * i / SR));
end;

procedure Test_AnalyzeStereoBuffer_Silence;
var
  l, r: TAudioSampleArray;
  res: TAudioAnalysisResult;
begin
  l := MakeSilence(SR);
  r := MakeSilence(SR);
  res := AnalyzeStereoBuffer(l, r, SR);
  CheckEqualInt(SR, res.Frames, 'frame count reported');
  CheckNear(100.0, res.SilencePercent, 0.5, 'a fully silent buffer is ~100% silence');
  CheckEqualInt(0, res.ClippingSamples, 'silence never clips');
end;

procedure Test_AnalyzeStereoBuffer_ClippedSquareWave;
var
  l, r: TAudioSampleArray;
  i: Integer;
  res: TAudioAnalysisResult;
begin
  SetLength(l, SR); SetLength(r, SR);
  for i := 0 to SR - 1 do
  begin
    if (i mod 100) < 50 then l[i] := 1.0 else l[i] := -1.0;
    r[i] := l[i];
  end;
  res := AnalyzeStereoBuffer(l, r, SR);
  Check(res.ClippingSamples > 0, 'full-scale square wave clips');
  CheckNear(0.0, res.SamplePeakDb, 0.01, 'full-scale peak reads ~0 dBFS');
  Check(res.StereoCorrelation > 0.9, 'identical L/R is highly correlated');
end;

procedure Test_AnalyzeStereoBuffer_DetectsPitch;
var
  l, r: TAudioSampleArray;
  res: TAudioAnalysisResult;
begin
  l := MakeSine(SR, 220.0, 0.5);   // A3
  r := Copy(l);
  res := AnalyzeStereoBuffer(l, r, SR);
  Check(res.DetectedPitchHz > 0, 'a clean sine yields a detected pitch');
  CheckNear(220.0, res.DetectedPitchHz, 3.0, 'detected pitch is close to 220 Hz');
end;

procedure Test_AnalysisResultToJSONString_CarriesPlanFields;
var
  res: TAudioAnalysisResult;
  json: string;
begin
  res := TAudioAnalysisResult.Empty;
  res.IntegratedLufs := -15.4;
  res.TruePeakDb := -0.6;
  res.LowBandEnergy := 0.42;
  res.StereoCorrelation := 0.78;
  res.ClippingSamples := 0;
  json := AnalysisResultToJSONString(res);
  { field names match the plan's own worked example (section 40) exactly }
  Check(Pos('"integrated_lufs"', json) > 0, 'integrated_lufs present');
  Check(Pos('"true_peak"', json) > 0, 'true_peak present');
  Check(Pos('"low_band_energy"', json) > 0, 'low_band_energy present');
  Check(Pos('"stereo_correlation"', json) > 0, 'stereo_correlation present');
  Check(Pos('"clipping_samples"', json) > 0, 'clipping_samples present');
end;

procedure Test_SuggestMixHeuristic_FlagsBassMasking;
var
  doc: TProjectDocument;
  analysis: TAudioAnalysisResult;
  suggestions: TArray<TMixSuggestion>;
  i: Integer;
  foundEQ: Boolean;
begin
  doc := TProjectDocument.CreateNew;
  try
    doc.Mixer.AddStrip(skAudioTrack, 'Bass');
    analysis := TAudioAnalysisResult.Empty;
    analysis.LowBandEnergy := 0.6;
    analysis.IntegratedLufs := -14.0;
    analysis.TruePeakDb := -3.0;
    analysis.StereoCorrelation := 0.5;
    analysis.HighBandEnergy := 0.2;
    suggestions := SuggestMixHeuristic(analysis, doc);
    foundEQ := False;
    for i := 0 to High(suggestions) do
      if (suggestions[i].Kind = mskCorrectiveEQ) and SameText(suggestions[i].StripName, 'Bass') then
        foundEQ := True;
    Check(foundEQ, 'heavy low-band energy + a Bass strip => a corrective EQ suggestion on it');
  finally
    doc.Free;
  end;
end;

procedure Test_MixingSession_PreviewApplyReject;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  session: TAIMixingSession;
  strip: TMixStrip;
  analysis: TAudioAnalysisResult;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  try
    strip := doc.Mixer.MasterStrip;
    strip.FaderDb := 0.0;

    analysis := TAudioAnalysisResult.Empty;
    analysis.TruePeakDb := 2.0;      // well over ceiling -> forces a master trim suggestion
    analysis.ClippingSamples := 100;
    analysis.IntegratedLufs := -14.0;
    analysis.StereoCorrelation := 0.5;
    analysis.LowBandEnergy := 0.2;
    analysis.HighBandEnergy := 0.2;

    session := TAIMixingSession.Create(doc, cmds);
    try
      session.Analyze(analysis);
      Check(Length(session.Suggestions) > 0, 'a hot true peak produces a suggestion');

      session.Preview;
      Check(session.HasPendingPreview, 'preview applied at least one command');
      Check(strip.FaderDb < 0.0, 'master fader was actually trimmed down');

      session.Reject;
      CheckFalse(session.HasPendingPreview, 'reject clears the pending preview');
      CheckNear(0.0, strip.FaderDb, 1.0E-9, 'reject restores the original fader');
    finally
      session.Free;
    end;
  finally
    cmds.Free;
    doc.Free;
  end;
end;

procedure Test_MixingSession_ApplyKeepsEditOnUndoStack;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  session: TAIMixingSession;
  strip: TMixStrip;
  analysis: TAudioAnalysisResult;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  try
    strip := doc.Mixer.MasterStrip;
    strip.FaderDb := 0.0;

    analysis := TAudioAnalysisResult.Empty;
    analysis.TruePeakDb := 2.0;
    analysis.IntegratedLufs := -14.0;
    analysis.StereoCorrelation := 0.5;
    analysis.LowBandEnergy := 0.2;
    analysis.HighBandEnergy := 0.2;

    session := TAIMixingSession.Create(doc, cmds);
    try
      session.Analyze(analysis);
      session.Preview;
      session.Apply;
      CheckFalse(session.HasPendingPreview, 'apply clears session tracking');
      Check(strip.FaderDb < 0.0, 'the trim survives Apply');
      Check(cmds.CanUndo, 'the edit is still a normal, undoable command');
    finally
      session.Free;
    end;
  finally
    cmds.Free;
    doc.Free;
  end;
end;

procedure RegisterPhase27Tests;
begin
  RegisterTest(GRP, 'AnalyzeStereoBuffer: silent buffer', Test_AnalyzeStereoBuffer_Silence);
  RegisterTest(GRP, 'AnalyzeStereoBuffer: clipped square wave', Test_AnalyzeStereoBuffer_ClippedSquareWave);
  RegisterTest(GRP, 'AnalyzeStereoBuffer: detects a clean sine''s pitch', Test_AnalyzeStereoBuffer_DetectsPitch);
  RegisterTest(GRP, 'AnalysisResultToJSONString: carries the plan''s example fields', Test_AnalysisResultToJSONString_CarriesPlanFields);
  RegisterTest(GRP, 'SuggestMixHeuristic: flags bass masking a Bass strip', Test_SuggestMixHeuristic_FlagsBassMasking);
  RegisterTest(GRP, 'TAIMixingSession: Preview/Apply/Reject workflow', Test_MixingSession_PreviewApplyReject);
  RegisterTest(GRP, 'TAIMixingSession: Apply keeps the edit on the undo stack', Test_MixingSession_ApplyKeepsEditOnUndoStack);
end;

end.
