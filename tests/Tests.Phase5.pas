unit Tests.Phase5;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 5 acceptance tests: the project system.

  Covers the document model and its validated setters/dirty-tracking; the
  versioned sectioned-text serializer (round-trip of metadata + the embedded
  Phase 4 graph, atomic save, version rejection, corrupt-field rejection);
  the undo/redo command manager (project metadata commands including the
  rapid-edit merge window, and the audio-graph commands built on the Phase 4
  TAudioGraph edit API); and autosave/crash-recovery (rotation, "never
  touches the primary file", unclean-shutdown detection, recovering the
  newest candidate).

  Requires src/common, src/audio, src/audio/dsp, src/audio/graph and
  src/project on the search path. }

interface

procedure RegisterPhase5Tests;

implementation

uses
  SysUtils, Classes,
  UDAW.Testing,
  UDAW.Errors, UDAW.Config,
  UDAW.Paths,
  UDAW.Audio.Graph, UDAW.Audio.Graph.Nodes,
  UDAW.Project.Document, UDAW.Project.Serialization,
  UDAW.Project.Commands, UDAW.Project.Recovery;

function ScratchDir: string;
begin
  Result := IncludeTrailingPathDelimiter(Paths.Temp) + 'phase5-tests' + PathDelim;
  ForceDirectories(Result);
end;

procedure WipeFile(const AFileName: string);
begin
  if FileExists(AFileName) then
    DeleteFile(AFileName);
end;

{ ================= document ================= }

procedure Test_Doc_DefaultsAndDirty;
var
  doc: TProjectDocument;
begin
  doc := TProjectDocument.CreateNew('My Song');
  try
    CheckEqualStr('My Song', doc.Name, 'name');
    CheckNear(120.0, doc.TempoBPM, 1e-9, 'default tempo');
    CheckEqualInt(4, doc.TimeSigNum, 'default time sig num');
    CheckEqualInt(4, doc.TimeSigDen, 'default time sig den');
    CheckEqualInt(48000, doc.SampleRate, 'default sample rate');
    CheckEqualInt(2, doc.Channels, 'default channels');
    CheckEqualInt(1, doc.Graph.NodeCount, 'fresh project has just the Master node');
    CheckEqualStr('output', NodeKindId(doc.Graph.GetNode(0).Kind), 'that node is an Output');
    CheckFalse(doc.Dirty, 'a freshly created project is not dirty');

    doc.TempoBPM := 140;
    Check(doc.Dirty, 'setting tempo dirties the document');
    doc.ClearDirty;

    doc.Name := 'Renamed';
    Check(doc.Dirty, 'setting name dirties the document');
  finally
    doc.Free;
  end;
end;

procedure Test_Doc_ValidatedSetters;
var
  doc: TProjectDocument;
  raised: Boolean;
begin
  doc := TProjectDocument.CreateNew;
  try
    raised := False;
    try
      doc.TempoBPM := 5;   // below PROJECT_MIN_TEMPO
    except
      on E: EUDAWError do raised := True;
    end;
    Check(raised, 'out-of-range tempo raises EUDAWError');

    raised := False;
    try
      doc.TimeSigDen := 3;   // not a power of two
    except
      on E: EUDAWError do raised := True;
    end;
    Check(raised, 'non power-of-two denominator raises EUDAWError');

    raised := False;
    try
      doc.Name := '   ';
    except
      on E: EUDAWError do raised := True;
    end;
    Check(raised, 'blank name raises EUDAWError');
  finally
    doc.Free;
  end;
end;

procedure Test_Doc_Clone;
var
  doc, clone: TProjectDocument;
begin
  doc := TProjectDocument.CreateNew('Cloneable');
  try
    doc.Graph.AddNode(nkGain, 'Trim');
    doc.TempoBPM := 90;
    clone := doc.Clone;
    try
      CheckEqualStr(doc.Name, clone.Name, 'clone name matches');
      CheckNear(doc.TempoBPM, clone.TempoBPM, 1e-9, 'clone tempo matches');
      CheckEqualInt(doc.Graph.NodeCount, clone.Graph.NodeCount, 'clone graph node count matches');
      Check(clone.Graph <> doc.Graph, 'clone owns an independent graph object');

      { mutating the clone must not affect the original }
      clone.Graph.AddNode(nkMeter, 'Tap');
      CheckEqualInt(2, doc.Graph.NodeCount, 'original graph untouched by clone edit');
      CheckEqualInt(3, clone.Graph.NodeCount, 'clone graph got the new node');
    finally
      clone.Free;
    end;
  finally
    doc.Free;
  end;
