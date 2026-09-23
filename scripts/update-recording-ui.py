from pathlib import Path
import re
p=Path('src/ui/UDAW.UI.MainForm.pas');s=p.read_text(encoding='utf-8-sig')
s=s.replace('UDAW.Recording.Recovery, UDAW.Recording.Commands,','UDAW.Recording.Recovery, UDAW.Recording.Commands,\n  UDAW.Recording.Writer, UDAW.Audio.Ring,')
s=s.replace('    pnlRecReadout: TPanel;', '''    btnRecArm: TButton;
    btnRecCommit: TButton;
    btnRecScan: TButton;
    btnRecSaved: TButton;
    lblRecDestination: TLabel;
    dlgRecSaved: TOpenDialog;
    pnlRecReadout: TPanel;''')
s=s.replace('    procedure RefreshRecordingTab;', '''    procedure StopLiveRecording;
    procedure btnRecSavedClick(Sender: TObject);
    function RecordingPosition: Double;
    function RecordingRootPath: string;
    procedure RefreshRecordingTab;''')
s=s.replace('    FRec: TRecordingEngine;', '''    FRec: TRecordingEngine;
    FRecWriter: TRecordingWriterThread;
    FRecRing: TAudioRing;
    FRecTrackId: Integer;
    FRecCommitted: Boolean;
    FRecStarted: UInt64;''')
