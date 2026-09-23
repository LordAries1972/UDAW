object frmAbout: TfrmAbout
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'About Ultimanium UDAW'
  ClientHeight = 240
  ClientWidth = 380
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
    Width = 380
    Height = 240
    Align = alClient
    BevelOuter = bvNone
    TabOrder = 0
    object lblAppName: TLabel
      Left = 24
      Top = 20
      Width = 200
      Height = 25
      Caption = 'Ultimanium UDAW'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -19
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
    object lblPublisher: TLabel
      Left = 24
      Top = 58
      Width = 130
      Height = 15
      Caption = 'by Ultimanium Designs'
    end
    object lblAuthor: TLabel
      Left = 24
      Top = 78
      Width = 220
      Height = 15
      Caption = 'Daniel J. Hobson of Australia, 2026'
    end
    object lblVersion: TLabel
      Left = 24
      Top = 98
      Width = 100
      Height = 15
      Caption = 'Version 0.0.0.0'
    end
    object lblWebsiteCaption: TLabel
      Left = 24
      Top = 134
      Width = 51
      Height = 15
      Caption = 'Website:'
    end
    object lblWebsite: TLabel
      Left = 24
      Top = 154
      Width = 110
      Height = 15
      Cursor = crHandPoint
      Caption = 'https://ultimanium.com/'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clHighlight
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = [fsUnderline]
      ParentFont = False
      OnClick = lblWebsiteClick
    end
    object btnClose: TButton
      Left = 280
      Top = 195
      Width = 80
      Height = 25
      Caption = 'Close'
      Default = True
      ModalResult = 1
      TabOrder = 0
      OnClick = btnCloseClick
    end
  end
end
