object frmFoley: TfrmFoley
  Left = 0
  Top = 0
  Caption = 'Foley Sampler'
  ClientHeight = 444
  ClientWidth = 484
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poOwnerFormCenter
  OnDestroy = FormDestroy
  OnKeyDown = FormKeyDown
  OnKeyUp = FormKeyUp
  OnShow = FormShow
  TextHeight = 15
  object btnPad1: TButton
    Left = 12
    Top = 12
    Width = 108
    Height = 64
    Tag = 0
    Caption = 'Pad'
    Hint = 'Foley pad 1: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 0
    OnClick = PadClick
  end
  object btnPad2: TButton
    Left = 128
    Top = 12
    Width = 108
    Height = 64
    Tag = 1
    Caption = 'Pad'
    Hint = 'Foley pad 2: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 1
    OnClick = PadClick
  end
  object btnPad3: TButton
    Left = 244
    Top = 12
    Width = 108
    Height = 64
    Tag = 2
    Caption = 'Pad'
    Hint = 'Foley pad 3: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 2
    OnClick = PadClick
  end
  object btnPad4: TButton
    Left = 360
    Top = 12
    Width = 108
    Height = 64
    Tag = 3
    Caption = 'Pad'
    Hint = 'Foley pad 4: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 3
    OnClick = PadClick
  end
  object btnPad5: TButton
    Left = 12
    Top = 84
    Width = 108
    Height = 64
    Tag = 4
    Caption = 'Pad'
    Hint = 'Foley pad 5: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 4
    OnClick = PadClick
  end
  object btnPad6: TButton
    Left = 128
    Top = 84
    Width = 108
    Height = 64
    Tag = 5
    Caption = 'Pad'
    Hint = 'Foley pad 6: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 5
    OnClick = PadClick
  end
  object btnPad7: TButton
    Left = 244
    Top = 84
    Width = 108
    Height = 64
    Tag = 6
    Caption = 'Pad'
    Hint = 'Foley pad 7: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 6
    OnClick = PadClick
  end
  object btnPad8: TButton
    Left = 360
    Top = 84
    Width = 108
    Height = 64
    Tag = 7
    Caption = 'Pad'
    Hint = 'Foley pad 8: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 7
    OnClick = PadClick
  end
  object btnPad9: TButton
    Left = 12
    Top = 156
    Width = 108
    Height = 64
    Tag = 8
    Caption = 'Pad'
    Hint = 'Foley pad 9: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 8
    OnClick = PadClick
  end
  object btnPad10: TButton
    Left = 128
    Top = 156
    Width = 108
    Height = 64
    Tag = 9
    Caption = 'Pad'
    Hint = 'Foley pad 10: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 9
    OnClick = PadClick
  end
  object btnPad11: TButton
    Left = 244
    Top = 156
    Width = 108
    Height = 64
    Tag = 10
    Caption = 'Pad'
    Hint = 'Foley pad 11: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 10
    OnClick = PadClick
  end
  object btnPad12: TButton
    Left = 360
    Top = 156
    Width = 108
    Height = 64
    Tag = 11
    Caption = 'Pad'
    Hint = 'Foley pad 12: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 11
    OnClick = PadClick
  end
  object btnPad13: TButton
    Left = 12
    Top = 228
    Width = 108
    Height = 64
    Tag = 12
    Caption = 'Pad'
    Hint = 'Foley pad 13: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 12
    OnClick = PadClick
  end
  object btnPad14: TButton
    Left = 128
    Top = 228
    Width = 108
    Height = 64
    Tag = 13
    Caption = 'Pad'
    Hint = 'Foley pad 14: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 13
    OnClick = PadClick
  end
  object btnPad15: TButton
    Left = 244
    Top = 228
    Width = 108
    Height = 64
    Tag = 14
    Caption = 'Pad'
    Hint = 'Foley pad 15: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 14
    OnClick = PadClick
  end
  object btnPad16: TButton
    Left = 360
    Top = 228
    Width = 108
    Height = 64
    Tag = 15
    Caption = 'Pad'
    Hint = 'Foley pad 16: click or press its key to play the loaded sound and record the hit.'
    TabOrder = 15
    OnClick = PadClick
  end
  object lblSelected: TGLLabel
    Left = 12
    Top = 308
    Width = 460
    Height = 15
    Caption = 'Pad'
    Transparent = True
  end
  object btnLoadPad: TButton
    Left = 12
    Top = 330
    Width = 130
    Height = 25
    Caption = 'Load into pad...'
    Hint = 'Load a sound file into the selected pad.'
    TabOrder = 16
    OnClick = btnLoadPadClick
  end
  object btnClearPad: TButton
    Left = 148
    Top = 330
    Width = 90
    Height = 25
    Caption = 'Clear pad'
    Hint = 'Remove the sound from the selected pad.'
    TabOrder = 17
    OnClick = btnClearPadClick
  end
  object btnPlace: TButton
    Left = 244
    Top = 330
    Width = 228
    Height = 25
    Caption = 'Place pad at playhead'
    Hint = 'Place the selected pad''s sound on the Timeline at the playhead.'
    TabOrder = 18
    OnClick = btnPlaceClick
  end
  object chkTimeline: TGLCheck
    Left = 12
    Top = 356
    Width = 460
    Height = 20
    Caption = 'A pad key adds its sound at the playhead (splits the clip it lands in)'
    Checked = True
    Hint = 'Pressing a pad key puts that pad''s sound on the selected Timeline lane at the playhead. If the playhead is inside a clip, the clip is split and the sound goes between the two halves.'
    TabOrder = 22
  end
  object chkRecord: TGLCheck
    Left = 12
    Top = 390
    Width = 230
    Height = 20
    Caption = 'Record hits while the Timeline plays'
    TabOrder = 19
  end
  object lblHits: TGLLabel
    Left = 250
    Top = 393
    Width = 120
    Height = 15
    Caption = '0 hit(s) recorded'
    Transparent = True
  end
  object btnCommit: TButton
    Left = 12
    Top = 412
    Width = 226
    Height = 25
    Caption = 'Add hits to Timeline'
    Hint = 'Add every recorded hit to the Timeline as clips.'
    Enabled = False
    TabOrder = 20
    OnClick = btnCommitClick
  end
  object btnClearHits: TButton
    Left = 244
    Top = 412
    Width = 120
    Height = 25
    Caption = 'Discard hits'
    Hint = 'Throw away the recorded hits without adding them.'
    Enabled = False
    TabOrder = 21
    OnClick = btnClearHitsClick
  end
  object dlgOpenSample: TGLOpenDialog
    Filter = 'Sound effects (*.wav;*.mp3)|*.wav;*.mp3|All files (*.*)|*.*'
    Title = 'Load a sound into the pad'
    Left = 420
    Top = 380
  end
end