a=s.index('function TfrmMain.BuildRecordSettings:');b=s.index('procedure TfrmMain.cboRecPunchChange',a)
s=s[:a]+'''function TfrmMain.BuildRecordSettings: TRecordSettings;
begin
  Result := TRecordSettings.Default;
  Result.SampleRate := App.Audio.Granted.SampleRate;
  Result.Channels := App.Audio.Granted.CaptureChannels;
  if Result.Channels = 1 then Result.ChannelMode := rcmMono
  else if Result.Channels = 2 then Result.ChannelMode := rcmStereo
  else Result.ChannelMode := rcmMultichannel;
  case cboRecFormat.ItemIndex of
    1: Result.TakeFormat := wsfPCM24;
    2: Result.TakeFormat := wsfPCM16;
  else Result.TakeFormat := wsfFloat32;
  end;
  Result.Validate;
end;

function TfrmMain.RecordingRootPath: string;
begin
  Result := Trim(App.Config.GetString(CFG_SEC_PATHS, CFG_PATH_RECORDINGS, ''));
  if Result = '' then Result := IncludeTrailingPathDelimiter(App.Paths.Cache) + 'recordings';
end;

function TfrmMain.RecordingPosition: Double;
begin
  Result := 0;
  if FProject = nil then Exit;
  if FTlRangeActive then Result := Max(0, FTlRangeStartSec)
  else Result := Max(0, FProject.Timeline.PlayheadSeconds);
end;

'''+s[b:]
a=s.index('procedure TfrmMain.btnRecArmClick');b=s.index('procedure TfrmMain.btnRecCommitClick',a)
s=s[:a]+'''procedure TfrmMain.btnRecArmClick(Sender: TObject);
var
  settings: TRecordSettings;
begin
  if FRecWriter <> nil then
  begin
    StopLiveRecording;
    Exit;
  end;
  if (App = nil) or (App.Audio = nil) or (FProject = nil) then Exit;
  try
    if (App.Audio.Granted.CaptureChannels <= 0) or
       (Pos('software', LowerCase(App.Audio.BackendName)) > 0) then
      RaiseUDAW(errInvalidState, 'Recording',
        'Select a real input device and enable capture in Settings, then reopen Audio.');
    if App.Audio.State <> aesRunning then App.Audio.Start;
    if App.Audio.State <> aesRunning then
      RaiseUDAW(errInvalidState, 'Recording', 'The input device is not running.');
    if FTlPlaying then btnTlStopClick(nil);
    settings := BuildRecordSettings;
    App.Audio.Stop;
    FRec.Disarm;
    FRec.ClearTakes;
    FRec.Configure(settings);
    FRec.Arm;
    FRecTrackId := Max(0, TlSelectedAudioTrackId);
    FRecCommitted := False;
    FRec.Start(RecordingPosition);
    FRecRing := TAudioRing.Create(settings.Channels, settings.SampleRate * 4);
    FRecWriter := TRecordingWriterThread.Create(FRec, FRecRing);
    App.Audio.SetCaptureRing(FRecRing);
    FRecStarted := GetTickCount64;
    App.Audio.Start;
    if App.Audio.State <> aesRunning then
      RaiseUDAW(errInvalidState, 'Recording', 'Could not start the input device.');
    RefreshRecordingTab;
  except
    on E: Exception do
    begin
      if FRecWriter <> nil then StopLiveRecording;
      memRec.Lines.Text := 'Recording failed: ' + E.Message;
      MessageDlg(memRec.Lines.Text, mtError, [mbOK], 0);
    end;
  end;
end;

procedure TfrmMain.StopLiveRecording;
var
  captureError: string;
  overruns: Integer;
begin
  if FRecWriter = nil then Exit;
  captureError := '';
  App.Audio.Stop; { quiesce producer before final drain and ring release }
  App.Audio.SetCaptureRing(nil);
  ShowStatusProgress('Finishing recording: draining captured audio...', 3);
  try
    FRecWriter.Stop;
    captureError := FRecWriter.LastError;
    overruns := FRecWriter.RingOverruns;
    if overruns > 0 then
      captureError := captureError + Format(' Capture buffer overflow (%d); audio was lost.', [overruns]);
    FreeAndNil(FRecWriter);
    FreeAndNil(FRecRing);
    UpdateStatusProgress(1, 'Finishing recording: saving complete take...');
    FRec.Stop;
    UpdateStatusProgress(2, 'Adding recording to the timeline...');
    if FRec.TakeCount > 0 then btnRecCommitClick(nil)
    else captureError := captureError + ' No audio frames were received.';
    UpdateStatusProgress(3, 'Recording saved.');
  except
    on E: Exception do captureError := captureError + ' ' + E.Message;
  end;
  HideStatusProgress;
  RefreshRecordingTab;
  if captureError <> '' then
  begin
    memRec.Lines.Insert(0, 'Recording needs attention: ' + captureError);
    Logger.Error('Recording', captureError);
    MessageDlg('Recording needs attention: ' + captureError, mtWarning, [mbOK], 0);
  end;
  App.Audio.Start;
end;

procedure TfrmMain.btnRecSavedClick(Sender: TObject);
var
  trackId: Integer;
begin
  if (FRecWriter <> nil) or (FProject = nil) then Exit;
  dlgRecSaved.InitialDir := FRec.RecordingRoot;
  if not dlgRecSaved.Execute then Exit;
  trackId := TlSelectedAudioTrackId;
  if trackId < 0 then trackId := TlNewAudioTrackId;
  if ImportBrowserFileToTimeline(dlgRecSaved.FileName, trackId, RecordingPosition) then
    RefreshTimelineTab;
end;

'''+s[b:]
s=s.replace('  if (FRec = nil) or (FProject = nil) then Exit;\n  if FRec.TakeCount = 0 then','  if (FRec = nil) or (FProject = nil) or (FRecWriter <> nil) or FRecCommitted then Exit;\n  if FRec.TakeCount = 0 then')
s=s.replace("    FCmds.Perform(TCommitTakeCommand.Create(FProject, 0, specs, 'Recorded'));", "    FCmds.Perform(TCommitTakeCommand.Create(FProject, FRecTrackId, specs, 'Recorded'));\n    FRecCommitted := True;")
s=s.replace('  if FRecovery2 = nil then Exit;', '  if (FRecovery2 = nil) or (FRecWriter <> nil) then Exit;')
s=s.replace('  if FRec = nil then Exit;\n  mnuRecCommit.Enabled := FRec.TakeCount > 0;', '''  if FRec = nil then Exit;
  btnRecSaved.Enabled := FRecWriter = nil;
  btnRecScan.Enabled := FRecWriter = nil;
  cboRecFormat.Enabled := FRecWriter = nil;
  if FRecWriter <> nil then
  begin
    btnRecArm.Caption := 'Stop and add to timeline';
    mnuRecArm.Caption := btnRecArm.Caption;
    pmRecArm.Caption := btnRecArm.Caption;
    btnRecCommit.Enabled := False;
    mnuRecCommit.Enabled := False;
    pmRecCommit.Enabled := False;
    lblRecDestination.Caption := Format('Capturing %.1f s | %d Hz | %d channels | target track %d',
      [FRecWriter.FramesConsumed / FRec.Settings.SampleRate, FRec.Settings.SampleRate,
       FRec.Settings.Channels, FRecTrackId]);
    stbMain.SimpleText := lblRecDestination.Caption;
    Exit; { no access to takes while the writer owns the engine }
  end;
  btnRecArm.Caption := 'Start live recording';
  mnuRecArm.Caption := btnRecArm.Caption;
  pmRecArm.Caption := btnRecArm.Caption;
  lblRecDestination.Caption := Format('Insert at %.3f s. Selected audio track, or a new track. Full input until Stop.', [RecordingPosition]);
  mnuRecCommit.Enabled := (FRec.TakeCount > 0) and not FRecCommitted;
  btnRecCommit.Enabled := mnuRecCommit.Enabled;''')
