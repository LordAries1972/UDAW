unit UDAW.UI.VST2Editor;
{$I udaw.inc}

{ A dedicated window for editing one hosted VST2 plugin insert (all of its own controls are UDAW
  OpenGL 3.3 widgets; only the plug-in's native editor, when it has one, is the plug-in's window) (see
  UDAW.Mixer.VST2 and UDAW.Audio.Graph.Nodes.TVST2Node).

  This form owns its own scratch TVST2Host, loaded from the insert's saved
  path/state rather than reaching into whatever TMixerProcessor node happens
  to exist on the RT thread at the moment (the Mixer tab does not run a
  continuously-live engine outside the Preview render - see
  UDAW.UI.MainForm's btnMixPreviewClick) - so this is the architecturally
  honest place to host editing: a real plugin instance, really opened,
  really processing GetParam/SetParam/effEditOpen calls, whose resulting
  state is captured back into the mixer model as an undo-safe command
  (TSetMixInsertParamsCommand) when the user saves.

  If the plugin advertises a native editor (effFlagsHasEditor), it's opened
  into pnlHost via effEditOpen and pumped with effEditIdle on a timer, the
  same way any minimal VST host keeps a GUI alive. Otherwise - or if the
  plugin has no editor at all - a generic parameter list (index / name /
  value / display+label) with a slider gives full access to every automatable
  parameter regardless of whether the plugin ships a custom GUI. }

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, ExtCtrls, Math, System.UITypes, UDAW.GL.Widgets,
  UDAW.Mixer.VST2;

type
  TfrmVST2Editor = class(TForm)
    pnlTop: TGLPanel;
    lblInfo: TGLLabel;
    btnSave: TGLButton;
    btnClose: TGLButton;
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
    tmrIdle: TTimer;
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormDestroy(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure btnCloseClick(Sender: TObject);
    procedure lbParamsClick(Sender: TObject);
    procedure tbParamChange(Sender: TObject);
    procedure tmrIdleTimer(Sender: TObject);
  private
    FHost: TVST2Host;
    FUsingNativeEditor: Boolean;
    FSelectedParam: Integer;
    FGuard: Boolean;
    FOnSaved: TProc<string>;   // called with the new base64 state on Save
    procedure RefreshParamList;
    procedure SelectParam(AIndex: Integer);
  public
    { Set by the caller right after Create so FormClose can report which
      remembered-window entry (UDAW.Project.WindowLayout) this editor's final
      geometry belongs to - see MainForm's OnEditorClosing. Empty means the
      caller does not want geometry remembered for this instance. }
    WindowKey: string;
    { Fires from FormClose, before the form frees itself, so the caller can
      capture Left/Top/Width/Height/WindowState one last time. }
    OnEditorClosing: TNotifyEvent;
    { APath: plugin DLL path. AStateBase64: the insert's currently-saved
      state (may be ''). ASampleRate/AMaxFrames/AChannels: whatever the
      project is currently configured for, so parameter displays that read
      sample-rate-dependent text (e.g. a filter's Hz->display mapping) are
      accurate. AOnSaved fires with the freshly captured state string when
      the user clicks Save - the caller is expected to write it into the
      mixer model via TSetMixInsertParamsCommand. Returns False (and shows
      a message) if the plugin failed to load. }
    function OpenPlugin(const APath, AStateBase64: string;
      ASampleRate, AMaxFrames, AChannels: Integer; AOnSaved: TProc<string>): Boolean;
  end;

implementation

{$R *.dfm}

function TfrmVST2Editor.OpenPlugin(const APath, AStateBase64: string;
  ASampleRate, AMaxFrames, AChannels: Integer; AOnSaved: TProc<string>): Boolean;
var
  w, h: Integer;
begin
  Result := False;
  FOnSaved := AOnSaved;
  FHost := TVST2Host.Create;
  try
    FHost.LoadAndOpen(APath, ASampleRate, AMaxFrames, AChannels);
  except
    on E: Exception do
    begin
      MessageDlg('Could not load VST plugin:'#13#10 + APath + #13#10#13#10 + E.Message,
        mtError, [mbOK], 0);
      FreeAndNil(FHost);
      Exit;
    end;
  end;
  if AStateBase64 <> '' then
    FHost.LoadStateBase64(AStateBase64);

  lblInfo.Caption := Format('%s   (%s)   %d params, %d in / %d out',
    [FHost.EffectName, FHost.VendorString, FHost.ParamCount, FHost.NumInputs, FHost.NumOutputs]);
  Caption := 'VST Plugin - ' + FHost.EffectName;

  FUsingNativeEditor := FHost.HasEditor;
  if FUsingNativeEditor then
  begin
    pnlHost.Visible := True;
    pnlParams.Visible := False;
    if FHost.OpenEditor(pnlHost.Handle, w, h) then
    begin
      if w > 0 then pnlHost.Width := w;
      if h > 0 then pnlHost.Height := h;
      ClientWidth := Max(pnlHost.Width, 420);
      ClientHeight := pnlTop.Height + Max(pnlHost.Height, 200);
      tmrIdle.Enabled := True;
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

  Result := True;
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
begin
  FSelectedParam := AIndex;
  if (FHost = nil) or (AIndex < 0) or (AIndex >= FHost.ParamCount) then
  begin
    lblParamName.Caption := '';
    lblParamValue.Caption := '';
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

procedure TfrmVST2Editor.tmrIdleTimer(Sender: TObject);
begin
  if (FHost <> nil) and FUsingNativeEditor then
    FHost.EditorIdle;
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
  if FHost <> nil then
  begin
    FHost.CloseEditor;
    FHost.Free;
    FHost := nil;
  end;
end;

end.
