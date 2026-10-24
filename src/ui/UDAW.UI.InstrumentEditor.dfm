object frmInstrumentEditor: TfrmInstrumentEditor
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'Instrument editor'
  ClientHeight = 628
  ClientWidth = 884
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poOwnerFormCenter
  OnKeyDown = FormKeyDown
  TextHeight = 15
  object lblTitle: TGLLabel
    Left = 12
    Top = 8
    Width = 600
    Height = 24
    AutoSize = False
    Caption = ''
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -18
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object lblInfo: TGLLabel
    Left = 12
    Top = 32
    Width = 700
    Height = 15
    AutoSize = False
    Caption = ''
  end
  object pbWave: TGLView
    Left = 12
    Top = 54
    Width = 860
    Height = 232
    Cursor = crCross
    OnDblClick = pbWaveDblClick
    OnMouseDown = pbWaveMouseDown
    OnMouseMove = pbWaveMouseMove
    OnMouseUp = pbWaveMouseUp
    OnMouseWheel = pbWaveMouseWheel
    OnPaint = pbWavePaint
  end
  object sbWave: TGLScrollBar
    Left = 12
    Top = 290
    Width = 860
    Height = 16
    TabOrder = 0
    OnChange = sbWaveChange
  end
  object ibTransport: TGLIconBar
    Left = 12
    Top = 314
    Width = 118
    Height = 36
    ShowHint = True
    Buttons = 'play;stop;undo'
    Hints = 'Play the marked region (or the whole sound) through the pad - Space;Stop the sound;Undo the last edit - Ctrl+Z'
    CellWidth = 38
    OnButtonClick = ToolClick
  end
  object ibView: TGLIconBar
    Left = 142
    Top = 314
    Width = 194
    Height = 36
    ShowHint = True
    Buttons = 'selall;zoomin;zoomout;zoomsel;fit'
    Hints = 'Mark the whole sound - Ctrl+A or double-click the waveform;Zoom in - mouse wheel over the waveform;Zoom out - mouse wheel over the waveform;Zoom to the marked region;Show the whole sound'
    CellWidth = 38
    OnButtonClick = ToolClick
  end
  object ibEdit: TGLIconBar
    Left = 348
    Top = 314
    Width = 270
    Height = 36
    ShowHint = True
    Buttons = 'trim;cut;silence;reverse;normalize;fadein;fadeout'
    Hints = 'Trim - keep only the marked region;Cut - remove the marked region and join the ends (Delete);Silence - make the marked region silent;Reverse - play the region backwards;Normalise - raise the region to just under full scale;Fade in - from silence;Fade out - to silence'
    CellWidth = 38
    OnButtonClick = ToolClick
  end
  object ibEffects: TGLIconBar
    Left = 630
    Top = 314
    Width = 42
    Height = 36
    ShowHint = True
    Buttons = 'tools'
    Hints = 'Edit and apply the effect chosen in the list to the marked region'
    CellWidth = 38
    OnButtonClick = ToolClick
  end
  object ibFile: TGLIconBar
    Left = 684
    Top = 314
    Width = 42
    Height = 36
    ShowHint = True
    Buttons = 'save'
    Hints = 'Save the audio to a WAV file on disk;Loop: the clip repeats on the Timeline until the last segment (lit = on)'
    CellWidth = 38
    OnButtonClick = FileToolClick
  end
  object dlgSaveWav: TGLSaveDialog
    DefaultExt = 'wav'
    Filter = 'WAV audio (*.wav)|*.wav|All files (*.*)|*.*'
    Left = 820
    Top = 314
  end
  object lblSel: TGLLabel
    Left = 12
    Top = 358
    Width = 860
    Height = 15
    AutoSize = False
    Caption = ''
  end
  object grpRegion: TGLGroup
    Left = 12
    Top = 382
    Width = 590
    Height = 146
    Caption = ' Region tools '
    TabOrder = 1
   object knobGain: TGLKnob
     Left = 16
     Top = 26
     Width = 96
     Height = 104
     Caption = 'Level (dB)'
     ShowHint = True
     Hint = 'Level change for the region. Double-click resets.'
     TabOrder = 0
     Min = -24
     Max = 24
     Position = 0
     DefaultPosition = 0
     Decimals = 1
   end
   object ibGain: TGLIconBar
     Left = 118
     Top = 62
     Width = 42
     Height = 36
     ShowHint = True
     Buttons = 'gain'
     Hints = 'Apply the level change to the marked region'
     CellWidth = 38
     OnButtonClick = ToolClick
   end
   object knobExtend: TGLKnob
     Left = 212
     Top = 26
     Width = 96
     Height = 104
     Caption = 'Add (ms)'
     ShowHint = True
     Hint = 'How much silence to add after the region - room for a reverb or echo tail.'
     TabOrder = 1
     Min = 10
     Max = 3000
     Position = 500
     DefaultPosition = 500
     Decimals = 0
     Logarithmic = True
   end
   object ibExtend: TGLIconBar
     Left = 314
     Top = 62
     Width = 42
     Height = 36
     ShowHint = True
     Buttons = 'extend'
     Hints = 'Insert the silence after the marked region, or at the end'
     CellWidth = 38
     OnButtonClick = ToolClick
   end
   object knobStretch: TGLKnob
     Left = 408
     Top = 26
     Width = 96
     Height = 104
     Caption = 'Length (%)'
     ShowHint = True
     Hint = 'New length of the region as a percentage - pitch is kept.'
     TabOrder = 2
     Min = 25
     Max = 400
     Position = 100
     DefaultPosition = 100
     Decimals = 0
   end
   object ibStretch: TGLIconBar
     Left = 510
     Top = 62
     Width = 42
     Height = 36
     ShowHint = True
     Buttons = 'stretch'
     Hints = 'Stretch the marked region to this length without changing its pitch'
     CellWidth = 38
     OnButtonClick = ToolClick
   end
  end
  object grpFx: TGLGroup
    Left = 614
    Top = 382
    Width = 258
    Height = 200
    Caption = ' Effects - double-click to edit and apply '
    TabOrder = 2
    object edtFilter: TGLEdit
      Left = 8
      Top = 24
      Width = 242
      Height = 24
      TextHint = 'Find an effect...'
      TabOrder = 0
      OnChange = edtFilterChange
    end
    object lstFx: TGLList
      Left = 8
      Top = 54
      Width = 242
      Height = 136
      TabOrder = 1
      OnDblClick = lstFxDblClick
    end
  end
  object lblHint: TGLLabel
    Left = 12
    Top = 542
    Width = 590
    Height = 40
    AutoSize = False
    WordWrap = True
    Caption = 'Effects only change the marked region. To leave room for a reverb or echo tail, add silence after the region first.'
  end
  object ibDialog: TGLIconBar
    Left = 772
    Top = 588
    Width = 100
    Height = 36
    ShowHint = True
    Buttons = 'ok;erase'
    Hints = 'OK - keep the edited sound on this instrument;Cancel - put the original sound back'
    CellWidth = 48
    OnButtonClick = DialogClick
  end
end
