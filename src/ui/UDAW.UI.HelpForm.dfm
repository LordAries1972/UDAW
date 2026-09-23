object frmHelp: TfrmHelp
  Left = 0
  Top = 0
  Caption = 'UDAW Help Centre'
  ClientHeight = 720
  ClientWidth = 1040
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
    Width = 1040
    Height = 33
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object btnRefresh: TButton
      Left = 960
      Top = 4
      Width = 72
      Height = 25
      Anchors = [akTop, akRight]
      Caption = 'Refresh'
      TabOrder = 0
      OnClick = btnRefreshClick
    end
  end
  object wb: TWebBrowser
    Left = 0
    Top = 33
    Width = 1040
    Height = 687
    Align = alClient
    TabOrder = 1
    ExplicitLeft = 3
    ExplicitTop = 36
    ExplicitWidth = 1034
    ExplicitHeight = 681
  end
end
