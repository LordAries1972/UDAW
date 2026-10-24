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
  SysUtils, Windows,
  UDAW.Testing,
  UDAW.AI.ToolCommands, UDAW.AI.MCPServer, UDAW.SystemInfo, UDAW.UI.Display, UDAW.GL.Canvas,
  UDAW.Project.Document, UDAW.Project.Commands, UDAW.Project.Serialization,
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

type
  { stands in for the window: records the call it was handed }
  TFakeUI = class
    LastKind: TAIToolKind;
    Calls: Integer;
    function Handle(const ACall: TAIToolCall): string;
  end;

function TFakeUI.Handle(const ACall: TAIToolCall): string;
begin
  LastKind := ACall.Kind;
  Inc(Calls);
  if ACall.Kind = atkRunCommand then
    Result := '{"error":"refused for the test"}'
  else
    Result := '{"ok":true}';
end;

procedure Test_ParseAIToolCalls_ApplicationTools;
var
  calls: TArray<TAIToolCall>;
begin
  calls := ParseAIToolCalls(
    '```tool' + sLineBreak + '{"command":"SelectClips","clip_ids":[3,5,8]}' + sLineBreak + '```' +
    '```tool' + sLineBreak + '{"command":"ClampClips","clip_ids":[5],"mode":"next"}' + sLineBreak + '```' +
    '```tool' + sLineBreak + '{"command":"RunCommand","menu_path":"Timeline > Edit > Clamp to > Clamp to Last Segment"}' + sLineBreak + '```' +
    '```tool' + sLineBreak + '{"command":"SetRange","start_sec":1.5,"end_sec":4}' + sLineBreak + '```');
  CheckEqualInt(4, Length(calls), 'four application tool blocks parsed');
  Check(calls[0].Kind = atkSelectClips, 'SelectClips');
  CheckEqualInt(3, Length(calls[0].ClipIds), 'three clip ids');
  CheckEqualInt(8, calls[0].ClipIds[2], 'ids in order');
  Check(calls[1].Kind = atkClampClips, 'ClampClips');
  CheckEqualStr('next', calls[1].Mode, 'mode parsed');
  Check(calls[2].Kind = atkRunCommand, 'RunCommand');
  Check(Pos('Clamp to Last Segment', calls[2].CommandPath) > 0, 'menu path parsed');
  Check(calls[3].Kind = atkSetRange, 'SetRange');
  CheckNear(1.5, calls[3].StartSec, 1.0E-9, 'start parsed');
  CheckNear(4.0, calls[3].EndSec, 1.0E-9, 'end parsed');
end;

procedure Test_ValidateToolCall_ApplicationTools;
var
  c: TAIToolCall;
  err: string;
begin
  FillChar(c, SizeOf(c), 0);
  c.HasKind := True; c.Kind := atkClampClips;
  c.HasClipIds := True; c.ClipIds := [1];
  c.HasMode := True; c.Mode := 'sideways';
  CheckFalse(ValidateToolCall(c, err), 'unknown clamp mode rejected');
  c.Mode := 'LAST';
  Check(ValidateToolCall(c, err), 'mode is case-insensitive');

  Finalize(c);
  FillChar(c, SizeOf(c), 0);
  c.HasKind := True; c.Kind := atkRunCommand;
  CheckFalse(ValidateToolCall(c, err), 'RunCommand needs a path');

  FillChar(c, SizeOf(c), 0);
  c.HasKind := True; c.Kind := atkSetRange;
  c.HasStartSec := True; c.StartSec := 5;
  c.HasEndSec := True; c.EndSec := 2;
  CheckFalse(ValidateToolCall(c, err), 'range must end after it starts');
  c.HasEnabled := True; c.Enabled := False;
  Check(ValidateToolCall(c, err), 'clearing the range needs no times');
end;

procedure Test_Dispatcher_ApplicationTools_GoToTheWindow;
var
  doc: TProjectDocument;
  cmds: TCommandManager;
  dispatcher: TAIToolDispatcher;
  ui: TFakeUI;
  call: TAIToolCall;
  resultText: string;
begin
  doc := TProjectDocument.CreateNew;
  cmds := TCommandManager.Create;
  ui := TFakeUI.Create;
  try
    FillChar(call, SizeOf(call), 0);
    call.HasKind := True; call.Kind := atkSetPlayhead;
    call.HasPositionSec := True; call.PositionSec := 2;
    dispatcher := TAIToolDispatcher.Create(doc, cmds);
    try
      CheckFalse(dispatcher.Execute(call, resultText), 'without a window the call fails cleanly');
      Check(Pos('error', resultText) > 0, 'and says why');
      dispatcher.OnUICommand := ui.Handle;
      Check(dispatcher.Execute(call, resultText), 'with a window the call goes through');
      CheckEqualInt(1, ui.Calls, 'window handed the call once');
      Check(ui.LastKind = atkSetPlayhead, 'the right call');
      call.Kind := atkRunCommand;
      CheckFalse(dispatcher.Execute(call, resultText), 'an error result counts as a failure');
    finally
      dispatcher.Free;
    end;
  finally
    ui.Free;
    cmds.Free;
    doc.Free;
  end;
