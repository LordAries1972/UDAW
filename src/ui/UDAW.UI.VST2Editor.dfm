object frmVST2Editor: TfrmVST2Editor
  Left = 0
  Top = 0
  Caption = 'VST Plugin'
  ClientHeight = 420
  ClientWidth = 520
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
  object pnlTop: TPanel
    Left = 0
    Top = 0
    Width = 520
    Height = 44
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object lblInfo: TLabel
      Transparent = True
      Left = 8
      Top = 8
      Width = 300
      Height = 15
      Caption = 'plugin info'
    end
    object btnSave: TButton
      Left = 340
      Top = 6
      Width = 80
      Height = 25
      Caption = 'Save'
      TabOrder = 0
      OnClick = btnSaveClick
    end
    object btnClose: TButton
      Left = 426
      Top = 6
      Width = 80
      Height = 25
      Caption = 'Close'
      TabOrder = 1
      OnClick = btnCloseClick
    end
  end
  object pnlHost: TPanel
    Left = 0
    Top = 44
    Width = 520
    Height = 376
    Align = alClient
    BevelOuter = bvLowered
    Caption = ''
    TabOrder = 1
    Visible = False
  end
  object pnlParams: TPanel
    Left = 0
    Top = 44
    Width = 520
    Height = 376
    Align = alClient
    BevelOuter = bvNone
    TabOrder = 2
    object lbParams: TListBox
      Left = 0
      Top = 0
      Width = 220
      Height = 376
      Align = alLeft
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -12
      Font.Name = 'Consolas'
      Font.Style = []
      ItemHeight = 15
      ParentFont = False
      TabOrder = 0
      OnClick = lbParamsClick
    end
    object pnlParamDetail: TPanel
      Left = 220
      Top = 0
      Width = 300
      Height = 376
      Align = alClient
      BevelOuter = bvNone
      TabOrder = 1
      object lblParamName: TLabel
        Transparent = True
        Left = 12
        Top = 12
        Width = 100
        Height = 15
        Caption = 'param name'
      end
      object lblParamValue: TLabel
        Transparent = True
        Left = 12
        Top = 44
        Width = 100
        Height = 15
        Caption = 'value'
      end
      object tbParam: TTrackBar
        Left = 12
        Top = 68
        Width = 260
        Height = 30
        Max = 1000
        Min = 0
        TabOrder = 0
        OnChange = tbParamChange
      end
    end
  end
  object tmrIdle: TTimer
    Enabled = False
    Interval = 30
    OnTimer = tmrIdleTimer
    Left = 456
    Top = 60
  end
end
