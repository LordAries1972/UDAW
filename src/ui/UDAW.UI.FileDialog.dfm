object frmGLFileDialog: TfrmGLFileDialog
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu, biMaximize]
  Caption = 'Open'
  ClientHeight = 460
  ClientWidth = 720
  Color = clBtnFace
  Constraints.MinHeight = 380
  Constraints.MinWidth = 560
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poMainFormCenter
  OnCreate = FormCreate
  OnKeyDown = FormKeyDown
  TextHeight = 15
  object lblLook: TGLLabel
    Left = 12
    Top = 15
    Width = 52
    Height = 15
    Caption = 'Look in:'
  end
  object cboPlaces: TGLCombo
    Left = 70
    Top = 10
    Width = 200
    Height = 24
    Hint = 'Jump to a drive or a common folder'
    TabOrder = 0
    OnChange = cboPlacesChange
  end
  object ibNav: TGLIconBar
    Left = 278
    Top = 6
    Width = 76
    Height = 32
    ShowHint = True
    Buttons = 'up;newfolder'
    Hints = 'Up one folder;New folder: creates a folder named like the text in the name box (or "New folder")'
    CellWidth = 38
    OnButtonClick = ibNavClick
  end
  object edPath: TGLEdit
    Left = 12
    Top = 44
    Width = 696
    Height = 24
    Hint = 'The current folder; type a path and press Enter to go there'
    Anchors = [akLeft, akTop, akRight]
    TabOrder = 1
    OnKeyDown = edPathKeyDown
  end
  object lvFiles: TGLListView
    Left = 12
    Top = 76
    Width = 696
    Height = 296
    Anchors = [akLeft, akTop, akRight, akBottom]
    Columns = <
      item
        Caption = 'Name'
        Width = 360
      end
      item
        Caption = 'Size'
        Width = 100
        Alignment = taRightJustify
      end
      item
        Caption = 'Modified'
        Width = 170
      end>
    ReadOnly = True
    RowSelect = True
    TabOrder = 4
    ViewStyle = vsReport
    OnClick = lvFilesClick
    OnDblClick = lvFilesDblClick
    OnMouseDown = lvFilesMouseDown
  end
  object lblName: TGLLabel
    Left = 12
    Top = 391
    Width = 66
    Height = 15
    Anchors = [akLeft, akBottom]
    Caption = 'File name:'
  end
  object edName: TGLEdit
    Left = 100
    Top = 386
    Width = 490
    Height = 24
    Anchors = [akLeft, akRight, akBottom]
    TabOrder = 5
  end
  object lblType: TGLLabel
    Left = 12
    Top = 423
    Width = 82
    Height = 15
    Anchors = [akLeft, akBottom]
    Caption = 'Files of type:'
  end
  object cboFilter: TGLCombo
    Left = 100
    Top = 418
    Width = 490
    Height = 24
    Anchors = [akLeft, akRight, akBottom]
    TabOrder = 6
    OnChange = cboFilterChange
  end
  object btnOK: TGLButton
    Left = 604
    Top = 385
    Width = 104
    Height = 26
    Anchors = [akRight, akBottom]
    Caption = 'Open'
    Default = True
    TabOrder = 7
    OnClick = btnOKClick
  end
  object btnCancel: TGLButton
    Left = 604
    Top = 417
    Width = 104
    Height = 26
    Anchors = [akRight, akBottom]
    Caption = 'Cancel'
    TabOrder = 8
    OnClick = btnCancelClick
  end
end
