object frmMeters: TfrmMeters
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu]
  Caption = 'Loudness and Phase Meters'
  ClientHeight = 520
  ClientWidth = 1040
  Color = clBtnFace
  DoubleBuffered = True
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poOwnerFormCenter
  OnHide = FormHide
  OnKeyDown = FormKeyDown
  OnShow = FormShow
  TextHeight = 15
  object pbMeters: TGLView
    Left = 0
    Top = 0
    Width = 620
    Height = 340
    Align = alClient
    OnPaint = pbMetersPaint
  end
  object pnlBottom: TPanel
    Left = 0
    Top = 340
    Width = 620
    Height = 40
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 0
    object lblSource: TGLLabel
      Left = 12
      Top = 6
      Width = 44
      Height = 24
      AutoSize = False
      Layout = tlCenter
      Caption = 'Source'
      Transparent = True
    end
    object cboSource: TGLCombo
      Left = 62
      Top = 6
      Width = 200
      Height = 28
      Hint = 'Which mixer the meters read: Automatic follows what is playing (a module in the Tracker, otherwise the Timeline).'
      ItemIndex = 0
      ParentShowHint = False
      ShowHint = True
      TabOrder = 1
      Items.Strings = (
        'Automatic (follows playback)'
        'Timeline'
        'Tracker Module')
    end
    object lblTargets: TGLLabel
      Left = 284
      Top = 6
      Width = 380
      Height = 24
      AutoSize = False
      Layout = tlCenter
      Caption = 'Master output. Delivery targets: -23 LUFS (broadcast), -14 LUFS (streaming).'
      Transparent = True
    end
    object btnReset: TButton
      Left = 660
      Top = 8
      Width = 84
      Height = 25
      Anchors = [akTop, akRight]
      Caption = 'Reset'
      Hint = 'Reset the loudness and peak readings so they start measuring again.'
      TabOrder = 0
      OnClick = btnResetClick
    end
  end
  object tmrMeters: TTimer
    Enabled = False
    Interval = 50
    OnTimer = tmrMetersTimer
    Left = 24
    Top = 24
  end
end
