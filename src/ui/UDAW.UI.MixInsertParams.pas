unit UDAW.UI.MixInsertParams;
{$I udaw.inc}

{ Generic parameter-editing dialog for one mixer insert (see
  UDAW.Mixer.Model.TMixInsert - a plain Kind + "key=value;key=value" Params
  string, no typed/ranged metadata). Reused for two call sites in
  UDAW.UI.MainForm:

    - btnMixAddEQClick: edit the new insert's default params before it is
      committed via TAddMixInsertCommand.
    - pbMixerDblClick: edit an existing insert's params in place via
      TSetMixInsertParamsCommand (undo-safe, same path the AI mixing/
      mastering assistants use).

  Mirrors UDAW.UI.VST2Editor's master-list-plus-single-detail-editor idiom
  (a TListBox of items, one shared value editor for whichever is selected)
  so per-parameter rows never need to be built at runtime - only the
  ListBox/ComboBox *contents* are dynamic, every control is design-time.

  VST2 inserts are NOT edited here - TfrmVST2Editor already hosts a real
  plugin instance and edits its binary state; this dialog only understands
  the plain-text key=value contract used by UDAW's own DSP node kinds.

  Presets are a flat INI at UDAW.Paths.DataFile('MixerPresets.ini'), one
  section per insert Kind id, key = preset name, value = the full
  "key=value;..." params string - the same user-data root the rest of the
  app resolves via UDAW.Paths, so presets survive alongside projects/config. }

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls, ExtCtrls, System.UITypes;

type
  TfrmMixInsertParams = class(TForm)
    pnlTop: TPanel;
    lblKind: TLabel;
    pnlPresets: TPanel;
    lblPreset: TLabel;
    cboPreset: TComboBox;
    btnLoadPreset: TButton;
    btnSavePreset: TButton;
    btnDeletePreset: TButton;
    pnlBody: TPanel;
    lbParams: TListBox;
    pnlDetail: TPanel;
    lblParamKey: TLabel;
    edtParamValue: TEdit;
    btnParamApply: TButton;
    pnlButtons: TPanel;
    btnOK: TButton;
    btnCancel: TButton;
    procedure lbParamsClick(Sender: TObject);
    procedure btnParamApplyClick(Sender: TObject);
    procedure edtParamValueKeyPress(Sender: TObject; var Key: Char);
    procedure btnLoadPresetClick(Sender: TObject);
    procedure btnSavePresetClick(Sender: TObject);
    procedure btnDeletePresetClick(Sender: TObject);
  private
    FKindId: string;
    FParamList: TStringList;   // lines "key=value", order preserved
    FSelected: Integer;
    procedure RefreshList;
    procedure RefreshPresetCombo;
    function PresetsIniPath: string;
    procedure ApplyPendingEdit;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Opens the dialog modally for one insert's params. AKindId is the raw
      insert Kind string (e.g. 'parametriceq') - used as the preset-store
      section and must be stable/non-blank. ADisplayName is shown to the
      user. Returns True (with AResultParams filled) iff the user clicked
      OK; on False the caller must not touch the insert. }
    class function Edit(AOwnerForm: TComponent; const AKindId, ADisplayName,
      AInitialParams: string; out AResultParams: string): Boolean;
  end;

implementation

uses
  IniFiles, UDAW.Paths;

{$R *.dfm}

constructor TfrmMixInsertParams.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FParamList := TStringList.Create;
  FSelected := -1;
end;

destructor TfrmMixInsertParams.Destroy;
begin
  FParamList.Free;
  inherited Destroy;
end;

function TfrmMixInsertParams.PresetsIniPath: string;
begin
  Result := DataFile('MixerPresets.ini');
end;

procedure TfrmMixInsertParams.RefreshList;
var
  i: Integer;
begin
  lbParams.Items.BeginUpdate;
  try
    lbParams.Items.Clear;
    for i := 0 to FParamList.Count - 1 do
      lbParams.Items.Add(FParamList[i]);
  finally
    lbParams.Items.EndUpdate;
  end;
  if (FSelected < 0) and (lbParams.Items.Count > 0) then
    FSelected := 0;
  if (FSelected >= 0) and (FSelected < lbParams.Items.Count) then
  begin
    lbParams.ItemIndex := FSelected;
    lbParamsClick(lbParams);
  end;
end;

procedure TfrmMixInsertParams.RefreshPresetCombo;
var
  ini: TMemIniFile;
begin
  cboPreset.Items.Clear;
  ini := TMemIniFile.Create(PresetsIniPath);
  try
    ini.ReadSection(FKindId, cboPreset.Items);
  finally
    ini.Free;
  end;
end;

procedure TfrmMixInsertParams.lbParamsClick(Sender: TObject);
var
  line, key, val: string;
  eq: Integer;
