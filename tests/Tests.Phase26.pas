unit Tests.Phase26;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 26 acceptance tests - the AI structured tool-command interface
  (UDAW.AI.ToolCommands): fenced-block parsing, name/alias resolution,
  validation, and dispatch against a real (in-memory) TProjectDocument /
  TCommandManager, so every mutating tool is verified to go through the
  normal undo-safe command path rather than touching the model directly. }

interface

procedure RegisterPhase26Tests;

implementation

uses
  SysUtils,
  UDAW.Testing,
  UDAW.AI.ToolCommands,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Mixer.Model;

const
  GRP = 'phase26.ai_tools';

procedure Test_ParseAIToolCalls_ExtractsFencedBlock;
var
  calls: TArray<TAIToolCall>;
begin
  calls := ParseAIToolCalls(
    'Sure, I''ll lower the drums.' + sLineBreak +
    '```tool' + sLineBreak +
    '{"command":"SetGain","track":"drums","delta_db":-2}' + sLineBreak +
    '```' + sLineBreak +
    'Let me know how that sounds.');
  CheckEqualInt(1, Length(calls), 'one tool block found');
  Check(calls[0].HasKind and (calls[0].Kind = atkSetGain), 'parsed as SetGain');
  CheckEqualStr('drums', calls[0].TrackName, 'track name parsed');
  CheckNear(-2.0, calls[0].DeltaDb, 1.0E-9, 'delta_db parsed');
end;

procedure Test_ParseAIToolCalls_MultipleBlocksAndGarbageIgnored;
var
  calls: TArray<TAIToolCall>;
begin
  calls := ParseAIToolCalls(
    '```tool' + sLineBreak + '{"command":"GetProjectInfo"}' + sLineBreak + '```' + sLineBreak +
    'some prose in between' + sLineBreak +
    '```tool' + sLineBreak + 'not json at all' + sLineBreak + '```' + sLineBreak +
    '```tool' + sLineBreak + '{"command":"SetTempo","bpm":128}' + sLineBreak + '```');
  CheckEqualInt(2, Length(calls), 'malformed block is skipped, the two valid ones kept');
  Check(calls[0].Kind = atkGetProjectInfo, 'first block');
  Check(calls[1].Kind = atkSetTempo, 'second block');
  CheckNear(128.0, calls[1].TempoBpm, 1.0E-9, 'bpm parsed');
end;

procedure Test_ParseAIToolCalls_NoFenceReturnsEmpty;
begin
  CheckEqualInt(0, Length(ParseAIToolCalls('just a normal chat reply, no tool calls here')),
    'no fenced block => no calls');
end;

procedure Test_AIToolKindFromId_AcceptsPlanAliases;
var
  k: TAIToolKind;
begin
  Check(AIToolKindFromId('SetGain', k) and (k = atkSetGain), 'canonical name');
  Check(AIToolKindFromId('set_track_gain', k) and (k = atkSetGain),
    'plan section 35''s own worked-example spelling');
  Check(AIToolKindFromId('set_track_pan', k) and (k = atkSetPan), 'pan alias');
  Check(AIToolKindFromId('add_track', k) and (k = atkAddTrack), 'add_track alias');
  CheckFalse(AIToolKindFromId('DeleteEverything', k), 'unknown command rejected');
end;

procedure Test_IsDestructiveTool_Classification;
begin
  Check(IsDestructiveTool(atkAddTrack), 'AddTrack is destructive');
  Check(IsDestructiveTool(atkSetTempo), 'SetTempo is destructive');
  Check(IsDestructiveTool(atkExportProject), 'ExportProject is destructive');
  CheckFalse(IsDestructiveTool(atkSetGain), 'SetGain is a normal reversible edit');
  CheckFalse(IsDestructiveTool(atkGetProjectInfo), 'a Get* tool is never destructive');
  Check(IsReadOnlyTool(atkGetMixerState), 'GetMixerState is read-only');
  CheckFalse(IsReadOnlyTool(atkSetPan), 'SetPan mutates, so it is not read-only');
end;

procedure Test_ValidateToolCall_RangeChecks;
var
  c: TAIToolCall;
  err: string;
begin
  FillChar(c, SizeOf(c), 0);
  c.HasKind := True; c.Kind := atkSetPan; c.HasTrackName := True; c.TrackName := 'Lead';
  c.HasPanValue := True; c.PanValue := 1.5;
  CheckFalse(ValidateToolCall(c, err), 'pan out of range rejected');

  c.PanValue := 0.5;
  Check(ValidateToolCall(c, err), 'in-range pan accepted');

  FillChar(c, SizeOf(c), 0);
  c.HasKind := True; c.Kind := atkSetTempo; c.HasTempoBpm := True; c.TempoBpm := 5;
  CheckFalse(ValidateToolCall(c, err), 'tempo below 20 bpm rejected');

  FillChar(c, SizeOf(c), 0);
  c.HasKind := True; c.Kind := atkSetGain; c.HasTrackName := True; c.TrackName := 'Bass';
  CheckFalse(ValidateToolCall(c, err), 'SetGain with neither delta_db nor gain_db rejected');
