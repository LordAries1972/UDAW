from pathlib import Path
import re
p=Path('src/ui/UDAW.UI.MainForm.pas');s=p.read_text(encoding='utf-8-sig').replace('    lblRecDestination: TLabel;', '    lblRecDestination: TLabel;\n    lblRecMicState: TLabel;')
s=s.replace('  if FRec = nil then Exit;\n  btnRecSaved.Enabled', '''  if FRec = nil then Exit;
  if (App <> nil) and (App.Audio <> nil) and
     (App.Audio.State = aesRunning) and (App.Audio.Granted.CaptureChannels > 0) and
     (Pos('software', LowerCase(App.Audio.BackendName)) = 0) then
  begin
    if FRecWriter <> nil then
      lblRecMicState.Caption := 'Microphone: ON | Recording: ON'
    else
      lblRecMicState.Caption := 'Microphone: ON | Recording: OFF';
    lblRecMicState.Hint := App.Audio.Granted.CaptureDeviceName;
  end
  else
    lblRecMicState.Caption := 'Microphone: OFF | Recording: OFF';
  btnRecSaved.Enabled''')
s=s.replace('      if FRecWriter <> nil then StopLiveRecording;\n      memRec.Lines.Text', '      if FRecWriter <> nil then StopLiveRecording\n      else FreeAndNil(FRecRing);\n      FSyncProgressActive := False;\n      memRec.Lines.Text')
# Local help ships with the build; this version-aligned copy takes priority.
s=s.replace('  htmlText, errMsg: string;\nbegin\n  if not FetchUDAWHelpPage(htmlText, errMsg) then', '''  htmlText, errMsg, localHelp: string;
  localText: TStringList;
begin
  localHelp := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'WebCache' + PathDelim + 'udaw-help.html';
  if FileExists(localHelp) then
  begin
    localText := TStringList.Create;
    try
      localText.LoadFromFile(localHelp, TEncoding.UTF8);
      htmlText := localText.Text;
    finally
      localText.Free;
    end;
  end
  else if not FetchUDAWHelpPage(htmlText, errMsg) then''')
p.write_text(s,encoding='utf-8-sig')
for ext in ['dfm','lfm']:
 p=Path('src/ui/UDAW.UI.MainForm.'+ext);s=p.read_text(encoding='utf-8-sig');a=s.index('        object lblRecDestination:');s=s[:a]+'''        object lblRecMicState: TLabel
          Left = 370
          Top = 10
          Width = 410
          Height = 18
          Caption = 'Microphone: OFF | Recording: OFF'
          ShowHint = True
        end
'''+s[a:];p.write_text(s,encoding='utf-8-sig')
p=Path('src/recording/UDAW.Recording.ChunkFile.pas');s=p.read_text(encoding='utf-8-sig').replace('  if FileExists(ChunkMarkerPath(FSessionDir)) then\n    DeleteFile', '  if (not AKeepRecoveryMarker) and FileExists(ChunkMarkerPath(FSessionDir)) then\n    DeleteFile');p.write_text(s,encoding='utf-8-sig')
# Synchronize version metadata.
for file in ['resources/UDAW.rc','src/common/UDAW.Version.pas']:
 p=Path(file);s=p.read_text(encoding='utf-8-sig').replace('1,0,0,178','1,0,0,179').replace('1.0.0.178','1.0.0.179').replace('1.0.178','1.0.179').replace('BUILD_NUMBER = 178','BUILD_NUMBER = 179');p.write_text(s,encoding='utf-8-sig')