begin
  FSelected := lbParams.ItemIndex;
  if (FSelected < 0) or (FSelected >= FParamList.Count) then
  begin
    lblParamKey.Caption := '';
    edtParamValue.Text := '';
    edtParamValue.Enabled := False;
    Exit;
  end;
  edtParamValue.Enabled := True;
  line := FParamList[FSelected];
  eq := Pos('=', line);
  if eq > 0 then
  begin
    key := Copy(line, 1, eq - 1);
    val := Copy(line, eq + 1, MaxInt);
  end
  else
  begin
    key := line;
    val := '';
  end;
  lblParamKey.Caption := key;
  edtParamValue.Text := val;
end;

procedure TfrmMixInsertParams.ApplyPendingEdit;
var
  key: string;
  eq: Integer;
begin
  if (FSelected < 0) or (FSelected >= FParamList.Count) then Exit;
  eq := Pos('=', FParamList[FSelected]);
  if eq > 0 then key := Copy(FParamList[FSelected], 1, eq - 1)
  else key := FParamList[FSelected];
  FParamList[FSelected] := key + '=' + Trim(edtParamValue.Text);
  RefreshList;
end;

procedure TfrmMixInsertParams.btnParamApplyClick(Sender: TObject);
begin
  ApplyPendingEdit;
end;

procedure TfrmMixInsertParams.edtParamValueKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    Key := #0;
    ApplyPendingEdit;
  end;
end;

procedure TfrmMixInsertParams.btnLoadPresetClick(Sender: TObject);
var
  ini: TMemIniFile;
  raw: string;
  parts: TArray<string>;
  p: string;
begin
  if cboPreset.ItemIndex < 0 then Exit;
  ApplyPendingEdit;
  ini := TMemIniFile.Create(PresetsIniPath);
  try
    raw := ini.ReadString(FKindId, cboPreset.Text, '');
  finally
    ini.Free;
  end;
  FParamList.Clear;
  parts := raw.Split([';']);
  for p in parts do
    if Pos('=', p) > 0 then
      FParamList.Add(p);
  FSelected := -1;
  RefreshList;
end;

procedure TfrmMixInsertParams.btnSavePresetClick(Sender: TObject);
var
  ini: TMemIniFile;
  name, raw: string;
  i: Integer;
begin
  ApplyPendingEdit;
  name := Trim(cboPreset.Text);
  if not InputQuery('Save preset', 'Preset name:', name) then Exit;
  name := Trim(name);
  if name = '' then Exit;
  raw := '';
  for i := 0 to FParamList.Count - 1 do
  begin
    if i > 0 then raw := raw + ';';
    raw := raw + FParamList[i];
  end;
  ini := TMemIniFile.Create(PresetsIniPath);
  try
    ini.WriteString(FKindId, name, raw);
    ini.UpdateFile;
  finally
    ini.Free;
  end;
  RefreshPresetCombo;
  cboPreset.ItemIndex := cboPreset.Items.IndexOf(name);
end;

procedure TfrmMixInsertParams.btnDeletePresetClick(Sender: TObject);
var
  ini: TMemIniFile;
begin
  if cboPreset.ItemIndex < 0 then Exit;
  if MessageDlg('Delete preset "' + cboPreset.Text + '"?', mtConfirmation,
    [mbYes, mbNo], 0) <> mrYes then Exit;
  ini := TMemIniFile.Create(PresetsIniPath);
  try
    ini.DeleteKey(FKindId, cboPreset.Text);
    ini.UpdateFile;
  finally
    ini.Free;
  end;
  RefreshPresetCombo;
end;

class function TfrmMixInsertParams.Edit(AOwnerForm: TComponent; const AKindId,
  ADisplayName, AInitialParams: string; out AResultParams: string): Boolean;
var
  frm: TfrmMixInsertParams;
  parts: TArray<string>;
  p: string;
  i: Integer;
begin
  AResultParams := AInitialParams;
  frm := TfrmMixInsertParams.Create(AOwnerForm);
  try
    frm.Caption := 'Edit parameters - ' + ADisplayName;
    frm.lblKind.Caption := ADisplayName;
    frm.FKindId := AKindId;
    frm.FParamList.Clear;
    parts := AInitialParams.Split([';']);
    for p in parts do
      if Pos('=', p) > 0 then
        frm.FParamList.Add(p);
    frm.FSelected := -1;
    frm.RefreshList;
    frm.RefreshPresetCombo;
    Result := frm.ShowModal = mrOk;
    if Result then
    begin
      frm.ApplyPendingEdit;
      AResultParams := '';
      for i := 0 to frm.FParamList.Count - 1 do
      begin
        if i > 0 then AResultParams := AResultParams + ';';
        AResultParams := AResultParams + frm.FParamList[i];
      end;
    end;
  finally
    frm.Free;
  end;
end;

end.