s=s.replace('  if (FRec = nil) or (FRec.TakeCount = 0) then','  if FRecWriter <> nil then Exit;\n  if (FRec = nil) or (FRec.TakeCount = 0) then')
s=s.replace('No takes yet - configure a pass and press "Arm + simulate record".','Select a timeline destination, then start live recording or add saved audio.')
s=s.replace('procedure TfrmMain.FormClose(Sender: TObject; var Action: TCloseAction);\nbegin','procedure TfrmMain.FormClose(Sender: TObject; var Action: TCloseAction);\nbegin\n  StopLiveRecording;')
s=s.replace('  tmrUI.Enabled := False;','  tmrUI.Enabled := False;\n  StopLiveRecording;',1)
s=s.replace('  FinishSunoJob;\n  FinishTimelineExport;', '''  if FRecWriter <> nil then
  begin
    RefreshRecordingTab;
    if (FRecWriter.ErrorCount > 0) or (FRecWriter.RingOverruns > 0) or
       (App.Audio.State <> aesRunning) or
       ((FRecWriter.FramesConsumed = 0) and (GetTickCount64 - FRecStarted > 5000)) then
      StopLiveRecording;
  end;
  FinishSunoJob;
  FinishTimelineExport;''')
for name in ['OpenProjectFile','btnProjectNewClick','btnAudioStopClick','btnAudioReopenClick','btnVoiceRecordClick','btnSettingsSaveClick']:
 a=s.index('procedure TfrmMain.'+name+'(');b=s.index('\nbegin',a)+len('\nbegin');s=s[:b]+"\n  if FRecWriter <> nil then\n  begin\n    MessageDlg('Stop live recording before changing the project or audio input.', mtInformation, [mbOK], 0);\n    Exit;\n  end;"+s[b:]
s=s.replace("IncludeTrailingPathDelimiter(App.Paths.Cache) + 'recordings')", "RecordingRootPath)")
p.write_text(s,encoding='utf-8-sig')
hide=['lblRecChannels','cboRecChannels','lblRecDuration','edtRecDuration','lblRecPreRoll','edtRecPreRoll','lblRecCountIn','edtRecCountIn','lblRecPunch','cboRecPunch','lblRecPunchIn','edtRecPunchIn','lblRecPunchOut','edtRecPunchOut','chkRecLoop','lblRecLoopStart','edtRecLoopStart','lblRecLoopEnd','edtRecLoopEnd','chkRecMonitor']
for ext in ['dfm','lfm']:
 p=Path('src/ui/UDAW.UI.MainForm.'+ext);s=p.read_text(encoding='utf-8-sig')
 for name in hide:s=re.sub(r'(object '+name+r': [^\n]+\n)',r'\1          Visible = False\n',s)
 for name in ['btnRecArm','btnRecCommit','btnRecScan']:s=re.sub(r'        object '+name+r': TButton\n.*?        end\n','',s,flags=re.S)
 a=s.index('      object pnlRecReadout:');prefix=s[:a];end=prefix.rfind('      end');controls=''
 for i,(name,caption,event,width) in enumerate([('btnRecArm','Start live recording','btnRecArmClick',190),('btnRecCommit','Retry adding take','btnRecCommitClick',150),('btnRecSaved','Add saved audio...','btnRecSavedClick',150),('btnRecScan','Recover unfinished takes','btnRecScanClick',190)]):
  controls+=f"        object {name}: TButton\n          Left = {8+i*200}\n          Top = 48\n          Width = {width}\n          Height = 28\n          Caption = '{caption}'\n          TabOrder = {12+i}\n          OnClick = {event}\n        end\n"
 controls+="        object lblRecDestination: TLabel\n          Left = 8\n          Top = 92\n          Width = 780\n          Height = 18\n          Caption = 'Full input until Stop. Select input device and enable capture in Settings.'\n        end\n"
 s=prefix[:end]+controls+prefix[end:]+s[a:]
 s=s.replace("Caption = 'Arm + simulate record'", "Caption = 'Start / stop live recording'").replace("Caption = 'Commit last take(s) to timeline'", "Caption = 'Retry adding recorded take'")
 a=s.rfind('end');s=s[:a]+"  object dlgRecSaved: TOpenDialog\n    Filter = 'Audio files|*.wav;*.flac;*.mp3;*.mp4;*.m4a|All files|*.*'\n    Options = [ofFileMustExist, ofEnableSizing]\n    Title = 'Add full saved audio to timeline'\n    Left = 880\n    Top = 640\n  end\n"+s[a:];p.write_text(s,encoding='utf-8-sig')
