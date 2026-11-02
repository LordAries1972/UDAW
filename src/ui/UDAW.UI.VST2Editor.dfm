object frmVST2Editor: TfrmVST2Editor
  Left = 0
  Top = 0
  Caption = 'VST Plugin'
  BorderIcons = [biSystemMenu]
  ClientHeight = 440
  ClientWidth = 560
  Color = clBtnFace
  Constraints.MinHeight = 280
  Constraints.MinWidth = 440
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnClose = FormClose
  OnDestroy = FormDestroy
  TextHeight = 15
  object pnlTop: TGLPanel
    Left = 0
    Top = 0
    Width = 560
    Height = 44
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object lblInfo: TGLLabel
      Transparent = True
      Left = 12
      Top = 14
      Width = 300
      Height = 15
      Caption = 'plugin info'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object btnSave: TGLButton
      Left = 380
      Top = 9
      Width = 80
      Height = 26
      Anchors = [akTop, akRight]
      Caption = 'Save'
      Hint = 'Save the plug-in settings you have edited into the project.'
      ShowHint = True
      TabOrder = 0
      OnClick = btnSaveClick
    end
    object btnClose: TGLButton
      Left = 468
      Top = 9
      Width = 80
      Height = 26
      Anchors = [akTop, akRight]
      Caption = 'Close'
      Hint = 'Close the plug-in editor.'
      ShowHint = True
      TabOrder = 1
      OnClick = btnCloseClick
    end
  end
  object pnlHost: TGLPanel
    Left = 0
    Top = 44
    Width = 560
    Height = 396
    Align = alClient
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 1
    Visible = False
  end
  object pnlParams: TGLPanel
    Left = 0
    Top = 44
    Width = 560
    Height = 396
    Align = alClient
    BevelOuter = bvNone
    TabOrder = 2
    object lbParams: TGLList
      Left = 0
      Top = 0
      Width = 230
      Height = 396
      Align = alLeft
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -12
      Font.Name = 'Consolas'
      Font.Style = []
      ItemHeight = 20
      ParentFont = False
      TabOrder = 0
      OnClick = lbParamsClick
    end
    object pnlParamDetail: TGLPanel
      Left = 230
      Top = 0
      Width = 330
      Height = 396
      Align = alClient
      BevelOuter = bvNone
      TabOrder = 1
      object lblParamHead: TGLLabel
        Transparent = True
        Left = 20
        Top = 20
        Width = 120
        Height = 15
        Caption = 'PARAMETER'
      end
      object lblParamName: TGLLabel
        Transparent = True
        Left = 20
        Top = 40
        Width = 290
        Height = 22
        Caption = 'param name'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -16
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
      end
      object lblValueHead: TGLLabel
        Transparent = True
        Left = 20
        Top = 84
        Width = 120
        Height = 15
        Caption = 'VALUE'
      end
      object lblParamValue: TGLLabel
        Transparent = True
        Left = 20
        Top = 104
        Width = 290
        Height = 20
        Caption = 'value'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -14
        Font.Name = 'Consolas'
        Font.Style = []
        ParentFont = False
      end
      object tbParam: TGLTrackBar
        Left = 20
        Top = 138
        Width = 290
        Height = 28
        Anchors = [akLeft, akTop, akRight]
        Max = 1000
        Min = 0
        Position = 0
        TabOrder = 0
        ThumbLength = 14
        OnChange = tbParamChange
      end
      object lblParamHint: TGLLabel
        Transparent = True
        Left = 20
        Top = 180
        Width = 290
        Height = 15
        Caption = 'Pick a parameter on the left, then drag the slider.'
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