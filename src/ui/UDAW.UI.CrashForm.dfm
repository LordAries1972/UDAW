object frmCrash: TfrmCrash
  Left = 0
  Top = 0
  BorderIcons = []
  Caption = 'UDAW - Unexpected error'
  ClientHeight = 540
  ClientWidth = 760
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnClose = FormClose
  OnCloseQuery = FormCloseQuery
  TextHeight = 15
  object lblHeadline: TGLLabel
    Transparent = True
    Left = 16
    Top = 12
    Width = 728
    Height = 26
    AutoSize = False
    Caption = 'UDAW hit an unexpected error and has to close.'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -18
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object lblNote: TGLLabel
    Transparent = True
    Left = 16
    Top = 44
    Width = 728
    Height = 32
    AutoSize = False
    Caption = 'The report below says what happened and where. Copy it or save it before you exit, and send it with your problem report.'
  end
  object memTrace: TGLMemo
    Left = 16
    Top = 84
    Width = 728
    Height = 384
    Anchors = [akLeft, akTop, akRight, akBottom]
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    PlainText = True
    ScrollBars = ssBoth
    TabOrder = 0
    WordWrap = False
  end
  object btnCopy: TGLButton
    Left = 16
    Top = 484
    Width = 120
    Height = 36
    Anchors = [akLeft, akBottom]
    Hint = 'Copy the whole report to the clipboard.'
    Caption = 'Copy'
    TabOrder = 1
    OnClick = btnCopyClick
  end
  object btnSave: TGLButton
    Left = 144
    Top = 484
    Width = 120
    Height = 36
    Anchors = [akLeft, akBottom]
    Hint = 'Save the report to a text file.'
    Caption = 'Save...'
    TabOrder = 2
    OnClick = btnSaveClick
  end
  object lblStatus: TGLLabel
    Transparent = True
    Left = 280
    Top = 494
    Width = 340
    Height = 16
    Anchors = [akLeft, akRight, akBottom]
    AutoSize = False
    Caption = ' '
  end
  object btnExit: TGLButton
    Left = 624
    Top = 484
    Width = 120
    Height = 36
    Anchors = [akRight, akBottom]
    Hint = 'Close UDAW.'
    Caption = 'Exit'
    TabOrder = 3
    OnClick = btnExitClick
  end
  object dlgSave: TGLSaveDialog
    DefaultExt = 'txt'
    Filter = 'Text file (*.txt)|*.txt|All files (*.*)|*.*'
    Title = 'Save the crash report'
    Left = 700
    Top = 8
  end
end