end;

procedure Test_Dispatcher_SetGain_GoesThroughUndoStack;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  dispatcher: TAIToolDispatcher;
  strip: TMixStrip;
  call: TAIToolCall;
  resultText: string;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  try
    strip := doc.Mixer.AddStrip(skAudioTrack, 'Drums');
    strip.FaderDb := 0.0;

    FillChar(call, SizeOf(call), 0);
    call.HasKind := True; call.Kind := atkSetGain;
    call.HasTrackName := True; call.TrackName := 'drums';   // case-insensitive match
    call.HasDeltaDb := True; call.DeltaDb := -2.0;

    dispatcher := TAIToolDispatcher.Create(doc, cmds);
    try
      Check(dispatcher.Execute(call, resultText), 'SetGain executed');
    finally
      dispatcher.Free;
    end;

    CheckNear(-2.0, strip.FaderDb, 1.0E-9, 'fader actually moved');
    Check(cmds.CanUndo, 'the edit is on the undo stack');
    cmds.Undo;
    CheckNear(0.0, strip.FaderDb, 1.0E-9, 'undo restores the original fader');
  finally
    cmds.Free;
    doc.Free;
  end;
end;

procedure Test_Dispatcher_GetProjectInfo_ReturnsJSON;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  dispatcher: TAIToolDispatcher;
  call: TAIToolCall;
  resultText: string;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  try
    FillChar(call, SizeOf(call), 0);
    call.HasKind := True; call.Kind := atkGetProjectInfo;
    dispatcher := TAIToolDispatcher.Create(doc, cmds);
    try
      Check(dispatcher.Execute(call, resultText), 'GetProjectInfo executed');
    finally
      dispatcher.Free;
    end;
    Check(Pos('"tempo_bpm"', resultText) > 0, 'JSON carries tempo_bpm');
    CheckFalse(cmds.CanUndo, 'a read-only tool pushes nothing onto the undo stack');
  finally
    cmds.Free;
    doc.Free;
  end;
end;

procedure Test_Dispatcher_UnknownTrack_FailsCleanly;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  dispatcher: TAIToolDispatcher;
  call: TAIToolCall;
  resultText: string;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  try
    FillChar(call, SizeOf(call), 0);
    call.HasKind := True; call.Kind := atkSetGain;
    call.HasTrackName := True; call.TrackName := 'nonexistent';
    call.HasDeltaDb := True; call.DeltaDb := -2.0;
    dispatcher := TAIToolDispatcher.Create(doc, cmds);
    try
      CheckFalse(dispatcher.Execute(call, resultText), 'no such strip => False, not an exception');
    finally
      dispatcher.Free;
    end;
    Check(resultText <> '', 'explains why it failed');
  finally
    cmds.Free;
    doc.Free;
  end;
end;

procedure RegisterPhase26Tests;
begin
  RegisterTest(GRP, 'ParseAIToolCalls: extracts a fenced tool block', Test_ParseAIToolCalls_ExtractsFencedBlock);
  RegisterTest(GRP, 'ParseAIToolCalls: multiple blocks, malformed one skipped', Test_ParseAIToolCalls_MultipleBlocksAndGarbageIgnored);
  RegisterTest(GRP, 'ParseAIToolCalls: no fence => no calls', Test_ParseAIToolCalls_NoFenceReturnsEmpty);
  RegisterTest(GRP, 'AIToolKindFromId: accepts plan-example aliases', Test_AIToolKindFromId_AcceptsPlanAliases);
  RegisterTest(GRP, 'IsDestructiveTool/IsReadOnlyTool classification', Test_IsDestructiveTool_Classification);
  RegisterTest(GRP, 'ValidateToolCall: range and required-field checks', Test_ValidateToolCall_RangeChecks);
  RegisterTest(GRP, 'Dispatcher: SetGain goes through the undo stack', Test_Dispatcher_SetGain_GoesThroughUndoStack);
  RegisterTest(GRP, 'Dispatcher: GetProjectInfo returns JSON, no undo entry', Test_Dispatcher_GetProjectInfo_ReturnsJSON);
  RegisterTest(GRP, 'Dispatcher: unknown track fails cleanly', Test_Dispatcher_UnknownTrack_FailsCleanly);
end;

end.
