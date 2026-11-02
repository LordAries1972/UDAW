object frmPyEditor: TfrmPyEditor
  Left = 0
  Top = 0
  Caption = 'Python Plug-in Editor'
  BorderIcons = [biSystemMenu]
  ClientHeight = 700
  ClientWidth = 1040
  Color = clBtnFace
  Constraints.MinHeight = 420
  Constraints.MinWidth = 820
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnActivate = FormActivate
  OnClose = FormClose
  OnCloseQuery = FormCloseQuery
  OnCreate = FormCreate
  OnKeyDown = FormKeyDown
  TextHeight = 15
  object pnlToolbar: TGLPanel
    Left = 0
    Top = 0
    Width = 1040
    Height = 44
    Align = alTop
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 0
    object btnNew: TGLButton
      Left = 8
      Top = 9
      Width = 56
      Height = 26
      Caption = 'New'
      Hint = 'Start a new plug-in from the template (Ctrl+N).'
      ShowHint = True
      TabOrder = 0
      OnClick = btnNewClick
    end
    object btnOpen: TGLButton
      Left = 68
      Top = 9
      Width = 56
      Height = 26
      Caption = 'Open'
      Hint = 'Open a plug-in script (Ctrl+O).'
      ShowHint = True
      TabOrder = 1
      OnClick = btnOpenClick
    end
    object btnSave: TGLButton
      Left = 128
      Top = 9
      Width = 56
      Height = 26
      Caption = 'Save'
      Hint = 'Save the script (Ctrl+S).'
      ShowHint = True
      TabOrder = 2
      OnClick = btnSaveClick
    end
    object btnSaveAs: TGLButton
      Left = 188
      Top = 9
      Width = 70
      Height = 26
      Caption = 'Save As'
      Hint = 'Save the script under another name (Ctrl+Shift+S).'
      ShowHint = True
      TabOrder = 3
      OnClick = btnSaveAsClick
    end
    object btnValidate: TGLButton
      Left = 280
      Top = 9
      Width = 72
      Height = 26
      Caption = 'Validate'
      Hint = 'Check the script for errors without running it on real audio (F6): syntax, loading, parameters, the window, and a test signal through process().'
      ShowHint = True
      TabOrder = 4
      OnClick = btnValidateClick
    end
    object btnRun: TGLButton
      Left = 356
      Top = 9
      Width = 56
      Height = 26
      Caption = 'Run'
      Hint = 'Start the plug-in and open its window so you can try the controls (F5).'
      ShowHint = True
      TabOrder = 5
      OnClick = btnRunClick
    end
    object btnStop: TGLButton
      Left = 416
      Top = 9
      Width = 56
      Height = 26
      Caption = 'Stop'
      Hint = 'Stop the running plug-in.'
      ShowHint = True
      TabOrder = 6
      OnClick = btnStopClick
    end
    object lblTarget: TGLLabel
      Transparent = True
      Left = 600
      Top = 14
      Width = 70
      Height = 15
      Anchors = [akTop, akRight]
      Caption = 'Add to lane:'
    end
    object cboTarget: TGLCombo
      Left = 676
      Top = 9
      Width = 250
      Height = 26
      Anchors = [akTop, akRight]
      Hint = 'The Timeline lane / bus or Tracker channel the plug-in will be put on.'
      ShowHint = True
      TabOrder = 8
    end
    object btnAdd: TGLButton
      Left = 932
      Top = 9
      Width = 100
      Height = 26
      Anchors = [akTop, akRight]
      Caption = 'Add to Mixer'
      Hint = 'Put the plug-in, with the settings shown in its window, on the chosen lane or channel.'
      ShowHint = True
      TabOrder = 9
      OnClick = btnAddClick
    end
  end
  object stbMain: TGLStatusBar
    Left = 0
    Top = 678
    Width = 1040
    Height = 22
    Align = alBottom
    SimplePanel = True
    SimpleText = 'Write the plug-in, Validate, Run, then Add to Mixer.'
    TabOrder = 1
  end
  object pcOut: TGLPageControl
    Left = 0
    Top = 520
    Width = 1040
    Height = 158
    Align = alBottom
    TabOrder = 2
    object tabProblems: TGLPage
      Caption = 'Problems'
      object lstIssues: TGLList
        Left = 0
        Top = 0
        Width = 1032
        Height = 124
        Align = alClient
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -12
        Font.Name = 'Consolas'
        Font.Style = []
        ItemHeight = 20
        ParentFont = False
        TabOrder = 0
        OnClick = lstIssuesClick
      end
    end
    object tabOutput: TGLPage
      Caption = 'Output'
      object memOut: TGLMemo
        Left = 0
        Top = 0
        Width = 1032
        Height = 124
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
  end
  object splBottom: TGLSplitter
    Left = 0
    Top = 516
    Width = 1040
    Height = 4
    Align = alBottom
  end
  object memCode: TGLMemo
    Left = 0
    Top = 44
    Width = 1040
    Height = 472
    Align = alClient
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -14
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = False
    ScrollBars = ssBoth
    TabOrder = 3
    WordWrap = False
    OnChange = memCodeChange
  end
  object dlgOpen: TGLOpenDialog
    DefaultExt = 'py'
    Filter = 'Python plug-in (*.py)|*.py|All files (*.*)|*.*'
    Options = [ofFileMustExist]
    Title = 'Open a plug-in script'
    Left = 120
    Top = 120
  end
  object dlgSave: TGLSaveDialog
    DefaultExt = 'py'
    Filter = 'Python plug-in (*.py)|*.py|All files (*.*)|*.*'
    Options = [ofOverwritePrompt]
    Title = 'Save the plug-in script'
    Left = 200
    Top = 120
  end
end
