object frmEffectEditor: TfrmEffectEditor
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'Effect'
  ClientHeight = 722
  ClientWidth = 712
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poOwnerFormCenter
  OnCreate = FormCreate
  OnKeyDown = FormKeyDown
  TextHeight = 15
  object lblTitle: TGLLabel
    Left = 12
    Top = 10
    Width = 200
    Height = 25
    AutoSize = False
    Caption = 'Effect'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -19
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object lblSub: TGLLabel
    Left = 12
    Top = 34
    Width = 420
    Height = 15
    AutoSize = False
    Caption = ''
  end
  object knob1: TGLKnob
    Left = 12
    Top = 56
    Width = 96
    Height = 104
    TabOrder = 0
    Visible = False
    OnChange = ControlChanged
  end
  object knob2: TGLKnob
    Left = 116
    Top = 56
    Width = 96
    Height = 104
    TabOrder = 1
    Visible = False
    OnChange = ControlChanged
  end
  object knob3: TGLKnob
    Left = 220
    Top = 56
    Width = 96
    Height = 104
    TabOrder = 2
    Visible = False
    OnChange = ControlChanged
  end
  object knob4: TGLKnob
    Left = 324
    Top = 56
    Width = 96
    Height = 104
    TabOrder = 3
    Visible = False
    OnChange = ControlChanged
  end
  object knob5: TGLKnob
    Left = 12
    Top = 164
    Width = 96
    Height = 104
    TabOrder = 4
    Visible = False
    OnChange = ControlChanged
  end
  object knob6: TGLKnob
    Left = 116
    Top = 164
    Width = 96
    Height = 104
    TabOrder = 5
    Visible = False
    OnChange = ControlChanged
  end
  object knob7: TGLKnob
    Left = 220
    Top = 164
    Width = 96
    Height = 104
    TabOrder = 6
    Visible = False
    OnChange = ControlChanged
  end
  object knob8: TGLKnob
    Left = 324
    Top = 164
    Width = 96
    Height = 104
    TabOrder = 7
    Visible = False
    OnChange = ControlChanged
  end
  object knob9: TGLKnob
    Left = 12
    Top = 272
    Width = 96
    Height = 104
    TabOrder = 20
    Visible = False
    OnChange = ControlChanged
  end
  object knob10: TGLKnob
    Left = 116
    Top = 272
    Width = 96
    Height = 104
    TabOrder = 21
    Visible = False
    OnChange = ControlChanged
  end
  object knob11: TGLKnob
    Left = 220
    Top = 272
    Width = 96
    Height = 104
    TabOrder = 22
    Visible = False
    OnChange = ControlChanged
  end
  object knob12: TGLKnob
    Left = 324
    Top = 272
    Width = 96
    Height = 104
    TabOrder = 23
    Visible = False
    OnChange = ControlChanged
  end
  object chk1: TGLCheck
    Left = 12
    Top = 382
    Width = 100
    Height = 22
    Caption = ''
    TabOrder = 8
    Visible = False
    OnChange = ControlChanged
  end
  object chk2: TGLCheck
    Left = 116
    Top = 382
    Width = 100
    Height = 22
    Caption = ''
    TabOrder = 9
    Visible = False
    OnChange = ControlChanged
  end
  object chk3: TGLCheck
    Left = 220
    Top = 382
    Width = 100
    Height = 22
    Caption = ''
    TabOrder = 10
    Visible = False
    OnChange = ControlChanged
  end
  object chk4: TGLCheck
    Left = 324
    Top = 382
    Width = 100
    Height = 22
    Caption = ''
    TabOrder = 11
    Visible = False
    OnChange = ControlChanged
  end
  object lblNone: TGLLabel
    Left = 12
    Top = 60
    Width = 400
    Height = 15
    AutoSize = False
    Caption = 'This effect has no adjustable settings. The graphs below show what it does to the region.'
    Visible = False
  end
  object lblText: TGLLabel
    Left = 12
    Top = 410
    Width = 200
    Height = 15
    AutoSize = False
    Caption = 'Other settings (name=value;name=value)'
    Visible = False
  end
  object edtText: TGLEdit
    Left = 12
    Top = 428
    Width = 420
    Height = 24
    TabOrder = 12
    Visible = False
    OnChange = ControlChanged
  end
  object cboPreset: TGLCombo
    Left = 448
    Top = 8
    Width = 112
    Height = 24
    Style = csDropDown
    TabOrder = 24
    OnChange = cboPresetChange
  end
  object btnLoadPreset: TGLButton
    Left = 564
    Top = 8
    Width = 44
    Height = 24
    Caption = 'Load'
    ShowHint = True
    Hint = 'Load the preset named in the box.'
    TabOrder = 25
    OnClick = btnLoadPresetClick
  end
  object btnSavePreset: TGLButton
    Left = 612
    Top = 8
    Width = 48
    Height = 24
    Caption = 'Save'
    ShowHint = True
    Hint = 'Save these settings as a preset with the name typed in the box.'
    TabOrder = 26
    OnClick = btnSavePresetClick
  end
  object btnDeletePreset: TGLButton
    Left = 664
    Top = 8
    Width = 36
    Height = 24
    Caption = 'Del'
    ShowHint = True
    Hint = 'Delete the preset named in the box (click twice to confirm).'
    TabOrder = 27
    OnClick = btnDeletePresetClick
  end
  object lblNote: TGLLabel
    Left = 448
    Top = 36
    Width = 252
    Height = 15
    AutoSize = False
    Caption = ''
  end
  object pbCurve: TGLView
    Left = 448
    Top = 56
    Width = 252
    Height = 140
    OnPaint = pbCurvePaint
  end
  object pbGraph2: TGLView
    Left = 448
    Top = 204
    Width = 252
    Height = 140
    OnPaint = pbGraph2Paint
  end
  object pbScope: TGLView
    Left = 12
    Top = 462
    Width = 688
    Height = 212
    Cursor = crCross
    OnDblClick = pbScopeDblClick
    OnMouseLeave = pbScopeMouseLeave
    OnMouseMove = pbScopeMouseMove
    OnMouseWheel = pbScopeMouseWheel
    OnPaint = pbScopePaint
  end
  object btnReset: TGLButton
    Left = 12
    Top = 686
    Width = 84
    Height = 28
    Anchors = [akLeft, akBottom]
    Caption = '&Reset'
    ShowHint = True
    Hint = 'Back to the settings this window opened with.'
    TabOrder = 13
    OnClick = btnResetClick
  end
  object btnPreview: TGLButton
    Left = 104
    Top = 686
    Width = 110
    Height = 28
    Anchors = [akLeft, akBottom]
    Caption = '&Audition'
    ShowHint = True
    Hint = 'Play the region with these settings, without applying them.'
    TabOrder = 14
    Visible = False
    OnClick = btnPreviewClick
  end
  object btnOK: TGLButton
    Left = 528
    Top = 686
    Width = 84
    Height = 28
    Anchors = [akRight, akBottom]
    Caption = 'OK'
    Default = True
    TabOrder = 15
    OnClick = btnOKClick
  end
  object btnCancel: TGLButton
    Left = 616
    Top = 686
    Width = 84
    Height = 28
    Anchors = [akRight, akBottom]
    Caption = 'Cancel'
    TabOrder = 16
    OnClick = btnCancelClick
  end
  object tmrRender: TTimer
    Enabled = False
    Interval = 220
    OnTimer = tmrRenderTimer
    Left = 360
    Top = 8
  end
end
