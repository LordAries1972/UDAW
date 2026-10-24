unit UDAW.UI.TrkFxPick;
{$I udaw.inc}

{ Effect chooser for a tracker channel: a filterable list of every effect that can run live on a
  channel (the DSP effect kinds). Double-click or OK picks one; the caller then opens the effect
  editor on it. }

interface

uses
  System.SysUtils, System.Classes, Vcl.Controls, Vcl.Forms, UDAW.GL.Controls, UDAW.GL.Widgets,
  UDAW.Timeline.FxPresets;

type
  TfrmTrkFxPick = class(TForm)
    edtFilter: TGLEdit;
    lstFx: TGLList;
    ibDialog: TGLIconBar;
    procedure edtFilterChange(Sender: TObject);
    procedure lstFxDblClick(Sender: TObject);
    procedure DialogClick(Sender: TObject; AIndex: Integer; const AId: string);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  private
    FFx: TArray<TFxPresetInfo>;
    FShown: TArray<Integer>;
    procedure FillList;
  public
    { True when the user picked an effect; AKind / AParams / AName describe it }
    class function Pick(AOwner: TComponent; out AKind, AParams, AName: string): Boolean;
  end;

implementation

{$R *.dfm}

uses
  Winapi.Windows, UDAW.Audio.Graph.Nodes;

class function TfrmTrkFxPick.Pick(AOwner: TComponent; out AKind, AParams, AName: string): Boolean;
var
  frm: TfrmTrkFxPick;
  all: TArray<TFxPresetInfo>;
  fx: TFxPresetInfo;
  nk: TNodeKind;
begin
  Result := False;
  AKind := '';
  AParams := '';
  AName := '';
  frm := TfrmTrkFxPick.Create(AOwner);
  try
    all := FxExtraPresets + FxPresetList;
    for fx in all do
      { only effects that run as a live DSP node (the offline spectral tools can't run on a channel) }
      if (Copy(fx.Kind, 1, 1) <> '@') and NodeKindFromId(fx.Kind, nk) then
      begin
        SetLength(frm.FFx, Length(frm.FFx) + 1);
        frm.FFx[High(frm.FFx)] := fx;
      end;
    frm.FillList;
    if (frm.ShowModal = mrOk) and (frm.lstFx.ItemIndex >= 0) and
       (frm.lstFx.ItemIndex < Length(frm.FShown)) then
    begin
      fx := frm.FFx[frm.FShown[frm.lstFx.ItemIndex]];
      AKind := fx.Kind;
      AParams := fx.Params;
      AName := fx.Name;
      Result := True;
    end;
  finally
    frm.Free;
  end;
end;

procedure TfrmTrkFxPick.FillList;
var
  i: Integer;
  flt: string;
begin
  flt := LowerCase(Trim(edtFilter.Text));
  lstFx.Items.BeginUpdate;
  try
    lstFx.Items.Clear;
    SetLength(FShown, 0);
    for i := 0 to High(FFx) do
      if (flt = '') or (Pos(flt, LowerCase(FFx[i].Name)) > 0) then
      begin
        lstFx.Items.Add(FFx[i].Name);
        SetLength(FShown, Length(FShown) + 1);
        FShown[High(FShown)] := i;
      end;
  finally
    lstFx.Items.EndUpdate;
  end;
  if lstFx.Items.Count > 0 then lstFx.ItemIndex := 0;
end;

procedure TfrmTrkFxPick.edtFilterChange(Sender: TObject);
begin
  FillList;
end;

procedure TfrmTrkFxPick.lstFxDblClick(Sender: TObject);
begin
  if lstFx.ItemIndex >= 0 then ModalResult := mrOk;
end;

procedure TfrmTrkFxPick.DialogClick(Sender: TObject; AIndex: Integer; const AId: string);
begin
  if AId = 'ok' then
  begin
    if lstFx.ItemIndex >= 0 then ModalResult := mrOk;
  end
  else
    ModalResult := mrCancel;
end;

procedure TfrmTrkFxPick.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then ModalResult := mrCancel
  else if (Key = VK_RETURN) and (lstFx.ItemIndex >= 0) then ModalResult := mrOk;
end;

end.
