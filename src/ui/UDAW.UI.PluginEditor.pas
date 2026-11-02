unit UDAW.UI.PluginEditor;
{$I udaw.inc}

{ The Python plug-in editor / creator.

  Toolbar:  New | Open | Save | Save As   -   Validate | Run | Stop | Test signal   -   Add to mixer
    Validate  checks the script without running it on audio: syntax, loading, parameters, the window
              description, and a test signal through process() (speed and sanity); results are
              listed under Problems, a click jumps to the line.
    Run       starts the plug-in, opens its window (change the controls as you like) and feeds it
              a plucked-string test signal so the meters and pictures move.
    Add to mixer  puts the plug-in, with the settings currently shown in its window, on the chosen
              Timeline lane / bus or Tracker channel.

  The editor owns no audio engine: it hosts a scratch instance of the script (UDAW.Scripting.PyPlugin)
  and reports everything to the application through events. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, System.JSON, System.IOUtils,
  System.Generics.Collections, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.Graphics, Vcl.ExtCtrls, System.StrUtils, System.UITypes, UDAW.GL.Widgets, UDAW.UI.FileDialog, UDAW.Scripting.PyPlugin,
  UDAW.UI.PluginWindow;

type
  TPyTarget = record
    Tracker: Boolean;
    StripId: Integer;
    Caption: string;
  end;

  { AFilePath: the saved script file the insert will point at }
  TPyAddEvent = procedure(const ATarget: TPyTarget; const AFilePath, APluginName,
    AValuesJson, AStateJson, ANames: string) of object;

  TfrmPyEditor = class(TForm)
    pnlToolbar: TGLPanel;
    btnNew: TGLButton;
    btnOpen: TGLButton;
    btnSave: TGLButton;
    btnSaveAs: TGLButton;
    btnValidate: TGLButton;
    btnRun: TGLButton;
    btnStop: TGLButton;
    lblTarget: TGLLabel;
    cboTarget: TGLCombo;
    btnAdd: TGLButton;
    memCode: TGLMemo;
    splBottom: TGLSplitter;
    pcOut: TGLPageControl;
    tabProblems: TGLPage;
    lstIssues: TGLList;
    tabOutput: TGLPage;
    memOut: TGLMemo;
    stbMain: TGLStatusBar;
    dlgOpen: TGLOpenDialog;
    dlgSave: TGLSaveDialog;
    procedure FormCreate(Sender: TObject);
    procedure FormActivate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure btnNewClick(Sender: TObject);
    procedure btnOpenClick(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure btnSaveAsClick(Sender: TObject);
    procedure btnValidateClick(Sender: TObject);
    procedure btnRunClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure btnAddClick(Sender: TObject);
    procedure memCodeChange(Sender: TObject);
    procedure lstIssuesClick(Sender: TObject);
  private
    FFileName: string;
    FModified, FLoading, FBusy: Boolean;
    FIssueLines: TArray<Integer>;
    FHost: TPyPluginHost;
    FPreview: TfrmPyPlugin;
    FTargets: TArray<TPyTarget>;
    FOnAdd: TPyAddEvent;
    FOnRefreshTargets: TNotifyEvent;
    FOnClosed: TNotifyEvent;
    FSampleRate, FChannels, FMaxFrames: Integer;
    procedure SetFile(const AFileName: string);
    procedure UpdateCaption;
    function LoadFile(const AFileName: string): Boolean;
    function SaveTo(const AFileName: string): Boolean;
    function SaveCurrent: Boolean;
    function CheckSave: Boolean;
    procedure SetText(const AText: string);
    procedure ShowStatus(const AText: string);
    procedure AppendOutput(ALine: string);
    procedure PreviewClosing(Sender: TObject);
    procedure PreviewAddRequested(Sender: TObject);
    function RunValidation(AQuiet: Boolean): Boolean;
    function StartHost(AShowWindow: Boolean): Boolean;
    procedure StopHost;
    procedure GotoLine(ALine: Integer);
    function ScratchFile: string;
    procedure SyncButtons;
  public
    { Audio format the scratch instance runs at: the project's }
    procedure SetFormat(ASampleRate, AChannels, AMaxFrames: Integer);
    { the places the plug-in can be added; ASelect is the index to preselect (or -1) }
    procedure SetTargets(const ATargets: TArray<TPyTarget>; ASelect: Integer);
    { opens a script file, or starts a new one when AFileName is '' }
    procedure OpenScript(const AFileName: string);
    procedure NewScript;
    property OnAddToMixer: TPyAddEvent read FOnAdd write FOnAdd;
    property OnRefreshTargets: TNotifyEvent read FOnRefreshTargets write FOnRefreshTargets;
    property OnClosed: TNotifyEvent read FOnClosed write FOnClosed;
  end;

implementation

{$R *.dfm}

const
  EDITOR_TITLE = 'Python Plug-in Editor';

procedure TfrmPyEditor.FormCreate(Sender: TObject);
begin
  FSampleRate := 48000;
  FChannels := 2;
  FMaxFrames := 512;
  KeyPreview := True;
  pcOut.ActivePageIndex := 0;
  NewScript;
  SyncButtons;
end;

procedure TfrmPyEditor.FormActivate(Sender: TObject);
begin
  if Assigned(FOnRefreshTargets) then FOnRefreshTargets(Self);
end;

procedure TfrmPyEditor.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := CheckSave;
end;

procedure TfrmPyEditor.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  StopHost;
  Action := caFree;
  if Assigned(FOnClosed) then FOnClosed(Self);
end;

procedure TfrmPyEditor.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (ssCtrl in Shift) and (Key = Ord('S')) then
  begin
    if ssShift in Shift then btnSaveAsClick(nil) else btnSaveClick(nil);
    Key := 0;
  end
  else if (ssCtrl in Shift) and (Key = Ord('O')) then
  begin
    btnOpenClick(nil);
    Key := 0;
  end
  else if (ssCtrl in Shift) and (Key = Ord('N')) then
  begin
    btnNewClick(nil);
    Key := 0;
  end
  else if Key = VK_F5 then
  begin
    btnRunClick(nil);
    Key := 0;
  end
  else if Key = VK_F6 then
  begin
    btnValidateClick(nil);
    Key := 0;
  end;
end;

procedure TfrmPyEditor.SetFormat(ASampleRate, AChannels, AMaxFrames: Integer);
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  if AMaxFrames > 0 then FMaxFrames := AMaxFrames;
end;

procedure TfrmPyEditor.SetTargets(const ATargets: TArray<TPyTarget>; ASelect: Integer);
var
  i, keep: Integer;
begin
  keep := cboTarget.ItemIndex;
  FTargets := ATargets;
  cboTarget.Items.BeginUpdate;
  try
    cboTarget.Items.Clear;
    for i := 0 to High(FTargets) do cboTarget.Items.Add(FTargets[i].Caption);
  finally
    cboTarget.Items.EndUpdate;
  end;
  if (ASelect >= 0) and (ASelect <= High(FTargets)) then cboTarget.ItemIndex := ASelect
  else if (keep >= 0) and (keep <= High(FTargets)) then cboTarget.ItemIndex := keep
  else if Length(FTargets) > 0 then cboTarget.ItemIndex := 0;
  SyncButtons;
end;

procedure TfrmPyEditor.SyncButtons;
begin
  btnStop.Enabled := FHost <> nil;
  btnAdd.Enabled := (cboTarget.ItemIndex >= 0) and not FBusy;
  btnValidate.Enabled := not FBusy;
  btnRun.Enabled := not FBusy;
end;

procedure TfrmPyEditor.ShowStatus(const AText: string);
begin
  stbMain.SimpleText := AText;
end;

procedure TfrmPyEditor.UpdateCaption;
var
  nm: string;
begin
  if FFileName <> '' then nm := ExtractFileName(FFileName) else nm := 'untitled.py';
  Caption := EDITOR_TITLE + ' - ' + nm + IfThen(FModified, ' *', '');
end;

procedure TfrmPyEditor.SetFile(const AFileName: string);
begin
  FFileName := AFileName;
  UpdateCaption;
end;

procedure TfrmPyEditor.SetText(const AText: string);
begin
  FLoading := True;
  try
    memCode.Text := AText;
  finally
    FLoading := False;
  end;
  FModified := False;
  lstIssues.Items.Clear;
  SetLength(FIssueLines, 0);
  UpdateCaption;
end;

procedure TfrmPyEditor.memCodeChange(Sender: TObject);
begin
  if FLoading then Exit;
  if not FModified then
  begin
    FModified := True;
    UpdateCaption;
  end;
end;

function TfrmPyEditor.CheckSave: Boolean;
begin
  Result := True;
  if not FModified then Exit;
  case MessageDlg('Save the changes to ' + IfThen(FFileName <> '', ExtractFileName(FFileName), 'this plug-in') + '?',
         mtConfirmation, [mbYes, mbNo, mbCancel], 0) of
    mrYes: Result := SaveCurrent;
    mrNo: Result := True;
  else
    Result := False;
  end;
end;

procedure TfrmPyEditor.NewScript;
begin
  if not CheckSave then Exit;
  StopHost;
  SetText(PyTemplateSource);
  SetFile('');
  ShowStatus('New plug-in from the template - edit it, Validate, then Run.');
end;

function TfrmPyEditor.LoadFile(const AFileName: string): Boolean;
begin
  Result := False;
  try
    SetText(TFile.ReadAllText(AFileName, TEncoding.UTF8));
    SetFile(AFileName);
    Result := True;
  except
    on E: Exception do MessageDlg('Could not open ' + AFileName + ':'#13#10 + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TfrmPyEditor.OpenScript(const AFileName: string);
begin
  if AFileName = '' then
  begin
    NewScript;
    Exit;
  end;
  if not CheckSave then Exit;
  StopHost;
  if LoadFile(AFileName) then ShowStatus('Opened ' + AFileName);
end;

function TfrmPyEditor.SaveTo(const AFileName: string): Boolean;
var
  enc: TEncoding;
begin
  Result := False;
  enc := TUTF8Encoding.Create(False);
  try
    try
      ForceDirectories(ExtractFilePath(AFileName));
      TFile.WriteAllText(AFileName, StringReplace(memCode.Text, #13#10, #10, [rfReplaceAll]), enc);
      SetFile(AFileName);
      FModified := False;
      UpdateCaption;
      ShowStatus('Saved ' + AFileName);
      Result := True;
    except
      on E: Exception do MessageDlg('Could not save ' + AFileName + ':'#13#10 + E.Message, mtError, [mbOK], 0);
    end;
  finally
    enc.Free;
  end;
end;

function TfrmPyEditor.SaveCurrent: Boolean;
begin
  if FFileName = '' then
  begin
    dlgSave.InitialDir := PyPluginsFolder;
    dlgSave.FileName := 'my_plugin.py';
    if not dlgSave.Execute then Exit(False);
    Result := SaveTo(dlgSave.FileName);
  end
  else
    Result := SaveTo(FFileName);
end;

procedure TfrmPyEditor.btnNewClick(Sender: TObject);
begin
  NewScript;
end;

procedure TfrmPyEditor.btnOpenClick(Sender: TObject);
begin
  if not CheckSave then Exit;
  dlgOpen.InitialDir := IfThen(FFileName <> '', ExtractFilePath(FFileName), PyPluginsFolder);
  if not dlgOpen.Execute then Exit;
  StopHost;
  if LoadFile(dlgOpen.FileName) then ShowStatus('Opened ' + dlgOpen.FileName);
end;

procedure TfrmPyEditor.btnSaveClick(Sender: TObject);
begin
  SaveCurrent;
end;

procedure TfrmPyEditor.btnSaveAsClick(Sender: TObject);
begin
  dlgSave.InitialDir := IfThen(FFileName <> '', ExtractFilePath(FFileName), PyPluginsFolder);
  dlgSave.FileName := IfThen(FFileName <> '', ExtractFileName(FFileName), 'my_plugin.py');
  if dlgSave.Execute then SaveTo(dlgSave.FileName);
end;

procedure TfrmPyEditor.AppendOutput(ALine: string);
begin
  memOut.Lines.Add(ALine);
  while memOut.Lines.Count > 1000 do memOut.Lines.Delete(0);
end;

function TfrmPyEditor.ScratchFile: string;
var
  nm: string;
begin
  nm := 'untitled.py';
  if FFileName <> '' then nm := ExtractFileName(FFileName);
  Result := IncludeTrailingPathDelimiter(IfThen(PyScratchFolder <> '', PyScratchFolder, PyPluginsFolder)) + nm;
end;

{ ---- Validate ---- }

function TfrmPyEditor.RunValidation(AQuiet: Boolean): Boolean;
var
  issues: TArray<TPyIssue>;
  err: string;
  i, errors, warnings: Integer;
  tag: string;
begin
  Result := False;
  FBusy := True;
  SyncButtons;
  ShowStatus('Checking the plug-in...');
  try
    if not PyValidate(memCode.Text, ScratchFile, issues, err,
         procedure
         begin
           Application.ProcessMessages;
         end) then
    begin
      lstIssues.Items.Clear;
      SetLength(FIssueLines, 0);
      lstIssues.Items.Add('ERROR  ' + StringReplace(err, #13#10, '  ', [rfReplaceAll]));
      SetLength(FIssueLines, 1);
      pcOut.ActivePageIndex := 0;
      ShowStatus('The check could not run.');
      Exit;
    end;
  finally
    FBusy := False;
    SyncButtons;
  end;
  errors := 0;
  warnings := 0;
  lstIssues.Items.BeginUpdate;
  try
    lstIssues.Items.Clear;
    SetLength(FIssueLines, Length(issues));
    for i := 0 to High(issues) do
    begin
      if SameText(issues[i].Severity, 'error') then
      begin
        tag := 'ERROR   ';
        Inc(errors);
      end
      else if SameText(issues[i].Severity, 'warning') then
      begin
        tag := 'warning ';
        Inc(warnings);
      end
      else
        tag := 'info    ';
      if issues[i].Line > 0 then
        lstIssues.Items.Add(Format('%sline %d: %s', [tag, issues[i].Line, issues[i].Msg]))
      else
        lstIssues.Items.Add(tag + issues[i].Msg);
      FIssueLines[i] := issues[i].Line;
    end;
  finally
    lstIssues.Items.EndUpdate;
  end;
  pcOut.ActivePageIndex := 0;
  Result := errors = 0;
  if Result then
    ShowStatus(Format('Validation passed (%d warning(s)).', [warnings]))
  else
    ShowStatus(Format('Validation found %d error(s) and %d warning(s).', [errors, warnings]));
  if (errors > 0) and not AQuiet then
    for i := 0 to High(issues) do
      if SameText(issues[i].Severity, 'error') and (issues[i].Line > 0) then
      begin
        GotoLine(issues[i].Line);
        Break;
      end;
end;

procedure TfrmPyEditor.btnValidateClick(Sender: TObject);
begin
  RunValidation(False);
end;

procedure TfrmPyEditor.lstIssuesClick(Sender: TObject);
var
  i: Integer;
begin
  i := lstIssues.ItemIndex;
  if (i >= 0) and (i <= High(FIssueLines)) and (FIssueLines[i] > 0) then GotoLine(FIssueLines[i]);
end;

procedure TfrmPyEditor.GotoLine(ALine: Integer);
var
  t: string;
  pos_, cnt, stop: Integer;
begin
  t := memCode.Text;
  pos_ := 1;
  cnt := 1;
  while (cnt < ALine) and (pos_ <= Length(t)) do
  begin
    if t[pos_] = #10 then Inc(cnt);
    Inc(pos_);
  end;
  stop := pos_;
  while (stop <= Length(t)) and (t[stop] <> #10) and (t[stop] <> #13) do Inc(stop);
  memCode.SelStart := pos_ - 1;
  memCode.SelLength := stop - pos_;
  if memCode.CanFocus then memCode.SetFocus;
end;

{ ---- running the scratch instance ---- }

procedure TfrmPyEditor.StopHost;
begin
  if FPreview <> nil then
  begin
    FPreview.OnEditorClosing := nil;
    FPreview.OnLogged := nil;
    FPreview.Close;
    FPreview := nil;
  end;
  if FHost <> nil then
  begin
    FHost.AudioActive := False;
    FHost.Release;
    FHost := nil;
  end;
  SyncButtons;
end;

procedure TfrmPyEditor.PreviewClosing(Sender: TObject);
begin
  FPreview := nil;
end;

procedure TfrmPyEditor.PreviewAddRequested(Sender: TObject);
begin
  btnAddClick(nil);
end;

function TfrmPyEditor.StartHost(AShowWindow: Boolean): Boolean;
var
  host: TPyPluginHost;
  err: string;
  scriptDir: string;
  rate: Integer;
begin
  Result := False;
  StopHost;
  rate := FSampleRate;
  if Assigned(PyAuditionRate) and (PyAuditionRate() > 0) then rate := PyAuditionRate();   // the speakers' rate, so Listen works
  host := TPyPluginHost.Create;
  FBusy := True;
  SyncButtons;
  ShowStatus('Starting the plug-in...');
  try
    scriptDir := '';
    if FFileName <> '' then scriptDir := ExtractFilePath(FFileName);
    if not host.Start(memCode.Text, IfThen(FFileName <> '', ExtractFileName(FFileName), 'untitled.py'),
         scriptDir, '', '', rate, FChannels, FMaxFrames, err) then
    begin
      host.Release;
      AppendOutput('Could not start the plug-in:');
      AppendOutput(err);
      pcOut.ActivePageIndex := 1;
      ShowStatus('The plug-in did not start - see Output.');
      Exit;
    end;
  finally
    FBusy := False;
    SyncButtons;
  end;
  FHost := host;
  FHost.AudioActive := True;
  AppendOutput(Format('-- started "%s" %s (Python %s) --', [FHost.Name, FHost.Version, FHost.PythonVersion]));
  if AShowWindow then
  begin
    FPreview := TfrmPyPlugin.Create(Self);
    FPreview.OnEditorClosing := PreviewClosing;
    FPreview.OnLogged := AppendOutput;
    FPreview.SourceFile := FFileName;
    FPreview.AutoListen := True;      // hear it on the guitar phrase (or the highlighted Timeline range) straight away
    FPreview.OnAddToMixer := PreviewAddRequested;
    if not FPreview.Open(FHost, '', FHost.Name, nil) then
    begin
      FPreview.Free;
      FPreview := nil;
    end
    else
      FPreview.Show;
  end;
  ShowStatus('Running. Listen plays it on a guitar phrase or your highlighted Timeline range; Add to Mixer keeps the settings.');
  SyncButtons;
  Result := True;
end;

procedure TfrmPyEditor.btnRunClick(Sender: TObject);
begin
  if not RunValidation(True) then
  begin
    ShowStatus('Fix the errors under Problems first.');
    Exit;
  end;
  pcOut.ActivePageIndex := 1;
  StartHost(True);
end;

procedure TfrmPyEditor.btnStopClick(Sender: TObject);
begin
  StopHost;
  ShowStatus('Stopped.');
end;

{ ---- Add to mixer ---- }

procedure TfrmPyEditor.btnAddClick(Sender: TObject);
var
  st, vals, custom, names: string;
  v: TJSONValue;
  o: TJSONObject;
  target: TPyTarget;
begin
  if (cboTarget.ItemIndex < 0) or (cboTarget.ItemIndex > High(FTargets)) then
  begin
    MessageDlg('Choose where to put the plug-in first.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if not Assigned(FOnAdd) then Exit;
  target := FTargets[cboTarget.ItemIndex];
  { the project points at the script file, so it has to exist on disk and be what is in the editor }
  if (FFileName = '') or FModified then
  begin
    if MessageDlg('The project keeps a link to this plug-in''s script file, not a copy, so the script must be saved ' +
         'first. Save it now?', mtConfirmation, [mbYes, mbCancel], 0) <> mrYes then Exit;
    if not SaveCurrent then Exit;
  end;
  if not RunValidation(True) then
  begin
    ShowStatus('Fix the errors under Problems before adding the plug-in.');
    Exit;
  end;
  { the settings come from the running instance: start one (without a window) if none is up }
  if (FHost = nil) or FHost.Dead then
    if not StartHost(False) then Exit;
  st := FHost.CaptureState;
  vals := '';
  custom := '';
  v := TJSONObject.ParseJSONValue(st);
  try
    if v is TJSONObject then
    begin
      o := TJSONObject(v);
      if o.GetValue('values') <> nil then vals := o.GetValue('values').ToJSON;
      if (o.GetValue('custom') <> nil) and not (o.GetValue('custom') is TJSONNull) then
        custom := o.GetValue('custom').ToJSON;
    end;
  finally
    v.Free;
  end;
  names := FHost.ParamNames;
  FOnAdd(target, FFileName, FHost.Name, vals, custom, names);
  ShowStatus('Added "' + FHost.Name + '" to ' + target.Caption + '.');
end;

end.
