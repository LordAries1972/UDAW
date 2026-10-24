object frmProjectStart: TfrmProjectStart
  Left = 0
  Top = 0
  AlphaBlend = True
  AlphaBlendValue = 232
  BorderIcons = []
  BorderStyle = bsNone
  Caption = 'Welcome to UDAW'
  ClientHeight = 560
  ClientWidth = 560
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poScreenCenter
  OnCreate = FormCreate
  OnKeyDown = FormKeyDown
  TextHeight = 15
  object tmrShine: TTimer
    Interval = 30
    OnTimer = tmrShineTimer
    Left = 16
    Top = 16
  end
  object pnlBody: TGLPanel
    Left = 0
    Top = 124
    Width = 560
    Height = 436
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 0
      object lblVersion: TGLLabel
        Left = 0
        Top = 12
        Width = 560
        Height = 30
        Alignment = taCenter
        AutoSize = False
        Caption = 'Version'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -24
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
      end
      object lblStart: TGLLabel
        Left = 40
        Top = 50
        Width = 230
        Height = 16
        AutoSize = False
        Caption = 'START'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clGrayText
        Font.Height = -11
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
      end
      object btnNew: TGLButton
        Left = 40
        Top = 76
        Width = 230
        Height = 44
        Hint = 'Start a new, empty project'
        Caption = 'New Project'
        OnClick = btnNewClick
      end
      object btnOpen: TGLButton
        Left = 40
        Top = 128
        Width = 230
        Height = 44
        Hint = 'Open a project file from disk'
        Caption = 'Open Project...'
        OnClick = btnOpenClick
      end
      object bvlOpenSep: TGLShineBar
        Left = 40
        Top = 184
        Width = 230
        Height = 8
      end
      object lblLearn: TGLLabel
        Left = 40
        Top = 204
        Width = 230
        Height = 16
        AutoSize = False
        Caption = 'LEARN'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clGrayText
        Font.Height = -11
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
      end
      object btnHelp: TGLButton
        Left = 40
        Top = 230
        Width = 230
        Height = 44
        Hint = 'Open the UDAW Help Centre'
        Caption = 'Help'
        OnClick = btnHelpClick
      end
      object btnAbout: TGLButton
        Left = 40
        Top = 282
        Width = 230
        Height = 44
        Hint = 'Version, publisher and credits'
        Caption = 'About UDAW'
        OnClick = btnAboutClick
      end
      object lblRecent: TGLLabel
        Left = 290
        Top = 50
        Width = 230
        Height = 16
        AutoSize = False
        Caption = 'RECENT PROJECTS'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clGrayText
        Font.Height = -11
        Font.Name = 'Segoe UI'
        Font.Style = [fsBold]
        ParentFont = False
      end
      object btnRecent0: TGLButton
        Left = 290
        Top = 76
        Width = 230
        Height = 44
        Caption = '-'
        Tag = 0
        OnClick = btnRecentClick
      end
      object btnRecent1: TGLButton
        Left = 290
        Top = 128
        Width = 230
        Height = 44
        Caption = '-'
        Tag = 1
        OnClick = btnRecentClick
      end
      object btnRecent2: TGLButton
        Left = 290
        Top = 180
        Width = 230
        Height = 44
        Caption = '-'
        Tag = 2
        OnClick = btnRecentClick
      end
      object btnRecent3: TGLButton
        Left = 290
        Top = 232
        Width = 230
        Height = 44
        Caption = '-'
        Tag = 3
        OnClick = btnRecentClick
      end
      object btnRecent4: TGLButton
        Left = 290
        Top = 284
        Width = 230
        Height = 44
        Caption = '-'
        Tag = 4
        OnClick = btnRecentClick
      end
      object lblTagline: TGLLabel
        Left = 40
        Top = 396
        Width = 280
        Height = 16
        AutoSize = False
        Caption = 'Pick up where you left off, or start something new.'
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clGrayText
        Font.Height = -12
        Font.Name = 'Segoe UI'
        Font.Style = []
        ParentFont = False
      end
      object chkShowOnStartup: TGLCheck
        Left = 340
        Top = 394
        Width = 180
        Height = 20
        Hint = 'Show this screen every time UDAW starts. Also available in Settings.'
        Caption = 'Show on Startup'
        Checked = True
        ParentShowHint = False
        ShowHint = True
      end
  end
end
