object frmHelp: TfrmHelp
  Left = 0
  Top = 0
  Caption = 'UDAW Help Centre'
  BorderIcons = [biSystemMenu]
  ClientHeight = 780
  ClientWidth = 1260
  Constraints.MinHeight = 420
  Constraints.MinWidth = 760
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnClose = FormClose
  OnDestroy = FormDestroy
  TextHeight = 15
  object pnlToolbar: TPanel
    Left = 0
    Top = 0
    Width = 1260
    Height = 33
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object btnTranslate: TButton
      Left = 1056
      Top = 4
      Width = 118
      Height = 25
      Anchors = [akTop, akRight]
      Caption = 'Translate...'
      Hint = 'Open this help in your web browser, where the Google Translate language box in the header bar works.'
      ShowHint = True
      TabOrder = 1
      OnClick = btnTranslateClick
    end
    object btnRefresh: TButton
      Left = 1180
      Top = 4
      Width = 72
      Height = 25
      Anchors = [akTop, akRight]
      Caption = 'Refresh'
      Hint = 'Reload the Help Centre page.'
      TabOrder = 0
      OnClick = btnRefreshClick
    end
  end
  object wb: TWebBrowser
    Left = 0
    Top = 33
    Width = 1260
    Height = 747
    Align = alClient
    TabOrder = 1
    ExplicitLeft = 3
    ExplicitTop = 36
    ExplicitHeight = 681
  end
end