end;

{ ================= serialization ================= }

procedure Test_Serialize_RoundTrip;
var
  doc, loaded: TProjectDocument;
  text: string;
  gainId: Integer;
begin
  doc := TProjectDocument.CreateNew('Round Trip');
  try
    doc.TempoBPM := 133.5;
    doc.TimeSigNum := 3;
    doc.TimeSigDen := 8;
    doc.SampleRate := 96000;
    doc.Channels := 2;

    gainId := doc.Graph.AddNode(nkGain, 'Trim').Id;
    TGainNode(doc.Graph.NodeById(gainId)).GainDb := -4.5;
    doc.Graph.Connect(gainId, doc.Graph.GetNode(0).Id);

    text := ProjectToString(doc);
    Check(text.Contains('UDAWPROJECT'), 'header present');
    Check(text.Contains('GRAPH-BEGIN'), 'graph section present');
    Check(text.Contains('UDAWGRAPH'), 'embedded graph header present');

    loaded := ProjectFromString(text);
    try
      CheckEqualStr(GUIDToString(doc.UUID), GUIDToString(loaded.UUID), 'uuid round-trips');
      CheckEqualStr('Round Trip', loaded.Name, 'name round-trips');
      CheckNear(133.5, loaded.TempoBPM, 1e-6, 'tempo round-trips');
      CheckEqualInt(3, loaded.TimeSigNum, 'time sig num round-trips');
      CheckEqualInt(8, loaded.TimeSigDen, 'time sig den round-trips');
      CheckEqualInt(96000, loaded.SampleRate, 'sample rate round-trips');
      CheckEqualInt(2, loaded.Graph.NodeCount, 'graph node count round-trips');
      CheckNear(-4.5, TGainNode(loaded.Graph.NodeById(gainId)).GainDb, 1e-6,
        'graph node parameter round-trips');
      CheckEqualInt(1, loaded.Graph.ConnectionCount, 'graph connection round-trips');
      CheckFalse(loaded.Dirty, 'a freshly parsed document is clean');
    finally
      loaded.Free;
    end;
  finally
    doc.Free;
  end;
end;

procedure Test_Serialize_FileRoundTrip;
var
  doc, loaded: TProjectDocument;
  fn: string;
begin
  fn := ScratchDir + 'roundtrip.udawproj';
  WipeFile(fn);
  doc := TProjectDocument.CreateNew('File Round Trip');
  try
    SaveProjectToFile(doc, fn);
    Check(FileExists(fn), 'save creates the file');
    CheckEqualStr(fn, doc.FileName, 'save records the file name');
    CheckFalse(doc.Dirty, 'save clears dirty');

    loaded := LoadProjectFromFile(fn);
    try
      CheckEqualStr('File Round Trip', loaded.Name, 'loaded name matches');
      CheckEqualStr(fn, loaded.FileName, 'load records the file name');
    finally
      loaded.Free;
    end;
  finally
    doc.Free;
    WipeFile(fn);
  end;
end;

procedure Test_Serialize_RejectFutureVersion;
var
  raised: Boolean;
  doc: TProjectDocument;
