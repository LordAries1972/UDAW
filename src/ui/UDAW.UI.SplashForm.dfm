object frmSplash: TfrmSplash
  Left = 0
  Top = 0
  BorderStyle = bsNone
  Caption = 'frmSplash'
  ClientHeight = 420
  ClientWidth = 420
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  TextHeight = 15
  object pnlMain: TPanel
    Left = 0
    Top = 0
    Width = 420
    Height = 420
    Align = alClient
    BevelOuter = bvRaised
    BevelWidth = 2
    TabOrder = 0
    object imgLogo: TImage
      Left = 20
      Top = 20
      Width = 380
      Height = 256
      Center = True
      Proportional = True
      Stretch = True
    end
    object pnlTitle: TPanel
      Left = 2
      Top = 286
      Width = 416
      Height = 28
      BevelOuter = bvNone
      Caption = ''
      TabOrder = 2
    end
    object lblVersion: TGLLabel
      Left = 0
      Top = 318
      Width = 420
      Height = 15
      Alignment = taCenter
      AutoSize = False
      Caption = 'Version 1.0.175.01/01/2026'
    end
    object lblAuthor: TGLLabel
      Left = 0
      Top = 338
      Width = 420
      Height = 15
      Alignment = taCenter
      AutoSize = False
      Caption = #169' Daniel J. Hobson of Australia, 2026'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clGrayText
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
    end
    object lblStatus: TGLLabel
      Left = 56
      Top = 366
      Width = 344
      Height = 15
      Caption = 'Starting...'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clGrayText
      Font.Height = -11
      Font.Name = 'Segoe UI'
      Font.Style = []
      ParentFont = False
    end
    object prgLoad: TGLCapsuleProgress
      Left = 20
      Top = 390
      Width = 380
      Height = 20
      Min = 0
      Max = 100
      TextSize = 10
      TabStop = False
    end
    object pnlActivity: TPanel
      Left = 20
      Top = 358
      Width = 30
      Height = 30
      BevelOuter = bvNone
      TabOrder = 1
    end
  end
end
