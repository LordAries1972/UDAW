object frmMixInsertParams: TfrmMixInsertParams
  Left = 0
  Top = 0
  Caption = 'Edit parameters'
  ClientHeight = 360
  ClientWidth = 460
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  TextHeight = 15
  object pnlTop: TPanel
    Left = 0
    Top = 0
    Width = 460
    Height = 28
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object lblKind: TLabel
      Transparent = True
      Left = 8
      Top = 6
      Width = 60
      Height = 15
      Caption = 'Insert kind'
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -12
      Font.Name = 'Segoe UI'
      Font.Style = [fsBold]
      ParentFont = False
    end
  end
  object pnlPresets: TPanel
    Left = 0
    Top = 28
    Width = 460
    Height = 33
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 1
    object lblPreset: TLabel
      Transparent = True
      Left = 8
      Top = 9
      Width = 40
      Height = 15
      Caption = 'Preset:'
    end
    object cboPreset: TComboBox
      Left = 54
      Top = 5
      Width = 160
      Height = 23
      TabOrder = 0
    end
    object btnLoadPreset: TButton
      Left = 220
      Top = 4
      Width = 65
      Height = 25
      Caption = 'Load'
      TabOrder = 1
      OnClick = btnLoadPresetClick
    end
    object btnSavePreset: TButton
      Left = 289
      Top = 4
      Width = 80
      Height = 25
      Caption = 'Save as...'
      TabOrder = 2
      OnClick = btnSavePresetClick
    end
    object btnDeletePreset: TButton
      Left = 373
      Top = 4
      Width = 78
      Height = 25
      Caption = 'Delete'
      TabOrder = 3
      OnClick = btnDeletePresetClick
    end
  end
  object pnlBody: TPanel
    Left = 0
    Top = 61
    Width = 460
    Height = 254
    Align = alClient
    BevelOuter = bvNone
    TabOrder = 2
    object lbParams: TListBox
      Left = 0
      Top = 0
      Width = 220
      Height = 254
      Align = alLeft
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -12
      Font.Name = 'Consolas'
      Font.Style = []
      ItemHeight = 15
      ParentFont = False
      TabOrder = 0
      OnClick = lbParamsClick
    end
    object pnlDetail: TPanel
      Left = 220
      Top = 0
      Width = 240
      Height = 254
      Align = alClient
      BevelOuter = bvNone
      TabOrder = 1
      object lblParamKey: TLabel
        Transparent = True
        Left = 12
        Top = 16
        Width = 62
        Height = 15
        Caption = 'param key'
      end
      object edtParamValue: TEdit
        Left = 12
        Top = 40
        Width = 200
        Height = 23
        Enabled = False
        TabOrder = 0
        OnKeyPress = edtParamValueKeyPress
      end
      object btnParamApply: TButton
        Left = 12
        Top = 72
        Width = 100
        Height = 25
        Caption = 'Update'
        TabOrder = 1
        OnClick = btnParamApplyClick
      end
    end
  end
  object pnlButtons: TPanel
    Left = 0
    Top = 315
    Width = 460
    Height = 45
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 3
    object btnOK: TButton
      Left = 292
      Top = 10
      Width = 75
      Height = 25
      Caption = 'OK'
      Default = True
      ModalResult = 1
      TabOrder = 0
    end
    object btnCancel: TButton
      Left = 373
      Top = 10
      Width = 75
      Height = 25
      Cancel = True
      Caption = 'Cancel'
      ModalResult = 2
      TabOrder = 1
    end
  end
end
