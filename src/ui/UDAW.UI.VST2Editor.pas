unit UDAW.UI.VST2Editor;
{$I udaw.inc}

{ A dedicated window for editing one hosted VST2 or VST3 plug-in insert (all of its own controls are
  UDAW OpenGL 3.3 widgets; only the plug-in's native editor, when it has one, is the plug-in's window)
  (see UDAW.Mixer.PluginHost, UDAW.Mixer.VST2, UDAW.Mixer.VST3 and UDAW.Audio.Graph.Nodes.TVST2Node /
  TVST3Node).  The class keeps its old name; it hosts either format through TPluginHostBase.

  This form owns its own scratch host, loaded from the insert's saved path/state rather than reaching
  into whatever TMixerProcessor node happens to exist on the RT thread at the moment (the Mixer tab does
  not run a continuously-live engine outside the Preview render) - so this is the architecturally honest
  place to host editing: a real plugin instance, really opened, whose resulting state is captured back
  into the mixer model as an undo-safe command (TSetMixInsertParamsCommand) when the user saves.

  If the plugin has a native editor it is opened into pnlHost (VST2: effEditOpen pumped with effEditIdle
  on a timer; VST3: IPlugView attached to the panel's window).  Otherwise - or if it has none - a generic
  parameter list (index / name / value / display text, a slider, and a box to type a value) gives full
  access to every parameter.

  Hearing it:  Listen plays program material through the plug-in with the audio device - the built-in
  phrase, the Timeline range the user highlighted (the plug-in's SAMPLE INPUT), nothing at all (an
  instrument played only from MIDI), or the live input.  The MIDI keyboard chosen in Settings plays an
  instrument (Live MIDI), and the Note button sounds a test note.  Programs, bypass and panic (all notes
  off) are here too.  Whatever is highlighted can also be rendered through the plug-in from the Timeline's
  Effects menu. }

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, ExtCtrls, Math, System.StrUtils, System.UITypes, UDAW.GL.Widgets,
  UDAW.Audio.Source, UDAW.Mixer.PluginHost, UDAW.Mixer.PluginRender;

type
  TfrmVST2Editor = class(TForm)
    pnlTop: TGLPanel;
    lblInfo: TGLLabel;
    btnSave: TGLButton;
    btnClose: TGLButton;
    cboProgram: TGLCombo;
    chkBypass: TGLCheck;
    chkLive: TGLCheck;
    lblSource: TGLLabel;
    cboSource: TGLCombo;
    btnListen: TGLButton;
    cboNote: TGLCombo;
    btnTest: TGLButton;
    btnPanic: TGLButton;
    lblStatus: TGLLabel;
    pnlHost: TGLPanel;            // the plug-in's own editor window lives in here
    pnlParams: TGLPanel;
    lbParams: TGLList;
    pnlParamDetail: TGLPanel;
    lblParamHead: TGLLabel;
    lblParamName: TGLLabel;
    lblValueHead: TGLLabel;
    lblParamValue: TGLLabel;
    tbParam: TGLTrackBar;
    lblParamHint: TGLLabel;
    edtParamText: TGLEdit;
    btnParamText: TGLButton;
    lblParamInfo: TGLLabel;
    tmrIdle: TTimer;
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormDestroy(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure btnCloseClick(Sender: TObject);
    procedure lbParamsClick(Sender: TObject);
    procedure tbParamChange(Sender: TObject);
    procedure tmrIdleTimer(Sender: TObject);
    procedure cboProgramChange(Sender: TObject);
    procedure chkBypassChange(Sender: TObject);
    procedure chkLiveChange(Sender: TObject);
    procedure btnListenClick(Sender: TObject);
    procedure cboSourceChange(Sender: TObject);
    procedure btnTestClick(Sender: TObject);
    procedure btnPanicClick(Sender: TObject);
    procedure btnParamTextClick(Sender: TObject);
  private
    FHost: TPluginHostBase;
    FKind: string;
    FUsingNativeEditor: Boolean;
    FSelectedParam: Integer;
    FGuard: Boolean;
    FOnSaved: TProc<string>;   // called with the new base64 state on Save
    FAud: TPluginAuditionSource;
    FAudIntf: IAudioSource;
    FTestNote: Integer;        // note currently sounding from the Note button (-1 = none)
    FTestOffTick: Cardinal;
    procedure RefreshParamList;
    procedure RefreshPrograms;
    procedure SelectParam(AIndex: Integer);
    procedure HostSizeWindow(AWidth, AHeight: Integer);
    procedure StartListening;
    procedure StopListening;
    procedure SetStatus(const AText: string);
    function GetLiveMidi: Boolean;
  public
    { Set by the caller right after Create so FormClose can report which
      remembered-window entry (UDAW.Project.WindowLayout) this editor's final
      geometry belongs to - see MainForm's OnEditorClosing. Empty means the
      caller does not want geometry remembered for this instance. }
    WindowKey: string;
    { Fires from FormClose, before the form frees itself, so the caller can
      capture Left/Top/Width/Height/WindowState one last time. }
    OnEditorClosing: TNotifyEvent;
    { AKind: 'vst2' or 'vst3'. APath: plugin file. AStateBase64: the insert's currently-saved
      state (may be ''). ASampleRate/AMaxFrames/AChannels: whatever the
      project is currently configured for, so parameter displays that read
      sample-rate-dependent text (e.g. a filter's Hz->display mapping) are
      accurate. ALiveMidi: the insert's "Live MIDI" setting. AOnSaved fires with the
      freshly captured state string when the user clicks Save - the caller is expected to write it
      into the mixer model via TSetMixInsertParamsCommand (and read LiveMidi). Returns False (and
      shows a message) if the plugin failed to load. }
    function OpenPlugin(const AKind, APath, AStateBase64: string;
      ASampleRate, AMaxFrames, AChannels: Integer; ALiveMidi: Boolean;
      AOnSaved: TProc<string>): Boolean;
    property LiveMidi: Boolean read GetLiveMidi;
  end;

implementation

{$R *.dfm}

uses
  UDAW.Audio.Types, UDAW.Mixer.VST2, UDAW.Mixer.VST3, UDAW.Mixer.PluginMidi,
  UDAW.Scripting.PyAudition, UDAW.UI.PluginWindow;

const
  NOTE_LOW = 36;            // C2
  NOTE_NAMES: array[0..11] of string = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B');
  SRC_PHRASE = 0;
  SRC_RANGE = 1;
  SRC_SILENCE = 2;
  SRC_LIVE = 3;

var
  GVstAuditionOwner: TfrmVST2Editor;

function TfrmVST2Editor.OpenPlugin(const AKind, APath, AStateBase64: string;
  ASampleRate, AMaxFrames, AChannels: Integer; ALiveMidi: Boolean; AOnSaved: TProc<string>): Boolean;
var
  w, h, n: Integer;
begin
  Result := False;
  FOnSaved := AOnSaved;
  FKind := LowerCase(AKind);
  FTestNote := -1;
  if FKind = 'vst3' then FHost := TVST3Host.Create else FHost := TVST2Host.Create;
  FHost.RequireEffect := False;          { instruments open too }
  try
    FHost.LoadAndOpen(APath, ASampleRate, AMaxFrames, AChannels);
  except
    on E: Exception do
    begin
      MessageDlg('Could not load plugin:'#13#10 + APath + #13#10#13#10 + E.Message,
        mtError, [mbOK], 0);
      FreeAndNil(FHost);
      Exit;
    end;
  end;
  if AStateBase64 <> '' then
    FHost.LoadStateBase64(AStateBase64);
  FHost.OnSizeWindow := HostSizeWindow;

  lblInfo.Caption := Format('%s  %s   (%s)   %d params, %d in / %d out%s',
    [FHost.FormatName, FHost.EffectName, FHost.VendorString, FHost.ParamCount, FHost.NumInputs,
     FHost.NumOutputs, IfThen(FHost.IsSynth, '   instrument', '')]);
  Caption := FHost.FormatName + ' Plugin - ' + FHost.EffectName;

  { top-bar controls }
  FGuard := True;
  try
    chkLive.Checked := ALiveMidi;
    chkLive.Enabled := FHost.WantsMidi;
    chkBypass.Enabled := FHost.SupportsBypass;
    cboNote.Items.Clear;
    for n := 0 to 60 do
      cboNote.Items.Add(NOTE_NAMES[(NOTE_LOW + n) mod 12] + IntToStr((NOTE_LOW + n) div 12 - 1));
    cboNote.ItemIndex := 24;                              { C4 }
    btnTest.Enabled := FHost.WantsMidi;
    btnPanic.Enabled := FHost.WantsMidi;
    cboNote.Enabled := FHost.WantsMidi;
    if FHost.IsSynth then cboSource.ItemIndex := SRC_SILENCE else cboSource.ItemIndex := SRC_PHRASE;
    RefreshPrograms;
  finally
    FGuard := False;
  end;
  { the MIDI keyboard reaches this window's plug-in instance while Live MIDI is on }
  if FHost.WantsMidi then PluginMidi.Register(Self, 0, chkLive.Checked, FHost.IsSynth);

  FUsingNativeEditor := FHost.HasEditor;
  if FUsingNativeEditor then
  begin
    pnlHost.Visible := True;
    pnlParams.Visible := False;
    if FHost.OpenEditor(pnlHost.Handle, w, h) then
    begin
      if w > 0 then pnlHost.Width := w;
      if h > 0 then pnlHost.Height := h;
      ClientWidth := Max(pnlHost.Width, 560);
      ClientHeight := pnlTop.Height + Max(pnlHost.Height, 200);
    end
    else
      FUsingNativeEditor := False;
  end;

  if not FUsingNativeEditor then
  begin
    pnlHost.Visible := False;
    pnlParams.Visible := True;
    RefreshParamList;
  end;
  tmrIdle.Enabled := True;
  SetStatus('Listen plays the plug-in through the audio device; Note sounds a test note.');
  Result := True;
end;

procedure TfrmVST2Editor.SetStatus(const AText: string);
begin
  lblStatus.Caption := AText;
end;

function TfrmVST2Editor.GetLiveMidi: Boolean;
begin
  Result := chkLive.Checked;
end;

procedure TfrmVST2Editor.HostSizeWindow(AWidth, AHeight: Integer);
begin
  { the plug-in asked for a different window size }
  if (AWidth <= 0) or (AHeight <= 0) or not FUsingNativeEditor then Exit;
  pnlHost.Width := AWidth;
  pnlHost.Height := AHeight;
  ClientWidth := Max(AWidth, 560);
  ClientHeight := pnlTop.Height + Max(AHeight, 200);
end;

procedure TfrmVST2Editor.FormResize(Sender: TObject);
begin
  if (FHost <> nil) and FUsingNativeEditor and FHost.IsEditorOpen and FHost.EditorCanResize then
    FHost.ResizeEditor(pnlHost.ClientWidth, pnlHost.ClientHeight);
end;

procedure TfrmVST2Editor.RefreshPrograms;
var
  i, n: Integer;
begin
  cboProgram.Items.BeginUpdate;
  try
    cboProgram.Items.Clear;
    n := Min(FHost.ProgramCount, 4096);
    for i := 0 to n - 1 do
      cboProgram.Items.Add(Format('%3d  %s', [i + 1, FHost.ProgramName(i)]));
    cboProgram.Enabled := n > 0;
    if n > 0 then
      cboProgram.ItemIndex := Min(Max(0, FHost.CurrentProgram), n - 1)
    else
      cboProgram.ItemIndex := -1;
  finally
    cboProgram.Items.EndUpdate;
  end;
end;

procedure TfrmVST2Editor.RefreshParamList;
var
  i: Integer;
begin
  lbParams.Items.BeginUpdate;
  try
    lbParams.Items.Clear;
    if FHost = nil then Exit;
    for i := 0 to FHost.ParamCount - 1 do
      lbParams.Items.Add(Format('%3d  %s', [i, FHost.ParamName(i)]));
  finally
    lbParams.Items.EndUpdate;
  end;
  if lbParams.Items.Count > 0 then
  begin
    lbParams.ItemIndex := 0;
    SelectParam(0);
  end;
end;

procedure TfrmVST2Editor.SelectParam(AIndex: Integer);
var
  steps: Integer;
begin
  FSelectedParam := AIndex;
  if (FHost = nil) or (AIndex < 0) or (AIndex >= FHost.ParamCount) then
  begin
    lblParamName.Caption := '';
    lblParamValue.Caption := '';
    lblParamInfo.Caption := '';
    Exit;
  end;
  FGuard := True;
  try
    tbParam.Position := Round(FHost.GetParam(AIndex) * 1000);
  finally
    FGuard := False;
  end;
  lblParamName.Caption := FHost.ParamName(AIndex);
  lblParamValue.Caption := Format('%s %s', [FHost.ParamDisplay(AIndex), FHost.ParamLabel(AIndex)]);
  edtParamText.Text := FHost.ParamDisplay(AIndex);
  steps := FHost.ParamSteps(AIndex);
  lblParamInfo.Caption := Format('%s%s%s',
    [IfThen(FHost.ParamCanAutomate(AIndex), 'automatable', 'not automatable'),
     IfThen(FHost.ParamIsSwitch(AIndex), ', on/off switch', ''),
     IfThen((steps > 1), Format(', %d steps', [steps]), '')]);
end;

procedure TfrmVST2Editor.lbParamsClick(Sender: TObject);
begin
  if lbParams.ItemIndex >= 0 then SelectParam(lbParams.ItemIndex);
end;

procedure TfrmVST2Editor.tbParamChange(Sender: TObject);
begin
  if FGuard or (FHost = nil) then Exit;
  if (FSelectedParam < 0) or (FSelectedParam >= FHost.ParamCount) then Exit;
  FHost.SetParam(FSelectedParam, tbParam.Position / 1000.0);
  lblParamValue.Caption := Format('%s %s',
    [FHost.ParamDisplay(FSelectedParam), FHost.ParamLabel(FSelectedParam)]);
end;

procedure TfrmVST2Editor.btnParamTextClick(Sender: TObject);
begin
  if (FHost = nil) or (FSelectedParam < 0) or (FSelectedParam >= FHost.ParamCount) then Exit;
  if FHost.SetParamFromText(FSelectedParam, edtParamText.Text) then
    SelectParam(FSelectedParam)
  else
    SetStatus('The plug-in did not understand "' + edtParamText.Text + '" for this parameter.');
end;

procedure TfrmVST2Editor.cboProgramChange(Sender: TObject);
begin
  if FGuard or (FHost = nil) or (cboProgram.ItemIndex < 0) then Exit;
  FHost.SetProgram(cboProgram.ItemIndex);
  if not FUsingNativeEditor then SelectParam(FSelectedParam);
end;

procedure TfrmVST2Editor.chkBypassChange(Sender: TObject);
begin
  if FGuard or (FHost = nil) then Exit;
  FHost.SetBypass(chkBypass.Checked);
  if FAud <> nil then FAud.Bypass := False;     { bypass is the plug-in's own, not the A/B switch }
end;

procedure TfrmVST2Editor.chkLiveChange(Sender: TObject);
begin
  if FGuard or (FHost = nil) or not FHost.WantsMidi then Exit;
  PluginMidi.Register(Self, 0, chkLive.Checked, FHost.IsSynth);
end;

procedure TfrmVST2Editor.btnTestClick(Sender: TObject);
begin
  if (FHost = nil) or not FHost.WantsMidi then Exit;
  if FTestNote >= 0 then FHost.NoteOff(0, FTestNote);
  FTestNote := NOTE_LOW + Max(0, cboNote.ItemIndex);
  FHost.NoteOn(0, FTestNote, 100);
  FTestOffTick := GetTickCount + 600;
  if FAud = nil then
    SetStatus('Press Listen to hear the note.');
end;

procedure TfrmVST2Editor.btnPanicClick(Sender: TObject);
begin
  if FHost = nil then Exit;
  FHost.AllNotesOff;
  FTestNote := -1;
end;

{ ---- listening ---- }

procedure TfrmVST2Editor.cboSourceChange(Sender: TObject);
begin
  if FGuard then Exit;
  if btnListen.Down then
  begin
    StopListening;
    StartListening;
  end;
end;

procedure TfrmVST2Editor.btnListenClick(Sender: TObject);
begin
  if FGuard then Exit;
  if btnListen.Down then StartListening else StopListening;
end;

procedure TfrmVST2Editor.StartListening;
var
  rate, liveCh, liveRate: Integer;
  mat: TPyPlanar;
  msg: string;
  buf: array[0..255] of TPluginMidi;

  procedure Fail(const AText: string);
  begin
    FGuard := True;
    btnListen.Down := False;
    FGuard := False;
    SetStatus(AText);
  end;

begin
  if (FHost = nil) or not Assigned(PyAuditionAttach) or not Assigned(PyAuditionRate) then
  begin
    Fail('Listening is not available here.');
    Exit;
  end;
  rate := PyAuditionRate();
  if rate <= 0 then
  begin
    Fail('The audio output could not be opened.');
    Exit;
  end;
  if rate <> FHost.SampleRate then
  begin
    FHost.Configure(rate, UDAW_DEFAULT_BUFFER_FRAMES, 2);
    FHost.Reset;
  end;
  { drop MIDI that arrived while nothing was listening }
  while PluginMidi.Take(Self, buf) > 0 do ;
  if (GVstAuditionOwner <> nil) and (GVstAuditionOwner <> Self) then GVstAuditionOwner.StopListening;

  if cboSource.ItemIndex = SRC_LIVE then
  begin
    if not Assigned(PyLiveInfo) or not Assigned(PyAuditionAttachLive) then
    begin
      Fail('Live input is not available here.');
      Exit;
    end;
    if not PyLiveInfo(liveCh, liveRate, msg) then
    begin
      Fail(msg);
      Exit;
    end;
    if liveRate <> FHost.SampleRate then
    begin
      Fail(Format('The input runs at %d Hz and this plug-in instance at %d Hz.', [liveRate, FHost.SampleRate]));
      Exit;
    end;
    FAud := TPluginAuditionSource.CreateLive(FHost, Self, 2, UDAW_DEFAULT_BUFFER_FRAMES, liveCh, liveRate);
    FAudIntf := FAud;
    if not PyAuditionAttachLive(FAudIntf, FAud.Ring, msg) then
    begin
      FAudIntf := nil;
      FAud := nil;
      Fail(msg);
      Exit;
    end;
    GVstAuditionOwner := Self;
    SetStatus('Live input: the first input channel plays through the plug-in.');
    Exit;
  end;

  SetLength(mat, 0);
  case cboSource.ItemIndex of
    SRC_RANGE:
      if Assigned(PyAuditionRange) then
      begin
        if (not PyAuditionRange(rate, mat)) or (Length(mat) = 0) then
        begin
          SetStatus('Nothing is highlighted on the Timeline - playing the built-in phrase instead.');
          SetLength(mat, 0);
          mat := BuildGuitarPhrase(rate);
        end
        else
          SetStatus('The highlighted Timeline range is the plug-in''s sample input.');
      end;
    SRC_SILENCE:
      begin
        SetLength(mat, 0);
        SetStatus('No audio input: play the plug-in from the MIDI keyboard or the Note button.');
      end;
  else
    mat := BuildGuitarPhrase(rate);
    SetStatus('The built-in phrase is the plug-in''s input.');
  end;
  FAud := TPluginAuditionSource.Create(FHost, Self, 2, UDAW_DEFAULT_BUFFER_FRAMES, mat);
  FAudIntf := FAud;
  if not PyAuditionAttach(FAudIntf) then
  begin
    FAudIntf := nil;
    FAud := nil;
    Fail('Could not start the audio output.');
    Exit;
  end;
  GVstAuditionOwner := Self;
end;

procedure TfrmVST2Editor.StopListening;
begin
  if GVstAuditionOwner = Self then
  begin
    if Assigned(PyAuditionAttach) then PyAuditionAttach(nil);
    GVstAuditionOwner := nil;
  end;
  FAudIntf := nil;
  FAud := nil;
  if (FHost <> nil) and FHost.WantsMidi then FHost.AllNotesOff;
  FGuard := True;
  try
    btnListen.Down := False;
  finally
    FGuard := False;
  end;
end;

procedure TfrmVST2Editor.tmrIdleTimer(Sender: TObject);
begin
  if FHost = nil then Exit;
  if FUsingNativeEditor then FHost.EditorIdle;
  if (FTestNote >= 0) and (Integer(GetTickCount - FTestOffTick) >= 0) then
  begin
    FHost.NoteOff(0, FTestNote);
    FTestNote := -1;
  end;
  if (FAud <> nil) and (FAud.Fault <> '') then
  begin
    SetStatus('The plug-in stopped while playing: ' + FAud.Fault);
    StopListening;
  end;
  { the plug-in changed its I/O, latency or parameter list }
  if FHost.TakeRestartRequest then
  begin
    RefreshPrograms;
    if not FUsingNativeEditor then RefreshParamList;
  end;
end;

procedure TfrmVST2Editor.btnSaveClick(Sender: TObject);
begin
  if FHost = nil then Exit;
  if Assigned(FOnSaved) then
    FOnSaved(FHost.SaveStateBase64);
end;

procedure TfrmVST2Editor.btnCloseClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmVST2Editor.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  if Assigned(OnEditorClosing) then OnEditorClosing(Self);
  Action := caFree;
end;

procedure TfrmVST2Editor.FormDestroy(Sender: TObject);
begin
  tmrIdle.Enabled := False;
  StopListening;
  PluginMidi.Unregister(Self);
  if FHost <> nil then
  begin
    FHost.OnSizeWindow := nil;
    FHost.CloseEditor;
    FHost.Free;
    FHost := nil;
  end;
end;

end.
