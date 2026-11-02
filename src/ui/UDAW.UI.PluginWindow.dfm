object frmPyPlugin: TfrmPyPlugin
  Left = 0
  Top = 0
  Caption = 'Python plug-in'
  BorderIcons = [biSystemMenu]
  ClientHeight = 440
  ClientWidth = 560
  Color = clBtnFace
  Constraints.MinHeight = 200
  Constraints.MinWidth = 520
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
    Height = 40
    Align = alTop
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 0
    object lblInfo: TGLLabel
      Transparent = True
      Left = 12
      Top = 13
      Width = 160
      Height = 15
      Caption = 'plug-in'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object btnAbout: TGLButton
      Left = 178
      Top = 7
      Width = 60
      Height = 26
      Anchors = [akTop, akRight]
      Caption = 'About'
      Hint = 'Who wrote this plug-in, its version and what it does.'
      ShowHint = True
      TabOrder = 0
      OnClick = btnAboutClick
    end
    object btnLog: TGLButton
      Left = 244
      Top = 7
      Width = 50
      Height = 26
      Anchors = [akTop, akRight]
      Caption = 'Log'
      Hint = 'Show what the script printed and any errors it raised.'
      ShowHint = True
      TabOrder = 1
      Toggle = True
      OnChange = btnLogChange
    end
    object btnDefaults: TGLButton
      Left = 300
      Top = 7
      Width = 74
      Height = 26
      Anchors = [akTop, akRight]
      Caption = 'Defaults'
      Hint = 'Put every parameter back to its default value.'
      ShowHint = True
      TabOrder = 2
      OnClick = btnDefaultsClick
    end
    object btnSave: TGLButton
      Left = 380
      Top = 7
      Width = 100
      Height = 26
      Anchors = [akTop, akRight]
      Caption = 'Save settings'
      Hint = 'Keep these settings in the project (they are also kept when you close this window).'
      ShowHint = True
      TabOrder = 3
      Visible = False
      OnClick = btnSaveClick
    end
    object btnAdd: TGLButton
      Left = 380
      Top = 7
      Width = 100
      Height = 26
      Anchors = [akTop, akRight]
      Caption = 'Add to Mixer'
      Hint = 'Put this plug-in, with the settings shown, on the strip selected in the Mixer tab.'
      ShowHint = True
      TabOrder = 4
      Visible = False
      OnClick = btnAddClick
    end
    object btnClose: TGLButton
      Left = 488
      Top = 7
      Width = 64
      Height = 26
      Anchors = [akTop, akRight]
      Caption = 'Close'
      Hint = 'Close this window.'
      ShowHint = True
      TabOrder = 5
      OnClick = btnCloseClick
    end
  end
  object pnlAudition: TGLPanel
    Left = 0
    Top = 40
    Width = 560
    Height = 34
    Align = alTop
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 1
    Visible = False
    object lblHear: TGLLabel
      Transparent = True
      Left = 12
      Top = 9
      Width = 50
      Height = 15
      Caption = 'Hear it:'
    end
    object btnListen: TGLButton
      Left = 66
      Top = 4
      Width = 70
      Height = 26
      Caption = 'Listen'
      Hint = 'Play program material through the plug-in so you can hear what it does before adding it to the mixer.'
      ShowHint = True
      TabOrder = 0
      Toggle = True
      OnChange = btnListenChange
    end
    object btnBypass: TGLButton
      Left = 142
      Top = 4
      Width = 70
      Height = 26
      Caption = 'Bypass'
      Hint = 'Hear the material without the plug-in, to compare.'
      ShowHint = True
      TabOrder = 1
      Toggle = True
      OnChange = btnBypassChange
    end
    object cboSource: TGLCombo
      Left = 220
      Top = 4
      Width = 230
      Height = 26
      Hint = 'What to play through the plug-in: a built-in guitar phrase, or the range you highlighted on the Timeline.'
      ShowHint = True
      Items.Strings = (
        'Built-in guitar phrase'
        'Highlighted Timeline range')
      ItemIndex = 0
      TabOrder = 2
      OnChange = cboSourceChange
    end
  end
  object pnlStatus: TGLPanel
    Left = 0
    Top = 416
    Width = 560
    Height = 24
    Align = alBottom
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 2
    object lblStatus: TGLLabel
      Transparent = True
      Left = 12
      Top = 4
      Width = 536
      Height = 15
      Anchors = [akLeft, akTop, akRight]
      Caption = ''
    end
  end
  object pnlLog: TGLPanel
    Left = 0
    Top = 306
    Width = 560
    Height = 110
    Align = alBottom
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 3
    Visible = False
    object memLog: TGLMemo
      Left = 0
      Top = 0
      Width = 560
      Height = 110
      Align = alClient
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -12
      Font.Name = 'Consolas'
      Font.Style = []
      ParentFont = False
      ReadOnly = True
      ScrollBars = ssVertical
      TabOrder = 0
    end
  end
  object pnlSurface: TGLPanel
    Left = 0
    Top = 74
    Width = 560
    Height = 232
    Align = alClient
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 4
    OnResize = pnlSurfaceResize
  end
  object tmrPump: TTimer
    Enabled = False
    Interval = 30
    OnTimer = tmrPumpTimer
    Left = 480
    Top = 120
  end
end