end;

procedure Test_EveryToolIsDescribedAndRoundTrips;
var
  k, back: TAIToolKind;
begin
  for k := Low(TAIToolKind) to High(TAIToolKind) do
  begin
    Check(AIToolKindFromId(AIToolKindId(k), back) and (back = k), 'id round-trips: ' + AIToolKindId(k));
    Check(AIToolDescription(k) <> AIToolKindId(k), 'has a real description: ' + AIToolKindId(k));
    Check(Pos(AIToolKindId(k), AIToolSystemPrompt) > 0, 'named in the system prompt: ' + AIToolKindId(k));
  end;
end;


procedure Test_McpToolsList_PublishesEveryTool;
var
  server: TUDAWMcpServer;
  resp: string;
  k: TAIToolKind;
begin
  server := TUDAWMcpServer.Create;
  try
    resp := server.HandleRequestForTest('{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
    for k := Low(TAIToolKind) to High(TAIToolKind) do
      Check(Pos('"name":"' + AIToolKindId(k) + '"', resp) > 0, 'tools/list publishes ' + AIToolKindId(k));
    Check(Pos('"items"', resp) > 0, 'array parameters carry an element type');
    resp := server.HandleRequestForTest('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"SetPlayhead","arguments":{"position_sec":3}}}');
    Check(Pos('no live project', resp) + Pos('no project', resp) > 0, 'a call without a project says so, no crash');
  finally
    server.Free;
  end;
end;

procedure Test_ScoreSpread_RoundTripsInTheProjectFile;
var
  doc, back: TProjectDocument;
  text, old: string;
begin
  doc := TProjectDocument.CreateNew;
  try
    CheckNear(1.0, doc.ScoreSpread, 1.0E-9, 'normal spacing by default');
    doc.ScoreSpread := 1.7;
    text := ProjectToString(doc);
    back := ProjectFromString(text);
    try
      CheckNear(1.7, back.ScoreSpread, 1.0E-6, 'spacing comes back from the file');
    finally
      back.Free;
    end;
    old := StringReplace(text, 'SCORESPREAD 1.7' + sLineBreak, '', []);
    Check(old <> text, 'the file carries a SCORESPREAD line');
    back := ProjectFromString(old);
    try
      CheckNear(1.0, back.ScoreSpread, 1.0E-9, 'a file without the line loads with normal spacing');
    finally
      back.Free;
    end;
    doc.ScoreSpread := 99;
    CheckNear(3.0, doc.ScoreSpread, 1.0E-9, 'spacing is clamped');
  finally
    doc.Free;
  end;
end;

function InfoValue(AInfo: TSysInfo; const AKey: string): string;
var
  i: Integer;
begin
  for i := 0 to AInfo.Count - 1 do
    if (AInfo[i].Kind = sikRow) and SameText(AInfo[i].Key, AKey) then Exit(AInfo[i].Value);
  Result := '';
end;

function InfoHasSection(AInfo: TSysInfo; const ATitle: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to AInfo.Count - 1 do
    if (AInfo[i].Kind = sikSection) and (Pos(ATitle, AInfo[i].Key) = 1) then Exit(True);
  Result := False;
end;

procedure Test_SystemInfo_ReportsTheMachine;
var
  info: TSysInfo;
  extraRan: Boolean;
  txt: string;
begin
  SetEnvironmentVariable('UDAW_TEST_SECRET_KEY', 'top-secret-value');
  info := TSysInfo.Create;
  try
    extraRan := False;
    CollectSystemInfo(info,
      procedure(AInfo: TSysInfo)
      begin
        extraRan := True;
        AInfo.Section('From the application');
        AInfo.Row('Marker', 'present');
      end);
    Check(extraRan, 'the application can add its own sections');
    CheckEqualStr('', InfoValue(info, 'This section could not be read'), 'every section of the report could be read');
    Check(InfoHasSection(info, 'Application'), 'application section');
    Check(InfoHasSection(info, 'Operating system'), 'operating system section');
    Check(InfoHasSection(info, 'Processor'), 'processor section');
    Check(InfoHasSection(info, 'Memory'), 'memory section');
    Check(InfoHasSection(info, 'Video adapters'), 'video adapter section');
    Check(InfoHasSection(info, 'Displays'), 'display section');
    Check(InfoHasSection(info, 'Drives'), 'drives section');
    Check(InfoHasSection(info, 'Loaded modules'), 'module list');
    Check(InfoHasSection(info, 'Environment'), 'environment');
    Check(InfoValue(info, 'Total physical memory (RAM)') <> '', 'total RAM is reported');
    Check(Pos('GB', InfoValue(info, 'Total physical memory (RAM)')) > 0, 'RAM is shown in GB on any real machine');
    Check(InfoValue(info, 'Virtual address space of this process - total') <> '', 'virtual memory is reported');
    Check(InfoValue(info, 'Commit limit (RAM + page file)') <> '', 'page file / commit limit is reported');
    CheckEqualStr(IntToStr(GetCurrentProcessId), InfoValue(info, 'Process id'), 'process id');
    Check(InfoValue(info, 'Logical processors') <> '', 'CPU core count');
    Check(InfoValue(info, 'Name') <> '', 'a name for the CPU or the OS');
    CheckEqualStr('(hidden)', InfoValue(info, 'UDAW_TEST_SECRET_KEY'), 'a secret-looking environment value is never shown');
    txt := info.AsText;
    Check(Pos('top-secret-value', txt) = 0, 'the secret is not in the text report either');
    Check(Pos('== Memory ==', txt) > 0, 'the text report has section headings');
  finally
    info.Free;
  end;
end;

procedure Test_Display_ListsMonitorsAndModes;
var
  mons: TArray<TMonitorEntry>;
  modes: TArray<TDisplayMode>;
  cur: TDisplayMode;
  i: Integer;
  found: Boolean;
begin
  mons := ListMonitors;
  Check(Length(mons) >= 1, 'at least one monitor');
  Check(mons[0].Primary, 'the primary monitor comes first');
  Check(mons[0].Rect.Right > mons[0].Rect.Left, 'a real desktop rectangle');
  modes := ListDisplayModes(mons[0].Device);
  Check(Length(modes) > 0, 'the primary monitor offers modes');
  for i := 1 to High(modes) do
    Check((modes[i].Width < modes[i - 1].Width) or
          ((modes[i].Width = modes[i - 1].Width) and (modes[i].Height <= modes[i - 1].Height)),
      'modes are listed widest first');
  if CurrentDisplayMode(mons[0].Device, cur) then
  begin
    found := False;
    for i := 0 to High(modes) do
      if (modes[i].Width = cur.Width) and (modes[i].Height = cur.Height) then found := True;
    Check(found, 'the mode in use is among those offered');
  end;
  cur.Width := 1920; cur.Height := 1080; cur.Frequency := 144; cur.Bits := 32;
  CheckEqualStr('1920 x 1080 @ 144 Hz', DisplayModeText(cur), 'mode text');
end;

procedure Test_Gl_DriverReportAndFrameCounters;
var
  rep: TArray<string>;
  s: string;
  fps, draws: Double;
  surfaces: Integer;
  hasRenderer: Boolean;
begin
  rep := GLDriverReport;
  Check(Length(rep) > 0, 'the driver report is never empty');
  hasRenderer := False;
  for s in rep do
    if Pos('renderer|', s) = 1 then hasRenderer := True;
  Check(hasRenderer or (Pos('status|', rep[0]) = 1), 'a renderer name, or a clear statement why not');
  GLSampleFrames(fps, draws, surfaces);
  GLSampleFrames(fps, draws, surfaces);
  CheckEqualInt(0, surfaces, 'nothing was drawn between two samples');
  CheckNear(0.0, fps, 1.0E-9, 'so the frame rate is zero');
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
  RegisterTest(GRP, 'ParseAIToolCalls: application tools (arrays, paths, ranges)', Test_ParseAIToolCalls_ApplicationTools);
  RegisterTest(GRP, 'ValidateToolCall: application tools', Test_ValidateToolCall_ApplicationTools);
  RegisterTest(GRP, 'Dispatcher: application tools go to the window', Test_Dispatcher_ApplicationTools_GoToTheWindow);
  RegisterTest(GRP, 'Every tool is described, named in the prompt and round-trips', Test_EveryToolIsDescribedAndRoundTrips);
  RegisterTest(GRP, 'MCP tools/list publishes every tool', Test_McpToolsList_PublishesEveryTool);
  RegisterTest(GRP, 'Score vertical spacing is saved with the project', Test_ScoreSpread_RoundTripsInTheProjectFile);
  RegisterTest(GRP, 'System report covers the machine and hides secrets', Test_SystemInfo_ReportsTheMachine);
  RegisterTest(GRP, 'Display: monitors and modes are listed', Test_Display_ListsMonitorsAndModes);
  RegisterTest(GRP, 'OpenGL: driver report and frame counters', Test_Gl_DriverReportAndFrameCounters);
end;

end.
