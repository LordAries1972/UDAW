from pathlib import Path
p=Path('src/ui/UDAW.UI.MainForm.pas');s=p.read_text(encoding='utf-8-sig');s=s.replace('    procedure btnRecSavedClick(Sender: TObject);\n','');s=s.replace('    procedure btnRecArmClick(Sender: TObject);','    procedure btnRecArmClick(Sender: TObject);\n    procedure btnRecSavedClick(Sender: TObject);')
s=s.replace("  App.Audio.Stop; { quiesce producer before final drain and ring release }", "  App.Audio.Stop; { quiesce producer before final drain and ring release }")
s=s.replace('    FRec.Stop;\n    UpdateStatusProgress(2,', '    UpdateStatusProgress(2,')
s=s.replace('  if FRecWriter <> nil then\n  begin\n    RefreshRecordingTab;', '  if FRecWriter <> nil then\n  begin\n    RefreshRecordingTab;',1)
# Keep active capture progress from being overwritten by the general jobs readout.
s=s.replace("    FRecStarted := GetTickCount64;", "    FRecStarted := GetTickCount64;\n    FSyncProgressActive := True;")
# Configure recording path again on each start, so Settings changes take effect.
s=s.replace('    FRec.Disarm;\n    FRec.ClearTakes;', '''    FRec.Disarm;
    if not SameText(FRec.RecordingRoot, RecordingRootPath) then
    begin
      FreeAndNil(FRec);
      FRec := TRecordingEngine.Create(RecordingRootPath);
      FreeAndNil(FRecovery2);
      FRecovery2 := TRecordingRecovery.Create(RecordingRootPath);
    end;
    FRec.ClearTakes;''')
# Prevent accidental removal of an uncommitted previous take from the retry UI.
s=s.replace('  if (App = nil) or (App.Audio = nil) or (FProject = nil) then Exit;\n  try\n    if (App.Audio.Granted.CaptureChannels', "  if (App = nil) or (App.Audio = nil) or (FProject = nil) then Exit;\n  if (FRec.TakeCount > 0) and not FRecCommitted then\n  begin\n    MessageDlg('Add the pending take to the timeline before starting another recording.', mtInformation, [mbOK], 0);\n    Exit;\n  end;\n  try\n    if (App.Audio.Granted.CaptureChannels")
# Capture commit: select actual inserted clip/track and warm its waveform.
s=s.replace('  lane: TTakeLane;\n  comp: TTakeComp;\n  specs:', '  lane: TTakeLane;\n  comp: TTakeComp;\n  cmd: TCommitTakeCommand;\n  clip: TTimelineClip;\n  specs:')
s=s.replace("    FCmds.Perform(TCommitTakeCommand.Create(FProject, FRecTrackId, specs, 'Recorded'));\n    FRecCommitted := True;", """    cmd := TCommitTakeCommand.Create(FProject, FRecTrackId, specs, 'Recorded');
    FCmds.Perform(cmd);
    FRecCommitted := True;
    if Length(cmd.ClipIds) > 0 then
    begin
      TlSetSingleSelection(cmd.ClipIds[0]);
      clip := FProject.Timeline.ClipById(cmd.ClipIds[0]);
      if clip <> nil then
      begin
        FTlSelectedTrackId := clip.TrackId;
        FTlView.EnsureVisible(clip.StartSeconds);
        WarmClipWaveform(clip.SourceId);
      end;
    end;""")
# Refresh recovery root from settings and save recovered WAVs in a discoverable subfolder.
s=s.replace('  pending := FRecovery2.ScanUnfinished;', '''  FreeAndNil(FRecovery2);
  FRecovery2 := TRecordingRecovery.Create(RecordingRootPath);
  pending := FRecovery2.ScanUnfinished;''')
s=s.replace("  outDir := IncludeTrailingPathDelimiter(App.Paths.Cache) + 'recordings-recovered';", "  outDir := IncludeTrailingPathDelimiter(RecordingRootPath) + 'Recovered';")
s=s.replace("  dlgRecSaved.InitialDir := FRec.RecordingRoot;", "  dlgRecSaved.InitialDir := RecordingRootPath;")
s=s.replace("  if ImportBrowserFileToTimeline(dlgRecSaved.FileName, trackId, RecordingPosition) then\n    RefreshTimelineTab;", "  if ImportBrowserFileToTimeline(dlgRecSaved.FileName, trackId, RecordingPosition) then\n    RefreshTimelineTab\n  else MessageDlg('Audio could not be imported. See the Timeline readout for details.', mtError, [mbOK], 0);")
# Prevent manual device reset during capture.
a=s.index('procedure TfrmMain.btnAudioResetClick(');b=s.index('\nbegin',a)+len('\nbegin');s=s[:b]+'\n  if FRecWriter <> nil then StopLiveRecording;'+s[b:]
p.write_text(s,encoding='utf-8-sig')
# Finalize on writer, after its last drain, not on the UI thread.
p=Path('src/recording/UDAW.Recording.Writer.pas');s=p.read_text(encoding='utf-8-sig');s=s.replace('  while DrainOnce > 0 do\n    ;\nend;', '''  while DrainOnce > 0 do
    ;
  try
    FEngine.Stop;
  except
    on E: Exception do NoteError(E.Message);
  end;
end;''');p.write_text(s,encoding='utf-8-sig')
# Device recovery must not replace the format under an active recording.
p=Path('src/audio/UDAW.Audio.Engine.pas');s=p.read_text(encoding='utf-8-sig');s=s.replace('          BeginRecovery;', '          if FCaptureRing = nil then BeginRecovery;');s=s.replace('  FCaptureRing := ARing;', '''  { All callers quiesce the stream before attaching/detaching a live ring. }
  FCaptureRing := ARing;''');s=s.replace('if toWrite * AInput.ChannelCount <= Length(FCaptureScratch) then', 'if (AInput.ChannelCount = FCaptureRing.Channels) and\n         (toWrite * AInput.ChannelCount <= Length(FCaptureScratch)) then');p.write_text(s,encoding='utf-8-sig')
# WASAPI: route each captured packet directly to the input side of the engine.
# The old render-clock bridge zero-padded input and left a tail behind at Stop.
p=Path('src/audio/backend/UDAW.Audio.Backend.WASAPI.pas');s=p.read_text(encoding='utf-8-sig')
a=s.index('          gotIn := 0;');b=s.index('          t.CallbackIndex := cbIndex;',a);s=s[:a]+s[b:]
s=s.replace('            if inBuf <> nil then\n              FCallback(inBuf, buf, t)\n            else\n              FCallback(nil, buf, t);','            FCallback(nil, buf, t);')
s=s.replace('          if (gotIn < Integer(avail)) and (inBuf <> nil) then\n            NoteXRun(1);','')
a=s.index('              if FRequest.Direction = adDuplex then',s.index('procedure TWASAPIStream.RunCapture') if 'procedure TWASAPIStream.RunCapture' in s else 0);b=s.index('                t.CallbackIndex := cbIndex;',a)
s=s[:a]+'              begin\n'+s[b:]
s=s.replace('                NoteBlock(framesRead, load);','                if FRequest.Direction <> adDuplex then NoteBlock(framesRead, load);')
p.write_text(s,encoding='utf-8-sig')
