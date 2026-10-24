object frmSpectrum: TfrmSpectrum
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu]
  Caption = 'Audio Spectrum'
  ClientHeight = 480
  ClientWidth = 880
  Color = clBlack
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
  object pbView: TGLView
    Left = 0
    Top = 0
    Width = 880
    Height = 480
    Align = alClient
    OnPaint = pbViewPaint
  end
  object tmrAnim: TTimer
    Enabled = False
    Interval = 25
    OnTimer = tmrAnimTimer
    Left = 24
    Top = 56
  end
end