begin
  raised := False;
  doc := nil;
  try
    doc := ProjectFromString('UDAWPROJECT 99'#13#10'UUID {00000000-0000-0000-0000-000000000000}'#13#10);
  except
    on E: EUDAWError do
    begin
      raised := True;
      CheckEqualInt(Ord(errConfig), Ord(E.Code), 'rejects with errConfig');
    end;
  end;
  Check(raised, 'a future document version is rejected');
  doc.Free;
end;

procedure Test_Serialize_RejectMalformed;
var
  raised: Boolean;
begin
  raised := False;
  try
    ProjectFromString('not a project file at all');
  except
    on E: EUDAWError do raised := True;
  end;
  Check(raised, 'a document missing the header is rejected');

  raised := False;
  try
    ProjectFromString('UDAWPROJECT 1'#13#10'TEMPO not-a-number'#13#10);
  except
    on E: EUDAWError do raised := True;
  end;
  Check(raised, 'a corrupt field is rejected, not silently defaulted');
end;

{ ================= undo / redo ================= }

procedure Test_Commands_TempoUndoRedo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
begin
  doc := TProjectDocument.CreateNew;
  mgr := TCommandManager.Create;
  try
    CheckFalse(mgr.CanUndo, 'nothing to undo yet');
    Check(mgr.Perform(TSetTempoCommand.Create(doc, 140)), 'set tempo executes');
    CheckNear(140, doc.TempoBPM, 1e-9, 'tempo applied');
    Check(mgr.CanUndo, 'now something to undo');
    CheckFalse(mgr.CanRedo, 'nothing to redo yet');

    mgr.Undo;
    CheckNear(120, doc.TempoBPM, 1e-9, 'undo restores previous tempo');
    Check(mgr.CanRedo, 'now something to redo');

    mgr.Redo;
    CheckNear(140, doc.TempoBPM, 1e-9, 'redo re-applies the tempo');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Commands_MergeRapidEdits;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
begin
  doc := TProjectDocument.CreateNew;
  mgr := TCommandManager.Create;
  try
    mgr.Perform(TSetTempoCommand.Create(doc, 121));
    mgr.Perform(TSetTempoCommand.Create(doc, 122));
    mgr.Perform(TSetTempoCommand.Create(doc, 123));
    mgr.Perform(TSetTempoCommand.Create(doc, 124));
    CheckNear(124, doc.TempoBPM, 1e-9, 'last value applied');
    CheckEqualInt(1, mgr.UndoCount, 'a burst of rapid tempo edits collapses to one undo step');

    mgr.Undo;
    CheckNear(120, doc.TempoBPM, 1e-9, 'one undo restores the pre-burst value');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Commands_NameAndTimeSig;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
begin
  doc := TProjectDocument.CreateNew('Original');
  mgr := TCommandManager.Create;
  try
    mgr.Perform(TSetProjectNameCommand.Create(doc, 'Renamed'));
    CheckEqualStr('Renamed', doc.Name, 'name changed');
    mgr.Perform(TSetTimeSignatureCommand.Create(doc, 3, 4));
    CheckEqualInt(3, doc.TimeSigNum, 'time sig num changed');
    CheckEqualInt(4, doc.TimeSigDen, 'time sig den changed');

    mgr.Undo;
    CheckEqualInt(4, doc.TimeSigNum, 'undo restores time sig num');
    CheckEqualInt(4, doc.TimeSigDen, 'undo restores time sig den');
    mgr.Undo;
    CheckEqualStr('Original', doc.Name, 'undo restores name');
    CheckFalse(mgr.CanUndo, 'undo stack exhausted');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Commands_GraphAddRemoveNode;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  addCmd: TAddGraphNodeCommand;
  gainId: Integer;
begin
  doc := TProjectDocument.CreateNew;   // 1 node: Master output
  mgr := TCommandManager.Create;
  try
    addCmd := TAddGraphNodeCommand.Create(doc, nkGain, 'Trim');
    mgr.Perform(addCmd);
    gainId := addCmd.CreatedId;
    CheckEqualInt(2, doc.Graph.NodeCount, 'node added');
    Check(doc.Graph.NodeById(gainId) <> nil, 'new node is findable by id');

    mgr.Perform(TConnectNodesCommand.Create(doc, gainId, doc.Graph.GetNode(0).Id));
    CheckEqualInt(1, doc.Graph.ConnectionCount, 'connection added');

    mgr.Undo;   // undo connect
    CheckEqualInt(0, doc.Graph.ConnectionCount, 'undo removed the connection');
    mgr.Undo;   // undo add node
    CheckEqualInt(1, doc.Graph.NodeCount, 'undo removed the node');
    Check(doc.Graph.NodeById(gainId) = nil, 'removed node no longer findable');

    mgr.Redo;   // redo add node
    CheckEqualInt(2, doc.Graph.NodeCount, 'redo re-added the node');
    Check(doc.Graph.NodeById(gainId) <> nil, 'redo re-added it with the same id');
    mgr.Redo;   // redo connect
    CheckEqualInt(1, doc.Graph.ConnectionCount, 'redo re-added the connection');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Commands_RemoveNodeRestoresConnections;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  gainId, outId: Integer;
begin
  doc := TProjectDocument.CreateNew;
  mgr := TCommandManager.Create;
  try
    outId := doc.Graph.GetNode(0).Id;
    gainId := doc.Graph.AddNode(nkGain, 'Trim').Id;
    TGainNode(doc.Graph.NodeById(gainId)).GainDb := -6;
    doc.Graph.Connect(gainId, outId);
    CheckEqualInt(2, doc.Graph.NodeCount, 'setup: two nodes');
    CheckEqualInt(1, doc.Graph.ConnectionCount, 'setup: one connection');

    mgr.Perform(TRemoveGraphNodeCommand.Create(doc, gainId));
    CheckEqualInt(1, doc.Graph.NodeCount, 'node removed');
    CheckEqualInt(0, doc.Graph.ConnectionCount, 'its connection removed too');

    mgr.Undo;
    CheckEqualInt(2, doc.Graph.NodeCount, 'undo restores the node');
    CheckEqualInt(1, doc.Graph.ConnectionCount, 'undo restores its connection');
    CheckNear(-6, TGainNode(doc.Graph.NodeById(gainId)).GainDb, 1e-6,
      'undo restores the node''s parameters');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Commands_SetNodeParamsMerge;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  gainId: Integer;
begin
  doc := TProjectDocument.CreateNew;
  mgr := TCommandManager.Create;
  try
    gainId := doc.Graph.AddNode(nkGain, 'Trim').Id;
    mgr.Perform(TSetNodeParamsCommand.Create(doc, gainId, 'db=-1'));
    mgr.Perform(TSetNodeParamsCommand.Create(doc, gainId, 'db=-2'));
    mgr.Perform(TSetNodeParamsCommand.Create(doc, gainId, 'db=-3'));
    CheckNear(-3, TGainNode(doc.Graph.NodeById(gainId)).GainDb, 1e-6, 'last value applied');
    CheckEqualInt(1, mgr.UndoCount, 'a burst of fader drags collapses to one undo step');

    mgr.Undo;
    CheckNear(0, TGainNode(doc.Graph.NodeById(gainId)).GainDb, 1e-6,
      'one undo restores the pre-burst gain');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Commands_ClearFreesHistory;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
begin
  doc := TProjectDocument.CreateNew;
  mgr := TCommandManager.Create;
  try
    mgr.Perform(TSetTempoCommand.Create(doc, 121));
    mgr.Undo;
    Check(mgr.CanRedo, 'redo available before Clear');
    mgr.Clear;
    CheckFalse(mgr.CanUndo, 'Clear empties the undo stack');
    CheckFalse(mgr.CanRedo, 'Clear empties the redo stack');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

{ ================= autosave / recovery ================= }

procedure Test_Recovery_AutosaveRotation;
var
  doc: TProjectDocument;
  rec: TProjectRecoveryManager;
  fn: string;
  i: Integer;
begin
  fn := ScratchDir + 'rotation.udawproj';
  WipeFile(fn);
  for i := 1 to 5 do
    WipeFile(fn + '.autosave.' + IntToStr(i));

  doc := TProjectDocument.CreateNew('Rotation');
  rec := TProjectRecoveryManager.Create(3);
  try
    rec.BeginSession(fn);

    doc.Name := 'Rev 1'; rec.AutosaveNow(doc);
    doc.Name := 'Rev 2'; rec.AutosaveNow(doc);
    doc.Name := 'Rev 3'; rec.AutosaveNow(doc);
    doc.Name := 'Rev 4'; rec.AutosaveNow(doc);

    CheckEqualInt(3, rec.AutosaveCount(fn), 'only max-backups autosaves are kept');
    CheckFalse(FileExists(fn), 'autosave never writes the primary project file');

    { newest kept slot is #1, rotated forward each time - Rev 4 must be there }
    with LoadProjectFromFile(rec.AutosaveFileName(fn, 1)) do
    try
      CheckEqualStr('Rev 4', Name, 'slot 1 holds the newest revision');
    finally
      Free;
    end;
    { oldest surviving revision is Rev 2 (Rev 1 was rotated out) }
    with LoadProjectFromFile(rec.AutosaveFileName(fn, 3)) do
    try
      CheckEqualStr('Rev 2', Name, 'slot 3 holds the oldest surviving revision');
    finally
      Free;
    end;
  finally
    rec.Free;
    doc.Free;
    for i := 1 to 5 do
      WipeFile(fn + '.autosave.' + IntToStr(i));
    WipeFile(fn);
  end;
end;

procedure Test_Recovery_UncleanShutdownDetection;
var
  rec: TProjectRecoveryManager;
  fn: string;
begin
  fn := ScratchDir + 'crash.udawproj';
  WipeFile(fn);
  WipeFile(fn + '.open');

  rec := TProjectRecoveryManager.Create;
  try
    CheckFalse(rec.HasUncleanShutdown(fn), 'no marker before any session');

    rec.BeginSession(fn);
    Check(FileExists(fn + '.open'), 'BeginSession writes the open marker');
    { a second manager instance simulates re-opening the app: the marker from
      the still-"running" session looks like a crash to a fresh check }
    Check(rec.HasUncleanShutdown(fn), 'marker present => unclean shutdown reported');

    rec.EndSessionClean;
    CheckFalse(FileExists(fn + '.open'), 'EndSessionClean removes the marker');
    CheckFalse(rec.HasUncleanShutdown(fn), 'no unclean shutdown after a clean end');
  finally
    rec.Free;
    WipeFile(fn + '.open');
  end;
end;

procedure Test_Recovery_RecoverNewest;
var
  doc: TProjectDocument;
  rec: TProjectRecoveryManager;
  fn: string;
  recovered: TProjectDocument;
  candidates: TArray<TRecoveryCandidate>;
begin
  fn := ScratchDir + 'recover.udawproj';
  WipeFile(fn);
  WipeFile(fn + '.autosave.1');
  WipeFile(fn + '.autosave.2');

  doc := TProjectDocument.CreateNew('Before Crash');
  rec := TProjectRecoveryManager.Create;
  try
    rec.BeginSession(fn);
    doc.TempoBPM := 150;
    rec.AutosaveNow(doc);   // simulates an autosave just before the crash

    { the app "crashes": no EndSessionClean, no primary file ever written }
    Check(rec.HasUncleanShutdown(fn), 'unclean shutdown visible to the next session');

    candidates := rec.ListRecoveryCandidates(fn);
    Check(Length(candidates) >= 1, 'at least one recovery candidate exists');
    Check(candidates[0].IsAutosave, 'the only candidate is the autosave (primary was never saved)');

    recovered := rec.RecoverNewest(fn);
    try
      CheckEqualStr('Before Crash', recovered.Name, 'recovered document has the right content');
      CheckNear(150, recovered.TempoBPM, 1e-9, 'recovered document has the latest autosaved edit');
      CheckEqualStr(fn, recovered.FileName, 'recovered document is bound back to the primary path');
    finally
      recovered.Free;
    end;
  finally
    rec.Free;
    doc.Free;
    WipeFile(fn + '.autosave.1');
    WipeFile(fn + '.autosave.2');
    WipeFile(fn + '.open');
  end;
end;

procedure Test_Recovery_TickRespectsIntervalAndDirty;
var
  doc: TProjectDocument;
  rec: TProjectRecoveryManager;
  fn: string;
begin
  fn := ScratchDir + 'tick.udawproj';
  WipeFile(fn);
  WipeFile(fn + '.autosave.1');

  doc := TProjectDocument.CreateNew('Tick');
  rec := TProjectRecoveryManager.Create;
  try
    rec.Interval := ai5Min;
    rec.BeginSession(fn);
    doc.ClearDirty;

    rec.Tick(doc, Now);
    CheckFalse(FileExists(fn + '.autosave.1'), 'Tick does nothing when the document is clean');

    doc.Name := 'Tick 2';   // dirties it, but interval has not elapsed
    rec.Tick(doc, Now);
    CheckFalse(FileExists(fn + '.autosave.1'), 'Tick does nothing before the interval elapses');

    rec.Tick(doc, Now + (6 / (24 * 60)));   // simulate 6 minutes later
    Check(FileExists(fn + '.autosave.1'), 'Tick autosaves once the interval has elapsed and dirty');
  finally
    rec.Free;
    doc.Free;
    WipeFile(fn + '.autosave.1');
  end;
end;

{ ---------------- registration ---------------- }

procedure Test_RecentProjects;
var cfg: TConfig; fn, path: string; i: Integer;
begin
  fn := ScratchDir + 'recents.ini';
  WipeFile(fn);
  cfg := TConfig.Create(fn);
  try
    for i := 1 to 12 do RememberRecentProject(cfg, ScratchDir + IntToStr(i) + '.udawproj');
    CheckEqualStr(ExpandFileName(ScratchDir + '12.udawproj'), cfg.GetString('project', 'recent_0', ''), 'newest first');
    CheckEqualStr(ExpandFileName(ScratchDir + '3.udawproj'), cfg.GetString('project', 'recent_9', ''), 'only ten retained');
    path := ExpandFileName(ScratchDir + '7.udawproj');
    RememberRecentProject(cfg, path);
    RememberRecentProject(cfg, UpperCase(path));
    CheckEqualStr(ExpandFileName(ScratchDir + '12.udawproj'), cfg.GetString('project', 'recent_1', ''), 'reopen deduplicates and moves to front');
    Check(cfg.Save, 'recent list saves');
  finally cfg.Free; end;
  cfg := TConfig.Create(fn);
  try
    CheckEqualStr(UpperCase(path), cfg.GetString('project', 'last_project', ''), 'startup target survives restart');
    CheckEqualStr(UpperCase(path), cfg.GetString('project', 'recent_0', ''), 'menu order survives restart');
  finally cfg.Free; WipeFile(fn); WipeFile(fn + '.bak'); end;
end;

procedure RegisterPhase5Tests;
begin
  RegisterTest('project.recent', 'last ten, deduplication and restart persistence', Test_RecentProjects);
  RegisterTest('project.document', 'defaults + dirty tracking', @Test_Doc_DefaultsAndDirty);
  RegisterTest('project.document', 'validated setters',         @Test_Doc_ValidatedSetters);
  RegisterTest('project.document', 'clone is independent',      @Test_Doc_Clone);

  RegisterTest('project.serialize', 'round-trip (text)',        @Test_Serialize_RoundTrip);
  RegisterTest('project.serialize', 'round-trip (file, atomic save)', @Test_Serialize_FileRoundTrip);
  RegisterTest('project.serialize', 'reject future version',    @Test_Serialize_RejectFutureVersion);
  RegisterTest('project.serialize', 'reject malformed document', @Test_Serialize_RejectMalformed);

  RegisterTest('project.commands', 'tempo undo/redo',           @Test_Commands_TempoUndoRedo);
  RegisterTest('project.commands', 'merge rapid tempo edits',   @Test_Commands_MergeRapidEdits);
  RegisterTest('project.commands', 'name + time signature',     @Test_Commands_NameAndTimeSig);
  RegisterTest('project.commands', 'graph add/remove node',     @Test_Commands_GraphAddRemoveNode);
  RegisterTest('project.commands', 'remove node restores connections', @Test_Commands_RemoveNodeRestoresConnections);
  RegisterTest('project.commands', 'merge rapid node param edits', @Test_Commands_SetNodeParamsMerge);
  RegisterTest('project.commands', 'clear frees history',       @Test_Commands_ClearFreesHistory);

  RegisterTest('project.recovery', 'autosave rotation',         @Test_Recovery_AutosaveRotation);
  RegisterTest('project.recovery', 'unclean shutdown detection', @Test_Recovery_UncleanShutdownDetection);
  RegisterTest('project.recovery', 'recover newest candidate',  @Test_Recovery_RecoverNewest);
  RegisterTest('project.recovery', 'tick respects interval + dirty', @Test_Recovery_TickRespectsIntervalAndDirty);
end;

end.
