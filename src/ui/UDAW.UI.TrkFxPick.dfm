object frmTrkFxPick: TfrmTrkFxPick
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'Channel effect'
  ClientHeight = 360
  ClientWidth = 300
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poOwnerFormCenter
  OnKeyDown = FormKeyDown
  TextHeight = 15
  object edtFilter: TGLEdit
    Left = 8
    Top = 8
    Width = 284
    Height = 24
    TextHint = 'Find an effect...'
    TabOrder = 0
    OnChange = edtFilterChange
  end
  object lstFx: TGLList
    Left = 8
    Top = 40
    Width = 284
    Height = 270
    TabOrder = 1
    OnDblClick = lstFxDblClick
  end
  object ibDialog: TGLIconBar
    Left = 192
    Top = 318
    Width = 100
    Height = 36
    ShowHint = True
    Buttons = 'ok;erase'
    Hints = 'OK - use the selected effect on the channel;Cancel'
    CellWidth = 48
    OnButtonClick = DialogClick
  end
end
