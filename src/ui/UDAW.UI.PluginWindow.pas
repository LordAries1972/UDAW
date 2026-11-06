unit UDAW.UI.PluginWindow;
{$I udaw.inc}

{ The window of one running Python plug-in: the controls the script described, drawn with UDAW's own
  OpenGL widgets (see UDAW.UI.PluginUI) and scaled with the window, a Listen row to hear the plug-in on
  program material before it goes on the mixer, an About box (name, version, author), a log of what the
  script printed, and Close.

  Used three ways:
    * from the Plugins menu or the editor: a stand-alone instance to try (Add to Mixer puts it on a strip);
    * from the mixer: double-click a Python insert. The window attaches to the instance that is playing
      when there is one (live meters and pictures) and otherwise starts its own; the settings are written
      back to the project when the window closes or Save is pressed. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, System.Types, System.Generics.Collections, Vcl.Controls, Vcl.Forms,
  Vcl.Dialogs, Vcl.Graphics, Vcl.ExtCtrls, System.StrUtils, System.UITypes, UDAW.GL.Widgets,
  UDAW.Audio.Source, UDAW.Audio.Ring, UDAW.MIDI.Types, UDAW.MIDI.Hardware, UDAW.Scripting.PyPlugin, UDAW.Scripting.PyAudition, UDAW.UI.PluginUI;

type
  TPyRangeFunc = reference to function(ARate: Integer; out APlanar: TPyPlanar): Boolean;
  TPyAttachFunc = reference to function(const ASource: IAudioSource): Boolean;
  { the input device the engine captured: its channel count and rate, or why live input is not available }
  TPyLiveInfoFunc = reference to function(out AChannels, ARate: Integer; out AMsg: string): Boolean;
  { takes over the speakers with a live source and routes the captured input into its ring }
  TPyLiveAttachFunc = reference to function(const ASource: IAudioSource; ARing: TAudioRing;
    out AMsg: string): Boolean;

  TfrmPyPlugin = class(TForm)
    pnlTop: TGLPanel;
    lblInfo: TGLLabel;
    btnAbout: TGLButton;
    btnLog: TGLButton;
    btnDefaults: TGLButton;
    btnSave: TGLButton;
    btnAdd: TGLButton;
    btnClose: TGLButton;
    pnlAudition: TGLPanel;
    lblHear: TGLLabel;
    btnListen: TGLButton;
    btnBypass: TGLButton;
    cboSource: TGLCombo;
    cboMidi: TGLCombo;
    lblMidiOut: TGLLabel;
    cboMidiOut: TGLCombo;
    pnlSurface: TGLPanel;
    pnlLog: TGLPanel;
    memLog: TGLMemo;
    pnlStatus: TGLPanel;
    lblStatus: TGLLabel;
    tmrPump: TTimer;
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormDestroy(Sender: TObject);
    procedure btnLogChange(Sender: TObject);
    procedure btnDefaultsClick(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure btnAddClick(Sender: TObject);
    procedure btnAboutClick(Sender: TObject);
    procedure btnCloseClick(Sender: TObject);
    procedure btnListenChange(Sender: TObject);
    procedure btnBypassChange(Sender: TObject);
    procedure cboSourceChange(Sender: TObject);
    procedure cboMidiChange(Sender: TObject);
    procedure cboMidiOutChange(Sender: TObject);
    procedure pnlSurfaceResize(Sender: TObject);
    procedure tmrPumpTimer(Sender: TObject);
  private
    FHost: TPyPluginHost;
    FBinder: TPyUiBinder;
    FIid: string;
    FSave: TProc<string>;
    FOnAdd: TNotifyEvent;
    FDirty, FUiGuard, FAutoListen: Boolean;
    FLastLive, FLastStatus: UInt64;
    FAud: TPyAuditionSource;
    FAudIntf: IAudioSource;
    FCaption: string;
    FMidi: TMidiInputDevice;
    FMidiDevs: TMidiDeviceList;
    FMidiOut: TMidiOutputDevice;
    FMidiOutDevs: TMidiDeviceList;
    FMidiOutBuf: TList<TPyMidiOut>;
    procedure FillMidiDevices;
    procedure PumpMidiOut;
    procedure CloseMidiOut;
    procedure MidiEvent(Sender: TObject; const AMsg: TMidiMessage; ATimestampMs: Cardinal);
    procedure LogLine(ALevel, AText: string);
    procedure PluginError(AText: string);
    procedure ParamChanged(AId: string; AValue: Double);
    procedure FollowLivePlugin;
    procedure UpdateStatus;
    procedure SaveNow;
    procedure ShowLog(AShow: Boolean);
    procedure StartListening;
    procedure StopListening;
  public
    { Set by the caller so the window's geometry can be remembered, like the other plug-in editors }
    WindowKey: string;
    OnEditorClosing: TNotifyEvent;
    { full path of the script this window runs, for Add to Mixer }
    SourceFile: string;
    { every log line the script prints, for an editor that shows them in its own Output tab }
    OnLogged: TProc<string>;
    { AHost: a started plug-in (this window keeps its own reference). AIid: the insert's instance
      id, '' for a stand-alone instance. ASave receives the captured state JSON when the settings are
      saved; nil when there is no insert to save into. }
    function Open(AHost: TPyPluginHost; const AIid, ACaption: string; const ASave: TProc<string>): Boolean;
    { another window took over the speakers }
    procedure ListenEnded;
    { start playing program material through the plug-in as soon as the window opens }
    property AutoListen: Boolean read FAutoListen write FAutoListen;
    { when assigned the window offers Add to Mixer (the creator puts the plug-in on the chosen strip) }
    property OnAddToMixer: TNotifyEvent read FOnAdd write FOnAdd;
    property Host: TPyPluginHost read FHost;
  end;

var
  { the application's audio engine, for listening: its sample rate (0 = unavailable), taking over the
    output with a source (nil releases it), and the Timeline range the user highlighted }
  PyAuditionRate: TFunc<Integer>;
  PyAuditionAttach: TPyAttachFunc;
  PyAuditionRange: TPyRangeFunc;
  PyLiveInfo: TPyLiveInfoFunc;
  PyAuditionAttachLive: TPyLiveAttachFunc;

{ the speakers went to something else (Timeline playback): no window is listening any more }
procedure PyAuditionReleaseAll;

implementation

{$R *.dfm}

const
  LOG_ROWS_MAX = 500;

var
  GAuditionOwner: TfrmPyPlugin;

procedure PyAuditionReleaseAll;
begin
  if GAuditionOwner <> nil then GAuditionOwner.ListenEnded;
end;

function TfrmPyPlugin.Open(AHost: TPyPluginHost; const AIid, ACaption: string;
  const ASave: TProc<string>): Boolean;
var
  w, h: Integer;
begin
  Result := False;
  FIid := AIid;
  FSave := ASave;
  FHost := AHost;
  FHost.Retain;
  FBinder := TPyUiBinder.Create(FHost, pnlSurface);
  FBinder.OnLog := LogLine;
  FBinder.OnError := PluginError;
  FBinder.OnParam := ParamChanged;
  if not FBinder.Build then
  begin
    MessageDlg('This plug-in did not describe a window.', mtInformation, [mbOK], 0);
    Exit;
  end;
  FCaption := ACaption;
  Caption := ACaption;
  if FBinder.WindowTitle <> '' then Caption := ACaption + ' - ' + FBinder.WindowTitle;
  lblInfo.Caption := Trim(FHost.Name + '  ' + FHost.Version);
  btnSave.Visible := Assigned(FSave);
  btnAdd.Visible := Assigned(FOnAdd);
  pnlAudition.Visible := Assigned(PyAuditionAttach);
  FillMidiDevices;
  w := Max(FBinder.WindowWidth, 520);
  h := FBinder.WindowHeight;
  ClientWidth := w;
  ClientHeight := h + pnlTop.Height + pnlStatus.Height + IfThen(pnlAudition.Visible, pnlAudition.Height, 0) +
    IfThen(pnlLog.Visible, pnlLog.Height, 0);
  FBinder.Rescale;
  memLog.Text := FHost.LogText;
  FDirty := False;
  tmrPump.Enabled := True;
  if FAutoListen and pnlAudition.Visible then
  begin
    FUiGuard := True;
    btnListen.Down := True;
    FUiGuard := False;
    StartListening;
  end;
  Result := True;
end;

procedure TfrmPyPlugin.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  tmrPump.Enabled := False;
  FreeAndNil(FMidi);
  CloseMidiOut;
  StopListening;
  if FDirty and Assigned(FSave) then SaveNow;
  if Assigned(OnEditorClosing) then OnEditorClosing(Self);
  Action := caFree;
end;

procedure TfrmPyPlugin.FormDestroy(Sender: TObject);
begin
  tmrPump.Enabled := False;
  FreeAndNil(FMidi);
  CloseMidiOut;
  FreeAndNil(FMidiOutBuf);
  StopListening;
  FreeAndNil(FBinder);
  if FHost <> nil then
  begin
    FHost.Release;
    FHost := nil;
  end;
end;

procedure TfrmPyPlugin.btnCloseClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmPyPlugin.pnlSurfaceResize(Sender: TObject);
begin
  if FBinder <> nil then FBinder.Rescale;
end;

procedure TfrmPyPlugin.ShowLog(AShow: Boolean);
begin
  if AShow = pnlLog.Visible then Exit;
  pnlLog.Visible := AShow;
  if AShow then ClientHeight := ClientHeight + pnlLog.Height
  else ClientHeight := ClientHeight - pnlLog.Height;
end;

procedure TfrmPyPlugin.btnLogChange(Sender: TObject);
begin
  ShowLog(btnLog.Down);
end;

procedure TfrmPyPlugin.LogLine(ALevel, AText: string);
begin
  memLog.Lines.Add('[' + ALevel + '] ' + AText);
  if Assigned(OnLogged) then OnLogged('[' + ALevel + '] ' + AText);
  while memLog.Lines.Count > LOG_ROWS_MAX do memLog.Lines.Delete(0);
  { layout and other warnings from the script are shown straight away, so the scripter sees them on start-up }
  if SameText(ALevel, 'warning') and not btnLog.Down then
  begin
    btnLog.Down := True;
    ShowLog(True);
    lblStatus.Caption := 'The plug-in reported warnings (window layout) - see the Log.';
  end;
end;

procedure TfrmPyPlugin.PluginError(AText: string);
begin
  LogLine('error', AText);
  lblStatus.Caption := 'The plug-in reported an error - open the Log.';
  if not btnLog.Down then
  begin
    btnLog.Down := True;
    ShowLog(True);
  end;
end;

procedure TfrmPyPlugin.ParamChanged(AId: string; AValue: Double);
begin
  FDirty := True;
end;

procedure TfrmPyPlugin.btnDefaultsClick(Sender: TObject);
var
  i: Integer;
  p: TPyParam;
begin
  for i := 0 to FHost.ParamCount - 1 do
  begin
    p := FHost.GetParam(i);
    FHost.SetParam(p.Id, p.DefaultValue);
  end;
  FBinder.RefreshParams;
  FDirty := True;
end;

procedure TfrmPyPlugin.btnAboutClick(Sender: TObject);
var
  s: string;
begin
  s := FHost.Name;
  if FHost.Version <> '' then s := s + '  ' + FHost.Version;
  s := s + #13#10#13#10;
  if FHost.Author <> '' then s := s + 'Author: ' + FHost.Author + #13#10
  else s := s + 'Author: (not stated by the plug-in)'#13#10;
  if FHost.Vendor <> '' then s := s + 'Published by: ' + FHost.Vendor + #13#10;
  if FHost.Description <> '' then s := s + #13#10 + FHost.Description + #13#10;
  s := s + #13#10 + Format('%d parameter(s)  -  runs on Python %s', [FHost.ParamCount, FHost.PythonVersion]);
  MessageDlg(s, mtInformation, [mbOK], 0);
end;

procedure TfrmPyPlugin.btnAddClick(Sender: TObject);
begin
  if Assigned(FOnAdd) then FOnAdd(Self);
end;

procedure TfrmPyPlugin.SaveNow;
var
  st: string;
begin
  if not Assigned(FSave) then Exit;
  st := FHost.CaptureState;
  if st = '' then
  begin
    lblStatus.Caption := 'The plug-in is not running, so its settings could not be saved.';
    Exit;
  end;
  FSave(st);
  FDirty := False;
  lblStatus.Caption := 'Settings saved in the project.';
end;

procedure TfrmPyPlugin.btnSaveClick(Sender: TObject);
begin
  SaveNow;
end;

{ ---- listening ---- }

procedure TfrmPyPlugin.StartListening;
var
  rate, liveCh, liveRate: Integer;
  mat: TPyPlanar;
  msg: string;

  procedure LiveFailed(const AText: string);
  begin
    FUiGuard := True;
    btnListen.Down := False;
    FUiGuard := False;
    lblStatus.Caption := AText;
    MessageDlg(AText, mtInformation, [mbOK], 0);
  end;

begin
  if not Assigned(PyAuditionAttach) or (FHost = nil) or FHost.Dead then Exit;
  rate := 0;
  if Assigned(PyAuditionRate) then rate := PyAuditionRate();
  if (rate <= 0) or (rate <> FHost.SampleRate) then
  begin
    lblStatus.Caption := Format('Cannot listen from here: the audio output runs at %d Hz and this plug-in instance at %d Hz.',
      [rate, FHost.SampleRate]);
    FUiGuard := True;
    btnListen.Down := False;
    FUiGuard := False;
    Exit;
  end;
  if cboSource.ItemIndex = 2 then
  begin
    { live input: the guitar (or microphone) plugged into the input device, through the plug-in }
    if not Assigned(PyLiveInfo) or not Assigned(PyAuditionAttachLive) then Exit;
    if not PyLiveInfo(liveCh, liveRate, msg) then
    begin
      LiveFailed(msg);
      Exit;
    end;
    if liveRate <> FHost.SampleRate then
    begin
      LiveFailed(Format('The input runs at %d Hz and this plug-in instance at %d Hz.', [liveRate, FHost.SampleRate]));
      Exit;
    end;
    if (GAuditionOwner <> nil) and (GAuditionOwner <> Self) then GAuditionOwner.ListenEnded;
    FAud := TPyAuditionSource.CreateLive(FHost, liveCh, liveRate);
    FAud.Bypass := btnBypass.Down;
    FAudIntf := FAud;
    if not PyAuditionAttachLive(FAudIntf, FAud.Ring, msg) then
    begin
      FAudIntf := nil;
      FAud := nil;
      LiveFailed(msg);
      Exit;
    end;
    GAuditionOwner := Self;
    lblStatus.Caption := 'Live input: playing the first input channel through the plug-in.';
    Exit;
  end;
  SetLength(mat, 0);
  if (cboSource.ItemIndex = 1) and Assigned(PyAuditionRange) then
    if not PyAuditionRange(rate, mat) or (Length(mat) = 0) then
    begin
      lblStatus.Caption := 'Nothing is highlighted on the Timeline - playing the built-in guitar phrase instead.';
      FUiGuard := True;
      cboSource.ItemIndex := 0;
      FUiGuard := False;
      SetLength(mat, 0);
    end;
  if Length(mat) = 0 then mat := BuildGuitarPhrase(rate);
  if (GAuditionOwner <> nil) and (GAuditionOwner <> Self) then GAuditionOwner.ListenEnded;
  FAud := TPyAuditionSource.Create(FHost, mat);
  FAud.Bypass := btnBypass.Down;
  FAudIntf := FAud;
  if not PyAuditionAttach(FAudIntf) then
  begin
    FAudIntf := nil;
    FAud := nil;
    FUiGuard := True;
    btnListen.Down := False;
    FUiGuard := False;
    Exit;
  end;
  GAuditionOwner := Self;
end;

procedure TfrmPyPlugin.StopListening;
begin
  if GAuditionOwner = Self then
  begin
    if Assigned(PyAuditionAttach) then PyAuditionAttach(nil);
    GAuditionOwner := nil;
  end;
  FAudIntf := nil;
  FAud := nil;
end;

procedure TfrmPyPlugin.ListenEnded;
begin
  FAudIntf := nil;
  FAud := nil;
  GAuditionOwner := nil;
  FUiGuard := True;
  btnListen.Down := False;
  FUiGuard := False;
end;

{ ---- MIDI input: the chosen device's messages go to the script's on_midi ---- }

procedure TfrmPyPlugin.FillMidiDevices;
var
  i: Integer;
begin
  FMidiDevs := EnumerateMidiInputs;
  cboMidi.Items.BeginUpdate;
  try
    cboMidi.Items.Clear;
    cboMidi.Items.Add('MIDI input: none');
    for i := 0 to High(FMidiDevs) do cboMidi.Items.Add('MIDI: ' + FMidiDevs[i].Name);
  finally
    cboMidi.Items.EndUpdate;
  end;
  cboMidi.ItemIndex := 0;

  FMidiOutDevs := EnumerateMidiOutputs;
  cboMidiOut.Items.BeginUpdate;
  try
    cboMidiOut.Items.Clear;
    cboMidiOut.Items.Add('MIDI output: none');
    for i := 0 to High(FMidiOutDevs) do cboMidiOut.Items.Add('MIDI out: ' + FMidiOutDevs[i].Name);
  finally
    cboMidiOut.Items.EndUpdate;
  end;
  cboMidiOut.ItemIndex := 0;
  if FMidiOutBuf = nil then FMidiOutBuf := TList<TPyMidiOut>.Create;
end;

{ ---- MIDI output: what the script sends with send_midi goes to the chosen device ---- }

procedure TfrmPyPlugin.CloseMidiOut;
begin
  if FMidiOut = nil then Exit;
  FMidiOut.AllNotesOffAllChannels;   // never leave a note hanging on the hardware
  FreeAndNil(FMidiOut);
end;

procedure TfrmPyPlugin.cboMidiOutChange(Sender: TObject);
var
  i: Integer;
begin
  if FUiGuard then Exit;
  CloseMidiOut;
  i := cboMidiOut.ItemIndex - 1;
  if i < 0 then
  begin
    lblStatus.Caption := 'MIDI output closed.';
    Exit;
  end;
  FMidiOut := TMidiOutputDevice.Create;
  if not FMidiOut.Open(FMidiOutDevs[i].Id, FMidiOutDevs[i].Name) then
  begin
    FreeAndNil(FMidiOut);
    FUiGuard := True;
    cboMidiOut.ItemIndex := 0;
    FUiGuard := False;
    MessageDlg('Could not open the MIDI output "' + FMidiOutDevs[i].Name + '". Another program may be ' +
      'using it (the Microsoft GS Wavetable Synth and many hardware drivers allow only one user).',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  lblStatus.Caption := 'The plug-in''s MIDI output goes to "' + FMidiOutDevs[i].Name + '".';
end;

{ drains what the script sent; with no output device chosen it is discarded so it cannot pile up }
procedure TfrmPyPlugin.PumpMidiOut;
var
  i: Integer;
  m: TMidiMessage;
begin
  if (FHost = nil) or (FMidiOutBuf = nil) then Exit;
  FMidiOutBuf.Clear;
  FHost.TakeMidiOut(FMidiOutBuf);
  if FMidiOut = nil then Exit;
  for i := 0 to FMidiOutBuf.Count - 1 do
  begin
    m.Status := FMidiOutBuf[i].Status;
    m.Data1 := FMidiOutBuf[i].Data1;
    m.Data2 := FMidiOutBuf[i].Data2;
    FMidiOut.SendMessage(m);
  end;
end;

procedure TfrmPyPlugin.cboMidiChange(Sender: TObject);
var
  i: Integer;
begin
  if FUiGuard then Exit;
  FreeAndNil(FMidi);
  i := cboMidi.ItemIndex - 1;
  if i < 0 then
  begin
    lblStatus.Caption := 'MIDI input closed.';
    Exit;
  end;
  FMidi := TMidiInputDevice.Create;
  if not FMidi.Open(FMidiDevs[i].Id, FMidiDevs[i].Name) then
  begin
    FreeAndNil(FMidi);
    FUiGuard := True;
    cboMidi.ItemIndex := 0;
    FUiGuard := False;
    MessageDlg('Could not open the MIDI input "' + FMidiDevs[i].Name + '". Another program, or another part ' +
      'of UDAW, may be using it.', mtWarning, [mbOK], 0);
    Exit;
  end;
  lblStatus.Caption := 'MIDI from "' + FMidiDevs[i].Name + '" goes to the plug-in (its on_midi).';
end;

procedure TfrmPyPlugin.MidiEvent(Sender: TObject; const AMsg: TMidiMessage; ATimestampMs: Cardinal);
begin
  if (FHost <> nil) and not FHost.Dead then FHost.SendMidi(AMsg.Status, AMsg.Data1, AMsg.Data2);
end;

procedure TfrmPyPlugin.btnListenChange(Sender: TObject);
begin
  if FUiGuard then Exit;
  if btnListen.Down then StartListening else StopListening;
end;

procedure TfrmPyPlugin.btnBypassChange(Sender: TObject);
begin
  if FAud <> nil then FAud.Bypass := btnBypass.Down;
end;

procedure TfrmPyPlugin.cboSourceChange(Sender: TObject);
begin
  if FUiGuard then Exit;
  if btnListen.Down then
  begin
    StopListening;
    StartListening;
  end;
end;

{ ---- following the playing instance, status ---- }

{ playback started (or restarted): the mixer has its own instance now - follow it, taking along what
  the user has set in this window }
procedure TfrmPyPlugin.FollowLivePlugin;
var
  live: TPyPluginHost;
  i: Integer;
  p: TPyParam;
begin
  if FIid = '' then Exit;
  live := PyLive.Acquire(FIid);
  if live = nil then Exit;
  if live = FHost then
  begin
    live.Release;
    Exit;
  end;
  for i := 0 to FHost.ParamCount - 1 do
  begin
    p := FHost.GetParam(i);
    live.SetParam(p.Id, p.Value);
  end;
  FBinder.Rehost(live);
  FHost.Release;
  FHost := live;   // the reference Acquire gave us is the window's now
end;

procedure TfrmPyPlugin.UpdateStatus;
var
  s: string;
begin
  if FHost.Dead then
    s := 'The Python process has stopped.' + IfThen(FHost.LastError <> '', ' ' + FHost.LastError, '')
  else if FHost.AudioActive or (FAud <> nil) then
  begin
    s := 'Python ' + FHost.PythonVersion + '  -  processing audio';
    if FHost.BlocksProcessed > 0 then
      s := s + Format('  -  %.1f%% of blocks late, %d skipped', [FHost.LatePercent, FHost.DroppedBlocks]);
    if FHost.Buffered then s := s + '  -  buffered (one block of latency)';
  end
  else
    s := 'Python ' + FHost.PythonVersion + '  -  idle (press Listen, or play the project, to hear it)';
  lblStatus.Caption := s;
end;

procedure TfrmPyPlugin.tmrPumpTimer(Sender: TObject);
var
  now_: UInt64;
begin
  if FBinder = nil then Exit;
  now_ := GetTickCount64;
  if FMidi <> nil then FMidi.Poll(MidiEvent, Self);
  PumpMidiOut;
  FBinder.Pump(True);
  if now_ - FLastLive >= 300 then
  begin
    FLastLive := now_;
    FollowLivePlugin;
  end;
  if now_ - FLastStatus >= 500 then
  begin
    FLastStatus := now_;
    if (FHost.LastError = '') or FHost.Dead then UpdateStatus;
  end;
end;

end.
