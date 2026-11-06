object frmVST2Editor: TfrmVST2Editor
  Left = 0
  Top = 0
  Caption = 'VST Plugin'
  BorderIcons = [biSystemMenu]
  ClientHeight = 524
  ClientWidth = 560
  Color = clBtnFace
  Constraints.MinHeight = 340
  Constraints.MinWidth = 560
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnClose = FormClose
  OnDestroy = FormDestroy
  OnResize = FormResize
  TextHeight = 15
  object pnlTop: TGLPanel
    Left = 0
    Top = 0
    Width = 560
    Height = 128
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object lblInfo: TGLLabel
      Transparent = True
      Left = 12
      Top = 14
      Width = 360
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
    object cboProgram: TGLCombo
      Left = 12
      Top = 42
      Width = 232
      Height = 24
      Hint = 'The plug-in'#39's programs (presets).'
      ShowHint = True
      TabOrder = 2
      OnChange = cboProgramChange
    end
    object chkBypass: TGLCheck
      Left = 254
      Top = 44
      Width = 76
      Height = 22
      Caption = 'Bypass'
      Hint = 'Switch the plug-in'#39's own bypass on (if it has one).'
      ShowHint = True
      TabOrder = 3
      OnChange = chkBypassChange
    end
    object chkLive: TGLCheck
      Left = 336
      Top = 44
      Width = 200
      Height = 22
      Caption = 'Live MIDI keyboard'
      Hint = 'Play this plug-in from the MIDI keyboard chosen in Settings (instruments, and effects that take MIDI).'
      ShowHint = True
      TabOrder = 4
      OnChange = chkLiveChange
    end
    object lblSource: TGLLabel
      Transparent = True
      Left = 12
      Top = 78
      Width = 60
      Height = 15
      Caption = 'Listen to:'
    end
    object cboSource: TGLCombo
      Left = 72
      Top = 74
      Width = 176
      Height = 24
      Hint = 'What plays through the plug-in: the built-in phrase, the Timeline range you highlighted (its sample input), nothing (an instrument played from MIDI), or the live input.'
      ShowHint = True
      Items.Strings = (
        'Built-in phrase'
        'Highlighted range'
        'Silence (MIDI only)'
        'Live input')
      ItemIndex = 0
      TabOrder = 5
      OnChange = cboSourceChange
    end
    object btnListen: TGLButton
      Left = 254
      Top = 73
      Width = 76
      Height = 26
      Caption = 'Listen'
      Hint = 'Play the plug-in through the audio device.'
      ShowHint = True
      Toggle = True
      TabOrder = 6
      OnClick = btnListenClick
    end
    object cboNote: TGLCombo
      Left = 336
      Top = 74
      Width = 70
      Height = 24
      Hint = 'The note the Note button plays.'
      ShowHint = True
      TabOrder = 7
    end
    object btnTest: TGLButton
      Left = 412
      Top = 73
      Width = 64
      Height = 26
      Caption = 'Note'
      Hint = 'Sound a test note (an instrument, or an effect that takes MIDI).'
      ShowHint = True
      TabOrder = 8
      OnClick = btnTestClick
    end
    object btnPanic: TGLButton
      Left = 482
      Top = 73
      Width = 66
      Height = 26
      Anchors = [akTop, akRight]
      Caption = 'Panic'
      Hint = 'All notes off.'
      ShowHint = True
      TabOrder = 9
      OnClick = btnPanicClick
    end
    object lblStatus: TGLLabel
      Transparent = True
      Left = 12
      Top = 106
      Width = 536
      Height = 15
      Anchors = [akLeft, akTop, akRight]
      Caption = ''
    end
  end
  object pnlHost: TGLPanel
    Left = 0
    Top = 128
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
    Top = 128
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
      object edtParamText: TGLEdit
        Left = 20
        Top = 210
        Width = 200
        Height = 24
        Anchors = [akLeft, akTop, akRight]
        Hint = 'Type a value the way the plug-in shows it (for example 440 Hz or -6 dB), then press Set.'
        ShowHint = True
        TabOrder = 1
      end
      object btnParamText: TGLButton
        Left = 228
        Top = 209
        Width = 60
        Height = 26
        Anchors = [akTop, akRight]
        Caption = 'Set'
        Hint = 'Give the parameter the value typed in the box.'
        ShowHint = True
        TabOrder = 2
        OnClick = btnParamTextClick
      end
      object lblParamInfo: TGLLabel
        Transparent = True
        Left = 20
        Top = 246
        Width = 290
        Height = 15
        Caption = ''
      end
    end
  end
  object tmrIdle: TTimer
    Enabled = False
    Interval = 30
    OnTimer = tmrIdleTimer
    Left = 456
    Top = 130
  end
end
