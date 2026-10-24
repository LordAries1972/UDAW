object frmVideoPlayer: TfrmVideoPlayer
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu]
  BorderStyle = bsSingle
  Caption = 'Video'
  ClientHeight = 360
  ClientWidth = 640
  Color = clBlack
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poOwnerFormCenter
  OnClose = FormClose
  OnKeyDown = FormKeyDown
  TextHeight = 15
  object pnlVideo: TGLPanel
    Left = 0
    Top = 0
    Width = 640
    Height = 360
    Align = alClient
    BevelOuter = bvNone
    Color = clBlack
    ParentBackground = False
    ShowCaption = False
    TabOrder = 0
    OnResize = pnlVideoResize
  end
end
